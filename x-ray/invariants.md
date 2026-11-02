# Invariant Map
> TSV V1 · main@6743896 · 107 guards · 18 inferred · 2 On-chain=No blocks

所有性质限定于当前实现和正常初始化后的状态；任意新实现升级不属于证明范围。Guards 的多行源码仅折叠空白，不改动 token。历史文档声明仅作对照，未验证或已移除的声明不升级为当前性质。

## 1. Enforced Guards (Reference)

#### G-1
`if (permissionsAdapterFactory != address(0)) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:234` · Purpose: 保持场所依赖一次性绑定，防止既有池的回调和身份基础设施被改绑。

#### G-2
`if (poolManager.code.length == 0) revert InvalidConfig();` · `src/v1/core/TSVRegistryV1.sol:250` · Purpose: 保证绑定的 PoolManager 是可调用合约，保护后续场所结算依赖。

#### G-3
`if (participantSbt == address(0)) revert SbtNotConfigured();` · `src/v1/core/TSVRegistryV1.sol:275` · Purpose: 保证身份配置写入前已确定唯一 SBT 来源。

#### G-4
`if (participantSbt == address(0)) revert SbtNotConfigured();` · `src/v1/core/TSVRegistryV1.sol:296` · Purpose: 保证身份查询使用场所绑定的 SBT 来源。

#### G-5
`if (!sbtIdentityConfig[tokenId].registered) revert InvalidConfig();` · `src/v1/core/TSVRegistryV1.sol:297` · Purpose: 防止未纳入场所身份集合的 tokenId 被当成有效身份。

#### G-6
`if (participantSbt == address(0)) revert SbtNotConfigured();` · `src/v1/core/TSVRegistryV1.sol:305` · Purpose: 保持汇总身份查询与固定 SBT 依赖的一致性。

#### G-7
`if (participantSbt == address(0)) revert SbtNotConfigured();` · `src/v1/core/TSVRegistryV1.sol:313` · Purpose: 保持操作权限汇总与固定 SBT 依赖的一致性。

#### G-8
`if (tierId == 0 || maxListed < tier.listedCount) revert InvalidConfig();` · `src/v1/core/TSVRegistryV1.sol:340` · Purpose: 防止调低 tier 容量后当前上市证券数超出容量，并保留零 tier 为无效值。

#### G-9
`if (config.securityId == 0 || config.listed) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:358` · Purpose: 防止已上市或未创建证券重复取得上市容量。

#### G-10
`if (!config.listed || config.tierId == tierId) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:374` · Purpose: 防止无效 tier 迁移破坏上市计数。

#### G-11
`if (!config.listed || config.listedPoolCount != 0) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:388` · Purpose: 确保证券下市前所有关联池已退出非 DELIST 集合。

#### G-12
`if (!config.listed || config.tierId != tierId) { revert InvalidStatus(); }` · `src/v1/core/TSVRegistryV1.sol:424` · Purpose: 防止追加 W 时绕过既有证券上市状态或重设其 tier。

#### G-13
`if (quoteTokens[quote].registered) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:436` · Purpose: 避免覆盖仍生效的 Q 准入记录。

#### G-14
`if (!config.registered) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:452` · Purpose: 限制未来建池禁用操作作用于有效 Q 注册记录。

#### G-15
`if (!config.registered) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:466` · Purpose: 限制未来建池禁用操作作用于有效 U 注册记录。

#### G-16
`if (config.securityId == 0 || newAdapter == config.legalShareAdapter) revert InvalidConfig();` · `src/v1/core/TSVRegistryV1.sol:481` · Purpose: 防止对未知 U 或未变化的 converter 执行替换。

#### G-17
`if (msg.sender != lpManager) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:514` · Purpose: 将池注册限定于场所 LPManager 的原子初始化路径。

#### G-18
`if ( address(key.hooks) != hook || currency0 == address(0) || currency0 >= currency1 || key.fee >= 1_000_000 || key.tickSpacing < 1 || key.tickSpacing > 32767 || !_assetAllowed(currency0) || !_assetAllowed(currency1) ) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:517` · Purpose: 保证完整 PoolKey 使用本场所 Hook、有效静态 fee/tickSpacing 及允许建池的资产。

#### G-19
`if (!security.listed) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:527` · Purpose: 避免为已下市证券创建新的活跃池。

#### G-20
`if (isKnownPool(poolId)) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:530` · Purpose: 防止覆盖池的永久身份、注册快照和历史关联索引。

