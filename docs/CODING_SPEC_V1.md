# TSV V1 合约编码规格

版本：1.3，2026-10-01。本文记录**当前源码 ABI**、迁移前类型参考和已实现/未冻结规则，接口以 `src/v1/` 为准。[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)是资产分类、结算能力与计股能力的规范；当前 V1 每侧只直接收付该侧 Currency，Tesla 池目标只收付 wTSLAx。本地实现使用 ERC-8056 标准测试代币，真实 wTSLAx 实例仍待外部审查。TSLAx 是 xStock 系列的一个实例，其接口不代表其他 xStock。系统关系见[主架构](./CONTRACT_ARCHITECTURE.md)，Tesla 特有细节见[实例规格](./TSLAX_INTEGRATION.md)，未编码和未冻结之处见[实现与缺口清单](./IMPLEMENTATION_STATUS_V1.md)。

| 位置 | 阅读方式 |
| --- | --- |
| §2–4、§5–6、§8–12 中标明“当前”的类型、入口与权限 | 现有 `src/v1/` 合约 ABI 和行为；旧 TSLAx 包装/赎回仅在明确标注的历史章节中出现，不属于当前入口 |
| §3 D-36、§5–6 直结迁移、§7 D-33/D-34、§9 D-35 及前端报价描述 | 部分已编码、部分仍待冻结；各项状态以实现缺口清单为准 |
| §7 的旧 `TradeDayReport`、SIP 窗口及必填 quota | 仅为历史评审背景；本部署没有旧 SIP 日账，不设计迁移，目标验收以[测试规格](./TEST_SPEC_V1.md)为准 |

**编码就绪边界：**D-35 GovernanceAnchor 状态机和日内公司行动单位处理尚未闭合；不能据现有段落直接生成完整目标实现。当前没有旧链上 LP 仓位或旧 SIP 日账，因此不包含历史状态迁移算法。详见缺口清单 SPEC-01～02。

## 1. 范围、单位与外部依赖

- V1 每次 Swap **只经过一个 V4 PoolKey**；不提供多跳、批量 Swap、原生币、动态 LP fee、Hook fee、ERC-6909 用户余额或直接以可变余额 AutoFee 原币入池。每个成功的 PoolManager `swap` 恰有一个 Hook 成交记账过程。
- 所有池使用同一个 TSV Hook 代理、Registry、VolumeLedger、DataInbox、Router、LP Manager 和 SBT Adapter。官方 PoolManager 不由 TSV 升级。Hook 的 `BEFORE_DONATE` 回调拒绝捐赠。
- Hook 代理地址低 14 位固定为 `0x3FFF`：预留 V4 的 10 个回调位和 4 个返回 delta 位，避免已建池因 `PoolKey.hooks` 地址不可改而失去后续扩展能力。**V1 行为仍不使用自定义结算**：`beforeSwap` 返回零 `BeforeSwapDelta`，`afterSwap` 返回零 `int128`，`afterAddLiquidity/afterRemoveLiquidity` 返回零 `BalanceDelta`；`beforeDonate/afterDonate` 均回滚，禁止捐赠。其余回调按本文现行门禁执行。部署脚本须以本地 `Hooks.sol` 常量重新计算并断言代理地址位型。
- 预留返回 delta 权限只赋予地址能力，不授权 V1 升级立即返回非零值。未来启用非零 delta 前，必须同版重设计 Router/LP Manager 的最终 `callerDelta` 结算、Hook/Ledger 的监管成交数量口径、Hook 自身欠款清算、签名边界、事件及回滚不变量，并完成独立审查与升级回归。当前 `afterSwap` 参数是 Hook 返回值影响 PoolManager 最终 caller delta **之前**的 Swap delta；直接沿用现有股数公式会错计。非零 delta 不能靠单独升级 Hook 启用。静态 LP fee、单池 Swap 和禁用 donate 的 V1 限制保持不变。
- `poolCurrency` 是 PoolKey 中的 ERC-20；`userToken` 是用户最终支付/收到的 ERC-20，当前 Registry 要求两者相等并直接结算，不登记额外底层路径。TSV 不发行 Wrapped。
- 股数账本单位 `legalSharesWad` 为 `1e18` 表示 1 股；金额字段除明确标注外均是相应 ERC-20 的**原始整数单位**。当前 `tradeDayId` 是按自动 UTC 日切计算的周期开始日 `YYYYMMDD`；不再使用 SIP 日历。链上时间为 Unix 秒。
- 外部源码固定为本仓库 `lib/v4-core`、`lib/soul-bound-token-1155`、`lib/TestToken/backed-token-contract` 的当前提交；TSV Solidity `0.8.26` 只导入本地薄接口及 V4 类型，发行方/SBT 实现分别独立编译。任何实际代理 ABI/代码与参考源码不符，资产保持 `UNREVIEWED`。

| 外部协议 | 编码必须遵守的本地源码事实 |
| --- | --- |
| V4 `PoolManager`/`IHooks` | `unlock` 内调用 `swap/modifyLiquidity/sync/settle/take`；Hook 原签名及地址权限位由 `Hooks.sol` 约束；`modifyLiquidity` 的 `callerDelta` 已包含本次本金与费用；零流动性零 delta 领费不可依赖 |
| `SmartWalletSbt` | `verify(owner,tokenId)` 与全局 `paused()` 必须分别读取；ERC-1271 AA 钱包签名能力不等于能接收 ERC-1155 SBT |
| Backed AutoFee/发行方 Wrapped | 底层 `balanceOf` 按 shares 与 multiplier 向下取整，`transferSharesFrom` 按显示单位消耗 allowance；Wrapped `_deposit` 从调用者拉取内部 shares，`_withdraw` 向指定接收人转出内部 shares |

## 2. 公共类型与存储主键

以下名称、顺序和整数宽度是**当前实现 ABI**。`TokenConfig` 仍保留旧结算和比例字段以维持存储/接口兼容，但当前登记规则要求直接结算并将这些旧字段置零；它们不是新的业务逻辑来源。`PoolKey/PoolId/BalanceDelta` 使用固定 V4 类型。

```solidity
enum AssetClass { QUOTE_ERC20, FIXED_BALANCE_STOCK, ISSUER_WRAPPED_DYNAMIC, ONCHAIN_DYNAMIC }
enum SettlementMode { DIRECT_ERC20, ISSUER_SHARE_WRAPPED }
enum TokenStatus { UNREVIEWED, APPROVED, DISABLED }
enum PoolStatus { ABSENT, PENDING, ACTIVE, DISABLED }
enum MarketStatus { UNINITIALIZED, OPEN, HALTED }
enum MarketAction { INITIAL_OPEN, INITIAL_HALTED, HALT, RESUME }
enum PauseScope { GLOBAL, SECURITY, TOKEN, POOL }
enum RoundingMode { FLOOR, CEIL }
enum LegalShareMode { STATIC_RATIO, ONCHAIN_DYNAMIC }
enum RawBoundMode { MIN_RAW_FOR_AT_LEAST_SHARES, MAX_RAW_FOR_AT_MOST_SHARES }
enum LPOperationMode { OPEN, INCREASE, DECREASE, COLLECT, CLOSE, FORCE_EXIT }

struct TokenConfig {
    address userToken;
    address poolCurrency;
    uint8 userDecimals;
    uint8 poolDecimals;
    AssetClass assetClass;
    bytes32 securityId;              // QUOTE_ERC20 使用 bytes32(0)
    SettlementMode settlementMode;
    address settlementAdapter;       // DIRECT_ERC20 使用 address(0)
    uint32 settlementVersion;
    address legalShareAdapter;       // QUOTE_ERC20 使用 address(0)
    uint32 legalAdapterVersion;
    uint256 sharesPerWholeTokenWad;  // 兼容保留；当前 registerToken 必须为 0
    bytes32 ratioEvidenceHash;       // 兼容保留；当前 registerToken 必须为 0
    TokenStatus status;
    bytes32 userRuntimeCodeHash;
    bytes32 poolRuntimeCodeHash;
    bytes32 settlementAdapterCodeHash;
    bytes32 legalAdapterCodeHash;
    bytes32 userImplementationHash;  // 非代理可为 0
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

struct AssetBounds {
    uint256 maxSharesIn;
    uint256 minSharesOut;
    uint256 maxDisplayedDebit;
    uint256 minDisplayedCredit;
}

struct RateSnapshot {
    bytes32 rateId;
    uint256 numerator;
    uint256 denominator;
    uint32 adapterVersion;
    RoundingMode rounding;
}

struct LPContext {
    bytes32 poolId;
    uint256 positionId;
    int24 tickLower;
    int24 tickUpper;
    bytes32 salt;
    LPOperationMode mode;
    address owner;
    int256 liquidityDelta;
}
```

