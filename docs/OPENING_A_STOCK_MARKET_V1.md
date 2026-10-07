# W/U/Q 股票市场开通与运营（2026-10-07）

当前流程使用项目 underlying U、原版 PermissionsAdapter W 和原币报价 Q。用户授权 Router、收付 U/Q；PoolKey 和 PM 使用 W/Q。Registry 与单池 Wrapped Swap 已实现；生产 Wrapped LP 尚待交付，开通流程中的生产建池/注资步骤须由兼容组件完成。源码与验收范围见 [Registry 与 Wrapped Swap](./PERMISSIONED_REGISTRY_V1.md)。

## 开通顺序

```mermaid
flowchart TD
    A[部署只读验证库及核心代理<br/>Router 实现固定 PM/R] --> B[绑定组件、真实 Factory、SBT、Tier 和角色]
    B --> C[Governor 批准合约 owner<br/>核定 U 法律股数 Adapter 和发行方权限]
    C --> D[通过 R 创建原版 W<br/>存入验证 U 并由真实 Factory 验证]
    D --> E[owner 允许 Router 和 Hook<br/>配置独立 exitAdmin，暂不启用 swapping]
    E --> F[admitPermissionedSecurity<br/>登记 W 与 U 的 canonical 配置]
    B --> Q[registerQuoteToken：登记原币 Q]
    F --> V[提交适用月份 ADTV]
    F --> L[兼容生产 LP 组件登记 W/Q 池并注入流动性]
    Q --> L
    V --> G[核对额度、库存、资格和发行方权限]
    L --> G
    G --> H[W owner 启用 swappingEnabled]
    H --> I[用户授权 Router 支出 U 或 Q<br/>执行四种 Swap 路径并保存证据]
```

证券准入、Pool ACTIVE 和可实际成交是不同阶段。`OPEN` / `isTradable` 不证明 ADTV、剩余额度、价格区间内流动性、用户 SBT 或发行方转账条件已齐备。ADTV 与建池注资可在准入后分别准备；完成两者及所有权限核验后再启用 swapping。

## 一次性环境配置

复用已完成的环境时读取并核验，不重复调用一次性绑定。

| 执行者 / 入口 | 必须核对的结果 |
| --- | --- |
| 部署者：部署 `PermissionedValidationLib` | Registry 和 Router 链接同一已记录地址；内部 settlement/runtime helper 不单独部署。 |
| 部署者：原版 `PermissionsAdapterFactory(PM)`、Registry R、Router 实现 `(PM,R)` | F 与 Router 使用同一个 PM；Router 的 `PERMISSIONS_ADAPTER_FACTORY()` 返回 R，R 的 `permissionsAdapterFactory()` 返回真实 F。 |
| Governor：`R.bindComponents(Hook, LPManager, DataInbox)` | 三组件身份与 manifest 一致。 |
| Governor：`R.bindPermissionedComponents(F, Router)` | R 一次性记录真实 F、PM、Router；Hook 的 Router/LP 引用一致。 |
| Governor：`Ledger.bindWriters(Hook, DataInbox)`、`Anchor.bindProxies(address[6])` | 写入者及六代理顺序为 R、Ledger、Inbox、Hook、Router、LPManager。 |
| Governor：`R.setSbtConfig(sbt, tokenId)`、`R.setTierPolicy(tierId, tierBps, maxListed)` | SBT 正常、用户可验证；Tier 非零、有名额，比例为 `1..10000` bps。 |
| Governor：目标代理 `grantRole` | Registry 的 SYMBOL_ADMIN、Inbox 的 VOLUME_ORACLE/HALT_REPORTER，以及暂停/恢复人员均使用真实执行账号。生产建池角色由兼容 LP 组件提供。 |

部署脚本保留六代理框架；当前生产 LP 未完成 Wrapped 改造，不能仅运行脚本就宣布市场可交易。`VerifyDeploymentV1` 校验组件身份、不可变 PM/R 与库链接，资产/issuer/流动性条件需另行记录。所有地址、实现参数、依赖版本、ABI/layout 和交易证据填入 [manifest](./DEPLOYMENT_MANIFEST_V1.example.json)。

