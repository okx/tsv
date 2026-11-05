#!/usr/bin/env python3
"""Read Robinhood Stock Token prices and optionally rebalance TSV v4 pools."""

from __future__ import annotations

import argparse
from collections import deque
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation, localcontext
import hashlib
from html.parser import HTMLParser
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time
from zoneinfo import ZoneInfo
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CONFIG = Path(__file__).with_name("production_config.json")
TEST_CONFIG = Path(__file__).with_name("test_config.json")
Q96 = Decimal(2) ** 96


def progress(message: str) -> None:
    """Emit live status separately from the machine-readable JSON output."""
    stamp = datetime.now(timezone.utc).isoformat(timespec="seconds")
    print(f"[{stamp}] {message}", file=sys.stderr, flush=True)


class BroadcastOutcomeUncertain(RuntimeError):
    """A failed broadcast command must not be retried automatically."""


POOL_MANAGER_ABI = [{"type": "function", "name": "extsload", "stateMutability": "view",
                     "inputs": [{"name": "slot", "type": "bytes32"}],
                     "outputs": [{"name": "value", "type": "bytes32"}]}]
ERC20_ABI = [{"type": "function", "name": "decimals", "stateMutability": "view",
              "inputs": [], "outputs": [{"type": "uint8"}]}]
REGISTRY_ABI = [
    {"type": "function", "name": "getCurrencyUnderlying", "stateMutability": "view",
     "inputs": [{"name": "w", "type": "address"}],
     "outputs": [{"name": "underlying", "type": "address"}]},
    {"type": "function", "name": "getUnderlying", "stateMutability": "view",
     "inputs": [{"name": "u", "type": "address"}],
     "outputs": [{"name": "", "type": "tuple", "components": [
         {"name": "securityId", "type": "bytes32"},
         {"name": "legalShareAdapter", "type": "address"},
         {"name": "rawDecimals", "type": "uint8"},
         {"name": "registered", "type": "bool"},
     ]}]},
    {"type": "function", "name": "isTradable", "stateMutability": "view",
     "inputs": [{"name": "poolId", "type": "bytes32"}],
     "outputs": [{"type": "bool"}]},
    {"type": "function", "name": "hook", "stateMutability": "view",
     "inputs": [], "outputs": [{"type": "address"}]},
]
ROUTER_ABI = [{"type": "function", "name": "registry", "stateMutability": "view",
               "inputs": [], "outputs": [{"name": "", "type": "address"}]}]


def load_config(path: Path) -> dict:
    with path.open(encoding="utf-8") as handle:
        return json.load(handle)


def load_web3():
    try:
        from web3 import Web3
    except ImportError as exc:
        raise RuntimeError("Install requirements with: python3 -m pip install -r script/rwa-market-maker/requirements.txt") from exc
    return Web3


def pool_id(Web3, w3, key: dict) -> bytes:
    encoded = w3.codec.encode(
        ["address", "address", "uint24", "int24", "address"],
        [Web3.to_checksum_address(key["currency0"]), Web3.to_checksum_address(key["currency1"]),
         int(key["fee"]), int(key["tick_spacing"]), Web3.to_checksum_address(key["hooks"])],
    )
    return Web3.keccak(encoded)


def sqrt_price_at_tick(tick: int) -> int:
    with localcontext() as ctx:
        ctx.prec = 100
        ratio = Decimal("1.0001") ** (Decimal(tick) / 2)
        return int((Q96 * ratio).to_integral_value(rounding="ROUND_FLOOR"))


def tick_at_sqrt_price(sqrt_price_x96: int) -> int:
    with localcontext() as ctx:
        ctx.prec = 100
        ratio = Decimal(sqrt_price_x96) / Q96
        tick = 2 * ratio.ln() / Decimal("1.0001").ln()
        return int(tick.to_integral_value(rounding="ROUND_FLOOR"))


def initialized_ticks_between(Web3, w3, pool_manager: str, pool_id_hex: str,
                              tick_spacing: int, current_tick: int, target_tick: int):
    """Read initialized ticks between the current and target prices from v4 storage."""
    pid = bytes.fromhex(pool_id_hex.removeprefix("0x"))
    state_slot = int.from_bytes(Web3.keccak(pid + (6).to_bytes(32, "big")), "big")
    bitmap_mapping_slot = (state_slot + 5).to_bytes(32, "big")
    ticks_mapping_slot = (state_slot + 4).to_bytes(32, "big")
    low_compressed = min(current_tick, target_tick) // tick_spacing
    high_compressed = max(current_tick, target_tick) // tick_spacing
    low_word, high_word = low_compressed >> 8, high_compressed >> 8
    manager = w3.eth.contract(address=Web3.to_checksum_address(pool_manager), abi=POOL_MANAGER_ABI)
    initialized = []
    for word_pos in range(low_word, high_word + 1):
        bitmap_slot = Web3.keccak(w3.codec.encode(["int16", "bytes32"], [word_pos, bitmap_mapping_slot]))
        bitmap = int.from_bytes(manager.functions.extsload(bitmap_slot).call(), "big")
        while bitmap:
            least_bit = bitmap & -bitmap
            bit_pos = least_bit.bit_length() - 1
            compressed = word_pos * 256 + bit_pos
            tick = compressed * tick_spacing
            if min(current_tick, target_tick) <= tick <= max(current_tick, target_tick):
                tick_slot = Web3.keccak(w3.codec.encode(["int24", "bytes32"], [tick, ticks_mapping_slot]))
                packed = int.from_bytes(manager.functions.extsload(tick_slot).call(), "big")
                liquidity_net = packed >> 128
                if liquidity_net >= (1 << 127):
                    liquidity_net -= 1 << 128
                initialized.append((tick, liquidity_net))
            bitmap ^= least_bit
    return sorted(initialized, key=lambda row: row[0], reverse=target_tick < current_tick)