#### G-21
`if (!isKnownPool(poolId)) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:591` · Purpose: 避免为未知 poolId 创建伪造生命周期状态。

#### G-22
`if (!isKnownPool(poolId)) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:610` · Purpose: 保持批量生命周期更新仅作用于已注册池。

#### G-23
`if (msg.sender != lpManager) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:621` · Purpose: 将 NFT 数量计数更新限定于实际头寸管理组件。

#### G-24
`if (!isKnownPool(poolId)) revert InvalidPool();` · `src/v1/core/TSVRegistryV1.sol:624` · Purpose: 避免向未注册池写入 NFT 计数。

#### G-25
`if (delta > 0 && (pool.lifecycle == PoolLifecycle.DELIST || !securities[pool.securityId].listed)) { revert InvalidStatus(); }` · `src/v1/core/TSVRegistryV1.sol:625` · Purpose: 避免下市池或下市证券取得新的 NFT 头寸计数。

#### G-26
`if (securityId == 0 || !security.listed) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:645` · Purpose: 将证券操作暂停限定于已上市且可识别的证券。

#### G-27
`if (emergencyPauseEnable == enabled) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:658` · Purpose: 使全局暂停事件与真实 bool 状态变化一致。

#### G-28
`if (tier.listedCount >= tier.maxListed) revert InvalidConfig();` · `src/v1/core/TSVRegistryV1.sol:703` · Purpose: 防止新增上市证券超出当前 tier 配额。

#### G-29
`if (permissionsAdapterFactory == address(0)) revert PermissionedEnvironmentNotBound();` · `src/v1/core/TSVRegistryV1.sol:709` · Purpose: 避免资产准入使用尚未绑定的 Factory 来源。

#### G-30
`if (currencyUnderlying[currency] != address(0) || !securities[registerParam.securityId].listed) { revert InvalidPermissionedConfig(); }` · `src/v1/core/TSVRegistryV1.sol:725` · Purpose: 保持 W/U 首绑唯一并限制新增 W 归属已上市证券。

#### G-31
`if ( canonicalUnderlying.securityId != 0 && (canonicalUnderlying.securityId != registerParam.securityId || canonicalUnderlying.rawDecimals != rawDecimals || canonicalUnderlying.legalShareAdapter != registerParam.legalShareAdapter) ) { revert InvalidPermissionedConfig(); }` · `src/v1/core/TSVRegistryV1.sol:731` · Purpose: 保持同 U 的 security、decimals 和 converter canonical 记录一致。

#### G-32
`if (underlying == registerParam.legalShareAdapter || currency == registerParam.legalShareAdapter) { revert InvalidPermissionedConfig(); }` · `src/v1/core/TSVRegistryV1.sol:740` · Purpose: 避免资产地址与用于解释其法定份额的转换器地址重叠。

#### G-33
`if (lifecycle == PoolLifecycle.DELIST && pool.tickCount != 0) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:811` · Purpose: 保证池下市之前不存在未销毁的头寸 NFT 计数。

#### G-34
`if (lifecycle != PoolLifecycle.DELIST && !securities[securityId].listed) revert InvalidStatus();` · `src/v1/core/TSVRegistryV1.sol:814` · Purpose: 避免通过池生命周期恢复绕过证券上市状态。

#### G-35
`if (registry.isPaused()) revert InvalidOperation();` · `src/v1/core/TSVHookV1.sol:59` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-36
`if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();` · `src/v1/core/TSVHookV1.sol:60` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-37
`if (msg.sender != address(poolManager)) revert UnauthorizedCallback();` · `src/v1/core/TSVHookV1.sol:87` · Purpose: 保证 V4 回调来自固定 PoolManager。

#### G-38
`if ( sender != lpManager || address(key.hooks) != address(this) || registry.isPaused() || !registry.isKnownPool(PoolId.unwrap(key.toId())) ) revert InvalidPool();` · `src/v1/core/TSVHookV1.sol:103` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-39
`if (registry.isPaused() || !registry.isLPAllowed(poolId)) revert InvalidPool();` · `src/v1/core/TSVHookV1.sol:137` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-40
`if (registry.isPaused() || (!ITSVLPUnwindContext(lpManager).isUnwindActive() && !registry.isLPAllowed(poolId))) { revert InvalidPool(); }` · `src/v1/core/TSVHookV1.sol:171` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-41
`if (sender != router) revert UnauthorizedCallback();` · `src/v1/core/TSVHookV1.sol:208` · Purpose: 防止非固定 Router 通过该 Hook 交易。

