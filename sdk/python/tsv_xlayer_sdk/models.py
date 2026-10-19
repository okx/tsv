"""Typed inputs shared by SDK callers and the interactive operator."""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
import re


_ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")


def _address(value: str, name: str) -> str:
    if not _ADDRESS_RE.fullmatch(value) or int(value, 16) == 0:
        raise ValueError(f"{name} must be a nonzero 20-byte address")
    return value


@dataclass(frozen=True)
class PoolKey:
    currency0: str
    currency1: str
    fee: int
    tick_spacing: int
    hook: str

    def __post_init__(self) -> None:
        _address(self.currency0, "currency0")
        _address(self.currency1, "currency1")
        _address(self.hook, "hook")
        if int(self.currency0, 16) >= int(self.currency1, 16):
            raise ValueError("currency0 must be lower than currency1 by address")
        if not 0 <= self.fee <= 0xFFFFFF:
            raise ValueError("fee must fit uint24")
        if not 1 <= self.tick_spacing <= 0x7FFF:
            raise ValueError("tick_spacing must fit positive int16")

    def env(self, prefix: str = "TSV_") -> dict[str, str]:
        return {
            f"{prefix}CURRENCY0": self.currency0,
            f"{prefix}CURRENCY1": self.currency1,
            f"{prefix}FEE": str(self.fee),
            f"{prefix}TICK_SPACING": str(self.tick_spacing),
            f"{prefix}HOOK": self.hook,
        }


@dataclass(frozen=True)
class TradeRequest:
    pool: PoolKey
    zero_for_one: bool
    amount_in: int
    min_amount_out: int
    deadline_seconds: int = 300

    def __post_init__(self) -> None:
        for name, value in (
            ("amount_in", self.amount_in),
            ("min_amount_out", self.min_amount_out),
            ("deadline_seconds", self.deadline_seconds),
        ):
            if value <= 0:
                raise ValueError(f"{name} must be greater than zero")
        if self.amount_in > (1 << 128) - 1:
            raise ValueError("amount_in must fit uint128")

    def env(self) -> dict[str, str]:
        values = self.pool.env()
        values.update(
            {
                "TSV_ZERO_FOR_ONE": str(self.zero_for_one).lower(),
                "TSV_AMOUNT_IN": str(self.amount_in),
                "TSV_MIN_AMOUNT_OUT": str(self.min_amount_out),
                "TSV_DEADLINE_SECONDS": str(self.deadline_seconds),
            }
        )
        return values


class TradeSide(Enum):
    BUY_STOCK = "buy_stock"
    SELL_STOCK = "sell_stock"


@dataclass(frozen=True)
class DexRouterTradeRequest:
    """One TSVAdapter hop: amount_in funds DexRouter; only stock sales need authorization."""

    adapter: str
    dex_router: str
    tsv_router: str
    pool: PoolKey
    stock_currency: str
    stock_underlying: str
    side: TradeSide
    amount_in: int
    min_return: int
    expected_multiplier: int
    nonce: int
    deadline_seconds: int
    participant: str | None = None
    receiver: str | None = None

    def __post_init__(self) -> None:
        _address(self.adapter, "adapter")
        _address(self.dex_router, "dex_router")
        _address(self.tsv_router, "tsv_router")
        _address(self.stock_currency, "stock_currency")
        _address(self.stock_underlying, "stock_underlying")
        if self.participant is not None:
            _address(self.participant, "participant")
        if self.receiver is not None:
            _address(self.receiver, "receiver")
        if self.stock_currency.lower() not in (self.pool.currency0.lower(), self.pool.currency1.lower()):
            raise ValueError("stock_currency must be one of the PoolKey currencies")
        if self.stock_underlying.lower() in (self.pool.currency0.lower(), self.pool.currency1.lower()):
            raise ValueError("stock_underlying must be the settlement token behind the stock W")
        if not isinstance(self.side, TradeSide):
            raise TypeError("side must be TradeSide.BUY_STOCK or TradeSide.SELL_STOCK")
        if self.amount_in <= 0 or self.amount_in > ((1 << 127) - 1):
            raise ValueError("amount_in must be in 1..int128.max")
        if self.min_return <= 0 or self.min_return >= 1 << 128:
            raise ValueError("min_return must fit a positive uint128")
        if self.expected_multiplier <= 0 or self.expected_multiplier >= 1 << 256:
            raise ValueError("expected_multiplier must fit a positive uint256")
        if self.nonce < 0 or self.nonce >= 1 << 256:
            raise ValueError("nonce must fit uint256")
        if self.deadline_seconds <= 0 or self.deadline_seconds >= 1 << 64:
            raise ValueError("deadline_seconds must fit a positive uint64")
        if (self.participant is None) != (self.receiver is None):
            raise ValueError("participant and receiver must either both be set or both default to the operator wallet")
        if self.participant is not None and self.receiver is not None and self.receiver.lower() != self.participant.lower():
            raise ValueError("single-hop TSV trades must send output to the authenticated participant")

    @property
    def zero_for_one(self) -> bool:
        stock_is_currency0 = self.stock_currency.lower() == self.pool.currency0.lower()
        if self.side is TradeSide.BUY_STOCK:
            return not stock_is_currency0
        return stock_is_currency0

    @property
    def token_in(self) -> str:
        if self.side is TradeSide.SELL_STOCK:
            return self.stock_underlying
        return self.pool.currency1 if self.stock_currency.lower() == self.pool.currency0.lower() else self.pool.currency0

    @property
    def token_out(self) -> str:
        if self.side is TradeSide.BUY_STOCK:
            return self.stock_underlying
        return self.pool.currency1 if self.stock_currency.lower() == self.pool.currency0.lower() else self.pool.currency0

    @property
    def asset_to(self) -> str:
        """DexRouter pre-funds W for sells and the Adapter for buys."""
        return self.stock_currency if self.side is TradeSide.SELL_STOCK else self.adapter

    def env(self) -> dict[str, str]:
        """Return public operation inputs; signing keys are loaded separately from the local env file."""
        values = {
            "TSV_DEX_ADAPTER": self.adapter,
            "TSV_DEX_ROUTER": self.dex_router,
            "TSV_DEX_TSV_ROUTER": self.tsv_router,
            "TSV_DEX_CURRENCY0": self.pool.currency0,
            "TSV_DEX_CURRENCY1": self.pool.currency1,
            "TSV_DEX_FEE": str(self.pool.fee),
            "TSV_DEX_TICK_SPACING": str(self.pool.tick_spacing),
            "TSV_DEX_HOOK": self.pool.hook,
            "TSV_DEX_STOCK_CURRENCY": self.stock_currency,
            "TSV_DEX_STOCK_UNDERLYING": self.stock_underlying,
            "TSV_DEX_SIDE": self.side.name,
            "TSV_DEX_AMOUNT_IN": str(self.amount_in),
            "TSV_DEX_MIN_RETURN": str(self.min_return),
            "TSV_DEX_EXPECTED_MULTIPLIER": str(self.expected_multiplier),
            "TSV_DEX_NONCE": str(self.nonce if self.side is TradeSide.SELL_STOCK else 0),
            "TSV_DEX_DEADLINE_SECONDS": str(self.deadline_seconds),
        }
        if self.participant is not None:
            values["TSV_DEX_PARTICIPANT"] = self.participant
        if self.receiver is not None:
            values["TSV_DEX_RECEIVER"] = self.receiver
        return values
