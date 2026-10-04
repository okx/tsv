# X-Ray Report

> TSV V1 | 2514 enumerated nSLOC | 44012cb (`feat/tsv-governance-tests-split-factors`) | Foundry / Solidity 0.8.26 / Cancun | 04/10/26

结构审查范围为src的18个自有实现/库/类型文件，2491 nSLOC；枚举TOTAL 2514含两个interface的23 nSLOC，未将interface作为审查目标。script仅用于部署流程与覆盖分析，test仅分析场景覆盖；外部仓库/依赖只作调用语义与运行辅助，未做review。代码证据为当前HEAD；本报告是审计准备与结构分析，漏洞结论仍以[三轮审计报告](../.solidity-auditor/runs/20261004-023005/full-report.md)为准。

---

## 1. Protocol Overview

**What it does:** TSV把经准入的证券Currency接入V4池，按实际swap delta实时换算法律股数，并在同一securityId/计量日共享ADTV×Tier预算。

- **Users**: 当前SBT有效且未暂停的交易者/LP；授权DEX Adapter可代表认证participant参与交易。
- **Core flow**: Router→V4 PoolManager→Hook→Ledger记账，再直接完成付款人与PM之间的Currency收付。
- **Key mechanism**: V4提供AMM定价/流动性，TSV维护准入、TRADE/LP暂停、实际delta计量和非转让Receipt。
- **Token model**: stock Currency与quote Currency直接结算；同stock security可有多Currency，池至多一stock，quote/quote允许。
- **Admin model**: Governor即时配置角色/参数及升级；Guardian冻结升级并批准恢复；immutable Council提案恢复，执行无需特定caller。

For a visual overview of the protocol's architecture, see the [architecture diagram](architecture.svg).

### Contracts in Scope

| Subsystem | Key Contracts | nSLOC | Role |
|---|---|---:|---|
| Adapters | BackedAutoFeeLegalShareAdapter / ERC8056DirectLegalShareAdapter | 90 | 池Currency实际delta到法律股WAD |
| Core | Registry / DataInbox / Hook / VolumeLedger | 1180 | 准入、报告、回调门禁及共同日预算 |
| Deployment | TSVERC1967Proxy / TSVHookProxyFactoryV1 | 34 | 原子初始化与CREATE2 Hook地址权限位 |
| Governance | TSVGovernanceAnchor / TSVGoverned | 292 | 固定根、六proxy即时UUPS升级与多方恢复 |
| Legacy | IssuerShareSettlementAdapter | 175 | 历史两阶段issuer/wrapper结算，当前V1不接入 |
| Libraries | ReportValidationLib / TSVDirectSettlementLib / TradeDayLib | 113 | Ingress校验、精确直接收付、日历与月份 |
| Periphery | SwapRouter / LPManager | 455 | swap与非转让Receipt仓位生命周期 |
| Types | TSVReports / TSVTypes | 152 | 报告、资产、池、请求与context结构 |
| **Total reviewed** | **18 source files** | **2491** | 不含interface与vendored代码 |

架构图显示当前V1运行路径；Factory、Proxy和legacy结算位于上表，legacy的activeAssetOperation接口未由当前Router/LP实现，编码规格将其列为隔离历史回归对象（`docs/CODING_SPEC_V1.md:19`）。图中Registry→Anchor代表六业务proxy共享的权限根，结算helper归入Router/LP，省略次要查询边。

### How It Fits Together

The core trick: 把V4实际成交raw delta、调用时的法律股转换值和security/day共同计数连接起来，同时让PM保管池资产。

### Direct swap

```text
TSVSwapRouterV1.swapExactInput / swapExactOutput
└─ PoolManager.unlock → Router.unlockCallback → PoolManager.swap
   ├─ TSVHookV1.afterSwap → BackedAutoFeeLegalShareAdapter.toLegalShares / ERC8056DirectLegalShareAdapter.toLegalShares → TSVVolumeLedgerV1.recordSwap
   └─ TSVDirectSettlementLib.settle / take → ERC20 + PoolManager
```

*Hook按实际delta写usedWad；Router按实际in/out落实界限并核对精确余额变化，任一失败整笔回滚。*

### Allowlisted Adapter swap

```text
External DEX Adapter → TSVSwapRouterV1.swapExactInputFromAdapter(request, participant)
├─ TSVRegistryV1.isEligible(participant) / isTradable(pool)
└─ [same direct-swap callback and Ledger path]
   └─ TSVDirectSettlementLib: Adapter ↔ PoolManager
```