#### G-42
`if (!registry.isTradable(PoolId.unwrap(key.toId())) || registry.isPaused()) revert InvalidOperation();` · `src/v1/core/TSVHookV1.sol:209` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-43
`if (sender != router) revert UnauthorizedCallback();` · `src/v1/core/TSVHookV1.sol:227` · Purpose: 保持记账回调与固定 Router 的交易来源一致。

#### G-44
`if (sender != lpManager) revert UnauthorizedCallback();` · `src/v1/core/TSVHookV1.sol:270` · Purpose: 防止非固定 LPManager 修改本场所池流动性。

#### G-45
`if (address(key.hooks) != address(this) || !registry.isKnownPool(poolId)) revert InvalidPool();` · `src/v1/core/TSVHookV1.sol:272` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-46
`if (adapter.code.length == 0) revert InvalidPool();` · `src/v1/core/TSVHookV1.sol:298` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-47
`if (currentMultiplier == 0 || currentMultiplier != expectedMultiplier) revert MultiplierChanged();` · `src/v1/core/TSVHookV1.sol:301` · Purpose: 保护 V4 回调来源、场所操作许可和同次交易的份额换算上下文。

#### G-48
`if (!registry.hasRole(VOLUME_ORACLE_ROLE, msg.sender)) revert Unauthorized();` · `src/v1/core/TSVVolumeLedgerV1.sol:42` · Purpose: 将日额度调整限定于明确授权的 volume oracle。

#### G-49
`if (msg.sender != registry.hook()) revert Unauthorized();` · `src/v1/core/TSVVolumeLedgerV1.sol:60` · Purpose: 将实际成交量累积限定于 Registry 当前 Hook。

#### G-50
`if (usedWad[securityId][ESTDay] > quota) revert QuotaExceeded(securityId, ESTDay);` · `src/v1/core/TSVVolumeLedgerV1.sol:71` · Purpose: 使本次成交追加后的使用量不突破执行时日额度。

#### G-51
`if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert Unauthorized();` · `src/v1/core/TSVVolumeLedgerV1.sol:76` · Purpose: 保护每日额度账本的可信写入来源及已提交的成交量边界。

#### G-52
`if (PERMISSIONS_ADAPTER_FACTORY.POOL_MANAGER() != pm) revert InvalidRequest();` · `src/v1/periphery/TSVSwapRouterV1.sol:65` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-53
`if (registry_.code.length == 0 || pm != address(poolManager)) { revert InvalidRequest(); }` · `src/v1/periphery/TSVSwapRouterV1.sol:74` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-54
`if (!registry.hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);` · `src/v1/periphery/TSVSwapRouterV1.sol:81` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-55
`if (registry.isPaused()) revert RegistryPaused();` · `src/v1/periphery/TSVSwapRouterV1.sol:86` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-56
`if (adapter == address(0) || (allowed && adapter.code.length == 0)) revert InvalidAdapter();` · `src/v1/periphery/TSVSwapRouterV1.sol:96` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-57
`if (currencyAddress != activeInputCurrency) revert SettlementMismatch();` · `src/v1/periphery/TSVSwapRouterV1.sol:143` · Purpose: 避免结算与本次预付输入 currency 不匹配。

#### G-58
`if (PERMISSIONS_ADAPTER_FACTORY.verifiedPermissionsAdapterOf(currencyAddress) != underlying) { revert InvalidAdapter(); }` · `src/v1/periphery/TSVSwapRouterV1.sol:149` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-59
`if (!permissionsAdapter.swappingEnabled()) revert SwappingDisabled();` · `src/v1/periphery/TSVSwapRouterV1.sol:153` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-60
`if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.SWAP_ALLOWED)) revert Unauthorized();` · `src/v1/periphery/TSVSwapRouterV1.sol:154` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-61
`if (activeAmountIn == 0 || amount == 0) revert SlippageExceeded();` · `src/v1/periphery/TSVSwapRouterV1.sol:177` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-62
`if (!isAdapterAllowed[msg.sender]) revert AdapterNotAllowed();` · `src/v1/periphery/TSVSwapRouterV1.sol:198` · Purpose: 将代参与者支付/执行交易能力限定于获准合约。