## 每只证券的准备与准入

1. **核定 U 与计股口径。** U 是项目中的股票 underlying，可能是发行方自身的 shares/wrapped token；它不等于 TSV 的 W。Adapter 的 `poolCurrency()` 必须为 U，支持 `IDirectLegalShareAdapter`，首次 canonical 版本为 1。U/W 精度一致且不超过 18，raw 余额与转账必须符合精确结算。先取得 issuer 对 Router 支出用户 U、W 托管 U、W 向用户释放 U、协议费接收方收取 U 的允许条件。
2. **批准 owner。** Governor 调用 `R.setPermissionedOwnerApproval(owner, true)`；owner 必须是合约账号，随后配置 W 的允许 wrapper、Hook 和 swapping。owner 与 exitAdmin 分离。
3. **创建、验证 W。** 任何账号均可调用 `R.createPermissionsAdapter(IERC20(U), owner, IAllowlistChecker(R))`，保存真实 F 的 Created 事件及 W 地址。持有者先 `U.approve(W, verificationAmount)`，再 `W.depositForVerification(verificationAmount)`；之后调用 `R.verifyPermissionsAdapter(W)` 并核对 F 的两个查询均返回 U。验证保证金为 surplus，不能作为 Swap 少付的抵扣。
4. **配置 W 与 exitAdmin。** W owner 调用 `updateAllowedWrapper(Router,true)`、`updateAllowedHook(Hook,true)`；checker 必须为 R。Governor 调用 `R.setExitAdmin(W, exitAdmin)`，要求独立合约且不得为 owner、资产或系统组件。此时 swapping 可保持 false，准入不要求已开启交易。
5. **原子准入证券与 W。** SYMBOL_ADMIN 调用 `R.admitPermissionedSecurity(tierId, PermissionedAdmission(W, securityId, owner, legalShareAdapter))`。securityId 非零且未上市；首次 W 要求 supply、PM W 余额及累计 W 协议费为零。R 派生并保存 U/decimals/canonical 版本，默认上市且市场 OPEN。
6. **登记报价 Q。** SYMBOL_ADMIN 调用 `R.registerQuoteToken(Q)`；Q 是原币 ERC-20，不能使用 U、W 或系统地址。报价精度独立，例如 U/W 18 decimals、Q 6 decimals。已有 APPROVED Q 可复用。

同一 U 添加第二个 W 时调用 `registerPermissionedCurrency(admission)`，沿用相同 securityId、精度和 canonical Adapter。每个 W 独立管理 owner、状态、exitAdmin 与版本，但全部池共用证券日额度。

## 报告、生产 LP 与启用门禁

VOLUME_ORACLE 向 DataInbox 提交适用上月的 `AdtvReport`，量纲为法律股数 WAD；quota 为可选当日绝对覆盖。新证券默认 OPEN，不需要额外首次开市报告。交易所停复市由 HALT_REPORTER 提交 `MarketReport`，没有自动交易所日历。

生产兼容 LP 组件必须按 Registry 的 W/Q PoolKey、排序、Hook 地址及真实 LP context 完成登记、PM initialize 和注资，达到 ACTIVE 且覆盖首笔交易价格。该组件、仓位/退出/费用流程与权限须独立交付验收。`test/helpers/v1/WrappedSwapMocks.sol` 中的 seed helper 仅为本地验收提供资金，不属于运营 ABI，也不能授予其测试 wrapper 权限给生产实例。

启用前检查以下条件，均保存读值与证据：