*participant用于资格，Adapter是付款人/收款人；DEX caller身份的来源由外部Adapter认证。*

### Pool / position lifecycle

```text
TSVLPManagerV1.initializePool
├─ TSVRegistryV1.registerPendingPool → PoolManager.initialize → Registry.markPoolActive
└─ openPosition → _modify → PoolManager.unlock → LP.unlockCallback → modifyLiquidity
   ├─ TSVHookV1.before/afterAddLiquidity: validate activeLPContext
   └─ TSVDirectSettlementLib: owner ↔ PoolManager → save liquidity + mint Receipt
```

*创建池PENDING→ACTIVE同笔完成；开仓过程中先有临时记录，成功返回时才有正liquidity与Receipt。*

### Owner close / force exit

```text
TSVLPManagerV1.closePosition / forceExit
└─ _modify → PoolManager.unlock → LP.unlockCallback → modifyLiquidity
   ├─ TSVHookV1.before/afterRemoveLiquidity: validate ordinary / force mode
   └─ TSVDirectSettlementLib.take → original owner → _close + burn Receipt
```

*普通退出受SBT/LP许可；强退经独立角色规则、已知池和全额减少路径，始终交付原owner，发行方实际拒转仍可导致回滚。*

---

## 2. Threat & Trust Model

### Protocol Threat Profile

> Protocol classified as: **DEX / AMM integration** with **oracle/reporting and upgradeable governance** characteristics

V4承担当下定价，TSV以授权ADTV/quota/factor报告提供非价格的量化预算；没有借贷、清算、桥接或用户签名订单验证模块。

### Actors & Adversary Model

| Actor | Trust Level | Capabilities |
|---|---|---|
| Governor / DEFAULT_ADMIN_ROLE | Trusted | 即时角色/关键配置、单笔或最多六proxy批量升级；升级受Guardian冻结，业务配置不受该冻结 |
| Guardian | Bounded（独立身份） | 即时冻结/解冻升级、批准/撤回恢复；不能单方提案或直接改身份 |
| Recovery Council | Bounded（immutable、独立身份） | 提案/取消根身份恢复，须当前Guardian批准，无单方执行授权 |
| SYMBOL_ADMIN_ROLE | Trusted for admission | 即时准入/上市/Tier归属、Token/Pool状态及符合替换条件的Adapter更换 |
| VOLUME_ORACLE_ROLE | Trusted for numeric reports | ADTV/quota/未来split factors；受Ingress、version、时间及数值范围检查 |
| HALT_REPORTER_ROLE | Bounded（listed证券、有效顺序） | 即时市场TRADE/LP暂停或恢复，不清除紧急pause记录 |
| EMERGENCY_PAUSER_ROLE / RESUMER_ROLE | Bounded（记录及scope） | 创建/逐条解除GLOBAL/SECURITY/TOKEN/POOL与TRADE/LP/ALL记录 |
| POOL_CREATOR_ROLE | Bounded（已准入key） | 提交初始V4价格与priceBasisHash并原子建池；hash不证明价格合理性 |
| FORCE_EXIT_ADMIN_ROLE / REVOKE_EXIT_EXECUTOR_ROLE | Bounded（原owner交付） | 前者强退；后者仅owner无credential时强退；绕过普通SBT/业务暂停 |
| SBT holder / LP owner | Bounded（当前资格、pool、amount） | 直接swap；开仓/自己仓位修改，普通LP受LP暂停 |
| Allowlisted DEX Adapter | Trusted for participant provenance | 选择participant并承担收付；Router检查participant的当前资格 |
| Bound PoolManager / Hook / Inbox / LP Manager | Bounded（固定caller links） | PM回调、成交量写入、报告写入、建池状态写入各有专用caller约束 |

**Adversary Ranking**

1. **被入侵或错误配置的治理/准入执行者** — 可即时改变六proxy逻辑或关键资产与预算配置。
2. **不一致的issuer/资产配置及转换来源** — 是raw Currency与法律股预算之间的语义来源。
3. **被入侵或错误的reporter服务** — 提供月度ADTV与当日/未来预算数据。
4. **恶意持证交易者或LP** — 能组合成交、仓位、日切及费用状态路径。
5. **失配的DEX Adapter集成** — 处在participant认证与实际付款来源的外部边界。

