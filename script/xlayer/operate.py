#!/usr/bin/env python3
"""Interactive XLayer TSV operator. Prompts per action, simulates, then asks before broadcast."""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "sdk/python"))
from tsv_xlayer_sdk import (
    DexRouterTradeRequest,
    ExecutionClient,
    Operation,
    PoolKey,
    Target,
    TradeSide,
)


ROOT = Path(__file__).resolve().parents[2]
DEPLOYMENT_FILE = ROOT / "script/xlayer/deployment.json"
LOCAL_ENV_FILE = ROOT / "script/xlayer/.env.xlayer"
ADDRESS_RE = re.compile(r"^0x[0-9a-fA-F]{40}$")
BYTES32_RE = re.compile(r"^0x[0-9a-fA-F]{64}$")


def load_public_env(path: Path) -> dict[str, str]:
    return ExecutionClient.load_public_env(path)


def ask(label: str, default: str | None = None) -> str:
    suffix = f" [{default}]" if default not in (None, "") else ""
    value = input(f"{label}{suffix}: ").strip()
    if not value and default not in (None, ""):
        return default
    if not value:
        raise ValueError(f"{label} 不能为空")
    return value


def ask_address(label: str, default: str | None = None) -> str:
    value = ask(label, default)
    if not ADDRESS_RE.fullmatch(value) or int(value, 16) == 0:
        raise ValueError(f"{label} 必须是非零 20-byte 地址")
    return value


def ask_bytes32(label: str, reason: bool = False, default: str | None = None) -> str:
    value = ask(label, default)
    if BYTES32_RE.fullmatch(value):
        result = value
    elif reason and len(value.encode("utf-8")) <= 32:
        result = "0x" + value.encode("utf-8").ljust(32, b"\0").hex()
    else:
        tip = "reason code 可输入 0x+64 位十六进制或不超过 32 字节的文字" if reason else "请使用 0x+64 位十六进制"
        raise ValueError(f"{label} 格式错误；{tip}")
    if int(result, 16) == 0:
        raise ValueError(f"{label} 不能为零")
    return result


def ask_uint(label: str, default: str | None = None, maximum: int | None = None) -> str:
    raw = ask(label, default)
    try:
        value = int(raw, 0)
    except ValueError as exc:
        raise ValueError(f"{label} 必须是整数") from exc
    if value < 0 or (maximum is not None and value > maximum):
        raise ValueError(f"{label} 超出允许范围")
    return str(value)


def ask_count(label: str, default: str, maximum: int) -> int:
    value = int(ask(label, default), 10)
    if value < 0 or value > maximum:
        raise ValueError(f"{label} 必须在 0..{maximum}")
    return value


def ask_bool(label: str) -> str:
    value = ask(f"{label} (y/n)").lower()
    if value in ("y", "yes", "true", "1"):
        return "true"
    if value in ("n", "no", "false", "0"):
        return "false"
    raise ValueError(f"{label} 请输入 y 或 n")


def ask_reason(label: str) -> str:
    return ask_bytes32(label, reason=True)


def ask_pool_key(env: dict[str, str], prefix: str = "TSV_", existing_pool_default: bool = False) -> None:
    defaults: dict[str, str | None] = {}
    if existing_pool_default:
        defaults = {
            "CURRENCY0": env.get("TSV_EXISTING_POOL_CURRENCY0"),
            "CURRENCY1": env.get("TSV_EXISTING_POOL_CURRENCY1"),
            "FEE": env.get("TSV_EXISTING_POOL_FEE"),
            "TICK_SPACING": env.get("TSV_EXISTING_POOL_TICK_SPACING"),
            "HOOK": env.get("TSV_HOOK"),
        }
    currency0 = ask_address("currency0", defaults.get("CURRENCY0"))
    currency1 = ask_address("currency1", defaults.get("CURRENCY1"))
    if int(currency0, 16) >= int(currency1, 16):
        raise ValueError("currency0 必须小于 currency1，按地址升序")
    env[prefix + "CURRENCY0"] = currency0
    env[prefix + "CURRENCY1"] = currency1
    env[prefix + "FEE"] = ask_uint("fee", defaults.get("FEE"), maximum=0xFFFFFF)
    env[prefix + "TICK_SPACING"] = ask_uint("tick spacing", defaults.get("TICK_SPACING"), maximum=32767)
    env[prefix + "HOOK"] = ask_address("Hook", defaults.get("HOOK") or env.get("TSV_HOOK"))


