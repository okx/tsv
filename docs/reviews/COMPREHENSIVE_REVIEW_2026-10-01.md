# TSV V1 全仓库复核记录（2026-10-01）

范围：`src/v1/`、`lib/TestToken/erc8056/`、`test/`、`script/`、`foundry.toml`、README、`docs/` 与发布清单。项目未部署；本记录基于当前工作区，历史评审文件保留其当时结论。三系统流程及文档索引见[三系统总览](../SYSTEMS_OVERVIEW.md)。没有向外部应用发布本报告。

## 已修复并回归

| 事项 | 发现及处理 | 验证 |
| --- | --- | --- |
| 治理恢复可绕开根迁移双批准 | 原 Council 可单独更换 Guardian，继而批准自己的根迁移。`TSVUpgradeTimelock` 现在要求**当前 Guardian** 对精确 operation ID 批准；可撤回批准。Anchor 绑定当前 Guardian 与轮换序号，身份恢复同交易同步，旧提案失效；旧 Guardian 对其他恢复排期的批准也不会在轮换后继续有效。 | `TSVGovernanceTest` 的未批准/撤回/批准恢复；六代理迁移测试的未批准/撤回/批准与旧根升级拒绝 |
| 治理根地址不可迁移 | 六代理改为只保存固定 Anchor；候选三合约先互绑、冻结事故控制器、提名 Anchor，并预先允许六代理升级。Council 提案、Guardian 批准后原子切换；Anchor 检查六代理相互引用。 | `TSVHookFactoryTest` 真实六代理 CREATE/CREATE2、错误六地址、缺目标名单、迁移与新根升级 |
| Registry 超过 EIP-170 尺寸 | 新治理读根使非 IR 构建的 Registry 达 24,975 B，超过 24,576 B。`foundry.toml` 锁定 `via_ir = true`，Registry 运行时代码约 19,349 B。 | `forge build --skip test --sizes`，并对 via-IR 产物执行全量测试 |
| 直接结算非精确转账风险 | 对输入/输出发送方与接收方的实际余额变化均作精确检查；新增对池输出侧额外扣费与 LP 退出异常扣费的回滚回归。 | `TSVProtocolLocalTest` Swap/LP 双侧异常扣费用例 |
| 授权、SBT、部署边界缺口 | Swap Router 仅接受 participant 直接调用并保持 SBT、nonce 校验；SBT 读取故障保持回滚；Hook 初始化要求 Router/LP 已有代码；脚本分阶段部署并检查链 ID/外部代码哈希，发布后只读校验六代理绑定、实现地址及代码哈希。 | 本地测试与 `DeployGovernanceV1`/`DeployCoreV1`/`VerifyDeploymentV1` 编译 |
| 公司行动规范矛盾 | 原文允许同日混合拆股前后法律单位，却仅让运营事后换算。链上 `usedWad` 已在交易时比较额度，事后换算不能修复。V1 准入规则收紧为单位变化前暂停整个 `securityId`，至少跨到下一计量日，先确认新单位 ADTV/quota 和继续交易 Token 的映射。 | 文档对照；该控制仍依赖发行方预告及链下暂停，不是链上自动识别 |

## 尚未满足的生产门禁

1. **公司行动无预告切换：**当前合约没有 `unitEpoch` 或发行方单位变化的链上自动暂停。可能无预告在日内改变法律股数单位的资产不得准入；提前暂停的监控、权限、时效和法务证据须按资产验收。
2. **真实外部依赖：**wTSLAx、SmartWalletSbt、X Layer 官方 PoolManager 的实际地址、代码哈希、代理实现和资金行为仍需在固定区块核验。本次网络查询服务未返回可核实结果，脚本因此要求 manifest 提供目标链代码哈希，不内置未经核实的地址。
3. **升级与发布：**目标链尚未执行部署脚本；候选合约需对六代理做存储布局、跨版本调用兼容、真实多签与 Guardian/Council 流程、事故升级名单、完整交易 receipt 的验收。发布脚本不会授予业务角色、登记资产或替运营签署法务证据。
4. **测试范围：**本地 V4 PoolManager 集成、ERC-8056 与异常 ERC-20 已覆盖主要资金路径；真实发行方代理、实际 SBT、固定区块 fork、最坏 gas 尚缺。测试通过不构成零漏洞保证。

`TSVUpgradeTimelock` 普通排期允许 0 延迟是既有产品决定；Guardian 取消权无法保证抢在 0 延迟执行前生效。发行方代理升级依赖链下监控暂停、`forceExit` 的 `minOut` 由运营设置，也是既有明确边界。上线前须核对这些责任的执行人和告警链路。

## 本地证据

- `FOUNDRY_PROFILE=unit` 与 `FOUNDRY_PROFILE=local`：62 个测试通过、0 失败、0 跳过；新增股数反算性质测试执行 256 组 fuzz 输入。
- `forge fmt --check src/v1 script test`、`git diff --check`、JSON 模板语法及 Markdown 本地链接检查通过。
- 构建配置：Solidity 0.8.26、Cancun、optimizer 200、via-IR。尺寸核对需与最终提交的构建制品和部署 manifest 再执行一次。