def estimate_exact_input_to_sqrt(Web3, w3, config: dict, pool: dict, target_sqrt: int,
                                 zero_for_one: bool, fee: int) -> int:
    """Estimate exact-input amount across initialized liquidity ticks, including pool fee."""
    current_sqrt = int(pool["sqrt_price_x96"])
    current_tick = int(pool["tick"])
    target_tick = tick_at_sqrt_price(target_sqrt)
    if (zero_for_one and target_sqrt >= current_sqrt) or (not zero_for_one and target_sqrt <= current_sqrt):
        raise RuntimeError("target price is not in the requested swap direction")

    boundaries = initialized_ticks_between(
        Web3, w3, config["pool_manager"], pool["pool_id"],
        int(pool["tick_spacing"]), current_tick, target_tick,
    )
    liquidity = int(pool["active_liquidity"])
    if liquidity <= 0:
        raise RuntimeError("cannot size trade: current tick has zero active liquidity")
    fee_denominator = 1_000_000 - fee
    if fee < 0 or fee_denominator <= 0:
        raise RuntimeError(f"invalid pool fee for input sizing: {fee}")

    def ceil_div(numerator: int, denominator: int) -> int:
        return (numerator + denominator - 1) // denominator

    total_input = 0

    def add_segment(sqrt_a: int, sqrt_b: int, active_liquidity: int) -> int:
        if sqrt_a == sqrt_b or active_liquidity == 0:
            return 0
        if zero_for_one:
            net_input = ceil_div(active_liquidity * (sqrt_a - sqrt_b) * int(Q96), sqrt_a * sqrt_b)
        else:
            net_input = ceil_div(active_liquidity * (sqrt_b - sqrt_a), int(Q96))
        return ceil_div(net_input * 1_000_000, fee_denominator) if net_input else 0

    cursor = current_sqrt
    for tick, liquidity_net in boundaries:
        boundary_sqrt = sqrt_price_at_tick(tick)
        if zero_for_one:
            if not target_sqrt < boundary_sqrt < cursor:
                continue
            total_input += add_segment(cursor, boundary_sqrt, liquidity)
            cursor = boundary_sqrt
            liquidity -= liquidity_net
        else:
            if not cursor < boundary_sqrt < target_sqrt:
                continue
            total_input += add_segment(cursor, boundary_sqrt, liquidity)
            cursor = boundary_sqrt
            liquidity += liquidity_net
        if liquidity < 0:
            raise RuntimeError(f"invalid liquidity transition at initialized tick {tick}")
        if liquidity == 0 and cursor != target_sqrt:
            next_boundary = next((t for t, _ in boundaries if
                                  (t < tick if zero_for_one else t > tick) and
                                  (sqrt_price_at_tick(t) > target_sqrt if zero_for_one else
                                   sqrt_price_at_tick(t) < target_sqrt)), None)
            if next_boundary is None:
                raise RuntimeError(
                    f"reference-price target is outside available pool liquidity; "
                    f"liquidity ends at initialized tick {tick}"
                )
    if cursor != target_sqrt:
        if liquidity == 0:
            raise RuntimeError("reference-price target is outside available pool liquidity")
        total_input += add_segment(cursor, target_sqrt, liquidity)
    if total_input <= 0:
        raise RuntimeError("calculated exact-input amount is zero")
    return total_input


def inspect_pool(Web3, w3, config: dict, asset: dict, *, require_tradable: bool = True):
    key = asset["pool_key"]
    c0 = Web3.to_checksum_address(key["currency0"])
    c1 = Web3.to_checksum_address(key["currency1"])
    if int(c0, 16) >= int(c1, 16):
        raise RuntimeError("PoolKey currencies must be sorted by address")

    pid = pool_id(Web3, w3, key)
    expected_pid = asset.get("pool_id")
    if expected_pid and pid.hex().lower() != expected_pid.removeprefix("0x").lower():
        raise RuntimeError(f"configured PoolId does not match PoolKey: computed 0x{pid.hex()}")

    manager = w3.eth.contract(address=Web3.to_checksum_address(config["pool_manager"]), abi=POOL_MANAGER_ABI)
    slot = Web3.keccak(w3.codec.encode(["bytes32", "uint256"], [pid, 6]))
    try:
        packed = int.from_bytes(manager.functions.extsload(slot).call(), "big")
    except Exception as exc:
        raise RuntimeError(f"PoolManager state read failed for 0x{pid.hex()}") from exc
    sqrt_x96 = packed & ((1 << 160) - 1)
    tick_raw = (packed >> 160) & ((1 << 24) - 1)
    tick = tick_raw - (1 << 24) if tick_raw & (1 << 23) else tick_raw
    if not sqrt_x96:
        raise RuntimeError(f"pool 0x{pid.hex()} is not initialized")

    registry_address = config["registry"]
    registry = w3.eth.contract(address=Web3.to_checksum_address(registry_address), abi=REGISTRY_ABI)
    registry_hook = Web3.to_checksum_address(registry.functions.hook().call())
    configured_hook = config.get("hook")
    if configured_hook and registry_hook.lower() != Web3.to_checksum_address(configured_hook).lower():
        raise RuntimeError(f"configured Hook {configured_hook} does not match Registry Hook {registry_hook}")
    if registry_hook.lower() != Web3.to_checksum_address(key["hooks"]).lower():
        raise RuntimeError(f"PoolKey Hook {key['hooks']} does not match Registry Hook {registry_hook}")
    if config.get("router"):
        router = w3.eth.contract(address=Web3.to_checksum_address(config["router"]), abi=ROUTER_ABI)
        router_registry = router.functions.registry().call()
        if router_registry.lower() != Web3.to_checksum_address(registry_address).lower():
            raise RuntimeError(f"configured router points to Registry {router_registry}, expected {registry_address}")
    underlying = Web3.to_checksum_address(asset["underlying_token"])
    expected_security_id = asset.get("security_id")
    if expected_security_id:
        underlying_record = registry.functions.getUnderlying(underlying).call()
        actual_security_id = bytes(underlying_record[0]).hex()
        if actual_security_id.lower() != expected_security_id.removeprefix("0x").lower():
            raise RuntimeError(f"Registry securityId for {underlying} does not match configured security_id")
        if not underlying_record[3]:
            raise RuntimeError(f"Registry underlying {underlying} is not registered")
    matches = [i for i, currency in enumerate((c0, c1))
               if registry.functions.getCurrencyUnderlying(currency).call().lower() == underlying.lower()]
    if len(matches) != 1:
        raise RuntimeError(f"Registry must map exactly one pool currency to {underlying}; found {len(matches)}")
    tradable = bool(registry.functions.isTradable(pid).call())
    if require_tradable and not tradable:
        raise RuntimeError(f"pool 0x{pid.hex()} is not tradable in the TSV Registry")

    liquidity_slot = (int.from_bytes(slot, "big") + 3).to_bytes(32, "big")
    active_liquidity = int.from_bytes(manager.functions.extsload(liquidity_slot).call(), "big") & ((1 << 128) - 1)

    stock_index = matches[0]
    quote_index = 1 - stock_index
    quote_address = (c0, c1)[quote_index]
    currencies = [w3.eth.contract(address=currency, abi=ERC20_ABI) for currency in (c0, c1)]
    decimals0, decimals1 = [int(token.functions.decimals().call()) for token in currencies]
    underlying_decimals = int(w3.eth.contract(address=underlying, abi=ERC20_ABI).functions.decimals().call())
    with localcontext() as ctx:
        ctx.prec = 80
        raw_price_1_per_0 = (Decimal(sqrt_x96) / Q96) ** 2
        human_price_1_per_0 = raw_price_1_per_0 * (Decimal(10) ** (decimals0 - decimals1))
        quote_per_stock = human_price_1_per_0 if stock_index == 0 else Decimal(1) / human_price_1_per_0
    return {
        "pool_id": "0x" + pid.hex(), "tick": tick, "sqrt_price_x96": str(sqrt_x96),
        "pool_quote_per_stock": quote_per_stock, "quote_address": quote_address,
        "quote_decimals": [decimals0, decimals1][quote_index],
        "currency0_decimals": decimals0, "currency1_decimals": decimals1,
        "fee": int(key["fee"]), "tick_spacing": int(key["tick_spacing"]),
        "underlying_decimals": underlying_decimals, "active_liquidity": active_liquidity,
        "tradable": tradable,
    }


