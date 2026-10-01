# TSV 合约架构独立技术可行性评审

日期：2026-09-29  
评审对象：[CONTRACT_ARCHITECTURE.md](../CONTRACT_ARCHITECTURE.md) v0.3  
评审方式：独立评审身份只读核对本仓库三个外部协议源码；未运行编译、测试或链上部署验证。本文记录评审发现，不修改原架构决策。

阅读定位：下文结论针对 **v0.3 历史架构稿**，不是当前文档的编码就绪判定。当前交易、运营和治理流程见[三系统总览](../SYSTEMS_OVERVIEW.md)；针对这些发现以及后续问答形成的 V1 具体 ABI、算法和状态规则，见[编码规格](../CODING_SPEC_V1.md)；实际发行方代理和法律权益依据仍需生产核验。

本评审中 `0x3AE0` 是当时的 Hook 地址设计；后续已改为预留全部 14 位的 `0x3FFF`。当前位型与零 delta 行为以编码规格为准。

## 结论

TSV Hook、Router、LP Manager 组合在 Uniswap V4 Core 上的总体方向**有技术可行性**；SBT 与发行方 Token 可以通过薄接口接入。但现行架构稿不能直接作为完整实现规格。零流动性 LP 操作与 V4 源码冲突；直接纳入 Backed AutoFee 原币会破坏固定余额与股数计量假设。另有 AA 钱包领证、编译版本、零输出成交和含费计量口径需要写成明确的准入或实现规则。

| ID | 优先级 | 确定性 | 结论与最小修订 |
| --- | --- | --- | --- |
| F-01 | 阻断 | 源码确定；是否触发取决于准入资产 | V1 排除 Backed AutoFee 原币作为 V4 Currency。若使用 Wrapped Token，先固定其单位与证券股数的映射。 |
| F-02 | 阻断 | 源码确定 | 修正零流动性仓位状态机；最后一次减仓同笔结清费用，不能再以零 delta collect。 |
| F-03 | 高 | AA 钱包实现决定 | AA 钱包领 SBT 必须支持 ERC-1155 单件接收回调；ERC-1271 单独不够。 |
| F-04 | 高 | 当前编译配置确定 | TSV 与三份外部实现以 ABI/薄接口连接，分别按其编译器与 OZ 版本构建；不要直接并入一个 Solidity 编译单元。 |
| F-05 | 中 | 源码确定 | 池费率排除 100%，并拒绝实际输出为零的 Swap。 |
| F-06 | 中 | 源码确定；口径待业务确认 | 明确股票输入侧成交量是否含 LP/协议费；现有 `BalanceDelta` 算法计入含费毛支出。 |
| F-07 | 中 | 具体 Token 状态决定 | 准入和运行监测须覆盖 Backed 原币及 Wrapped Token 的制裁名单、暂停状态和相关地址。 |
| F-08 | 低 | 取决于 Hook 实现方式 | Hook 权限位按最终代理地址验证，不在实现构造函数里用实现地址替代代理地址。 |

## 详细发现

### F-01：Backed AutoFee 原币不能直接套用固定 ERC-20 股数模型

架构稿 §3.1、§5.1 把 Token `decimals` 和 V4 `BalanceDelta` 转成固定 `sharesWad`。[BackedAutoFeeTokenImplementation.sol](../../lib/TestToken/backed-token-contract/contracts/BackedAutoFeeTokenImplementation.sol) 第 254–282 行的 `balanceOf` 根据动态 multiplier 计算；第 543–553 行的普通 `transfer(amount)` 先把金额向下取整为内部 shares，随后第 590 行起转移 shares。若 multiplier 为 `2e18` 且转账金额为 1 最小单位，换算出的 shares 可为 0：ERC-20 转账调用成功，实际余额不变。TSV 的精确到账校验会回滚；同时 PoolManager 中已经持有的 AutoFee 余额也可能随 multiplier 改变。V4 的 `sync/settle` 按当前余额差结算，见 [PoolManager.sol](../../lib/v4-core/src/PoolManager.sol) 第 277–314、347–363 行。

**修订：**V1 Token 准入明确拒绝 rebasing/自动手续费原币直接入池。若业务要使用该发行方资产，优先评审 [WrappedBackedTokenImplementation.sol](../../lib/TestToken/backed-token-contract/contracts/WrappedBackedTokenImplementation.sol) 作为池的 Currency；其 ERC-20 余额单位与底层 AutoFee shares/法定证券股数的关系必须单独定义和验证，不能只凭 `decimals` 推断。