def configure_inspect_assets(env: dict[str, str]) -> None:
    for code, prefix in (("U", "TSV_INSPECT_U"), ("W", "TSV_INSPECT_W"), ("Q", "TSV_INSPECT_Q")):
        default_count = env.get(prefix + "_COUNT", "0")
        count = ask_count(f"{code} 地址数量", default_count, 500)
        env[prefix + "_COUNT"] = str(count)
        for index in range(count):
            default = env.get(f"{prefix}_{index}")
            env[f"{prefix}_{index}"] = ask_address(f"{code}[{index}]", default)

    prefix = "TSV_INSPECT_SECURITY"
    count = ask_count("Security ID 数量", env.get(prefix + "_COUNT", "0"), 500)
    env[prefix + "_COUNT"] = str(count)
    for index in range(count):
        env[f"{prefix}_{index}"] = ask_bytes32(
            f"Security ID[{index}]", reason=False, default=env.get(f"{prefix}_{index}")
        )


def configure_quote_list(env: dict[str, str]) -> None:
    count = ask_count("本次要登记的 Q 数量", "", 50)
    if count < 1 or count > 50:
        raise ValueError("Q 数量必须在 1..50")
    env["TSV_QUOTE_COUNT"] = str(count)
    for index in range(count):
        token = ask_address(f"Q[{index}]")
        env[f"TSV_QUOTE_TOKEN_{index}"] = token
        env[f"TSV_QUOTE_REASON_{index}"] = ask_reason(f"Q[{index}] 登记 reasonCode")


def configure_stock_list(env: dict[str, str]) -> None:
    count = ask_count("本次要登记的股票/W 数量", "1", 50)
    if count < 1 or count > 50:
        raise ValueError("股票数量必须在 1..50")
    env["TSV_STOCK_COUNT"] = str(count)
    for index in range(count):
        suffix = str(index)
        env[f"TSV_STOCK_WRAPPED_{suffix}"] = ask_address(f"W[{index}]")
        env[f"TSV_STOCK_UNDERLYING_{suffix}"] = ask_address(f"预期 U[{index}]")
        env[f"TSV_STOCK_SECURITY_ID_{suffix}"] = ask_bytes32(f"新 Security ID[{index}]")
        env[f"TSV_STOCK_LEGAL_SHARE_ADAPTER_{suffix}"] = ask_address(f"Legal-share Adapter[{index}]")
        env[f"TSV_STOCK_TIER_ID_{suffix}"] = ask_uint(f"Tier ID[{index}]", maximum=255)
        env[f"TSV_STOCK_REASON_{suffix}"] = ask_reason(f"股票/W[{index}] 登记 reasonCode")


def configure_pool_list(env: dict[str, str]) -> None:
    count = ask_count("本次要初始化的池数量", "1", 20)
    if count < 1 or count > 20:
        raise ValueError("池数量必须在 1..20")
    env["TSV_POOL_COUNT"] = str(count)
    for index in range(count):
        suffix = str(index)
        currency0 = ask_address(f"Pool[{index}] currency0")
        currency1 = ask_address(f"Pool[{index}] currency1")
        if int(currency0, 16) >= int(currency1, 16):
            raise ValueError(f"Pool[{index}] currency0 必须小于 currency1，按地址升序")
        env[f"TSV_POOL_CURRENCY0_{suffix}"] = currency0
        env[f"TSV_POOL_CURRENCY1_{suffix}"] = currency1
        env[f"TSV_POOL_FEE_{suffix}"] = ask_uint(f"Pool[{index}] fee", maximum=0xFFFFFF)
        env[f"TSV_POOL_TICK_SPACING_{suffix}"] = ask_uint(f"Pool[{index}] tick spacing", maximum=32767)
        env[f"TSV_POOL_HOOK_{suffix}"] = ask_address(f"Pool[{index}] Hook", env.get("TSV_HOOK"))
        env[f"TSV_POOL_SQRT_PRICE_X96_{suffix}"] = ask_uint(
            f"Pool[{index}] initial sqrtPriceX96", maximum=(1 << 160) - 1
        )
        if int(env[f"TSV_POOL_SQRT_PRICE_X96_{suffix}"]) == 0:
            raise ValueError(f"Pool[{index}] initial sqrtPriceX96 必须大于 0")


