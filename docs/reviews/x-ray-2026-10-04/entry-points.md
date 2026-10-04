# Entry Point Map

> TSV V1 | 59 declared operational definitions | 2 permissionless | 46 role/caller-gated | 11 admin-only

统计按自行声明的函数定义去重，共享基类定义不按六个代理重复计数；另列6个initializer与继承UUPS升级selector。role/caller-gated包含SBT资格、仓位所有者、绑定组件、Guardian/Council及角色条件；按skill规则，委托到父类的caller self-confirmation也计入该类。参数没有用户签名输入；user-controlled表示该入口caller自由选择，keeper-provided表示授权reporter提供，protocol-derived表示上游组件生成。

---

## Protocol Flow Paths

### Setup (Governor / deployer)

`new Anchor(Governor, Guardian, Council)` → 六个proxy的`initialize()` → `Registry.bindComponents()` → `Ledger.bindWriters()` → `Anchor.bindProxies()`

`[setup]` → `grantRole()` → `setTierPolicy()` → `setSbtConfig()` → `admitSecurity()/registerToken()`

### Pool creator

`[admission]` → `LP.initializePool()` → `Registry.registerPendingPool()` → `PoolManager.initialize()` → `Registry.markPoolActive()` ◄── 两侧已批准，至多一stock，准确Hook/key及静态fee

### Reporters

`[roles + listing]` → `Inbox.submitAdtv()/submitAdtvBatch()` → `Ledger.acceptAdtv()` ◄── 对应前一来源月的ADTV

`[roles + listing]` → `Inbox.submitQuota()/submitSplitFactor()/submitMarketStatus()` → 对应Ledger/Registry写入口 ◄── 正确顺序、ID、deadline、version

### Trader / DEX Adapter

`[active pool + applicable ADTV]` → `Router.swapExactInput()/swapExactOutput()` → `PoolManager.unlock()` → `Router.unlockCallback()` → `PoolManager.swap()` → `Hook.afterSwap()` → `Ledger.recordSwap()` ◄── caller持有效且未暂停SBT，TRADE允许，cap足够

`[same trade prerequisites]` → `setAdapterAllowed()` → `Router.swapExactInputFromAdapter()` → 同一成交链 ◄── Adapter认证participant并付款/收款，participant持有效SBT

### LP owner / exit executor

`[active pool + SBT + LP允许]` → `openPosition()` → `increaseLiquidity()/decreaseLiquidity()/collectFees()/closePosition()` → `PoolManager.unlock()` → `LP.unlockCallback()` → `modifyLiquidity()` ◄── ordinary修改caller=position owner=Receipt owner

`[open position]` → `forceExit()` → 同一LP callback → `_close()` ◄── 强退admin，或撤证executor且owner已无credential；交付原owner

### Guardian / Council

`freezeUpgrades()` → `unfreezeUpgrades()` ◄── 当前Guardian与正确freeze ID

`Council.proposeRecovery()` → `Guardian.approveRecovery()` → `executeRecovery()` ◄── 当前epochs，无active upgrade batch

---

## Permissionless

### `TSVHookProxyFactoryV1.deploy()`

| Aspect | Detail |
|---|---|
| Visibility | external |
| Caller | 任意地址，必须提供合法implementation/initData与预测Hook地址bits |
| Parameters | `address implementation` (user-controlled); `bytes initData` (user-controlled); `bytes32 salt` (user-controlled) |
| Call chain | `predict → CREATE2 TSVERC1967Proxy constructor → ERC1967Proxy initialization delegatecall` |
| State modified | 创建新proxy；目标initData决定该proxy初始存储；Factory无治理存储写入 |
| Value flow | 无Token转移，接口不可payable |
| Reentrancy guard | 无；不持有业务操作状态 |
| Source | `src/v1/deployment/TSVHookProxyFactoryV1.sol:36` |

### `TSVGovernanceAnchor.executeRecovery()`