class PageText(HTMLParser):
    """Extract visible page text and table rows without third-party HTML packages."""

    def __init__(self):
        super().__init__(convert_charrefs=True)
        self.parts = []
        self.rows = []
        self.row = None
        self.cell = ""
        self.skip_depth = 0

    def handle_starttag(self, tag, attrs):
        if tag in ("script", "style", "noscript"):
            self.skip_depth += 1
        if tag == "tr":
            self.row = []
        if tag in ("td", "th") and self.row is not None:
            self.cell = ""

    def handle_endtag(self, tag):
        if tag in ("script", "style", "noscript") and self.skip_depth:
            self.skip_depth -= 1
        if tag == "tr" and self.row is not None:
            self.rows.append(self.row)
            self.row = None
        if tag in ("td", "th") and self.row is not None:
            self.row.append(re.sub(r"\s+", " ", self.cell).strip())
            self.cell = ""

    def handle_data(self, data):
        if self.skip_depth:
            return
        clean = re.sub(r"\s+", " ", data).strip()
        if clean:
            self.parts.append(clean)
            if self.row is not None:
                self.cell += " " + clean


class MultiSourcePriceClient:
    """Fetches quotes with per-endpoint caching and a global 30/minute cap."""

    def __init__(self, max_requests_per_minute: int = 30, timeout_seconds: int = 20):
        self.max_requests = min(30, max(1, int(max_requests_per_minute)))
        self.timeout = timeout_seconds
        self.requests = deque()
        self.last_source_request: dict[str, float] = {}
        self.response_cache: dict[str, tuple[float, bytes]] = {}

    def fetch(self, source: str, url: str, min_interval: int) -> bytes:
        if not url.startswith(("https://api.robinhood.com/", "https://www.marketbeat.com/", "https://www.mexc.com/")):
            raise ValueError("price source URL is outside the configured provider allowlist")
        now = time.monotonic()
        # Cache cadence is per endpoint/page; BTGO and SECZ are separate MarketBeat URLs.
        request_key = url
        cached = self.response_cache.get(request_key)
        if cached is not None and now - cached[0] < min_interval:
            return cached[1]
        wait_for_source = min_interval - (now - self.last_source_request.get(request_key, -1e9))
        while wait_for_source > 0:
            time.sleep(wait_for_source)
            now = time.monotonic()
            wait_for_source = min_interval - (now - self.last_source_request.get(request_key, -1e9))
        while True:
            while self.requests and now - self.requests[0] >= 60:
                self.requests.popleft()
            if len(self.requests) < self.max_requests:
                break
            time.sleep(max(0.1, 60 - (now - self.requests[0])))
            now = time.monotonic()
        self.last_source_request[request_key] = now
        self.requests.append(now)
        request = Request(url, headers={"Accept": "text/html,application/json", "User-Agent": "Mozilla/5.0 (compatible; TSV-RWAMarketMaker/1.0)"})
        try:
            with urlopen(request, timeout=self.timeout) as response:
                body = response.read()
                self.response_cache[request_key] = (time.monotonic(), body)
                return body
        except HTTPError as exc:
            body = exc.read().decode("utf-8", errors="replace").strip()
            raise RuntimeError(f"{source} returned HTTP {exc.code}: {body[:300] or exc.reason}") from exc
        except URLError as exc:
            # Some macOS proxy/network setups fail in urllib before an HTTP response;
            # retry through the system curl client without invoking a shell.
            command = ["curl", "--fail", "--location", "--silent", "--show-error",
                       "--max-time", str(self.timeout), "-H", "Accept: text/html,application/json",
                       "-A", "Mozilla/5.0 (compatible; TSV-RWAMarketMaker/1.0)", url]
            try:
                result = subprocess.run(command, capture_output=True, check=False, timeout=self.timeout + 2)
            except (FileNotFoundError, subprocess.TimeoutExpired) as curl_exc:
                raise RuntimeError(f"{source} urllib failed ({exc}); curl fallback unavailable/timeout ({curl_exc})") from exc
            if result.returncode != 0:
                detail = result.stderr.decode("utf-8", errors="replace").strip()[-500:]
                raise RuntimeError(f"{source} urllib failed ({exc}); curl fallback failed (exit {result.returncode}): {detail}") from exc
            self.response_cache[request_key] = (time.monotonic(), result.stdout)
            return result.stdout