def configure_create_stock_adapters(env: dict[str, str]) -> None:
    count = ask_count("本次要创建的股票适配器数量", "1", 50)
    if count < 1:
        raise ValueError("至少需要创建一个股票适配器")
    env["TSV_CREATE_STOCK_COUNT"] = str(count)
    print("每项会部署 Legal-share Adapter 和 W。部署后请先让发行方把新 W 加入 U 的 allowlist，再继续菜单里的 Factory 验证。")
    print("Allowlist Checker 必须是该证券实际使用的准入策略；不要把测试用的 allow-all 地址当生产默认值。")
    for index in range(count):
        suffix = str(index)
        env[f"TSV_CREATE_STOCK_UNDERLYING_{suffix}"] = ask_address(f"U[{index}] ERC-20")
        env[f"TSV_CREATE_STOCK_OWNER_{suffix}"] = ask_address(f"W[{index}] 初始 owner")
        env[f"TSV_CREATE_STOCK_ALLOWLIST_{suffix}"] = ask_address(f"W[{index}] Allowlist Checker")


def configure_legal_adapter(env: dict[str, str]) -> None:
    env["TSV_LEGAL_ADAPTER_UNDERLYING"] = ask_address("要绑定的 ERC-8056 Underlying U")


def configure_add_liquidity(env: dict[str, str]) -> None:
    ask_pool_key(env)
    env["TSV_LIQUIDITY_AMOUNT0_MAX"] = ask_uint("currency0 最大投入（raw units）")
    env["TSV_LIQUIDITY_AMOUNT1_MAX"] = ask_uint("currency1 最大投入（raw units）")
    env["TSV_LIQUIDITY_TICK_RADIUS"] = ask_uint("当前 Tick 两侧的区间宽度", "600")
    if any(int(env[name]) == 0 for name in ("TSV_LIQUIDITY_AMOUNT0_MAX", "TSV_LIQUIDITY_AMOUNT1_MAX", "TSV_LIQUIDITY_TICK_RADIUS")):
        raise ValueError("最大投入数量和 Tick 区间宽度都必须大于 0")


def configure_dexrouter_trade(env: dict[str, str]) -> None:
    values = env.copy()
    ask_pool_key(values, prefix="TSV_DEX_", existing_pool_default=True)
    values["TSV_DEX_ADAPTER"] = ask_address(
        "无签名三字段 TSVAdapter", values.get("TSV_DEX_ADAPTER")
    )
    pool = PoolKey(
        values["TSV_DEX_CURRENCY0"],
        values["TSV_DEX_CURRENCY1"],
        int(values["TSV_DEX_FEE"]),
        int(values["TSV_DEX_TICK_SPACING"]),
        values["TSV_DEX_HOOK"],
    )
    side_raw = ask("DexRouter 方向（1=买入股票，2=卖出股票）")
    if side_raw not in ("1", "2"):
        raise ValueError("DexRouter 方向只能输入 1 或 2")
    side = TradeSide.BUY_STOCK if side_raw == "1" else TradeSide.SELL_STOCK
    default_stock = values.get("TSV_EXISTING_POOL_CURRENCY1")
    stock_currency = ask_address("股票/W 的 PoolKey currency", default_stock)
    stock_underlying = ask_address("股票/W 对应的底层 U", values.get("TSV_INSPECT_U_0"))
    amount_in = int(ask_uint("DexRouter 实际输入 amountIn（raw units，卖出时写入 moreInfo.amountIn）"))
    min_return = int(ask_uint("DexRouter 最小输出（raw units）"))
    expected_multiplier = int(ask_uint("报价时的 legal-share multiplier（WAD）"))
    deadline_seconds = int(ask_uint("DexRouter 交易有效秒数", "300", maximum=(1 << 64) - 1))
    request = DexRouterTradeRequest(
        adapter=values["TSV_DEX_ADAPTER"],
        dex_router=values["DEX_ROUTER"],
        tsv_router=values["TSV_ROUTER"],
        pool=pool,
        stock_currency=stock_currency,
        stock_underlying=stock_underlying,
        side=side,
        amount_in=amount_in,
        min_return=min_return,
        expected_multiplier=expected_multiplier,
        deadline_seconds=deadline_seconds,
    )
    env.update(request.env())


