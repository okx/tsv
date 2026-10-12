# TSV V1 当前验证边界

本文列出仅凭当前本地源码和测试无法证明的事项，不是未修复合约漏洞清单，也不替代某次审计。Solidity 行为和可执行测试映射见 [`IMPLEMENTATION_STATUS_V1.md`](./IMPLEMENTATION_STATUS_V1.md) 与 [`TEST_COVERAGE_V1.md`](./TEST_COVERAGE_V1.md)。

## 尚需目标链或外部证据

| 事项 | 源码/测试能证明什么 | 仍需的证据 |
| --- | --- | --- |
| X Layer 部署集成 | Foundry 有 `xlayer` profile 和配置目录 | 当前目录没有可执行 `.t.sol`；需部署地址、真实 PM/F/SBT、固定区块 fork 及交易证据 |
| 生产 W/U/Q | Registry 对 Factory provenance、部分接口和 decimals 做链上校验；本地测试有行为 mock | 真实 issuer 权限、原始 Token 转账语义、升级/黑名单/暂停能力和 exact-transfer 证据 |
| SBT 与 issuer checker | 单元/本地测试验证接口消费和权限路径 | 生产 SBT `verify/paused`、真实 tokenId 政策、发行方 allowlist 及实际撤销行为 |
| 法律股数单位 | Hook 经 Adapter 将真实 W delta 转成 legal-share WAD | multiplier 单位、发行方批准的公式、source-of-truth 和变更审批证据 |
| 强退可靠性 | 本地集成覆盖支持的退出路径和回滚 | quote 收款不能被 LP 拒绝、最大本金/费用在 `int128` 范围内，或业务接受退出可失败的风险处置 |
| 生产部署顺序与 roles | 源码暴露 initializer、immutable、role consumer 和 Registry bind | source-compatible deploy script、目标链交叉绑定核对、最小权限签字和升级恢复演练 |
| 后端额度运行 | Ledger 接受直接日额度并在成交时校验 | `setQuota` 数据源、币种单位、EST epoch day、额度审批和 `setUsedWad` 更正审计 |

## 当前源码明确的业务依赖

- 正数股票成交需要当前日 `Quota` 足额；Ledger 没有 ADTV/tier 自动计算或未来日期报告。
- W/U 使用精确 ERC-20 结算是准入假设，不是 Registry 强制规则。
- `applySecurityStatus` 的 `reasonCode` 会校验非零，但 `SecurityStatusChanged` 事件不包含该字段；需要在链下事务记录中保留原因。
- 全仓 unwind 可能因 Token 拒收或 V4 `int128` delta 上限而回滚，合约没有受权的 partial-unwind 接口。

不要将以上集成/治理/数据证据项标成 Solidity 单元测试“失败”；它们需要相应的链下控制或目标链验证。
