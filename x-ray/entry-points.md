# Entry Point Map
> TSV V1 · main@6743896 · 50 主场所有效可变入口 · 9 permissionless / 29 role-gated / 12 admin-only

统计五个 TSV 业务组件及 Hook Proxy Factory 的实际有效 ABI，含继承入口及 receive；重载分开计数。初始化、永久禁用入口及发行方辅助合约另列。签名 relayer 可由任意地址提交，但签名必须有效；LP actions 的入口本身无角色 modifier，实际有效 action 均在内部检查参与者权限。空 actions 不执行资金/头寸操作。Value flow 指业务资产方向；payable 方法另可附带 msg.value，none 不等于不接收 ETH。

## Protocol Flow Paths

### Setup / admission

`Registry.initialize(admin)` → `bindComponents` → `setTierPolicy` / `setSbtConfig` → grant business roles

`Factory.createPermissionsAdapter` → `W.depositForVerification` → `Factory.verifyPermissionsAdapter` → `Registry.registerPermissionedCurrency` / `registerQuoteToken`

`[admission above]` → `LPManager.initializePool` → `Registry.registerPool` → `PoolManager.initialize`

### Trading

`Router.setAdapterAllowed` → `[pool setup above]` → `[VOLUME_ORACLE setQuota]` → `swapExactInputFromContract` / `swapExactInputFromAdapterDirect` ◄── liquidity / SBT / issuer permissions / multiplier / deadline

`swap` → `PM.swap` → `Hook.beforeSwap` / `Hook.afterSwap` → `Ledger.recordSwap` → settle / take

### LP / position management

`[pool setup above]` → `[TokenApprove chain approval]` → `modifyLiquidities(MINT + SETTLE)` ◄── executor / recipient LP permission

`[mint above]` → `approve` / signed `permit` → `modifyLiquidities(INCREASE / DECREASE / BURN + TAKE)` ◄── owner / operator + pool gate

`[mint above]` → `unwindPositionByOkx` / issuer `unwindPosition` ◄── W.UNWIND_ALLOWED / global not paused

`[public methods above]` → `multicall` ◄── each inner method retains its own role / signature / action checks

## Permissionless

### `TSVHookProxyFactoryV1.deploy()` @ src/v1/deployment/TSVHookProxyFactoryV1.sol:36

| Aspect | Detail |
|---|---|
| Visibility | `function deploy(address implementation, bytes calldata initData, bytes32 salt) external returns (address proxy)` |
| Caller | any caller; valid code/initData/salt/flags |
| Parameters | user-controlled；见完整 typed signature |
| Call chain | CREATE2 TSVERC1967Proxy → constructor init delegatecall |
| State modified | new proxy ERC1967/initializer storage |
| Value flow | none |
| Reentrancy guard / pause | no；none |

### `TSVLPManagerV1.setApprovalForAll()` @ src/v1/periphery/TSVLPManagerV1.sol:224

| Aspect | Detail |
|---|---|
| Visibility | `function setApprovalForAll(address operator, bool approved) public override whenRegistryNotPaused` |
| Caller | self operator approval |
| Parameters | user-controlled；见完整 typed signature |
| Call chain | ERC721Permit._approveForAll |
| State modified | isApprovedForAll[caller] |
| Value flow | none |
| Reentrancy guard / pause | no；global pause gate |

### `TSVLPManagerV1.permit()` @ src/v1/periphery/TSVLPManagerV1.sol:228

| Aspect | Detail |
|---|---|
| Visibility | `function permit(address spender, uint256 tokenId, uint256 deadline, uint256 nonce, bytes calldata signature) public payable override(ERC721Permit_v4, IERC721Permit_v4) whenRegistryNotPaused` |
| Caller | 任意 relayer；当前 NFT owner 签名 |
| Parameters | user-signed；见完整 typed signature |
| Call chain | ERC721Permit → signature verification → nonce → _approve |
| State modified | NFT signer nonce / getApproved |
| Value flow | none |
| Reentrancy guard / pause | no; signature deadline；global pause gate |

### `TSVLPManagerV1.permitForAll()` @ src/v1/periphery/TSVLPManagerV1.sol:237

