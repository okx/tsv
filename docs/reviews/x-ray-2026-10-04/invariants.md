# Invariant Map

> TSV V1 | 187 guards | 49 inferred | 2 not enforced on-chain

范围：18个自有source文件，2491 nSLOC；interface与外部仓库只作为调用语义辅助。性质针对HEAD 44012cb当前实现；成功后/静止状态条件显式说明，未来任意implementation不在该保证范围。On-chain=No的两项为已在规格中列出的法律单位语义前提，未作为已确认漏洞。

---

## 1. Enforced Guards (Reference)

下列为本范围显式if-revert/require/assert的拒绝谓词，省略纯日历输入检查及外部库内部检查。多行谓词仅折叠空白，原始表达式保存在guard-data.json；`|`不会改写。每个guard是调用条件，不自动成为全局性质。

#### G-1
`underlying_ == address(0) || wrapped_ == address(0) || underlying_ == wrapped_ || version_ == 0 || underlying_.code.length == 0 || wrapped_.code.length == 0` · `src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol:44` · 固定Backed转换来源与池Currency的有效身份，避免无效依赖成为股数基准（拒绝时InvalidAdapterConfig）。

#### G-2
`IBackedWrappedAsset(wrapped_).asset() != underlying_ || IBackedShareConversionSource(underlying_).decimals() != 18 || IBackedWrappedAsset(wrapped_).decimals() != 18` · `src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol:48` · 确保包装资产指向该issuer且双方18位精度与WAD约定一致（拒绝时InvalidAdapterConfig）。

#### G-3
`currency != poolCurrency` · `src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol:75` · 避免把其他Currency的raw金额用此Adapter解释（拒绝时InvalidCurrency）。

#### G-4
`legalSharesWad == 0` · `src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol:79` · 避免正数stock成交以零股数通过换算（拒绝时InvalidConversion）。

#### G-5
`currency_ == address(0) || currency_.code.length == 0 || version_ == 0` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol:23` · 确保ERC8056Adapter只绑定有效Currency及可追溯非零版本（拒绝时InvalidAdapterConfig）。

#### G-6
`decimals_ > 18` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol:25` · 使raw-to-WAD缩放指数处于支持范围（拒绝时InvalidAdapterConfig）。

#### G-7
`legalSharesWad == 0` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol:44` · 避免正数成交因换算舍入而记为零股数（拒绝时InvalidRate）。

#### G-8
`currency != poolCurrency` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol:48` · 使动态multiplier查询来自本Adapter绑定的Currency（拒绝时InvalidCurrency）。