def configure_verify_stock_adapters(env: dict[str, str]) -> None:
    count = ask_count("本次要 Factory 验证的 W 数量", "1", 50)
    if count < 1:
        raise ValueError("至少需要验证一个 W")
    env["TSV_VERIFY_STOCK_COUNT"] = str(count)
    print("请确认发行方已经把每个 W 加入对应 U 的 allowlist，验证存款会从当前签名钱包转入 W。")
    for index in range(count):
        suffix = str(index)
        env[f"TSV_VERIFY_STOCK_WRAPPED_{suffix}"] = ask_address(f"W[{index}]")
        env[f"TSV_VERIFY_STOCK_UNDERLYING_{suffix}"] = ask_address(f"对应 U[{index}]")
        env[f"TSV_VERIFY_STOCK_AMOUNT_{suffix}"] = ask_uint(
            f"U[{index}] 验证存款数量（raw units）", "1"
        )
        if int(env[f"TSV_VERIFY_STOCK_AMOUNT_{suffix}"]) == 0:
            raise ValueError("验证存款数量必须大于 0")


def configure_registry_action(env: dict[str, str]) -> None:
    actions = [
        "GRANT_SYMBOL_ADMIN_ROLE", "GRANT_POOL_CREATOR_ROLE", "REVOKE_POOL_CREATOR_ROLE",
        "GRANT_VOLUME_ORACLE_ROLE", "REVOKE_VOLUME_ORACLE_ROLE", "DISABLE_QUOTE", "DISABLE_UNDERLYING",
        "REPLACE_LEGAL_ADAPTER", "SET_TIER_POLICY",
        "SET_SBT_CONFIG", "RELIST_SECURITY", "SET_SECURITY_TIER", "DELIST_SECURITY",
        "SECURITY_STATUS", "POOL_LIFECYCLE", "GLOBAL_PAUSE", "ROUTER_ADAPTER",
    ]
    print("可选 Registry/Router 操作：" + ", ".join(actions))
    action = ask("操作名").upper()
    if action not in actions:
        raise ValueError("不支持的 Registry/Router 操作")
    env["TSV_REGISTRY_ACTION"] = action

    if action in (
        "GRANT_SYMBOL_ADMIN_ROLE", "GRANT_POOL_CREATOR_ROLE", "REVOKE_POOL_CREATOR_ROLE",
        "GRANT_VOLUME_ORACLE_ROLE", "REVOKE_VOLUME_ORACLE_ROLE",
    ):
        env["TSV_ROLE_ACCOUNT"] = ask_address("授予目标 Registry Role 的地址")
    elif action == "DISABLE_QUOTE":
        env["TSV_DISABLE_QUOTE_TOKEN"] = ask_address("要禁用新池准入的 Q")
        env["TSV_DISABLE_QUOTE_REASON_CODE"] = ask_reason("禁用 Q reasonCode")
    elif action == "DISABLE_UNDERLYING":
        env["TSV_DISABLE_UNDERLYING_TOKEN"] = ask_address("要禁用新池准入的 U")
        env["TSV_DISABLE_UNDERLYING_REASON_CODE"] = ask_reason("禁用 U reasonCode")
    elif action == "REPLACE_LEGAL_ADAPTER":
        env["TSV_REPLACE_ADAPTER_UNDERLYING"] = ask_address("U")
        env["TSV_REPLACE_LEGAL_ADAPTER"] = ask_address("新 Legal-share Adapter")
        env["TSV_REPLACE_ADAPTER_REASON_CODE"] = ask_reason("更换 Adapter reasonCode")
    elif action == "SET_TIER_POLICY":
        env["TSV_TIER_ID"] = ask_uint("Tier ID", maximum=255)
        env["TSV_TIER_MAX_LISTED"] = ask_uint("最大上市证券数", maximum=(1 << 32) - 1)
        env["TSV_TIER_POLICY_REASON_CODE"] = ask_reason("Tier policy reasonCode")
    elif action == "SET_SBT_CONFIG":
        env["TSV_SBT_TOKEN_ID"] = ask_uint("SBT token ID")
        env["TSV_SBT_PERMISSIONS"] = ask_uint("权限位（0=NONE, 1=SWAP, 2=LP, 3=SWAP|LP）", maximum=3)
        env["TSV_SBT_CONFIG_REASON_CODE"] = ask_reason("SBT config reasonCode")
    elif action in ("RELIST_SECURITY", "SET_SECURITY_TIER", "DELIST_SECURITY", "SECURITY_STATUS"):
        env["TSV_SECURITY_ID"] = ask_bytes32("Security ID")
        if action == "RELIST_SECURITY":
            env["TSV_RELIST_SECURITY_REASON_CODE"] = ask_reason("Relist reasonCode")
        elif action == "SET_SECURITY_TIER":
            env["TSV_SECURITY_TIER_ID"] = ask_uint("目标 Tier ID", maximum=255)
            env["TSV_SECURITY_TIER_REASON_CODE"] = ask_reason("Security tier reasonCode")
        elif action == "DELIST_SECURITY":
            env["TSV_DELIST_SECURITY_REASON_CODE"] = ask_reason("Delist reasonCode")
        else:
            env["TSV_SECURITY_PAUSE_MODE"] = ask_uint("暂停范围（0=TRADE, 1=LP, 2=ALL）", maximum=2)
            env["TSV_SECURITY_PAUSE_ENABLE"] = ask_bool("启用暂停")
            env["TSV_SECURITY_STATUS_REASON_CODE"] = ask_reason("Security status reasonCode")
    elif action == "POOL_LIFECYCLE":
        env["TSV_POOL_ID"] = ask_bytes32("Pool ID")
        env["TSV_POOL_LIFECYCLE"] = ask_uint("状态（0=DELIST, 1=LIST, 2=PAUSE）", maximum=2)
        env["TSV_POOL_LIFECYCLE_REASON_CODE"] = ask_reason("Pool lifecycle reasonCode")
    elif action == "GLOBAL_PAUSE":
        env["TSV_GLOBAL_PAUSE_ENABLED"] = ask_bool("启用全局暂停")
        env["TSV_GLOBAL_PAUSE_REASON_CODE"] = ask_reason("Global pause reasonCode")
    elif action == "ROUTER_ADAPTER":
        env["TSV_ROUTER_ADAPTER"] = ask_address("Router Adapter", env.get("TSV_DEX_ADAPTER"))
        env["TSV_ROUTER_ADAPTER_ALLOWED"] = ask_bool("授权 Adapter")