#### G-63
`if (address(request.key.hooks) != registry.hook()) revert InvalidPool();` · `src/v1/periphery/TSVSwapRouterV1.sol:201` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-64
`if (registry.getPoolLifeCycle(request.key) == PoolLifecycle.DELIST) revert PoolDelisted();` · `src/v1/periphery/TSVSwapRouterV1.sol:202` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-65
`if (!registry.isTradable(PoolId.unwrap(request.key.toId()))) revert PoolNotTradable();` · `src/v1/periphery/TSVSwapRouterV1.sol:203` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-66
`if (participant == address(0) || !registry.isSbtAllowed(PermissionFlags.SWAP_ALLOWED, participant)) { revert Unauthorized(); }` · `src/v1/periphery/TSVSwapRouterV1.sol:207` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-67
`if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();` · `src/v1/periphery/TSVSwapRouterV1.sol:258` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-68
`if (_getLocker() != address(0)) revert ContractLocked();` · `src/v1/periphery/TSVSwapRouterV1.sol:259` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-69
`if ( address(TSVSwapRouterV1(implementation).poolManager()) != address(poolManager) || address(TSVSwapRouterV1(implementation).PERMISSIONS_ADAPTER_FACTORY()) != address(PERMISSIONS_ADAPTER_FACTORY) ) revert InvalidRequest();` · `src/v1/periphery/TSVSwapRouterV1.sol:260` · Purpose: 保护交易主体、输入结算上下文和获准交易/升级调用边界。

#### G-70
`if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();` · `src/v1/periphery/TSVLPManagerV1.sol:310` · Purpose: 保护授权退出回调与代理升级调用边界。

#### G-71
`if (keccak256(data) != expected) revert Unauthorized();` · `src/v1/periphery/TSVLPManagerV1.sol:318` · Purpose: 将授权 unwind 回调限定于入口已承诺的精确 actions 与参数。

#### G-72
`if (!registry.hasRole(role, msg.sender)) revert AccessControlUnauthorizedAccount(msg.sender, role);` · `src/v1/libraries/TSVLPManagerLib.sol:72` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-73
`if (registry.isPaused()) revert RegistryPaused();` · `src/v1/libraries/TSVLPManagerLib.sol:76` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-74
`if (!permissionsAdapter.isAllowed(executor, PermissionFlags.LIQUIDITY_ALLOWED)) { revert Unauthorized(); }` · `src/v1/libraries/TSVLPManagerLib.sol:251` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-75
`require((owner = owners[tokenId]) != address(0), "NOT_MINTED");` · `src/v1/libraries/TSVLPManagerLib.sol:283` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-76
`if (!registry.isLPAllowed(PoolId.unwrap(poolKey.toId()))) revert PoolNotAllowed();` · `src/v1/libraries/TSVLPManagerLib.sol:287` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-77
`if (!registry.isSbtAllowed(PermissionFlags.LIQUIDITY_ALLOWED, account)) revert Unauthorized();` · `src/v1/libraries/TSVLPManagerLib.sol:324` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-78
`if (factory.permissionsAdapterOf(currencyAddress) != address(0)) { revert NoVerifiedAdapter(); }` · `src/v1/libraries/TSVLPManagerLib.sol:336` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-79
`if (!adapter.allowedHooks(hooks)) revert InvalidHook();` · `src/v1/libraries/TSVLPManagerLib.sol:344` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-80
`if (!adapter.isAllowed(owner, PermissionFlags.LIQUIDITY_ALLOWED)) revert Unauthorized();` · `src/v1/libraries/TSVLPManagerLib.sol:345` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-81
`if (_subscriber == NO_SUBSCRIBER) revert INotifier.NotSubscribed();` · `src/v1/libraries/TSVLPManagerLib.sol:358` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-82
`if (!registry.updatePoolTickCount(poolKey, delta)) revert PoolTickCountUpdateFailed();` · `src/v1/libraries/TSVLPManagerLib.sol:424` · Purpose: 保护 LP 参与者准入、发行方退出授权和头寸结算调用边界。

#### G-83
`if (!allowedWrappers[msg.sender]) revert UnauthorizedWrapper(msg.sender);` · `src/v1/vendor/permissionedPools/PermissionsAdapter.sol:49` · Purpose: 防止未获 issuer 授权的调用者使用 W 的 surplus 进行包装。

#### G-84
`assert(to == POOL_MANAGER);` · `src/v1/vendor/permissionedPools/PermissionsAdapter.sol:122` · Purpose: 确保新 W 只发行给 PoolManager。