See [entry-points.md](entry-points.md) for the full permissionless entry point map.

### Trust Boundaries

- **Governor→six proxy implementations** — 无timelock，当前Governor可即时改变逻辑；Guardian开关只控制升级（`TSVGoverned.sol:116–123`），未验证生产多签。
- **Admission→legal-share unit** — Registry核对接口、Currency/version/codehash而无法证明法律单位；replacement可立即改变未来换算（`TSVRegistryV1.sol:378–388`）。
- **Reporter→numeric budget** — VOLUME_ORACLE可更正ADTV/quota，Ingress维护授权/顺序/ID而不验证链外数据真值（`TSVDataInboxV1.sol:156–170`）。
- **DEX→participant provenance** — allowlisted Adapter负责caller marker认证，Router只验证其提供地址的资格（`TSVSwapRouterV1.sol:125–137`）。
- **Recovery→current roots** — Council提案与Guardian批准共同授权、epochs防旧授权，执行者可任意；冻结仍保持（`TSVGovernanceAnchor.sol:239–295`）。

### Key Attack Surfaces

- **Legal-unit continuity** &#91;[X-8](invariants.md#x-8), [E-4](invariants.md#e-4)&#93; — `Registry.replaceLegalShareAdapter:378–388`与`Ledger._consume:509–514`共享旧预算/usage，核对跨Currency及动态转换的单位连续性。

- **Actual-delta settlement and callbacks** &#91;[X-5](invariants.md#x-5), [X-6](invariants.md#x-6), [I-34](invariants.md#i-34)&#93; — `Router.unlockCallback:154–178`和`DirectSettlementLib:23–55`连接V4 delta、Hook零delta及双边余额，追踪边界数量与异常Token行为。

- **Report corrections and factor basis** &#91;[I-12](invariants.md#i-12), [I-16](invariants.md#i-16), [I-17](invariants.md#i-17), [X-9](invariants.md#x-9)&#93; — `Ledger.acceptAdtv/Quota/SplitFactor:186–288`修改预算但保留历史used，核对月基数与最后未来checkpoint组合。

- **Day-start schedule/history** &#91;[I-18](invariants.md#i-18), [I-19](invariants.md#i-19)&#93; — `Ledger.scheduleDayStart/cancelPendingDayStart:335–381`使用前一过渡日锁定边界，追踪20/28小时日与月份切换。

- **LP context, receipt and exit modes** &#91;[I-26](invariants.md#i-26), [I-28](invariants.md#i-28), [I-29](invariants.md#i-29), [X-4](invariants.md#x-4)&#93; — `LPManager._modify:342–356`与`Hook._checkLP:287–294`跨越PM callback及仓位暂态，核对owner、hash和force-mode字段。

- **Independent pause composition** &#91;[I-10](invariants.md#i-10), [I-11](invariants.md#i-11), [X-3](invariants.md#x-3)&#93; — `Registry._isOperationAllowed:581–600`组合市场与多scope计数，核对清除单条记录、部分恢复及强退例外。

- **Admission and active-pool counters** &#91;[I-7](invariants.md#i-7), [I-8](invariants.md#i-8), [I-32](invariants.md#i-32)&#93; — `Registry.markPoolActive/disablePool/enablePool:425–474`与上市/Tier迁移共用计数，追踪多Currency证券及禁用池状态。

- **Immediate upgrade and recovery interleaving** &#91;[I-21](invariants.md#i-21), [I-30](invariants.md#i-30), [I-35](invariants.md#i-35), [X-7](invariants.md#x-7)&#93; — `Anchor.upgradeBatch:151–174`、`executeRecovery:277–295`与共享UUPS授权涉及batch context及epochs，核对初始化过程caller与冻结保持。

- **Adapter participant versus payer** &#91;[G-177](invariants.md#g-177), [G-186](invariants.md#g-186)&#93; — `Router.swapExactInputFromAdapter:130–137`分别使用participant资格与Adapter收付身份，核对集成端身份来源和退款归属。

### Upgrade Architecture Concerns

- **Current UUPS authority** — 六个实现constructor锁初始化，单笔/批量都执行共享授权；任意新逻辑的layout与权限保持须由发布验收核对（`TSVGoverned.sol:31–51,116–123`）。
- **Stable Hook address versus future accounting** — Factory强制Hook低14位权限，V1返回0 delta；非零delta逻辑升级须连同Router/LP记账假设审阅（`TSVHookProxyFactoryV1.sol:38`、`TSVHookV1.sol:28–29`）。
- **Fixed root and shared component blast radius** — Anchor非proxy、Council immutable，六proxy列表仅bind一次；code/nonempty-init检查不替代业务layout检查（`TSVGovernanceAnchor.sol:183–234`）。