| Aspect | Detail |
|---|---|
| Visibility | `function permitForAll( address owner, address operator, bool approved, uint256 deadline, uint256 nonce, bytes calldata signature ) public payable override(ERC721Permit_v4, IERC721Permit_v4) whenRegistryNotPaused` |
| Caller | relayer; owner signature |
| Parameters | user-signed；见完整 typed signature |
| Call chain | ERC721Permit verification → nonce → _approveForAll |
| State modified | nonce bitmap / isApprovedForAll |
| Value flow | none |
| Reentrancy guard / pause | no; signature deadline；global pause gate |

### `TSVLPManagerV1.permit()` @ src/v1/periphery/TSVLPManagerV1.sol:248

| Aspect | Detail |
|---|---|
| Visibility | `function permit(address owner, IAllowanceTransfer.PermitSingle calldata permitSingle, bytes calldata signature) public payable override(Permit2Forwarder, IPermit2Forwarder) whenRegistryNotPaused returns (bytes memory err)` |
| Caller | 任意 relayer；Permit2 验证 owner 签名 |
| Parameters | user-signed；见完整 typed signature |
| Call chain | Permit2Forwarder → Permit2.permit；catch 返回 err |
| State modified | 外部 Permit2 allowance |
| Value flow | none |
| Reentrancy guard / pause | no; external signature check；global pause gate |

### `TSVLPManagerV1.permitBatch()` @ src/v1/periphery/TSVLPManagerV1.sol:258

| Aspect | Detail |
|---|---|
| Visibility | `function permitBatch(address owner, IAllowanceTransfer.PermitBatch calldata permits, bytes calldata signature) public payable override(Permit2Forwarder, IPermit2Forwarder) whenRegistryNotPaused returns (bytes memory err)` |
| Caller | relayer; Permit2 signatures |
| Parameters | user-signed；见完整 typed signature |
| Call chain | Permit2Forwarder → Permit2.permit (catch returns error) |
| State modified | external Permit2 allowance |
| Value flow | none |
| Reentrancy guard / pause | no；global pause gate |

### `TSVLPManagerV1.revokeNonce()` @ src/v1/periphery/TSVLPManagerV1.sol:268

| Aspect | Detail |
|---|---|
| Visibility | `function revokeNonce(uint256 nonce) public payable override(UnorderedNonce, IUnorderedNonce) whenRegistryNotPaused` |
| Caller | self nonce consumption |
| Parameters | user-controlled；见完整 typed signature |
| Call chain | UnorderedNonce._useUnorderedNonce |
| State modified | caller nonce bitmap |
| Value flow | none |
| Reentrancy guard / pause | no；global pause gate |

### `TSVLPManagerV1.multicall()` @ src/v1/periphery/TSVLPManagerV1.sol:285

| Aspect | Detail |
|---|---|
| Visibility | `function multicall(bytes[] calldata data) public payable override(Multicall_v4, IMulticall_v4) whenRegistryNotPaused returns (bytes[] memory results)` |
| Caller | any caller; inner calls retain gates |
| Parameters | user-controlled；见完整 typed signature |
| Call chain | Multicall → delegatecall public methods |
| State modified | inner calls determine state |
| Value flow | in/out/none |
| Reentrancy guard / pause | inner calls determine lock；global pause gate |

### `TSVRegistryV1.renounceRole()` @ dependencies/@openzeppelin-contracts-upgradeable-5.5.0/access/AccessControlUpgradeable.sol:177

| Aspect | Detail |
|---|---|
| Visibility | `function renounceRole(bytes32 role, address callerConfirmation) public virtual {` |
| Caller | 自己的角色；callerConfirmation==msg.sender |
| Parameters | user-controlled；见完整 typed signature |
| Call chain | AccessControl._revokeRole |
| State modified | 自己 role membership |
| Value flow | none |
| Reentrancy guard / pause | no；none |

## Role-Gated

角色/管理员参数由授权调用者选择，标记为 user-controlled；HALT/VOLUME reporter 的操作参数为 keeper-provided；callback 数据和固定组件地址为 protocol-derived。