#### G-85
`if (from != POOL_MANAGER) { // if the pool manager is the sender, the permissioned token is automatically released, skip the checks revert InvalidTransfer(from, to); }` · `src/v1/vendor/permissionedPools/PermissionsAdapter.sol:126` · Purpose: 禁止 PoolManager 以外的地址转出持有 W。

#### G-86
`if (to == POOL_MANAGER) revert InvalidTransfer(from, to);` · `src/v1/vendor/permissionedPools/PermissionsAdapter.sol:131` · Purpose: 避免自转账自动解包把 U 错误交回 PoolManager。

#### G-87
`assert(balanceOf(POOL_MANAGER) == totalSupply());` · `src/v1/vendor/permissionedPools/PermissionsAdapter.sol:135` · Purpose: 维持完成解包后 PoolManager 是 W 的唯一持有者。

#### G-88
`if (address(permissionedToken) == address(0)) revert PermissionsAdapterNotFound(permissionsAdapter);` · `src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol:37` · Purpose: 保护 Factory 创建记录与一次性验证记录的一致性。

#### G-89
`if (verifiedPermissionsAdapterOf[permissionsAdapter] != address(0)) { revert PermissionsAdapterAlreadyVerified(permissionsAdapter); }` · `src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol:38` · Purpose: 保护 Factory 创建记录与一次性验证记录的一致性。

#### G-90
`if (permissionedToken.balanceOf(permissionsAdapter) == 0) { revert PermissionsAdapterNotVerified(permissionsAdapter); }` · `src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol:42` · Purpose: 保护 Factory 创建记录与一次性验证记录的一致性。

#### G-91
`if (!_isApprovedOrOwner(caller, tokenId)) revert NotApproved(caller);` · `src/v1/vendor/permissionedPools/PositionManager.sol:159` · Purpose: 保护 NFT 操作授权和 PoolManager 的锁定上下文。

#### G-92
`if (poolManager.isUnlocked()) revert PoolManagerMustBeLocked();` · `src/v1/vendor/permissionedPools/PositionManager.sol:165` · Purpose: 保护 NFT 操作授权和 PoolManager 的锁定上下文。

#### G-93
`if (PERMISSIONS_ADAPTER_FACTORY.permissionsAdapterOf(currencyAddress) != address(0)) { revert NoVerifiedAdapter(); }` · `src/v1/vendor/permissionedPools/PermissionedPositionManager.sol:221` · Purpose: 保护发行方权限、Hook 准入及 claim 所有权边界；TSV 覆盖入口另见架构。

#### G-94
`if (!adapter.allowedHooks(hooks)) revert InvalidHook();` · `src/v1/vendor/permissionedPools/PermissionedPositionManager.sol:229` · Purpose: 保护发行方权限、Hook 准入及 claim 所有权边界；TSV 覆盖入口另见架构。

#### G-95
`if (!adapter.isAllowed(owner, PermissionFlags.LIQUIDITY_ALLOWED)) revert Unauthorized();` · `src/v1/vendor/permissionedPools/PermissionedPositionManager.sol:230` · Purpose: 保护发行方权限、Hook 准入及 claim 所有权边界；TSV 覆盖入口另见架构。

#### G-96
`if (!permissionsAdapter.isAllowed(msgSender(), PermissionFlags.LIQUIDITY_ALLOWED)) { revert Unauthorized(); }` · `src/v1/vendor/permissionedPools/PermissionedPositionManager.sol:245` · Purpose: 保护发行方权限、Hook 准入及 claim 所有权边界；TSV 覆盖入口另见架构。

#### G-97
`if (msg.sender != owner && !isApprovedForAll[owner][msg.sender]) revert Unauthorized();` · `src/v1/vendor/permissionedPools/base/ERC721Permit_v4.sol:87` · Purpose: 保护 NFT 所有者及操作授权，避免未经授权更改 token approval。

#### G-98
`if (_subscriber != NO_SUBSCRIBER) revert AlreadySubscribed(tokenId, address(_subscriber));` · `src/v1/vendor/permissionedPools/base/Notifier.sol:52` · Purpose: 保护 NFT subscriber 状态和 PoolManager 锁定时的通知边界。

#### G-99
`if (_subscriber == NO_SUBSCRIBER) revert NotSubscribed();` · `src/v1/vendor/permissionedPools/base/Notifier.sol:80` · Purpose: 保护 NFT subscriber 状态和 PoolManager 锁定时的通知边界。