### Protocol-Type Concerns

**As a DEX / AMM integration:**

- `LPManager._validateTicks:421`限制排序/范围/spacing，`Registry.registerPendingPool:406`只接收静态fee；初始价格依PoolCreator与外部V4范围检查。
- `Registry:413`允许quote/quote、拒绝stock/stock，核对无stock池的零计量语义；TVL、曲线和费用增长的正确性由外部PM提供。

**As a reporting / budget system:**

- `Ledger._hardCap:538`以Math.mulDiv一次最终floor；ERC8056转换:43另有一次floor，两者不应误认为同一舍入位置。
- `Inbox._accept:168–170`采用按kind/security的stream与全局ID；无用户/报告签名验真路径，顺序不随sourceMonth重置。

### Temporal Risk Profile

**Deployment & Initialization:**

- `TSVERC1967Proxy.sol:15–16`构造delegate-init并拒绝空data；六组件完成互链后才可`Anchor.bindProxies:204–234`，初始化角色/目标与脚本成功路径需一致。

**Market Stress:**

- `Registry:221–230`的SBT verify/paused及`DirectSettlementLib:23–55`的issuer拒转均可使交易/普通LP回滚；强退绕过业务门禁但仍依赖实际资产可转移。

### Composability & Dependency Risks

**Dependency Risk Map:**

> **V4 PoolManager** — via `Router.unlockCallback:164`, `LP.unlockCallback:315`
> - Assumes: pools/liquidity、signed delta、unlock/callback与settle/take语义正确。
> - Validates: 绑定caller、准确PoolKey、LP hash/context、amount界限与精确双边余额。
> - Mutability: TSV中的PM引用初始化后不变；目标部署与外部代码治理未在本范围确定。
> - On failure: 外部调用或delta/余额检查失败则整笔回滚。

> **Issuer conversion / Currency ERC20** — via `BackedAdapter.toLegalShares:78`, `ERC8056Adapter:43/50–54`, `DirectSettlementLib:23–55`
> - Assumes: 转换值有正确法律单位，balanceOf真实、raw余额稳定，非fee-on-transfer/rebase异常资产。
> - Validates: 配置code/decimals/Currency/version、positive转换、转账前后双方精确差值；不证明发行方法律语义或proxy实施槽位。
> - Mutability: 自有Adapter配置immutable；Registry可更换Adapter；issuer/multiplier/底层proxy治理属于外部边界。
> - On failure: 转换/转账/余额不符回滚；正数且语义错误的转换不能由数值检查识别。

> **Participant SBT** — via `Registry.hasCredential/isEligible:221–230`
> - Assumes: verify/paused语义对应资格与运营暂停。
> - Validates: Governor配置时code与两个selector返回可读，普通路径要求verify=true、paused=false。
> - Mutability: Governor即时替换SBT地址/tokenId；目标升级治理未核验。
> - On failure: 调用失败回滚；资格false阻断普通路径，强退executor分支另核对撤证。

> **External DEX Adapter / Router caller marker** — via `SwapRouter.swapExactInputFromAdapter:130–137`
> - Assumes: participant源自被认证DEX调用者、退款只回原payer、新增output正确转发。（per spec：集成文档:41–45）
> - Validates: allowlist、participant SBT、同一swap/pool/cap/结算边界；没有在TSV内部认证DEX marker。
> - Mutability: Governor即时启用/撤销Adapter；外部Router/Adapter治理未核验。
> - On failure: TSV内失败原子回滚；DEX付款/转发步骤的行为只作辅助理解。

> **OpenZeppelin 5.5.0 / ERC1967 / AccessControl** — via `TSVGoverned`、`TSVERC1967Proxy`
> - Assumes: 安装版本的initializer、UUPS、角色及ERC721基础语义；仅为解释继承调用读取相关方法。
> - Validates: 自有保护DEFAULT_ADMIN和升级授权、实现初始化锁；未review依赖仓库。
> - Mutability: 编译依赖固定在foundry.toml；部署后随业务implementation选择。
> - On failure: 初始化/授权检查失败回滚。