def freshness(quote: dict, max_age_seconds: int) -> dict:
    age = (datetime.now(timezone.utc) - quote["timestamp"].astimezone(timezone.utc)).total_seconds()
    if age < -10:
        raise RuntimeError(f"price timestamp is future-dated by {-age:.0f}s")
    return {**quote, "age_seconds": round(age, 1), "trade_eligible": age <= max_age_seconds}


def get_robinhood_quote(client: MultiSourcePriceClient, asset: dict) -> dict:
    symbol = asset["ticker"]
    if not re.fullmatch(r"[A-Z0-9.-]{1,20}", symbol):
        raise ValueError(f"invalid Robinhood ticker symbol: {symbol!r}")
    payload = json.loads(client.fetch("robinhood", f"https://api.robinhood.com/rhj/prices/{symbol}",
                                      int(asset.get("min_poll_seconds", 15))))
    quotes = payload.get("quotes") if isinstance(payload, dict) else None
    quote = next((row for row in quotes or [] if row.get("tokenSymbol") == symbol), None)
    if quote is None:
        raise RuntimeError(f"Robinhood returned no whitelisted Stock Token quote for {symbol}")
    if quote.get("currency") != "USD" or quote.get("isTradingHalt"):
        raise RuntimeError(f"Robinhood quote for {symbol} is halted or not denominated in USD")
    try:
        bid, ask = Decimal(str(quote["bid"])), Decimal(str(quote["ask"]))
        stamp = datetime.fromisoformat(quote["generatedAt"].replace("Z", "+00:00"))
    except (AttributeError, KeyError, InvalidOperation, ValueError) as exc:
        raise RuntimeError(f"Robinhood returned invalid price fields for {symbol}") from exc
    if bid <= 0 or ask < bid:
        raise RuntimeError(f"Robinhood returned invalid bid/ask for {symbol}")
    return freshness({"price": (bid + ask) / 2, "bid": bid, "ask": ask,
                      "timestamp": stamp, "timestamp_label": quote["generatedAt"],
                      "price_basis": "live bid/ask midpoint", "price_source": "Robinhood Stock Token API"},
                     int(asset.get("max_trade_age_seconds", 90)))


def get_marketbeat_quote(client: MultiSourcePriceClient, asset: dict) -> dict:
    page = PageText()
    page.feed(client.fetch("marketbeat", asset["page_url"], int(asset.get("min_poll_seconds", 60))).decode("utf-8", errors="replace"))
    text = re.sub(r"\s+", " ", " ".join(page.parts))
    # Read the quote banner, not the narrative analyst-summary price. Require its
    # displayed "As of" time so a daily close or stale narrative cannot pass as intraday.
    pattern = re.compile(
        r"\$([\d,]+(?:\.\d+)?)\s*[+-]\s*\$?[\d,]+(?:\.\d+)?\s*"
        r"\([+-]?[\d.]+%\)\s*As of\s+(?:(\d{1,2}/\d{1,2}/\d{4})\s+)?"
        r"(\d{1,2}:\d{2}\s*[AP]M)\s+Eastern",
        re.IGNORECASE,
    )
    matches = list(pattern.finditer(text))
    if not matches:
        raise RuntimeError("MarketBeat page has no intraday quote banner with an 'As of' time")
    match = matches[-1]
    price = Decimal(match.group(1).replace(",", ""))
    if price <= 0:
        raise RuntimeError("MarketBeat returned a non-positive current price")
    eastern = ZoneInfo("America/New_York")
    quote_date = match.group(2) or datetime.now(eastern).strftime("%m/%d/%Y")
    observed_at = datetime.strptime(
        f"{quote_date} {match.group(3).upper()}", "%m/%d/%Y %I:%M %p"
    ).replace(tzinfo=eastern)
    date_label = f"{match.group(2)} " if match.group(2) else ""
    return freshness({"price": price, "bid": None, "ask": None,
                      "timestamp": observed_at,
                      "timestamp_label": f"MarketBeat banner as of {date_label}{match.group(3)} Eastern",
                      "price_basis": "intraday Fair Market Value (page quote banner)",
                      "price_source": "MarketBeat stock profile"},
                     int(asset.get("max_trade_age_seconds", 120)))


def get_mexc_quote(client: MultiSourcePriceClient, asset: dict) -> dict:
    page = PageText()
    page.feed(client.fetch("mexc", asset["page_url"], int(asset.get("min_poll_seconds", 60))).decode("utf-8", errors="replace"))
    text = re.sub(r"\s+", " ", " ".join(page.parts))
    symbol = re.escape(asset["ticker"])
    matches = list(re.finditer(
        rf"As of (\d{{4}}-\d{{2}}-\d{{2}} \d{{2}}:\d{{2}}:\d{{2}}),\s*{symbol} is trading at \$\s*([\d,]+(?:\.\d+)?)([^.{{}}]{{0,220}})",
        text, re.IGNORECASE))
    if not matches:
        raise RuntimeError("MEXC page did not contain a timestamped price; refusing an undated quote")
    zone = ZoneInfo(asset.get("timestamp_timezone", "UTC"))
    quote_rows = []
    for match in matches:
        raw_time, raw_price, tail = match.groups()
        try:
            stamp = datetime.strptime(raw_time, "%Y-%m-%d %H:%M:%S").replace(tzinfo=zone)
            price = Decimal(raw_price.replace(",", ""))
        except (ValueError, InvalidOperation) as exc:
            raise RuntimeError("MEXC returned an invalid timestamp or price") from exc
        session = "after-hours" if "after-hours" in tail.lower() else (
            "pre-market" if "pre-market" in tail.lower() else "regular session")
        quote_rows.append((stamp, session, price))
    latest_stamp = max(row[0] for row in quote_rows)
    current_et = latest_stamp.astimezone(ZoneInfo("America/New_York"))
    minute = current_et.hour * 60 + current_et.minute
    if 4 * 60 <= minute < 9 * 60 + 30:
        preferred = "pre-market"
    elif 9 * 60 + 30 <= minute < 16 * 60:
        preferred = "regular session"
    else:
        preferred = "after-hours"
    available = [row for row in quote_rows if row[0] == latest_stamp]
    selected = next((row for row in available if row[1] == preferred), None)
    if selected is None:
        selected = next((row for row in available if row[1] == "regular session"), available[0])
    stamp, session, price = selected
    if price <= 0:
        raise RuntimeError("MEXC returned a non-positive price")
    return freshness({"price": price, "bid": None, "ask": None, "timestamp": stamp,
                      "timestamp_label": f"{stamp.isoformat()} ({asset.get('timestamp_timezone', 'UTC')})",
                      "price_basis": f"MEXC {session} quote", "price_source": "MEXC Stocks page"},
                     int(asset.get("max_trade_age_seconds", 3600)))