#### G-100
`if (adapter.code.length == 0) revert InvalidConfig();` · `src/v1/libraries/PermissionedValidationLib.sol:63` · Purpose: 保护被注册资产的组件隔离、Factory 来源与转换器绑定。

#### G-101
`if (!ok || supported != 1 || _readAddress(adapter, IDirectLegalShareAdapter.poolCurrency.selector) != currency) { revert InvalidConfig(); }` · `src/v1/libraries/PermissionedValidationLib.sol:71` · Purpose: 保护被注册资产的组件隔离、Factory 来源与转换器绑定。

#### G-102
`if ( u == address(0) || _readAddressArgument( r.permissionsAdapterFactory(), IPermissionsAdapterFactory.verifiedPermissionsAdapterOf.selector, w ) != u ) revert UnverifiedPermissionedAdapter(w);` · `src/v1/libraries/PermissionedValidationLib.sol:117` · Purpose: 保护被注册资产的组件隔离、Factory 来源与转换器绑定。

#### G-103
`if ( w.code.length == 0 || _readAddress(w, IPermissionsAdapter.POOL_MANAGER.selector) != r.permissionedPoolManager() || _readAddress(w, IPermissionsAdapter.PERMISSIONED_TOKEN.selector) != u ) revert InvalidPermissionedConfig();` · `src/v1/libraries/PermissionedValidationLib.sol:125` · Purpose: 保护被注册资产的组件隔离、Factory 来源与转换器绑定。

#### G-104
`if ( u.code.length == 0 || w == u || _isSystem(w) || _isSystem(u) || r.getQuoteToken(w).registered || r.getQuoteToken(u).registered || r.getUnderlying(w).securityId != 0 || r.getCurrencyUnderlying(u) != address(0) || _readAddressArgument( r.permissionsAdapterFactory(), IPermissionsAdapterFactory.permissionsAdapterOf.selector, u ) != address(0) ) revert InvalidPermissionedConfig();` · `src/v1/libraries/PermissionedValidationLib.sol:147` · Purpose: 保护被注册资产的组件隔离、Factory 来源与转换器绑定。

#### G-105
`if ( quote.code.length == 0 || _isSystem(quote) || r.getCurrencyUnderlying(quote) != address(0) || r.getUnderlying(quote).securityId != 0 || _readAddressArgument( r.permissionsAdapterFactory(), IPermissionsAdapterFactory.permissionsAdapterOf.selector, quote ) != address(0) ) revert UnsupportedAsset(quote);` · `src/v1/libraries/PermissionedValidationLib.sol:173` · Purpose: 保护被注册资产的组件隔离、Factory 来源与转换器绑定。

