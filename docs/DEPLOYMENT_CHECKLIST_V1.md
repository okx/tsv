# TSV V1 部署与发布检查

本文从当前构造器、initializer 和绑定入口整理发布检查项；它不是已经验证的部署脚本。旧架构的部署补全工具已归档到运维分支，不作为当前合约的部署入口。`docs/DEPLOYMENT_MANIFEST_V1.example.json` 是当前五组件的发布记录模板，不是部署脚本或已填充的部署记录。仓库未提供与当前源码匹配的完整目标链部署脚本。

## 1. 锁定构建和外部依赖

- 固定 Git commit、submodule gitlink、Solidity 0.8.26、Cancun、via-IR、optimizer 200 及依赖解析结果。
- 部署前构建并记录链接库地址。Registry 需要链接 `PermissionedValidationLib`；LP Manager 及其上游位置数学逻辑依赖 `TSVLPManagerLib`、`LPPositionMath`。
- 核对目标链 PoolManager、Permissions Adapter Factory、SBT、Permit2、Position Descriptor、WETH 和 quote/stock token 地址及 codehash。
- 测试配置 `test/integration/xlayer/deployment.json` 是外部 DexRouter 的历史固定区块清单，不是 TSV 合约部署清单。

不得从旧 `docs/artifacts/*` 中带有 `dataInbox` 的 ABI/storage-layout 文件推断当前接口。当前接口以源码编译产物为准；部署前应重建 ABI/layout 并纳入审阅。

## 2. 部署构造器和代理

实现合约禁用 implementation 自身 initializer；每个 `TSVERC1967Proxy` 都须在创建时带非空、匹配 implementation ABI 的初始化 calldata。

| 实现/代理 | 构造参数或初始化 |
| --- | --- |
| `TSVRegistryV1` | Proxy initializer：`initialize(admin)`；稍后 `bindComponents(hook, lpManager, factory, sbt)` |
| `TSVVolumeLedgerV1` | Proxy initializer：`initialize(registry)` |
| `TSVSwapRouterV1` | Implementation constructor：`(poolManager, permissionsAdapterFactory)`；Proxy initializer：`initialize(poolManager, registry)` |
| `TSVLPManagerV1` | Implementation constructor：`(poolManager, permit2, unsubscribeGasLimit, tokenDescriptor, weth9, factory, deliveryGasLimit, registry)`；Proxy initializer：`initialize(registry)` |
| `TSVHookV1` | CREATE2 Hook proxy；initializer：`initialize(poolManager, registry, ledger, router, lpManager)`；proxy 地址低 14 位须与 `0x3FFF` 相符 |

Router constructor 要求 Factory 的 `POOL_MANAGER()` 与传入 PM 相同；其 implementation immutable 参数在升级时应保持一致。LP Manager 的 PM、Factory、Descriptor、WETH 和 gas limits 同样是 implementation 级固定配置。

## 3. 组件顺序和地址绑定

当前代码没有 Registry/Router/LPManager 循环地址的一站式发布脚本。部署自动化须基于最终 proxy 地址、immutable 参数和 Hook initializer calldata 做地址预计算，再按以下约束编排：

1. 部署外部 PM、Factory、SBT 等依赖以及所需链接库和 implementations。
2. 部署 Registry proxy 并初始化 admin。
3. 部署 Ledger、Router、LP Manager proxies，initializer 均指向最终 Registry；Router/LP implementation constructors 使用最终外部地址。
4. 使用 `TSVHookProxyFactoryV1.predict/deploy` 部署 permission bits 正确的 Hook proxy；其 initializer 使用最终 Registry、Ledger、Router 和 LP Manager 地址。
5. Registry Default Admin 调用一次 `bindComponents(hook, lpManager, factory, sbt)`。函数从 Factory 读取 PM，并验证 SBT 的基础 view 可调用。该调用不绑定 Router/Ledger，也不自动验证完整拓扑。
6. 发布后逐一核对每个合约的 Registry/PM/Factory/Hook/Router/LPManager getter 和 immutable。将所有地址、implementation、构造参数和 tx hash 写入新的当前格式 release record。

