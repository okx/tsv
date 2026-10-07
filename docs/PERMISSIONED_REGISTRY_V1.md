# Permissioned Registry 与 Wrapped Swap 实现（2026-10-07）

依据：[Wrapped Swap 编码前详细设计 v2](https://okg-block.sg.larksuite.com/docx/HZHpdOzm3obeEhxXWKRlBNUmgNb)。当前交付 Registry、Hook/Ledger 配置读取、共同接口及单池 Wrapped Swap。生产 Wrapped LP、真实发行方与目标链验收仍待后续交付。旧文档中的 DIRECT 股票、TokenConfig/getToken 和旧成功路径不适用于本批制品。

## 数据与接口

- `currencies[W]` 保存永久 U、expectedOwner、AssetStatus、configVersion；`getCurrency(W)` 返回该记录。
- `underlyings[U]` 唯一保存 securityId、rawDecimals、legalShareAdapter 和 legalAdapterVersion；`getUnderlying(U)` 返回该记录。同 U 的全部 W 共享此口径及 securityId 的 Ledger 额度。
- `quoteTokens[Q]` 独立保存原币报价的精度、状态和版本；`getQuoteToken(Q)` 返回该记录。0 decimals 合法，存在性按 status 判断。
- 新证券使用 `admitPermissionedSecurity(tierId, admission)`；已有证券添加 W 使用 `registerPermissionedCurrency(admission)`。U、精度和版本从真实合约派生，admission 仅含 W/securityId/expectedOwner/legalShareAdapter。
- 报价币使用 `registerQuoteToken(Q)`。股票、underlying、报价和系统地址不得混用；Pool 只登记 W/Q。
- W/Q 各用独立状态入口，只有 APPROVED ↔ DISABLED，每次递增版本。恢复 W 复查配置，保留已有 supply 和协议费用；首次准入要求新 W supply、PM W 余额及累计 W 费用为零。
- owner 批准由 Governor 控制；expectedOwner 轮换由 SYMBOL_ADMIN 执行，要求 W 已禁用、新 owner 已实际接受 ownership、获批准且与 exitAdmin 分离。
- exitAdmin 可在 verified 候选 W 准入前独立配置，每个 W 的版本独立。它不接收本期 Swap 输出，也不授予 owner 或执行角色。
- `replaceUnderlyingLegalShareAdapter(U, newAdapter)` 要求证券范围同时覆盖交易和 LP 暂停；单 W 的 TOKEN 暂停不足。更新立即影响该 U 的所有 W，不清 Ledger。

## Factory 与 checker

Registry 代理 R 直接实现上游 `IPermissionsAdapterFactory` 和 `IAllowlistChecker`。`permissionsAdapterFactory()` 是真实 F；Router 的 `PERMISSIONS_ADAPTER_FACTORY()` 是 R；`permissionedAllowlistChecker()` 也是 R。

先 `bindComponents(Hook, LPManager, DataInbox)`，再 Governor 调用一次性 `bindPermissionedComponents(F, Router)`。候选 F 的 PM 必须与三组件一致；三组件 Registry 为 R，Hook 的 Router/LPManager 关系一致。全部检查完成后原子写入 F/PM/Router。

未绑定时三个 Factory 查询返回零，create/verify/准入/建池拒绝。绑定后创建、验证保持 permissionless，原样转发 owner/checker，checker 只能是 R，共享重入锁，Factory 错误冒泡。Created/Verified 事件只由 F 发出。F 仍可直接创建；每个 W 仍须完整准入。

checker 只接受已准入 W 的调用，tokenAddress 必须等于该 W 的 U；W APPROVED、证券上市且 SBT 合格时返回 `0x0003`。未配置、paused、verify=false 拒绝；有效 W 的 SBT 读取异常回滚。普通账号、Router、PM 和 Factory 直接查询返回 NONE；SDK 应通过 W.isAllowed 查询。

## 尺寸收敛：已确认的只读链接库设计

单合约版本在既定 Solidity 0.8.26 / Cancun / viaIR / optimizer 200 下超过 EIP-170 限制。经确认抽出 `PermissionedValidationLib`，未改变编译基准。

同一个库包含 Registry 准入校验，以及 Router 运行时的 W/U/Q 结算计划和策略快照：候选环境、Factory/W 身份、元数据、法律股数接口、owner/wrapper/Hook/exitAdmin、报价类型、首次库存和 W 的交易资格。没有状态变量、SSTORE、创建 W、checker 或治理入口。Registry 保留全部映射、角色检查、状态写入、事件、Factory 转发、SBT checker 及共享重入锁。

库通过 Solidity 外部 library 的 delegatecall 执行，`address(this)` 是调用方 Registry 或 Router 代理。Registry 准入分支读取自身无副作用 getter，不调用 checker 或 W.isAllowed；Router 的 `swapPlans` 分支显式读取 R，并调用原版 `W.isAllowed(user, SWAP_ALLOWED)`。资金移动、回调上下文、锁和全部存储仍由 Router 管理；内部 `TSVSwapValidationLib` 与 `TSVPermissionedSettlementLib` 无需独立部署或链接。库地址编译链接到实现中，`permissionedValidationLibrary()` 返回实际链接地址；无法通过运营 setter 换库，后续更换只能随受治理的实现升级交付并复核。

部署前先部署并核验库，将链接地址提供给 Forge：

```sh
forge build --libraries "src/v1/libraries/PermissionedValidationLib.sol:PermissionedValidationLib:$TSV_PERMISSIONED_VALIDATION_LIBRARY"
forge script script/DeployCoreV1.s.sol:DeployCoreV1 --libraries "src/v1/libraries/PermissionedValidationLib.sol:PermissionedValidationLib:$TSV_PERMISSIONED_VALIDATION_LIBRARY" --rpc-url "$TSV_RPC_URL"
```

上述 script 命令为模拟，广播仍按发布审批执行。真实原版 PermissionsAdapterFactory 独立部署并绑定同一个 PM，不能传 R 充当 F。部署验证读取 `TSV_PERMISSIONS_ADAPTER_FACTORY` 与 `TSV_PERMISSIONED_VALIDATION_LIBRARY`，核对代码存在、Registry 实际绑定，以及 Registry/Router 两个实现的库链接值均与 manifest 一致。manifest 记录库地址、固定上游 commit、scoped OZ 5.0.2、TSV OZ 5.5.0 和 Registry 新 layout。没有旧状态迁移。

## Wrapped Swap 行为与接口

`TSVSwapRouterV1` 继承本地兼容版 `PermissionedV4Router` 与既有治理父类。实现构造参数为 `(PoolManager, Registry)`，两者固定在实现字节码中；`initialize(anchor, pm, registry, ledger)` 验证它们与初始化值、Anchor 和 Ledger 的 Registry 相同。升级候选必须保留相同 PM/R，并延续本批新存储布局。

仅 `swapExactInput(request)` 与 `swapExactOutput(request)` 可执行交易。`SwapRequest` 字段仍为 `(key, zeroForOne, amountSpecified, limitAmount, deadline)`，key 中股票地址是 W、报价地址是 Q；amountSpecified/limitAmount 使用对应腿的 raw 单位。用户直接调用并授权 Router 支出 U 或 Q，股票输出直接交付 U。支持 U→Q、Q→U 各自 exact-in/exact-out 四条路径。

- Router 固定构造单池 SWAP、SETTLE_ALL、TAKE_ALL 三个动作，hookData 为空；没有公开 action dispatcher、多跳、native 或库存兜底。
- `msgSender()` 从入口首次资格读取开始返回真实用户，空闲时为零。仅 PM 能进入回调，payload/request/policy 哈希绑定当次调用，回调只能消费一次；重入与重放拒绝。
- 股票输入：精确检查用户 U 减少与 W 合约 U 增加，再由原版 W mint 相同数量到 PM。仅一次 PM sync/pay/settle，settle 返回值须与实际欠款一致。
- 股票输出：PM take 原版 W，自动 burn/unwrap 并发送 U 给用户；逐项检查 W 的 collateral、supply、PM W 与用户 U 的变化。Q 直接双侧精确转账。
- 库存恒等式：PM W = W totalSupply，用户/Router W 为零，PM/Router U 为零，collateral ≥ supply；验证保证金余量 E = collateral − supply 在交易中保持不变，不能掩盖少付或税费。
- exact-in 按真实成交量支付，可部分成交，须满足最小输出；exact-out 输出必须严格等于指定量且输入不超过上限。两腿最终 PM delta 为零。
- 入口、回调前和结算后复查完整 W/U/Q 计划、池/证券版本及市场序号；权限、SBT、owner、exitAdmin、精度或 canonical legalShareAdapter 变化使整笔交易回滚。
- Hook 按真实股票腿 gross input / net output 计量一次，使用 U 的 canonical 法律股数换算。同 U 的多个 W/池共享 securityId 额度。Router 不另收结算费用；原版静态 LP fee、协议费仍由 PM 处理。

`swapExactInputFromAdapter` 保留 ABI 但立即以 `WrappedExternalAdapterUnsupported()` 拒绝。原 Adapter 白名单 setter/getter/事件已删除；历史 DEX 成功路径不属于本次验收。

## 本地验收与交付边界

Registry 测试使用固定上游原版 F/W 和真实 PM。新 Wrapped Swap fixture 使用真实 PM、原版 F/W、真实 Registry/Hook/Ledger/Inbox/Router 代理；U/Q/SBT 为行为替身。`V1WrappedLiquiditySeed` 仅在 test 目录提供带真实 Hook context 的建池注资，额外 wrapper 权限也只在测试中设置。生产 LP 源码未迁移，不得部署该 seed helper 替代生产 LP。

成功交易与资金守恒均经过真实 PM 和原版 W。少数回调畸形、重复回调、settle 返回值错误及 exact-out 超额返回测试使用受控故障注入，只证明拒绝与回滚。Hook 消费者单元测试注入 delta，不计作真实资金结算。

历史 DIRECT/LP/DEX 的 29 个 `.sol.deferred` 文件保留，未计入当前通过数量，清单见 `test/DEFERRED_PERMISSIONED.md`。新套件覆盖四条交易路径、18/6 精度、非 1:1 法律计股、验证保证金、共享额度、部分成交、协议费提取、双侧转账故障、交易中策略变化、身份、重入/重放及不可变升级身份。

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

`forge test -vv`：45 个 suite、274 项测试通过，0 失败、0 跳过。包含 Registry 首批 247 项和新增 Wrapped Swap 27 项；普通 fuzz 每项 256 次，治理/运营 invariant 每项 64 轮 × 32 步。29 个延期文件与 Swap 阶段起始快照逐字节一致，不计入通过数。生产 LP、Registry、Hook、Ledger 源码与本阶段起始快照一致。

| 生产制品 | Runtime | Initcode | EIP-170 余量 |
| --- | ---: | ---: | ---: |
| TSVRegistryV1 | 23,851 B | 24,088 B | 725 B |
| TSVSwapRouterV1 | 23,705 B | 24,249 B | 871 B |
| PermissionedValidationLib | 15,446 B | 15,476 B | 9,130 B |

`forge build src --sizes`、`forge build src script`、`forge fmt --check`、目录规则和 `git diff --check` 通过。验证库的实际运行时代码无 SSTORE/TSTORE，存储布局为空；Router ABI 没有旧 Adapter 白名单或公开 action dispatcher。尺寸使用相同 Solidity 0.8.26 / Cancun / viaIR / optimizer 200 / bytecode_hash none，没有更改编译基准。

四条路径的本地顺序调用 gas 观测：U→Q exact-in 1,427,287，exact-out 1,074,718；Q→U exact-in 1,117,365，exact-out 1,093,203。此日志来自同一测试中的先后调用，受存储/账户预热影响，不能视为真实 issuer 或目标链生产预算。

ABI 与普通存储布局保存于 `docs/artifacts/TSVRegistryV1.*.json` 和 `docs/artifacts/TSVSwapRouterV1.*.json`。治理父类的 OZ ERC-7201 命名空间还须随固定依赖共同保留；Library 自身无存储布局。本批为全新布局，不提供旧 TokenConfig 或旧 Router 状态迁移。兼容父类来源及完整差异见 `src/v1/vendor/v4-router/README.md` 与 `docs/artifacts/v4-router-compatibility.diff`；原版 Factory/W 没有修改。