Registry 使用 `mapping(address poolCurrency => TokenConfig)` 和唯一反向索引 `mapping(address userToken => address poolCurrency)`；`PoolId` 键保存**完整 PoolKey 结构**、两侧已冻结的 `securityId`、状态和版本。`securityId` 为不可变底层证券 ID，不从 ticker 推导。一个 `userToken` 在当前 ABI 只能对应一个 `poolCurrency`；不同用户 Token 可映射同一 `securityId` 并共享额度。**PoolKey 两侧 `securityId` 只要同时非零，登记待初始化池就失败**；该限制不区分证券是否相同。

**目标存储兼容性：**原地址升级保留当前 `TokenConfig` 已占用的字段槽位及既有 `poolCurrency` 键；新登记和新操作强制 `userToken == poolCurrency`、`settlementMode == DIRECT_ERC20`、`settlementAdapter == 0`，并允许获批动态股数 Adapter 与直接结算组合。D-36 所说“不再登记静态比例”表示新规则不读、不写该旧比例作为权威值；升级不得直接删除或重排既有 struct 字段，应保留废弃槽位或使用经布局验证的独立新命名空间。旧 wTSLAx 条目从 TSLAx 用户 Token 改为直结时，须原子清理旧 `currencyOf(TSLAx)` 反向索引并设置 `currencyOf(wTSLAx)`，不得留下两地址均指向同一 Currency。本部署没有历史仓位或旧账本，不设置旧状态兼容分支。

**当前实现的准入组合如下；完整业务门槛以[新版准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)为准。**`registerToken(TokenConfig, bytes32 evidenceHash)` 仅 `SYMBOL_ADMIN`，初次状态必须 `UNREVIEWED`，两个地址均非零且有代码、`userDecimals/poolDecimals` 均须等于相应 ERC-20 `decimals()` 实测值、`poolDecimals <= 18`、版本从 1 开始；合约对用户 Token、池内 Currency 和非零股数 Adapter 的 `extcodehash` 逐一核对配置哈希。V1 只接受 `DIRECT_ERC20`，要求 `userToken == poolCurrency && settlementAdapter == 0`；`sharesPerWholeTokenWad` 和 `ratioEvidenceHash` 是兼容保留字段，登记时必须为零。股票要求 `securityId != 0`、已上市、`legalShareAdapter != 0`、`legalSharePolicyHash != 0`，并由 Adapter 自身提供计股模式和当前快照；配对币要求 `securityId == 0`、`legalShareAdapter == 0`、`legalAdapterCodeHash == 0`、`legalAdapterVersion == 0`、`legalSharePolicyHash == 0`。`QUOTE_ERC20`、`FIXED_BALANCE_STOCK` 和 `ONCHAIN_DYNAMIC` 均走直接结算；`ISSUER_WRAPPED_DYNAMIC` 只保留旧 ABI 枚举值，当前注册会拒绝。代理 implementationHash 是链下审查证据，链上不能读取另一合约的 ERC-1967 存储槽；运维监测实际实现变化。注册、批准、停用、股数 Adapter 更新都发事件；状态只允许 `UNREVIEWED→APPROVED→DISABLED→APPROVED`，重新批准必须附新审查依据。转入 `APPROVED` 时要求非零 `reviewHash`、`evidenceHash`；其哈希证明文件本身由链下评审，合约不推断法律真实性。只有 `APPROVED` 可用于新 Swap/用户 LP。`DISABLED` 保留配置供原 owner 强退。

**当前实现的替换入口：**新路径不提供用户结算 Adapter 替换；`replaceSettlementAdapter` 直接拒绝。更换法定股数 Adapter 仍要求暂停、版本递增和历史成交不重算；ERC8056 测试 Adapter 通过读取发行方当前 multiplier 支持参数更新，不要求更换 Adapter 地址。Token 代理实现、制裁权限或关键规则变化时先停用，再复核恢复。

### 2.1 当前代码中的两个资产实例（源码对照）

| 字段 | 本地标准股票测试代币 `ERC8056TestToken` | 发行方 wTSLAx 直结实例 |
| --- | --- | --- |
| `userToken / poolCurrency` | 同一个 `STDx` 地址；raw ERC-20 余额稳定 | 同一个经批准的 wTSLAx 地址；TSLAx 不登记为用户结算 Token |
| `userDecimals / poolDecimals` | 从 `decimals()` 实测，测试为 18 / 18 | 从拟上市的 wTSLAx 代理实测，生产值不能假设 |
| `assetClass / settlementMode` | `ONCHAIN_DYNAMIC / DIRECT_ERC20` | `ONCHAIN_DYNAMIC / DIRECT_ERC20` |
| `settlementAdapter` | `address(0)` | `address(0)`；Router/LP 不调用包装、赎回或发行方结算 Adapter |
| `securityId` | 测试用已登记证券 ID（例如 `SEC_A`） | Tesla 的已登记 ID |
| `legalShareAdapter` | `ERC8056LegalShareAdapter`；读取 `uiMultiplier()`，按当前快照用 FLOOR 换算 | 发行方/法务批准的动态 Adapter；通常读取 wTSLAx 对应发行方公式 |
| `sharesPerWholeTokenWad` | 0；Registry 不保存第二份静态比例 | 0；Registry 不保存第二份静态比例 |
| `status` | 测试配置批准前为 `UNREVIEWED` | 实际代理、精确转账和法律计量证据齐全前为 `UNREVIEWED` |

普通 ERC-20 配对币用 `QUOTE_ERC20 / DIRECT_ERC20`、`securityId == 0`、无股数 Adapter，不占用股票成交额度。`ERC8056TestToken` 的 18 位精度和 multiplier 仅是测试行为；它不代表任何发行方或法律股数事实。普通 ERC-20 故障夹具仍用于验证拒收、少转和非精确到账路径。

**目标实例：**本地集成测试以 `ERC8056TestToken(STDx)` 作为标准股票 Currency，验证 raw 结算、UI multiplier 更新、双向 Swap、LP 加减仓和按实际 V4 delta 计股；普通 `V1LocalERC20(QUOTE)` 作为报价币。Tesla 生产池为 `userToken == poolCurrency == wTSLAx`、`DIRECT_ERC20`、零结算 Adapter、`ONCHAIN_DYNAMIC` 与已批准的发行方股数 Adapter；TSLAx 不能作为 TSV 新用户结算 Token。本部署没有旧 LP 仓位或旧账本，因此不设置历史结算兼容分支。

## 3. 法定股数 Adapter

`ILegalShareAdapter` 的规范接口为 `poolCurrency()`、`adapterVersion()`、`legalShareMode()`、`snapshot(address poolCurrency)`、`toLegalShares(address poolCurrency, uint256 rawAmount, RateSnapshot calldata)`、`rawForLegalShares(address poolCurrency, uint256 legalSharesWad, RateSnapshot calldata, RawBoundMode)` 和 `isCurrent(address poolCurrency, RateSnapshot calldata)`。仅 Registry 绑定的 Adapter 可用于该 Currency；Hook 在 `beforeSwap` 自己读取快照，`afterSwap` 用同一快照换算，Router 结算结束前要求 `isCurrent == true`。`numerator/denominator` 均大于零，所有乘除用 512 位 `mulDiv`；结果零、溢出或 `isCurrent == false` 均回滚。事件记录 `rateId`、版本、原始数量、舍入模式和换算结果。

**D-36 接口状态。**当前 `TokenConfig` 注册已禁止把 `sharesPerWholeTokenWad` 作为权威配置；Registry 绑定经审查的 Adapter 地址、版本、运行代码哈希、计股模式及策略／权益依据哈希。静态比例在相应 Adapter 的不可变配置中，动态公式读取发行方认可的链上状态；Registry 的单个字段或 Adapter 自报哈希均不能证明法律事实。`ERC8056LegalShareAdapter` 已实现本地标准 Token 的 `uiMultiplier()` 快照、正向计股和 raw 边界反算；其他发行方公式若无法用现有快照结构完整表达，须先评审并版本化扩展 ABI。前端直接读取发行方持仓权益并换算成现有 raw Swap/LP 参数，Router 和 LP Manager 不增加股数输入入口：

```solidity
enum RawBoundMode { MIN_RAW_FOR_AT_LEAST_SHARES, MAX_RAW_FOR_AT_MOST_SHARES }

function rawForLegalShares(
    address poolCurrency,
    uint256 legalSharesWad,
    RateSnapshot calldata rate,
    RawBoundMode mode
) external view returns (uint256 rawAmount);
```