**Token Assumptions** *(unvalidated only)*:

- ERC20 raw余额不因非转账动作改变且balanceOf如实反映余额；代码仅验证本次观察差值（`docs/TOKEN_ADMISSION_STANDARD_V1.md:25`，per spec）。
- 法律股转换与ADTV须同单位，日内unit变化按链外暂停/核对/恢复流程处理；结构检查不证明实际issuer准入（同文档:46/50/95，per spec）。

**Shared State Exposure**:

- V4 PM共享池与currency会计；Hook约束TSV池sender为自有Router/LP，其他V4池/issuer转账不计入TSV成交量（`Hook:80,202,223,287`）。

---

## 3. Invariants

> ### Full invariant map: **[invariants.md](invariants.md)**
>
> - **187 Enforced Guards** (`G-1`…`G-187`)
> - **36 Single-Contract Invariants** (`I-1`…`I-36`)
> - **9 Cross-Contract Invariants** (`X-1`…`X-9`)
> - **4 Economic Invariants** (`E-1`…`E-4`)
>
> 共49项推导性质；2项On-chain=No为规格明确的法律股单位语义/连续性链外前提，非已确认漏洞。

---

## 4. Documentation Quality

| Aspect | Status | Notes |
|---|---|---|
| README | Present | 运行方式、结构、369本地/11fork摘要 |
| NatSpec | 957 annotation lines/tags | 20 source文件均有注释；枚举器输出20是文件数，非注释条数 |
| Spec / architecture | Present | 本次读取13份当前规格/部署/覆盖文档，见[manifest](spec-docs.json) |
| Inline comments | Adequate | 说明factor绝对值、日切历史、角色根及Hook零delta约定 |

- **Adapter implementation drift** — `TOKEN_ADMISSION_STANDARD_V1.md:16`仍称无ERC8056 Adapter，`CODING_SPEC_V1.md:18/108`及`IMPLEMENTATION_STATUS_V1.md:14`称Backed唯一；当前src已有ERC8056Direct，测试规格:3与独立7项测试也承认该路径。
- **Retired signature wording** — `TEST_SPEC_V1.md:150`仍要求version=1/2授权切换，而当前Router/Inbox没有该签名参数；规格条款须与直接调用/角色报告模型一致。
- **Production evidence boundary** — `IMPLEMENTATION_STATUS_V1.md:42–46`与部署清单列出真实issuer/法律依据、目标链artifact、SBT、真实多签等验收；本地mock/继承语义不构成这些证据。（per spec）

---

## 5. Test Analysis

| Metric | Value | Source |
|---|---|---|
| Test Solidity files | 81（含helpers） | 文件枚举 |
| test* functions | 373 | 文件枚举，含13 testFuzz*，不含7 invariant* |
| Executed local tests | 369 passed / 0 failed / 0 skipped；63 suites | [coverage.log](coverage.log) |
| Line coverage | 91.98% (1181/1284) | forge coverage；src+4 script |
| Branch coverage | 85.14% (235/276) | 同上 |
| Source-only line / branch | 97.78% (1099/1124) / 86.33% (221/256) | 从逐文件src行加总 |
| Statements / functions | 92.98% (2000/2151) / 94.71% (179/189) | src+script总计 |

命令为`FOUNDRY_PROFILE=coverage forge coverage --offline`，首轮stack-too-deep后以`--ir-minimum`成功；Forge提示minimum IR optimization可能影响source映射准确度。profile排除X Layer fork，本次没有执行网络fork。指标见[coverage-summary.json](coverage-summary.json)，不将覆盖百分比等同于场景充分性。

### Test Depth

| Category | Count | Contracts Covered |
|---|---:|---|
| Unit | 231 test*（执行partition另有6 invariant，共237） | 治理、Registry、报告/日历/因子、Adapter、Factory、volume、legacy |
| Integration | 131本地test*（另有1 invariant，共132） | 真实V4交易、LP、暂停、运营更正、升级状态保留 |
| Fork | 11 test*；1 createSelectFork site | 固定X Layer DEX流程；存在但本次未运行 |
| Stateless Fuzz | 13 testFuzz*（unit11/local2） | 治理批次/绑定/部署、Registry、交易边界 |
| Stateful Fuzz (Foundry) | 7 invariant* / 3 suites | 治理、报告/日切运营、Trading/LP独立模型；64 runs×32 depth |
| Formal Verification | 0 Certora / Halmos / HEVM | 未发现自有spec或配置 |