部署工具必须处理 CREATE2 initCodeHash 对 implementation、initializer calldata 和 salt 的依赖；不得以旧 `anchorProxyOrder` 或 DataInbox 顺序替代。

## 4. 角色配置

Default Admin 在 Registry 上管理 `grantRole`/`revokeRole`。按职责最小授予：

| Role | 消费入口 |
| --- | --- |
| `DEFAULT_ADMIN_ROLE` | 配置其他 role、tier policy、SBT identity；Router Adapter allowlist 由 Registry Default Admin 管理 |
| `SYMBOL_ADMIN_ROLE` | W/Q 准入、security/tier 操作、pool lifecycle |
| `HALT_REPORTER_ROLE` | 设置 security 的最终 pause mode |
| `VOLUME_ORACLE_ROLE` | Ledger `setQuota` 和 `setUsedWad` |
| `EMERGENCY_PAUSER_ROLE` / `EMERGENCY_RESUMER_ROLE` | 分别启用/解除 global pause |
| `POOL_CREATOR_ROLE` | LP Manager `initializePool` |
| `FORCE_EXIT_ADMIN_ROLE` | LP Manager `unwindPositionByTsv` |
| `UPGRADE_ADMIN_ROLE` | Registry 自身及其他代理的 UUPS 升级授权 |

确认组件在目标环境中实际查询 Registry role root。不要配置旧治理 Anchor、Council、DataInbox role 或已删除的 report executor。`REVOKE_EXIT_EXECUTOR_ROLE` 和 `WITHDRAW_CLAIM_ROLE` 当前没有合约消费者。

## 5. 资产和交易配置

- 将 W 的 Registry address、U、securityId、decimals 和 legal-share adapter 核对一致；Factory `verifiedPermissionsAdapterOf(W)` 必须指向 U。
- Registry 登记 Q 和 W；tier policy 在首次 security listing 前配置。每个新池必须是一侧 W、一侧 Q，Hook 为本 TSV Hook。
- 在 W 配置 issuer checker、`swappingEnabled`、Router/LP wrapper 和 Hook allowlist；在 Registry 配置 SBT tokenId 与 TSV permission flags。
- LP 付款人对 U/Q 分别授权 LP Manager **proxy**；Swap 付款人（已授权 Adapter）对输入 U/Q 另行授权 Router **proxy**。对真实 U/Q 验证直接 `transferFrom` 划转语义。
- Router allowlist 中只加入经过审核的 DEX Adapter；adapter signer/caller 认证与此链上 allowlist 是两套配置。
- 为目标 `currentESTDay()` 和 security 设置直接 legal-share WAD quota。quota 默认 0；旧 ADTV/tier 公式不存在。
- 由 Pool Creator 用 LP Manager 初始化 PoolKey，再通过显式 liquidity action 提供流动性。

## 6. 发布后检查

先通过静态调用核对：

- `tsvImplementation()`、implementation bytecode hash 和 Hook flags `0x3FFF`；
- Registry 绑定的 Hook、LP Manager、Factory、PM、SBT；Hook 的 PM/Registry/Ledger/Router/LP Manager；Router 的 PM/Factory/Registry；Ledger/LP Manager 的 Registry；
- 所有 role holder、SBT tokenId 权限、W issuer checker 和 owner 配置、Router Adapter allowlist；
- W→U 和 U→Adapter 的 canonical 关系、Q 注册状态、PoolKey、lifecycle、Tier 和 tickCount；
- 当前日 quota、usedWad 和 legal-share adapter multiplier。

再使用真实资产执行审核批准的交易检查：双向 Swap、SBT 与 issuer 权限拒绝、限额/暂停失败回滚、LP mint/increase/decrease/burn、授权强退收款、拒收/大仓位强退边界。保存可验证交易和事件证据。

## 7. 当前发布阻断信息

本地测试未证明任何目标链组件已部署、角色已配置或生产资产准入完成。仓库没有可执行 X Layer fork `.t.sol`。当前强退路径不是无条件保证：quote 拒收和单次完整退出超出 `int128` delta 都可回滚。发布负责人须处理这些已知边界并提供真实资产证据。