### F-02：V4 不允许对零流动性仓位做零增量 collect

架构稿 §7 的 `decreaseLiquidity`、`collectFees`、`closePosition` 和 `forceExit` 允许仓位流动性归零后继续通过 `liquidityDelta == 0` 领取费用。[Position.sol](../../lib/v4-core/src/libraries/Position.sol) 第 76–87 行在 `liquidityDelta == 0 && liquidity == 0` 时明确抛出 `CannotUpdateEmptyPosition`。[PoolManager.sol](../../lib/v4-core/src/PoolManager.sol) 第 157–178 行的 `modifyLiquidity` 已将本次费用加进 `callerDelta` 并返回 `feesAccrued`。

**复现场景：**用户全额 `decreaseLiquidity`，TSV 保留零流动性 Receipt；随后 `collectFees` 或 `closePosition` 再调用零 delta `modifyLiquidity`，交易必定回滚。

**修订：**最后一次减仓在同一 unlock 中结清本金与费用，并决定是否立即关闭 Receipt；若产品要求零流动性 Receipt 暂存，后续 `closePosition/forceExit` 只能清理 TSV 账本和 Receipt，不得再调用 V4 零 delta。`collectFees` 仅对正流动性仓位开放。强退遇零流动性仓位需走对应的无 V4 修改分支。

### F-03：ERC-1271 AA 钱包未必能领取 ERC-1155 SBT

架构稿 §1、§4 接受 ERC-1271 AA 钱包。[SmartWalletSbt.sol](../../lib/soul-bound-token-1155/src/SmartWalletSbt.sol) 第 83–95、115–127 行的 `claim/issue` 都调用 `_mint`。依赖的 [ERC1155Upgradeable.sol](../../dependencies/@openzeppelin-contracts-upgradeable-5.5.0/token/ERC1155/ERC1155Upgradeable.sol) 第 308–313 行进入接收检查；[ERC1155Utils.sol](../../dependencies/@openzeppelin-contracts-5.5.0/token/ERC1155/utils/ERC1155Utils.sol) 第 25–49 行要求目标合约的 `onERC1155Received` 返回正确 selector。否则铸造回滚，即使该钱包支持 ERC-1271 签名也没有 SBT 可供 `verify()` 读取。

**修订：**AA 钱包准入时核对 ERC-1155 单件接收能力；对不支持的账户明确不可使用当前 SBT 协议，或另行设计发行方支持的资格证明方式。不要把 ERC-1271 与 ERC-1155 接收能力视为同一条件。

### F-04：三个外部协议不能直接在根项目的一个编译单元中组合

根 [foundry.toml](../../foundry.toml) 第 6–8 行固定 solc `0.8.26` 且关闭自动识别。[PoolManager.sol](../../lib/v4-core/src/PoolManager.sol) 第 2 行精确要求 `0.8.26`；[SmartWalletSbt.sol](../../lib/soul-bound-token-1155/src/SmartWalletSbt.sol) 第 2 行要求 `^0.8.29`；[BackedTokenImplementation.sol](../../lib/TestToken/backed-token-contract/contracts/BackedTokenImplementation.sol) 第 37 行精确要求 `0.8.9`。Backed 合约族还依赖 OZ 4.x，而根项目映射 OZ 5.5.0。

**修订：**TSV 核心仅导入本项目编译版本兼容的 V4 类型和自行定义的 SBT/Backed 薄接口；外部 SBT 与 Backed 实现各按自己的构建环境编译和部署。集成时核对实际代理地址、ABI、实现版本和运行代码哈希。根项目的 `integration` profile 使用 0.8.29 时，也不能直接导入精确 0.8.26 的 V4 实现源码。

### F-05：V4 允许 100% LP fee 的 exact-in 零输出交易

架构稿 §5 允许 `actualOut >= minOut`，但没有规定 `minOut > 0` 或 `actualOut > 0`。[LPFeeLibrary.sol](../../lib/v4-core/src/libraries/LPFeeLibrary.sol) 第 24–55 行允许最大费率 1,000,000 pips（100%）；[Pool.sol](../../lib/v4-core/src/libraries/Pool.sol) 第 310–316 行仅对 exact-out 禁止这一费率；[SwapMath.sol](../../lib/v4-core/src/libraries/SwapMath.sol) 第 63–86 行的 exact-in 可将全部输入作为费用而输出为 0。若股票在输入侧，`afterSwap` 仍可能把输入股数计入额度。