def configure_ledger_action(env: dict[str, str]) -> None:
    action = ask("Ledger 操作（SET_QUOTA / SET_USED_WAD）").upper()
    if action not in ("SET_QUOTA", "SET_USED_WAD"):
        raise ValueError("不支持的 Ledger 操作")
    env["TSV_LEDGER_ACTION"] = action
    env["TSV_LEDGER_SECURITY_ID"] = ask_bytes32("Security ID")
    if action == "SET_QUOTA":
        env["TSV_QUOTA_AMOUNT_WAD"] = ask_uint("每日额度（legal-share WAD）")
        env["TSV_SET_QUOTA_REASON_CODE"] = ask_reason("setQuota reasonCode")
    else:
        count = ask_count("要修正的 EST 日数量", "1", 100)
        if count < 1 or count > 100:
            raise ValueError("EST 日数量必须在 1..100")
        env["TSV_USED_WAD_COUNT"] = str(count)
        for index in range(count):
            suffix = str(index)
            env[f"TSV_USED_WAD_EST_DAY_{suffix}"] = ask_uint(f"EST epoch day[{index}]")
            env[f"TSV_USED_WAD_AMOUNT_{suffix}"] = ask_uint(f"usedWad[{index}]（legal-share WAD）")
        env["TSV_SET_USED_WAD_REASON_CODE"] = ask_reason("setUsedWad reasonCode")