| Aspect | Detail |
|---|---|
| Visibility | external |
| Caller | 任意地址可执行已由Council提案、当前Guardian批准且epochs匹配的记录 |
| Parameters | `bytes32 id` (user-controlled)；新身份/epochs读取提案 (protocol-derived) |
| Call chain | `_validateRecovery → 消耗proposal → 更新Governor/Guardian与epochs` |
| State modified | recoveries[id].active/approved、Governor/Guardian、epoch、必要时guardianEpoch |
| Value flow | 无Token转移 |
| Reentrancy guard | 无外部调用；`upgradeContextActive`禁止batch中执行 |
| Source | `src/v1/governance/TSVGovernanceAnchor.sol:277` |

---

## Role-Gated

业务组件入口为external，共享基类renounceRole为public；`nonReentrant`为操作锁，不作为授权条件。Hook、Registry、Ledger和legacy绑定caller在函数体/内部helper中检查。下表每行对应一个定义。

| Entry / source | Effective caller | Parameters / trust | Downstream path / leaf | State modified | Value flow / lock |
|---|---|---|---|---|---|
| `TSVDataInboxV1.submitMarketStatus`<br>`src/v1/core/TSVDataInboxV1.sol:42` | HALT_REPORTER_ROLE（_accept） | `MarketReport report` (keeper-provided) | _accept → ReportValidationLib.validate → TSVRegistryV1.applyMarketStatus | Inbox 元数据；Registry market mask/sequence | 无Token转移；无reentrancy modifier |
| `TSVDataInboxV1.submitAdtv`<br>`src/v1/core/TSVDataInboxV1.sol:62` | VOLUME_ORACLE_ROLE（_accept） | `AdtvReport report` (keeper-provided) | _accept → ReportValidationLib.validate → TSVVolumeLedgerV1.acceptAdtv | Inbox 的 sequence/timestamp/used-ID；Ledger 对应报告记录 | 无Token转移；无reentrancy modifier |
| `TSVDataInboxV1.submitAdtvBatch`<br>`src/v1/core/TSVDataInboxV1.sol:69` | VOLUME_ORACLE_ROLE（_accept） | `AdtvReport[] reports` (keeper-provided) | _accept → ReportValidationLib.validate → TSVVolumeLedgerV1.acceptAdtv | Inbox 的 sequence/timestamp/used-ID；Ledger 对应报告记录 | 无Token转移；无reentrancy modifier |
| `TSVDataInboxV1.submitQuota`<br>`src/v1/core/TSVDataInboxV1.sol:107` | VOLUME_ORACLE_ROLE（_accept） | `QuotaReport report` (keeper-provided) | _accept → ReportValidationLib.validate → TSVVolumeLedgerV1.acceptQuota | Inbox 的 sequence/timestamp/used-ID；Ledger 对应报告记录 | 无Token转移；无reentrancy modifier |
| `TSVDataInboxV1.submitSplitFactor`<br>`src/v1/core/TSVDataInboxV1.sol:123` | VOLUME_ORACLE_ROLE（_accept） | `SplitFactorReport report` (keeper-provided) | _accept → ReportValidationLib.validate → TSVVolumeLedgerV1.acceptSplitFactor | Inbox 的 sequence/timestamp/used-ID；Ledger 对应报告记录 | 无Token转移；无reentrancy modifier |
| `TSVHookV1.afterSwap`<br>`src/v1/core/TSVHookV1.sol:216` | 绑定PoolManager + sender==Router | `address sender` (protocol-derived); `PoolKey key` (protocol-derived); `IPoolManager.SwapParams` (protocol-derived); `BalanceDelta delta` (protocol-derived); `bytes hookData` (protocol-derived) | _requireExactKey → _sharesForLeg → BackedAutoFeeLegalShareAdapter.toLegalShares / ERC8056DirectLegalShareAdapter.toLegalShares → TSVVolumeLedgerV1.recordSwap | Ledger usedWad；Hook自身无成交量存储 | 无Token转移；仅按实际delta计量；无reentrancy modifier |
| `TSVRegistryV1.admitSecurity`<br>`src/v1/core/TSVRegistryV1.sol:239` | SYMBOL_ADMIN_ROLE | `bytes32 securityId` (user-controlled); `bytes32 symbolHash` (user-controlled); `uint8 tierId` (user-controlled); `TokenConfig config` (user-controlled); `bytes32 evidenceHash` (user-controlled) | _takeTierSlot → _registerToken → Token/Adapter metadata | securities、symbol映射、Tier计数、tokens | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.relistSecurity`<br>`src/v1/core/TSVRegistryV1.sol:260` | SYMBOL_ADMIN_ROLE | `bytes32 securityId` (user-controlled); `bytes32 evidenceHash` (user-controlled) | _takeTierSlot → listed=true | listed/version、Tier计数 | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.setSecurityTier`<br>`src/v1/core/TSVRegistryV1.sol:273` | SYMBOL_ADMIN_ROLE | `bytes32 securityId` (user-controlled); `uint8 tierId` (user-controlled); `bytes32 evidenceHash` (user-controlled) | _takeTierSlot → 减少旧Tier | tierId/version、两Tier计数 | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.delistSecurity`<br>`src/v1/core/TSVRegistryV1.sol:290` | SYMBOL_ADMIN_ROLE | `bytes32 securityId` (user-controlled); `bytes32 evidenceHash` (user-controlled) | activePoolCount==0 → listed=false | listed/version、Tier计数 | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.registerToken`<br>`src/v1/core/TSVRegistryV1.sol:309` | SYMBOL_ADMIN_ROLE | `TokenConfig config` (user-controlled); `bytes32 evidenceHash` (user-controlled) | _registerToken → Token/Adapter metadata | tokens | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.setTokenStatus`<br>`src/v1/core/TSVRegistryV1.sol:350` | SYMBOL_ADMIN_ROLE | `address currency` (user-controlled); `TokenStatus status` (user-controlled); `bytes32 evidenceHash` (user-controlled) | approval检查 → status赋值 | tokens.status | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.replaceLegalShareAdapter`<br>`src/v1/core/TSVRegistryV1.sol:373` | SYMBOL_ADMIN_ROLE | `address currency` (user-controlled); `address newAdapter` (user-controlled); `bytes32 evidenceHash` (user-controlled) | _assetPausedForReplacement → _validateLegalShareAdapter → Adapter metadata | adapter/codehash/version/policy hash | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.registerPendingPool`<br>`src/v1/core/TSVRegistryV1.sol:402` | msg.sender==绑定LP Manager | `PoolKey key` (user-controlled) | 检查完整key/Token → PoolKey.toId | 新pool PENDING | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.markPoolActive`<br>`src/v1/core/TSVRegistryV1.sol:425` | 绑定LP Manager + PENDING | `bytes32 poolId` (user-controlled); `uint160 sqrtPriceX96` (user-controlled); `address creator` (user-controlled); `bytes32 priceBasisHash` (user-controlled) | ACTIVE赋值 → 计数增加 | pool status/version、活跃计数 | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.disablePool`<br>`src/v1/core/TSVRegistryV1.sol:441` | SYMBOL_ADMIN_ROLE | `bytes32 poolId` (user-controlled); `bytes32 evidenceHash` (user-controlled) | ACTIVE检查 → 计数减少 | pool status/version、活跃计数 | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.enablePool`<br>`src/v1/core/TSVRegistryV1.sol:456` | SYMBOL_ADMIN_ROLE | `bytes32 poolId` (user-controlled); `bytes32 evidenceHash` (user-controlled) | Token/listing/暂停检查 → 计数增加 | pool status/version、活跃计数 | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.applyMarketStatus`<br>`src/v1/core/TSVRegistryV1.sol:506` | msg.sender==绑定Inbox | `bytes32 securityId` (protocol-derived); `MarketAction action` (protocol-derived); `PauseMode mode` (protocol-derived); `uint64 sequence` (protocol-derived); `bytes32 reportId` (protocol-derived) | sequence/listed检查 → mask更新 | marketPauseMode、marketSequence | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.addEmergencyPause`<br>`src/v1/core/TSVRegistryV1.sol:539` | EMERGENCY_PAUSER_ROLE | `PauseScope scope` (user-controlled); `bytes32 target` (user-controlled); `PauseMode mode` (user-controlled); `bytes32 reasonCode` (user-controlled); `bytes32 sourceHash` (user-controlled) | 创建记录 → activePauseCount++ | nextPauseId、emergencyPauses、activePauseCount | 无Token转移；无reentrancy modifier |
| `TSVRegistryV1.clearEmergencyPause`<br>`src/v1/core/TSVRegistryV1.sol:558` | EMERGENCY_RESUMER_ROLE | `uint256 recordId` (user-controlled); `bytes32 reasonCode` (user-controlled) | active=false → activePauseCount-- | emergencyPauses、activePauseCount | 无Token转移；无reentrancy modifier |
| `TSVVolumeLedgerV1.acceptAdtv`<br>`src/v1/core/TSVVolumeLedgerV1.sol:186` | 绑定Inbox（onlyDataInbox） | `AdtvReport report` (protocol-derived) | 版本校验 → 既有factor可表示性检查 → 保存 | adtv value/version/reportId | 无Token转移；无reentrancy modifier |
| `TSVVolumeLedgerV1.acceptQuota`<br>`src/v1/core/TSVVolumeLedgerV1.sol:206` | 绑定Inbox（onlyDataInbox） | `QuotaReport report` (protocol-derived) | _hardCap → SET/CLEAR | quota value/active/version/reportId | 无Token转移；无reentrancy modifier |
| `TSVVolumeLedgerV1.acceptSplitFactor`<br>`src/v1/core/TSVVolumeLedgerV1.sol:234` | 绑定Inbox（onlyDataInbox） | `SplitFactorReport report` (protocol-derived) | currentTradeDay → _reducedFactor → 最新checkpoint更新/取消 | factor数组、factorVersions | 无Token转移；无reentrancy modifier |
| `TSVVolumeLedgerV1.recordSwap`<br>`src/v1/core/TSVVolumeLedgerV1.sol:460` | msg.sender==绑定Hook | `bytes32 poolId` (protocol-derived); `int128 delta0` (protocol-derived); `int128 delta1` (protocol-derived); `uint256 legalShares0` (protocol-derived); `uint256 legalShares1` (protocol-derived) | Registry.isTradable → currentTradeDay → _recordLeg → _consume | usedWad | 无Token转移；无reentrancy modifier |
| `TSVGovernanceAnchor.freezeUpgrades`<br>`src/v1/governance/TSVGovernanceAnchor.sol:129` | 当前Guardian | `bytes32 reasonHash` (user-controlled) | 生成incident ID → frozen=true | freezeEpoch/freezeId/upgradesFrozen | 无Token转移；无reentrancy modifier |
| `TSVGovernanceAnchor.unfreezeUpgrades`<br>`src/v1/governance/TSVGovernanceAnchor.sol:140` | 当前Guardian | `bytes32 expectedFreezeId` (user-controlled); `bytes32 evidenceHash` (user-controlled) | 检查当前freeze ID → frozen=false | upgradesFrozen | 无Token转移；无reentrancy modifier |
| `TSVGovernanceAnchor.proposeRecovery`<br>`src/v1/governance/TSVGovernanceAnchor.sol:239` | immutable Recovery Council | `address newGovernor` (user-controlled); `address newGuardian` (user-controlled); `bytes32 salt` (user-controlled); `bytes32 evidenceHash` (user-controlled) | _validateRecovery → 保存提案 | recoveries[id] | 无Token转移；无reentrancy modifier |
| `TSVGovernanceAnchor.approveRecovery`<br>`src/v1/governance/TSVGovernanceAnchor.sol:254` | 当前Guardian | `bytes32 id` (user-controlled) | 当前epoch提案 → approved=true | recoveries[id].approved | 无Token转移；无reentrancy modifier |
| `TSVGovernanceAnchor.revokeRecoveryApproval`<br>`src/v1/governance/TSVGovernanceAnchor.sol:263` | 当前Guardian | `bytes32 id` (user-controlled) | approved=false | recoveries[id].approved | 无Token转移；无reentrancy modifier |
| `TSVGovernanceAnchor.cancelRecovery`<br>`src/v1/governance/TSVGovernanceAnchor.sol:270` | immutable Recovery Council | `bytes32 id` (user-controlled) | active=false | recoveries[id].active | 无Token转移；无reentrancy modifier |
| `IssuerShareSettlementAdapter.pullAndWrap`<br>`src/v1/legacy/IssuerShareSettlementAdapter.sol:149` | immutable Router/LP Manager + activeAssetOperation context | `address owner` (user-controlled); `address receiver` (user-controlled); `uint256 shares` (user-controlled); `uint256 maxDisplayedDebit` (user-controlled); `bytes32 operationId` (user-controlled) | _requireContext → issuer.transferSharesFrom → wrapped.mint → wrapped.transfer | 外部issuer/wrapper余额与supply；临时reentrancy lock | owner → wrapper → 调用manager；nonReentrant |
| `IssuerShareSettlementAdapter.prepareReceive`<br>`src/v1/legacy/IssuerShareSettlementAdapter.sol:205` | immutable Router/LP Manager + activeAssetOperation context | `uint256 shares` (user-controlled); `bytes32 operationId` (user-controlled) | _requireContext → 保存pre-balances | prepared snapshot、临时lock | 无Token转移；nonReentrant |
| `IssuerShareSettlementAdapter.redeemAndDeliver`<br>`src/v1/legacy/IssuerShareSettlementAdapter.sol:221` | immutable Router/LP Manager + activeAssetOperation context | `address recipient` (user-controlled); `uint256 shares` (user-controlled); `uint256 minDisplayedCredit` (user-controlled); `bytes32 operationId` (user-controlled) | _requireContext → snapshot核对 → wrapped.redeem → 清除prepared | prepared删除；外部余额/supply；临时lock | wrapper → context recipient；nonReentrant |
| `TSVLPManagerV1.initializePool`<br>`src/v1/periphery/TSVLPManagerV1.sol:115` | POOL_CREATOR_ROLE | `PoolKey key` (user-controlled); `uint160 sqrtPriceX96` (user-controlled); `bytes32 priceBasisHash` (user-controlled) | Registry.registerPendingPool → PoolManager.initialize → Registry.markPoolActive | Registry pool/计数；PM pool | 无Token转移；nonReentrant |
| `TSVLPManagerV1.openPosition`<br>`src/v1/periphery/TSVLPManagerV1.sol:133` | Registry SBT当前有效/未暂停 | `PoolKey key` (user-controlled); `int24 tickLower` (user-controlled); `int24 tickUpper` (user-controlled); `uint128 liquidity` (user-controlled); `LPBounds bounds` (user-controlled) | _requireUserPool/_validateTicks → _modify → PoolManager.unlock → 保存liquidity/_mint | nextPositionId、position、Receipt、临时context；PM仓位 | owner → PM，可能PM → owner；nonReentrant |
| `TSVLPManagerV1.increaseLiquidity`<br>`src/v1/periphery/TSVLPManagerV1.sol:156` | Registry SBT当前有效/未暂停 + position.owner==Receipt owner==caller | `uint256 positionId` (user-controlled); `uint128 liquidity` (user-controlled); `LPBounds bounds` (user-controlled) | _requireOwner → _modify → PoolManager.unlock → liquidity增加 | position.liquidity、临时context；PM仓位 | owner → PM，可能PM → owner；nonReentrant |
| `TSVLPManagerV1.decreaseLiquidity`<br>`src/v1/periphery/TSVLPManagerV1.sol:174` | Registry SBT当前有效/未暂停 + position.owner==Receipt owner==caller | `uint256 positionId` (user-controlled); `uint128 liquidity` (user-controlled); `LPBounds bounds` (user-controlled) | _requireOwner → _modify → PoolManager.unlock → liquidity减少 | position.liquidity、临时context；PM仓位 | PM → owner，依实际delta也可能owner → PM；nonReentrant |
| `TSVLPManagerV1.collectFees`<br>`src/v1/periphery/TSVLPManagerV1.sol:186` | Registry SBT当前有效/未暂停 + position.owner==Receipt owner==caller | `uint256 positionId` (user-controlled); `LPBounds bounds` (user-controlled) | _requireOwner → _modify → PoolManager.unlock | 临时context；PM fees | PM → owner；nonReentrant |
| `TSVLPManagerV1.closePosition`<br>`src/v1/periphery/TSVLPManagerV1.sol:197` | Registry SBT当前有效/未暂停 + position.owner==Receipt owner==caller | `uint256 positionId` (user-controlled); `LPBounds bounds` (user-controlled) | _requireOwner → _modify → PoolManager.unlock → _close/_burn | liquidity=0、active=false、Receipt烧毁、临时context | PM → owner，依实际delta也可能owner → PM；nonReentrant |
| `TSVLPManagerV1.forceExit`<br>`src/v1/periphery/TSVLPManagerV1.sol:210` | FORCE_EXIT_ADMIN_ROLE，或 REVOKE_EXIT_EXECUTOR_ROLE 且 owner无credential | `uint256 positionId` (user-controlled); `uint256 minPoolOut0` (user-controlled); `uint256 minPoolOut1` (user-controlled); `bytes32 reasonCode` (user-controlled); `bytes32 evidenceHash` (user-controlled) | role/credential检查 → Registry.isKnownPool → _modify → PoolManager.unlock → _close | 关闭position/Receipt、临时context；PM仓位 | 仅PM → 原owner；负付款delta拒绝；nonReentrant |
| `TSVLPManagerV1.unlockCallback`<br>`src/v1/periphery/TSVLPManagerV1.sol:303` | 绑定PM + entered + 活跃context + 请求hash | `bytes data` (protocol-derived) | 解码hash匹配请求 → PoolManager.modifyLiquidity → TSVDirectSettlementLib.settle/take | PM仓位/Token余额；callback本身不写position.liquidity | 按两leg实际delta，owner ↔ PM；要求entered；LP另核对hash |
| `TSVSwapRouterV1.swapExactInput`<br>`src/v1/periphery/TSVSwapRouterV1.sol:103` | msg.sender有当前有效SBT | `SwapRequest request` (user-controlled) | _swapWithSettlement → _validate → PoolManager.unlock | entered临时锁；PM成交、Ledger usedWad | caller ↔ PM；nonReentrant |
| `TSVSwapRouterV1.swapExactOutput`<br>`src/v1/periphery/TSVSwapRouterV1.sol:115` | msg.sender有当前有效SBT | `SwapRequest request` (user-controlled) | _swapWithSettlement → _validate → PoolManager.unlock | entered临时锁；PM成交、Ledger usedWad | caller ↔ PM；nonReentrant |
| `TSVSwapRouterV1.swapExactInputFromAdapter`<br>`src/v1/periphery/TSVSwapRouterV1.sol:130` | allowlisted Adapter + participant有当前有效SBT | `SwapRequest request` (user-controlled); `address participant` (user-controlled) | _swapWithSettlement → _validate → PoolManager.unlock | entered临时锁；PM成交、Ledger usedWad | Adapter ↔ PM；participant用于资格；nonReentrant |
| `TSVSwapRouterV1.unlockCallback`<br>`src/v1/periphery/TSVSwapRouterV1.sol:154` | 绑定PM + entered | `bytes data` (protocol-derived) | PoolManager.swap → delta/界限检查 → TSVDirectSettlementLib.settle/take | PM pool/Token余额；Ledger由Hook计量 | request.payer/recipient ↔ PM；要求entered；LP另核对hash |
| `TSVGoverned.renounceRole`<br>`src/v1/governance/TSVGoverned.sol:92` | account==caller（self-confirmation）；任何地址可放弃自身非DEFAULT_ADMIN角色，无事先持有角色要求 | `bytes32 role` (user-controlled); `address account` (user-controlled，须等于caller) | AccessControlUpgradeable.renounceRole → TSVGoverned._revokeRole；继承语义仅作辅助 | caller的指定business role成员位；无成员时不变 | 无Token转移；无外部调用 |