现有模型已覆盖成功/拒绝、原子回滚、多scope暂停、实际delta、历史usage与仓位/根身份状态。场景合理性的15项细化建议沿用[三轮测试覆盖分析](../.solidity-auditor/runs/20261004-023005/test-coverage.md)，其中明确区分已有覆盖与组合/资金状态/脚本成功路径增补；未对test代码报告安全漏洞。

覆盖分布：DeployCore 27.27%行、DeployGovernance 46.15%行且0/2分支、ScriptEnvironment 0/6行；legacy Adapter 79.17%行但1/14分支，该路径不属于当前V1资金主流程。Governance Anchor覆盖24/24分支，本地Executor/mock不证明生产多签实现。

### Gaps

- 未发现Certora/Halmos/HEVM形式化验证类别。
- 未发现独立Echidna或Medusa stateful suites；Foundry stateful类别已存在，不能据此称缺少状态性测试。

---

## 6. Developer & Git History

> Repo shape: **normal_dev** — 当前HEAD可达25个commit，16个触及src；可见历史跨2026-10-01至10-04，共3天。

Analyzed branch: `feat/tsv-governance-tests-split-factors` at `44012cbe9b832f731806838d3e9478b0bf75c9c5`；不含其他分支状态。

### Contributors

| Author label | Commits | Source Lines (+/-) | % of Source Changes |
|---|---:|---|---:|
| zewei.lu | 23 | +6235 / -2407 | 100% |
| zewei.lu@okg.com | 2 | +0 / -0 | 0% |

author label不等于独立身份，两个标签是否同一人未核实；行数来自枚举脚本src numstat，安全分析器另按过滤口径得到6364新增行，集中度同为100%。

### Review & Process Signals

| Signal | Value | Assessment |
|---|---|---|
| Unique author labels | 2；source author 1 | 可见source变更集中于一个标签 |
| Merge commits | 4/25 (16%) | 只证明有merge；不能据此确认人工peer review |
| Test co-change rate | 93.8% (15/16 source commits) | 文件同commit变化率，不代表覆盖质量 |
| Fix-scored without co-changed tests | 10% (1/10) | c84aa50该commit未改tests；当前已有Adapter测试 |
| Average source commit size | 552.6 changed lines | 包含baseline/大批注释，非缺陷数量 |
| Last-30-day source commits | 16 | 窗口包含全部3天历史，不能推断临审赶工 |

### File Hotspots

| File | Modifications | Note |
|---|---:|---|
| periphery/TSVSwapRouterV1.sol | 10 | 实际delta、callback、Adapter route |
| types/TSVTypes.sol | 9 | 跨组件记录与请求结构 |
| core/TSVHookV1.sol | 9 | PM门禁、context、转换调用 |
| periphery/TSVLPManagerV1.sol | 8 | 仓位、Receipt、强退、context |
| core/TSVRegistryV1.sol | 8 | 准入、暂停、Tier与计数 |
| core/TSVDataInboxV1.sol | 7 | 报告Ingress与顺序 |
| types/TSVReports.sol | 5 | 跨报告参数版本 |
| core/TSVVolumeLedgerV1.sol | 5 | 日计量、因子、日切 |
| adapters/BackedAutoFeeLegalShareAdapter.sol | 5 | 转换来源绑定 |
| governance/TSVGovernanceAnchor.sol | 4 | 根身份、恢复与冻结 |

### Security-Relevant Commits

Score为message/diff/领域关键词等加权启发式，10+适合作为人工diff优先级；不是已确认bug、修复结论或已完成diff审查。历史中已删除模块不作为当前功能列出。

