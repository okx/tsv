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
    """One TSVAdapter hop formatted for DexRouter.dagSwapTo."""

    adapter: str
    tsv_router: str
    pool: PoolKey
    stock_currency: str
    settlement_currency0: str
    settlement_currency1: str
    side: TradeSide
    amount_in: int
    min_return: int
    deadline: int
    more_info: bytes
    receiver: str

    def __post_init__(self) -> None:
        _address(self.adapter, "adapter")
        _address(self.tsv_router, "tsv_router")
        _address(self.stock_currency, "stock_currency")
        _address(self.settlement_currency0, "settlement_currency0")
        _address(self.settlement_currency1, "settlement_currency1")
        _address(self.receiver, "receiver")
        if self.stock_currency.lower() not in (self.pool.currency0.lower(), self.pool.currency1.lower()):
            raise ValueError("stock_currency must be one of the PoolKey currencies")
        if self.settlement_currency0.lower() == self.settlement_currency1.lower():
            raise ValueError("pool settlement currencies must differ")
        if not isinstance(self.side, TradeSide):
            raise TypeError("side must be TradeSide.BUY_STOCK or TradeSide.SELL_STOCK")
        if self.amount_in <= 0 or self.min_return <= 0 or self.deadline <= 0:
            raise ValueError("amount_in, min_return, and deadline must be greater than zero")
        if self.amount_in >= 1 << 128:
            raise ValueError("amount_in must fit the TSVAdapter's int128-compatible range")
        if not isinstance(self.more_info, bytes) or not self.more_info:
            raise ValueError("more_info must be ABI-encoded TSVAdapter.MoreInfo (PoolKey, expectedMultiplier)")

    @property
    def zero_for_one(self) -> bool:
        stock_is_currency0 = self.stock_currency.lower() == self.pool.currency0.lower()
        if self.side is TradeSide.BUY_STOCK:
            return not stock_is_currency0
        return stock_is_currency0

    @property
    def token_in(self) -> str:
        return self.settlement_currency0 if self.zero_for_one else self.settlement_currency1

    @property
    def token_out(self) -> str:
        return self.settlement_currency1 if self.zero_for_one else self.settlement_currency0

    def dag_swap_to_arguments(self, order_id: int = 0) -> tuple[int, str, dict[str, object], list[dict[str, object]]]:
        """Return (orderId, receiver, BaseRequest, paths) for the IDexRouter ABI."""
        if order_id < 0 or order_id >= 1 << 256:
            raise ValueError("order_id must fit uint256")
        weight_100_percent = 10_000 << 160
        output_index_one = 1 << 176
        reverse = 0 if self.zero_for_one else 1 << 255
        raw_data = int(self.tsv_router, 16) | weight_100_percent | output_index_one | reverse
        base_request: dict[str, object] = {
            "fromToken": int(self.token_in, 16),
            "toToken": self.token_out,
            "fromTokenAmount": self.amount_in,
            "minReturnAmount": self.min_return,
            "deadLine": self.deadline,
        }
        path: dict[str, object] = {
            "mixAdapters": [self.adapter],
            # Sales pre-transfer underlying U directly into the wrapped stock W.
            # Purchases pre-transfer quote Q into the adapter.
            "assetTo": [self.stock_currency if self.side is TradeSide.SELL_STOCK else self.adapter],
            "rawData": [raw_data],
            "extraData": ["0x" + self.more_info.hex()],
            "fromToken": int(self.token_in, 16),
        }
        return order_id, self.receiver, base_request, [path]