**修订：**池费率白名单须排除 100%（动态费率如开放也须限制实际值）；Router 对 exact-in/out 都要求有效实际输入、输出非零，并使 `minOut`、价格边界和金额精度约束一致。

### F-06：V4 `BalanceDelta` 的股票输入侧包含手续费

架构稿 §5.1 以 `abs(stockDeltaRaw)` 作为股数。[Pool.sol](../../lib/v4-core/src/libraries/Pool.sol) 第 371–395 行对输入侧累加 `step.amountIn + step.feeAmount`；第 451–460 行将其映射为最终 delta。[PoolManager.sol](../../lib/v4-core/src/PoolManager.sol) 第 218–224 行把这个 delta 交给 `afterSwap`。因此股票为输入币时计入用户**含费总支出**，股票为输出币时计入净输出。两侧都是股票 Token 时，两边计量含义也不同。

**修订：**若业务接受含费毛支出口径，直接在 PRD 与额度公式中写明。若要求净兑换股数，需要另设计可验证的手续费分解；仅靠 `afterSwap` 的 `BalanceDelta` 不能得到净输入。此项是源码确定的差异，法律/业务口径仍需另行确认。

### F-07：Backed 制裁名单和暂停会影响每一条资金流

[BackedTokenImplementation.sol](../../lib/TestToken/backed-token-contract/contracts/BackedTokenImplementation.sol) 第 288–318 行在转账时检查 from/to 制裁名单，在 `transferFrom` 消耗 allowance 时还检查 spender。[WrappedBackedTokenImplementation.sol](../../lib/TestToken/backed-token-contract/contracts/WrappedBackedTokenImplementation.sol) 第 177–205 行从底层 Token 实时读取制裁名单并检查转账双方及 spender。TSV 的入金、Swap 出金、LP 退出涉及用户、Router、LP Manager、PoolManager 等不同地址；任一相关地址被限制或 Token 暂停，路径都可能失败。

**修订：**Token 准入记录实际 `sanctionsList` 指针、暂停状态和代理实现；在真实资金路径上核对 PoolManager、Router、LP Manager、预期用户及 spender 的可转账性。持续监测发行方管理员改动。架构稿方案 A 对强退拒转时整体回滚的处理与这些源码一致，但不能保证发行方恢复转账。

### F-08：Hook 权限校验须使用代理地址

[Hooks.sol](../../lib/v4-core/src/libraries/Hooks.sol) 第 78–101 行的 `validateHookPermissions` 检查传入 Hook 地址的低位。若 TSVHook 实现构造函数使用 `address(this)` 调此函数，看到的是**实现地址**，不是通过 CREATE2 挖出的代理地址；代理低位正确也不能让错误的构造期检查通过。

**修订：**实现合约构造期只禁用 initializer；在代理初始化或部署核验时检查最终代理地址、预期 `0x3AE0` 位型和回调权限。此问题只在目标实现加入上述构造期验证时触发。

## 源码核对后成立的设计点

- [Hooks.sol](../../lib/v4-core/src/libraries/Hooks.sol) 第 28–46 行的权限位与架构稿拟议 `0x3AE0` 相符；最终仍须以代理地址和实际实现回调清单核验。
- [SmartWalletSbt.sol](../../lib/soul-bound-token-1155/src/SmartWalletSbt.sol) 第 167–172 行的 `verify()` 只检查余额；架构稿另查 `paused()` 的做法正确。
- [PoolManager.sol](../../lib/v4-core/src/PoolManager.sol) 第 277–314、347–363 行支持在同一 unlock 中按 `sync → transfer → settle` 与 `take` 完成结算；发行方 Token 转账拒绝时，整笔 EVM 交易回滚的方案 A 符合调用链语义。

## 最小修订顺序

1. 先确定 V1 实际入池 Token 类型，以及 Wrapped 单位到法定证券股数的换算；把 AutoFee 原币排除或另行设计。
2. 修订 LP 全额减仓、collect、close、forceExit 的状态机和费用领取路径。
3. 补上 AA 钱包的 ERC-1155 接收条件，并明确三个协议的编译/接口边界。
4. 在费率白名单和 Router 入口拒绝零输出成交。
5. 就含费股数口径取得业务结论，并把 Backed 制裁/暂停检查写进 Token 准入条件。

## 处置记录（架构文档 v0.5）

本节记录评审后的文档修订；上面的独立评审发现及其评审时版本保持原样。修订仅改变架构规格，未修改合约代码，未执行编译、测试或链上验证。

