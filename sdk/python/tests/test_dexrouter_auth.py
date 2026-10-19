"""No network or real signing keys: exercise SDK validation and operator prompts."""
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sys
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from tsv_xlayer_sdk import DexRouterTradeRequest, ExecutionClient, Operation, PoolKey, Target, TradeSide
from tsv_xlayer_sdk.client import ExecutionResult, Simulation

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("tsv_operate", ROOT / "script/xlayer/operate.py")
operate = importlib.util.module_from_spec(spec)
spec.loader.exec_module(operate)


def address(index):
    return f"0x{index:040x}"


class DexRouterAuthTest(unittest.TestCase):
    def setUp(self):
        self.client = ExecutionClient(root=ROOT)
        self.process = patch.dict(os.environ, {"XLAYER_PRIVATE_KEY": "<mock-operator-key>"}, clear=True)
        self.process.start()
        self.addCleanup(self.process.stop)
        self.local = patch.object(ExecutionClient, "load_local_env", return_value={})
        self.local.start()
        self.addCleanup(self.local.stop)

    def operation(self, side):
        return Operation(Target.DEX_ROUTER_TRADE, "test", {"TSV_DEX_SIDE": side})

    def test_buy_needs_no_auth_signer(self):
        env = self.client._environment(self.operation("BUY_STOCK"))
        self.assertNotIn("TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY", env)
        self.assertEqual(env["TSV_DEX_SIDE"], "BUY_STOCK")

    def test_sale_requires_auth_signer(self):
        with self.assertRaisesRegex(ValueError, "stock sales require"):
            self.client._environment(self.operation("SELL_STOCK"))

    def test_sale_accepts_auth_signer_from_environment(self):
        with patch.dict(os.environ, {"TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY": "<mock-auth-key>"}):
            self.client._environment(self.operation("SELL_STOCK"))

    def test_invalid_or_missing_side_fails_before_execution(self):
        for side in ("", "BUY", "buy_stock"):
            with self.subTest(side=side), self.assertRaisesRegex(ValueError, "TSV_DEX_SIDE"):
                self.client._environment(self.operation(side))

    def test_buy_still_requires_transaction_wallet(self):
        with patch.dict(os.environ, {}, clear=True), self.assertRaisesRegex(ValueError, "XLAYER_PRIVATE_KEY"):
            self.client._environment(self.operation("BUY_STOCK"))

    def test_model_preserves_router_amount_and_deadline_but_zeros_buy_nonce(self):
        for side in TradeSide:
            request = DexRouterTradeRequest(
                adapter=address(1), dex_router=address(2), tsv_router=address(3),
                pool=PoolKey(address(4), address(5), 3000, 60, address(6)),
                stock_currency=address(5), stock_underlying=address(7), side=side,
                amount_in=123, min_return=1, expected_multiplier=10**18, nonce=42, deadline_seconds=300,
            )
            self.assertEqual(request.env()["TSV_DEX_AMOUNT_IN"], "123")
            self.assertEqual(request.env()["TSV_DEX_DEADLINE_SECONDS"], "300")
            self.assertEqual(request.env()["TSV_DEX_NONCE"], "0" if side is TradeSide.BUY_STOCK else "42")

    def test_buy_prompt_does_not_request_nonce(self):
        env = {"DEX_ROUTER": address(2), "TSV_ROUTER": address(3)}
        def pool(values, **kwargs):
            values.update({"TSV_DEX_CURRENCY0": address(4), "TSV_DEX_CURRENCY1": address(5),
                           "TSV_DEX_FEE": "3000", "TSV_DEX_TICK_SPACING": "60", "TSV_DEX_HOOK": address(6)})
        with patch.object(operate, "ask_pool_key", side_effect=pool), \
             patch.object(operate, "ask_address", side_effect=[address(1), address(5), address(7)]), \
             patch.object(operate, "ask", return_value="1"), \
             patch.object(operate, "ask_uint", side_effect=["123", "1", str(10**18), "300"]) as ask_uint:
            operate.configure_dexrouter_trade(env)
        self.assertEqual(env["TSV_DEX_NONCE"], "0")
        self.assertEqual(env["TSV_DEX_AMOUNT_IN"], "123")
        self.assertFalse(any("nonce" in call.args[0] for call in ask_uint.call_args_list))

    def test_operator_buy_reaches_simulation_without_auth_key_and_does_not_broadcast(self):
        def prepare(choice, env):
            env["TSV_DEX_SIDE"] = "BUY_STOCK"
            return Target.DEX_ROUTER_TRADE.script, "buy", True
        result = ExecutionResult(0, "", "")
        with patch.object(operate, "ask", return_value="14"), \
             patch.object(operate, "prepare_action", side_effect=prepare), \
             patch.object(ExecutionClient, "simulate", side_effect=lambda op: Simulation(op, result, "mock")) as simulate, \
             patch.object(ExecutionClient, "broadcast") as broadcast, \
             patch("builtins.input", return_value=""), contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(operate.main(), 0)
        simulate.assert_called_once()
        broadcast.assert_not_called()


if __name__ == "__main__":
    unittest.main()