定义 `F(raw) = toLegalShares(poolCurrency,raw,rate)`，在数学约束中令 `F(0)=0`，正 raw 成交仍要求 `F(raw)>0`。`MIN_RAW_FOR_AT_LEAST_SHARES` 返回使 `F(raw)>=legalSharesWad` 的最小 raw；`MAX_RAW_FOR_AT_MOST_SHARES` 返回使 `F(raw)<=legalSharesWad` 的最大 raw，若不存在允许的正 raw 则返回 0。目标股数为 0 时返回 0；无法在 `uint256` 内表示、快照过期或映射非单调时回滚。两个方向使用同一快照，必须验证边界相邻 raw 的不等式；整数舍入可能不存在 `F(raw)==legalSharesWad` 的精确解。反向供前端只读报价及构造 raw 限额，**Hook/VolumeLedger 仍只对实际 V4 股票腿 delta 正向换算并记账**；前端报价快照与执行时快照可能不同，Router 的实际结算仍按既有规则核对执行时快照。固定比例公司行动可更换整版 Adapter/依据，也可在 Adapter 代码不变时采用发行方新参数/rate epoch；两者都必须对齐 ADTV、配额和已用量，而不是更新 Registry 单一比例。同一 `securityId` 下 Token 的发行方实现可不同步；只要各自 snapshot 可验证，就可以继续交易并由运营分段汇总，只有无法验证映射的 Token 才暂停。接口、TokenConfig、Hook 快照和所有调用方需同版迁移。

**当前代码的固定比例股票：**固定比例由 `StaticLegalShareAdapter` 的不可变参数提供，`snapshot()` 返回 `numerator = sharesPerWholeTokenWad`、`denominator = 10 ** poolDecimals`、`rounding = CEIL`，即 `ceil(rawAmount * numerator / denominator)`。Registry 不把 `TokenConfig.sharesPerWholeTokenWad` 或 `ratioEvidenceHash` 当作第二份比例来源，而是在注册/替换时校验 Adapter 快照、版本、代码哈希和模式。固定比例变更必须暂停受影响 Token、采用新 Adapter 版本或经批准的同一 Adapter 新参数/rate epoch，并同步审查 ADTV、quota 和单位边界；历史成交不重算。

Tesla 股票的 V1 **业务计量选择**是按 TSLAx 显示数量计股：1 个完整显示 TSLAx 计作 1 股；本仓库 `BackedAutoFeeTokenImplementation._getUnderlyingAmountByShares` 给出 `displayRaw = floor(wrappedShares * currentMultiplier / 1e18)`。股票 Currency 为 wTSLAx，其实际 V4 raw delta 就是 `wrappedShares`。生产候选 `BackedAutoFeeLegalShareAdapter` 固定 `numerator = currentMultiplier`、`denominator = 1e18`、`rounding = FLOOR`，故 `legalSharesWad = displayRaw`；该 Adapter 的 `rateId = keccak256(abi.encode(TSLAx, currentMultiplier, currentMultiplierNonce, legalAdapterVersion))`，其中 TSLAx 是发行方系数来源地址，**不是用户结算资产**。`snapshot` 直接读取发行方 `getCurrentMultiplier()`，不得依赖心跳上链。用户已确认上述计量选择；源码只证明显示单位公式，发行方与法务仍须确认该显示单位可作为监管口径的法定股数。批准依据、实际代理行为或读数 gas 未核验时，wTSLAx 不得从 `UNREVIEWED` 改为 `APPROVED`。若获批公式不同，部署另一固定版本 Adapter，先暂停相关池并按配置流程更换，不能让 Router 或用户自报比率。

股票输入腿取 PoolManager caller `BalanceDelta` 的绝对含费总支出，输出腿取净收到量；准入池每笔 Swap 最多一条股票腿，按其实际方向计股。LP 操作和 `take/settle` 不调用成交记账。每笔 `legalSharesWad` 必须大于零，历史日累计量不因 multiplier、Adapter 或 Tier 后续变化而重算。

## 4. 旧资产结算 Adapter 与目标直结

以下 `IAssetSettlementAdapter` 是**历史结算 Adapter 的源码参考**，不属于当前 V1 Swap/LP ABI。它只用于理解旧代码和维护独立回归测试；当前 Registry 拒绝 `ISSUER_SHARE_WRAPPED` 登记，Router/LP Manager 不调用包装、赎回或底层 shares 转移。本部署没有需要兼容的旧仓位：

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

当前所有新操作均为 `DIRECT_ERC20`，不经过结算 Adapter。每笔入金同时核对付款人准确减少、PoolManager 准确增加及 `settle()` 返回值；出金同时核对 PoolManager 准确减少与最终收款人准确增加，任何发送方额外扣费、接收方少收、rebase 或异常返回都回滚。本地故障币回归覆盖发送方额外扣费；固定依赖与目标网络验收仍见[安全评审 F-05](./reviews/SECURITY_REVIEW_2026-09-30.md)。

## 5. Swap ABI、授权与 Hook

**本节结构体与下列步骤描述当前代码；Router EIP-712 域版本为 `2`。**新交易按一个 PoolKey 的 raw 金额执行，只直接收付两侧 Currency；旧 TSLAx 包装分支不属于当前能力。

```solidity
struct SwapRequest {
    PoolKey key;
    address participant;
    address payer;
    address recipient;
    address authorizedCaller;  // 直连为 0；代调用为已批准入口 Adapter
    bool zeroForOne;
    bool exactInput;
    uint128 amountSpecified;   // V4 输入/输出 Currency 的原始单位；须 <= int128.max
    uint128 limitAmount;       // exactInput 为最小输出；exactOutput 为最大输入
    uint160 sqrtPriceLimitX96;
    AssetBounds bounds0;
    AssetBounds bounds1;
    uint256 nonce;
    uint64 deadline;
}

function swapExactInput(SwapRequest calldata request, bytes calldata participantSignature)
    external returns (uint256 actualIn, uint256 actualOut);
function swapExactOutput(SwapRequest calldata request, bytes calldata participantSignature)
    external returns (uint256 actualIn, uint256 actualOut);
function cancelSwapNonce(uint256 nonce) external;
```

两入口分别要求 `exactInput == true/false`。`participant == payer == recipient != 0`；直连时 `msg.sender == participant`、`authorizedCaller == 0`、签名为空；代调用时 `msg.sender == authorizedCaller` 且该地址在 Router 白名单，签名必须由 participant 产生。`authorizedCaller` 是代提交入口，**不是**资产 `settlementAdapter`。Router 对 EOA 使用 ECDSA、对合约钱包使用 ERC-1271，严格核验 magic value。两种调用都消耗 `(participant,nonce)`；`cancelSwapNonce` 只允许 participant 自己将未使用 nonce 标记取消，回滚交易不消耗 nonce。

EIP-712 域固定 `name="TSVSwapRouter"`、`version="2"`、当前 `chainId`、Router **代理地址**。类型名为 `SwapAuthorization`，按下列**精确顺序与类型**编码；`poolId = keccak256(abi.encode(request.key))`，Router 还必须核对 Registry 中保存的完整 PoolKey：

```text
SwapAuthorization(address participant,address payer,address recipient,address authorizedCaller,bytes32 poolId,bool zeroForOne,bool exactInput,uint128 amountSpecified,uint128 limitAmount,uint160 sqrtPriceLimitX96,uint256 maxSharesIn0,uint256 minSharesOut0,uint256 maxDisplayedDebit0,uint256 minDisplayedCredit0,uint256 maxSharesIn1,uint256 minSharesOut1,uint256 maxDisplayedDebit1,uint256 minDisplayedCredit1,uint256 nonce,uint64 deadline)
```

Router 用 `keccak256(abi.encode(TYPEHASH, 各字段按上述顺序展开))` 生成 struct hash，再按 EIP-712 域生成 digest；不得对 `PoolKey` 的用户提供哈希或另一个请求字段直接信任。`amountSpecified > 0` 且不超过 `int128.max`；`limitAmount > 0`；deadline 未过。两侧 `DIRECT_ERC20` 的四个 `AssetBounds` 字段必须全零；任何非零股数/显示数量边界均拒绝。准入池最多一侧为股票，两种池内 Currency 的普通滑点由 `limitAmount` 约束。

执行顺序固定如下：

