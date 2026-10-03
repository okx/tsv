# TSV V1 合约编码规格

版本：1.7，2026-10-03。本文记录**当前源码 ABI**、已实现/未冻结规则，接口以 `src/v1/` 为准。交易、运营、治理流程及直接入口总览见[三系统总览](./SYSTEMS_OVERVIEW.md)。[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)是资产分类、结算能力与计股能力的规范，并集中说明 wTSLAx、未接入股数 Adapter 的 ERC-8056 测试夹具及公司行动边界；当前 V1 每侧只直接收付该侧 Currency。系统设计理由见[主架构](./CONTRACT_ARCHITECTURE.md)，未编码和未冻结之处见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。

| 位置 | 阅读方式 |
| --- | --- |
| §2–4、§5–6、§8–12 中标明“当前”的类型、入口与权限 | 现有 `src/v1/` 合约 ABI 和行为；旧 TSLAx 包装/赎回仅在明确标注的历史章节中出现，不属于当前入口 |
| §3 D-36、§5–6 直结迁移、§7 D-33/D-34、§9 D-35 及前端报价描述 | 部分已编码、部分仍待冻结；各项状态以实现缺口清单为准 |
| §7 的旧 `TradeDayReport`、SIP 窗口及必填 quota | 仅为历史评审背景；本部署没有旧 SIP 日账，不设计迁移，目标验收以[测试规格](./TEST_SPEC_V1.md)为准 |

**编码就绪边界：**D-35 GovernanceAnchor 已编码并通过本地迁移回归；日内法律股数单位切换不在 V1 支持范围，发行方必须提供足够预告并提前暂停。目标链部署和外部发行方证据仍未闭合。当前 V1 明确采用全新六代理实例组，不复用旧 Router、LP Manager、独立 Receipt 或 SBT Adapter 地址，因此不包含旧代理状态迁移算法。详见缺口清单 SPEC-01～02 和[全新部署清单](./DEPLOYMENT_CHECKLIST_V1.md)。

## 1. 范围、单位与外部依赖

- V1 每次 Swap **只经过一个 V4 PoolKey**；不提供多跳、批量 Swap、原生币、动态 LP fee、Hook fee、ERC-6909 用户余额或直接以可变余额 AutoFee 原币入池。每个成功的 PoolManager `swap` 恰有一个 Hook 成交记账过程。
- 所有池使用同一个 TSV Hook、Registry、VolumeLedger、DataInbox、Router 和 LP Manager 六个业务代理。Registry 保存唯一的 SBT 地址/tokenId 策略；LP Manager 同时提供不可转让 Receipt ERC-721。官方 PoolManager 不由 TSV 升级。Hook 的 `BEFORE_DONATE` 回调拒绝捐赠。
- Hook 代理地址低 14 位固定为 `0x3FFF`：预留 V4 的 10 个回调位和 4 个返回 delta 位，避免已建池因 `PoolKey.hooks` 地址不可改而失去后续扩展能力。**V1 行为仍不使用自定义结算**：`beforeSwap` 返回零 `BeforeSwapDelta`，`afterSwap` 返回零 `int128`，`afterAddLiquidity/afterRemoveLiquidity` 返回零 `BalanceDelta`；`beforeDonate/afterDonate` 均回滚，禁止捐赠。其余回调按本文现行门禁执行。部署脚本须以本地 `Hooks.sol` 常量重新计算并断言代理地址位型。
- Router 和 LP Manager 的直接 ERC-20 结算共用 `TSVDirectSettlementLib`；当前唯一股数 Adapter `BackedAutoFeeLegalShareAdapter` 直接调用发行方换算方法；Ledger 日期换算与 DataInbox 报告通用校验分别使用 `TradeDayLib` 和 `ReportValidationLib`。这些都是内部 Solidity 库，不引入新的代理地址。
- `IssuerShareSettlementAdapter` 与 `IAssetSettlementAdapter` 只保留在 `src/v1/legacy/`，仅由隔离的历史回归测试导入，不属于核心部署清单。
- 预留返回 delta 权限只赋予地址能力，不授权 V1 升级立即返回非零值。未来启用非零 delta 前，必须同版重设计 Router/LP Manager 的最终 `callerDelta` 结算、Hook/Ledger 的监管成交数量口径、Hook 自身欠款清算、请求边界、事件及回滚不变量，并完成独立审查与升级回归。当前 `afterSwap` 参数是 Hook 返回值影响 PoolManager 最终 caller delta **之前**的 Swap delta；直接沿用现有股数公式会错计。非零 delta 不能靠单独升级 Hook 启用。静态 LP fee、单池 Swap 和禁用 donate 的 V1 限制保持不变。
- `poolCurrency` 是 PoolKey 中的 ERC-20，也是用户直接支付/收到的资产及 Registry 主键；当前 ABI 不定义独立用户 Token 或结算 Adapter 路径。TSV 不发行 Wrapped。
- 股数账本单位 `legalSharesWad` 为 `1e18` 表示 1 股；金额字段除明确标注外均是相应 ERC-20 的**原始整数单位**。当前 `tradeDayId` 是按自动 UTC 日切计算的周期开始日 `YYYYMMDD`；不再使用 SIP 日历。链上时间为 Unix 秒。
- 外部源码固定为本仓库 `lib/v4-core`、`lib/soul-bound-token-1155`、`lib/TestToken/backed-token-contract` 的当前提交；TSV Solidity `0.8.26` 只导入本地薄接口及 V4 类型，发行方/SBT 实现分别独立编译。任何实际代理 ABI/代码与参考源码不符，资产不得准入；未登记状态为 `ABSENT`。

| 外部协议 | 编码必须遵守的本地源码事实 |
| --- | --- |
| V4 `PoolManager`/`IHooks` | `unlock` 内调用 `swap/modifyLiquidity/sync/settle/take`；Hook 原签名及地址权限位由 `Hooks.sol` 约束；`modifyLiquidity` 的 `callerDelta` 已包含本次本金与费用；零流动性零 delta 领费不可依赖 |
| `SmartWalletSbt` | `verify(owner,tokenId)` 与全局 `paused()` 必须分别读取；AA 钱包还须能接收 ERC-1155 SBT |
| Backed AutoFee/发行方 Wrapped | 底层 `balanceOf` 按 shares 与 multiplier 向下取整，`transferSharesFrom` 按显示单位消耗 allowance；Wrapped `_deposit` 从调用者拉取内部 shares，`_withdraw` 向指定接收人转出内部 shares |

## 2. 公共类型与存储主键

以下名称、顺序和整数宽度是**当前实现 ABI**。首次部署前的注册模型已移除 `AssetClass`、`LegalShareMode` 及重复比例字段：`securityId == 0` 表示非股票配对币，非零 `securityId` 表示绑定股数 Adapter 的股票资产。未部署的旧 ABI 不作为代理升级来源；首次部署后升级必须遵守存储布局约束。`PoolKey/PoolId/BalanceDelta` 使用固定 V4 类型。

```solidity
enum TokenStatus { ABSENT, APPROVED, DISABLED }
enum PoolStatus { ABSENT, PENDING, ACTIVE, DISABLED }
enum MarketStatus { OPEN, HALTED }
enum MarketAction { HALT, RESUME }
enum PauseScope { GLOBAL, SECURITY, TOKEN, POOL }
enum PauseMode { NONE, TRADE, LP, ALL } // ABI values: 0, 1, 2, 3
enum LPOperationMode { OPEN, INCREASE, DECREASE, COLLECT, CLOSE, FORCE_EXIT }

struct TokenConfig {
    address poolCurrency;
    uint8 poolDecimals;
    bytes32 securityId;              // 非股票配对币使用 bytes32(0)
    address legalShareAdapter;       // securityId == 0 时使用 address(0)
    uint32 legalAdapterVersion;
    TokenStatus status;
    bytes32 poolRuntimeCodeHash;
    bytes32 legalAdapterCodeHash;
    bytes32 poolImplementationHash;  // 非代理可为 0
    bytes32 reviewHash;
    bytes32 restrictionsHash;
    bytes32 legalSharePolicyHash;
}

struct SecurityConfig {
    bytes32 securityId;
    bytes32 symbolHash;
    uint8 tierId;
    bool listed;
    uint32 activePoolCount;
    uint32 version;
}

struct LPContext {
    bytes32 poolId;
    uint256 positionId;
    int24 tickLower;
    int24 tickUpper;
    LPOperationMode mode;
    bytes32 salt;
    int256 liquidityDelta;
}

struct LPHookContext {
    bytes32 poolId;
    int24 tickLower;
    int24 tickUpper;
    LPOperationMode mode;
    bytes32 salt;
    int256 liquidityDelta;
}
```

Registry 使用 `mapping(address poolCurrency => TokenConfig)`；不再维护用户 Token 到池内 Currency 的反向索引。`PoolId` 键保存**完整 PoolKey 结构**、两侧已冻结的 `securityId`、状态和版本。`securityId` 为不可变底层证券 ID，不从 ticker 推导。多个池内 Currency 可以映射同一 `securityId` 并共享额度。**PoolKey 两侧 `securityId` 只要同时非零，登记待初始化池就失败**；该限制不区分证券是否相同。

**首次部署与后续升级：**V1 当前尚未在目标链部署，本次注册 ABI 精简在首次部署前完成；此前未部署的源码 ABI 不需要迁移兼容。首次部署后，六个代理的后续实现升级必须通过存储布局检查，不得删除或重排已部署的字段。V1 首次部署不迁移旧 wTSLAx 条目、LP 仓位或旧账本。

