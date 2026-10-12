# TSV V1 运营入口与验证边界

本文件是当前源码运营入口的测试索引，不是日期固定的旧 review。实际 assertions 见所列 `.t.sol`。运营角色、数据提交与发布边界以 Registry/Ledger 源码和 [`BACKEND_INTEGRATION_GUIDE_V1.md`](./BACKEND_INTEGRATION_GUIDE_V1.md) 为准。

## 1. Registry 运营入口

| 运营对象 | 当前入口 | 可执行测试位置 |
| --- | --- | --- |
| W/U/security 准入与追加 W | `registerPermissionedCurrency` | `test/unit/v1/registry/Admission.t.sol`、`Environment.t.sol`、`FactoryChecker.t.sol` |
| Q 准入与新池禁用 | `registerQuoteToken`、`disableQuoteTokenPoolRegister`、`disableUnderlyingPoolRegister` | `test/unit/v1/registry/Admission.t.sol`、`Configuration.t.sol` |
| 证券 tier/list/delist | `setTierPolicy`、`setSecurityTier`、`relistSecurity`、`delistSecurity` | `test/unit/v1/registry/Lifecycle.t.sol`、`Configuration.t.sol` |
| 池 lifecycle 与计数 | `registerPool`、`updatePoolLifeCycle`、`batchUpdatePoolLifeCycle`、LP Manager 计数回调 | `test/unit/v1/registry/Lifecycle.t.sol`、`integration/local/deployment/LPHook.t.sol` |
| SBT identity 配置 | `setSbtConfig`、`permissionsOf`、`isSbtAllowed` | `test/unit/v1/registry/Permissions.t.sol`、`integration/local/trading/WrappedPolicy.t.sol` |
| 证券/全局 pause | `applySecurityStatus`、`setEmergencyPauseEnable` | `test/unit/v1/registry/Pauses.t.sol`、`PauseBoundaries.t.sol`、本地 Policy/LP suites |

配置方法需非零 reasonCode。请按事件 ABI 解析事件；`SecurityStatusChanged` 不发出传入的 reasonCode。

## 2. Ledger 运营入口

| 入口 | 当前作用 | 测试位置 |
| --- | --- | --- |
| `setQuota(securityId, DailyQuota[], reasonCode)` | 对任意 EST epoch day 直接写 legal-share WAD quota，不重置 usage | `test/unit/v1/trading/VolumeLedgerAccounting.t.sol` |
| `setUsedWad(securityId, DailyQuota[], reasonCode)` | 覆盖 usage，可纠正到零或高于 quota | `test/unit/v1/trading/VolumeLedgerSetUsedWad.t.sol`、`VolumeLedgerAccounting.t.sol` |
| Hook `recordSwap(...)` | 用 actual PoolManager delta 计算后校验当前额度 | `test/unit/v1/registry/Consumers.t.sol`、本地 Wrapped Swap tests |

Quota 缺省为零。当前没有 reportId、ADTV、月度数据、quota formula、配置交易日或拆并股调度。所有 W/池使用同一 securityId 的 Ledger 状态。更多可执行边界见 [`TEST_COVERAGE_V1.md`](./TEST_COVERAGE_V1.md)。

## 3. 超出本地运营测试的事项

- 真实角色部署、密钥 custody、角色撤销演练和升级恢复审批；
- 生产 SBT、issuer checker、W、U、Q、Factory、PM 地址与权限状态；
- 外部数据源怎样计算并审批额度，以及 reasonCode 与事件/工单的链下关联；
- 目标链 DEX caller markers、signer 签名、Adapter allowlist 和真实资产双向结算；
- X Layer fork 执行。`test/integration/xlayer/` 当前没有可执行测试。

不要将这些事项报告成未运行本地套件的测试失败。它们需要目标链或运营流程证据。
