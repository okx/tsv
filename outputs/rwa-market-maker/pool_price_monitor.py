#!/usr/bin/env python3
"""Continuously display pool-implied USD prices beside market reference prices."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
from decimal import Decimal
import json
import os
from pathlib import Path
import time

from market_rebalancer import (
    DEFAULT_CONFIG,
    TEST_CONFIG,
    MultiSourcePriceClient,
    get_market_quote,
    inspect_pool,
    load_config,
    load_web3,
)


def display_symbol(name: str, asset: dict) -> str:
    """Name the pool asset, while keeping its market benchmark separate."""
    if name.upper().startswith("RWT"):
        return "RWT"
    return str(asset.get("monitor_symbol", name)).upper()


def select_assets(config: dict, requested: list[str] | None) -> list[tuple[str, dict]]:
    assets = config.get("assets", {})
    if requested:
        wanted = {item.upper() for item in requested}
        selected = [
            (name, asset) for name, asset in assets.items()
            if name.upper() in wanted
            or display_symbol(name, asset) in wanted
            or str(asset.get("ticker", "")).upper() in wanted
            or str(asset.get("reference_ticker", "")).upper() in wanted
        ]
        matched = {value for name, asset in selected for value in (
            name.upper(), display_symbol(name, asset), str(asset.get("ticker", "")).upper(),
            str(asset.get("reference_ticker", "")).upper()
        )}
        missing = sorted(wanted - matched)
        if missing:
            raise ValueError(f"assets not found in selected config: {', '.join(missing)}")
        return selected

    selected = list(assets.items())
    if not selected:
        raise ValueError("selected config has no configured pools")
    return selected


def emit_record(environment: str, name: str, asset: dict, Web3, w3, price_client,
                 config: dict) -> None:
    label = display_symbol(name, asset)
    record = {
        "time_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "environment": environment,
        "asset": label,
        "pool_name": name,
        "reference_ticker": asset.get("reference_ticker", asset.get("ticker")),
    }

    try:
        pool = inspect_pool(Web3, w3, config, asset, require_tradable=False)
        quote_usd = Decimal(str(config.get("quote_usd", "1")))
        pool_usd = pool["pool_quote_per_stock"] * quote_usd
        has_active_liquidity = pool["active_liquidity"] > 0
        record.update({
            "pool_id": pool["pool_id"],
            "pool_price_usd": str(pool_usd),
            "tick": pool["tick"],
            "sqrt_price_x96": pool["sqrt_price_x96"],
            "active_liquidity": str(pool["active_liquidity"]),
            "has_active_liquidity": has_active_liquidity,
            "liquidity_status": "active" if has_active_liquidity else "zero_active",
            "registry_tradable": pool["tradable"],
        })
    except Exception as exc:
        record["pool_error"] = str(exc)
        pool_usd = None

    try:
        quote = get_market_quote(price_client, asset)
        reference_usd = quote["price"]
        record.update({
            "market_ticker": asset["ticker"],
            "market_price_usd": str(reference_usd),
            "market_price_source": quote["price_source"],
            "market_price_basis": quote["price_basis"],
            "market_price_timestamp": quote["timestamp_label"],
            "market_quote_age_seconds": quote["age_seconds"],
            "market_quote_fresh": quote["trade_eligible"],
        })
        if quote.get("bid") is not None:
            record["bid_usd"] = str(quote["bid"])
            record["ask_usd"] = str(quote["ask"])
        if pool_usd is not None and reference_usd > 0:
            record["pool_vs_market_percent"] = str((pool_usd / reference_usd - 1) * 100)
    except Exception as exc:
        record["market_price_error"] = str(exc)

    print(json.dumps(record, ensure_ascii=False), flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(
        description="Read-only continuous monitor for RWT, MSTR, and BTGO pool USD prices"
    )
    parser.add_argument("--environment", choices=("production", "test"),
                        default=os.getenv("RWA_MARKET_ENV", "production"),
                        help="choose production_config.json or test_config.json")
    parser.add_argument("--config", type=Path,
                        help="explicit config path; overrides --environment")
    parser.add_argument("--assets", nargs="+",
                        help="asset names or tickers from the config; defaults to configured RWT/MSTR/BTGO pools")
    parser.add_argument("--interval-seconds", type=int,
                        help="polling interval; never below an asset's configured endpoint interval")
    parser.add_argument("--once", action="store_true", help="print one cycle and exit")
    args = parser.parse_args()

    config_path = args.config or (TEST_CONFIG if args.environment == "test" else DEFAULT_CONFIG)
    config = load_config(config_path)
    try:
        selected = select_assets(config, args.assets)
    except ValueError as exc:
        parser.error(str(exc))

    requested_interval = args.interval_seconds or int(config.get("interval_seconds", 60))
    minimum_endpoint_interval = max(
        int(asset.get("min_poll_seconds", 15)) for _, asset in selected
    )
    interval_seconds = max(15, requested_interval, minimum_endpoint_interval)

    Web3 = load_web3()
    rpc_url = os.getenv("XLAYER_RPC_URL", config.get("rpc_url", "https://rpc.xlayer.tech"))
    w3 = Web3(Web3.HTTPProvider(rpc_url, request_kwargs={"timeout": 15}))
    if not w3.is_connected():
        parser.error(f"cannot connect to configured X Layer RPC: {rpc_url}")
    if w3.eth.chain_id != int(config["chain_id"]):
        parser.error(f"wrong chain id: expected {config['chain_id']}, got {w3.eth.chain_id}")

    price_client = MultiSourcePriceClient(config.get("max_requests_per_minute", 30))
    print(json.dumps({
        "event": "monitor_started",
        "environment": args.environment,
        "config": str(config_path),
        "chain_id": int(config["chain_id"]),
        "assets": [display_symbol(name, asset) for name, asset in selected],
        "interval_seconds": interval_seconds,
        "max_market_requests_per_minute": min(30, int(config.get("max_requests_per_minute", 30))),
        "mode": "read_only",
    }, ensure_ascii=False), flush=True)

    try:
        while True:
            cycle_start = time.monotonic()
            for name, asset in selected:
                emit_record(args.environment, name, asset, Web3, w3, price_client, config)
            if args.once:
                return 0
            time.sleep(max(0, interval_seconds - (time.monotonic() - cycle_start)))
    except KeyboardInterrupt:
        print(json.dumps({"event": "monitor_stopped"}), flush=True)
        return 0


if __name__ == "__main__":
    raise SystemExit(main())