1. Router 非重入，核对 SBT `!paused() && verify(participant, tokenId)`、授权、nonce、完整 PoolKey、AssetBounds、Pool/Token/security 暂停、市场状态和 Ledger 当前数据。`sqrtPriceLimitX96` 须处于 V4 允许范围且方向正确。
2. Router 生成 `operationId = keccak256(abi.encode(block.chainid, address(this), participant, nonce, poolId))`，保存只供本次调用读取的活跃上下文 `(operationId,poolId,participant,mode)`，调用 `PoolManager.unlock(abi.encode(operationId,request))`。`unlockCallback` 只接受 PoolManager，核对回调数据哈希与活跃上下文。一次 unlock 只调用一次 `swap`，`hookData = abi.encode(operationId)`。
3. Hook 的 V4 回调 ABI 严格使用本地 `IHooks.sol` 原签名，所有回调只接受 PoolManager。`beforeSwap` 要求 `sender == Router`、Hook/Router 上下文完全匹配，重新核对池、暂停和市场状态；SBT 资格由 Router 在进入 unlock 前检查。Hook 仅对股票 Currency 从 Registry 绑定的 `legalShareAdapter` 自行读取 `RateSnapshot` 并存入本次暂态上下文；配对币使用零快照且不调用股数 Adapter。返回零 Hook delta 与零费率覆盖。`afterSwap` 要求同一 PoolId、operationId 与未消费快照，从实际 `BalanceDelta` 解析 caller 输入/输出，任何一腿为零即回滚；股票腿按 §3 换算，在 Ledger 一次原子调用中记账，标记该上下文已计量但暂不删除快照；返回零 Hook delta。Hook 另提供 `assertCurrentAndClear(bytes32 operationId)`，仅当前 Router 可在已计量且结算完成时调用；未调用则 Router 操作不得成功结束。其他人直接调用 PoolManager 的 swap/modify/initialize/donate 全部被 Hook 拒绝。
4. Router 对实际 delta 再验 `actualIn > 0 && actualOut > 0`。exact input 要求 `actualIn <= amountSpecified && actualOut >= limitAmount`，允许价格边界造成的部分成交；exact output 要求 `actualOut == amountSpecified && actualIn <= limitAmount`，任何部分成交回滚。按**实际**负 delta 直接从 participant 拉取对应 Currency，按实际正 delta 直接 `take` 同一 Currency 给 participant；两侧均核对发送方扣减、PoolManager 余额变化、接收方增加和 `settle()` 返回值。
5. Router 调用 Hook `assertCurrentAndClear(operationId)`，Hook 确认已经计量且两侧股数快照仍当前后删除上下文；Router 清除自身上下文并消耗 nonce。任一检查失败整笔回滚。当前路径没有包装、赎回、底层 shares 转移或其他结算分流。

**当前直结路径。**Registry 对每侧只批准 `userToken == poolCurrency`、`DIRECT_ERC20`、零结算 Adapter。Router 使用单池 `swapExactInput/swapExactOutput` 与 raw `amountSpecified/limitAmount`，对实际负 delta 直接从 payer 拉取 Currency 并 `sync/settle`，对正 delta 直接 `take` 同一 Currency 给 recipient；每次核对发送方恰扣、接收方恰增。**为原地址升级保留现有 `SwapRequest` 结构、`SWAP_TYPEHASH` 和两个 `AssetBounds` 字段，但要求八个字段全为零；任何新 Swap 均不得调用包装 Adapter。**Router 当前 EIP-712 域版本为 `"2"`，旧版本 digest 不可复用；已消耗 nonce 保留，新授权必须使用 `version="2"` 域。旧 `IssuerShareSettlementAdapter` 只保留为源码和隔离单元测试对照，本部署没有旧仓位兼容分支，也不参与新 Swap。

Swap 成功事件包含 `operationId,participant,poolId,zeroForOne,actualAmount0,actualAmount1,tradeDayId`。Hook/Ledger 的 `SwapAccounted` 对每个股票腿分别记录 `securityId,poolCurrency,inputSide,rawAmount,legalSharesWad,rateId,legalAdapterVersion,roundingMode`。交易哈希与 logIndex 由索引器取链上 receipt，不写进合约事件。若未来升级改变签名请求的执行语义，必须先变更 EIP-712 `version` 并拒绝旧版本签名；兼容升级保留 nonce 和当前域。

**前端股数展示与 Swap 报价。**前端从 Registry 读取该股票 Currency 当前绑定的 `LegalShareAdapter`、版本和快照，通过只读正向／反向换算，结合发行方确认的账户权益规则显示用户持有股数和 raw 报价。前端以换算后的 raw 数量构造 `SwapRequest.amountSpecified`、`limitAmount`、价格限制和 deadline；保留的两个 `AssetBounds` 全部置零。用户及 AA 钱包签署 raw `SwapAuthorization`，升级后域版本为 `"2"`。账户总持仓的舍入规则可能与单笔 raw 成交换算不同，尤其是 TSLAx，前端须分别展示，不得把两者混用。V1 Router 无股数输入参数或股数专用签名；报价后价格、余额或发行方系数变化可能改变实际股数，链上只保证已提交的 raw 与结算边界。成交股数由 Hook 按实际 V4 股票腿 delta 和执行时快照正向换算并记入 VolumeLedger，前端估值不写入额度。

## 6. LP、Receipt 与强退

以下 `LPBounds` 和七个入口沿用当前 ABI，以便原地址升级；目标新操作仍保留两个 `AssetBounds` 结构字段，但其八个数值必须全零。

