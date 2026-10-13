# TSV V1 架构与代码边界

本文解释当前代码采用的边界及其工程后果。所有结论都对应 `src/v1/`；完整入口见 [`SYSTEMS_OVERVIEW.md`](./SYSTEMS_OVERVIEW.md)，接口摘要见 [`CODING_SPEC_V1.md`](./CODING_SPEC_V1.md)。

## 1. 一个 V4 池对应一个证券

Registry 将每个 Permissioned Adapter W 绑定到一个 canonical U 和 `securityId`，PoolKey 必须由一侧 W 和一侧已登记 Q 构成。完整 PoolKey 的 hash 是池身份；Registry 保留池历史、lifecycle、证券关系和位置 NFT 计数。一个证券可对应多个 W 和多个池，Ledger 的 quota/used 仍以 securityId 为主键，因此池之间共享日额度。

W/Q 结构使 V4 价格、流动性及池 delta 继续使用 raw Currency 单位；用户在股票腿以 U 结算，PoolManager 内则通过 W 结算。法律股数换算由 U 对应的 `IDirectLegalShareAdapter` 承担。发行方 multiplier 随成交读取，并通过 Router 请求快照防止报价时与执行时发生未被发现的变化。

## 2. Hook 只校验和记账

V1 Hook 在 V4 回调中检查固定 Router/LP Manager、注册池、Registry 操作门禁和 multiplier。afterSwap 根据 PoolManager 返回的实际 delta，将唯一股票腿转换为 legal-share WAD 并调用 Ledger。Hook 返回的 swap、fee 和 liquidity delta 均为零；Hook 不重写 Uniswap 定价或费率。Donation 回调明确拒绝。

这一安排把池内实际结算数据作为额度输入，而不是接受 Router/Adapter 声明的成交量。Ledger 只接受 Registry 配置的 Hook 写入；`recordSwap` 核验 delta 符号和单一股票 leg，再对写入后的用量执行 quota 检查。超额时整笔 PoolManager 交易回滚。

## 3. 额度不包含市场数据算法

Ledger 仅保存按 securityId 和固定 EST epoch day 索引的 quota 与 usedWad。运营端使用 `setQuota` 直接写额度，使用 `setUsedWad` 校正用量；没有 ADTV、tier 算式、拆并股 checkpoint、报告去重或自动报告失效状态。Quota 缺省为 0，因此正成交前需写入当日额度。

固定日切简化了链上换算，但没有夏令时切换。运营后端必须按 `currentESTDay()` 的链上返回值操作，不能将其解释为 `YYYYMMDD` 或依赖本地时区库得出相同编号。

## 4. Registry 是准入和角色根

Registry 保存 W/U/Q、证券、tier、池、SBT 身份及暂停状态。它链接 `PermissionedValidationLib` 将纯准入验证从 Registry runtime 拆出；库通过 delegatecall 读取 Registry 配置，但不拥有独立状态。

各受限组件从 Registry 读取角色：Router、LP Manager、Hook 和 Ledger 共用 Registry 中的 Upgrade Admin/业务角色配置。当前实现使用普通 AccessControl 默认管理员管理角色，没有额外 Governor、Guardian、Council、治理 Anchor、timelock 或外置报告 Inbox。

## 5. 交易 Router 与 Adapter 边界

Router 只有单池 exact-input 入口，并要求输入全额成交与最小输出。Adapter 地址必须由 Registry Default Admin 配入 Router allowlist。participant 是独立参数：Router 用它检查 TSV SBT 权限，W 用同一用户执行 issuer permission 检查；Adapter 必须根据可信外部调用上下文确定该地址。

`swapExactInputFromContractDirect` 从 participant 拉取输入并将输出交给指定 recipient；`swapExactInputFromContract` 从调用 Adapter 的余额付款并将输出返回给 Adapter。Router 不实现多跳、exact-output、外部 DEX 的 caller-marker 认证，也不判定 Adapter 是否可信；这些责任属于 Adapter 部署、Router allowlist 与后端路由配置。

## 6. LP 位置与退出

LP Manager 复用 permissioned V4 position manager，在 action 分发处增加 Registry SBT 和 lifecycle 门禁，并在成功 mint/burn 后更新 Registry 的 NFT 数量。两个基于 V4 currency delta 的 mint/increase actions 不受支持。普通 `withdrawClaim` 禁用。

强退通过独立入口生成一次性、受限的 unlock callback，只允许对应仓位的 burn 和退出结算。`unwindPosition` 以 Factory 验证的 permissioned currency owner 授权，`unwindPositionByOkx` 使用 `FORCE_EXIT_ADMIN_ROLE`。二者均向 NFT 原 owner 交付，并执行完整 burn。因为完整本金/费用可能超过 V4 单次 `int128` delta，或者 quote Token 可拒绝收款，强退不是对所有池资产行为和任意仓位规模的无条件保证；准入与仓位政策必须处理这些限制。

## 7. UUPS 与 V4 Hook 地址

业务合约 implementation 禁用自身初始化，状态存放在 ERC-1967 proxy。Hook proxy 地址低 14 位必须匹配 `REQUIRED_HOOK_FLAGS == 0x3FFF`，所以使用 `TSVHookProxyFactoryV1` 通过 CREATE2 预测并部署。Router/LP Manager 的若干外部依赖为实现 immutable；升级时必须保留对应依赖，不能只比较 storage layout。

## 8. 明确由链下流程承担的检查

源码会检查地址、Factory provenance、接口和部分 metadata，但它不证明：

- U/Q 具有稳定 raw balance 语义、双向精确转账或允许 LP 强退收款；
- issuer checker、SBT、PoolManager 和 Factory 是生产地址且实现满足产品/法律要求；
- multiplier 公式是发行方批准的法律股数定义；
- 角色最小权限、部署顺序、代理地址、外部 Adapter caller 解析或 X Layer 上的运行状态已正确配置。

这些事项须以目标链部署证据、发行方文档、人工审批和真实合约集成结果单独核实。当前本地 Foundry fixtures 不能替代这些证据。