def prepare_action(choice: str, env: dict[str, str]) -> tuple[str, str, bool]:
    if choice == "1":
        configure_inspect_assets(env)
        return "InspectAssets.s.sol:InspectAssets", "TSV_INSPECT_ASSETS", False
    if choice == "2":
        ask_pool_key(env, existing_pool_default=True)
        return "InspectTSV.s.sol:InspectTSV", "TSV_INSPECT_POOL", False
    if choice == "3":
        configure_quote_list(env)
        return "RegisterQuoteTokens.s.sol:RegisterQuoteTokens", "TSV_REGISTER_QUOTES", True
    if choice == "4":
        configure_create_stock_adapters(env)
        return "CreateStockAdapters.s.sol:CreateStockAdapters", "TSV_CREATE_STOCK_ADAPTERS", True
    if choice == "5":
        configure_verify_stock_adapters(env)
        return "VerifyStockAdapters.s.sol:VerifyStockAdapters", "TSV_VERIFY_STOCK_ADAPTERS", True
    if choice == "6":
        configure_stock_list(env)
        return "RegisterStocks.s.sol:RegisterStocks", "TSV_REGISTER_STOCKS", True
    if choice == "7":
        configure_pool_list(env)
        return "InitializeTSVPools.s.sol:InitializeTSVPools", "TSV_INITIALIZE_POOLS", True
    if choice == "8":
        ask_pool_key(env)
        direction = ask("交易方向（0=currency0→currency1, 1=currency1→currency0）")
        if direction not in ("0", "1"):
            raise ValueError("交易方向只能输入 0 或 1")
        env["TSV_ZERO_FOR_ONE"] = "true" if direction == "0" else "false"
        env["TSV_AMOUNT_IN"] = ask_uint("输入数量（raw units）")
        env["TSV_MIN_AMOUNT_OUT"] = ask_uint("最小输出（raw units）")
        env["TSV_DEADLINE_SECONDS"] = ask_uint("交易有效秒数", "300")
        if int(env["TSV_AMOUNT_IN"]) == 0 or int(env["TSV_MIN_AMOUNT_OUT"]) == 0 or int(env["TSV_DEADLINE_SECONDS"]) == 0:
            raise ValueError("交易数量、最小输出和有效秒数都必须大于 0")
        return "TradeTSV.s.sol:TradeTSV", "TSV_TRADE", True
    if choice == "9":
        configure_registry_action(env)
        return "RegistryOperations.s.sol:RegistryOperations", "TSV_REGISTRY_OPERATION", True
    if choice == "10":
        configure_ledger_action(env)
        return "VolumeLedgerOperations.s.sol:VolumeLedgerOperations", "TSV_LEDGER_OPERATION", True
    if choice == "11":
        configure_legal_adapter(env)
        return "DeployLegalShareAdapter.s.sol:DeployLegalShareAdapter", "TSV_DEPLOY_LEGAL_ADAPTER", True
    if choice == "12":
        return "IssueOperatorSbt.s.sol:IssueOperatorSbt", "TSV_ISSUE_OPERATOR_SBT", True
    if choice == "13":
        configure_add_liquidity(env)
        return "AddLiquidityTSV.s.sol:AddLiquidityTSV", "TSV_ADD_LIQUIDITY", True
    if choice == "14":
        configure_dexrouter_trade(env)
        return "TradeDexRouterTSV.s.sol:TradeDexRouterTSV", "TSV_DEX_ROUTER_TRADE", True
    raise ValueError("无效选项")