```solidity
struct LPBounds {
    uint256 maxPoolIn0;
    uint256 maxPoolIn1;
    uint256 minPoolOut0;
    uint256 minPoolOut1;
    AssetBounds bounds0;
    AssetBounds bounds1;
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

`positionId` 从 1 单调递增；`salt = keccak256(abi.encode(block.chainid,address(LPManager),positionId))`。LP Manager 的 `nextOperationNonce` 也从 1 单调递增，每次 LP 外部操作在 unlock 前生成 `operationId = keccak256(abi.encode(block.chainid,address(this),nextOperationNonce,positionId,operationMode))`，保存活跃上下文供 Hook 和结算 Adapter 核对，结束清除；回滚不消耗序号。LP `modifyLiquidity` 的 `hookData = abi.encode(operationId)`；LP Manager 提供 `activeLPContext(bytes32 operationId) external view returns (LPContext memory)`，Hook 的 `beforeAddLiquidity/beforeRemoveLiquidity` 必须与 V4 `sender/params` 逐项比对，强退还要求 `mode == FORCE_EXIT` 且全额负 delta。仓位保存不可变 owner、PoolKey、ticks、salt，流动性严格为正。Receipt tokenId 等于 positionId，只能由 LP Manager mint/burn，所有转移和授权入口回滚。用户 LP 操作仅允许 `msg.sender == position.owner == receipt.ownerOf(positionId)` 且共用 SBT 当前有效、未暂停；只允许已批准资产和 ACTIVE 池。强退例外见下段。

所有 LP 操作验证 deadline、tick 间隔、`0 < liquidity <= int128.max`（需要非零 liquidity 的操作）和 PoolManager 返回的**实际** `callerDelta`；`maxPoolIn* / minPoolOut*` 是两种池内 Currency 的原始单位边界。强退调用方必须传入两侧 raw `minPoolOut`，合约逐侧校验，具体下限由运营按执行时策略设置；若任一侧不足则整笔回滚并保留仓位。目标新操作的两个 `AssetBounds` 均全零。正流动性变化用 V4 `modifyLiquidity(+liquidity)`，减仓用负值；所有实际负 delta 直接从原 owner 拉取对应 Currency，正 delta 直接交付同一 Currency 给原 owner，并核对双方准确余额变化。`openPosition` 在同笔结算成功后 mint Receipt；`increaseLiquidity` 增加账本流动性；`decreaseLiquidity` 的 `liquidity < current` 且剩余严格为正；`collectFees` 只在 OPEN 且正流动性时使用 V4 零 delta，若两侧实际领取均为零则回滚；`closePosition` 一次负 delta 清空流动性，直接用该次包含费用的 `callerDelta` 结清、交付并 burn Receipt，不再调用零 delta。wTSLAx 与普通 ERC-20 完全共用这条直接结算路径，不调用包装/赎回 Adapter。

`forceExit` 仅 `REVOKE_EXIT_EXECUTOR` 或 `FORCE_EXIT_ADMIN`。前者还须在执行当时确认原 owner 的 SBT 凭证**已缺失**；仅 SBT 全局 paused 不算撤销。后者须传非零 reason/evidence。LP Manager 在 unlock 前设置精确 `(positionId,poolId,salt,forceExit)` 上下文，Hook 只允许对应的全额 remove；普通暂停、HALT、报告缺失或 Token DISABLED 不阻止该路径。所有应收资产只能交付仓位原 owner，调用者无 recipient 参数。两侧 Currency 均直接交付原 owner，并核对双方准确余额变化。两侧全部成功后关闭仓位并 burn Receipt；任何拒转整体回滚，仓位与 Receipt 保留。失败交易不产生持久失败事件，链下按失败 receipt 告警，沿用方案 A。本部署没有旧仓位，因此不定义旧 Adapter 退出分支。

**前端股数展示与 LP 报价。**前端用已批准 Adapter 的只读反向换算估计用户股数预算对应的股票 Currency raw 数量，再结合当前 V4 价格、tick 范围和另一侧资金预算估计 `liquidity`；开仓和加仓仍提交现有 `openPosition`／`increaseLiquidity` 与 raw `LPBounds`。减仓、关仓和领费时，前端按预计 raw 到账展示对应股数，提交现有流动性参数和 raw 到账下限。报价只是估计，实际 LP `callerDelta` 还可能包含已累积手续费；价格、发行方系数或账户余额变化后，实际显示股数可能变化，raw 边界不等于链上股数保证。LP Manager 不增加股数驱动入口，LP 操作也不调用 `recordSwap` 或占用成交额度。

## 7. 角色报告、计量日和额度

**当前规则：**旧 SIP 日历、`TradeDayReport`、窗口追加/替换和逐日必填 quota 均不属于当前 ABI，仅在历史评审资料中保留。当前 DataInbox 接受 `MarketReport`、单条 `AdtvReport`、批量 `AdtvReport[]` 和带 `action` 的 `QuotaReport`；报告不使用 EIP-712、签名或任意 relayer 代提，`msg.sender` 必须直接持有对应的 `HALT_REPORTER_ROLE` 或 `VOLUME_ORACLE_ROLE`。`sequence`、`reportId`、`sourceTimestamp` 和 `submitDeadline` 仍用于顺序、去重、来源审计和提交时限，不是签名机制。Router 的用户授权仍单独使用 EIP-712/ERC-1271。当前计量日由 VolumeLedger 根据 UTC 起点自动计算，不需要提交日历，也不需要心跳交易。

月度 ADTV 使用 `submitAdtvBatch(AdtvReport[] reports)` 批量入口。一个批次内所有报告必须属于同一 `sourceMonth`，`securityId` 必须按严格递增顺序排列且不得重复，批次长度为 `1..MAX_ADTV_BATCH_SIZE`（当前为 100），且整批由当前 `msg.sender` 以 `VOLUME_ORACLE_ROLE` 直接提交。批次采用全有或全无语义：任一报告无效，整笔交易回滚，不留下已接受的 ADTV、序号或 reportId。75 个证券的月度 ADTV 可由一笔批量交易提交；单条 `submitAdtv` 继续用于补发和纠错。批量提交不改变单报告的版本、序号、来源时间或截止时间规则。

**D-33：日配额是可选整日覆盖；当前 `src/v1/` 已实现以下规则。**当前 ABI 使用 `action` 字段；`VOLUME_ORACLE_ROLE` 地址直接提交：

1. 对每个 `(securityId,tradeDayId)` 保存 `QuotaOverride { uint256 quotaWad; bool active; uint64 version; bytes32 reportId; }`。从未提交、或已显式清除覆盖时，`active=false`；不能用 `quotaWad == 0` 判定 ADTV 缺失。新 TSV 计量日默认没有覆盖，不继承前一日状态。
2. `QuotaReport` 增加 `uint8 action`，只允许 `SET=1` 或 `CLEAR=2`。Solidity 字段顺序为 `bytes32 securityId,uint32 tradeDayId,uint8 action,uint256 quotaWad,uint64 sourceTimestamp,uint64 submitDeadline,uint64 version,uint64 sequence,bytes32 reportId,bytes32 sourceHash`；没有 `signer` 字段或签名参数。`SET` 要求证券已登记、该日所需 ADTV 已存在、`0 < quotaWad <=` 提交时的硬上限；`CLEAR` 要求原覆盖处于 active 且 `quotaWad == 0`。两者都要求该 key 的 version 严格加一、报告 ID 唯一、报告来源序号递增，发出包含 action、值、版本、reportId 的事件。不能把零配额当作暂停；暂停仍走 §8。
3. 每次 Swap 必须有按 D-34 自动算出的当前计量日、适用 ADTV、有效股票资产和 OPEN 市场状态。`hardCapWad == 0` 时拒绝；当日 `active=false` 时 `effectiveCapWad=hardCapWad`，否则 `effectiveCapWad=min(hardCapWad,quotaWad)`。要求 `usedWad[securityId][tradeDayId] + legalSharesWad <= effectiveCapWad`；`remaining` 在无覆盖但 ADTV 有效时返回有效及 `max(0,hardCapWad-usedWad)`。同日 SET/CLEAR 从成功提交交易之后影响后续 Swap，不修改已计成交或已用量；低于已用量时后续 Swap 失败。
4. 同一计量单位内，ADTV/Tier 更正后始终重新计算硬上限并取 `min`，既有覆盖值不能使有效上限超过新硬上限；上调硬上限不会自动解除较低的覆盖值。公司行动改变股数单位时仍须先暂停并执行[公司行动流程](./STATIC_RATIO_CORPORATE_ACTION_GAP.md)，不能拿不同单位的数值取 `min`。
5. 本版 `DataInbox` 完全移除报告签名机制。升级时必须同步切换 ABI、角色运营脚本、索引器和 Ledger；旧版待提交的签名报告不再有入口，已接受的 `reportId`、序号和账本状态保持不变。D-34 同版移除日历报告依赖。

**D-34：每个日期都是独立 TSV 计量日，日切点按未来排期更新；当前 `src/v1/` 已实现以下规则。**

1. 初始配置 `dayStartOffsetSeconds` 是部署清单中的 `uint32`，范围 `0..86399`；示例为 `14400`，即 UTC 04:00。配置在 Ledger 初始化时设置，禁止未初始化或超范围值。`tradeDayId` 是周期**开始时的 UTC 公历日期** `YYYYMMDD`，不是成交所在 UTC 自然日期，也不再表示外部 SIP 归属日。所有公历日期，包括周末和节假日，都有自己的 ID、额度和 `usedWad`。时间区间左闭右开，链上以 `block.timestamp` 判定；不引入本地时区或夏令时。
2. 对 UTC 日期 D，定义 `midnightUTC(D) = ordinal(D) * 86400`，`startUTC(D) = midnightUTC(D) + offsetFor(D)`，`endUTC(D) = startUTC(D+1)`。`offsetFor(D)` 为最大 `effectiveDayId <= D` 的已排期配置值，若无则为初始值。设 `N = UTCDate(block.timestamp / 86400)`；若 `block.timestamp >= startUTC(N)`，当前 `tradeDayId=N`，否则为 N 的前一日期。实现须使用覆盖闰年、月末、年末的公历整数转换，校验日期范围；不能直接把 Unix 日数强转成 `YYYYMMDD`。每次 Swap 只算一次日 ID，并用于计量、ADTV 源月、可选配额和事件；`sourceMonth` 是该 ID 所在月的上一自然月。`currentTradeDay()` 可保留现有 `(bool,uint32)` ABI，但初始化后的 `exists` 恒为 true，不再要求当前／下一窗口。
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

**当前代码**的 `VolumeLedger.recordSwap(poolId, delta0, delta1, snapshot0, snapshot1)` 只允许固定 Hook 代理调用；从 Registry 读取两侧 Currency/securityId/Adapter，并对股票 Currency 重读批准 Adapter 的 `snapshot`，要求与传入快照各字段相等，不能信任调用者传入的证券 ID 或比率；非股票腿快照必须全零且不计股数。它从区块时间和日切检查点确定计量日，读取适用 ADTV 与可选 quota 覆盖，并要求 `used + charge <= effectiveCapWad`。Ledger 源码逐侧处理 delta，但 Registry 建池门禁使双股票分支不可用于新池。任一必需输入缺失、停牌、暂停、零股、超额或快照变化，整笔交易回滚。Ledger 不向 DataInbox 提供写 `used` 的入口。

## 8. 暂停与准入状态

紧急暂停记录以递增 `recordId` 为主键，保存 `scope,target,reasonCode,sourceHash,openedBy,openedAt,active`；`GLOBAL/SECURITY/TOKEN/POOL` 目标分别是零、securityId、Token 地址、PoolId。`EMERGENCY_PAUSER` 只新增记录，`EMERGENCY_RESUMER` 只关闭指定仍活跃记录；每 scope/target 维护活跃计数，任何命中即阻止新 Swap 和用户 LP。关闭一条记录不影响同目标的其他记录。市场 HALTED 阻止新 Swap/用户 LP；目标规则中仅缺适用 ADTV 会因报告缺失阻止 Swap，日切自动发生，quota 可选；Token/Pool DISABLED 阻止新 Swap/用户 LP。池初始化只看建池准入，不受运行期 HALT/暂停阻止。强退仅绕过这些业务门禁，不绕过发行方 Token 自身的转账限制。

## 9. 代理、角色和升级

TSV 自有业务合约使用 UUPS 实现和 ERC-1967 代理；Hook 最终**代理地址**的低 14 位必须与固定 V4 回调权限匹配。`TSVERC1967Proxy` 继承仓库固定的 OZ `ERC1967Proxy`，在代理自身实现 `tsvImplementation()` 读取 ERC-1967 实现槽，该 selector 不能被业务实现复用。CREATE2 工厂挖掘的是代理创建字节码与初始化参数的最终地址。Hook 的回调权限和代理地址一经建池不得变化；升级只能替换逻辑。所有实现禁止直接初始化。

`TSVBusinessAuthority` 为非代理合约，保存一个 `governor` 地址和不可变 `upgradeTimelock`；业务合约动态读取该地址判断 `DEFAULT_ADMIN_ROLE`，不得留静态旧管理员。各业务角色的持有人是单独地址，合约只核对 `msg.sender` 的地址/角色，不检查这些地址背后的多签成员和门槛。Governor 可即时配置业务角色与参数；UpgradeTimelock 不持有业务角色。`_authorizeUpgrade` 只接受 UpgradeTimelock 或事故升级控制器，不接受业务管理员。

**D-35 目标与当前实现边界。**以上固定治理地址描述的是当前 Solidity。若要在原代理地址下具备 Timelock、BusinessAuthority、事故控制器的整体换址能力，须在生产部署前完成[架构 §2.3](./CONTRACT_ARCHITECTURE.md#23-治理与升级)的 `TSVGovernanceAnchor` 改造：八个代理只绑定同一固定 Anchor，业务根管理员和 UUPS 授权每次从 Anchor 读取；当前 Timelock 的受保护 Guardian 轮换还须在同笔交易内同步 Anchor。Anchor 仅接受 RecoveryCouncil 提案、当前 Guardian 独立批准后的三地址组原子切换，提案绑定迁移 epoch、Guardian 轮换序号、三地址及运行代码哈希；切换前核验新 Timelock、Authority、控制器的相互绑定、Governor／Guardian／Council、冻结状态、八个代理的事故升级允许名单与角色配置。失败整体回滚；成功后旧治理地址不再对这些代理生效。此目标尚未落入源码，Anchor ABI、存储布局、迁移状态机和部署顺序需作为实现任务冻结并审查，不能按本节现有 ABI 宣称已经支持治理根换址。

业务 `AccessControl` 的角色常量固定为 `keccak256("SYMBOL_ADMIN_ROLE")`、`keccak256("POOL_CREATOR_ROLE")`、`keccak256("HALT_REPORTER_ROLE")`、`keccak256("VOLUME_ORACLE_ROLE")`、`keccak256("EMERGENCY_PAUSER_ROLE")`、`keccak256("EMERGENCY_RESUMER_ROLE")`、`keccak256("REVOKE_EXIT_EXECUTOR_ROLE")`、`keccak256("FORCE_EXIT_ADMIN_ROLE")`，对应本文去掉 `_ROLE` 后缀的角色称呼。各业务合约覆写 `hasRole(DEFAULT_ADMIN_ROLE,account)`，只在 `account == BusinessAuthority.governor()` 时返回真；禁止经公开或内部授撤入口改变此根角色，其他业务角色仅由当前 Governor 授撤。`SBTAdapter.hasCredential(owner)` 只读 `verify(owner,tokenId)`，不把 SBT 的全局 `paused()` 解释为凭证缺失；普通用户入口另外检查 `!paused()`。

`TSVUpgradeTimelock` 继承仓库固定 OZ `TimelockController`：父类 `minDelay` 初始化为 0；`updateDelay` 恒回滚；每笔普通 `schedule` 的 `delaySeconds` 原样传给父类，可为 0 或任意父类可表示的 `uint256`，不增加最小/最大规则。Governor 和 RecoveryCouncil 都必须持父类 `PROPOSER_ROLE`，但覆写 `schedule`：Governor 只能排期普通操作，RecoveryCouncil 只能排期下段定义的精确受保护恢复，任何其他 proposer 一律回滚。覆写 `scheduleBatch` 只接受 Governor 且拒绝任何受保护恢复 selector。Executor 地址或开放执行标志来自部署清单，并始终额外授予 RecoveryCouncil `EXECUTOR_ROLE`，保证受保护恢复能由 Council 自行执行。Guardian 是唯一外部 `CANCELLER_ROLE` 持有人；部署时撤销父类构造过程给予两个 proposer 的 canceller。父类 `DEFAULT_ADMIN_ROLE` 最终只留给 Timelock 自己。覆写 `grantRole/revokeRole/renounceRole`，禁止外部入口改变 `DEFAULT_ADMIN_ROLE/PROPOSER_ROLE/CANCELLER_ROLE/EXECUTOR_ROLE`；受保护恢复内部才可用 `_grantRole/_revokeRole` 轮换固定 proposer/canceller。Governor 的普通排期不能调用 `recoverAuthorities`，也不能通过自调用任意改变这些角色。普通执行仍使用父类 `execute/executeBatch` 的 operationId、predecessor、salt 与 ready 时间规则。

事故升级控制器非代理，初始 `frozen=true`，保存 Governor、Guardian、受限 TSV 代理名单与已使用 `upgradeActionId`。`executeEmergencyUpgrade(proxy,newImplementation,initData,incidentId,upgradeActionId,reasonCode,evidenceHash)` 仅 Governor 且未冻结时可调用；目标在名单、实现有代码、行动 ID/证据非零且未用，先读代理 `tsvImplementation()` 和旧 codehash，调用 UUPS `upgradeToAndCall`，再要求代理实现地址为提交地址并记录新 codehash。它不能转发任意目标调用。`freezeEmergencyUpgrades(incidentId,reasonHash,freezeSalt)` 仅 Guardian 且当前未冻结；递增 epoch，`freezeId = keccak256(abi.encode(block.chainid,address(this),epoch,guardian,incidentId,freezeSalt))`；`unfreezeEmergencyUpgrades(expectedFreezeId,evidenceHash)` 仅 Timelock 普通操作，必须匹配当前 freezeId。冻结只阻断事故即时升级，不自动停止普通排期或业务交易。

独立 RecoveryCouncil 仅能排期 `target == Timelock`、`value == 0`、`predecessor == 0`、精确 `recoverAuthorities(newGovernor,newGuardian,evidenceHash)` calldata 的单项操作；由 Council 为该笔指定 `delaySeconds`，可为 0；`scheduleBatch` 一律拒绝 Council。新身份须非零、彼此不同、都不同于 RecoveryCouncil，且不得将旧 Guardian 直接作为新 Governor 或旧 Governor 直接作为新 Guardian；交叉轮换可经中间独立地址分两笔恢复。Timelock 对该 operationId 标记 `protectedRecovery=true`。执行该 ID 时覆写 `execute`，先核对目标、payload、predecessor 和保护标记，仅在父类执行该 payload 的动态范围内设置与 ID 绑定的 `recoveryContext`，调用完成后清除；`executeBatch` 不得执行含受保护 selector 的批次。`recoverAuthorities` 同时要求 `msg.sender == address(this)` 和上下文 ID 有效，原子更新控制器、BusinessAuthority 以及 Timelock proposer/canceller，失败整笔回滚。Governor 排期同 selector 被覆写入口拒绝。Guardian 的 `cancel` 对受保护 ID 回滚，对普通 Waiting/Ready ID 调父类；已执行操作不可取消。恢复不自动解冻，旧 Governor 的普通业务授权在根切换后立即失效。RecoveryCouncil 自身地址固定，无普通更换入口。

治理专用写入口 ABI 固定为：

```solidity
// TSVUpgradeTimelock；schedule/scheduleBatch/execute/executeBatch/cancel 沿用 OZ 5.5.0 ABI
function bindBusinessAuthority(address authority) external;
function recoverAuthorities(address newGovernor, address newGuardian, bytes32 evidenceHash) external;
function recoveryContextActive() external view returns (bool);
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