#### G-106
`if (currency != poolCurrency) revert InvalidCurrency();` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol:51` · Purpose: 保护固定底层资产的法定份额转换身份。

#### G-107
`if (!hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();` · `src/v1/governance/TSVGoverned.sol:41` · Purpose: 保护 Registry 的升级授权边界。

## 2. Inferred Invariants (Single-Contract)

#### I-1

`Bound` · On-chain: **No**

> 对任意已配置日，usedWad[securityId][ESTDay] 始终不大于当前 Quota。

**Derivation** — guard-lift: `if (usedWad[securityId][ESTDay] > quota) revert QuotaExceeded(securityId, ESTDay);`；usedWad 唯一写入 src/v1/core/TSVVolumeLedgerV1.sol:70，Quota 唯一写入 :45。setQuota:41–47 不要求新值≥used，故全局属性未强制；成功 recordSwap 的单次检查仍有效。

**If violated** — 额度下调后 getter 可显示 used > quota；后续正量成交会回退。

#### I-2

`Bound` · On-chain: **Yes**

> 每个 tier 的 listedCount ≤ maxListed；可成功取得 listing slot 的 tier 非零。

**Derivation** — guard-lift: `if (tierId == 0 || maxListed < tier.listedCount) revert InvalidConfig();` 与 `if (tier.listedCount >= tier.maxListed) revert InvalidConfig();`；maxListed 唯一写点 :341；listedCount +1 唯一写点 :704，减量写点 :376/:390；tier0 无配置入口，默认容量为零。

**If violated** — 证券上市数不能与 tier 容量解释保持一致。

#### I-3

`StateMachine` · On-chain: **Yes**

> Registry 的 hook/lpManager/factory/poolManager/SBT 组件集合在当前实现绑定后不再改绑。

**Derivation** — edge: permissionsAdapterFactory==0@src/v1/core/TSVRegistryV1.sol:234 → nonzero@253；其余同次地址赋值 :251–255；没有反向或第二赋值入口。

**If violated** — 固定回调、身份与资产来源关系发生迁移。

#### I-4

`StateMachine` · On-chain: **Yes**

> 每个已注册 W 始终映射到首次准入的非零 U。

**Derivation** — edge: currencyUnderlying[currency]==0@src/v1/core/TSVRegistryV1.sol:725 → underlying@752；唯写点 :752；来源非零校验 PermissionedValidationLib.sol:112–129。

**If violated** — 同一 PoolKey 的资产身份会变化。

#### I-5

`StateMachine` · On-chain: **Yes**

> U 初始 canonical securityId 与 rawDecimals 不被后续注册、禁用或 converter 替换改变。

**Derivation** — edge: canonicalUnderlying.securityId==0@src/v1/core/TSVRegistryV1.sol:743 → record@744–745；已有记录一致性守卫 :731–738；其他 field writes 为 registered:467/:750 与 converter:484。

**If violated** — 共享同证券计量和 raw 单位的解释不再固定。

#### I-6

`StateMachine` · On-chain: **Yes**

> 已注册池的 PoolKey、securityId、tier 注册快照、poolSecurityIndex 和历史 poolIds 关联保持固定。

**Derivation** — edge: !isKnownPool@src/v1/core/TSVRegistryV1.sol:530 → stored record@532，先 append@531；记录仅此初始写点；后续只写 lifecycle:820、tickCount:840，无删除入口。

**If violated** — 旧 poolId 和历史证券归属不能一致解释。

#### I-7

`Bound` · On-chain: **Yes**

> 生命周期为 DELIST 的已注册池始终保持 tickCount==0，且 tickCount 不会下溢。

**Derivation** — guard-lift: `if (lifecycle == PoolLifecycle.DELIST && pool.tickCount != 0) revert InvalidStatus();`；初始 tickCount=0@532；唯一后续写 :840；负量 guard:837，正量 gate:625–627 排除 DELIST；lifecycle 唯写点 :532/:820。

**If violated** — 下市时仍存在未清理的 NFT 头寸计数。

#### I-8

`StateMachine` · On-chain: **Yes**

> 已配置 SBT tokenId 的 registered 保持 true，identityTokenIds 只追加一次。

**Derivation** — edge: !sbtIdentityConfig[tokenId].registered@src/v1/core/TSVRegistryV1.sol:280 → registered=true@281；只有此 config 写点，无删除/取消 registered 入口。

**If violated** — 身份枚举与配置记录发生分离。

#### I-9

`StateMachine` · On-chain: **Yes**

> Factory 对已创建 W 的 verified mapping 只可由零变为其创建记录的 U 一次。

**Derivation** — edge: verified==0@src/v1/vendor/permissionedPools/PermissionsAdapterFactory.sol:38–40 → permissionsAdapterOf 的 U@45；创建记录唯写点 :30；验证唯写点 :45；创建记录非零和正余额 guard:37/:42–44。

**If violated** — W 的来源映射不能持续证明初次资产关系。

#### I-10

`Conservation` · On-chain: **Yes**

> 每次完成的 W 操作后，W.balanceOf(PoolManager)==W.totalSupply；其他地址不保留 W。

**Derivation** — NatSpec: src/v1/vendor/permissionedPools/PermissionsAdapter.sol:114 — “Enforces that the pool manager is the only holder of the permissions adapter”；mint 唯入口 :48–52；_update mint断言 :122；转出 :132 → unwrap/burn :133/:139 → assert :135。仅断言完成操作后的状态；U 外部行为不在此断言内。

**If violated** — 池内 W 持有模型与自动解包语义不一致。

#### I-11

`Conservation` · On-chain: **Yes**

> Security.listedPoolCount 等于该证券历史池列表中 lifecycle 非 DELIST 的池数。

**Derivation** — NatSpec: src/v1/types/TSVTypes.sol:72 — “Number of associated pools whose lifecycle is not DELIST.”；初始 LIST record@src/v1/core/TSVRegistryV1.sol:532 + counter@533；变更跨 DELIST 时 counter±1@816/818、lifecycle@820；相同状态早退@813；无其他写点。

**If violated** — 证券下市前置条件不能反映池状态。

#### I-12

`Bound` · On-chain: **Yes**

> 每次写入 canonical U 或 Q 注册记录时，rawDecimals≤18；U 首绑的 W/U decimals 相等。

**Derivation** — guard-lift: `if (decimals > 18) revert PermissionedMetadataMismatch();`@PermissionedValidationLib.sol:163；U rawDecimals 唯写点 src/v1/core/TSVRegistryV1.sol:744–745，先 stockDecimals@729；Q 唯写点 :439，先 readDecimals@438；W/U equality guard library:168。这是注册快照，不保证外部 token 后续不变。

**If violated** — 份额换算的已存储 raw 单位失去准入保证。

#### I-13

`StateMachine` · On-chain: **Yes**

> LP NFT signature nonce 的每一位在成功消费后不能恢复为未使用。

**Derivation** — edge: nonce bit unused → set@src/v1/vendor/permissionedPools/base/UnorderedNonce.sol:19–25；使用 xor 后为零则回退，回滚原值；唯一写点 :23，revokeNonce 复用同一 helper@29。

**If violated** — 同一 NFT 签名授权可以再次使用。

## 3. Inferred Invariants (Cross-Contract)

#### X-1

On-chain: **Yes**

> 一次经当前 Hook 完成的 swap 只把实际 stock leg 的法定份额记入该池所属证券的当日 usedWad。

**Caller side** — src/v1/core/TSVHookV1.sol:220–232，读取两边实际 delta 并经 Registry W→U→converter 计算 shares，只调用一次 recordSwap。

**Callee side** — src/v1/core/TSVVolumeLedgerV1.sol:60–71 固定 Hook 校验、恰好一边正份额、读 PoolRecord.securityId，唯一 used 写点 :70；池归属初始写点 src/v1/core/TSVRegistryV1.sol:532。

**If violated** — 实际成交与证券日累计量关联不一致。

#### X-2

On-chain: **Yes**

> LP mint/burn NFT 成功后，该池 Registry.tickCount 与当前 LPManager 的该池 NFT 数同步。

**Caller side** — src/v1/periphery/TSVLPManagerV1.sol:363–370 普通 mint+1、burn−1；授权 burn:332–334 同步−1；增加/减少流动性不改数量。

**Callee side** — src/v1/core/TSVRegistryV1.sol:532 初始计数0；only lpManager@621，checked delta@625–628/828–840 为唯一后续写点；本地 PositionManager.sol:371–384 mint 和 :433–435 burn 提供 NFT 写点。

**If violated** — 池清退资格与实际 NFT 存续数量不一致。

#### X-3

On-chain: **Yes**

> Hook 后续读取当前 canonical U converter；更换 converter 不重写历史 usedWad。

**Caller side** — src/v1/core/TSVHookV1.sol:296–301 / 309–315 每次读取 Registry.getUnderlying(U).legalShareAdapter。

**Callee side** — src/v1/core/TSVRegistryV1.sol:484 唯一替换写点，准入验证 :482；初始 record :744–745；src/v1/core/TSVVolumeLedgerV1.sol:70 唯一 used 增量写点，quota setter:45 不写 used。

**If violated** — 后续成交换算与历史用量的分界不确定。

#### X-4

On-chain: **Yes**

> 全局 emergency pause 生效时，Hook 的普通交易/LP 及 LPManager 授权 unwind 均无法成功继续。

**Caller side** — src/v1/core/TSVHookV1.sol:137/171/209；src/v1/periphery/TSVLPManagerV1.sol:140–171 和 LP 库 requireRegistryNotPaused:75–77 对当前状态设门禁。

**Callee side** — src/v1/core/TSVRegistryV1.sol:660 是 emergencyPauseEnable 唯一更新，getter:797–798 返回该值；不包含 SBT paused。

**If violated** — 全局暂停对这些业务入口的含义不能一致解释。

## 4. Economic Invariants

#### E-1

On-chain: **No**

> 同证券所有池的累计法定份额成交量，在任意配置变更后仍低于当前该证券的日额度。

**Follows from** — [I-1](#i-1) + [X-1](#x-1)：共享 security/day 汇总由 X-1 强制，但 setQuota 可下调到已用量以下，因此全局额度性质未强制；每次新成交仍按当时 quota 检查。

**If violated** — 配额重新配置后，当前额度与此前成功交易累计量可能不满足同一个上限关系。