---

## Admin-Only

这些定义由当前Governor/DEFAULT_ADMIN即时执行；`grantRole/revokeRole`经父类的DEFAULT_ADMIN检查，动态身份查询回到Anchor。Anchor.upgradeBatch初始化caller为Anchor。

| Contract | Function / source | Parameters / trust | State Modified |
|---|---|---|---|
| TSVRegistryV1 | `bindComponents()`<br>`src/v1/core/TSVRegistryV1.sol:161` | `address hook_` (user-controlled); `address lpManager_` (user-controlled); `address dataInbox_` (user-controlled) | hook/lpManager/dataInbox |
| TSVRegistryV1 | `setTierPolicy()`<br>`src/v1/core/TSVRegistryV1.sol:177` | `uint8 tierId` (user-controlled); `uint16 tierBps` (user-controlled); `uint32 maxListed` (user-controlled); `bytes32 evidenceHash` (user-controlled) | tiers[tierId].tierBps/maxListed |
| TSVRegistryV1 | `setSbtConfig()`<br>`src/v1/core/TSVRegistryV1.sol:198` | `address sbt_` (user-controlled); `uint256 tokenId_` (user-controlled); `bytes32 evidenceHash` (user-controlled) | participantSbt/sbtTokenId |
| TSVVolumeLedgerV1 | `bindWriters()`<br>`src/v1/core/TSVVolumeLedgerV1.sol:169` | `address hook_` (user-controlled); `address dataInbox_` (user-controlled) | hook/dataInbox |
| TSVVolumeLedgerV1 | `scheduleDayStart()`<br>`src/v1/core/TSVVolumeLedgerV1.sol:335` | `uint32 newOffsetSeconds` (user-controlled); `uint32 effectiveDayId` (user-controlled); `bytes32 reasonHash` (user-controlled) | dayStartCheckpoints、hasPendingDayStart |
| TSVVolumeLedgerV1 | `cancelPendingDayStart()`<br>`src/v1/core/TSVVolumeLedgerV1.sol:373` | `bytes32 reasonHash` (user-controlled) | checkpoint pop、hasPendingDayStart |
| TSVGovernanceAnchor | `upgradeBatch()`<br>`src/v1/governance/TSVGovernanceAnchor.sol:151` | `address[] targets` (user-controlled); `address[] implementations` (user-controlled); `bytes[] initData` (user-controlled) | upgradeContextActive；最多6个proxy的implementation及init状态 |
| TSVGovernanceAnchor | `bindProxies()`<br>`src/v1/governance/TSVGovernanceAnchor.sol:204` | `address[6] addresses` (user-controlled) | proxies[6]、proxiesBound |
| TSVGoverned | `grantRole()`<br>`src/v1/governance/TSVGoverned.sol:76` | `bytes32 role` (user-controlled); `address account` (user-controlled) | 指定business role成员 |
| TSVGoverned | `revokeRole()`<br>`src/v1/governance/TSVGoverned.sol:84` | `bytes32 role` (user-controlled); `address account` (user-controlled) | 指定business role成员 |
| TSVSwapRouterV1 | `setAdapterAllowed()`<br>`src/v1/periphery/TSVSwapRouterV1.sol:144` | `address adapter` (user-controlled); `bool allowed` (user-controlled) | isAdapterAllowed[adapter] |

