# X-Ray Report

> TSV V1 | 4270 src-tree nSLOC / 2064 authored nSLOC | 6743896 (`main`) | Foundry | 12/10/26
>
> Full commit: `6743896068174c0bd8472f893b661ab23366e409`. 当前实现是最高解释依据，历史文档只提供设计背景。中文主文见 **[合约架构](contract-architecture.md)**；固定代码清单见 [baseline.json](baseline.json)。

## 1. Protocol Overview

**What it does:** 在 Uniswap V4 上实现身份及发行方权限约束的 W/Q 集中流动性交易，并按证券消耗固定 EST 日的法定份额额度。

- **Users**: SBT/发行方许可的交易参与者和 LP，以及获准 DEX Adapter、池创建者与运维角色。
- **Core flow**: Adapter → Router → PoolManager → Hook → Ledger；用户池外使用 U/Q。
- **Key mechanism**: V4 actions、权限包装币自动解包、真实成交 delta 和共享 security/day 额度。
- **Token model**: W 为池内包装股票；U 为底层股票；Q 为原始报价币；LP 头寸为不可转让 NFT。
- **Admin model**: Registry AccessControl；issuer owner 独立控制 W；五个 TSV 业务组件 UUPS，没有内置业务 timelock。

For a visual overview see [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key contracts | nSLOC | Role |
|---|---|---:|---|
| Registry / governance / admission | TSVRegistryV1, TSVGoverned, PermissionedValidationLib | 686 | 角色、资产、证券和池状态 |
| Hook / volume / conversion | TSVHookV1, TSVVolumeLedgerV1, ERC8056DirectLegalShareAdapter | 311 | callback 和日额度计量 |
| Swap | TSVSwapRouterV1, TSVPermissionedSettlementLib | 219 | Adapter exact-input U/Q 结算 |
| LP | TSVLPManagerV1, TSVLPManagerLib | 710 | NFT positions 与授权退出 |
| Deployment | TSVERC1967Proxy, TSVHookProxyFactoryV1 | 34 | 初始化代理 / CREATE2 |
| Types | TSVTypes | 68 | 共享 schema |
| Unconnected authored helper | TSVDirectSettlementLib | 36 | 当前 src 没有调用该 helper |

表内为 2064 自有主代码 nSLOC；全 src-tree 4270 包含本地 vendor 与 interfaces。另追踪本地 permissionedPools/V4Router 的有效继承路径，不把上游复制代码计入表内自有代码。BSD grep -P 导致原 enumeration 零值，已以相同非空/非注释口径纠正，见 metrics.json。

### How It Fits Together

The core trick: 池内 W 仅由 PoolManager 持有，池外 U 与池内 W raw 等量结算，Hook 单独把成交量换为法定份额。

### Swap

```text
TSVSwapRouterV1._swap
├─ prefund U→W / Q→Router
└─ PoolManager.unlock → swap
   ├─ TSVHookV1.beforeSwap / afterSwap → legal-share adapter → TSVVolumeLedgerV1.recordSwap
   └─ SETTLE_ALL / TAKE_ALL → W mint/unwrap or Q transfer
```

*额度回退与交易原子回滚；unlock 返回后实际输入须完全等于请求。*

### Pool initialization

```text
TSVLPManagerV1.initializePool
└─ TSVLPManagerLib.initializePool
   ├─ TSVRegistryV1.registerPool → permanent security association
   └─ PoolManager.initialize → TSVHookV1.beforeInitialize
```

*同笔注册与初始化，固定 POOL_CREATOR_ROLE。*

### LP actions

```text
TSVLPManagerV1.modifyLiquidities
└─ PoolManager.unlock → action dispatcher
   ├─ TSVLPManagerLib.checkPositionAction → issuer/NFT checks → modifyLiquidity
   ├─ mint/burn → TSVRegistryV1.updatePoolTickCount
   └─ payment → TokenApproveProxy → U→W / Q→PoolManager
```

*计数单位是 NFT，非价格 tick；未销毁的零流动性 NFT 仍计数。*

### Authorized unwind

```text
TSVLPManagerV1.unwindPosition / unwindPositionByOkx
└─ TSVLPManagerLib → exact transient callback hash → burn NFT
   ├─ OKX path → TAKE_PAIR → LP
   └─ issuer path → internal claims → real asset to LP / issuer → revert if both fail
```

*不继承父类最终交付用户 claim 的 fallback；全局 pause 仍生效。*

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX/AMM**, with permissioned securities and role-operated daily-limit characteristics.

V4 owns concentrated-liquidity pricing, while local entry/callback code constrains identity, W provenance, settlement and total daily volume；当前没有 lending、清算、股价 oracle 或链上 voting 机制。

### Actors & Adversary Model

| Actor | Trust level | Capabilities |
|---|---|---|
| DEFAULT_ADMIN_ROLE | Trusted | 即时角色分配、SBT/tier 配置与 Adapter 授权；没有 timelock |
| UPGRADE_ADMIN_ROLE | Trusted | 五个代理即时 UUPS；Hook/LP 全局暂停时禁止，Router/Registry/Ledger 不以 pause 作 upgrade gate |
| SYMBOL_ADMIN_ROLE | Bounded by canonical bindings and counters | 即时资产准入、converter 替换、生命周期；Registry 配置不统一受全局 pause gate |
| VOLUME_ORACLE_ROLE | Bounded writer | 即时写任意非零 security/day quota，不重置 used；允许下调到 used 以下 |
| HALT_REPORTER_ROLE | Bounded writer | 对已上市证券直接设置最终 mode，无 sequence / freshness envelope |
| EMERGENCY_PAUSER / RESUMER | Bounded opposite roles | 全局 bool 的启用/解除即时执行，reason 非零 |
| POOL_CREATOR_ROLE | Bounded by admission | 注册并初始化池，初价由 caller 提供 |
| FORCE_EXIT_ADMIN_ROLE | Bounded by issuer UNWIND_ALLOWED | 授权 burn/实物到 LP，受全局 pause |
| W issuer owner | Trusted independent authority | 即时 checker/hooks/wrappers/swap 配置，Ownable2Step 转移，issuer unwind 可 fallback 至 owner |
| Allowlisted Adapter | Bounded contract caller | 提供 participant/payer/recipient；Core 依赖该 Adapter 认证 participant |
| NFT LP / approved operator | Bounded by identity, issuer and pool gates | ordinary actions；NFT transfer 禁用 |

**Adversary Ranking**

1. **被控制的管理/发行方账号** — 直接影响角色、实现、converter、可操作身份和实物退出目的地。
2. **被控制的获准 Adapter 或 signer** — 位于 participant 认证与预付款信任边界。
3. **交易排序者** — 影响 concentrated-liquidity 价格、单池 output 与 LP from-deltas 行为。
4. **异常 token / checker / subscriber 实现** — 参与资产交付、身份查询及有外部调用的 NFT 操作。

See [entry-points.md](entry-points.md) for all permissionless / privileged / inherited entry points.

### Trust Boundaries

- **Registry roles** — AccessControl 授权即时生效，UPGRADE_ADMIN 能改变五个业务实现；TSVGoverned.sol:15–41 没有业务延时。
- **Core / Adapter** — Router.sol:198/207 校验合约名单和 SBT，却由 Adapter 提供 participant；外部 TSVAdapter 用 signed caller 集合认证身份。
- **Venue / issuer** — W owner 可即时替换 checker 或 wrapper/hook 配置；PermissionsAdapter.sol:62–108，与 Registry admin 分属两套权限。
- **V4 custody / callbacks** — trusted PoolManager → fixed Hook/LP/Router，Hook.sol:86/208/270 与 Ledger.sol:60 约束 sender；资产行为仍依赖 U/Q 实现。

### Key Attack Surfaces

- **共享日额度与动态配置** [I-1](invariants.md#i-1), [X-1](invariants.md#x-1) — Ledger.sol:45/70–71 的所有 quota/used 写点应与日期和多池共享计量一起核对。

- **Wrapper 与 U/Q 预付款边界** [I-10](invariants.md#i-10), [G-83](invariants.md#g-83) — Router.sol:210–219 / PermissionsAdapter.sol:48–52/132–140 需联合检查 surplus、mint 和真实 U 交付。

- **LP NFT / Registry 计数联动** [I-7](invariants.md#i-7), [X-2](invariants.md#x-2) — LPManager.sol:367–370/334 与 Registry.sol:811/840 的普通和授权 burn 路径应一并核对。

- **授权退出与 recipient fallback** [X-4](invariants.md#x-4), [G-71](invariants.md#g-71) — LP 库:173–215 / LPManager.sol:315–345 的 hash 消费、gas-bound delivery 与管理员目的地值得共同追踪。

- **Canonical converter 替换** [I-5](invariants.md#i-5), [X-3](invariants.md#x-3) — Registry.sol:482–484 和 Hook.sol:296–315 将转换器变更立即用于后续成交。

- **生命周期与未来建池开关** [I-6](invariants.md#i-6), [I-11](invariants.md#i-11) — Registry.sol:446–468/769–793 的 registered 标志与旧池 gate 含义不同，需按实际 writer 解释。

- **Adapter 身份授权** — Router.sol:198–207 与子模块 TSVAdapter.sol:73–84 是不同认证层，应核对 caller、participant、nonce 与签名字段。

### Upgrade Architecture Concerns

- **独立升级 gate** — Router.sol:257–264 强制新实现 immutable PM/Factory 匹配；LPManager.sol:299–310 仅角色/pause/UUPS，不强制全部 immutable 兼容。
- **存储迁移边界** — Ledger 和 Registry 刚经历大幅简化，应以完整旧/新 storage layout 审查真实部署迁移，当前源文件不能证明任意已有代理可安全升级。

### Protocol-Type Concerns

- **集中流动性金额边界** — V4Router.sol:83–98 / Router.sol:222 的 min-out 与全额输入检查应按 raw units 解释。
- **仍可调用的 from-deltas** — 本地 PositionManager.sol:206/230 与 LPManager.sol:349–354 继续支持源码标注 deprecated 的两类动作。
- **零流动性 NFT** — PositionManager.sol:439 跳过 PM.modifyLiquidity，不能从 burn 名称推出总会重新结算费用。

### Temporal Risk Profile

- **Deployment & Initialization** — Hook.sol:69–82 要求组件先具备代码，Registry.sol:230–255 只允许组件一次后绑定；proxy constructor 必须携带对应 initializer。
- **EST day boundary** — Ledger.sol:53 采用固定 UTC-5 epoch day；夏令时、未来 quota provisioning 和日界线由该公式定义。

### Composability & Dependency Risks

> **V4 PoolManager / periphery** — via Router, LPManager, Hook
> - Assumes: trusted callback semantics, concentrated-liquidity math, unlock debt clearing.
> - Validates: fixed caller / exact pool / admitted assets; Router additionally input fill and min-out.
> - Mutability: implementation PM identity pinned in Router/LP, runtime chain deployment not inspected.
> - On failure: transaction reverts.

> **PermissionsAdapter W / issuer checker** — via Registry admission and trade/LP settlement
> - Assumes: U transfer behavior and meaningful issuer permission flags.
> - Validates: Factory creation/verification, bound U/PM, decimals, wrapper/hook and per-action permissions.
> - Mutability: owner can change checker/hooks/wrappers/swappingEnabled instantly.
> - On failure: revert; issuer unwind retries real asset to LP then issuer, then reverts.

> **Participant SBT** — via Registry.permissionsOf
> - Assumes: verify/paused semantics, actor identity supplied by callers.
> - Validates: bound code and query interface at bind, configured identities and merged operation mask.
> - Mutability: address bound once; external SBT implementation/admin behavior not inferred from a deployed address.
> - On failure: query reverts; paused SBT yields NONE operation permissions.

> **Legal-share adapter / U multiplier** — via Hook
> - Assumes: meaningful WAD multiplier and legal-share conversion.
> - Validates: interface/bound U at Registry writes, snapshot equality before/after swap; provided converter rejects invalid decimals/zero rate.
> - Mutability: SYMBOL_ADMIN replaces adapter; U multiplier remains external.
> - On failure: entire swap reverts.

> **TokenApproveProxy / Permit2 / subscribers** — via LPManager
> - Assumes: correct approved-token transfer and signature/callback implementations.
> - Validates: approve proxy code and tokenApprove code at construction, per-action permissions, NFT approval, signature/nonces.
> - Mutability: immutable dependency addresses in each LP implementation; subscriber is owner-selected.
> - On failure: ordinary asset operations revert; Permit2 forwarding returns caught error; unsubscribe notification catches bounded failure.

**Token assumptions:** SafeERC20 does not prove exact transfer or immutable balances; current PermissionedValidationLib has metadata/identity checks, not an on-chain rebase/fee simulation.

**Shared state:** all W/Q pools of one security share Ledger usage; V4 liquidity and price state is also visible to other permitted integrations.

## 3. Invariants

> 完整目录：**[invariants.md](invariants.md)** — 107 enforced guards / 13 single-contract / 4 cross-contract / 1 economic invariant。2 个 On-chain=No block 指向同一个可验证的 quota 下调边界。

## 4. Documentation Quality

| Aspect | Status | Notes |
|---|---|---|
| README / spec | Present but drifting | 历史 DataInbox / GovernanceAnchor / ADTV / split/sequence 不能解释当前 ABI |
| NatSpec | Present in 52 of 55 source files | 部分注释被继承覆盖；如 parent claim fallback、自动激活池与当前实现不同 |
| Current architecture | Produced | contract-architecture.md 逐组件以 current source 为准 |
| Historical claims | Context only | (per spec) 文档宣称 exact-transfer admission；(per code) 当前准入并无动态转账性质测试 |

## 5. Test Analysis

| Metric | Value | Source |
|---|---|---|
| Test / helper Solidity files | 53 = 38 `.t.sol` + 15 helpers | Portable file scan |
| test* functions | 272 | Portable function scan |
| Line / branch coverage | Unavailable | forge coverage and --ir-minimum both failed during compile |

编译失败的测试 import 指向已删除的 `TSVDataInboxV1.sol`、`TSVReports.sol`、`TradeDayLib.sol`、`ReportValidationLib.sol`，例如 reports/SplitFactorBoundaries.t.sol:5–9。测试存在与基准可编译是不同结论；未获得 runtime passing 证据。

### Test Depth

| Category | Count | Coverage evidence |
|---|---:|---|
| Unit files | 32 | registry/trading/governance/reports/adapters/deployment；未成功运行 |
| Integration files | 6 | local deployment/trading；未成功运行 |
| Stateless Fuzz functions | 15 | testFuzz* scan，仅存在性 |
| Stateful Foundry invariant functions | 0 | 发现 StatefulOperations.t.sol 名称，但无 invariant_* 函数 |
| Formal verification functions/specs | 0 | scope scan 未发现 Certora/Halmos/HEVM 项目证据 |

### Gaps

- Stateful invariant、项目 formal verification 和 fork 测试未发现；不得从库内的上游测试推断主项目覆盖。
- 现有测试引用已删除接口；旧测试结果不能用于当前 commit 的行为验证。

## 6. Developer & Git History

> Analyzed branch `main` at `6743896` only；143 reachable commits，normal_dev，2026-10-01 → 2026-10-12。

### Contributors / Review Signals

| Signal | Value | Meaning |
|---|---|---|
| Author identities | 6 git author strings; 3 normalized source contributors | 名称/email alias 不能当独立人员数 |
| Merge commits | 47 / 143 | merge records exist；未从 merge 数推断 review 已通过 |
| Source-changing commits | 83 | 30-day window 覆盖仓库全部 11 天历史 |
| Test co-change rate | 66.3% | 源码变更同时修改测试文件的比例，非覆盖率或运行结果 |
| Source additions share | zewei.lu 66.0%, comcat.li 25.3%, yunshan.fang 8.7% | analyzer 的 added-lines 权重，不代表 ownership 或审批责任 |

### File Hotspots

| Current file | Reachable-history modifications |
|---|---:|
| TSVRegistryV1.sol | 40 |
| TSVLPManagerV1.sol | 29 |
| TSVTypes.sol | 26 |
| ITSVPermissionedRegistry.sol | 25 |
| TSVSwapRouterV1.sol | 20 |
| TSVHookV1.sol | 19 |
| TSVVolumeLedgerV1.sol | 18 |

### Security-Relevant Commits

下表为 commit message/diff 的结构评分，用作人工查看索引，不是漏洞或修复充分性结论；当前行为只据 HEAD 源码描述。

| SHA | Date | Subject | Score | Signal |
|---|---|---|---:|---|
| 64b7cd5 | 2026-10-11 | fix: disable LP claim withdrawals and revert failed delivery | 17 | test files co-changed |
| cece27b | 2026-10-10 | fix(lp): extract linked libraries and authorize upgrades through registry | 17 | test files co-changed |
| 51aa98f | 2026-10-03 | feat: simplify security admission and default markets to open | 17 | test files co-changed |
| a9f1ccc | 2026-10-11 | fix(lp): align hook and unwind admission with registry gates | 16 | test files co-changed |
| ebb602e | 2026-10-01 | Update protocol sources, docs, and audit artifacts | 16 | test files co-changed |
| 38ec341 | 2026-10-11 | fix: prioritize authorized unwinds over LP admission | 14 | test files co-changed |
| 86911a1 | 2026-10-10 | fix(lp): separate issuer and LP claim withdrawals | 14 | test files co-changed |
| 52bf960 | 2026-10-09 | fix(lp): register and initialize pools atomically | 14 | test files co-changed |

### Dangerous Area Evolution

| Analyzer heuristic area | Commits | Current src examples |
|---|---:|---|
| access_control | 73 | TSVHookV1.sol, TSVRegistryV1.sol, TSVVolumeLedgerV1.sol, TSVGoverned.sol, ITSVPermissionedRegistry.sol, TSVLPManagerLib.sol, TSVLPManagerV1.sol, TSVSwapRouterV1 |
| fund_flows | 52 | TSVDirectSettlementLib.sol, TSVLPManagerLib.sol, TSVPermissionedSettlementLib.sol, TSVLPManagerV1.sol, TSVSwapRouterV1.sol, TSVTypes.sol, PermissionedPositionMa |
| oracle_price | 50 | TSVLPManagerLib.sol, TSVLPManagerV1.sol, TSVTypes.sol, PositionManager.sol, PoolInitializer_v4.sol, LPPositionMath.sol, V4Router.sol, IV4Router.sol, Actions.sol |
| signatures | 66 | TSVHookV1.sol, TSVRegistryV1.sol, ITSVPermissionedRegistry.sol, TSVLPManagerV1.sol, PermissionedPositionManager.sol, PositionManager.sol, BaseActionsRouter.sol, |
| state_machines | 72 | TSVHookV1.sol, TSVRegistryV1.sol, ITSVPermissionedRegistry.sol, TSVLPManagerLib.sol, TSVLPManagerV1.sol, TSVSwapRouterV1.sol, TSVTypes.sol |

这些是关键词结构命中，脚本也查看依赖的历史文件；oracle_price 分类不表示当前 TSV 存在独立股价 oracle，历史 liquidation 命中仅位于库，不属于本协议功能。

### Forked Dependencies

| Dependency | Baseline | Handling |
|---|---|---|
| local permissionedPools / v4-router | tracked in HEAD | 当前 override 和 upstream 注释分别核对 |
| v4-periphery | 9969eec44cfdf07e24b41de47f40276a58401976 | registered submodule |
| dex-adapters | cfa52d8c3036907911084c1581258bf36bf82543 | TSVAdapter caller auth / multiplier 接入 |
| soul-bound-token-1155 | a4c53ccbf7de65a3f415a706d22a506a215b68fc | registered submodule；runtime SBT 地址未检查 |
| lib/v4-core | internalized tracked code | 不把 nested periphery v4-core 路径与本地 remapping 混同 |
| OZ contracts / upgradeable | 5.5.0 package directories | 本地 package Solidity hashes 记录于 baseline |

### Security Observations / Cross-Reference Synthesis

- **Registry/LP churn** — 高改动文件与 §2 的生命周期、NFT 计数和退出路径一致，相关性质链接 I-7 / I-11 / X-2。
- **Recent interface simplification** — HEAD Ledger 仅日额度模型；历史 DataInbox 热点属于已删除代码，不能写作当前组件。
- **Tests co-change** — 28 of 83 source commits 在 30-day window 未同时修改 tests；独立于本次 coverage 编译失败。
- **Technical debt markers** — analyzer 在 src 检出 0 TODO/FIXME/HACK；这不意味着没有设计或测试缺口。

## X-Ray Verdict

**FRAGILE** — 按 x-ray 的结构分级取最低项：存在 unit 与 fuzz（Tests=ADEQUATE）、有 NatSpec/spec 但历史说明漂移（Docs≥ADEQUATE），角色具备但没有内置 timelock（Access Control=FRAGILE）；覆盖率编译失败单独记录，不用于抹去测试存在性。

**Structural facts:**

1. 主源码含 55 个 Solidity 文件、4270 nSLOC，其中自有主代码及类型定义 2064 nSLOC。
2. 当前有五个 TSV 业务 UUPS 实现；Hook 与 LP 的 upgrade gate 检查全局 pause，其他三个不统一检查。
3. Ledger 唯一成交量状态为按 security/EST-day 的 Quota 和 usedWad，没有 DataInbox、ADTV、split 或 report sequence。
4. 检出 38 个测试文件、15 个辅助文件、272 个 test* 函数和15个 testFuzz*；当前测试 import 与删除后的源码不一致。
5. 分析范围为 main@6743896，可达历史为143个提交、47个 merge；所有输出绑定同一基准。