def print_result(stdout: str, stderr: str) -> None:
    if stdout:
        print(stdout, end="" if stdout.endswith("\n") else "\n")
    if stderr:
        print(stderr, end="" if stderr.endswith("\n") else "\n", file=sys.stderr)


def main() -> int:
    if not DEPLOYMENT_FILE.is_file():
        print(f"找不到部署配置：{DEPLOYMENT_FILE}", file=sys.stderr)
        return 2
    client = ExecutionClient(root=ROOT, deployment_file=DEPLOYMENT_FILE, local_env_file=LOCAL_ENV_FILE)
    env = client.load_public_env(DEPLOYMENT_FILE)
    env.update(client.load_local_env(LOCAL_ENV_FILE))
    env.update(os.environ)
    baseline = env.copy()

    print("XLayer TSV 交互操作")
    print("1. 检查 U/W/Q 和 Security 列表")
    print("2. 检查一个 PoolKey")
    print("3. 登记 QuoteToken 列表")
    print("4. 为股票 U 创建 Legal-share Adapter 和 W")
    print("5. 发行方 allowlist 后，Factory 验证 W")
    print("6. 登记已有 W/U/Security ID 列表")
    print("7. 初始化 W/Q 池")
    print("8. 执行一次 swap")
    print("9. Registry/Router 管理操作（含授予 SYMBOL_ADMIN_ROLE）")
    print("10. Volume Ledger 管理操作")
    print("11. 为已有 U 部署 Legal-share Adapter")
    print("12. 给当前操作钱包发行已配置的 TSV SBT")
    print("13. 为已初始化的 W/Q 池添加流动性")
    print("14. 通过 DexRouter + TSVAdapter 买入或卖出股票")
    print("0. 退出")

    try:
        choice = ask("选择操作")
    except (KeyboardInterrupt, EOFError):
        print("已取消；未提交交易。")
        return 130
    if choice == "0":
        return 0
    if choice not in {str(value) for value in range(1, 15)}:
        print("参数错误：无效选项", file=sys.stderr)
        return 2
    writes = choice not in ("1", "2")
    if writes and not env.get("XLAYER_PRIVATE_KEY", "").strip():
        print(f"写操作需要私钥；请在 {LOCAL_ENV_FILE} 填写 XLAYER_PRIVATE_KEY。未执行任何交易。", file=sys.stderr)
        return 2
    try:
        target_script, label, _ = prepare_action(choice, env)
        target = next(item for item in Target if item.script == target_script)
        inputs = {
            name: value
            for name, value in env.items()
            if name.startswith("TSV_") and value != baseline.get(name)
        }
        operation = Operation(target, label, inputs)
        print(f"\n开始模拟：{label}")
        simulation = client.simulate(operation)
        print_result(simulation.result.stdout, simulation.result.stderr)
        if not simulation.result.succeeded:
            print("模拟失败；未提交交易。", file=sys.stderr)
            return simulation.result.returncode
        if not writes:
            return 0
        confirm = input("模拟成功。若要广播本次操作，请准确输入 BROADCAST：").strip()
        if confirm != "BROADCAST":
            print("未广播；模拟结束。")
            return 0
        print("正在广播已模拟的操作……")
        result = client.broadcast(simulation, confirm)
        print_result(result.stdout, result.stderr)
        return result.returncode
    except (ValueError, OSError, KeyboardInterrupt, EOFError) as exc:
        if isinstance(exc, ValueError):
            print(f"参数错误：{exc}", file=sys.stderr)
            return 2
        if isinstance(exc, OSError):
            print(f"执行失败：{exc}", file=sys.stderr)
            return 2
        print("已取消；未提交交易。")
        return 130


if __name__ == "__main__":
    raise SystemExit(main())
