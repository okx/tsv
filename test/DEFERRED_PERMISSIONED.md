# 待迁移的历史 DIRECT / LP / DEX 测试

以下 29 个文件保留本轮开始时的源码（含已有未提交改动），仅追加 `.deferred` 扩展名。它们不参与编译、不计入当前通过数量。Wrapped Swap 已由新的 Wrapped*.t.sol 套件验收；本清单仍为历史文件，不重复计数。恢复时应迁移到新 Registry ABI、真实 W/Q fixture，并按剩余 LP/DEX 范围重新设计；不得直接去掉扩展名并沿用 DIRECT 股票成功假设。

- `helpers/v1/ProtocolFixture.sol.deferred`
- `helpers/v1/TSVAdapterFixture.sol.deferred`
- `helpers/v1/TradingLPHandler.sol.deferred`
- `integration/local/governance/GovernanceLifecycle.t.sol.deferred`
- `integration/local/governance/SixProxyMigration.t.sol.deferred`
- `integration/local/liquidity/Boundaries.t.sol.deferred`
- `integration/local/liquidity/DeltaGuards.t.sol.deferred`
- `integration/local/liquidity/ForceExit.t.sol.deferred`
- `integration/local/liquidity/HookCallbacks.t.sol.deferred`
- `integration/local/liquidity/IssuerFailures.t.sol.deferred`
- `integration/local/liquidity/Liquidity.t.sol.deferred`
- `integration/local/liquidity/PositionId.t.sol.deferred`
- `integration/local/liquidity/Settlement.t.sol.deferred`
- `integration/local/operations/OperationsFlows.t.sol.deferred`
- `integration/local/operations/PoolCreationBoundaries.t.sol.deferred`
- `integration/local/operations/SplitFactorFlows.t.sol.deferred`
- `integration/local/registry/Admission.t.sol.deferred`
- `integration/local/registry/Pauses.t.sol.deferred`
- `integration/local/trading/Accounting.t.sol.deferred`
- `integration/local/trading/Boundaries.t.sol.deferred`
- `integration/local/trading/DeltaGuards.t.sol.deferred`
- `integration/local/trading/DexAdapter.t.sol.deferred`
- `integration/local/trading/HookCallbacks.t.sol.deferred`
- `integration/local/trading/IssuerFailures.t.sol.deferred`
- `integration/local/trading/Precision.t.sol.deferred`
- `integration/local/trading/Settlement.t.sol.deferred`
- `integration/local/trading/StatefulTradingLP.t.sol.deferred`
- `integration/local/trading/Trading.t.sol.deferred`
- `integration/xlayer/DexRouterFlow.t.sol.deferred`

Registry、治理与报告测试继续执行。部署校验已使用 SixProxyFixture 恢复；Hook 消费者测试为注入 delta 的计量验证。