**当前实现的准入组合如下；完整业务门槛以[新版准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)为准。**首次证券准入由 `SYMBOL_ADMIN` 调用 `admitSecurity(bytes32 securityId, bytes32 symbolHash, uint8 tierId, TokenConfig config, bytes32 evidenceHash)`，同笔登记证券、预留唯一符号与 Tier 名额、批准首个 Currency；要求证券 ID 与配置一致。任何校验失败均回滚，移除独立首次证券登记入口。`registerToken(TokenConfig, bytes32 evidenceHash)` 同样仅 `SYMBOL_ADMIN`，用于报价 Currency 或已有上市证券新增 Currency，登记即批准。两个入口只接收一个非零且有代码的池内 Currency 地址，输入状态必须 `APPROVED`、`reviewHash` 必须非零，`poolDecimals` 须等于 ERC-20 `decimals()` 实测值且不超过 18；合约核对池内 Currency 和非零股数 Adapter 的代码哈希。结算固定为 Router/LP Manager 对实际池内 Currency 直接执行 raw ERC-20 收付，ABI 不接受结算模式、版本、Adapter 或用户 Token 字段。

非股票配对币要求 `securityId == 0` 且不绑定股数 Adapter；股票要求 `securityId != 0`、证券已上市、Adapter 已部署且代码哈希匹配、Adapter 版本从 1 开始、`legalSharePolicyHash != 0`。Registry 通过 ERC-165 检查 `IDirectLegalShareAdapter`，并核对其 `poolCurrency()` 与 `adapterVersion()`；Registry 不读取、缓存或验证实时换算结果。换算公式及参数来源由经审查的 Adapter 定义。代理 `implementationHash` 是链下审查证据，链上不能读取另一合约的 ERC-1967 存储槽；运维监测实际实现变化。

准入发出 TokenRegistered 和 ABSENT→APPROVED 的 TokenStatusChanged；`admitSecurity` 先发出 SecurityListed。Token 状态只允许准入时 `ABSENT→APPROVED`，随后 `APPROVED↔DISABLED`，禁止将已登记 Token 设置为 ABSENT；重新批准必须附新审查依据。停用、恢复和股数 Adapter 更新都发事件。转入 `APPROVED` 时要求非零 `reviewHash`、`evidenceHash`；其哈希证明文件本身由链下评审，合约不推断法律真实性。只有 `APPROVED` 可用于新 Swap/用户 LP。`DISABLED` 保留配置供原 owner 强退。

**当前实现的替换入口：**当前 ABI 没有结算 Adapter 替换入口。更换法定股数 Adapter 仍要求暂停、版本递增和历史成交不重算。现有 Backed Adapter 每次转换都调用发行方 `getUnderlyingAmountByShares(rawShares)`，因此发行方方法所采用的实时 multiplier 会直接体现在该笔成交的计股结果中。Token 代理实现、制裁权限或关键规则变化时先停用，再复核恢复。

### 2.1 资产实例说明

