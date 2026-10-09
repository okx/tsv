# Permissioned Registry 与 Wrapped Swap 实现（2026-10-07）

依据：[Wrapped Swap 编码前详细设计 v2](https://okg-block.sg.larksuite.com/docx/HZHpdOzm3obeEhxXWKRlBNUmgNb)。当前交付 Registry、Hook/Ledger 配置读取、共同接口及单池 Wrapped Swap。生产 Wrapped LP、真实发行方与目标链验收仍待后续交付。旧文档中的 DIRECT 股票、TokenConfig/getToken 和旧成功路径不适用于本批制品。

## 数据与接口

- `currencies[W]` 保存永久 U 和 expectedOwner；`getCurrency(W)` 返回该记录。
- `underlyings[U]` 唯一保存 securityId、rawDecimals、legalShareAdapter；`getUnderlying(U)` 返回该记录。同 U 的全部 W 共享此口径及 securityId 的 Ledger 额度。
- `quoteTokens[Q]` 独立保存原币报价的精度和 registered 标记；`getQuoteToken(Q)` 返回该记录。0 decimals 合法，存在性按 registered 判断。
- 新证券使用 `admitPermissionedSecurity(tierId, admission)`；已有证券添加 W 使用 `registerPermissionedCurrency(admission)`。U 和精度从真实合约派生，admission 仅含 W/securityId/expectedOwner/legalShareAdapter。
- 报价币使用 `registerQuoteToken(Q)`。股票、underlying、报价和系统地址不得混用；Pool 只登记 W/Q。
- W/Q 准入记录永久保留，停用与恢复使用 TOKEN 暂停；单池使用 POOL 暂停。清除 TOKEN 暂停前复核已登记 W/Q 的身份、精度和授权，失败时暂停记录及计数不变。首次 W 准入要求 supply、PM W 余额及累计 W 费用为零，恢复不重复首次库存检查。PM 的既有 U 余额不影响准入。
- owner 批准由 Governor 控制；expectedOwner 轮换由 SYMBOL_ADMIN 执行，要求 TOKEN、SECURITY、GLOBAL 或市场暂停共同覆盖该 W 的交易和 LP 暂停、新 owner 已实际接受 ownership、获批准且与 exitAdmin 分离。
- exitAdmin 按 U 共享，Governor 直接调用 `setExitAdmin(U, admin)`，可在首次 W 准入前配置。是否配置直接按接收地址判断。更新检查该 U 下所有已登记 W 的 expectedOwner 和当前 owner，接收方须与这些 owner 分离。它不接收本期 Swap 输出，也不授予 owner 或执行角色。
- `replaceUnderlyingLegalShareAdapter(U, newAdapter)` 要求证券范围同时覆盖交易和 LP 暂停；单 W 的 TOKEN 暂停不足。更新立即影响该 U 的所有 W，不清 Ledger。

资产、报价币、证券、池、exitAdmin 和股数 Adapter 均无配置版本计数。Adapter 准入只核验接口及 U 绑定；`SwapAccounted` 不携带 Adapter 版本。ADTV、Quota 和 SplitFactor 报告保留 `version`，用于拒绝过期或乱序更正。

## 统一运营门禁

2026-10-08 运营状态简化回归：完整本地 **48 个 suite、318 项通过，0 失败、0 跳过**；其中真实 PM Wrapped Swap 33 项、DexAdapter 11 项。新增初始化失败回滚/重试、未注册池初始化拒绝、下架/重新上市历史池交易，以及 TOKEN 恢复失败保留暂停和配置修正后恢复的覆盖。日志：`out/tsv-router-lock.vhL8kj/state-removal-full-tests.log`。生产构建、`make check`、ABI/存储布局及制品源码哈希核验通过。

W 以非零 underlying 判断准入；Q 以 registered 判断准入；Pool 以保存的非零 currency0 判断登记。证券上市标志与 TRADE/LP 暂停共同决定普通操作资格。SYMBOL_ADMIN 负责准入及上下架，EMERGENCY_PAUSER/RESUMER 负责停用及恢复。

建池入口为 LP Manager 的 `initializePool(key,sqrtPriceX96)`，调用者须持有 LP Manager 上的 `POOL_CREATOR_ROLE`。入口依次执行 `Registry.registerPool(key)` 和 `PM.initialize(key,sqrtPriceX96)`，任一步失败都会回滚整笔交易，不使用上游捕获失败并返回最大 tick 的行为；Hook 核验 LP Manager sender 和已登记的完整 PoolKey。初始化仅创建池并设置初始价格，随后通过 `MINT_POSITION` 创建仓位和注资，也可将两步放入 LP Manager 的 `multicall`。没有初始化中间状态、额外激活调用、独立资产/池启停入口或活跃池计数。历史 PoolKey、资产配置、额度和仓位仍保留，强退依据登记事实及原有授权执行。

LP 用户付款采用与 DexRouter legacy 模式一致的统一授权链路：用户 approve `TokenApproveProxy.tokenApprove()` 返回的 TokenApprove，LP Manager 调用 `TokenApproveProxy.claimTokens(token,payer,destination,amount)`，由 TokenApprove 划转。实现合约构造参数新增 `_tokenApproveProxy`，固定为 `TOKEN_APPROVE_PROXY`；TokenApproveProxy 管理员须将实际 LP 代理地址加入允许调用的名单，不能只授权实现合约。底层资产 U 划转到 PermissionsAdapter 后 wrap，报价币 Q 划转到 PoolManager；两者都不要求用户授权 LP Manager 或 Permit2。LP Manager 自持资金仍直接支付。现有构造参数中的 Permit2 保留用于上游继承接口，但这两类用户付款不再通过它执行。

普通 LP 操作统一在 `_handleAction` 执行 Registry 门禁：`MINT_POSITION`、`MINT_POSITION_FROM_DELTAS`、`INCREASE_LIQUIDITY`、`INCREASE_LIQUIDITY_FROM_DELTAS`、`DECREASE_LIQUIDITY` 和 `BURN_POSITION` 同时要求 `Registry.isAllowed(LIQUIDITY_ALLOWED,msgSender())` 与 `Registry.isAllowed(LIQUIDITY_ALLOWED,owner)`。Mint 的 owner 从 action 参数解析并处理接收者占位地址；已有仓位使用 `ownerOf(tokenId)`。调用者和 owner 都必须持有具有 LP 权限的已登记 SBT，且 SBT 未暂停；零流动性领费也受同一门禁。两个批量入口共用检查，原有 NFT 授权及 Adapter/hook 检查继续执行。已授权 adapter owner 的 `unwindPosition` 可以在调用者或仓位 owner 无 SBT 时强制退出，临时豁免仅允许本次指定 tokenId 的 `BURN_POSITION`、其 `MINT_6909` 结算和 `UNWIND_WITH_FALLBACK` 交付，全部交付尝试结束后立即清除；其他 action 在强退上下文中禁止执行。实现使用一个原有预留存储槽，`__gap` 从 49 减为 48。

普通资金 actions 同样在 `_handleAction` 检查调用者的 Registry `LIQUIDITY_ALLOWED`：包括 SETTLE/SETTLE_PAIR、TAKE/TAKE_PAIR、CLOSE_CURRENCY、CLEAR_OR_TAKE、SWEEP、WRAP/UNWRAP 及 claim actions。TAKE、TAKE_PAIR、SWEEP 额外检查 `_mapRecipient` 解析后的收款人；CLOSE_CURRENCY 和 CLEAR_OR_TAKE 的收款人为已检查的调用者。接收者占位地址 `MSG_SENDER` 和 `ADDRESS_THIS` 先解析后校验，LP 合约地址没有隐含的 SBT 豁免。`withdrawClaim` 内部 BURN_6909/TAKE 共用此门禁，调用者和收款人都须具备 LP 权限，失败时 claim burn 与转账整体回滚。普通调用不能使用强退专用 `UNWIND_WITH_FALLBACK`。

## Factory 与 checker

Registry 代理 R 保存 TSV 身份、资产与市场配置，不实现 `IPermissionsAdapterFactory` 或 `IAllowlistChecker`。Router 构造参数为 `(PM,F)`，`PERMISSIONS_ADAPTER_FACTORY()` 与 R 的 `permissionsAdapterFactory()` 均为真实 Factory F。

Governor 一次调用 `bindComponents(Hook, LPManager, DataInbox, F, SBT)`，绑定 Registry 自身需要的五个依赖，PM 从 F 读取；没有独立的 `bindPermissionedComponents`。入口只检查地址有代码、PM 有代码和 SBT ABI 可读，原子写入配置并发出唯一 `ComponentsBound(hook,lpManager,dataInbox,factory,poolManager,sbt)` 事件。Registry 不重复保存 Router；W 准入时直接从 `Hook.router()` 读取 wrapper 授权对象。各组件 PM/Registry、Hook Router/LPManager、Router Factory 和 Anchor 交叉引用由只读 `VerifyDeploymentV1` 在部署后核验。未绑定时 TSV 资产准入和建池拒绝。

创建、验证 W 直接调用真实 F，均保持上游 permissionless 行为；创建成功或 Factory 验证成功不等于 TSV 已准入。`allowListChecker` 由股票发行方开发、部署并配置，表达发行方的权限规则；Registry 准入检查其代码和 `IAllowlistChecker` 接口，不要求地址为 R。

统一 SBT 入口 `R.isAllowed(permission, user)` 检查 TSV 对应操作权限；permission 只接受 SWAP_ALLOWED 或 LIQUIDITY_ALLOWED。发行方权限通过 `W.isAllowed(user, permission)` 独立检查：Router 复用 PermissionedV4Router 的 swap 门禁，LPManager 查询 W 的 LP 门禁。两层检查均须通过，SDK 应分别查询；Registry 不调用发行方 checker。

## SBT 身份与操作权限

Governor 按 tokenId 独立登记或更新身份权限，所有身份使用 `bindComponents` 一次绑定的同一个 SBT 合约：

```solidity
registry.setSbtConfig(retailTokenId, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED);
registry.setSbtConfig(marketmakerTokenId, PermissionFlags.SWAP_ALLOWED | PermissionFlags.LIQUIDITY_ALLOWED);
// 同一 tokenId 可再次更新权限；持有该身份的地址立即使用最新配置。
registry.setSbtConfig(retailTokenId, PermissionFlags.SWAP_ALLOWED);
```

绑定时探测 SBT 的 `paused()` 和 `verify(address(this),0)` ABI；暂停状态不阻止绑定。绑定完成但尚未登记任何身份时，持有查询为 false、操作权限为 NONE。`setSbtConfig` 校验实际 tokenId 的 `verify` 读取，并可在 SBT 暂停时更新权限。

`setSbtConfig(uint256,PermissionFlag)` 复用上游 `PermissionFlags`：`SWAP_ALLOWED`、`LIQUIDITY_ALLOWED` 及其按位并集。允许 `NONE`；该 ID 仍是已登记身份。拒绝其他权限位。`sbtIdentityConfig(tokenId)` 返回 registered/permissions，`sbtTokenIds()` 枚举全部已登记 ID，重复更新不重复登记。tokenId=0 合法。

`hasIdentity(owner,tokenId)` 查询单个已登记身份；`hasCredential(owner)` 读取全部已登记 ID，只要持有任一身份就返回 true。这两项忽略暂停和操作权限；未登记 ID 的单身份查询回滚。`permissionsOf(owner)` 返回未暂停时的权限并集；Router 与普通 LP 使用统一 `isAllowed(permission, account)` 检查 SBT 权限，并在各自路径独立检查发行方权限；不再提供两个操作资格接口。有效身份读取异常回滚，不能视为撤证。

撤销执行者仅在全部已登记身份都不持有时可强退；持有 swap-only 或两项权限关闭的身份仍阻止撤销强退。SBT 暂停不等于撤证；管理员强退维持独立授权，资产仍返还原 owner。上述 LP 权限行为不代表生产 Wrapped LP 已交付。

部署 manifest 对两个初始身份分别记录 tokenId 和权限位：`TSV_RETAIL_SBT_TOKEN_ID`/`TSV_MARKETMAKER_SBT_TOKEN_ID`、`TSV_RETAIL_SBT_PERMISSIONS`/`TSV_MARKETMAKER_SBT_PERMISSIONS`。权限位为 swap=1、LP=2，当前两身份均为 3。旧单 ID 和含 SBT 地址的权限配置 ABI 不再使用；链上新参数的 ABI 类型为 `bytes2`。本批采用全新存储布局，删除旧单 ID 占位字段；首次部署后的升级仍须保留已部署布局。

## Registry 准入校验库

单合约版本在既定 Solidity 0.8.26 / Cancun / viaIR / optimizer 200 下超过 EIP-170 限制。经确认抽出 `PermissionedValidationLib`，未改变编译基准。

`PermissionedValidationLib` 只承载 Registry 的资产准入校验，包括 Factory/W 身份、元数据、法律股数接口、owner/wrapper/Hook/exitAdmin 和首次库存。库通过 delegatecall 执行，`address(this)` 为 Registry 代理；Registry 保留映射、角色、状态写入、事件和 SBT 身份权限。已移除 `_environment()` 地址打包及 `Environment` 结构；库读取 Registry 的现有 getter，绑定入口仅保留依赖地址、F 的 PM 和 SBT ABI 检查，已删除 `validateEnvironment` 及组件交叉引用检查。共享 exitAdmin 校验读取 Registry 的 U→W 索引，不增加库自身存储。

Router 不再链接该库，也不再生成或比较运行时策略快照。执行时的 Hook、swappingEnabled 和用户权限检查复用 `PermissionedV4Router`；精确转账与库存检查保留在内部 `TSVPermissionedSettlementLib`。Registry 的 `permissionedValidationLibrary()` 返回实际链接地址，更换须随实现升级交付。

部署前先部署并核验库，将链接地址提供给 Forge：

```sh
forge build --libraries "src/v1/libraries/PermissionedValidationLib.sol:PermissionedValidationLib:$TSV_PERMISSIONED_VALIDATION_LIBRARY"
forge script script/DeployCoreV1.s.sol:DeployCoreV1 --libraries "src/v1/libraries/PermissionedValidationLib.sol:PermissionedValidationLib:$TSV_PERMISSIONED_VALIDATION_LIBRARY" --rpc-url "$TSV_RPC_URL"
```

上述 script 命令为模拟，广播仍按发布审批执行。真实原版 PermissionsAdapterFactory 独立部署并绑定同一个 PM，不能传 R 充当 F。部署验证读取 `TSV_PERMISSIONS_ADAPTER_FACTORY` 与 `TSV_PERMISSIONED_VALIDATION_LIBRARY`，核对代码存在、Registry 实际绑定，以及 Registry 实现的库链接值与 manifest 一致。manifest 记录库地址、固定上游 commit、scoped OZ 5.0.2、TSV OZ 5.5.0 和 Registry 新 layout。没有旧状态迁移。

## Wrapped Swap 行为与接口

`TSVSwapRouterV1` 继承本地兼容版 `PermissionedV4Router` 与既有治理父类。实现构造参数为 `(PoolManager, PermissionsAdapterFactory)`，两者固定在实现字节码中，构造时核验 F 的 PM；`initialize(anchor, pm, registry)` 验证 PM 与 Registry 的 Anchor。Router 不保存 Ledger、不读取交易日、不另发成交事件，额度记账与 `SwapAccounted` 由 Hook/Ledger 完成。升级候选必须保留相同 PM/F，并延续本批新存储布局。

`swapExactInput(request)`、`swapExactOutput(request)` 与白名单入口 `swapExactInputFromAdapter(request, participant)` 可执行交易。`SwapRequest` 字段仍为 `(key, zeroForOne, amountSpecified, limitAmount, deadline)`，key 中股票地址是 W、报价地址是 Q；amountSpecified/limitAmount 使用对应腿的 raw 单位。用户直接调用并授权 Router 支出 U 或 Q，股票输出直接交付 U。支持 U→Q、Q→U 各自 exact-in/exact-out 四条路径。

- Router 固定构造单池 SWAP、SETTLE_ALL、TAKE_ALL 三个动作，hookData 为空；没有公开 action dispatcher、多跳、native 或库存兜底。
- `msgSender()` 从入口首次资格读取开始返回真实用户，空闲时依据 V4 锁返回零。真实用户、实际输入和实际输出每次交易重新赋值，不再使用 `_clearContext` 或结束时 delete。回调直接复用 V4 `SafeCallback` 的 onlyPoolManager 门禁；固定的真实 PM 将 unlock 数据原样回调一次，不再保存 payload 哈希或消费标记。
- Router 复用 V4 Periphery 的 `ReentrancyLock`，通过 EIP-1153 临时存储保存发起者地址作为锁；交易入口和交易期间的升级尝试以 `ContractLocked()` 拒绝重入。目标链须支持 EIP-1153，运行时检查统一读取临时锁。
- 股票输入：精确检查付款方 U 减少与 W 合约 U 增加，再由原版 W mint 相同数量到 PM。仅一次 PM sync/pay/settle；债务结清由 PM.unlock 自身保证，不再额外比较 settle 返回值。
- 股票输出：PM take 原版 W，自动 burn/unwrap 并发送 U 给结算方；只检查 W 持有的 U 减少和结算方 U 增加。Q 输出使用相同的双侧检查，发送方为 PM。实际输入在 SETTLE_ALL 中记录，实际输出在 TAKE_ALL 中记录，无需预存输出币种或重复比较 credit。
- 原版 W 自身保证 PM W = W totalSupply、其他地址不持有 W，Router 不再重复读取这些 W 余额。保留整笔交易的一组库存检查：collateral ≥ supply；PM/Router 可以已有 U，但对应 U 余额必须保持不变；验证保证金余量 E = collateral − supply 保持不变。入金和出金不再各自重复读取整套库存。
- exact-in 按真实成交量支付，可部分成交，须满足最小输出；exact-out 输出必须严格等于指定量且输入不超过上限。两腿最终 PM delta 为零。
- 请求与真实用户的 TSV SBT 资格在入口校验。入口固定使用 Registry 配置的 TSV Hook，池准入、证券上市和暂停检查交给该 Hook，不再在 Router 重复调用 isTradable 或检查报价币状态。股票支付/取款复用父类的 swappingEnabled 与 W.isAllowed；Factory/W 的永久 U 绑定已在准入时验证，支付时不再重复比较。owner、exitAdmin、元数据等准入配置不再做整笔交易的快照一致性检查。
- Hook 按真实股票腿 gross input / net output 计量一次，使用 U 的 canonical 法律股数换算。同 U 的多个 W/池共享 securityId 额度。Router 不另收结算费用；原版静态 LP fee、协议费仍由 PM 处理。

聚合器沿用 main 的 Adapter 白名单与真实用户、结算方分离。Governor 通过 `setAdapterAllowed` 授权，并保留 `AdapterAuthorizationUpdated` 配置事件；Router 的两个成交事件已删除。`participant` 来自 Adapter 验证过的 DEX caller marker，父类 `msgSender()` 返回该用户，V4 锁中的发起者 Adapter 负责付款和收款。`settlementCurrency(W)` 返回 U、`settlementCurrency(Q)` 返回 Q；现有 TSVAdapter 仅将两处收付币种读取改为该映射，签名与 V4 请求中的 PoolKey 仍为 W/Q，输出交付和部分成交退款沿用 main 逻辑。

2026-10-07 review 经确认修正文档中的绝对零 U 余额条件：普通持有人向 PM/Router 转入少量 U，或同一 PM 托管其他池的 U，不应阻断本协议交易与 W 准入。Router 在进入 unlock 前将 U 余额基线保存在本次调用的内存中，并在 unlock 返回后核对；股票支付与取款分别检查实际 U 转账两端的精确变化。没有清扫 PM 资产的权限。

## 本地验收与交付边界

Registry 测试使用固定上游原版 F/W 和真实 PM。新 Wrapped Swap fixture 使用真实 PM、原版 F/W、真实 Registry/Hook/Ledger/Inbox/Router 代理；U/Q/SBT 为行为替身。`V1WrappedLiquiditySeed` 仅在 test 目录提供带真实 Hook context 的建池注资，额外 wrapper 权限也只在测试中设置。生产 LP 源码未迁移，不得部署该 seed helper 替代生产 LP。

成功交易、资金守恒、回调门禁与重入测试均经过真实 PM 和原版 W。已删除替换或冒充 PM 后篡改回调、重复回调、伪造 settle 返回值的测试。转账税、少付及资产回调由 U/Q 行为替身模拟，验证精确结算与回滚；Hook 消费者单元测试注入 delta，不计作真实资金结算。

历史 DIRECT/LP/DEX 的 27 个 `.sol.deferred` 文件保留，未计入当前通过数量，清单见 `test/DEFERRED_PERMISSIONED.md`。新套件覆盖四条交易路径、18/6 精度、非 1:1 法律计股、验证保证金、共享额度、部分成交、协议费提取、双侧转账故障、身份、V4 重入锁及不可变升级身份；DexAdapter 本地测试已迁移到真实 W/Q fixture，覆盖 U/Q 双向收付、签名重放拒绝、退款与 Adapter 锁。

```sh
forge test -vv
forge test --match-path 'test/integration/local/trading/Wrapped*.t.sol' -vv
forge build src --sizes
forge inspect TSVRegistryV1 storageLayout --json
forge inspect TSVSwapRouterV1 storageLayout --json
forge fmt --check
git diff --check
```

开通步骤见 [W/U/Q 市场运营流程](./OPENING_A_STOCK_MARKET_V1.md)。当前 manifest 是模板，`wrappedRouterReady` / `wrappedLiquidityReady` 保持 false；本地实现不等于生产启用。必须先完成生产 Wrapped LP、发行方对 Router/W/用户及协议费接收方的权限核验、目标链部署与实际流动性证据。

## 本地制品记录

2026-10-08 Registry 遗留代码清理后的完整本地回归：**314 项通过，0 失败、0 跳过，48 个套件**。新增非法 MarketAction 低层调用回归，确认 ABI 解码拒绝请求且不改变状态；生命周期和暂停测试改用实际控制下架的证券级池计数。命令为 `forge test --dynamic-test-linking --summary`，日志为 `out/registry-dead-code-full-tests.log`。生产构建、`make check`、编译源文件哈希与 ABI/layout 对照均通过。

2026-10-08 删除配置 Version、Router 成交事件和 Ledger 引用后的完整本地回归：**313 项通过，0 失败、0 跳过，48 个套件**，含 Wrapped Swap 30 项、DexAdapter 11 项。保留报告更新顺序和完整治理回归。命令使用默认优化配置及 `--dynamic-test-linking`；日志为 `out/tsv-router-lock.vhL8kj/version-cleanup-full-tests.log`。`make check`、生产源码构建及编译源文件哈希/ABI/layout 核对通过。

2026-10-08 Registry 精简回归：Registry 目录 **70 项通过，0 失败、0 跳过**，包含 SBT 固定绑定、逐身份权限更新与并集、权限/撤证区分、U 共享 exitAdmin、W 准入及暂停叠加。绑定事件验证只产生一条完整日志。格式、测试目录布局、ABI 和 Registry 存储布局检查通过。

2026-10-08 Router 第二轮简化后的当前版本：本地交易目录 6 个 suite、41 项测试通过，0 失败、0 跳过，其中 Wrapped 30 项、DexAdapter 11 项。普通 fuzz 每项 256 次。执行日志为 `out/tsv-router-lock.vhL8kj/simplified-round2-tests.log`。历史 DIRECT/LP/XLayer DEX 的 27 个延期文件不计入本次通过数。

Router 从 436 行减至 231 行，活跃交易上下文从 14 个字段减至 3 个；内部结算库从 92 行减至 58 行。删除 `TSVSwapValidationLib`、`SettlementLegPlan`、Router 的链接库依赖、成交事件、Ledger 引用及 `_clearContext`；回调与动作分发直接继承 V4。ABI 保留 Adapter 白名单、授权 setter 和配置事件，增加 `settlementCurrency`；没有公开 action dispatcher。

| 生产制品 | Runtime | Initcode | EIP-170 余量 |
| --- | ---: | ---: | ---: |
| TSVRegistryV1 | 19,883 B | 20,120 B | 4,693 B |
| TSVSwapRouterV1 | 20,190 B | 20,932 B | 4,386 B |
| PermissionedValidationLib | 7,561 B | 7,591 B | 17,015 B |

Registry 精简后为 650 行（原 854 行），移除 Factory/checker 实现、配置版本计数、冗余校验转发、重复准入检查、地址打包和通用资格入口。SBT 在组件绑定时固定，身份 setter 只接收 tokenId 与权限。绑定只发一个完整事件；W/报价币登记只发登记事件；建池使用 PM Initialize 事件，停用/恢复使用暂停事件。Router 地址改由 Hook 提供，删除绑定阶段的交叉引用检查；删除旧 Router、Factory 转发锁、单 SBT tokenId 的占位字段，保留实际使用的 SBT 身份配置及 U→W 索引。上述三项制品均满足 EIP-170。

2026-10-08 遗留代码检查另删除未抛出的 Registry `Paused` 错误、按币种维护但不参与业务门禁的 `activePoolCountByCurrency`，以及市场报告枚举的不可达兜底分支和重复的零 Tier 检查。本轮同时移除证券级池计数，下架直接阻止该证券全部池的普通操作；重新上市后，未暂停的历史池自动恢复。Registry 事件全部有对应写入口；Router 仅保留 Adapter 授权配置事件，其三个上下文字段均用于交易。兼容 V4 父类保留通用 action 分发，多跳、通用 SETTLE/TAKE 等分支无法由 TSV 固定的三动作请求进入。

尺寸沿用 Solidity 0.8.26 / Cancun / viaIR / optimizer 200 / bytecode_hash none。本次修改文件的格式检查和 `git diff --check` 通过。

上表为运营状态简化后的生产字节码尺寸，构建日志为 `out/tsv-router-lock.vhL8kj/state-removal-artifacts.log`；测试构建启用动态链接，其字节码不用于此表。旧 Swap gas 记录已移除，后续预算应按当前生产制品测量。

ABI 与普通存储布局保存于 `docs/artifacts/TSVRegistryV1.*.json` 和 `docs/artifacts/TSVSwapRouterV1.*.json`。治理父类的 OZ ERC-7201 命名空间还须随固定依赖共同保留；Library 自身无存储布局。本批为全新布局，不提供旧 TokenConfig 或旧 Router 状态迁移。兼容父类来源及完整差异见 `src/v1/vendor/v4-router/README.md` 与 `docs/artifacts/v4-router-compatibility.diff`；原版 Factory/W 没有修改。