def get_market_quote(client: MultiSourcePriceClient, asset: dict) -> dict:
    provider = asset["provider"]
    if provider == "robinhood":
        return get_robinhood_quote(client, asset)
    if provider == "marketbeat":
        return get_marketbeat_quote(client, asset)
    if provider == "mexc":
        return get_mexc_quote(client, asset)
    raise ValueError(f"unsupported price provider: {provider}")


def build_trade(Web3, w3, config: dict, asset: dict, pool: dict, reference_usd: Decimal,
                max_trade_notional_usd: Decimal, slippage_bps: int):
    from tsv_xlayer_sdk import PoolKey, TradeRequest

    key_data = asset["pool_key"]
    if str(key_data["currency0"]).lower() != str(pool["quote_address"]).lower():
        raise RuntimeError("dynamic sizing requires quote currency0 and wrapped stock currency1")
    pool_key = PoolKey(key_data["currency0"], key_data["currency1"], int(key_data["fee"]),
                       int(key_data["tick_spacing"]), key_data["hooks"])
    quote_usd = Decimal(str(config.get("quote_usd", "1")))
    if quote_usd <= 0:
        raise RuntimeError("quote_usd must be positive")

    # Q is currency0 and W is currency1 in the supplied PoolKeys.
    pool_usd = pool["pool_quote_per_stock"] * quote_usd
    if pool_usd == reference_usd:
        raise RuntimeError("pool price equals reference price; no rebalance direction")
    buy_stock = pool_usd < reference_usd
    target_deviation = Decimal(str(config.get("rebalance_target_deviation_percent", 1))) / 100
    target_price = reference_usd * (1 - target_deviation if buy_stock else 1 + target_deviation)
    if target_price <= 0:
        raise RuntimeError("rebalance target price must be positive")

    # Convert the target human price into the pool's raw token1/token0 price.
    zero_for_one = buy_stock
    max_input = (max_trade_notional_usd / quote_usd * (Decimal(10) ** pool["quote_decimals"])
                 if zero_for_one else
                 max_trade_notional_usd / reference_usd * (Decimal(10) ** pool["underlying_decimals"]))
    max_amount_in = int(max_input.to_integral_value(rounding="ROUND_FLOOR"))
    if max_amount_in <= 0:
        raise RuntimeError("maximum input rounded to zero")
    target_raw_price = ((quote_usd / target_price) *
                        (Decimal(10) ** (pool["currency1_decimals"] - pool["currency0_decimals"])))
    with localcontext() as ctx:
        ctx.prec = 100
        target_sqrt = int((Q96 * target_raw_price.sqrt()).to_integral_value(rounding="ROUND_FLOOR"))
    estimated_input = estimate_exact_input_to_sqrt(
        Web3, w3, config, pool, target_sqrt, zero_for_one, int(key_data["fee"])
    )
    # A tiny rounding buffer keeps a tick-boundary estimate from requesting an
    # input amount that the PoolManager can only partially consume.
    estimated_input = max(1, estimated_input - max(2, estimated_input // 1_000_000))
    amount_in = min(estimated_input, max_amount_in)
    progress(f"{asset['pool_id']}: price-based input estimate={estimated_input}, "
             f"configured maximum={max_amount_in}, selected={amount_in}")
    if amount_in <= 0:
        raise RuntimeError("calculated input rounded to zero")
    min_out = 1
    if min_out <= 0:
        raise RuntimeError("calculated trade amount or minimum output rounded to zero")
    request = TradeRequest(pool_key, zero_for_one, amount_in, min_out,
                           int(config.get("trade_deadline_seconds", 300)))
    return (request, ("BUY_STOCK" if zero_for_one else "SELL_STOCK"), pool_usd,
            max_trade_notional_usd, target_price, target_sqrt)


def execute_trade(config: dict, asset_name: str, request, action: str, pool_usd: Decimal,
                  reference_usd: Decimal, deviation_pct: Decimal, trade_notional_usd: Decimal,
                  target_price: Decimal, target_sqrt: int, slippage_bps: int, quote_decimals: int,
                  stock_decimals: int, max_trade_notional_usd: Decimal, Web3, w3):
    from tsv_xlayer_sdk import ExecutionClient, Operation, Target, TradeRequest

    # RPC URLs are execution credentials and must be sourced from the process
    # environment. Use the selected deployment's RPC only when the caller did
    # not explicitly provide XLAYER_RPC_URL.
    if not os.environ.get("XLAYER_RPC_URL"):
        os.environ["XLAYER_RPC_URL"] = str(config["rpc_url"])
    client = ExecutionClient(root=ROOT)
    quote_usd = Decimal(str(config.get("quote_usd", "1")))
    quote_units = Decimal(10) ** quote_decimals
    stock_units = Decimal(10) ** stock_decimals
    slip_factor = Decimal(10_000 - slippage_bps) / Decimal(10_000)

    def make_operation(trade_request):
        operation_inputs = trade_request.env()
        if config.get("router"):
            operation_inputs["TSV_ROUTER"] = config["router"]
        if config.get("hook"):
            operation_inputs["TSV_HOOK"] = config["hook"]
        return Operation(Target.TRADE, f"Robinhood auto-rebalance {asset_name} {action}", operation_inputs)

    def simulation_failure(phase: str, result) -> RuntimeError:
        # Foundry commonly writes warnings to stderr and Solidity console output
        # (including useful trace context) to stdout. Keep both streams so the
        # warning cannot hide the actual revert details.
        diagnostics = (
            f"phase={phase}\n"
            f"action={action}, zero_for_one={request.zero_for_one}\n"
            f"pool_price_usd={pool_usd}, reference_price_usd={reference_usd}, "
            f"target_price_usd={target_price}\n"
            f"amount_in_raw={request.amount_in}, min_amount_out_raw={request.min_amount_out}, "
            f"target_sqrt_price_x96={target_sqrt}\n"
            f"return_code={result.returncode}\n"
            f"--- stdout ---\n{result.stdout or '[empty]'}\n"
            f"--- stderr ---\n{result.stderr or '[empty]'}"
        )
        return RuntimeError(f"{phase} failed:\n{diagnostics[-10000:]}")

    # The deployed Router supports exact-input only. Estimate the required input
    # from current sqrt price, active liquidity, initialized ticks and target price.
    progress(f"{asset_name}: simulating price-calculated input amount_in_raw={request.amount_in}")
    probe_request = TradeRequest(request.pool, request.zero_for_one, request.amount_in, 1,
                                 request.deadline_seconds)
    simulation = client.simulate(make_operation(probe_request))
    probe_output = simulation.result.stdout + "\n" + simulation.result.stderr
    if not simulation.result.succeeded:
        raise simulation_failure("price-calculated exact-input simulation", simulation.result)
    input_match = re.search(r"Actual input \(raw\):\s*(\d+)", probe_output)
    output_match = re.search(r"Actual output \(raw\):\s*(\d+)", probe_output)
    sqrt_match = re.search(r"Post-swap sqrtPriceX96:\s*(\d+)", probe_output)
    if input_match is None or output_match is None or sqrt_match is None:
        missing = [label for label, match in (("actual input", input_match),
                                               ("actual output", output_match),
                                               ("post-swap sqrtPriceX96", sqrt_match)) if match is None]
        raise RuntimeError("price-calculated simulation omitted " + ", ".join(missing) +
                           f"; simulation output tail: {probe_output[-2000:]}")
    actual_in = int(input_match.group(1))
    actual_out = int(output_match.group(1))
    if actual_in != request.amount_in:
        raise RuntimeError(f"Router consumed {actual_in} of {request.amount_in} requested input; refusing partial exact-input trade")
    min_out = int((Decimal(actual_out) * slip_factor).to_integral_value(rounding="ROUND_FLOOR"))
    if min_out <= 0:
        raise RuntimeError("calculated minimum output rounded to zero; nothing was broadcast")
    request = TradeRequest(request.pool, request.zero_for_one, request.amount_in, min_out,
                           request.deadline_seconds)
    progress(f"{asset_name}: final slippage-protected simulation, amount_in_raw={request.amount_in}, "
             f"min_amount_out_raw={request.min_amount_out}")
    simulation = client.simulate(make_operation(request))
    if not simulation.result.succeeded:
        raise simulation_failure("final trade simulation", simulation.result)
    verified = simulation.result.stdout + "\n" + simulation.result.stderr
    verified_sqrt = re.search(r"Post-swap sqrtPriceX96:\s*(\d+)", verified)
    verified_input = re.search(r"Actual input \(raw\):\s*(\d+)", verified)
    if verified_sqrt is None or verified_input is None:
        missing = [label for label, match in (("actual input", verified_input),
                                               ("post-swap sqrtPriceX96", verified_sqrt)) if match is None]
        raise RuntimeError("final slippage-protected simulation omitted " + ", ".join(missing) +
                           f"; nothing was broadcast. Simulation output tail: {verified[-2000:]}")

    actual_trade_input = int(verified_input.group(1))
    actual_trade_notional = (Decimal(actual_trade_input) / quote_units * quote_usd if request.zero_for_one
                             else Decimal(actual_trade_input) / stock_units * reference_usd)
    print(json.dumps({"asset": asset_name, "simulation": "succeeded", "action": action,
                      "deviation_percent": str(deviation_pct), "pool_price_usd": str(pool_usd),
                      "reference_price_usd": str(reference_usd),
                      "dynamic_trade_notional_usd": str(actual_trade_notional),
                      "estimated_amount_in_raw": request.amount_in,
                      "simulated_actual_amount_in_raw": actual_trade_input,
                      "simulated_min_amount_out_raw": min_out,
                      "price_limit_enabled": False,
                      "target_pool_price_usd": str(target_price),
                      "price_target_execution": "price_calculated_exact_input",
                      "simulated_post_swap_sqrt_price_x96": int(verified_sqrt.group(1)),
                      "simulation_output": simulation.result.stdout[-2000:]}, ensure_ascii=False))
    progress(f"{asset_name}: final simulation passed; submitting broadcast")
    artifact_dir = ROOT / "broadcast" / "TradeTSV.s.sol" / str(config["chain_id"])
    artifact_snapshot = snapshot_broadcast_artifacts(artifact_dir)
    result = client.broadcast(simulation, "BROADCAST")
    if not result.succeeded:
        error_detail = (result.stderr or result.stdout)[-5000:]
        try:
            tx_hash = find_new_router_transaction(artifact_dir, artifact_snapshot, config["router"])
            receipt = wait_for_transaction_receipt(w3, tx_hash, config)
            if int(receipt["status"]) != 1:
                raise BroadcastOutcomeUncertain(
                    f"forge returned exit {result.returncode}; router transaction {tx_hash} reverted "
                    f"in block {receipt['block_number']}; reconcile before retry.\n{error_detail}"
                )
            progress(f"{asset_name}: forge returned exit {result.returncode}, but router transaction "
                     f"{tx_hash} is confirmed successful in block {receipt['block_number']}")
            execution = "broadcast_cli_error_but_confirmed"
        except BroadcastOutcomeUncertain:
            raise
        except Exception as exc:
            raise BroadcastOutcomeUncertain(
                "broadcast command returned nonzero and this run could not be confirmed on chain; "
                f"do not retry until reconciled. Reconciliation detail: {exc}\nFoundry output:\n{error_detail}"
            ) from exc
    else:
        try:
            tx_hash = find_new_router_transaction(artifact_dir, artifact_snapshot, config["router"])
            receipt = wait_for_transaction_receipt(w3, tx_hash, config)
        except Exception as exc:
            raise BroadcastOutcomeUncertain(
                f"broadcast command succeeded but its router receipt could not be confirmed; "
                f"do not retry until reconciled. {exc}\nFoundry output:\n{result.stdout[-3000:]}"
            ) from exc
        if int(receipt["status"]) != 1:
            raise RuntimeError(f"trade transaction {tx_hash} reverted in block {receipt['block_number']}")
        execution = "broadcast_confirmed"
    print(json.dumps({"asset": asset_name, "execution": execution,
                      "reconciliation": execution, "transaction_hash": tx_hash,
                      "broadcast_returncode": result.returncode,
                      "broadcast_output": (result.stdout + "\n" + result.stderr)[-5000:]}, ensure_ascii=False))
    return actual_trade_notional, tx_hash, receipt, execution


def snapshot_broadcast_artifacts(artifact_dir: Path) -> dict[str, str]:
    """Fingerprint current broadcast artifacts so a stale run-latest is not reused."""
    snapshot = {}
    if artifact_dir.is_dir():
        for artifact in artifact_dir.glob("run-*.json"):
            try:
                snapshot[str(artifact)] = hashlib.sha256(artifact.read_bytes()).hexdigest()
            except OSError:
                continue
    return snapshot


def find_new_router_transaction(artifact_dir: Path, snapshot: dict[str, str], router: str) -> str:
    """Find the Router transaction in a broadcast artifact created or changed this run."""
    candidates = []
    if artifact_dir.is_dir():
        for artifact in artifact_dir.glob("run-*.json"):
            try:
                raw = artifact.read_bytes()
                if snapshot.get(str(artifact)) == hashlib.sha256(raw).hexdigest():
                    continue
                payload = json.loads(raw)
                matches = [entry for entry in payload.get("transactions", [])
                           if isinstance(entry, dict) and entry.get("hash")
                           and str(entry.get("transaction", {}).get("to", "")).lower() == router.lower()]
                if matches:
                    candidates.append((artifact.stat().st_mtime_ns, matches[-1]["hash"]))
            except (OSError, json.JSONDecodeError, TypeError):
                continue
    if not candidates:
        raise RuntimeError("no new Router transaction found in broadcast artifacts written by this run")
    candidates.sort(reverse=True)
    return candidates[0][1]


def wait_for_transaction_receipt(w3, tx_hash: str, config: dict):
    """Wait for a specific transaction hash; do not infer status from forge's exit code."""
    try:
        receipt = w3.eth.wait_for_transaction_receipt(
            tx_hash, timeout=int(config.get("receipt_timeout_seconds", 180)), poll_latency=2
        )
    except Exception as exc:
        raise RuntimeError(f"failed waiting for trade receipt {tx_hash}: {exc}") from exc
    return {"transaction_hash": tx_hash, "block_number": int(receipt["blockNumber"]),
            "status": int(receipt["status"]), "gas_used": int(receipt["gasUsed"])}


def main() -> int:
    parser = argparse.ArgumentParser(description="Robinhood quote monitor and optional TSV X Layer rebalance trader")
    parser.add_argument("--mode", choices=("prices-only", "rebalance"), required=True,
                        help="prices-only never reads chain state; rebalance simulates then broadcasts when needed")
    parser.add_argument("--environment", choices=("production", "test"),
                        default=os.getenv("ROBINHOOD_ENV", "production"),
                        help="select production_config.json (production) or test_config.json (test)")
    parser.add_argument("--config", type=Path,
                        help="explicit config path; overrides --environment selection")
    parser.add_argument("--assets", nargs="+", help="tickers from config; defaults to MSTR BTGO SECZ")
    parser.add_argument("--max-trade-notional-usd", "--trade-notional-usd", dest="max_trade_notional_usd", type=Decimal,
                        help="required in rebalance mode; maximum USD notional per swap (actual size is liquidity/deviation based)")
    parser.add_argument("--slippage-bps", type=int, default=100,
                        help="minimum-output tolerance in basis points (default: 100 = 1%%)")
    parser.add_argument("--once", action="store_true", help="run one cycle and exit")
    args = parser.parse_args()
    selected_config = args.config or (TEST_CONFIG if args.environment == "test" else DEFAULT_CONFIG)
    config = load_config(selected_config)
    if args.mode == "rebalance":
        required_deployment = ("rpc_url", "registry", "router", "hook", "pool_manager")
        missing_deployment = [name for name in required_deployment if not config.get(name)]
        if missing_deployment:
            parser.error(f"rebalance config is missing deployment addresses: {', '.join(missing_deployment)}")
    names = args.assets or list(config["assets"])
    unknown = [name for name in names if name not in config["assets"]]
    if unknown:
        parser.error(f"unknown assets: {', '.join(unknown)}")
    if args.mode == "rebalance" and (args.max_trade_notional_usd is None or args.max_trade_notional_usd <= 0):
        parser.error("--max-trade-notional-usd (or legacy --trade-notional-usd) must be explicitly set and positive in rebalance mode")
    if not 0 <= args.slippage_bps < 10_000:
        parser.error("--slippage-bps must be in [0, 10000)")

    interval_seconds = max(15, int(config.get("interval_seconds", 60)))
    price_client = MultiSourcePriceClient(config.get("max_requests_per_minute", 30))
    Web3 = w3 = None
    if args.mode == "rebalance":
        Web3 = load_web3()
        rpc_url = os.getenv("XLAYER_RPC_URL", config.get("rpc_url", "https://rpc.xlayer.tech"))
        progress(f"Connecting to X Layer RPC for chain read (chain_id={config['chain_id']})")
        w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 15}))
        if not w3.is_connected():
            parser.error(f"cannot connect to X Layer RPC: {rpc_url}")
        if w3.eth.chain_id != int(config["chain_id"]):
            parser.error(f"wrong chain id: expected {config['chain_id']}, got {w3.eth.chain_id}")
        progress("X Layer RPC connected")
        progress(f"Using configured deployment: Registry={config['registry']}, Router={config['router']}, "
                 f"Hook={config['hook']}, PoolManager={config['pool_manager']}")

    last_trade: dict[str, float] = {}
    while True:
        cycle_start = time.monotonic()
        for name in names:
            asset = config["assets"][name]
            try:
                progress(f"{name}: fetching reference quote from {asset['provider']}")
                quote = get_market_quote(price_client, asset)
                progress(f"{name}: reference quote received: ${quote['price']} "
                         f"(trade_eligible={quote['trade_eligible']})")
                output = {"time_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
                          "asset": name, "ticker": asset["ticker"],
                          "reference_ticker": asset.get("reference_ticker", asset["ticker"]),
                          "isin": asset["isin"], "price_source": quote["price_source"],
                          "price_basis": quote["price_basis"], "market_price_usd": str(quote["price"]),
                          "price_timestamp": quote["timestamp_label"],
                          "quote_age_seconds": quote["age_seconds"],
                          "trade_eligible": quote["trade_eligible"]}
                if quote.get("bid") is not None:
                    output["bid_usd"] = str(quote["bid"])
                    output["ask_usd"] = str(quote["ask"])
                if args.mode == "prices-only":
                    print(json.dumps(output, ensure_ascii=False), flush=True)
                    continue

                progress(f"{name}: reading PoolManager and Registry state")
                pool = inspect_pool(Web3, w3, config, asset)
                fair_price = quote["price"]
                pool_usd = pool["pool_quote_per_stock"] * Decimal(str(config.get("quote_usd", "1")))
                deviation_pct = (pool_usd / fair_price - 1) * 100
                progress(f"{name}: pool price=${pool_usd}, reference=${fair_price}, "
                         f"deviation={deviation_pct}%, active_liquidity={pool['active_liquidity']}")
                output.update({"pool_id": pool["pool_id"], "tick": pool["tick"],
                               "pool_active_liquidity_raw": str(pool["active_liquidity"]),
                               "pool_has_active_liquidity": pool["active_liquidity"] > 0,
                               "pool_price_usd": str(pool_usd), "deviation_percent": str(deviation_pct),
                               "action": "HOLD"})
                if not quote["trade_eligible"]:
                    output["execution"] = "skipped_stale_price"
                elif pool["active_liquidity"] == 0:
                    output["execution"] = "skipped_no_active_liquidity"
                elif abs(deviation_pct) >= Decimal(str(config.get("rebalance_deviation_percent", 5))):
                    output["action"] = "BUY_STOCK" if deviation_pct < 0 else "SELL_STOCK"
                    cooldown = int(config.get("trade_cooldown_seconds", 30))
                    remaining = cooldown - (time.monotonic() - last_trade.get(name, -1e9))
                    if remaining > 0:
                        output["execution"] = "cooldown"
                        output["cooldown_remaining_seconds"] = round(remaining)
                    else:
                        request, action, pool_usd, actual_notional, target_price, target_sqrt = build_trade(
                            Web3, w3, config, asset, pool, fair_price,
                            args.max_trade_notional_usd, args.slippage_bps
                        )
                        actual_notional, trade_tx_hash, trade_receipt, reconciliation = execute_trade(
                            config, name, request, action, pool_usd, fair_price, deviation_pct,
                            actual_notional, target_price, target_sqrt, args.slippage_bps,
                            pool["quote_decimals"], pool["underlying_decimals"],
                            args.max_trade_notional_usd, Web3, w3
                        )
                        last_trade[name] = time.monotonic()
                        output["execution"] = reconciliation
                        output["dynamic_trade_notional_usd"] = str(actual_notional)
                        output["target_pool_price_usd"] = str(target_price)
                        output["transaction_hash"] = trade_tx_hash
                        output["receipt"] = trade_receipt
                        updated_pool = inspect_pool(Web3, w3, config, asset)
                        updated_pool_usd = updated_pool["pool_quote_per_stock"] * Decimal(str(config.get("quote_usd", "1")))
                        updated_deviation = (updated_pool_usd / fair_price - 1) * 100
                        output["post_trade_pool_price_usd"] = str(updated_pool_usd)
                        output["post_trade_deviation_percent"] = str(updated_deviation)
                        output["post_trade_readback"] = "closer_to_reference" if abs(updated_deviation) < abs(deviation_pct) else "not_closer"
                print(json.dumps(output, ensure_ascii=False), flush=True)
            except BroadcastOutcomeUncertain as exc:
                print(json.dumps({"asset": name, "error": str(exc),
                                  "action_required": "stop_and_reconcile_before_retry"}, ensure_ascii=False),
                      file=sys.stderr, flush=True)
                return 2
            except (HTTPError, URLError, TimeoutError, RuntimeError, ValueError, InvalidOperation) as exc:
                error_output = {"asset": name, "error": str(exc)}
                if "output" in locals() and output.get("asset") == name:
                    error_output = {**output, **error_output}
                    if output.get("transaction_hash"):
                        error_output["post_trade_readback"] = "failed_after_confirmed_broadcast"
                print(json.dumps(error_output, ensure_ascii=False), file=sys.stderr, flush=True)
        if args.once:
            return 0
        time.sleep(max(0, interval_seconds - (time.monotonic() - cycle_start)))


if __name__ == "__main__":
    raise SystemExit(main())