`bindBusinessAuthority` 只能由 Timelock 自身普通排期调用，且只成功一次。`setUpgradeTarget/unfreezeEmergencyUpgrades` 只能由 Timelock 普通排期调用。`setGovernor/setGuardian/recoverGovernor` 同时检查 `msg.sender == Timelock` 和 `Timelock.recoveryContextActive()`，必须比较 expected old 地址；`recoverAuthorities` 是唯一协调入口。`recoveryContextActive()` 只在受保护恢复调用栈内为真，返回前清零。`freezeEmergencyUpgrades` 要求当前未冻结且 `freezeSalt != 0`；`executeEmergencyUpgrade` 要求当前未冻结。控制器部署时 `frozen=true, freezeEpoch=0, freezeId=0`，首次普通排期解冻使用 `expectedFreezeId=0` 与非零证据哈希；以后每次 Guardian 冻结都生成非零新 ID。以上身份均是地址，不检查地址背后的多签配置。

代理升级、Adapter 更换和资产批准均须保留已有 PoolKey、已用日额度、Router 签名 nonce、暂停记录、LP 仓位/Receipt owner 与原 owner 交付路径。存储使用固定命名空间或经验证的追加布局；部署和每次升级须检查 layout、Hook 权限位、代理实现、角色、接口和历史仓位强退可达性。