| SHA | Date | Subject | Score | Key Signal |
|---|---|---|---:|---|
| 51aa98f | 2026-10-03 | feat: simplify security admission and default markets to open | 17 | rewrites access control (+1/-1)；tests同改=yes |
| ebb602e | 2026-10-01 | Update protocol sources, docs, and audit artifacts | 16 | adds runtime guards (+78/-1)；tests同改=yes |
| e5df399 | 2026-10-04 | feat(tsv): simplify governance and schedule split factors with protocol tests | 13 | adds runtime guards (+25/-8)；tests同改=yes |
| 5e78f7a | 2026-10-01 | Simplify swap hook accounting and enforce LP output bounds | 12 | changes token transfer logic；tests同改=yes |
| 868906e | 2026-10-01 | feat: remove report signature mechanism | 11 | rewrites access control (+1/-1)；tests同改=yes |
| 797e7b8 | 2026-10-01 | chore: sync TSV project updates | 10 | adds runtime guards (+4/-0)；tests同改=yes |
| c84aa50 | 2026-10-03 | feat(router): add allowlisted adapter swap entrypoint | 9 | tightens access control (+1/-0)；tests同改=no |
| 928b278 | 2026-10-02 | feat: refine TSV periphery and launch workflow | 9 | tightens access control (+1/-0)；tests同改=yes |
| f597879 | 2026-10-01 | Simplify swap accounting context | 9 | changes signature/auth handling；tests同改=yes |
| 11171f1 | 2026-10-01 | chore: establish TSV V1 repository baseline | 8 | adds runtime guards (+1189/-0)；tests同改=yes |

### Dangerous Area Evolution

以下为整commit关键词分类，可能由tests/外部文件触发，不能当作自有代码的漏洞或机制存在性；只展示与当前src关联的文件。

| Security Area | Classified commits | Current key files |
|---|---:|---|
| access_control | 13 | Registry、Inbox、Hook |
| fund_flows | 14 | Router、LP、DirectSettlementLib |
| oracle_price（keyword bucket） | 14 | Registry、Router、Types；当前ADTV是volume预算而非价格oracle |
| signatures / auth（keyword bucket） | 16 | Inbox、Reports；当前为角色报告，无签名Ingress |
| state_machines | 15 | Registry、Ledger、Anchor |

### Forked Dependencies

仅收录目录管理方式/配置元数据，不review外部代码、比较upstream差异或推断库安全性；upstream均未由脚本确认。

| Library | Path | Upstream | Status | Notes |
|---|---|---|---|---|
| TestToken | lib/TestToken | 未确认 | Internalized | 测试辅助；混合pragma |
| dexrouter | lib/dexrouter | 未确认 | Nested repository，非登记submodule | 集成辅助；混合pragma |
| dexrouter-interfaces | lib/dexrouter-interfaces | 未确认 | Internalized | ^0.8.17接口辅助 |
| soul-bound-token-1155 | lib/soul-bound-token-1155 | 未确认 | Submodule | ^0.8.29，SBT外部边界 |
| v4-core | lib/v4-core | 未确认 | Internalized | 运行辅助，目录及嵌套依赖混合pragma |
| v4-periphery | lib/v4-periphery | 未确认 | Submodule | 外部辅助，混合pragma |

### Security Observations

- **Source concentration** — src新增行100%归于zewei.lu标签，可见author统计不能替代独立review记录。
- **Current churn** — Router10次与Hook9次涉及`X-5/X-6`成交量/结算主路径。
- **Large recent source commit** — e5df399含1327行src变动且同改tests，当前Anchor/factor/day-start应按完整调用链核对。
- **Test co-change caveat** — c84aa50的Adapter功能commit没有同改tests，当前test树已有该入口覆盖。
- **Debt markers** — 当前src未发现TODO/FIXME/HACK/XXX；此事实不提高结构评级。

### Cross-Reference Synthesis

- **Router/Hook churn + actual-delta boundary** — 主路径热点与X-5/X-6重合，优先复核成交、转换及收付的组合场景。
- **e5df399 + temporal/root invariants** — factor与治理批量变更对应I-16/I-19/I-21，历史不可变与epochs应联合核对。
- **Cross-document ERC8056 drift + X-8** — 同时存在实现与陈旧准入描述，先确定每种Currency的权威单位规格与生产准入依据。

---

## X-Ray Verdict

**ADEQUATE** — 按Tests、Docs、Access Control最低项计算：测试含unit/fuzz/invariant，文档含NatSpec与规格；角色边界明确，但当前无timelock且未验证生产多签，Access Control为ADEQUATE。

**Structural facts:**
1. 已读取18个自有source文件，2491 nSLOC；枚举总计2514 nSLOC含23行interface。
2. 六个UUPS业务proxy共享固定Anchor治理根，Governor即时升级，Guardian控制升级冻结。
3. 81个test Solidity文件含373个test*与7个invariant*；本次369个本地测试通过，fork未执行。
4. src+script行覆盖率91.98%、分支85.14%；使用IR最小优化，source映射存在工具提示的精度限制。
5. 可见历史25个commit跨3天，source新增变更100%集中于一个author标签。