| 发现 | 文档修订位置 | 当前状态 |
| --- | --- | --- |
| F-01 | §3.1–3.2、§5.1、§12、§14 | 用户已选择固定余额原币与经验证的 Wrapped Token 条件准入；AutoFee 原币不得直接入池，Wrapped 的每单位法定股数稳定性及证据仍须按实际实例审查 |
| F-02 | §7、§7.1–7.2、§10、§13.1 | 已规定 OPEN 仓位严格正流动性；部分减仓不归零，全额 close/forceExit 同次 `modifyLiquidity` 结清本金和费用并销毁 Receipt |
| F-03 | §1、§4.1、§10、§14 | 已加入 AA 钱包的 ERC-1155 单件接收条件，并与 ERC-1271 签名验证分开 |
| F-04 | §1、§13.3、§14 | 已规定 TSV 与三个外部协议分别构建，仅通过版本兼容的 V4 类型及本地 SBT/Backed 薄接口接入 |
| F-05 | §3.1、§5、§10、§13、§14 | 已排除 100%/动态池费率，要求 `minOut/maxIn` 为正且每跳实际输入、输出均大于零 |
| F-06 | §0、§5.1、§10、§12、§13 | 用户已选择 V1 股票输入含费毛支出、输出净到账分别计量；是否符合法律成交量口径仍待书面确认 |
| F-07 | §3.2、§10、§12、§14 | 已加入实际发行方 Token 的 from/to/spender、暂停、包装及代理变更准入和监测；方案 A 的拒转风险仍在 |
| F-08 | §9、§10、§14 | 已规定按最终 Hook 代理地址验证权限位，避免实现构造函数误用实现地址 |

后续问答另确认：同一适用月份内 ADTV 不变时不重复上链，日配额只在需要覆盖硬上限时提交；当前实现使用适用期间、签名有效期和自动 UTC 日切，不再依赖 SIP 日历窗口。新期间仍须提交新报告，更正须递增版本。用户同时确认 V1 资产范围为固定余额原币和经单位映射审查的 Wrapped Token；动态权益必须由 Adapter 按可验证快照计算，否则该实例不得准入。

2026-09-30 的进一步设计将上一句“固定比率不能覆盖动态权益”的限制改为**有条件的动态 Adapter 方案**，现行规则及 wTSLAx 实例边界统一见[代币准入标准](../TOKEN_ADMISSION_STANDARD_V1.md)。对本节审查的 TSLAx AutoFee 路径，V4 PoolManager 只持有 raw 余额稳定的发行方 Wrapped；Hook 在成交时读取发行方确认、链上可复算的法定股数函数。此扩展不推翻 F-01 对 AutoFee 原币直接入池的阻断结论。后续准入标准另允许 raw 余额稳定的 UI Multiplier 原币经审查直接入池并动态计股；实际发行方权益公式、舍入单位和 raw 精确转账未确认前，Wrapped 实例仍不能生产准入。

随后的架构文档 v0.7/v0.8 曾讨论用户在同一交易中使用 TSLAx 并由 TSV 调用 wTSLAx 包装/赎回；该路径已被后续决策删除，只作为历史讨论保留。当前 Router/LP Manager 只直接收付池内 wTSLAx，V4 PoolManager 也只持有 wTSLAx。

后续用户进一步明确：**wTSLAx 是唯一的 TSV Swap/LP 结算资产**。本评审上文保留历史决策，不再把 TSLAx 同笔包装/赎回列为可选能力；目标准入及计股规则以[新版代币准入标准](../TOKEN_ADMISSION_STANDARD_V1.md)为准。

最新建池规则进一步禁止**任意股票 Currency / 股票 Currency 币对**；上文关于两侧股票各自计量的推导仅保留为历史评审背景。当前 Registry 在登记待初始化池时拒绝两侧 `securityId` 均非零，无需为不存在的双股票池设计额外运行期处理。

2026-09-30 的[编码规格 v1.3](../CODING_SPEC_V1.md)已固定单池 Swap、wTSLAx/普通 ERC-20 直接结算、报告 EIP-712 字段、自动 UTC 日切、股数 Adapter 公式、精确余额基线和治理升级状态机。本历史评审的源码发现仍作为约束；剩余生产条件集中在实际 Token 的换算依据与转账可达性、治理身份地址及法务成交口径。文档层面的编码规格不能替代外部协议部署实例核验或实现后的 fork 验证。