## 10. 规范事件与错误

实现可增加诊断事件，但以下事件的名称、字段顺序和索引字段为对外契约；动态大对象以哈希记录，链下通过交易 calldata/归档状态复核。

```text
SecurityListed(bytes32 indexed securityId,bytes32 symbolHash,uint8 tierId,bytes32 evidenceHash)
SecurityDelisted(bytes32 indexed securityId,bytes32 evidenceHash)
SecurityTierChanged(bytes32 indexed securityId,uint8 oldTierId,uint8 newTierId,bytes32 evidenceHash)
TierPolicyChanged(uint8 indexed tierId,uint16 tierBps,uint32 maxListed,bytes32 evidenceHash)
TokenRegistered(address indexed poolCurrency,address indexed userToken,bytes32 indexed securityId,uint8 settlementMode,uint32 settlementVersion,bytes32 evidenceHash)
TokenStatusChanged(address indexed poolCurrency,uint8 oldStatus,uint8 newStatus,bytes32 evidenceHash)
SettlementAdapterChanged(address indexed poolCurrency,address oldAdapter,address newAdapter,uint32 settlementVersion,bytes32 evidenceHash)
LegalShareAdapterChanged(address indexed poolCurrency,address oldAdapter,address newAdapter,uint32 legalAdapterVersion,bytes32 evidenceHash)
PoolInitialized(bytes32 indexed poolId,uint160 sqrtPriceX96,address indexed creator,bytes32 priceBasisHash)
PoolStatusChanged(bytes32 indexed poolId,uint8 oldStatus,uint8 newStatus,bytes32 evidenceHash)
MarketStatusChanged(bytes32 indexed securityId,uint8 oldStatus,uint8 newStatus,uint64 sequence,bytes32 indexed reportId)
AdtvAccepted(bytes32 indexed securityId,uint32 indexed sourceMonth,uint256 adtvWad,uint64 version,bytes32 indexed reportId)
QuotaAccepted(bytes32 indexed securityId,uint32 indexed tradeDayId,uint8 action,uint256 quotaWad,uint64 version,bytes32 indexed reportId)
DayStartScheduled(uint32 indexed effectiveDayId,uint32 indexed transitionDayId,uint32 oldOffsetSeconds,uint32 newOffsetSeconds,uint64 effectiveStartUTC,address indexed operator,bytes32 reasonHash)
DayStartCancelled(uint32 indexed effectiveDayId,address indexed operator,bytes32 reasonHash)
SwapAccounted(bytes32 indexed poolId,bytes32 indexed securityId,address indexed poolCurrency,bool inputSide,uint32 tradeDayId,uint256 rawAmount,uint256 legalSharesWad,bytes32 rateId,uint32 legalAdapterVersion,uint8 roundingMode)
SwapExecuted(bytes32 indexed operationId,bytes32 indexed poolId,address indexed participant,bool zeroForOne,int128 amount0,int128 amount1,uint32 tradeDayId)
SwapNonceCancelled(address indexed participant,uint256 indexed nonce)
AuthorizedCallerChanged(address indexed caller,bool allowed)
PositionOpened(uint256 indexed positionId,address indexed owner,bytes32 indexed poolId,uint128 liquidity)
PositionChanged(uint256 indexed positionId,uint128 oldLiquidity,uint128 newLiquidity)
FeesCollected(uint256 indexed positionId,uint256 amount0,uint256 amount1)
PositionClosed(uint256 indexed positionId,address indexed owner,bool forced,bytes32 reasonCode)
SbtConfigChanged(address indexed oldSbt,address indexed newSbt,uint256 oldTokenId,uint256 newTokenId,bytes32 evidenceHash)
EmergencyPauseOpened(uint256 indexed recordId,uint8 scope,bytes32 indexed target,bytes32 reasonCode)
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

Timelock 的普通与受保护排期/执行沿用父类 `CallScheduled/CallExecuted`，普通取消沿用 `Cancelled`；`AccessControl` 角色变更沿用 OZ `RoleGranted/RoleRevoked`，Receipt mint/burn 沿用 ERC-721 `Transfer`。`AuthoritiesRecovered` 由 Timelock 发出，`BusinessGovernorRecovered` 由 Authority 发出；Guardian 未变化时 `newGuardian` 等于原地址。跨合约共用 custom errors 至少固定：`Unauthorized()`、`InvalidConfig()`、`InvalidPool()`、`InvalidStatus()`、`InvalidSignature()`、`NonceUnavailable()`、`Expired()`、`MissingReport()`、`InvalidPeriod()`、`StaleSnapshot()`、`ZeroSwapAmount()`、`NoFees()`、`SlippageExceeded()`、`SettlementMismatch()`、`QuotaExceeded(bytes32 securityId,uint32 tradeDayId)`、`Paused(uint8 scope,bytes32 target)`、`InvalidPosition()`、`DeliveryFailed()`、`UpgradeFrozen()`、`ProtectedOperation(bytes32 operationId)`。外部发行方 revert 应原样冒泡或包装成带底层 selector 的 `DeliveryFailed`，但不能吞掉失败继续结算。

## 11. 部署输入和验收向量

部署清单必须含 chainId、官方 PoolManager 地址及代码哈希、每个 TSV 代理地址和实现 codehash、Hook 权限位、SBT 地址/tokenId、Governor/Guardian/RecoveryCouncil/Executor 与各运营报告角色地址、Tier 参数、两个资产地址/decimals/代码哈希/代理实现、股票股数 Adapter 地址和版本、发行方权益依据、制裁/暂停与升级控制者、价格依据及首批 PoolKey。新资产的结算 Adapter 固定为零；本部署没有旧 LP 仓位或旧 SIP 日账，不设置旧 Adapter 退出分支或历史账本迁移清单。缺必填项部署脚本拒绝启用资产；所有身份按独立地址配置，不读取多签内部设置。

编码验收至少覆盖以下**给定输入→确定结果**；这些是实现验收样例，不替代源码审计和真实代理行为核验：

| 场景 | 必须得到的结果 |
| --- | --- |
| `STDx` 18 decimals、1 币一股、实际股票输入 `2e18` 原始单位 | `legalSharesWad = 2e18`；若输出侧是非股票币，仅该证券用量增加 |
| TSLAx `wrappedShares = 3e18`、`currentMultiplier = 0.9e18` | 按源码整数公式 `floor(3e18 * 0.9e18 / 1e18) = 2.7e18` 技术股数；在发行方/法务批准映射前资产不能 APPROVED |
| 两枚股票 Currency 申请登记同一池 | `registerPendingPool` 回滚，池状态保持 `ABSENT`；相同与不同 `securityId` 均拒绝 |
| exact input 因价格边界只成交一部分，且输出仍达到下限 | 只拉取实际输入、只按实际两腿 delta 记账；满足所有用户边界才成功 |
| exact output 未完整达到指定输出 | 整笔回滚，不允许部分交付 |
| wTSLAx 或配对币向用户、原 LP owner 精确转账失败 | V4 仓位/成交、另一侧交付、额度及 Receipt 全部回滚，仓位保持可重试；本部署不执行 TSLAx 包装或赎回 |
| HALT 状态一整月未变化 | 无心跳要求；在下一次有效 RESUME 或紧急暂停前保持 HALTED |
| ADTV 数值不变但进入新适用月份；新计量日没有配额覆盖报告 | 必须有新适用月份 ADTV；新日无配额时使用硬上限，不因缺配额报告拒绝 Swap |
| Guardian 已冻结事故升级入口，普通升级已排期 | 事故即时升级失败；普通排期按其自身 ready 时间仍可执行 |

完整的测试 ID、fixture、三份外部源码集成、fuzz/invariant、fork 与通过门槛见规范性文件 [V1 测试规格](./TEST_SPEC_V1.md)。上表只是手算验收向量，不能代替其中的测试覆盖。构建交付包含完整 ABI、存储布局清单、Router 的 EIP-712 类型哈希常量、部署/配置脚本、事件索引说明、测试结果及上述行为的可复算案例。**代码完成**与**生产启用**分开验收：wTSLAx 动态权益映射的发行方/法务批准、实际代理 ABI/制裁矩阵/精确转账行为、gas 最坏情况和强退可达性仍是外部事实门禁；它们没有确认时合约可实现，但 wTSLAx 必须保持 `UNREVIEWED`，不得创建其活跃生产池。

## 12. 对外 ABI 清单与调用权限

下表列出**当前目标 ABI**。SIP 日历入口已从当前代码移除；Quota 保留 `action`，DataInbox 报告入口不接受签名或 signer 字段，直接按 `msg.sender` 角色授权。Swap 和 LP 的 `AssetBounds` 八个字段强制为零，Router 签名域版本为 `2`。`replaceSettlementAdapter` 在新资产流程中停用并拒绝调用；目标新操作不得调用 `IssuerShareSettlementAdapter`。struct 使用 §2/§5/§6/§7 的定义；`bytes32 poolId` 统一为 `PoolId.unwrap(key.toId())`。表内未列出的状态写入口不得对外开放。所有状态写入口成功后发 §10 的对应事件，失败不得留下状态。

| 合约 | 外部入口 | 调用者及主要约束 |
| --- | --- | --- |
| Registry | `listSecurity(bytes32 securityId,bytes32 symbolHash,uint8 tierId,bytes32 evidenceHash)`、`relistSecurity(bytes32 securityId,bytes32 evidenceHash)`、`setSecurityTier(bytes32 securityId,uint8 tierId,bytes32 evidenceHash)`、`delistSecurity(bytes32 securityId,bytes32 evidenceHash)`、`setTierPolicy(uint8 tierId,uint16 tierBps,uint32 maxListed,bytes32 evidenceHash)` | 前四项 `SYMBOL_ADMIN`，政策修改仅 Governor；activePoolCount/version 由合约派生，Tier 名额按不同 securityId 计算，活动池未全停用不得下架 |
| Registry | `registerToken(TokenConfig,bytes32 evidenceHash)`、`setTokenStatus(address poolCurrency,TokenStatus,bytes32 evidenceHash)`、`replaceSettlementAdapter(address poolCurrency,address newAdapter,bytes32 evidenceHash)`、`replaceLegalShareAdapter(address poolCurrency,address newAdapter,bytes32 evidenceHash)` | `SYMBOL_ADMIN`；仅按 §2 的状态、暂停、版本和旧仓位不变量变更 |
| Registry | `registerPendingPool(PoolKey)`、`markPoolActive(bytes32 poolId,uint160 sqrtPriceX96,address creator,bytes32 priceBasisHash)` | 仅 LP Manager；两个调用与 PoolManager.initialize 必须在同一外部交易成功 |
| Registry | `disablePool(bytes32 poolId,bytes32 evidenceHash)`、`enablePool(bytes32 poolId,bytes32 evidenceHash)` | `SYMBOL_ADMIN`；enable 重查两侧资产批准、市场与准入，不更改 PoolKey |
| Registry | `addEmergencyPause(PauseScope scope,bytes32 target,bytes32 reasonCode,bytes32 sourceHash)`、`clearEmergencyPause(uint256 recordId,bytes32 reasonCode)` | 分别仅 `EMERGENCY_PAUSER` 与 `EMERGENCY_RESUMER`；活跃计数逐条更新 |
| Registry | `getToken(address poolCurrency)`、`currencyOf(address userToken)`、`getPool(bytes32 poolId)`、`isTradable(bytes32 poolId)`、`isKnownPool(bytes32 poolId)` | 只读；`isKnownPool` 对停用历史池仍为真，供强退 |
| DataInbox | `submitMarketStatus(MarketReport)`、`submitAdtv(AdtvReport)`、`submitAdtvBatch(AdtvReport[])`、`submitQuota(QuotaReport)` | `msg.sender` 必须直接持有对应角色；批量 ADTV 同月、securityId 严格递增、最多 100 条且整批原子提交；不接受报告签名或任意 relayer 代提；序号、reportId 和期间规则按 §7；状态分别写 Registry/VolumeLedger 的仅 DataInbox 入口 |
| VolumeLedger | `recordSwap(bytes32 poolId,int128 delta0,int128 delta1,RateSnapshot snapshot0,RateSnapshot snapshot1)` | 仅固定 Hook 代理；从 Registry 重读资产身份，双侧额度原子检查/增加 |
| VolumeLedger | `scheduleDayStart(uint32 newOffsetSeconds,uint32 effectiveDayId,bytes32 reasonHash)`、`cancelPendingDayStart(bytes32 reasonHash)` | 仅 Governor；未来边界排期、单次偏差上限与过渡日锁定按 §7 |
| VolumeLedger | `currentTradeDay()`、`dayStartUTC(uint32 dayId)`、`dayStartCheckpointCount()`、`dayStartCheckpoint(uint256 index)`、`initialDayStartOffsetSeconds()`、`remaining(bytes32 securityId,uint32 tradeDayId)`、`used(bytes32 securityId,uint32 tradeDayId)` | 只读；初始化后 `currentTradeDay.exists == true`；ADTV 缺失时 `remaining` 返回无效标志 |
| SBTAdapter | `isEligible(address owner)`、`hasCredential(address owner)`、`setSbtConfig(address sbt,uint256 tokenId,bytes32 evidenceHash)` | 前两项只读；配置仅当前 Governor，切换需迁移依据 |
| Hook | V4 `IHooks` 的十个回调均由 `0x3FFF` 地址位启用、`assertCurrentAndClear(bytes32 operationId)` | 回调仅 PoolManager；四种返回 delta 当前均为零；donate 回调回滚；finalize 仅当前 Router，且必须为已计量操作 |
| Router | §5 两个 Swap 入口、`cancelSwapNonce(uint256)`、`setAuthorizedCaller(address caller,bool allowed)`、`activeSwapOperation(bytes32)`、`activeAssetOperation(bytes32,address)` | Swap/取消按 §5；白名单配置仅 Governor；上下文只读接口只在活跃操作内返回有效值 |
| LP Manager | §6 七个 LP/建池入口、`activeAssetOperation(bytes32,address)`、`activeLPContext(bytes32)` | 建池仅 POOL_CREATOR；普通 LP 仅原 owner；强退两类专职角色；上下文只读 |
| Receipt | ERC-721 `ownerOf`、`balanceOf`、LP Manager 专用 mint/burn | 所有转移和 approve 系列入口回滚；tokenId 等于 positionId |
| UpgradeTimelock/事故控制器/BusinessAuthority | `bindBusinessAuthority`、`bindEmergencyController`、§9 的 schedule/execute/cancel、冻结/解冻/即时升级、受保护恢复 | 精确 caller、目标、operationId、freezeId 和恢复上下文按 §9 |

`MarketReport/AdtvReport/QuotaReport` 的 Solidity 字段类型和顺序逐项等于 `src/v1/types/TSVReports.sol`，不额外嵌套、重排或使用 `string` 代替 `bytes32`；报告结构不含 `signer` 字段，也没有签名参数；`QuotaReport.action` 为 `uint8`。TradeDayReport 只属于历史资料，当前接口不再接受该类型。当前 getter 对未知主键返回 Solidity 默认结构；调用方必须检查 `status`、`poolCurrency`、`securityId`、`version` 或报告 `version/reportId` 等存在性字段，不能把零值当作有效配置。`Tier` 的规范存储为 `tierBps uint16`、`maxListed uint32`、`listedCount uint32`，Governor 修改 `tierBps/maxListed` 要求 `1 <= tierBps <= 10000` 且新 `maxListed >= listedCount`，变更对未来 Swap 立即生效而不清除历史额度。

`SettlementAdapterChanged` 事件和 `replaceSettlementAdapter` selector 仅为存储/ABI 兼容保留；当前替换入口始终回滚，生产路径不会发出该事件。`LegalShareAdapterChanged` 只在暂停或无活跃池、版本递增且新 Adapter 快照通过校验时发出。