### Inherited upgrade selector

`upgradeToAndCall(address newImplementation, bytes data)`是OpenZeppelin UUPS继承入口，部署在六个业务proxy上；不增加上述59个自行声明定义计数。两个参数均user-controlled（当前Governor或活跃Anchor batch），链路为UUPS→`TSVGoverned._authorizeUpgrade()`→ERC1967升级/初始化，写implementation slot和可选初始化状态；要求未冻结（`TSVGoverned.sol:116–123`）。

### Excluded ABI functions

view/pure、interface declarations和internal libraries不计入口。LP的approve/setApprovalForAll/transferFrom/safeTransferFrom四参覆盖实现均pure并拒绝；继承三参safeTransferFrom分派至拒绝实现。Hook的view门禁回调虽不计入口，其校验仍列入guards与运行流程。Adapter的toLegalShares为view转换。

---

## Initialization

一次性external入口，部署时caller可选参数；实施constructor中的 `_disableInitializers()` 锁实现，proxy通过nonempty构造initData初始化（`TSVGoverned.sol:31–51`、`TSVERC1967Proxy.sol:15–16`）。

| Initializer / source | Parameters (user-controlled) | Initialized state |
|---|---|---|
| `TSVDataInboxV1.initialize`<br>`src/v1/core/TSVDataInboxV1.sol:33` | `address anchor` (user-controlled); `address registry_` (user-controlled); `address ledger_` (user-controlled) | Anchor/AccessControl基础；该组件的Registry/Ledger/PM/Router/LP链接，或Ledger初始offset；LP另ERC721元数据与nextPositionId=1 |
| `TSVHookV1.initialize`<br>`src/v1/core/TSVHookV1.sol:57` | `address anchor` (user-controlled); `address poolManager_` (user-controlled); `address registry_` (user-controlled); `address ledger_` (user-controlled); `address router_` (user-controlled); `address lpManager_` (user-controlled) | Anchor/AccessControl基础；该组件的Registry/Ledger/PM/Router/LP链接，或Ledger初始offset；LP另ERC721元数据与nextPositionId=1 |
| `TSVRegistryV1.initialize`<br>`src/v1/core/TSVRegistryV1.sol:152` | `address anchor` (user-controlled) | Anchor/AccessControl基础；该组件的Registry/Ledger/PM/Router/LP链接，或Ledger初始offset；LP另ERC721元数据与nextPositionId=1 |
| `TSVVolumeLedgerV1.initialize`<br>`src/v1/core/TSVVolumeLedgerV1.sol:159` | `address anchor` (user-controlled); `address registry_` (user-controlled); `uint32 dayStartOffsetSeconds` (user-controlled) | Anchor/AccessControl基础；该组件的Registry/Ledger/PM/Router/LP链接，或Ledger初始offset；LP另ERC721元数据与nextPositionId=1 |
| `TSVLPManagerV1.initialize`<br>`src/v1/periphery/TSVLPManagerV1.sol:94` | `address anchor` (user-controlled); `address poolManager_` (user-controlled); `address registry_` (user-controlled) | Anchor/AccessControl基础；该组件的Registry/Ledger/PM/Router/LP链接，或Ledger初始offset；LP另ERC721元数据与nextPositionId=1 |
| `TSVSwapRouterV1.initialize`<br>`src/v1/periphery/TSVSwapRouterV1.sol:81` | `address anchor` (user-controlled); `address poolManager_` (user-controlled); `address registry_` (user-controlled); `address ledger_` (user-controlled) | Anchor/AccessControl基础；该组件的Registry/Ledger/PM/Router/LP链接，或Ledger初始offset；LP另ERC721元数据与nextPositionId=1 |