| Contract / function / source | Access | Parameters | State / call chain | Value / lock / pause |
|---|---|---|---|---|
| TSVHookV1.`afterSwap` · src/v1/core/TSVHookV1.sol:220 | PoolManager caller + fixed Router sender | protocol-derived; `function afterSwap( address sender, PoolKey calldata key, IPoolManager.SwapParams calldata, BalanceDelta delta, bytes calldata hookData ) external override onlyPoolManager returns (bytes4, int128)` | Ledger usedWad → Hook → configured LegalShareAdapter → Ledger.recordSwap | none; PM callback boundary; afterSwap 无直接 gate；同次 beforeSwap 检查 |
| TSVRegistryV1.`relistSecurity` · src/v1/core/TSVRegistryV1.sol:355 | SYMBOL_ADMIN_ROLE | user-controlled; `function relistSecurity(bytes32 securityId, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | security listed / tier counter → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`setSecurityTier` · src/v1/core/TSVRegistryV1.sol:368 | SYMBOL_ADMIN_ROLE | user-controlled; `function setSecurityTier(bytes32 securityId, uint8 tierId, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | security tier / tier counters → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`delistSecurity` · src/v1/core/TSVRegistryV1.sol:385 | SYMBOL_ADMIN_ROLE | user-controlled; `function delistSecurity(bytes32 securityId, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | security listed / tier counter → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`registerPermissionedCurrency` · src/v1/core/TSVRegistryV1.sol:406 | SYMBOL_ADMIN_ROLE | user-controlled; `function registerPermissionedCurrency( PermissionedRegisterParam calldata registerParam, uint8 tierId, bytes32 reasonCode ) external onlyRole(SYMBOL_ADMIN_ROLE)` | security / tier / canonical U / W→U → PermissionedValidationLib → Factory/W metadata → canonical records | none; no; none |
| TSVRegistryV1.`registerQuoteToken` · src/v1/core/TSVRegistryV1.sol:433 | SYMBOL_ADMIN_ROLE | user-controlled; `function registerQuoteToken(address quote, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | Q metadata + registered → PermissionedValidationLib → quote metadata → record | none; no; none |
| TSVRegistryV1.`disableQuoteTokenPoolRegister` · src/v1/core/TSVRegistryV1.sol:446 | SYMBOL_ADMIN_ROLE | user-controlled; `function disableQuoteTokenPoolRegister(address quote, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | Q registered=false → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`disableUnderlyingPoolRegister` · src/v1/core/TSVRegistryV1.sol:460 | SYMBOL_ADMIN_ROLE | user-controlled; `function disableUnderlyingPoolRegister(address u, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | U registered=false → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`replaceUnderlyingLegalShareAdapter` · src/v1/core/TSVRegistryV1.sol:475 | SYMBOL_ADMIN_ROLE | user-controlled; `function replaceUnderlyingLegalShareAdapter(address u, address newAdapter, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE)` | U converter → PermissionedValidationLib → adapter ERC165/poolCurrency → replace | none; no; none |
| TSVRegistryV1.`registerPool` · src/v1/core/TSVRegistryV1.sol:513 | fixed lpManager | protocol-derived; `function registerPool(PoolKey calldata key) external returns (bytes32 poolId)` | PoolRecord + security.poolIds/listedPoolCount → PoolKey ID → asset/security gates → pool record | none; no; none |
| TSVRegistryV1.`updatePoolLifeCycle` · src/v1/core/TSVRegistryV1.sol:584 | SYMBOL_ADMIN_ROLE | user-controlled; `function updatePoolLifeCycle(bytes32 poolId, PoolLifecycle lifecycle, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE) returns (bool)` | lifecycle + listedPoolCount → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`batchUpdatePoolLifeCycle` · src/v1/core/TSVRegistryV1.sol:600 | SYMBOL_ADMIN_ROLE | user-controlled; `function batchUpdatePoolLifeCycle(bytes32[] calldata poolIds, PoolLifecycle lifecycle, bytes32 reasonCode) external onlyRole(SYMBOL_ADMIN_ROLE) returns (uint256 changedCount)` | lifecycle + listedPoolCount → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`updatePoolTickCount` · src/v1/core/TSVRegistryV1.sol:620 | fixed lpManager | protocol-derived; `function updatePoolTickCount(PoolKey calldata key, int256 delta) external returns (bool)` | tickCount → checked signed delta → tickCount | none; no; none |
| TSVRegistryV1.`applySecurityStatus` · src/v1/core/TSVRegistryV1.sol:643 | HALT_REPORTER_ROLE | keeper-provided; `function applySecurityStatus(bytes32 securityId, SecurityPauseMode mode) external onlyRole(HALT_REPORTER_ROLE)` | security pauseMode → Registry guards → state assignment → event | none; no; none |
| TSVRegistryV1.`setEmergencyPauseEnable` · src/v1/core/TSVRegistryV1.sol:656 | dynamic emergency pauser/resumer | user-controlled; `function setEmergencyPauseEnable(bool enabled, bytes32 reasonCode) external` | emergencyPauseEnable → Registry guards → state assignment → event | none; no; none |
| TSVVolumeLedgerV1.`setQuota` · src/v1/core/TSVVolumeLedgerV1.sol:41 | VOLUME_ORACLE_ROLE | keeper-provided; `function setQuota(bytes32 securityId, DailyQuota[] calldata values, bytes32 reasonCode) external` | Quota[securityId][day] → direct quota assignment → QuotaSet | none; no; none |
| TSVVolumeLedgerV1.`recordSwap` · src/v1/core/TSVVolumeLedgerV1.sol:57 | fixed Registry.hook() | protocol-derived; `function recordSwap(bytes32 poolId, int128 delta0, int128 delta1, uint256 legalShares0, uint256 legalShares1) external` | usedWad[securityId][currentESTDay] → Registry.getPool → quota check → used increment | none; trusted Hook callback; none |
| TSVLPManagerV1.`initializePool` · src/v1/periphery/TSVLPManagerV1.sol:126 | POOL_CREATOR_ROLE | user-controlled; `function initializePool(PoolKey calldata key, uint160 sqrtPriceX96) public payable override(PoolInitializer_v4, IPoolInitializer_v4) onlyRole(POOL_CREATOR_ROLE) whenRegistryNotPaused isNotLocked returns (int24 tick)` | Registry pool record / PM price → TSVLPManagerLib.initializePool → Registry.registerPool → PoolManager.initialize | none; yes; global pause gate |
| TSVLPManagerV1.`unwindPositionByOkx` · src/v1/periphery/TSVLPManagerV1.sol:140 | FORCE_EXIT_ADMIN_ROLE + W.UNWIND_ALLOWED(lp) | user-controlled; `function unwindPositionByOkx(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) external onlyRole(FORCE_EXIT_ADMIN_ROLE) whenRegistryNotPaused isNotLocked` | NFT/position/subscriber + Registry tickCount → LP library → PM.unlock → burn/TAKE_PAIR → U/Q to LP | out; yes; global pause gate |
| TSVLPManagerV1.`modifyLiquidities` · src/v1/periphery/TSVLPManagerV1.sol:197 | action-gated SBT LP; existing NFT also approval | user-controlled; `function modifyLiquidities(bytes calldata unlockData, uint256 deadline) public payable override whenRegistryNotPaused` | NFT / position / poolKeys / Registry tickCount → PositionManager → PM.unlock → dispatch → U/Q settlement | in/out; yes; deadline; global pause gate |
| TSVLPManagerV1.`modifyLiquiditiesWithoutUnlock` · src/v1/periphery/TSVLPManagerV1.sol:206 | action-gated SBT LP; existing NFT also approval | user-controlled; `function modifyLiquiditiesWithoutUnlock(bytes calldata actions, bytes[] calldata params) public payable override whenRegistryNotPaused` | same action state → PositionManager → dispatch in existing PM unlock → settlement | in/out; yes; global pause gate |
| TSVLPManagerV1.`approve` · src/v1/periphery/TSVLPManagerV1.sol:220 | NFT owner or operator | user-controlled; `function approve(address spender, uint256 tokenId) public override whenRegistryNotPaused` | getApproved[tokenId] → ERC721Permit.approve → _approve | none; no; global pause gate |
| TSVLPManagerV1.`subscribe` · src/v1/periphery/TSVLPManagerV1.sol:272 | NFT owner/approved/operator | user-controlled; `function subscribe(uint256 tokenId, address newSubscriber, bytes calldata data) public payable override(Notifier, INotifier) whenRegistryNotPaused` | subscriber / positionInfo bit → Notifier → notifySubscribe | none; PM locked; global pause gate |
| TSVLPManagerV1.`unsubscribe` · src/v1/periphery/TSVLPManagerV1.sol:281 | NFT owner/approved/operator | user-controlled; `function unsubscribe(uint256 tokenId) public payable override(Notifier, INotifier) whenRegistryNotPaused` | subscriber / positionInfo bit → Notifier → bounded notifyUnsubscribe | none; PM locked; global pause gate |
| TSVLPManagerV1.`unlockCallback` · src/v1/periphery/TSVLPManagerV1.sol:295 | immutable PoolManager | protocol-derived; `function unlockCallback(bytes calldata data) public override whenRegistryNotPaused returns (bytes memory)` | NFT/action state; transient callback hash → SafeCallback → exact hash or ordinary actions dispatch | in/out; PM-only; operation holds lock; global pause gate |
| TSVSwapRouterV1.`swapExactInputFromAdapterDirect` · src/v1/periphery/TSVSwapRouterV1.sol:106 | allowlisted contract adapter + participant SBT | user-controlled; `function swapExactInputFromAdapterDirect( SwapRequest calldata request, address participant, address recipient ) external whenRegistryNotPaused isNotLocked returns (uint256 actualIn, uint256 actualOut)` | active context / PM pool / Ledger usage → transfer U/Q from participant → PM.unlock → swap/settle/take | in/out; yes; global pause gate |
| TSVSwapRouterV1.`swapExactInputFromContract` · src/v1/periphery/TSVSwapRouterV1.sol:117 | allowlisted contract adapter + participant SBT | user-controlled; `function swapExactInputFromContract(SwapRequest calldata request, address participant) external whenRegistryNotPaused isNotLocked returns (uint256 actualIn, uint256 actualOut)` | active context / PM pool / Ledger usage → transfer U/Q from adapter → PM.unlock → swap/settle/take to adapter | in/out; yes; global pause gate |
| TSVSwapRouterV1.`unlockCallback` · src/v1/vendor/v4-router/base/SafeCallback.sol:15 | immutable PoolManager | protocol-derived; `function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {` | activeAmountIn/Out / trade state → BaseActionsRouter → V4Router actions → settlement | in/out; PM-only callback; swap holds lock; outer swap global gate |
| TSVLPManagerV1.`receive` · src/v1/vendor/permissionedPools/base/NativeWrapper.sol:34 | WETH9 or PoolManager | protocol-derived; `receive() external payable virtual {` | native balance → receive ETH | in; sender gate; none |

## Admin-Only

角色/管理员参数由授权调用者选择，标记为 user-controlled；HALT/VOLUME reporter 的操作参数为 keeper-provided；callback 数据和固定组件地址为 protocol-derived。

| Contract / function / source | Access | Parameters | State / call chain | Value / lock / pause |
|---|---|---|---|---|
| TSVRegistryV1.`bindComponents` · src/v1/core/TSVRegistryV1.sol:230 | DEFAULT_ADMIN_ROLE | user-controlled; `function bindComponents(address hook_, address lpManager_, address factory, address sbt_) external onlyRole(DEFAULT_ADMIN_ROLE)` | fixed component set → SBT.paused/verify → Factory.POOL_MANAGER → bind | none; no; none |
| TSVRegistryV1.`setSbtConfig` · src/v1/core/TSVRegistryV1.sol:270 | DEFAULT_ADMIN_ROLE | user-controlled; `function setSbtConfig(uint256 tokenId, PermissionFlag permissions, bytes32 reasonCode) external onlyRole(DEFAULT_ADMIN_ROLE)` | identityTokenIds / identity config → SBT.verify → configure | none; no; none |
| TSVRegistryV1.`setTierPolicy` · src/v1/core/TSVRegistryV1.sol:334 | DEFAULT_ADMIN_ROLE | user-controlled; `function setTierPolicy(uint8 tierId, uint32 maxListed, bytes32 reasonCode) external onlyRole(DEFAULT_ADMIN_ROLE)` | tier maxListed → Registry guards → state assignment → event | none; no; none |
| TSVLPManagerV1.`unwindPosition` · src/v1/periphery/TSVLPManagerV1.sol:167 | W owner + W.UNWIND_ALLOWED(lp) | user-controlled; `function unwindPosition(uint256 tokenId, uint128 amount0Min, uint128 amount1Min, bytes calldata hookData) public override whenRegistryNotPaused isNotLocked` | NFT/position/subscriber + Registry tickCount + internal claim → LP library → PM.unlock → burn/claim → isolated delivery LP/W owner | out; yes; global pause gate |
| TSVLPManagerV1.`upgradeToAndCall` · src/v1/periphery/TSVLPManagerV1.sol:299 | Registry UPGRADE_ADMIN_ROLE | user-controlled; `function upgradeToAndCall(address newImplementation, bytes memory data) public payable override whenRegistryNotPaused` | ERC1967 implementation / migration → UUPS → newImplementation.proxiableUUID → upgrade/delegatecall | none; onlyProxy; global pause gate |
| TSVSwapRouterV1.`setAdapterAllowed` · src/v1/periphery/TSVSwapRouterV1.sol:91 | DEFAULT_ADMIN_ROLE | user-controlled; `function setAdapterAllowed(address adapter, bool allowed) external whenRegistryNotPaused onlyRole(DEFAULT_ADMIN_ROLE)` | isAdapterAllowed → direct assignment → authorization event | none; no; global pause gate |
| TSVRegistryV1.`grantRole` · dependencies/@openzeppelin-contracts-upgradeable-5.5.0/access/AccessControlUpgradeable.sol:142 | getRoleAdmin(role) | user-controlled; `function grantRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {` | role membership → AccessControl._grantRole | none; no; none |
| TSVRegistryV1.`revokeRole` · dependencies/@openzeppelin-contracts-upgradeable-5.5.0/access/AccessControlUpgradeable.sol:157 | getRoleAdmin(role) | user-controlled; `function revokeRole(bytes32 role, address account) public virtual onlyRole(getRoleAdmin(role)) {` | role membership → AccessControl._revokeRole | none; no; none |
| TSVRegistryV1.`upgradeToAndCall` · dependencies/@openzeppelin-contracts-5.5.0/proxy/utils/UUPSUpgradeable.sol:88 | UPGRADE_ADMIN_ROLE | user-controlled; `function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual onlyProxy {` | ERC1967 implementation / migration → UUPS → implementation.proxiableUUID → ERC1967 upgrade | none; onlyProxy; none |
| TSVHookV1.`upgradeToAndCall` · dependencies/@openzeppelin-contracts-5.5.0/proxy/utils/UUPSUpgradeable.sol:88 | Registry UPGRADE_ADMIN_ROLE | user-controlled; `function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual onlyProxy {` | ERC1967 implementation / migration → UUPS → implementation.proxiableUUID → ERC1967 upgrade | none; onlyProxy; global pause gate |
| TSVVolumeLedgerV1.`upgradeToAndCall` · dependencies/@openzeppelin-contracts-5.5.0/proxy/utils/UUPSUpgradeable.sol:88 | Registry UPGRADE_ADMIN_ROLE | user-controlled; `function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual onlyProxy {` | ERC1967 implementation / migration → UUPS → implementation.proxiableUUID → ERC1967 upgrade | none; onlyProxy; none |
| TSVSwapRouterV1.`upgradeToAndCall` · dependencies/@openzeppelin-contracts-5.5.0/proxy/utils/UUPSUpgradeable.sol:88 | Registry UPGRADE_ADMIN_ROLE | user-controlled; `function upgradeToAndCall(address newImplementation, bytes memory data) public payable virtual onlyProxy {` | ERC1967 implementation / migration → UUPS → new impl PM/factory comparison → ERC1967 upgrade | none; locker empty + onlyProxy; none |

## Initialization

| Component | One-time entry | Initialization state |
|---|---|---|
| TSVHookV1 | `function initialize(address poolManager_, address registry_, address ledger_, address router_, address lpManager_) external initializer` · src/v1/core/TSVHookV1.sol:69 | initializer；代理 storage 单次初始化；implementation constructor 锁定 |
| TSVRegistryV1 | `function initialize(address admin) external initializer` · src/v1/core/TSVRegistryV1.sol:220 | initializer；代理 storage 单次初始化；implementation constructor 锁定 |
| TSVVolumeLedgerV1 | `function initialize(address registry_) external initializer` · src/v1/core/TSVVolumeLedgerV1.sol:35 | initializer；代理 storage 单次初始化；implementation constructor 锁定 |
| TSVLPManagerV1 | `function initialize(ITSVPermissionedRegistry _registry) external initializer` · src/v1/periphery/TSVLPManagerV1.sol:115 | initializer；代理 storage 单次初始化；implementation constructor 锁定 |
| TSVSwapRouterV1 | `function initialize(address pm, address registry_) external initializer` · src/v1/periphery/TSVSwapRouterV1.sol:73 | initializer；代理 storage 单次初始化；implementation constructor 锁定 |

## Disabled ABI

| Entry | Actual behavior |
|---|---|
| LPManager.withdrawClaim · src/v1/periphery/TSVLPManagerV1.sol:216 | 全局 pause / locker 检查后始终 revert WithdrawClaimForbidden |
| LPManager.transferFrom · PermissionedPositionManager.sol:145 | PM locked 检查后始终 revert TransferDisabled |
| 两个 safeTransferFrom · PermissionedPositionManager.sol:149/153 | public pure，始终 revert TransferDisabled；按扫描定义不计可变入口 |
| Hook.beforeDonate / afterDonate · TSVHookV1.sol:239/251 | external pure，始终 revert UnsupportedCallback |
| 普通 LP MINT_6909 / UNWIND_WITH_FALLBACK / BURN_6909 actions | 非独立 ABI；普通 action dispatcher 拒绝 |

## Issuer auxiliary contracts

Factory/W 的入口独立于主场所计数，未自动获得 TSV 上市权限。

| Contract / function | Access | State / calls | Value |
|---|---|---|---|
| Factory.createPermissionsAdapter · :22 | permissionless；参数 user-controlled | deploy W → permissionsAdapterOf | none |
| Factory.verifyPermissionsAdapter · :35 | permissionless；已创建、未验证且 W 的 U 余额>0 | verified mapping → event | none |
| W.depositForVerification · :56 | permissionless | U.transferFrom caller→W；无 depositor ledger | in |
| W.wrapToPoolManager · :48 | allowedWrappers[msg.sender] | surplus check → mint W to PM | mint |
| W.updateAllowListChecker / updateAllowedWrapper / updateAllowedHook / updateSwappingEnabled · :62/67/72/77 | owner | issuer config → event；不检查 Registry pause | none |
| W.transferOwnership / acceptOwnership | Ownable2Step owner / pending owner | pendingOwner → owner | none |
| W.approve | ERC20 self approval，permissionless | allowances | none |
| W.transfer / transferFrom | ERC20 allowance + override from==PoolManager | W transfer → burn → U to recipient | out |
| W.renounceOwnership · :187 | pure disabled | always revert NotRenounceable | none |

W 无法在 PoolManager 之外保持非零持仓；其 ERC20 allowance 不构成股票 U 的 Core Router allowance。辅助入口定义见 `src/v1/vendor/permissionedPools/PermissionsAdapter*.sol` 及 remapping 所解析的 Ownable/ERC20。

## Read-only callback boundary

Hook beforeInitialize / beforeAddLiquidity / beforeRemoveLiquidity / beforeSwap 及各 afterLiquidity 等 view callbacks 仍执行有效权限/暂停/multiplier 门禁；按可变入口统计口径另行排除，完整业务效果见 [架构正文](contract-architecture.md)。