资产实例、测试夹具及 wTSLAx 的准入结论统一见[代币准入标准 §6–7](./TOKEN_ADMISSION_STANDARD_V1.md#6-tesla-实例tslax-与-wtslax)；本编码规格只定义通用 ABI、字段和算法。验收夹具及其预期行为见[测试规格 §2](./TEST_SPEC_V1.md#2-公共-fixture-与状态快照)。

## 3. 法定股数 Adapter

当前唯一股数换算接口是 `IDirectLegalShareAdapter`：`poolCurrency()`、`adapterVersion()` 和 `toLegalShares(address currency,uint256 rawAmount)`。它不携带 rate、nonce、快照或反向换算参数。Registry 注册/替换时通过 ERC-165 验证接口声明，并检查 Adapter 绑定 Currency 和版本；Hook 在 `afterSwap` 取得真实股票腿 delta 后，调用 `toLegalShares`，再把换算结果和两个真实 delta 一起传给 Ledger。Ledger 只接受固定 Hook 写入，检查非股票侧为零、股票侧换算结果非零、Registry 中证券和 Adapter 元数据匹配，再执行当日额度记账。对正 raw 成交，换算结果为零、外部换算调用 revert 或结果溢出时，整笔交易回滚。Registry 对 Adapter 的转换逻辑不做形式化验证；Adapter 代码、来源 Token 的方法、法律计量定义和 gas 必须在准入审核中确认。

**当前唯一实现：**`BackedAutoFeeLegalShareAdapter` 绑定发行方来源 Token 与池内 Wrapped Currency；构造时要求 Wrapped `asset()` 等于来源 Token，双方 `decimals() == 18`。每次 `toLegalShares` 调用都执行来源 Token 的 `getUnderlyingAmountByShares(rawShares)`。因此适配器不复制 multiplier 公式，也不缓存参数快照；成交采用该源方法在本次回调时返回的值。wTSLAx 场景中的源码实现为 `floor(wrappedShares × currentMultiplier / 1e18)`，但股数口径是否得到发行方与法务认可仍是生产准入条件。零 raw 输入返回零，正 raw 若来源方法返回零则回滚。其他 Adapter 实现不属于当前 V1 代码；新增发行方适配器应在单独评审后扩展。

前端展示用户当前持有股数时，仍须按发行方批准的**账户权益**规则读取与计算。当前接口不提供从 legal shares 反算 raw Token 数量的函数；前端报价与 `SwapRequest`/`LPBounds` 继续使用 raw 数量。法律股数单位切换仍须暂停整个 `securityId`，按[准入标准的公司行动流程](./TOKEN_ADMISSION_STANDARD_V1.md)等待新单位 ADTV/quota 就绪后恢复，不能把新旧单位混入同一日额度。

股票输入腿取 PoolManager caller `BalanceDelta` 的绝对含费总支出，输出腿取净收到量；准入池每笔 Swap 最多一条股票腿，按其实际方向计股。LP 操作和 `take/settle` 不调用成交记账。每笔 `legalSharesWad` 必须大于零，历史日累计量不因 multiplier、Adapter 或 Tier 后续变化而重算。

## 4. 旧资产结算 Adapter 与目标直结

以下 `IAssetSettlementAdapter` 是**历史结算 Adapter 的源码参考**，不属于当前 V1 Swap/LP ABI。它只用于理解旧代码和维护独立回归测试；当前 `TokenConfig` 不包含 `ISSUER_SHARE_WRAPPED` 结算模式或独立用户 Token 字段，Router/LP Manager 不调用包装、赎回或底层 shares 转移。本部署没有需要兼容的旧仓位：

```solidity
function userToken() external view returns (address);
function poolCurrency() external view returns (address);
function pullAndWrap(address owner, address receiver, uint256 shares, uint256 maxDisplayedDebit, bytes32 operationId)
    external returns (uint256 wrappedDelivered);
function prepareReceive(uint256 shares, bytes32 operationId) external;
function redeemAndDeliver(address recipient, uint256 shares, uint256 minDisplayedCredit, bytes32 operationId)
    external returns (uint256 sharesDelivered);
```

历史 `IssuerShareSettlementAdapter` 部署时不可变地绑定 TSLAx、发行方 wTSLAx、Router 和 LP Manager；它有三个写入口：`pullAndWrap`、`prepareReceive` 和 `redeemAndDeliver`，分别负责旧入金包装和旧出金的准备/赎回。Adapter 通过 `IActiveAssetOperation` 从 Router/LP Manager 读取当前操作上下文，核对 `operationId`、owner/recipient、份额和余额基线，不能只相信调用者传参；该上下文读取接口由 Router/LP Manager 提供，不是 Adapter 自身实现。旧单元测试还核对底层 `transferSharesFrom`、Wrapped `mint/redeem`、内部 shares、显示余额、allowance 和非重入边界。任何外部发行方调用或精确余额检查失败，整笔旧路径回滚。本段只描述历史源码，当前 Registry、Router 和 LP Manager 不会到达它。

旧出金时入口先调用 `prepareReceive(shares,operationId)` 保存 Wrapped/底层 shares 余额基线，入口再让 PoolManager `take` 准确 `shares` 个 Wrapped 到 Adapter，最后由 `redeemAndDeliver` 调用发行方 `redeem` 并核对 recipient 内部 shares、Wrapped 供应和显示余额变化。强退的 recipient 固定为历史仓位 owner；失败时整个旧外层交易回滚。当前新路径不执行这些步骤。

新 Swap 和 LP 操作都直接结算池内 Currency，不经过包装或赎回 Adapter。每笔入金同时核对付款人准确减少、PoolManager 准确增加及 `settle()` 返回值；出金同时核对 PoolManager 准确减少与最终收款人准确增加，任何发送方额外扣费、接收方少收、rebase 或异常返回都回滚。本地故障币回归覆盖发送方额外扣费；固定依赖与目标网络验收仍见[安全评审 F-05](./reviews/SECURITY_REVIEW_2026-09-30.md)。

## 5. Swap ABI、调用约束与 Hook

**本节结构体与下列步骤描述当前代码。**Router 提供用户直连 exact-in/exact-out，以及外部白名单 Adapter 代用户发起的 exact-in。两条路径都按一个 PoolKey 的 raw 金额执行；旧 TSLAx 包装分支不属于当前能力。

```solidity
struct SwapRequest {
    PoolKey key;
    bool zeroForOne;
    uint128 amountSpecified;   // V4 输入/输出 Currency 的原始单位；须 <= int128.max
    uint128 limitAmount;       // exact-in 为最小输出；exact-out 为最大输入
    uint64 deadline;
}

function swapExactInput(SwapRequest calldata request)
    external returns (uint256 actualIn, uint256 actualOut);
function swapExactOutput(SwapRequest calldata request)
    external returns (uint256 actualIn, uint256 actualOut);

function swapExactInputFromAdapter(SwapRequest calldata request, address participant)
    external returns (uint256 actualIn, uint256 actualOut);
function setAdapterAllowed(address adapter, bool allowed) external; // only Governor
```

用户直连入口由函数本身决定 exact-in 或 exact-out 模式；participant、payer 和 recipient 均为 `msg.sender`。Adapter 入口复用同一个 `SwapRequest`，只允许 `isAdapterAllowed[msg.sender]` 为真的调用方，Router 对 `participant` 检查 SBT 资格，但从 Adapter 拉取输入并把输出交给 Adapter；Adapter 再按外部 DexRouter 传入的 hop 收款地址转发输出。三个入口都不接受调用方指定价格边界；Router 按 `zeroForOne` 设置 V4 全范围边界。Adapter 入口的身份可信度依赖已审查并加入白名单的 Adapter 正确解析外部 DexRouter caller marker；不要把 `ORIGIN_PAYER` 退款地址当成 SBT 身份。Adapter exact-input 的 `amountSpecified` 须来自 DexRouter 追加的实际 hop 转账量，不能从 `moreInfo` 或 Adapter 总余额猜测。用户直连入口仍不接受第三方代提交或用户签名，也不提供应用层请求 nonce。

`amountSpecified > 0` 且不超过 `int128.max`；`limitAmount > 0`；deadline 未过。准入池最多一侧为股票，两种池内 Currency 的普通滑点由 `limitAmount` 约束。

Adapter exact-input 请求中的 `amountSpecified` 和 `limitAmount` 分别表示输入量与最小输出量，同样使用池内 Currency 的 raw 单位，二者均须大于零，且 `amountSpecified <= int128.max`；`deadline` 不得早于当前区块时间。完整字段和 ABI tuple 见[外部接入说明](./EXTERNAL_DEX_ROUTER_ADAPTER_TSV_INTEGRATION.md)。

执行顺序固定如下：

1. Router 非重入。用户直连时检查 `msg.sender` 的 SBT 资格；Adapter 入口先检查调用 Adapter 白名单，再检查 Adapter 传入的 participant 资格。两条路径均检查池是否可交易、金额边界和 deadline。完整 PoolKey 的精确匹配由 Hook 的 `beforeSwap` 检查；Registry 的 `isTradable(poolId)` 让无效池在进入 unlock 前快速失败。Router 按 `zeroForOne` 为所有入口设置 V4 全范围价格边界。
2. Router 调用 `PoolManager.unlock(abi.encode(request, settlementParticipant, exactInput))`。用户直连时 `settlementParticipant == msg.sender`；Adapter 路径中 `settlementParticipant == msg.sender`，即白名单 Adapter。`unlockCallback` 只接受 PoolManager 且要求 Router 非重入锁处于活跃状态，然后解码本次 unlock 携带的数据并执行一次 `swap`；资格、可交易池和请求参数已在进入 unlock 前检查。`hookData` 为空；Router 的非重入状态保证同一时刻只有一笔活跃 Swap，不另存 Swap 上下文。
3. Hook 的 V4 回调 ABI 严格使用本地 `IHooks.sol` 原签名，所有回调只接受 PoolManager。`beforeSwap` 要求 `sender == Router`、空 `hookData`、池可交易且 PoolKey 与 Registry 配置完全一致；SBT 资格由 Router 在进入 unlock 前检查。Hook 不为 Swap 保存状态，也不读取 Router 活跃上下文。`afterSwap` 保留 `sender == Router` 和空 `hookData` 检查，从实际 `BalanceDelta` 获取两侧 raw 成交量，对股票腿即时调用 Registry 绑定的 Adapter `toLegalShares`，将直接换算出的 shares 与真实 delta 一并交由 Ledger 原子记账；配对币使用零 shares 且不调用股数 Adapter。Ledger 按 Registry 身份及已配置 Adapter 元数据核验输入并记账，不再读取 Adapter 或重复换算。Hook 返回零 delta 与零费率覆盖。其他人直接调用 PoolManager 的 swap/modify/initialize/donate 全部被 Hook 拒绝。
4. Router 对实际 delta 再验 `actualIn > 0 && actualOut > 0`。exact-in 要求 `actualIn <= amountSpecified && actualOut >= limitAmount`；exact-out 要求 `actualOut == amountSpecified && actualIn <= limitAmount`，任何部分成交回滚。输入 `inDelta` 为 `int128.min` 时，在结算前以 `InputAmountTooLarge()` 拒绝，因为其绝对值 `2^127` 无法用 PoolManager 的 `int128` 结算边界表示。按**实际**负 delta 从 `settlementParticipant` 拉取对应 Currency，按实际正 delta `take` 给同一地址；直连时该地址是用户，Adapter 路径时是 Adapter。两侧均核对发送方扣减、PoolManager 余额变化、接收方增加和 `settle()` 返回值。
5. `unlockCallback` 返回后 Router 读取当前交易日并完成事件记录。Ledger 已在 `afterSwap` 记账时读取并校验交易日；Router 不在 unlock 前额外预查。成交换算和额度记账均在 `afterSwap` 完成，后续 Router 直接结算 raw Currency，不再读取或复验换算参数。当前路径没有包装、赎回、底层 shares 转移或其他结算分流。

**当前结算路径。**Registry 只登记实际池内 Currency。用户直连入口通过 `TSVDirectSettlementLib` 与 raw `amountSpecified/limitAmount` 直接结算；Adapter 入口仅提供 exact-in，此时 `amountSpecified/limitAmount` 分别表示输入量/最小输出量，Router 从白名单 Adapter 拉取输入并将输出返给 Adapter。Adapter 在调用前须为输入批准 TSV Router，并只向外部 DexRouter 的 hop `to` 转发本次新增输出。两条路径每次均核对发送方恰扣、接收方恰增。旧 `IssuerShareSettlementAdapter` 与接口仅在 `src/v1/legacy/` 保留，供隔离单元测试对照，不参与新 Swap。

Swap 成功时发出 `SwapExecuted`，其 `participant` 是直连用户或 Adapter 声明并通过资格检查的交易用户；Adapter 路径额外发出 `AdapterSwapExecuted`，同时记录 Adapter 地址。Governor 修改 Adapter 白名单时发出 `AdapterAuthorizationUpdated`。Hook/Ledger 的 `SwapAccounted` 对每个股票腿分别记录 `securityId,poolCurrency,inputSide,rawAmount,legalSharesWad,legalAdapterVersion`。交易哈希与 logIndex 由索引器取链上 receipt，不写进合约事件。

**前端股数展示与 Swap 报价。**前端从 Registry 读取该股票 Currency 当前绑定的 Adapter 与版本，并按发行方批准的账户权益规则显示用户持有股数。当前 Adapter 接口不提供 raw 与法律股数的通用反向报价；`SwapRequest.amountSpecified`、`limitAmount` 和 deadline 使用 raw 数量，V4 价格边界由 Router 内部按方向设置。账户总持仓的舍入可能不同于单笔成交换算，尤其是 TSLAx，前端须分别展示。V1 Router 无股数输入参数；报价后价格、余额或发行方转换结果变化可能改变实际股数，链上只保证提交的 raw 与结算边界。Hook 在 `afterSwap` 按实际股票腿 delta 调用 Adapter 并计入 VolumeLedger，前端估值不写入额度。

## 6. LP、Receipt 与强退

以下 LP 操作入口和参数构成重构后的 V1 部署 ABI；LP Manager 代理也作为 Receipt ERC-721 地址。本版本是全新 V1 实例组：Router/LP Manager 初始化参数已冻结为新 ABI，独立 SBT Adapter、Receipt 代理不再部署，旧实例地址不得复用。全新部署完成后，六个业务代理的后续 UUPS 升级仍必须遵守追加存储和布局检查规则。部署顺序与地址绑定见[全新部署清单](./DEPLOYMENT_CHECKLIST_V1.md)。

```solidity
struct LPBounds {
    uint256 maxPoolIn0;
    uint256 maxPoolIn1;
    uint256 minPoolOut0;
    uint256 minPoolOut1;
    uint64 deadline;
}
function initializePool(PoolKey calldata key, uint160 sqrtPriceX96, bytes32 priceBasisHash) external;
function openPosition(PoolKey calldata key, int24 tickLower, int24 tickUpper, uint128 liquidity, LPBounds calldata bounds)
    external returns (uint256 positionId);
function increaseLiquidity(uint256 positionId, uint128 liquidity, LPBounds calldata bounds) external;
function decreaseLiquidity(uint256 positionId, uint128 liquidity, LPBounds calldata bounds) external;
function collectFees(uint256 positionId, LPBounds calldata bounds) external;
function closePosition(uint256 positionId, LPBounds calldata bounds) external;
function forceExit(
    uint256 positionId,
    uint256 minPoolOut0,
    uint256 minPoolOut1,
    bytes32 reasonCode,
    bytes32 evidenceHash
) external;
```

建池仅 `POOL_CREATOR`，要求 `key.hooks == Hook`、`currency0 < currency1`、两侧都有已批准 TokenConfig、`0 <= key.fee < 1_000_000` pips 且 `1 <= key.tickSpacing <= 32767`；拒绝 V4 动态费率哨兵与 100% LP fee。Registry 先标记 PENDING，LP Manager 调用 PoolManager `initialize`，Hook 只允许来自 LP Manager 的准确 PoolKey，成功后 Registry 改为 ACTIVE；任一失败全部回滚。初始价格由 POOL_CREATOR 提交，只校验 V4 范围；`priceBasisHash` 只用于审计。

`positionId` 从 1 单调递增，V4 salt 直接取 `bytes32(positionId)`；在同一 LP Manager 内 positionId 唯一，且 V4 仓位键还包含 manager、PoolKey 和 ticks。每次 LP 操作在 `PoolManager.unlock` 前保存活跃 `LPContext`，并保存完整 `ModifyRequest` 的 `activeRequestHash`；unlock data 是该请求编码，LP `modifyLiquidity` 的 `hookData` 为空。PoolManager 回调要求调用者为 PoolManager、Manager 正处于非重入操作中、活跃 positionId 非零，并核对 unlock data 哈希后才解码和结算。Hook 通过无参 `activeLPContext()` 读取只含自身校验所需字段的 `LPHookContext`，并将 poolId、PoolKey、ticks、salt、liquidityDelta 与 V4 参数逐项比对；`beforeAddLiquidity/beforeRemoveLiquidity` 再按模式限制增加或移除，强退只允许全额负 delta。操作成功后 Manager 清除活跃上下文与请求哈希；任何回滚会原子恢复状态。这里不使用 LP operationId 或 nonce。仓位保存不可变 owner、PoolKey、ticks、salt，流动性严格为正。LP Manager 内置 Receipt ERC-721，tokenId 等于 positionId，mint/burn 仅由 LP 生命周期内部执行；所有转移和授权入口回滚。用户 LP 操作仅允许 `msg.sender == position.owner == ownerOf(positionId)` 且 Registry 的共用 SBT 当前有效、未暂停；无资格回滚 `Unauthorized()`，`isLPAllowed(poolId)` 为 false 时回滚 `InvalidPool()`。强退例外见下段。

Position ID 的唯一性范围是单个 LP Manager 代理，跨链或跨代理索引使用 `(chainId, managerProxyAddress, positionId)`。成功关闭或强退后 ID 不复用；开仓失败时计数器、Receipt 与 V4 状态一起回滚；uint256 计数溢出会回滚。兼容布局的升级保留计数器，初始化不能重复执行。对应 8 项真实 V4 验证见 `test/integration/local/TSVPositionIdLocal.t.sol`。

所有 LP 操作验证 deadline、tick 间隔、`0 < liquidity <= int128.max`（需要非零 liquidity 的操作）和 PoolManager 返回的**实际** `callerDelta`；`maxPoolIn* / minPoolOut*` 是两种池内 Currency 的原始单位边界。若输入 delta 为 `int128.min`，Manager 在 ERC-20 转账前以 `InputAmountTooLarge()` 拒绝，因为其绝对值 `2^127` 超出 PoolManager 可结算的正 `int128` 范围。强退调用方必须传入两侧 raw `minPoolOut`，合约逐侧校验，具体下限由运营按执行时策略设置；若任一侧不足则整笔回滚并保留仓位。正流动性变化用 V4 `modifyLiquidity(+liquidity)`，减仓用负值；所有实际负 delta 直接从原 owner 拉取对应 Currency，正 delta 直接交付同一 Currency 给原 owner，并核对双方准确余额变化。`openPosition` 在同笔结算成功后 mint Receipt；`increaseLiquidity` 增加账本流动性；`decreaseLiquidity` 的 `liquidity < current` 且剩余严格为正；`collectFees` 只在 OPEN 且正流动性时使用 V4 零 delta，任一负 delta 都拒绝、若两侧实际领取均为零也回滚；`closePosition` 一次负 delta 清空流动性，直接用该次包含费用的 `callerDelta` 结清、交付并 burn Receipt，不再调用零 delta。wTSLAx 与普通 ERC-20 完全共用这条直接结算路径，不调用包装/赎回 Adapter。

`forceExit` 仅 `REVOKE_EXIT_EXECUTOR` 或 `FORCE_EXIT_ADMIN`。前者还须在执行当时确认原 owner 的 SBT 凭证**已缺失**；仅 SBT 全局 paused 不算撤销。后者须传非零 reason/evidence。LP Manager 在 unlock 前设置当前操作上下文并将模式设为 `FORCE_EXIT`，Hook 只允许与该上下文匹配的全额 remove；普通暂停、HALT、报告缺失或 Token DISABLED 不阻止该路径。所有应收资产只能交付仓位原 owner，调用者无 recipient 参数。两侧 Currency 均直接交付原 owner，并核对双方准确余额变化；force-exit 的任意负 delta 在转账前拒绝。两侧全部成功后关闭仓位并 burn Receipt；任何拒转整体回滚，仓位与 Receipt 保留。失败交易不产生持久失败事件，链下按失败 receipt 告警，沿用方案 A。本部署没有旧仓位，因此不定义旧 Adapter 退出分支。

**前端股数展示与 LP 报价。**当前 Adapter 不提供从用户股数预算反算股票 Currency raw 数量的通用接口。前端须使用发行方认可的账户权益定义及具体 Token 的报价逻辑估计所需 raw 数量，再结合当前 V4 价格、tick 范围和另一侧资金预算估计 `liquidity`；开仓和加仓仍提交现有 `openPosition`／`increaseLiquidity` 与 raw `LPBounds`。减仓、关仓和领费时，前端按预计 raw 到账展示对应股数，提交现有流动性参数和 raw 到账下限。报价只是估计，实际 LP `callerDelta` 还可能包含已累积手续费；价格、发行方转换结果或账户余额变化后，实际显示股数可能变化，raw 边界不等于链上股数保证。LP Manager 不增加股数驱动入口，LP 操作也不调用 `recordSwap` 或占用成交额度。

## 7. 角色报告、计量日和额度

**当前规则：**旧 SIP 日历、`TradeDayReport`、窗口追加/替换和逐日必填 quota 均不属于当前 ABI，仅在历史评审资料中保留。当前 DataInbox 接受 `MarketReport`、单条 `AdtvReport`、批量 `AdtvReport[]` 和带 `action` 的 `QuotaReport`；报告不使用 EIP-712、签名或任意 relayer 代提，`msg.sender` 必须直接持有对应的 `HALT_REPORTER_ROLE` 或 `VOLUME_ORACLE_ROLE`。`sequence`、`reportId`、`sourceTimestamp` 和 `submitDeadline` 仍用于顺序、去重、来源审计和提交时限，不是签名机制。Swap 由 participant 直接调用 Router。当前计量日由 VolumeLedger 根据 UTC 起点自动计算，不需要提交日历，也不需要心跳交易。

月度 ADTV 使用 `submitAdtvBatch(AdtvReport[] reports)` 批量入口。一个批次内所有报告必须属于同一 `sourceMonth`，`securityId` 必须按严格递增顺序排列且不得重复，批次长度为 `1..MAX_ADTV_BATCH_SIZE`（当前为 100），且整批由当前 `msg.sender` 以 `VOLUME_ORACLE_ROLE` 直接提交。批次采用全有或全无语义：任一报告无效，整笔交易回滚，不留下已接受的 ADTV、序号或 reportId。75 个证券的月度 ADTV 可由一笔批量交易提交；单条 `submitAdtv` 继续用于补发和纠错。批量提交不改变单报告的版本、序号、来源时间或截止时间规则。

**D-33：日配额是可选整日覆盖；当前 `src/v1/` 已实现以下规则。**当前 ABI 使用 `action` 字段；`VOLUME_ORACLE_ROLE` 地址直接提交：

1. 对每个 `(securityId,tradeDayId)` 保存 `QuotaOverride { uint256 quotaWad; bool active; uint64 version; bytes32 reportId; }`。从未提交、或已显式清除覆盖时，`active=false`；不能用 `quotaWad == 0` 判定 ADTV 缺失。新 TSV 计量日默认没有覆盖，不继承前一日状态。
2. `QuotaReport` 增加 `uint8 action`，只允许 `SET=1` 或 `CLEAR=2`。Solidity 字段顺序为 `bytes32 securityId,uint32 tradeDayId,uint8 action,uint256 quotaWad,uint64 sourceTimestamp,uint64 submitDeadline,uint64 version,uint64 sequence,bytes32 reportId,bytes32 sourceHash`；没有 `signer` 字段或签名参数。`SET` 要求证券已登记、该日所需 ADTV 已存在、`0 < quotaWad <=` 提交时的硬上限；`CLEAR` 要求原覆盖处于 active 且 `quotaWad == 0`。两者都要求该 key 的 version 严格加一、报告 ID 唯一、报告来源序号递增，发出包含 action、值、版本、reportId 的事件。不能把零配额当作暂停；暂停仍走 §8。
3. 每次 Swap 必须有按 D-34 自动算出的当前计量日、适用 ADTV、有效股票资产和已初始化且未暂停交易的市场状态。`hardCapWad == 0` 时拒绝；当日 `active=false` 时 `effectiveCapWad=hardCapWad`，否则 `effectiveCapWad=min(hardCapWad,quotaWad)`。要求 `usedWad[securityId][tradeDayId] + legalSharesWad <= effectiveCapWad`；`remaining` 在无覆盖但 ADTV 有效时返回有效及 `max(0,hardCapWad-usedWad)`。同日 SET/CLEAR 从成功提交交易之后影响后续 Swap，不修改已计成交或已用量；低于已用量时后续 Swap 失败。
4. 同一计量单位内，ADTV/Tier 更正后始终重新计算硬上限并取 `min`，既有覆盖值不能使有效上限超过新硬上限；上调硬上限不会自动解除较低的覆盖值。公司行动改变股数单位时仍须先暂停并执行[准入标准的单位切换流程](./TOKEN_ADMISSION_STANDARD_V1.md)，不能拿不同单位的数值取 `min`。
5. 本版 `DataInbox` 完全移除报告签名机制。升级时必须同步切换 ABI、角色运营脚本、索引器和 Ledger；旧版待提交的签名报告不再有入口，已接受的 `reportId`、序号和账本状态保持不变。D-34 同版移除日历报告依赖。

**D-34：每个日期都是独立 TSV 计量日，日切点按未来排期更新；当前 `src/v1/` 已实现以下规则。**

1. 初始配置 `dayStartOffsetSeconds` 是部署清单中的 `uint32`，范围 `0..86399`；示例为 `14400`，即 UTC 04:00。配置在 Ledger 初始化时设置，禁止未初始化或超范围值。`tradeDayId` 是周期**开始时的 UTC 公历日期** `YYYYMMDD`，不是成交所在 UTC 自然日期，也不再表示外部 SIP 归属日。所有公历日期，包括周末和节假日，都有自己的 ID、额度和 `usedWad`。时间区间左闭右开，链上以 `block.timestamp` 判定；不引入本地时区或夏令时。
2. 对 UTC 日期 D，定义 `midnightUTC(D) = ordinal(D) * 86400`，`startUTC(D) = midnightUTC(D) + offsetFor(D)`，`endUTC(D) = startUTC(D+1)`。`offsetFor(D)` 为最大 `effectiveDayId <= D` 的已排期配置值，若无则为初始值。设 `N = UTCDate(block.timestamp / 86400)`；若 `block.timestamp >= startUTC(N)`，当前 `tradeDayId=N`，否则为 N 的前一日期。实现须使用覆盖闰年、月末、年末的公历整数转换，校验日期范围；不能直接把 Unix 日数强转成 `YYYYMMDD`。Ledger 在一次记账中计算日 ID，并用于额度、ADTV 源月及可选配额；Router 在 unlock 完成后再次读取当前日，仅用于 Swap 事件。`sourceMonth` 是 Ledger 所用 ID 所在月的上一自然月。`currentTradeDay()` 可保留现有 `(bool,uint32)` ABI，但初始化后的 `exists` 恒为 true，不再要求当前／下一窗口。
3. 治理入口 `scheduleDayStart(uint32 newOffsetSeconds,uint32 effectiveDayId,bytes32 reasonHash)` 只允许当前业务 Governor；`newOffsetSeconds < 86400`、`newOffsetSeconds != oldOffsetSeconds`、`abs(newOffsetSeconds - oldOffsetSeconds) <= 14400`、`reasonHash != 0`。初始起点可设为任意 UTC 日内秒数，**运行中每次最多变更四小时**。只允许一个待生效配置；新 `effectiveDayId` 必须晚于最后一次生效日，并且排期交易发生时，`effectiveDayId` 的前一个计量日按**当前已排期规则**尚未开始。Ledger 用链上公历算法算出前一日的开始时刻并要求 `block.timestamp < startUTC(D-1)`。不得排期使当前或过去计量日的开始/结束改变。事件记录旧/新秒数、D、过渡日 ID、过渡日新结束 UTC、操作者与 `reasonHash`。生效只看区块时间，无额外激活交易。
4. 排期一次由旧起点 `oldOffset` 改到 `newOffset` 时，只有 D-1 是过渡日，长度精确为 `86400 + newOffset - oldOffset` 秒，且在 20–28 小时范围内；此前及 D 以后均为 86400 秒。治理可在 D-1 开始**之前**取消这次尚未生效的排期并发出取消事件；D-1 一旦开始，配置锁定，不能取消或替换。生效后可为更晚日期排下一次变更；历史配置和计量日边界须永久可读。对查询日 D 的配置按生效日有序检查点选择，不能以后一次配置重算历史。较长或较短的过渡日仍只有**一份完整日硬上限**，不得按小时比例放大或缩小；已提交的 D-1/D 配额继续按原日 ID 生效，运营方在排期时复核。
5. 当前实现已移除 `TradeDayReport`、`DAY_TYPEHASH`、`submitTradeDay`、`replaceFutureWindows`、`appendWindow`、`windowCount/getWindow` 以及旧 Ledger 的窗口门禁。`DataInbox` 仅处理 Market、ADTV、Quota 三类报告。由于本部署没有旧 SIP 日账，部署直接初始化自动日切状态，不实现旧窗口到账本的历史转换；新 ABI、角色运营脚本、索引器和部署清单必须一起发布。

当前 Ledger 日切 ABI 与事件为：

```solidity
struct DayStartCheckpoint { uint32 effectiveDayId; uint32 offsetSeconds; bytes32 reasonHash; }
function scheduleDayStart(uint32 newOffsetSeconds, uint32 effectiveDayId, bytes32 reasonHash) external;
function cancelPendingDayStart(bytes32 reasonHash) external;
function dayStartUTC(uint32 dayId) external view returns (uint64);
function initialDayStartOffsetSeconds() external view returns (uint32);
function dayStartCheckpointCount() external view returns (uint256);
function dayStartCheckpoint(uint256 index) external view returns (DayStartCheckpoint memory);
function currentTradeDay() external view returns (bool exists, uint32 tradeDayId);
event DayStartScheduled(uint32 indexed effectiveDayId, uint32 indexed transitionDayId, uint32 oldOffsetSeconds, uint32 newOffsetSeconds, uint64 effectiveStartUTC, address indexed operator, bytes32 reasonHash);
event DayStartCancelled(uint32 indexed effectiveDayId, address indexed operator, bytes32 reasonHash);
```

`cancelPendingDayStart` 仅允许当前业务 Governor、非零原因哈希，且待生效配置的 D-1 尚未开始；取消后最后一个有效检查点仍用于后续计算，已生效检查点不可删除。检查点按生效日递增存储，查询可用二分搜索，当前交易日读取不得线性遍历全部历史变更。`dayStartUTC` 对非法公历日期或超出可表示范围回滚。`dayStartCheckpoint` 返回已生效及待生效的有效检查点，不返回已取消项；取消事件保留审计记录。初始 offset 通过单独 getter 暴露，且不依赖后续治理事件重建。

**当前代码**的 `VolumeLedger.recordSwap(poolId,delta0,delta1,legalShares0,legalShares1)` 只允许固定 Hook 调用。Ledger 从 Registry 读取两侧 Currency、securityId 和 Adapter 元数据；非股票侧必须传入零 shares，股票侧必须传入非零 shares，并验证 Token 的证券、Adapter 地址及版本配置。Adapter 的转换函数只由 Hook 在本回调之前调用，Ledger 信任固定 Hook 传来的 shares，不再读取或执行 Adapter。Ledger 从区块时间和日切检查点确定计量日，读取适用 ADTV 与可选 quota 覆盖，并要求 `used + charge <= effectiveCapWad`。源码逐侧处理 delta，但 Registry 建池门禁使双股票分支不可用于新池。任一必需输入缺失、交易停牌、交易暂停、零股或超额，整笔交易回滚。Ledger 不向 DataInbox 提供写 `used` 的入口。

## 8. 暂停与准入状态

暂停模式为 `TRADE=1`（仅交易）、`LP=2`（全部普通 LP）、`ALL=3`（交易和 LP）。`NONE=0` 只表示无市场暂停，不能作为暂停/恢复请求模式。普通 LP 包括开仓、加仓、减仓、领取手续费和关闭仓位。Router、Hook Swap 和 VolumeLedger 使用 `isTradable(poolId)`；LP Manager 与 Hook LP 使用 `isLPAllowed(poolId)`。单项暂停允许另一类操作通过暂停门禁，其他资产、池、证券和 SBT 准入仍须满足。

紧急暂停记录以递增 `recordId` 为主键，保存 `scope,target,mode,reasonCode,sourceHash,openedBy,openedAt,active`；`GLOBAL/SECURITY/TOKEN/POOL` 目标分别是零、securityId、Token 地址、PoolId。`EMERGENCY_PAUSER` 新增记录，`EMERGENCY_RESUMER` 关闭指定仍活跃记录；`activePauseCount(scope,target,mode)` 返回该精确模式的活跃记录数。交易检查 TRADE 或 ALL，LP 检查 LP 或 ALL；命中的记录叠加生效，关闭一条不会关闭其他记录或解除市场暂停。

`MarketReport` 在 `action` 后新增 `PauseMode mode`，DataInbox 调用 `applyMarketStatus(securityId,action,mode,sequence,reportId)`。新证券准入后默认 NONE/OPEN，不再提交首次开市报告。MarketAction 仅 HALT=0、RESUME=1；首份报告可直接 HALT。HALT 按位叠加指定模式，RESUME 只清除指定模式；不产生状态变化的报告回滚，报告序号和去重状态也回滚。`marketPauseMode(securityId)` 保存当前模式，`marketStatus(securityId)` 从该模式推导，任一位暂停时市场为 HALTED，全部恢复时为 OPEN；未知证券查询回滚，下架证券仍由 listed 门禁阻断，重新上市不清除暂停或报告序号。不再保存重复的市场状态映射。例如 TRADE → HALT LP → ALL → RESUME TRADE → LP → RESUME LP → NONE/OPEN。模式改变时即使市场仍为 HALTED，也发出带旧/新模式的 MarketStatusChanged。暂停不会因报告年龄自动恢复。

缺适用 ADTV 会阻止 Swap，日切自动发生，quota 可选；Token/Pool DISABLED 和外部 SBT paused 仍阻止普通 Swap/LP。池初始化只看建池准入，不受运行期 HALT/暂停阻止；enablePool 要求交易和 LP 门禁均通过。活跃 Currency 替换 LegalShareAdapter 时，GLOBAL/TOKEN 紧急记录必须共同覆盖交易和 LP，单项暂停不足。授权强退绕过上述业务门禁，资产仍只交付原 owner，发行方 Token 的转账限制仍生效。

本次按首次部署更新 ABI：准入、Token/Market 状态、暂停、市场报告、事件和计数查询均使用新接口；本版删除待审及市场未初始化状态，不提供旧接口重载或历史状态迁移。

## 9. 代理、角色和升级

TSV 自有业务合约使用 UUPS 实现和 ERC-1967 代理；Hook 最终**代理地址**的低 14 位必须与固定 V4 回调权限匹配。`TSVERC1967Proxy` 继承仓库固定的 OZ `ERC1967Proxy`，在代理自身实现 `tsvImplementation()` 读取 ERC-1967 实现槽，该 selector 不能被业务实现复用。CREATE2 工厂挖掘的是代理创建字节码与初始化参数的最终地址。Hook 的回调权限和代理地址一经建池不得变化；升级只能替换逻辑。所有实现禁止直接初始化。

`TSVBusinessAuthority` 为非代理合约，保存一个 `governor` 地址和不可变 `upgradeTimelock`；六代理经固定 Anchor 动态读取当前 Authority 判断 `DEFAULT_ADMIN_ROLE`，不得留静态旧管理员。各业务角色的持有人是单独地址，合约只核对 `msg.sender` 的地址/角色，不检查这些地址背后的多签成员和门槛。Governor 可即时配置业务角色与参数；UpgradeTimelock 不持有业务角色。`_authorizeUpgrade` 只接受 UpgradeTimelock 或事故升级控制器，不接受业务管理员。

**D-35 当前实现。**六个业务代理通过固定 GovernanceAnchor 读取当前治理根；完整 ABI 与迁移状态机见本节接口定义。治理根迁移的执行顺序见[部署清单 §9](./DEPLOYMENT_CHECKLIST_V1.md#9-治理根迁移)，目标链证据见[实现状态](./IMPLEMENTATION_STATUS_V1.md)。

业务 `AccessControl` 的角色常量固定为 `keccak256("SYMBOL_ADMIN_ROLE")`、`keccak256("POOL_CREATOR_ROLE")`、`keccak256("HALT_REPORTER_ROLE")`、`keccak256("VOLUME_ORACLE_ROLE")`、`keccak256("EMERGENCY_PAUSER_ROLE")`、`keccak256("EMERGENCY_RESUMER_ROLE")`、`keccak256("REVOKE_EXIT_EXECUTOR_ROLE")`、`keccak256("FORCE_EXIT_ADMIN_ROLE")`，对应本文去掉 `_ROLE` 后缀的角色称呼。各业务合约覆写 `hasRole(DEFAULT_ADMIN_ROLE,account)`，只在 `account == BusinessAuthority.governor()` 时返回真；禁止经公开或内部授撤入口改变此根角色，其他业务角色仅由当前 Governor 授撤。`Registry.hasCredential(owner)` 只读全局配置的 `verify(owner,tokenId)`，不把 SBT 的全局 `paused()` 解释为凭证缺失；普通用户入口另外检查 `!paused()`。读取 SBT 失败时调用回滚，不将故障解释为无凭证。

`TSVUpgradeTimelock` 继承仓库固定 OZ `TimelockController`：父类 `minDelay` 初始化为 0；`updateDelay` 恒回滚；每笔普通 `schedule` 的 `delaySeconds` 原样传给父类，可为 0 或任意父类可表示的 `uint256`，不增加最小/最大规则。Governor 和 RecoveryCouncil 都必须持父类 `PROPOSER_ROLE`，但覆写 `schedule`：Governor 只能排期普通操作，RecoveryCouncil 只能排期下段定义的精确受保护恢复，任何其他 proposer 一律回滚。覆写 `scheduleBatch` 只接受 Governor 且拒绝任何受保护恢复 selector。Executor 地址或开放执行标志来自部署清单，并始终额外授予 RecoveryCouncil `EXECUTOR_ROLE`，保证受保护恢复能由 Council 自行执行。Guardian 是唯一外部 `CANCELLER_ROLE` 持有人；部署时撤销父类构造过程给予两个 proposer 的 canceller。父类 `DEFAULT_ADMIN_ROLE` 最终只留给 Timelock 自己。覆写 `grantRole/revokeRole/renounceRole`，禁止外部入口改变 `DEFAULT_ADMIN_ROLE/PROPOSER_ROLE/CANCELLER_ROLE/EXECUTOR_ROLE`；受保护恢复内部才可用 `_grantRole/_revokeRole` 轮换固定 proposer/canceller。Governor 的普通排期不能调用 `recoverAuthorities`，也不能通过自调用任意改变这些角色。普通执行仍使用父类 `execute/executeBatch` 的 operationId、predecessor、salt 与 ready 时间规则。

事故升级控制器非代理，初始 `frozen=true`，保存 Governor、Guardian、六个已绑定 TSV 业务代理的允许状态与已使用 `upgradeActionId`。`setUpgradeTarget(proxy,allowed)` 仅 Timelock 普通操作可调用；Controller 从 Timelock 的已绑定 Anchor 读取六代理名单。候选治理根迁移时，Controller 只接受 `nominatedAnchor` 指向当前仍绑定在旧 Timelock 上的 Anchor，再从该 Anchor 读取名单；未绑定名单或任意其他代理均回滚。`executeEmergencyUpgrade(proxy,newImplementation,initData,incidentId,upgradeActionId,reasonCode,evidenceHash)` 仅 Governor 且未冻结时可调用；目标必须仍属于 Anchor 的六代理名单且已获允许，实现有代码、行动 ID/证据非零且未用，先读代理 `tsvImplementation()`，调用 UUPS `upgradeToAndCall`，再要求代理实现地址为提交地址并记录旧新实现地址及证据哈希；代码哈希由发布清单独立核对。它不能转发任意目标调用。`freezeEmergencyUpgrades(incidentId,reasonHash,freezeSalt)` 仅 Guardian 且当前未冻结；递增 epoch，`freezeId = keccak256(abi.encode(block.chainid,address(this),epoch,guardian,incidentId,freezeSalt))`；`unfreezeEmergencyUpgrades(expectedFreezeId,evidenceHash)` 仅 Timelock 普通操作，必须匹配当前 freezeId。冻结只阻断事故即时升级，不自动停止普通排期或业务交易。

独立 RecoveryCouncil 仅能排期 `target == Timelock`、`value == 0`、`predecessor == 0`、精确 `recoverAuthorities(newGovernor,newGuardian,evidenceHash)` calldata 的单项操作；由 Council 为该笔指定 `delaySeconds`，可为 0；`scheduleBatch` 一律拒绝 Council。新身份须非零、彼此不同、都不同于 RecoveryCouncil，且不得将旧 Guardian 直接作为新 Governor 或旧 Governor 直接作为新 Guardian；交叉轮换可经中间独立地址分两笔恢复。Timelock 对该 operationId 标记 `protectedRecovery=true`。执行该 ID 时覆写 `execute`，先核对目标、payload、predecessor、保护标记和当前 Guardian 对该 operationId 的批准，仅在父类执行该 payload 的动态范围内设置与 ID 绑定的 `recoveryContext`，调用完成后清除；`executeBatch` 不得执行含受保护 selector 的批次。`recoverAuthorities` 同时要求 `msg.sender == address(this)` 和上下文 ID 有效，原子更新控制器、BusinessAuthority 以及 Timelock proposer/canceller，失败整笔回滚。Governor 排期同 selector 被覆写入口拒绝。Guardian 的 `cancel` 对受保护 ID 回滚，但可以 `approveRecovery` 或 `revokeRecoveryApproval` 控制执行；对普通 Waiting/Ready ID 调父类；已执行操作不可取消。恢复不自动解冻，旧 Governor 的普通业务授权在根切换后立即失效。RecoveryCouncil 自身地址固定，无普通更换入口。

治理专用写入口 ABI 固定为：

```solidity
// TSVUpgradeTimelock；schedule/scheduleBatch/execute/executeBatch/cancel 沿用 OZ 5.5.0 ABI
function bindBusinessAuthority(address authority) external;
function bindEmergencyController(address controller) external;
function bindGovernanceAnchor(address anchor) external;
function nominateGovernanceAnchor(address anchor) external;
function activateGovernanceAnchor(address anchor) external;
function approveRecovery(bytes32 operationId) external;
function revokeRecoveryApproval(bytes32 operationId) external;
function recoverAuthorities(address newGovernor, address newGuardian, bytes32 evidenceHash) external;
function recoveryContextActive() external view returns (bool);
// TSVGovernanceAnchor；六代理顺序为 Registry, Ledger, DataInbox, Hook, Router, LPManager
function bindProxies(address[6] calldata proxies) external;
function proposeRoot(address newTimelock, address newAuthority, address newController,
    bytes32 salt, bytes32 evidenceHash) external returns (bytes32 id);
function approveRoot(bytes32 id) external;
function revokeRootApproval(bytes32 id) external;
function cancelRoot(bytes32 id) external;
function executeRoot(bytes32 id) external;
// TSVEmergencyUpgradeController
function setUpgradeTarget(address proxy, bool allowed) external;
function executeEmergencyUpgrade(
    address proxy, address newImplementation, bytes calldata initData,
    bytes32 incidentId, bytes32 upgradeActionId, bytes32 reasonCode, bytes32 evidenceHash
) external;
function freezeEmergencyUpgrades(bytes32 incidentId, bytes32 reasonHash, bytes32 freezeSalt) external;
function unfreezeEmergencyUpgrades(bytes32 expectedFreezeId, bytes32 evidenceHash) external;
function setGovernor(address expectedOldGovernor, address newGovernor, bytes32 evidenceHash) external;
function setGuardian(address expectedOldGuardian, address newGuardian, bytes32 evidenceHash) external;
// TSVBusinessAuthority
function recoverGovernor(address expectedOldGovernor, address newGovernor, bytes32 evidenceHash) external;
```

`bindBusinessAuthority` 只能由 Timelock 自身普通排期调用，且只成功一次。`setUpgradeTarget/unfreezeEmergencyUpgrades` 只能由 Timelock 普通排期调用；`setUpgradeTarget` 只接受当前已绑定 Anchor，或候选迁移中仍与旧 Timelock 互相绑定的 Anchor 所列出的六个业务代理。`setGovernor/setGuardian/recoverGovernor` 同时检查 `msg.sender == Timelock` 和 `Timelock.recoveryContextActive()`，必须比较 expected old 地址；`recoverAuthorities` 是唯一协调入口。`recoveryContextActive()` 只在受保护恢复调用栈内为真，返回前清零。`freezeEmergencyUpgrades` 要求当前未冻结且 `freezeSalt != 0`；`executeEmergencyUpgrade` 要求当前未冻结。控制器部署时 `frozen=true, freezeEpoch=0, freezeId=0`，首次普通排期解冻使用 `expectedFreezeId=0` 与非零证据哈希；以后每次 Guardian 冻结都生成非零新 ID。以上身份均是地址，不检查地址背后的多签配置。

代理升级、Adapter 更换和资产批准均须保留已有 PoolKey、已用日额度、暂停记录、LP 仓位/Receipt owner 与原 owner 交付路径。存储使用固定命名空间或经验证的追加布局；部署和每次升级须检查 layout、Hook 权限位、代理实现、角色、接口和历史仓位强退可达性。

## 10. 规范事件与错误

实现可增加诊断事件，但以下事件的名称、字段顺序和索引字段为对外契约；动态大对象以哈希记录，链下通过交易 calldata/归档状态复核。

```text
SecurityListed(bytes32 indexed securityId,bytes32 symbolHash,uint8 tierId,bytes32 evidenceHash)
SecurityDelisted(bytes32 indexed securityId,bytes32 evidenceHash)
SecurityTierChanged(bytes32 indexed securityId,uint8 oldTierId,uint8 newTierId,bytes32 evidenceHash)
TierPolicyChanged(uint8 indexed tierId,uint16 tierBps,uint32 maxListed,bytes32 evidenceHash)
TokenRegistered(address indexed poolCurrency,bytes32 indexed securityId,bytes32 evidenceHash)
TokenStatusChanged(address indexed poolCurrency,uint8 oldStatus,uint8 newStatus,bytes32 evidenceHash)
LegalShareAdapterChanged(address indexed poolCurrency,address oldAdapter,address newAdapter,uint32 legalAdapterVersion,bytes32 evidenceHash)
PoolInitialized(bytes32 indexed poolId,uint160 sqrtPriceX96,address indexed creator,bytes32 priceBasisHash)
PoolStatusChanged(bytes32 indexed poolId,uint8 oldStatus,uint8 newStatus,bytes32 evidenceHash)
MarketStatusChanged(bytes32 indexed securityId,uint8 oldStatus,uint8 newStatus,uint8 oldPauseMode,uint8 newPauseMode,uint64 sequence,bytes32 indexed reportId)
AdtvAccepted(bytes32 indexed securityId,uint32 indexed sourceMonth,uint256 adtvWad,uint64 version,bytes32 indexed reportId)
QuotaAccepted(bytes32 indexed securityId,uint32 indexed tradeDayId,uint8 action,uint256 quotaWad,uint64 version,bytes32 indexed reportId)
DayStartScheduled(uint32 indexed effectiveDayId,uint32 indexed transitionDayId,uint32 oldOffsetSeconds,uint32 newOffsetSeconds,uint64 effectiveStartUTC,address indexed operator,bytes32 reasonHash)
DayStartCancelled(uint32 indexed effectiveDayId,address indexed operator,bytes32 reasonHash)
SwapAccounted(bytes32 indexed poolId,bytes32 indexed securityId,address indexed poolCurrency,bool inputSide,uint32 tradeDayId,uint256 rawAmount,uint256 legalSharesWad,uint32 legalAdapterVersion)
SwapExecuted(bytes32 indexed poolId,address indexed participant,bool zeroForOne,int128 amount0,int128 amount1,uint32 tradeDayId)
PositionOpened(uint256 indexed positionId,address indexed owner,bytes32 indexed poolId,uint128 liquidity)
PositionChanged(uint256 indexed positionId,uint128 oldLiquidity,uint128 newLiquidity)
FeesCollected(uint256 indexed positionId,uint256 amount0,uint256 amount1)
PositionClosed(uint256 indexed positionId,address indexed owner,bool forced,bytes32 reasonCode)
SbtConfigChanged(address indexed oldSbt,address indexed newSbt,uint256 oldTokenId,uint256 newTokenId,bytes32 evidenceHash)
EmergencyPauseOpened(uint256 indexed recordId,uint8 scope,bytes32 indexed target,uint8 mode,bytes32 reasonCode)
EmergencyPauseClosed(uint256 indexed recordId,bytes32 reasonCode)
UpgradeTargetChanged(address indexed proxy,bool allowed)
EmergencyUpgradeExecuted(address indexed proxy,address oldImplementation,address newImplementation,bytes32 indexed upgradeActionId,bytes32 incidentId,bytes32 initDataHash,bytes32 evidenceHash)
EmergencyUpgradesFrozen(bytes32 indexed freezeId,uint256 epoch,bytes32 incidentId)
EmergencyUpgradesUnfrozen(bytes32 indexed freezeId,bytes32 evidenceHash)
BusinessAuthorityBound(address indexed authority)
EmergencyControllerBound(address indexed controller)
BusinessGovernorRecovered(address indexed oldGovernor,address indexed newGovernor,bytes32 evidenceHash)
AuthoritiesRecovered(address indexed oldGovernor,address indexed newGovernor,address indexed newGuardian,bytes32 evidenceHash)
```

Timelock 的普通与受保护排期/执行沿用父类 `CallScheduled/CallExecuted`，普通取消沿用 `Cancelled`；`AccessControl` 角色变更沿用 OZ `RoleGranted/RoleRevoked`，Receipt mint/burn 沿用 ERC-721 `Transfer`。`AuthoritiesRecovered` 由 Timelock 发出，`BusinessGovernorRecovered` 由 Authority 发出；Guardian 未变化时 `newGuardian` 等于原地址。跨合约共用 custom errors 至少固定：`Unauthorized()`、`InvalidConfig()`、`InvalidPool()`、`InvalidStatus()`、`SbtNotConfigured()`、`Expired()`、`MissingReport()`、`InvalidPeriod()`、`ZeroSwapAmount()`、`InputAmountTooLarge()`、`NoFees()`、`SlippageExceeded()`、`SettlementMismatch()`、`QuotaExceeded(bytes32 securityId,uint32 tradeDayId)`、`Paused(uint8 scope,bytes32 target)`、`InvalidPosition()`、`DeliveryFailed()`、`UpgradeFrozen()`、`ProtectedOperation(bytes32 operationId)`。外部发行方 revert 应原样冒泡或包装成带底层 selector 的 `DeliveryFailed`，但不能吞掉失败继续结算。

## 11. 部署输入和验收向量

部署清单必须含 chainId、官方 PoolManager 地址及代码哈希、每个 TSV 代理地址和实现 codehash、Hook 权限位、SBT 地址/tokenId、Governor/Guardian/RecoveryCouncil/Executor 与各运营报告角色地址、Tier 参数、两个资产地址/decimals/代码哈希/代理实现、股票股数 Adapter 地址和版本、发行方权益依据、制裁/暂停与升级控制者、价格依据及首批 PoolKey。新资产只登记唯一池内 Currency，不再配置第二个用户 Token 或独立结算路径；本部署没有旧 LP 仓位或旧 SIP 日账，也不需要历史账本迁移清单。Hook 初始化所需的 Router/LP Manager 地址必须通过确定性部署或 nonce 预计算后逐项比对；`TSVERC1967Proxy` 初始化数据不得为空。缺必填项部署脚本拒绝启用资产；所有身份按独立地址配置，不读取多签内部设置。完整顺序见[全新部署清单](./DEPLOYMENT_CHECKLIST_V1.md)。

编码验收至少覆盖以下**给定输入→确定结果**；这些是实现验收样例，不替代源码审计和真实代理行为核验：

| 场景 | 必须得到的结果 |
| --- | --- |
| wTSLAx 来源方法对实际股票输入 `2e18` shares 返回 `2e18` | `legalSharesWad = 2e18`；若输出侧是非股票币，仅该证券用量增加 |
| TSLAx `wrappedShares = 3e18`、`currentMultiplier = 0.9e18` | 按源码整数公式 `floor(3e18 * 0.9e18 / 1e18) = 2.7e18` 技术股数；在发行方/法务批准映射前资产不能 APPROVED |
| 两枚股票 Currency 申请登记同一池 | `registerPendingPool` 回滚，池状态保持 `ABSENT`；相同与不同 `securityId` 均拒绝 |
| exact input 因价格边界只成交一部分，且输出仍达到下限 | 只拉取实际输入、只按实际两腿 delta 记账；满足所有用户边界才成功 |
| exact output 未完整达到指定输出 | 整笔回滚，不允许部分交付 |
| wTSLAx 或配对币向用户、原 LP owner 精确转账失败 | V4 仓位/成交、另一侧交付、额度及 Receipt 全部回滚，仓位保持可重试；本部署不执行 TSLAx 包装或赎回 |
| HALT 状态一整月未变化 | 无心跳要求；在下一次有效 RESUME 或紧急暂停前保持 HALTED |
| ADTV 数值不变但进入新适用月份；新计量日没有配额覆盖报告 | 必须有新适用月份 ADTV；新日无配额时使用硬上限，不因缺配额报告拒绝 Swap |
| Guardian 已冻结事故升级入口，普通升级已排期 | 事故即时升级失败；普通排期按其自身 ready 时间仍可执行 |

完整的测试 ID、fixture、三份外部源码集成、fuzz/invariant、fork 与通过门槛见规范性文件 [V1 测试规格](./TEST_SPEC_V1.md)。上表只是手算验收向量，不能代替其中的测试覆盖。构建交付包含完整 ABI、存储布局清单、部署/配置脚本、事件索引说明、测试结果及上述行为的可复算案例。**代码完成**与**生产启用**分开验收：wTSLAx 动态权益映射的发行方/法务批准、实际代理 ABI/制裁矩阵/精确转账行为、gas 最坏情况和强退可达性仍是外部事实门禁；它们没有确认时合约可实现，但 wTSLAx 不得调用准入入口，未登记状态为 `ABSENT`，不得创建其活跃生产池。

## 12. 对外 ABI 清单与调用权限

下表列出**当前目标 ABI**。SIP 日历入口已从当前代码移除；Quota 保留 `action`，DataInbox 报告入口不接受签名或 signer 字段，直接按 `msg.sender` 角色授权。Swap 与 LP 只保留 raw Currency 边界，Swap 由 participant 直接调用。结算 Adapter 和独立用户 Token 均不属于当前 ABI；目标新操作不得调用历史 `IssuerShareSettlementAdapter`。struct 使用 §2/§5/§6/§7 的定义；`bytes32 poolId` 统一为 `PoolId.unwrap(key.toId())`。表内未列出的状态写入口不得对外开放。所有状态写入口成功后发 §10 的对应事件，失败不得留下状态。

| 合约 | 外部入口 | 调用者及主要约束 |
| --- | --- | --- |
| Registry | `admitSecurity(bytes32 securityId,bytes32 symbolHash,uint8 tierId,TokenConfig config,bytes32 evidenceHash)`、`relistSecurity(bytes32 securityId,bytes32 evidenceHash)`、`setSecurityTier(bytes32 securityId,uint8 tierId,bytes32 evidenceHash)`、`delistSecurity(bytes32 securityId,bytes32 evidenceHash)`、`setTierPolicy(uint8 tierId,uint16 tierBps,uint32 maxListed,bytes32 evidenceHash)` | 前四项 `SYMBOL_ADMIN`，政策修改仅 Governor；activePoolCount/version 由合约派生，Tier 名额按不同 securityId 计算，活动池未全停用不得下架 |
| Registry | `registerToken(TokenConfig,bytes32 evidenceHash)`、`setTokenStatus(address poolCurrency,TokenStatus,bytes32 evidenceHash)`、`replaceLegalShareAdapter(address poolCurrency,address newAdapter,bytes32 evidenceHash)` | `SYMBOL_ADMIN`；仅按 §2 的状态、暂停、版本和旧仓位不变量变更 |
| Registry | `bindComponents(address hook,address lpManager,address dataInbox)` | Governor 仅可首次绑定；三个地址均须有代码。部署初始化入口，不可替换已绑定组件 |
| Registry | `registerPendingPool(PoolKey)`、`markPoolActive(bytes32 poolId,uint160 sqrtPriceX96,address creator,bytes32 priceBasisHash)` | 仅 LP Manager；两个调用与 PoolManager.initialize 必须在同一外部交易成功 |
| Registry | `disablePool(bytes32 poolId,bytes32 evidenceHash)`、`enablePool(bytes32 poolId,bytes32 evidenceHash)` | `SYMBOL_ADMIN`；enable 重查两侧资产批准、市场与准入，不更改 PoolKey |
| Registry | `addEmergencyPause(PauseScope scope,bytes32 target,PauseMode mode,bytes32 reasonCode,bytes32 sourceHash)`、`clearEmergencyPause(uint256 recordId,bytes32 reasonCode)` | 分别仅 `EMERGENCY_PAUSER` 与 `EMERGENCY_RESUMER`；mode 必须为 TRADE/LP/ALL；按 scope/target/mode 逐条更新活跃计数 |
| Registry | `setSbtConfig(address sbt,uint256 tokenId,bytes32 evidenceHash)`、`isEligible(address owner)`、`hasCredential(address owner)`、`participantSbt()`、`sbtTokenId()` | SBT 配置仅 Governor，必须提供有代码地址和证据哈希；配置时校验 `paused()`/`verify()` ABI；所有用户 Swap/LP 使用同一份资格配置；未配置时回滚 `SbtNotConfigured()`，读取失败时调用回滚 |
| Registry | `getToken(address poolCurrency)`、`getPool(bytes32 poolId)`、`isTradable(bytes32 poolId)`、`isLPAllowed(bytes32 poolId)`、`marketPauseMode(bytes32 securityId)`、`activePauseCount(uint8 scope,bytes32 target,uint8 mode)`、`isKnownPool(bytes32 poolId)` | 只读；isTradable/isLPAllowed 分别判断交易/普通 LP；activePauseCount 返回精确 mode 的记录数；`isKnownPool` 对停用历史池仍为真，供强退 |
| DataInbox | `submitMarketStatus(MarketReport)`、`submitAdtv(AdtvReport)`、`submitAdtvBatch(AdtvReport[])`、`submitQuota(QuotaReport)` | `msg.sender` 必须直接持有对应角色；批量 ADTV 同月、securityId 严格递增、最多 100 条且整批原子提交；不接受报告签名或任意 relayer 代提；序号、reportId 和期间规则按 §7；状态分别写 Registry/VolumeLedger 的仅 DataInbox 入口 |
| VolumeLedger | `recordSwap(bytes32 poolId,int128 delta0,int128 delta1,uint256 legalShares0,uint256 legalShares1)` | 仅固定 Hook 代理；从 Registry 重读资产身份，检查 shares 与资产配置一致后双侧额度原子检查/增加 |
| VolumeLedger | `bindWriters(address hook,address dataInbox)` | Governor 仅可首次绑定；两个地址均须有代码。部署初始化入口，不可替换已绑定写入者 |
| VolumeLedger | `scheduleDayStart(uint32 newOffsetSeconds,uint32 effectiveDayId,bytes32 reasonHash)`、`cancelPendingDayStart(bytes32 reasonHash)` | 仅 Governor；未来边界排期、单次偏差上限与过渡日锁定按 §7 |
| VolumeLedger | `currentTradeDay()`、`dayStartUTC(uint32 dayId)`、`dayStartCheckpointCount()`、`dayStartCheckpoint(uint256 index)`、`initialDayStartOffsetSeconds()`、`remaining(bytes32 securityId,uint32 tradeDayId)`、`used(bytes32 securityId,uint32 tradeDayId)` | 只读；初始化后 `currentTradeDay.exists == true`；ADTV 缺失时 `remaining` 返回无效标志 |
| Hook | V4 `IHooks` 的十个回调均由 `0x3FFF` 地址位启用 | 回调仅 PoolManager；四种返回 delta 当前均为零；donate 回调回滚；`beforeSwap` 校验 Router sender、可交易状态和完整 PoolKey，`afterSwap` 校验 Router sender 与空 hookData |
| Router | §5 两个 Swap 入口、PoolManager `unlockCallback` | Swap 仅 participant 直接调用；资格与池校验在 unlock 前完成，非重入锁约束单笔 Swap 与解锁回调；不保存或暴露 Swap 活跃上下文 |
| LP Manager | §6 七个 LP/建池入口、协议上下文 `activeLPContext()`、ERC-721 `ownerOf/balanceOf/tokenURI/supportsInterface` | 建池仅 POOL_CREATOR；普通 LP 仅原 owner；强退两类专职角色；Receipt 的 mint/burn 仅由 LP 生命周期内部执行；所有转移和 approve 系列入口回滚；活跃上下文只供 Hook 校验，`tokenURI` 对有效 Receipt 返回空字符串 |
| UpgradeTimelock/事故控制器/BusinessAuthority | `bindBusinessAuthority`、`bindEmergencyController`、§9 的 schedule/execute/cancel、冻结/解冻/即时升级、受保护恢复 | 精确 caller、目标、operationId、freezeId 和恢复上下文按 §9 |

`MarketReport/AdtvReport/QuotaReport` 的 Solidity 字段类型和顺序逐项等于 `src/v1/types/TSVReports.sol`，不额外嵌套、重排或使用 `string` 代替 `bytes32`；报告结构不含 `signer` 字段，也没有签名参数；`QuotaReport.action` 为 `uint8`。TradeDayReport 只属于历史资料，当前接口不再接受该类型。当前 getter 对未知主键返回 Solidity 默认结构；调用方必须检查 `status`、`poolCurrency`、`securityId`、`version` 或报告 `version/reportId` 等存在性字段，不能把零值当作有效配置。`Tier` 的规范存储为 `tierBps uint16`、`maxListed uint32`、`listedCount uint32`，Governor 修改 `tierBps/maxListed` 要求 `1 <= tierBps <= 10000` 且新 `maxListed >= listedCount`，变更对未来 Swap 立即生效而不清除历史额度。

`LegalShareAdapterChanged` 只在 GLOBAL/TOKEN 紧急暂停共同覆盖交易和 LP 或无活跃池、版本递增且新 Adapter 声明支持直接换算接口并绑定对应 Currency 时发出。