| 门禁 | 验收读值或证据 |
| --- | --- |
| 身份与状态 | F 对 W created/verified 均为 U；W 的 PM/U/checker、owner 与 R 记录一致；W/Q APPROVED，证券上市，PoolKey 完整匹配且 ACTIVE。 |
| W 权限 | owner 已获 Governor 批准；Router wrapper 和 Hook 均允许；exitAdmin 独立且版本非零。 |
| 发行方权限 | 用户 U→W 及 W→用户 U、Router operator、W custody、协议费接收方均可达；Q 支出与接收无税费或额外扣费。 |
| 库存 | PM W = W supply，Router/用户 W = 0；W U collateral ≥ supply。记录 PM/Router 既有 U 余额并验证每笔交易保持不变；记录 surplus E，既有余额和验证保证金不可挪用于付款。 |
| 资格与额度 | SBT 未暂停，真实用户持证；ADTV/报告适用，当前日额度足够，交易门禁正常。SDK 从 W 调用 `isAllowed`，不能以直接向 R 查询 checker 替代。 |
| 流动性与费用 | 有真实覆盖区间流动性、可用报价和滑点参数；静态 LP fee 与协议费配置合理，W 协议费提取按原版 W 自动释放 U 到获准接收方。 |

条件齐备后由 W owner 调用 `W.updateSwappingEnabled(true)`。把 production LP 与发行方证据补齐后才能设置 manifest 的 readiness；当前仓库模板保持 false。

## 用户交易与首笔验收

用户直接调用 Router，输入股票时执行 `U.approve(Router, amount)`，输入报价时执行 `Q.approve(Router, amount)`。授权 W 不能替代 Swap 对 Router 的 U 授权。PoolKey 使用 W/Q，方向按地址排序确定；调用返回真实 `actualIn, actualOut`。

| 路径 | amountSpecified / limitAmount | 用户余额效果 |
| --- | --- | --- |
| U→Q exact-in | 指定 U raw 最大输入 / Q raw 最小输出 | 支付实际成交 U、接收 Q；允许部分成交。 |
| U→Q exact-out | 指定 Q raw 精确输出 / U raw 最大输入 | 支付不超上限的 U、接收严格指定 Q。 |
| Q→U exact-in | 指定 Q raw 最大输入 / U raw 最小输出 | 支付实际成交 Q、接收 U。 |
| Q→U exact-out | 指定 U raw 精确输出 / Q raw 最大输入 | 支付不超上限的 Q、接收严格指定 U。 |

四条路径使用 `swapExactInput` / `swapExactOutput` 与有效 deadline。检查一次 `SwapExecuted`、一次 Hook `SwapAccounted`、真实余额双侧变化、U canonical 法律股数与 Ledger.used 增量、PM 两腿零欠款，以及库存和 E 保持不变。失败须余额、价格、流动性、额度与策略写入全部回滚，随后修正条件能够重试。

本期 external Adapter 入口立即拒绝，且没有 Adapter 白名单、多跳、native 或 U 直接池入口。前端/SDK 应移除旧 DEX 成功路线。

## 持续运营

- W/Q 状态分别使用 `setPermissionedCurrencyStatus` / `setQuoteTokenStatus`，APPROVED↔DISABLED 每次递增各自版本。证券上下架、Pool 状态及紧急暂停仍按对应角色操作；恢复必须重新核验相关条件。
- owner 轮换先禁用 W，由新 owner 实际接受 ownership 并获 Governor 批准，再调用 `updatePermissionedExpectedOwner`，复核权限后恢复 W。
- exitAdmin 通过 `setExitAdmin` 独立更新，不改变 owner/业务角色，本期不接收 Swap 输出；用户输出受发行方限制时整笔交易回滚。
- canonical 计股口径更新使用 `replaceUnderlyingLegalShareAdapter(U,newAdapter)`，要求整个证券同时覆盖 TRADE 与 LP 暂停，新版本递增；仅暂停某个 W 不足。同 U 的全部 W 立即使用新口径，历史 used 不清零。
- 按月提交 ADTV，必要时更新 quota、排期拆并股系数；持续监控 issuer 拒转、SBT、W 权限/库存、适用额度、生产 LP 流动性及 PM 费用。交易中策略发生变化会回滚，不在结算途中接受新配置。