#### G-9
`multiplier == 0 || decimals_ > 18` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol:54` · 保持实时换算分子非零与支持的精度范围（拒绝时InvalidAdapterConfig）。

#### G-10
`registry_ == address(0) || ledger_ == address(0)` · `src/v1/core/TSVDataInboxV1.sol:35` · 保证Inbox具有可供后续报告转发的Registry/Ledger引用（拒绝时InvalidReport）。

#### G-11
`report.securityId == 0 || report.mode == PauseMode.NONE || report.reasonCode == 0 || report.exchangeHash == 0` · `src/v1/core/TSVDataInboxV1.sol:53` · 为市场操作保留明确证券、暂停类型和链外原因/来源证据（拒绝时InvalidReport）。

#### G-12
`reports.length == 0 || reports.length > MAX_ADTV_BATCH_SIZE` · `src/v1/core/TSVDataInboxV1.sol:70` · 限制原子ADTV批次的工作量及空批次语义（拒绝时InvalidReport）。

#### G-13
`report.securityId == 0 || report.sourceMonth != sourceMonth || (i != 0 && uint256(report.securityId) <= uint256(previousSecurityId))` · `src/v1/core/TSVDataInboxV1.sol:78` · 维护单一来源月且每证券恰出现一次的批次结构（拒绝时InvalidReport）。

#### G-14
`!hasRole(role, msg.sender)` · `src/v1/core/TSVDataInboxV1.sol:156` · 阻止未获reporter角色的地址写入报告流（拒绝时UnauthorizedReporter）。

#### G-15
`(uint160(address(this)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS` · `src/v1/core/TSVHookV1.sol:66` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidHookAddress）。

#### G-16
`poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0 || router_.code.length == 0 || lpManager_.code.length == 0` · `src/v1/core/TSVHookV1.sol:67` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidOperation）。

#### G-17
`msg.sender != address(poolManager)` · `src/v1/core/TSVHookV1.sol:80` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时UnauthorizedCallback）。

#### G-18
`params.liquidityDelta <= 0 || (ctx.mode != LPOperationMode.OPEN && ctx.mode != LPOperationMode.INCREASE) || !registry.isLPAllowed(ctx.poolId)` · `src/v1/core/TSVHookV1.sol:127` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidOperation）。

#### G-19
`params.liquidityDelta > 0 || ctx.mode == LPOperationMode.OPEN || ctx.mode == LPOperationMode.INCREASE` · `src/v1/core/TSVHookV1.sol:162` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidOperation）。

#### G-20
`params.liquidityDelta >= 0` · `src/v1/core/TSVHookV1.sol:166` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidOperation）。

#### G-21
`!registry.isLPAllowed(ctx.poolId)` · `src/v1/core/TSVHookV1.sol:167` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidPool）。

#### G-22
`sender != router || hookData.length != 0` · `src/v1/core/TSVHookV1.sol:202` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时UnauthorizedCallback）。

#### G-23
`!registry.isTradable(poolId)` · `src/v1/core/TSVHookV1.sol:204` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidOperation）。

#### G-24
`sender != router || hookData.length != 0` · `src/v1/core/TSVHookV1.sol:223` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时UnauthorizedCallback）。

#### G-25
`sender != lpManager || address(key.hooks) != address(this) || registry.getPool(PoolId.unwrap(key.toId())).status != PoolStatus.PENDING` · `src/v1/core/TSVHookV1.sol:260` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidPool）。

#### G-26
`keccak256(abi.encode(pool.key)) != keccak256(abi.encode(key))` · `src/v1/core/TSVHookV1.sol:272` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidPool）。

#### G-27
`sender != lpManager || hookData.length != 0` · `src/v1/core/TSVHookV1.sol:287` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时UnauthorizedCallback）。

#### G-28
`ctx.poolId == 0 || ctx.poolId != PoolId.unwrap(key.toId()) || ctx.salt != params.salt || ctx.tickLower != params.tickLower || ctx.tickUpper != params.tickUpper || ctx.liquidityDelta != params.liquidityDelta` · `src/v1/core/TSVHookV1.sol:289` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidOperation）。

#### G-29
`config.securityId != securityId || config.legalShareAdapter == address(0)` · `src/v1/core/TSVHookV1.sol:305` · 将PM回调约束到准入池及当前授权Router/LP操作（拒绝时InvalidPool）。

#### G-30
`hook != address(0) || lpManager != address(0) || dataInbox != address(0)` · `src/v1/core/TSVRegistryV1.sol:162` · 使Registry组件链接仅在空状态下绑定一次（拒绝时InvalidStatus）。

#### G-31
`hook_.code.length == 0 || lpManager_.code.length == 0 || dataInbox_.code.length == 0` · `src/v1/core/TSVRegistryV1.sol:163` · 确保预绑定目标具备代码供callback与writer检查使用（拒绝时InvalidConfig）。

#### G-32
`tierId == 0 || tierBps == 0 || tierBps > 10_000 || maxListed < tier.listedCount || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:179` · 保持Tier比例、已占用名额和新容量上限一致（拒绝时InvalidConfig）。

#### G-33
`sbt_.code.length == 0 || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:199` · 让资格服务配置带有可调用目标和准入证据（拒绝时InvalidConfig）。

#### G-34
`address(participantSbt) == address(0)` · `src/v1/core/TSVRegistryV1.sol:221` · 避免缺失资格服务时将撤证与未配置混为一谈（拒绝时SbtNotConfigured）。

#### G-35
`address(participantSbt) == address(0)` · `src/v1/core/TSVRegistryV1.sol:229` · 让普通用户资格查询在确定的SBT服务上执行（拒绝时SbtNotConfigured）。

#### G-36
`securityId == 0 || symbolHash == 0 || evidenceHash == 0 || securities[securityId].securityId != 0 || symbolToSecurity[symbolHash] != 0 || config.securityId != securityId` · `src/v1/core/TSVRegistryV1.sol:246` · 使证券ID、symbol及其初始Currency保持唯一对应（拒绝时InvalidConfig）。

#### G-37
`config.securityId == 0 || config.listed || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:262` · 只对既有且已退市证券恢复上市并保留原身份（拒绝时InvalidStatus）。

#### G-38
`!config.listed || config.tierId == tierId || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:278` · 把Tier迁移限定为已上市证券且确有归属变化（拒绝时InvalidStatus）。

#### G-39
`!config.listed || config.activePoolCount != 0 || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:292` · 保证证券退市前已解除其所有活跃池关联（拒绝时InvalidStatus）。

#### G-40
`config.poolCurrency == address(0) || config.status != TokenStatus.APPROVED || evidenceHash == 0 || tokens[config.poolCurrency].poolCurrency != address(0) || config.poolDecimals > 18 || config.reviewHash == 0 || config.poolCurrency.code.length == 0` · `src/v1/core/TSVRegistryV1.sol:315` · 维持Currency首次注册、支持精度及完整准入证据（拒绝时InvalidConfig）。

#### G-41
`config.poolCurrency.codehash != config.poolRuntimeCodeHash || IERC20DecimalsV1(config.poolCurrency).decimals() != config.poolDecimals` · `src/v1/core/TSVRegistryV1.sol:320` · 把准入记录与当时观察到的raw单位和runtime代码对应（拒绝时InvalidConfig）。

#### G-42
`config.legalShareAdapter != address(0) || config.legalAdapterCodeHash != 0 || config.legalAdapterVersion != 0 || config.legalSharePolicyHash != 0` · `src/v1/core/TSVRegistryV1.sol:325` · 避免quote Currency携带stock专属法律股配置（拒绝时InvalidConfig）。

#### G-43
`!securities[config.securityId].listed || config.legalShareAdapter.code.length == 0 || config.legalAdapterVersion != 1 || config.legalSharePolicyHash == 0 || config.legalShareAdapter.codehash != config.legalAdapterCodeHash` · `src/v1/core/TSVRegistryV1.sol:330` · 让stock Currency引用已上市证券及初始受审Adapter版本（拒绝时InvalidConfig）。

#### G-44
`config.poolCurrency == address(0) || evidenceHash == 0 || config.status == status` · `src/v1/core/TSVRegistryV1.sol:355` · 只更改既有Token状态并记录状态变化依据（拒绝时InvalidStatus）。

#### G-45
`status == TokenStatus.ABSENT` · `src/v1/core/TSVRegistryV1.sol:356` · 禁止清除准入身份并重复初始化已登记Currency（拒绝时InvalidStatus）。

#### G-46
`config.reviewHash == 0 || (config.securityId != 0 && config.legalSharePolicyHash == 0) || config.poolCurrency.codehash != config.poolRuntimeCodeHash` · `src/v1/core/TSVRegistryV1.sol:358` · 重新批准时保持代码与股数审查证据有效（拒绝时InvalidConfig）。

#### G-47
`config.securityId != 0 && !securities[config.securityId].listed` · `src/v1/core/TSVRegistryV1.sol:362` · 避免重新批准引用已退市证券的stock Currency（拒绝时InvalidStatus）。

#### G-48
`config.poolCurrency == address(0) || config.securityId == 0 || newAdapter == config.legalShareAdapter || newAdapter.code.length == 0 || evidenceHash == 0 || !_assetPausedForReplacement(currency)` · `src/v1/core/TSVRegistryV1.sol:378` · 只在资产无活跃池或TRADE和LP均覆盖暂停时更换stock Adapter（拒绝时InvalidConfig）。

#### G-49
`msg.sender != lpManager` · `src/v1/core/TSVRegistryV1.sol:403` · 限制池准入存储写入到绑定LP Manager（拒绝时InvalidPool）。

#### G-50
`address(key.hooks) != hook || c0 == address(0) || c0 >= c1 || key.fee >= 1_000_000 || key.tickSpacing < 1 || key.tickSpacing > 32767 || tokens[c0].status != TokenStatus.APPROVED || tokens[c1].status != TokenStatus.APPROVED` · `src/v1/core/TSVRegistryV1.sol:406` · 使登记PoolKey符合已准入Currency、Hook与V4参数前提（拒绝时InvalidPool）。

#### G-51
`s0 != 0 && s1 != 0` · `src/v1/core/TSVRegistryV1.sol:413` · 保持每池至多一stock腿的计量模型（拒绝时InvalidPool）。

#### G-52
`pools[poolId].status != PoolStatus.ABSENT` · `src/v1/core/TSVRegistryV1.sol:415` · 保留PoolId首次登记的完整key与证券归属（拒绝时InvalidPool）。

#### G-53
`msg.sender != lpManager || pools[poolId].status != PoolStatus.PENDING` · `src/v1/core/TSVRegistryV1.sol:426` · 把ACTIVE转换限定为绑定LP Manager完成的PENDING池（拒绝时InvalidPool）。

#### G-54
`pool.status != PoolStatus.ACTIVE || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:443` · 使停用计数只对应当前活跃池（拒绝时InvalidStatus）。

#### G-55
`pool.status != PoolStatus.DISABLED || evidenceHash == 0` · `src/v1/core/TSVRegistryV1.sol:458` · 使启用计数只对应当前已停用池（拒绝时InvalidStatus）。

#### G-56
`tokens[c0].status != TokenStatus.APPROVED || tokens[c1].status != TokenStatus.APPROVED || (pool.securityId0 != 0 && !securities[pool.securityId0].listed) || (pool.securityId1 != 0 && !securities[pool.securityId1].listed)` · `src/v1/core/TSVRegistryV1.sol:461` · 重新启用前仍须满足两个Currency和证券的准入条件（拒绝时InvalidStatus）。

#### G-57
`!_isOperationAllowed(poolId, PauseMode.TRADE) || !_isOperationAllowed(poolId, PauseMode.LP)` · `src/v1/core/TSVRegistryV1.sol:468` · 避免池启用绕过当前TRADE或LP暂停组合（拒绝时InvalidStatus）。

#### G-58
`securities[securityId].securityId == 0` · `src/v1/core/TSVRegistryV1.sol:496` · 区分未知证券与默认OPEN的既有证券（拒绝时InvalidConfig）。

#### G-59
`msg.sender != dataInbox || securityId == 0 || !securities[securityId].listed || sequence <= marketSequence[securityId] || mode == PauseMode.NONE` · `src/v1/core/TSVRegistryV1.sol:513` · 只由绑定Inbox按递增序号更新已上市证券的市场状态（拒绝时InvalidStatus）。

#### G-60
`nextMode == oldMode` · `src/v1/core/TSVRegistryV1.sol:523` · 让市场操作确实改变所选暂停位（拒绝时InvalidStatus）。

#### G-61
`mode == PauseMode.NONE || reasonCode == 0 || sourceHash == 0 || (scope == PauseScope.GLOBAL && target != 0) || (scope != PauseScope.GLOBAL && target == 0)` · `src/v1/core/TSVRegistryV1.sol:544` · 使紧急记录拥有明确scope/target/mode及原因证据（拒绝时InvalidConfig）。

#### G-62
`!record.active || reasonCode == 0` · `src/v1/core/TSVRegistryV1.sol:560` · 阻止单条暂停记录被重复清除并重复减少计数（拒绝时InvalidStatus）。

#### G-63
`tierId == 0 || tier.tierBps == 0 || tier.listedCount >= tier.maxListed` · `src/v1/core/TSVRegistryV1.sol:607` · 只有已配置且仍有名额的Tier能够增加证券计数（拒绝时InvalidConfig）。

#### G-64
`!supported` · `src/v1/core/TSVRegistryV1.sol:618` · 要求候选Adapter明确提供直接股数转换接口（拒绝时InvalidConfig）。

#### G-65
`directAdapter.poolCurrency() != currency || directAdapter.adapterVersion() != version` · `src/v1/core/TSVRegistryV1.sol:622` · 使Registry记录与Adapter自述Currency及版本一致（拒绝时InvalidConfig）。

#### G-66
`registry_ == address(0) || dayStartOffsetSeconds >= SECONDS_PER_DAY` · `src/v1/core/TSVVolumeLedgerV1.sol:161` · 确保Ledger有Registry且初始日切偏移可表示有效计量日（拒绝时InvalidReport）。

#### G-67
`hook != address(0) || dataInbox != address(0) || hook_.code.length == 0 || dataInbox_.code.length == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:170` · 使Ledger的Hook/Inbox写入目标只绑定一次（拒绝时InvalidReport）。

#### G-68
`msg.sender != dataInbox` · `src/v1/core/TSVVolumeLedgerV1.sol:180` · 防止Ledger接受绑定Hook/Inbox之外的计量或报告写入（拒绝时UnauthorizedWriter）。

#### G-69
`report.securityId == 0 || report.adtvWad == 0 || !TradeDayLib.validMonth(report.sourceMonth) || !registry.getSecurity(report.securityId).listed` · `src/v1/core/TSVVolumeLedgerV1.sol:187` · 只接受已上市证券的非零、有效来源月ADTV基数（拒绝时InvalidReport）。

#### G-70
`report.version != current.version + 1` · `src/v1/core/TSVVolumeLedgerV1.sol:192` · 使同一月度ADTV版本连续而非覆盖旧版本编号（拒绝时InvalidReport）。

#### G-71
`report.securityId == 0 || !registry.getSecurity(report.securityId).listed` · `src/v1/core/TSVVolumeLedgerV1.sol:207` · 把quota报告限制到当前已上市证券（拒绝时InvalidReport）。

#### G-72
`report.version != current.version + 1` · `src/v1/core/TSVVolumeLedgerV1.sol:209` · 使同证券/日quota版本连续（拒绝时InvalidReport）。

#### G-73
`hardCap == 0 || report.quotaWad == 0 || report.quotaWad > hardCap` · `src/v1/core/TSVVolumeLedgerV1.sol:213` · 创建的quota为正且不大于提交时的硬上限（拒绝时InvalidReport）。

#### G-74
`!current.active || report.quotaWad != 0` · `src/v1/core/TSVVolumeLedgerV1.sol:217` · 让CLEAR仅撤销已有quota并以零值表示取消（拒绝时InvalidReport）。

#### G-75
`report.securityId == 0 || !registry.getSecurity(report.securityId).listed || !TradeDayLib.validMonth(report.sourceMonth) || TradeDayLib.previousMonth(report.effectiveTradeDayId) != report.sourceMonth || report.version != splitFactorVersions[report.securityId][report.sourceMonth] + 1` · `src/v1/core/TSVVolumeLedgerV1.sol:235` · 把factor版本和目标日对应的前月ADTV基准固定在同一报告key（拒绝时InvalidReport）。

#### G-76
`report.effectiveTradeDayId <= currentDay` · `src/v1/core/TSVVolumeLedgerV1.sol:242` · 防止当前或历史计量日的factor被改写（拒绝时InvalidReport）。

#### G-77
`factors[count - 1].effectiveTradeDayId != report.effectiveTradeDayId` · `src/v1/core/TSVVolumeLedgerV1.sol:254` · 只允许原地修正最后一个同日期的未来factor（拒绝时InvalidReport）。

#### G-78
`report.numerator != 0 || report.denominator != 0 || count == 0 || factors[count - 1].effectiveTradeDayId != report.effectiveTradeDayId` · `src/v1/core/TSVVolumeLedgerV1.sol:270` · 只取消最后一个匹配日期的future factor（拒绝时InvalidReport）。

#### G-79
`newOffsetSeconds >= SECONDS_PER_DAY || reasonHash == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:339` · 保持排期偏移在一天范围内并有运营依据（拒绝时InvalidPeriod）。

#### G-80
`block.timestamp < _dayStartUTC(priorEffectiveDayId)` · `src/v1/core/TSVVolumeLedgerV1.sol:342` · 在旧日切排期尚未生效时保留唯一待生效排期（拒绝时InvalidPeriod）。

#### G-81
`ordinal == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:346` · 使过渡日前一日能在支持日历中表示（拒绝时InvalidPeriod）。

#### G-82
`newOffsetSeconds == oldOffset` · `src/v1/core/TSVVolumeLedgerV1.sol:350` · 避免创建不改变边界的日切checkpoint（拒绝时InvalidPeriod）。

#### G-83
`shift > MAX_DAY_START_SHIFT` · `src/v1/core/TSVVolumeLedgerV1.sol:352` · 把单次日切变化约束在最多4小时（拒绝时InvalidPeriod）。

#### G-84
`dayStartCheckpoints.length != 0 && effectiveDayId <= dayStartCheckpoints[dayStartCheckpoints.length - 1].effectiveDayId` · `src/v1/core/TSVVolumeLedgerV1.sol:353` · 使日切checkpoint按生效日严格有序（拒绝时InvalidPeriod）。

#### G-85
`block.timestamp >= _dayStartUTC(transitionDayId)` · `src/v1/core/TSVVolumeLedgerV1.sol:361` · 避免新增日切排期改变已开始的过渡日（拒绝时InvalidPeriod）。

#### G-86
`!hasPendingDayStart || reasonHash == 0 || count == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:375` · 只取消真实存在的待生效日切checkpoint（拒绝时InvalidPeriod）。

#### G-87
`block.timestamp >= _dayStartUTC(transitionDayId)` · `src/v1/core/TSVVolumeLedgerV1.sol:378` · 避免取消排期改变已开始的历史计量日（拒绝时InvalidPeriod）。

#### G-88
`ordinal == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:412` · 确保UTC偏移下前一计量日能由日历表示（拒绝时InvalidPeriod）。

#### G-89
`msg.sender != hook` · `src/v1/core/TSVVolumeLedgerV1.sol:463` · 防止Ledger接受绑定Hook/Inbox之外的计量或报告写入（拒绝时UnauthorizedWriter）。

#### G-90
`delta0 == 0 || delta1 == 0 || (delta0 < 0) == (delta1 < 0)` · `src/v1/core/TSVVolumeLedgerV1.sol:464` · 把stock计量限制在双leg非零且方向相反的实际swap（拒绝时ZeroSwapAmount）。

#### G-91
`pool.status != PoolStatus.ACTIVE || !registry.isTradable(poolId)` · `src/v1/core/TSVVolumeLedgerV1.sol:466` · 消费预算前再次确认pool与当前交易许可（拒绝时InvalidPeriod）。

#### G-92
`legalSharesWad != 0` · `src/v1/core/TSVVolumeLedgerV1.sol:488` · 让非stock腿不消费法律股预算（拒绝时InvalidLegalShareAmount）。

#### G-93
`legalSharesWad == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:491` · 让每个成功stock leg产生正数法律股charge（拒绝时InvalidLegalShareAmount）。

#### G-94
`config.securityId != securityId || config.legalShareAdapter == address(0) || config.legalAdapterVersion == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:493` · 使stock腿的证券归属与已准入转换配置对应（拒绝时InvalidLegalShareAmount）。

#### G-95
`hardCap == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:511` · 拒绝缺乏适用非零ADTV硬预算的stock记账（拒绝时MissingReport）。

#### G-96
`next > _effectiveCap(securityId, day, hardCap)` · `src/v1/core/TSVVolumeLedgerV1.sol:513` · 把新增法律股数限制在成交时的effective cap（拒绝时QuotaExceeded）。

#### G-97
`numerator == 0 || denominator == 0` · `src/v1/core/TSVVolumeLedgerV1.sol:543` · 保持精确factor约分的分子分母非零（拒绝时InvalidReport）。

#### G-98
`data.length == 0` · `src/v1/deployment/TSVERC1967Proxy.sol:16` · 使proxy创建时即初始化，避免空初始化窗口（拒绝时EmptyInitializationData）。

#### G-99
`implementation.code.length == 0 || initData.length == 0` · `src/v1/deployment/TSVHookProxyFactoryV1.sol:37` · 绑定Factory输出到有代码的implementation和非空初始化（拒绝时InvalidImplementation）。

#### G-100
`(uint160(predict(implementation, initData, salt)) & FLAG_MASK) != REQUIRED_HOOK_FLAGS` · `src/v1/deployment/TSVHookProxyFactoryV1.sol:38` · 使CREATE2新Hook地址具备V4所需权限位（拒绝时InvalidHookAddress）。

#### G-101
`msg.sender != guardian` · `src/v1/governance/TSVGovernanceAnchor.sol:130` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-102
`upgradesFrozen || reasonHash == 0` · `src/v1/governance/TSVGovernanceAnchor.sol:131` · 保持事故冻结、解冻证据与当前incident的一致对应（拒绝时InvalidFreeze）。

#### G-103
`msg.sender != guardian` · `src/v1/governance/TSVGovernanceAnchor.sol:141` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-104
`!upgradesFrozen || expectedFreezeId != freezeId || evidenceHash == 0` · `src/v1/governance/TSVGovernanceAnchor.sol:142` · 保持事故冻结、解冻证据与当前incident的一致对应（拒绝时InvalidFreeze）。

#### G-105
`msg.sender != governor` · `src/v1/governance/TSVGovernanceAnchor.sol:154` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-106
`upgradesFrozen` · `src/v1/governance/TSVGovernanceAnchor.sol:155` · 落实Guardian对当前所有升级入口的冻结开关（拒绝时UpgradeFrozen）。

#### G-107
`!proxiesBound || upgradeContextActive || targets.length == 0 || targets.length > 6 || targets.length != implementations.length || targets.length != initData.length` · `src/v1/governance/TSVGovernanceAnchor.sol:156` · 维护即时升级、独立冻结和多方身份恢复的权限范围（拒绝时InvalidBundle）。

#### G-108
`!bound || implementations[i].code.length == 0` · `src/v1/governance/TSVGovernanceAnchor.sol:165` · 维护即时升级、独立冻结和多方身份恢复的权限范围（拒绝时InvalidBundle）。

#### G-109
`targets[i] == targets[j]` · `src/v1/governance/TSVGovernanceAnchor.sol:167` · 维护即时升级、独立冻结和多方身份恢复的权限范围（拒绝时InvalidBundle）。

#### G-110
`governor_ == address(0) || guardian_ == address(0) || recoveryCouncil_ == address(0) || governor_ == guardian_ || governor_ == recoveryCouncil_ || guardian_ == recoveryCouncil_` · `src/v1/governance/TSVGovernanceAnchor.sol:185` · 在建立不可升级根时区分Governor、Guardian和Council（拒绝时InvalidBundle）。

#### G-111
`msg.sender != governor || proxiesBound` · `src/v1/governance/TSVGovernanceAnchor.sol:205` · 保留不可变的六业务proxy治理范围（拒绝时Unauthorized）。

#### G-112
`addresses[i].code.length == 0 || IAnchoredProxyV1(addresses[i]).governanceAnchor() != address(this)` · `src/v1/governance/TSVGovernanceAnchor.sol:207` · 把待绑定proxy对应到本治理Anchor及可调用代码（拒绝时InvalidBundle）。

#### G-113
`addresses[i] == addresses[j]` · `src/v1/governance/TSVGovernanceAnchor.sol:211` · 防止一个proxy占据多个组件绑定位置（拒绝时InvalidBundle）。

#### G-114
`IRegistryLinksV1(addresses[0]).hook() != addresses[3] || IRegistryLinksV1(addresses[0]).lpManager() != addresses[5] || IRegistryLinksV1(addresses[0]).dataInbox() != addresses[2] || ILedgerLinksV1(addresses[1]).registry() != addresses[0] || ILedgerLinksV1(addresses[1]).hook() != addresses[3] || ILedgerLinksV1(addresses[1]).dataInbox() != addresses[2] || IInboxLinksV1(addresses[2]).registry() != addresses[0] || IInboxLinksV1(addresses[2]).ledger() != addresses[1] || IHookLinksV1(addresses[3]).registry() != addresses[0] || IHookLinksV1(addresses[3]).ledger() != addresses[1] || IHookLinksV1(addresses[3]).router() != addresses[4] || IHookLinksV1(addresses[3]).lpManager() != addresses[5] || IRouterLinksV1(addresses[4]).registry() != addresses[0] || IRouterLinksV1(addresses[4]).ledger() != addresses[1] || ILpLinksV1(addresses[5]).registry() != addresses[0] || IHookLinksV1(addresses[3]).poolManager() != IRouterLinksV1(addresses[4]).poolManager() || IHookLinksV1(addresses[3]).poolManager() != ILpLinksV1(addresses[5]).poolManager()` · `src/v1/governance/TSVGovernanceAnchor.sol:215` · 将六组件的writer、callback及同一PM引用互相核对（拒绝时InvalidBundle）。

#### G-115
`msg.sender != recoveryCouncil || salt == 0 || evidenceHash == 0` · `src/v1/governance/TSVGovernanceAnchor.sol:243` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-116
`recoveries[id].active` · `src/v1/governance/TSVGovernanceAnchor.sol:248` · 绑定恢复授权到当前提案和根身份epochs（拒绝时InvalidProposal）。

#### G-117
`msg.sender != guardian` · `src/v1/governance/TSVGovernanceAnchor.sol:255` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-118
`!p.active || p.epoch != epoch || p.guardianEpoch != guardianEpoch` · `src/v1/governance/TSVGovernanceAnchor.sol:257` · 绑定恢复授权到当前提案和根身份epochs（拒绝时InvalidProposal）。

#### G-119
`msg.sender != guardian || !recoveries[id].approved` · `src/v1/governance/TSVGovernanceAnchor.sol:264` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-120
`msg.sender != recoveryCouncil || !recoveries[id].active` · `src/v1/governance/TSVGovernanceAnchor.sol:271` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-121
`upgradeContextActive || !p.active || !p.approved || p.epoch != epoch || p.guardianEpoch != guardianEpoch` · `src/v1/governance/TSVGovernanceAnchor.sol:279` · 绑定恢复授权到当前提案和根身份epochs（拒绝时InvalidProposal）。

#### G-122
`newGovernor == address(0) || newGuardian == address(0) || newGovernor == newGuardian || newGovernor == recoveryCouncil || newGuardian == recoveryCouncil || newGovernor == guardian || newGuardian == currentGovernor || (newGovernor == currentGovernor && newGuardian == guardian)` · `src/v1/governance/TSVGovernanceAnchor.sol:299` · 维护即时升级、独立冻结和多方身份恢复的权限范围（拒绝时InvalidBundle）。

#### G-123
`anchor_.code.length == 0` · `src/v1/governance/TSVGoverned.sol:39` · 建立业务实现到可调用治理Anchor的链接（拒绝时InvalidGovernance）。

#### G-124
`governor == address(0) || guardian == address(0) || council == address(0) || governor == guardian || governor == council || guardian == council` · `src/v1/governance/TSVGoverned.sol:44` · 业务初始化时确认根身份非零且彼此独立（拒绝时InvalidGovernance）。

#### G-125
`msg.sender != governanceAnchor.governor()` · `src/v1/governance/TSVGoverned.sol:56` · 使共享角色和升级授权持续依赖当前Anchor根身份（拒绝时AccessControlUnauthorizedAccount）。

#### G-126
`role == DEFAULT_ADMIN_ROLE` · `src/v1/governance/TSVGoverned.sol:77` · 防止业务AccessControl改写动态解析的Governor管理身份（拒绝时ProtectedRole）。

#### G-127
`role == DEFAULT_ADMIN_ROLE` · `src/v1/governance/TSVGoverned.sol:85` · 防止业务AccessControl改写动态解析的Governor管理身份（拒绝时ProtectedRole）。

#### G-128
`role == DEFAULT_ADMIN_ROLE` · `src/v1/governance/TSVGoverned.sol:93` · 防止业务AccessControl改写动态解析的Governor管理身份（拒绝时ProtectedRole）。

#### G-129
`role == DEFAULT_ADMIN_ROLE` · `src/v1/governance/TSVGoverned.sol:102` · 防止业务AccessControl改写动态解析的Governor管理身份（拒绝时ProtectedRole）。

#### G-130
`role == DEFAULT_ADMIN_ROLE` · `src/v1/governance/TSVGoverned.sol:111` · 防止业务AccessControl改写动态解析的Governor管理身份（拒绝时ProtectedRole）。

#### G-131
`msg.sender != governanceAnchor.governor() && !(msg.sender == address(governanceAnchor) && governanceAnchor.upgradeContextActive())` · `src/v1/governance/TSVGoverned.sol:117` · 使implementation变更仅来自当前Governor或有效Anchor batch（拒绝时UnauthorizedUpgrade）。

#### G-132
`governanceAnchor.upgradesFrozen()` · `src/v1/governance/TSVGoverned.sol:123` · 落实Guardian对当前所有升级入口的冻结开关（拒绝时UpgradeFrozen）。

#### G-133
`underlying_.code.length == 0 || wrapped_.code.length == 0 || router_ == address(0) || lpManager_ == address(0) || underlying_ == wrapped_ || IIssuerWrapped(wrapped_).asset() != underlying_` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:120` · 让legacy wrapper、issuer和授权manager配置具备正确资产关系（拒绝时InvalidOperation）。

#### G-134
`prepared.operationId != 0 || shares == 0 || owner == address(0) || owner == address(this) || owner != contextOwner || receiver != msg.sender || maxDisplayedDebit == 0` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:157` · 把legacy拉取/包装限定到当前owner及调用manager（拒绝时InvalidOperation）。

#### G-135
`!underlying.transferSharesFrom(owner, address(this), shares)` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:172` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-136
`p.ownerShares < shares || underlying.sharesOf(owner) != p.ownerShares - shares || underlying.sharesOf(address(this)) != p.adapterShares + shares` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:173` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-137
`displayedAllowance == 0` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:178` · 使legacy包装批准足够覆盖本次实际issuer份额（拒绝时SettlementMismatch）。

#### G-138
`underlying.sharesOf(address(this)) != p.adapterShares || underlying.sharesOf(address(wrapped)) != p.vaultShares + shares || wrapped.totalSupply() != p.wrapperSupply + shares || wrapped.balanceOf(address(this)) != p.adapterWrapped + shares` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:183` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-139
`wrapped.balanceOf(address(this)) != p.adapterWrapped || wrapped.balanceOf(receiver) != p.receiverWrapped + shares` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:191` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-140
`p.ownerDisplayed < ownerDisplayedAfter || p.ownerDisplayed - ownerDisplayedAfter > maxDisplayedDebit` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:196` · 把issuer显示单位的实际debit限定在owner同意范围（拒绝时SlippageExceeded）。

#### G-141
`prepared.operationId != 0 || operationId == 0 || shares == 0 || recipient == address(0)` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:207` · 只创建唯一、非零且有有效recipient的legacy接收snapshot（拒绝时InvalidOperation）。

#### G-142
`p.operationId != operationId || p.caller != msg.sender || p.shares != shares || shares == 0 || contextRecipient != recipient || recipient == address(0) || (forceExit && minDisplayedCredit != 0) || wrapped.balanceOf(address(this)) != p.wrappedBefore + shares` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:228` · 让legacy赎回匹配原snapshot与当前operation收款对象（拒绝时InvalidOperation）。

#### G-143
`underlying.sharesOf(recipient) != s.recipientShares + shares || s.vaultShares < shares || underlying.sharesOf(address(wrapped)) != s.vaultShares - shares || s.wrapperSupply < shares || wrapped.totalSupply() != s.wrapperSupply - shares || wrapped.balanceOf(address(this)) != p.wrappedBefore || underlying.sharesOf(address(this)) != p.underlyingSharesBefore` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:242` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-144
`displayedAfter < s.recipientDisplayed || displayedAfter - s.recipientDisplayed < minDisplayedCredit` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:250` · 保证legacy赎回的recipient实际显示credit满足界限（拒绝时SlippageExceeded）。

#### G-145
`msg.sender != router && msg.sender != lpManager` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:267` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-146
`poolId == 0 || o == address(0) || r == address(0)` · `src/v1/legacy/IssuerShareSettlementAdapter.sol:270` · 拒绝空的legacy operation context（拒绝时InvalidOperation）。

#### G-147
`reportId == 0 || sourceHash == 0 || reportIdUsed || sequence <= previousSequence || sourceTimestamp < previousSourceTimestamp` · `src/v1/libraries/ReportValidationLib.sol:32` · 维持各报告流的顺序、新鲜度和全局唯一ID（拒绝时InvalidReport）。

#### G-148
`sourceTimestamp > currentTimestamp || currentTimestamp > submitDeadline` · `src/v1/libraries/ReportValidationLib.sol:36` · 限制请求或报告可被执行的时间窗口（拒绝时Expired）。

#### G-149
`payerAfter > payerBefore || payerBefore - payerAfter != amount || poolAfter < poolBefore || poolAfter - poolBefore != amount || poolManager.settle() != amount` · `src/v1/libraries/TSVDirectSettlementLib.sol:32` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-150
`poolAfter > poolBefore || poolBefore - poolAfter != amount || recipientAfter < recipientBefore || recipientAfter - recipientBefore != amount` · `src/v1/libraries/TSVDirectSettlementLib.sol:52` · 保证本笔交易观察到的双方余额、share或supply变化符合预期（拒绝时SettlementMismatch）。

#### G-151
`poolManager_.code.length == 0 || registry_.code.length == 0` · `src/v1/periphery/TSVLPManagerV1.sol:97` · 让LP操作绑定有代码的PoolManager和Registry（拒绝时InvalidPool）。

#### G-152
`entered` · `src/v1/periphery/TSVLPManagerV1.sol:105` · 排除普通操作嵌套，保留受控PM callback运行窗口（拒绝时Reentrancy）。

#### G-153
`priceBasisHash == 0` · `src/v1/periphery/TSVLPManagerV1.sol:120` · 让初始价格提交带有可追溯依据hash（拒绝时InvalidPool）。

#### G-154
`liquidity == 0 || liquidity > uint128(type(int128).max)` · `src/v1/periphery/TSVLPManagerV1.sol:142` · 为新仓位建立正且可用int128表示的liquidity（拒绝时InvalidPosition）。

#### G-155
`liquidity == 0 || liquidity > uint128(type(int128).max) || uint256(p.liquidity) + liquidity > uint256(uint128(type(int128).max))` · `src/v1/periphery/TSVLPManagerV1.sol:158` · 避免增加仓位后超出V4 signed-liquidity范围（拒绝时InvalidPosition）。

#### G-156
`liquidity == 0 || liquidity >= p.liquidity` · `src/v1/periphery/TSVLPManagerV1.sol:176` · 普通部分减少后仍保持仓位liquidity为正（拒绝时InvalidPosition）。

#### G-157
`p.liquidity == 0` · `src/v1/periphery/TSVLPManagerV1.sol:188` · 只从有流动性的活跃权利记录收集费用（拒绝时InvalidPosition）。

#### G-158
`delta.amount0() <= 0 && delta.amount1() <= 0` · `src/v1/periphery/TSVLPManagerV1.sol:190` · 只完成实际存在正数费用交付的collect操作（拒绝时NoFees）。

#### G-159
`!p.active || p.liquidity == 0 || reasonCode == 0 || evidenceHash == 0` · `src/v1/periphery/TSVLPManagerV1.sol:218` · 只强退仍有资产权利的活跃仓位并保留原因证据（拒绝时InvalidPosition）。

#### G-160
`!hasRole(FORCE_EXIT_ADMIN_ROLE, msg.sender) && (!hasRole(REVOKE_EXIT_EXECUTOR_ROLE, msg.sender) || registry.hasCredential(p.owner))` · `src/v1/periphery/TSVLPManagerV1.sol:219` · 把撤证执行者强退限制于owner已无credential，admin分支独立（拒绝时Unauthorized）。

#### G-161
`!registry.isKnownPool(poolId)` · `src/v1/periphery/TSVLPManagerV1.sol:226` · 强退仍须使用Registry登记的既有池身份（拒绝时InvalidPool）。

#### G-162
`!entered || activeContext.positionId == 0` · `src/v1/periphery/TSVLPManagerV1.sol:245` · 只在实际LP操作期间向Hook暴露有效context（拒绝时InvalidPosition）。

#### G-163
`from != address(0) && to != address(0)` · `src/v1/periphery/TSVLPManagerV1.sol:283` · 使Receipt权利保持原仓位owner，限生命周期mint/burn（拒绝时NonTransferable）。

#### G-164
`msg.sender != address(poolManager) || !entered || activeContext.positionId == 0 || keccak256(data) != activeRequestHash` · `src/v1/periphery/TSVLPManagerV1.sol:304` · 将LP callback绑定到PM、操作锁、活跃position及原请求hash（拒绝时Unauthorized）。

#### G-165
`block.timestamp > request.bounds.deadline` · `src/v1/periphery/TSVLPManagerV1.sol:311` · 限制请求或报告可被执行的时间窗口（拒绝时Expired）。

#### G-166
`delta < 0 && (mode == LPOperationMode.FORCE_EXIT || mode == LPOperationMode.COLLECT)` · `src/v1/periphery/TSVLPManagerV1.sol:375` · collect/forceExit不向owner追加本次净付款义务（拒绝时SlippageExceeded）。

#### G-167
`delta == type(int128).min` · `src/v1/periphery/TSVLPManagerV1.sol:378` · 排除不可安全取绝对值或表示为V4 delta的数量（拒绝时InputAmountTooLarge）。

#### G-168
`delta < 0 && amount > maxIn` · `src/v1/periphery/TSVLPManagerV1.sol:380` · 在本币实际负delta上执行LP最大付款界限（拒绝时SlippageExceeded）。

#### G-169
`(delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut` · `src/v1/periphery/TSVLPManagerV1.sol:381` · 在本币实际非负delta（包括零）上执行LP最小交付界限（拒绝时SlippageExceeded）。

#### G-170
`block.timestamp > deadline` · `src/v1/periphery/TSVLPManagerV1.sol:393` · 限制请求或报告可被执行的时间窗口（拒绝时Expired）。

#### G-171
`!registry.isEligible(msg.sender)` · `src/v1/periphery/TSVLPManagerV1.sol:394` · 把普通LP入场与修改限制于当前有效且未暂停SBT的caller（拒绝时Unauthorized）。

#### G-172
`!registry.isLPAllowed(poolId)` · `src/v1/periphery/TSVLPManagerV1.sol:395` · 普通LP遵循LP模式准入和暂停组合（拒绝时InvalidPool）。

#### G-173
`!p.active || p.liquidity == 0 || p.owner != msg.sender || ownerOf(positionId) != p.owner` · `src/v1/periphery/TSVLPManagerV1.sol:409` · 使普通仓位修改caller、position owner和Receipt owner一致（拒绝时InvalidPosition）。

#### G-174
`lower >= upper || lower < TickMath.MIN_TICK || upper > TickMath.MAX_TICK || lower % key.tickSpacing != 0 || upper % key.tickSpacing != 0` · `src/v1/periphery/TSVLPManagerV1.sol:421` · 保持仓位tick范围和已准入key的spacing相容（拒绝时InvalidPosition）。

#### G-175
`poolManager_.code.length == 0 || registry_.code.length == 0 || ledger_.code.length == 0` · `src/v1/periphery/TSVSwapRouterV1.sol:83` · 使Router绑定可调用PM、Registry和Ledger（拒绝时InvalidRequest）。

#### G-176
`entered` · `src/v1/periphery/TSVSwapRouterV1.sol:93` · 排除普通操作嵌套，保留受控PM callback运行窗口（拒绝时Reentrancy）。

#### G-177
`!isAdapterAllowed[msg.sender]` · `src/v1/periphery/TSVSwapRouterV1.sol:135` · 只接受Governor启用的外部DEX Adapter交易入口（拒绝时AdapterNotAllowed）。

#### G-178
`adapter == address(0) || (allowed && adapter.code.length == 0)` · `src/v1/periphery/TSVSwapRouterV1.sol:145` · 启用时目标须有代码，撤销无需目标仍有代码（拒绝时InvalidAdapter）。

#### G-179
`msg.sender != address(poolManager) || !entered` · `src/v1/periphery/TSVSwapRouterV1.sol:155` · 限制caller到该组件授权的当前身份或绑定执行者（拒绝时Unauthorized）。

#### G-180
`inDelta >= 0 || outDelta <= 0` · `src/v1/periphery/TSVSwapRouterV1.sol:167` · 确保actualIn/actualOut按预期负付款/正收款方向解释（拒绝时SlippageExceeded）。

#### G-181
`inDelta == type(int128).min` · `src/v1/periphery/TSVSwapRouterV1.sol:168` · 排除不可安全取绝对值或表示为V4 delta的数量（拒绝时InputAmountTooLarge）。

#### G-182
`actualIn > request.amountSpecified || actualOut < request.limitAmount` · `src/v1/periphery/TSVSwapRouterV1.sol:172` · 把exact-input实际支出与最低产出约束到caller界限（拒绝时SlippageExceeded）。

#### G-183
`actualOut != request.amountSpecified || actualIn > request.limitAmount` · `src/v1/periphery/TSVSwapRouterV1.sol:173` · 把exact-output实际产出固定为目标值并限制最大付款（拒绝时SlippageExceeded）。

#### G-184
`block.timestamp > request.deadline` · `src/v1/periphery/TSVSwapRouterV1.sol:225` · 限制请求或报告可被执行的时间窗口（拒绝时Expired）。

#### G-185
`request.amountSpecified == 0 || request.amountSpecified > uint128(type(int128).max) || request.limitAmount == 0` · `src/v1/periphery/TSVSwapRouterV1.sol:226` · 使交易请求为正且可用V4 signed amount表示（拒绝时InvalidRequest）。

#### G-186
`participant == address(0) || !registry.isEligible(participant)` · `src/v1/periphery/TSVSwapRouterV1.sol:230` · 让直接/Adapter路径的指定participant通过当前SBT资格（拒绝时Unauthorized）。

#### G-187
`!registry.isTradable(poolId)` · `src/v1/periphery/TSVSwapRouterV1.sol:232` · 只有当前获TRADE许可的池进入swap（拒绝时InvalidPool）。

## 2. Inferred Invariants (Single-Contract)

提取方法为Δ-pair、核对全部写点后的guard-lift、不可逆生命周期edge、stored temporal predicate，或明确NatSpec/spec全局主张。Bound、Ratio、Conservation、StateMachine、Temporal按性质内容分类；单次deadline/输入上限保留在G段。

#### I-1

`Temporal` · On-chain: **Yes**

> 每个 (kind, securityId) 报告流的成功提交 sequence 严格递增、sourceTimestamp 非递减，换月不重置。

**Derivation** — guard-lift: `sequence <= previousSequence || sourceTimestamp < previousSourceTimestamp`（ReportValidationLib.sol:33–34）拒绝；全部写点 TSVDataInboxV1.sol:168、169 只在 _accept 校验后执行；没有重置写点。

**If violated** — 报告顺序和数据时效不再能由链上流元数据判定。

---

#### I-2

`StateMachine` · On-chain: **Yes**

> reportIdUsed[id] 只从 false 变为 true，跨类别与证券全局去重。

**Derivation** — edge: false → true@TSVDataInboxV1.sol:170；ReportValidationLib.sol:33 拒绝 `reportIdUsed`；170 是唯一写点。

**If violated** — 同一报告 ID 可被多次消费。

---

#### I-3

`Conservation` · On-chain: **Yes**

> 同月、按 securityId 严格排序的 ADTV batch 全部成功或全部回滚；失败 batch 不消费 ID、sequence 或 Ledger version。

**Derivation** — NatSpec: TSVDataInboxV1.sol:68 — "Reports to accept; the whole batch reverts if any entry is invalid."；69–85 顺序执行 _submitAdtv，102 调用 Ledger；无异常捕获，所有写入服从同一交易回滚。

**If violated** — 批次状态与提交方预期的原子结果不一致。

---

#### I-4

`StateMachine` · On-chain: **Yes**

> 已注册 Currency 的 poolCurrency、securityId、poolDecimals、初始 runtime code hash 不再由当前实现改写；一个 Currency 不可重新绑定另一证券。

**Derivation** — edge: absent → TokenConfig@TSVRegistryV1.sol:339，315 拒绝已存在记录；所有其他 TokenConfig 写点为 status@365 及 adapter/review/version@385–388，没有整记录删除或身份重写。

**If violated** — 跨池归集的证券身份或 raw-unit 基础改变。

---

#### I-5

`StateMachine` · On-chain: **Yes**

> Token 从 ABSENT 注册为 APPROVED 后，仅可在 APPROVED 与 DISABLED 间切换，不能回到 ABSENT。

**Derivation** — edge: ABSENT → APPROVED@TSVRegistryV1.sol:339；全部 status 写点 339、365，后者由 `status == TokenStatus.ABSENT`@356 拒绝逆向；不存在删除写点。

**If violated** — 已准入地址可重走初始注册与绑定流程。

---

#### I-6

`Bound` · On-chain: **Yes**

> 已配置 Tier 满足 0 < tierBps ≤ 10000 且 listedCount ≤ maxListed；未配置 Tier 保持零值。

**Derivation** — guard-lift: TSVRegistryV1.sol:179 的 `tierId == 0 || tierBps == 0 || tierBps > 10_000 || maxListed < tier.listedCount || evidenceHash == 0` 拒绝；全部 Tier 写点 tierBps@182、maxListed@183、listedCount 增量@608（607 拒绝容量已满）及减少@280/295。

**If violated** — Tier 比例或准入容量脱离配置范围。

---

#### I-7

`Conservation` · On-chain: **Yes**

> 每个 Tier 的 listedCount 等于其当前 listed 的 securityId 数量，按证券去重。（per spec）

**Derivation** — NatSpec/spec: docs/TEST_SPEC_V1.md:55 — "`listedCount` 按 securityId 去重"；全部关联写点：准入 _takeTierSlot@250 + listed@251，重新上市 slot@263 + listed@264，换 Tier slot@279/旧计数@280/tier@282，退市 listed@293/计数@295；setTierPolicy@182–183仅改比例/上限，保留旧 listedCount。

**If violated** — 上市容量与实际证券数不一致。

---

#### I-8

`Conservation` · On-chain: **Yes**

> stock 证券的 activePoolCount 等于所有绑定该 securityId 的 Currency 的 activePoolCountByCurrency 之和。

**Derivation** — Δ-pair: TSVRegistryV1.sol:430 ↔ 432、431 ↔ 433（激活 +1），446 ↔ 448、447 ↔ 449（停用 −1），471 ↔ 473、472 ↔ 474（启用 +1）；这些是两个计数的全部增减点，证券初值 251 为 0，Currency→securityId 由 I-4 固定，413 排除双 stock 池。

**If violated** — 证券退市与 Adapter 更换所依赖的活跃池计数失真。

---

#### I-9

`StateMachine` · On-chain: **Yes**

> PoolId 首次从 ABSENT 注册为 PENDING 后，其完整 PoolKey 和 securityId0/1 固定；后续状态可 ACTIVE↔DISABLED，不能回到 ABSENT。

**Derivation** — edge: ABSENT@TSVRegistryV1.sol:415 → PENDING@416；全部 pool 写点为整记录@416、status@428/444/466、version@429/445/467，未改写 key 或证券归属，未删除记录。

**If violated** — 同一 PoolId 的身份或准入生命周期不再稳定。

---

#### I-10

`Temporal` · On-chain: **Yes**

> 已接受市场暂停不随时间自动失效；退市/重新上市保留 marketPauseMode 与 marketSequence。（per spec）

**Derivation** — NatSpec/spec: docs/SYSTEMS_OVERVIEW.md:329 — "不会按报告年龄自动恢复"；全部市场状态写点 TSVRegistryV1.sol:525–526，仅 applyMarketStatus 写入并在513检查递增序号；上市/退市写点251/264/293不删除对应 mappings。

**If violated** — 市场状态的持续性与下一次报告的序号基线改变。

---

#### I-11

`Conservation` · On-chain: **Yes**

> activePauseCount[scope][target][mode] 等于该三元组仍 active 的 emergencyPauses 数量。

**Derivation** — Δ-pair: TSVRegistryV1.sol:550(active=true) ↔ 551(count++)；561(active=false) ↔ 562(count--)；549 为唯一记录创建点，560 拒绝重复清除，548 为单调唯一 ID 分配；无其他 count 或 active 写点。

**If violated** — 暂停叠加和逐条恢复的结果不再匹配有效记录集合。

---

#### I-12

`Conservation` · On-chain: **Yes**

> usedWad[securityId][day] 等于所有成功 stock leg 的正数转换返回值之和；每次成功写入满足当时 effectiveCap，报告更正、Tier/Adapter/日切变化均不重置历史 usage。（per spec）

**Derivation** — NatSpec/spec: docs/TEST_SPEC_V1.md:176 — "usedWad[securityId][day] 等于所有成功 Swap…返回值之和"；唯一写点 TSVVolumeLedgerV1.sol:514 来自 next=old+charge@512，stock charge>0@491，hardCap>0@511、next≤effectiveCap@513；已检索 ADTV@198、quota@214/218、factor@255/257/275、day-start@364/380 及 Registry 配置写点，均不写 usedWad。此处是成交时约束，授权下调 cap 后不声称 used 始终≤当前 cap。

**If violated** — 已成交使用量不能作为持续、可追溯的共同预算计数。

---

#### I-13

`Bound` · On-chain: **Yes**

> active quota 的 quotaWad 严格为正；inactive quota 的 quotaWad 为零。存储 quota 不保证始终≤后来更正的 hardCap。

**Derivation** — guard-lift: TSVVolumeLedgerV1.sol:213 拒绝 `hardCap == 0 || report.quotaWad == 0 || report.quotaWad > hardCap`；全部 quota 数值/active 写点 SET@214–215、CLEAR@218–219，CLEAR@217 检查原 active 且输入0；其他写点224–225仅元数据。

**If violated** — 配额激活状态与数值含义不一致。

---

#### I-14

`Bound` · On-chain: **Yes**

> 已有 ADTV 记录的 value>0，版本每次恰好加1；更正数值必须使所有已存 split factors 的 ADTV 换算可表示。

**Derivation** — guard-lift: TSVVolumeLedgerV1.sol:187 的 `report.adtvWad == 0` 与192的 `report.version != current.version + 1` 拒绝；唯一数值/版本写点198–199，写前196遍历全部既有 factor 执行 Math.mulDiv；200只写ID。

**If violated** — 月度基数或后续 factor 运算的版本、可表示性失去保障。

---

#### I-15

`Ratio` · On-chain: **Yes**

> 每个保存的 split factor 为正 numerator/denominator，并约为互质整数比。

**Derivation** — guard-lift: TSVVolumeLedgerV1.sol:543 的 `numerator == 0 || denominator == 0` 拒绝；247 调用 _reducedFactor，545–551执行Euclid并返回约分结果；全部 factor 写点255替换、257push 均使用该结果，275仅pop。

**If violated** — 绝对比例的标准表示和非零分母条件被破坏。

---

#### I-16

`Temporal` · On-chain: **Yes**

> factor 更新或取消只作用于未来 trade day 的最后一个 checkpoint，已开始或中间 checkpoint 不再改变。

**Derivation** — temporal: TSVVolumeLedgerV1.sol:242 的 `report.effectiveTradeDayId <= currentDay` 拒绝；全部 factor 写点255/257/275还分别由254同末尾日期、253有序追加分支、270–273同末尾日期约束；currentTradeDay@408–413依当前日程求值。

**If violated** — 历史或中间因子可被追溯改写。

---

#### I-17

`Ratio` · On-chain: **Yes**

> split factor 是相对对应 sourceMonth ADTV 的绝对比例，选择适用于目标日的最后一个 checkpoint，缺省为1/1，无需激活交易。

**Derivation** — NatSpec: TSVVolumeLedgerV1.sol:232 — "Factors are absolute, not multiplied by the previous checkpoint. No activation transaction is needed."；235–240强制目标日的 previousMonth==sourceMonth，全部写点255/257/275按该key；293–307查找并返回最后适用值或1/1，538仅乘所选factor一次。

**If violated** — 拆并股处理的月度基准或累计语义改变。

---

#### I-18

`Bound` · On-chain: **Yes**

> 初始和 checkpoint 的 day-start offset 均落在 [0,86400)，每次新增相邻排期的偏移改变量≤14400秒。

**Derivation** — guard-lift: TSVVolumeLedgerV1.sol:161、339拒绝 offset≥SECONDS_PER_DAY，352拒绝 `shift > MAX_DAY_START_SHIFT`；全部 offset/schedule 写点163初值、364push、380pop；没有原地修改 checkpoint 的写点。

**If violated** — 计量日边界范围和过渡日长度的约束改变。

---

#### I-19

`Temporal` · On-chain: **Yes**

> day-start 排期或取消必须早于前一过渡日开始；checkpoint effectiveDayId 严格递增，已开始的计量日边界固定。

**Derivation** — temporal: TSVVolumeLedgerV1.sol:361 与378的 `block.timestamp >= _dayStartUTC(transitionDayId)` 拒绝；全部 checkpoint 写点364push、380pop；353–357限定新日期大于最后日期，342阻止覆盖未生效的旧排期。

**If violated** — 历史计量日重新归属或日预算边界不稳定。

---

#### I-20

`Bound` · On-chain: **Yes**

> Governor、Guardian、immutable Recovery Council 非零、两两不同；恢复亦不得把新 Governor 指向当前 Guardian 或把新 Guardian 指向当前 Governor。

**Derivation** — guard-lift: `governor_ == address(0) || guardian_ == address(0) || recoveryCouncil_ == address(0) || governor_ == guardian_ || governor_ == recoveryCouncil_ || guardian_ == recoveryCouncil_`@TSVGovernanceAnchor.sol:185–188 与 `newGovernor == address(0) || newGuardian == address(0) || newGovernor == newGuardian || newGovernor == recoveryCouncil || newGuardian == recoveryCouncil || newGovernor == guardian || newGuardian == currentGovernor || (newGovernor == currentGovernor && newGuardian == guardian)`@299–303 _validateRecovery；全部身份写点189–191（constructor）、287与289（executeRecovery先282校验）；Council只有constructor写入191。

**If violated** — 治理、冻结和恢复的身份分离失效。

---

#### I-21

`StateMachine` · On-chain: **Yes**

> 成功 executeRecovery 消耗本次 active/approved 提案并使 epoch 加1；更换 Guardian 时 guardianEpoch 加1，使旧 epoch 批准不可执行。

**Derivation** — edge: approved/active@TSVGovernanceAnchor.sol:279 → false@283–284 → epoch+1@293；全部 epoch写点293及guardianEpoch@290；审批258只接受当前epoch@257，执行279重复核对。cancel后同epoch可重新提案249，因而不声称ID永不复用。

**If violated** — 旧根身份批准可被用于后续身份恢复。

---

#### I-22

`Bound` · On-chain: **Yes**

> freezeEpoch 随每次有效冻结严格加1，freezeId 绑定该次 incident；解冻必须引用当前 freezeId。

**Derivation** — NatSpec: TSVGovernanceAnchor.sol:121 — "Monotonically increasing identifier for freeze incidents."；唯一 freezeEpoch写点132，freezeId写点134；131拒绝重复冻结，142核对expectedFreezeId，身份恢复277–295不写这些字段。

**If violated** — 事故记录与解冻所解决的冻结状态不一致。

---

#### I-23

`StateMachine` · On-chain: **Yes**

> Anchor 的六代理列表仅能绑定一次，并按 Registry/Ledger/Inbox/Hook/Router/LP 顺序保存。

**Derivation** — edge: proxiesBound=false@TSVGovernanceAnchor.sol:205 → true@234；唯一 proxies[i]写点213，先验证code、固定Anchor、唯一性207/211及全部互链215–233；没有解绑、重排或迁移写点。

**If violated** — 既定治理范围与组件互链不再固定。

---

#### I-24

`StateMachine` · On-chain: **Yes**

> 当前实现的 business governanceAnchor、初始化组件链接，以及 Registry/ Ledger 后绑定链接只建立一次。

**Derivation** — edge: governanceAnchor零值 → root@TSVGoverned.sol:51（onlyInitializing@38、implementation锁33、各initialize一次）；Registry links零值@162 → 166–168，Ledger writers零值@170 →173–174；其余初始链接写点Inbox36–37、Hook71–75、Router86–88、LP98–99，未发现重绑定写点。范围限当前实现，任意未来升级逻辑不在此性质内。

**If violated** — 业务权限根或 callback/writer 目标在普通配置中被替换。

---

#### I-25

`Bound` · On-chain: **Yes**

> DEFAULT_ADMIN_ROLE 成员由 Anchor 当前 Governor 动态解析，不能用 grant/revoke/renounce 或内部角色写入改变。

**Derivation** — NatSpec: TSVGoverned.sol:73 — "Grants a business role; the default-admin role remains anchored to the Governor."；66–70动态查询；全部角色写入口76/84/92及内部102/111都拒绝role==DEFAULT_ADMIN_ROLE；其余角色由父类管理。

**If violated** — Governor 根身份与 AccessControl 管理身份脱节。

---

#### I-26

`Bound` · On-chain: **Yes**

> 每次 LP 入口成功完成时，active 仓位的 liquidity 位于 [1,int128.max]；关闭仓位的 liquidity=0。（不要求外部调用中的开仓暂态为正）

**Derivation** — NatSpec: TSVLPManagerV1.sol:126 — "Opens a positive-liquidity position and mints its nontransferable Receipt to the caller."；全部 liquidity写点145暂态0、147正数（142）、166增加（158–162）、179减少（176严格小于原值）、434关闭为0；active写点145/435。开仓在PM unlock与mint之前存在active且liquidity=0的暂态。

**If violated** — 成功后的活跃记录失去有效可结算流动性范围。

---

#### I-27

`StateMachine` · On-chain: **Yes**

> 在单个 LP Manager 中成功关闭的 positionId 永不重用；关闭后该记录不会再次 active。

**Derivation** — edge: active=true@TSVLPManagerV1.sol:145 → false/liquidity=0@434–435；nextPositionId全部写点100初始化1、144++，新position仅写新ID@145；普通/强退入口均检查active，未见重开或删除再注册写点。

**If violated** — 旧 Receipt/仓位标识可指向新的资产权利。

---

#### I-28

`Conservation` · On-chain: **Yes**

> 成功入口结束时，每个活跃 position 恰有一个同ID Receipt，Receipt owner==position.owner 且不可转移；关闭时burn，强退交付保持原owner。（per spec；V4实际liquidity由外部PM提供）

**Derivation** — NatSpec/spec: docs/TEST_SPEC_V1.md:175 — "Receipt 恰好一个且 owner 不变；关闭后不可再领取"；全部position owner写点145，Receipt mint@148、burn@436，_update@281–284拒绝非mint/burn转移；257–277授权/转移入口直接拒绝；_requireOwner@409–411核对三方身份，callback@316–331结算至p.owner。

**If violated** — Receipt 的唯一归属与资金交付对象不再一致。

---

#### I-29

`Bound` · On-chain: **Yes**

> 每次 LP 操作成功返回后 activeContext 和 activeRequestHash 清空；活跃 callback 对应该次已保存请求。（per spec）

**Derivation** — NatSpec/spec: docs/CODING_SPEC_V1.md:207 — "操作成功后 Manager 清除活跃上下文与请求哈希"；全部写点TSVLPManagerV1.sol:350/352设置，355/356删除；callback304–309核对caller、entered、positionId、hash；105–108排除嵌套操作，失败外部调用不被捕获。

**If violated** — 回调身份可能引用上一笔或不同请求。

---

#### I-30

`Conservation` · On-chain: **Yes**

> Anchor upgradeBatch 的当前交易中各代理升级全部成功或全部回滚，batch context 在成功返回时关闭。

**Derivation** — NatSpec: TSVGovernanceAnchor.sol:149 — "Upgrades up to six bound business proxies atomically in one Governor transaction."；全部context写点170(true)、174(false)，172的外部upgrade调用无catch；156–159排除嵌套/空/超6/长度不匹配批次，165/167核对bound、code和唯一性。

**If violated** — 一批组件升级停留于部分完成或残留授权上下文。

---

#### I-31

`Bound` · On-chain: **Yes**

> 已注册 stock Currency 的 legalAdapterVersion 初始为1，每次 replacement 恰好加1；与新 Adapter 报告版本一致。

**Derivation** — guard-lift: TSVRegistryV1.sol:330–334 拒绝 `config.legalAdapterVersion != 1`，382计算nextVersion=old+1，383调用_validateLegalShareAdapter，622拒绝返回版本不符；全部版本写点339初始记录、387replacement；非stock初值由325–328限定为0。

**If violated** — Adapter 的历史版本标记不能对应每次配置更换。

---

#### I-32

`Bound` · On-chain: **Yes**

> 所有登记 PoolKey 至多含一个 stock security；quote/quote 池仍允许。

**Derivation** — guard-lift: TSVRegistryV1.sol:413 的 `s0 != 0 && s1 != 0` 拒绝；唯一pool证券字段写点416，s0/s1取自固定token记录410–412；全部后续pool写点428/429/444/445/466/467不修改证券字段。

**If violated** — 池准入与单stock-leg计量前提不一致。

---

#### I-33

`Bound` · On-chain: **Yes**

> legacy Adapter 的 prepared.operationId 非零时，snapshot caller 是配置的 Router/LP Manager，shares>0，且不能被另一次 prepare覆盖；prepare时context recipient非零。

**Derivation** — guard-lift: IssuerShareSettlementAdapter.sol:207拒绝已有prepared/零ID/零shares/零recipient，_requireContext267仅配置caller；全部prepared写点210–212创建、253删除；redeem228–232核对caller、ID、shares及当前recipient。当前V1 Router/LP不实现该legacy context接口。

**If violated** — 旧式两阶段结算的快照与赎回请求脱节。

---

#### I-34

`Conservation` · On-chain: **Yes**

> V1 所有返回 Hook balance/swap delta 的成功回调均返回零，beforeSwap 的fee override亦为0，donate回调拒绝。

**Derivation** — NatSpec: TSVHookV1.sol:29 — "V1 returns zero deltas; nonzero deltas require a separately reviewed accounting upgrade."；所有相关返回点146/185/206/229为0，235/247的donate callback直接revert；当前实现不保存Hook delta余额。

**If violated** — Hook 的额外delta会改变现有Router/LP对PM实际delta的结算与计量约定。

---

#### I-35

`Bound` · On-chain: **Yes**

> 身份恢复保持 upgradesFrozen 原值；冻结/解冻只能由执行时的当前 Guardian 控制。（per spec）

**Derivation** — NatSpec/spec: docs/TEST_SPEC_V1.md:180 — "身份恢复保持冻结"；upgradesFrozen全部写点TSVGovernanceAnchor.sol:135(true)/143(false)，分别由130/141当前Guardian检查；executeRecovery277–295只改身份/epochs，未改冻结字段。

**If violated** — 身份恢复同时改变事故处理中的升级开关。

---

#### I-36

`Temporal` · On-chain: **Yes**

> 已接受的ADTV值不因原submitDeadline经过而失效；后续成交只需有适用的月度非零基数。（per spec）

**Derivation** — NatSpec/spec: docs/SYSTEMS_OVERVIEW.md:294 — "也不会让已接受的 ADTV 自动过期"；全部ADTV数值/版本写点TSVVolumeLedgerV1.sol:198–200仅替换有效报告；531–538的硬上限读取仅按previousMonth与非零value选基数，未存储/检查原submitDeadline。Inbox报告提交时仍经ReportValidationLib.sol:36检查deadline。

**If violated** — 已接受月度预算的持续有效期与报告提交窗口被混淆。

---

## 3. Inferred Invariants (Cross-Contract)

每项caller与callee均在自有src范围；外部issuer、SBT、PM和DEX行为假设列于主报告Dependency Risk Map。

#### X-1

On-chain: **Yes**

> Inbox 发往 Ledger 的 ADTV/quota/factor 经过同一 reporter、去重和顺序校验，Ledger写入口只接受初始化后绑定的Inbox。

**Caller side** — TSVDataInboxV1.sol:91–102、107–134、156–170：role和metadata校验后转发；registry/ledger只写于36–37。

**Callee side** — TSVVolumeLedgerV1.sol:170–174只绑定一次Inbox，180限制caller；全部报告存储写点198–200、214–225、255/257/275/288分别仅由186/206/234入口触达。

**If violated** — 报告写入可绕过统一Ingress状态。

---

#### X-2

On-chain: **Yes**

> stock非零实际delta选择本仓库两类legal-share Adapter时，成功转换接受其绑定Currency并返回正数；原始外部换算语义仍依赖issuer。

**Caller side** — TSVHookV1.sol:302–307取得Registry配置、取abs(delta)并调用Adapter；Ledger491拒绝零stock返回值。

**Callee side** — BackedAutoFeeLegalShareAdapter.sol:53–55唯一immutable绑定写点，75检查currency、78读取来源、79拒绝零；ERC8056DirectLegalShareAdapter.sol:26–27唯一绑定写点，42–44及48–54检查绑定/非零来源并Math.mulDiv；Registry339/385–388是可选择这些Adapter的配置写点。

**If violated** — 成功stock计量缺少正数或绑定Currency的基础条件。

---

#### X-3

On-chain: **Yes**

> 普通用户swap和普通LP操作均使用Registry当前SBT配置和对应TRADE/LP许可；Adapter路由校验participant，普通LP校验msg.sender。

**Caller side** — TSVSwapRouterV1.sol:230/232；TSVLPManagerV1.sol:394/395；强退219–226另有credential/knownPool检查。

**Callee side** — TSVRegistryV1.sol:212–213唯一SBT配置写点；221–230查询SBT；581–600合并pool/token/listing/market及scoped pause；相关状态写点251/264/293、365、428/444/466、525/526、550/561。participant的DEX来源真实性在外部Adapter边界处理。

**If violated** — 入场门禁与执行时的资格/操作类型配置不一致。

---

#### X-4

On-chain: **Yes**

> LP Hook callback校验的pool、ticks、salt、liquidityDelta、mode来自LP Manager保存的同一活跃context；forceExit仅对应全额负liquidityDelta。

**Caller side** — TSVLPManagerV1.sol:350–356写入/清除context和请求hash；303–315校验PM callback后调用modifyLiquidity；position初值145、liquidity写147/166/179/434。

**Callee side** — TSVHookV1.sol:287–294查询activeLPContext并逐项核对；127/128限定增加，162–168区分普通减少与FORCE_EXIT并验证负delta；全额值由LPManager.forceExit@231生成；_requireExactKey@272–274取Registry唯一pool记录416。

**If violated** — LP操作参数与Hook认可的仓位/模式不一致。

---

#### X-5

On-chain: **Yes**

> Ledger唯一stock使用量写入路径接受绑定Hook，Hook的afterSwap接受绑定PM且sender为绑定Router，按PM实际signed delta转换。

**Caller side** — TSVHookV1.sol:222–228检查sender/PM、取得PoolKey及实际delta，调用Ledger；初始化57–75固定引用。

**Callee side** — TSVVolumeLedgerV1.sol:463–469检查绑定Hook、两leg符号、ACTIVE/tradable并求当前日；491–499核对stock配置后消费；唯一usage写点514，writers173–174只绑定一次。

**If violated** — 计量记录不能追溯至授权路径的实际成交delta。

---

#### X-6

On-chain: **Yes**

> 当前Router/LP结算成功时，付款人减少和PM增加、或PM减少和指定收款人增加，均恰好等于实际delta的绝对值。

**Caller side** — TSVSwapRouterV1.sol:167–178按actualIn/actualOut和界限结算，239–245指定payer/recipient；TSVLPManagerV1.sol:316–331、375–385按delta/上下限指定p.owner。

**Callee side** — TSVDirectSettlementLib.sol:26–35执行sync/transferFrom/settle并核对双方balance差及ack；47–55执行take并核对双方balance差；无持久化余额账本或其他自有资金写点；外部balanceOf真实性属依赖假设。

**If violated** — 本笔实际池delta与观察到的Token交付数值不一致。

---

#### X-7

On-chain: **Yes**

> 当前六业务实现的single与batch升级授权均读取同一Anchor当前Governor、batch context及冻结状态。

**Caller side** — TSVGoverned.sol:116–123为共享_authorizeUpgrade，51唯一governanceAnchor写点；当前Governor或Anchor活跃batch才通过，冻结必拒绝。

**Callee side** — TSVGovernanceAnchor.sol:135/143为冻结全部写点，170/174为batchContext全部写点，189/287为Governor全部写点；upgradeBatch154–155检查Gov/冻结，executeRecovery279排除batch中执行。未来任意implementation逻辑不包含在本性质范围。

**If violated** — single和batch升级的权限根或冻结开关分裂。

---

#### X-8

On-chain: **No**

> 同一securityId下各Currency的换算返回值及更换前后Adapter，必须继续表示同一法律股单位，才能与既有ADTV和usedWad直接比较。（per spec）

**Caller side** — TSVRegistryV1.sol:378–388 replacement检查暂停、code、interface、Currency、version并更新Adapter；339初始注册记录securityId，未保存换算单位的可验证语义。

**Callee side** — TSVVolumeLedgerV1.sol:198以报告数值保存ADTV，493–499核对securityId后直接用转换返回值，514累计usage；全部相关写点均未重计历史或验证法律单位连续性。docs/TOKEN_ADMISSION_STANDARD_V1.md:10/46/50将单位核对和日内变化处理交给准入/运营。

**If violated** — 历史usage、当前换算与月度预算不具备相同量纲；这是明确的链外前提，非本报告确认的漏洞。

---

#### X-9

On-chain: **Yes**

> Ledger hardCap 按当前Registry证券Tier和目标日前一月ADTV，乘所选绝对factor并最后floor一次；effectiveCap=min(hardCap,active quota)。

**Caller side** — TSVVolumeLedgerV1.sol:531–538查询Registry tierId/bps与I-17的factor；524应用min，报告数值写198、quota写214/218、factor写255/257/275。

**Callee side** — TSVRegistryV1.sol:251/282是tierId全部写点，182是tierBps唯一配置写点且179限制(0,10000]，608/280/295只改变计数；getSecurity300–304/tierPolicy190–194返回当前存储。

**If violated** — 日预算与指定证券的月度基数/Tier/绝对factor公式不一致。

---

## 4. Economic Invariants

#### E-1

On-chain: **Yes**

> 同一securityId在所有已绑定Currency/Pool中的成功stock成交，共用一个按tradeDay归集的正数计数；按数值返回值记账，而非证明法律股语义。

**Follows from** — [I-4](#i-4) + [I-12](#i-12) + [I-32](#i-32) + [X-5](#x-5)

**If violated** — 多Currency的已用预算不再按共同证券key归集。

---

#### E-2

On-chain: **Yes**

> 每次被接受的stock charge在当时受hardCap及active quota两者约束；20/28小时过渡日仍按一个完整日预算而不按时长比例调整；更正不擦除历史，可能使之后remaining为0。

**Follows from** — [I-12](#i-12) + [I-13](#i-13) + [I-14](#i-14) + [I-17](#i-17) + [I-18](#i-18) + [I-19](#i-19) + [X-9](#x-9)

**If violated** — 新成交预算与当时配置公式不一致。

---

#### E-3

On-chain: **Yes**

> 完成普通或强退LP结算时，Receipt权利和Token交付保持初始owner，关闭后原ID不再领取；成功性依赖外部PM/Token行为。

**Follows from** — [I-26](#i-26) + [I-27](#i-27) + [I-28](#i-28) + [X-4](#x-4) + [X-6](#x-6)

**If violated** — 仓位所有权和完成交付的经济对象不一致。

---

#### E-4

On-chain: **No**

> 计入日预算的数值应始终可与月度ADTV以同一法律股单位比较，包括跨Currency、动态issuer multiplier和Adapter replacement。（per spec）

**Follows from** — [I-4](#i-4) + [I-12](#i-12) + [I-17](#i-17) + [X-8](#x-8)

**If violated** — 共同证券key下的经济量纲不连续；现有代码只能验证数值/接口和caller条件，语义靠链外准入。

---
