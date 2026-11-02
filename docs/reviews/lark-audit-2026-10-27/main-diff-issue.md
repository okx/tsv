## 目的与比较基线

登记审计版本与当前远端 main 已有业务代码差异，需要以固定 commit 明确本次审计结论适用范围，并确定增量复核范围。

- 审计报告：[DEX - TSV 合约审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd)。
- 审计版本：`6402443e9fc372e8aa52c9ba82cd3e84cb846493`，已保留在 `audit/2026-10-27-6402443`。
- 当前 main 快照：`90929552fd557fd67b9debafa905bafffb40ed86`，本次 fetch 后固定该 SHA 比较；后续 main 变化不包含在本说明中。
- [完整版本对比](https://gitlab.okg.com/web3-dex/tsv/-/compare/6402443e9fc372e8aa52c9ba82cd3e84cb846493...90929552fd557fd67b9debafa905bafffb40ed86)。审计版本为该 main 的祖先，共新增 57 个提交，其中 35 个非 merge 提交。
- 仓库整体：198 个文件，新增 39,417 行、删除 826 行。大量增量来自脚本、部署操作记录、SDK 和文档，不能将总行数等同于合约逻辑变更规模。
- `src/v1`：10 个文件，新增 739 行、删除 107 行；其中 vendor 2 个文件。测试目录 24 个文件变化。
- 风险等级：未评级。本 issue 记录版本差异及待复核范围，不为各项新增逻辑作安全定级。

## 主要业务差异

| 模块 | 审计版本 → main 的行为变化 | 增量复核与接入影响 |
|---|---|---|
| VolumeLedger 每日额度 | `Quota[securityId][ESTDay]` 改为 `Quota[securityId]`，额度按证券持续生效；`usedWad` 仍按日累计。`setQuota` 从按日数组改为单个 amount，`QuotaSet` 移除 ESTDay。 | 更新调用 ABI、事件解析和日额度运营逻辑；若升级已有代理，需要核对旧额度存储的迁移/重设，旧 mapping 数据不会自动成为新的单层 mapping 值。 |
| LP 授权与支付 | 移除 `TOKEN_APPROVE_PROXY` immutable、构造参数及 `ITokenApproveProxy.sol`；用户 U/Q 通过对 LPManager 的直接 ERC-20 allowance 支付。U 转给 W 后包装，Q 转给 PoolManager。 | 前端和脚本应改为授权 LPManager，旧 TokenApprove 授权不能替代新授权；核对库链接和部署构造参数。 |
| TSV 强退与事件 | `unwindPositionByOkx` 更名为 `unwindPositionByTsv`；TSV 管理员路径移除原有“两侧至少一侧可强退”的资格检查，仍有入口角色和其他执行检查。发行方 `unwindPosition` 保留该资格检查。新增 TSV/发行方退出汇总事件，区分 LP 与发行方到账；W 侧按底层 U 的余额差统计。 | 更新 selector 和事件解析；复核管理员/发行方两条路径的授权边界、回调余额快照及交付 fallback。事件 token0/token1 仍是池中 W/Q，金额是结算 U/Q 的原始单位，需要接入方正确映射。 |
| 强退 permission flag | vendor 中 `UNWIND_ALLOWED` 由 `0x0004` 改为 `0x8000`。 | 核对外部 Checker、适配器及权限配置使用的位值；旧权限不能未经映射直接沿用。 |
| Router 交易入口和结算 | 新增 `swapExactInput(request)`，付款方、权限主体、收款方均绑定调用者；Adapter 入口独立要求 allowlist。Direct 入口增加 payer 参数：U 输入要求预存 W 且 payer=0；Q 输入由 Adapter 付款，settle 时直接转入 PoolManager。Direct 的股票输出只能给 participant，Q 输出可给 participant 或调用 Adapter；另一 `swapExactInputFromContract` 路径保留独立行为。新增 activePayer 状态并在 unlock 后清零。 | 更新 Router ABI、授权与路由构建；分别复核所有入口的 participant/payer/recipient 绑定、预存 U 归属、Q 结算及失败回滚，不能只验证单一入口。 |
| 证券暂停状态 | `applySecurityStatus(id, mode, reason)` 改为 `(id, mode, enable, reason)`，从设置最终状态改为独立设置/清除 TRADE、LP 两个 bit。枚举由 NONE/TRADE/LP/ALL 改为 TRADE/LP/ALL（ordinal 0/1/2）；查询和事件值是 mask 0/1/2/3。`SecurityRecord.securityState` 嵌套结构改为 `uint8 pauseMode`。 | 更新 selector、枚举编码和事件/查询解析。旧存储结构与新结构存在 packing 变化，源码也明确要求旧代理迁移暂停状态；需要独立核对布局与迁移，不可只依据外部数值相似判断兼容。 |
| Registry 管理权限及 Factory 更换 | `setTierPolicy` 从 DEFAULT_ADMIN_ROLE 改为 SYMBOL_ADMIN_ROLE；新增 `replacePermissionsAdapterFactory(newFactory, reasonCode)`，要求 UPGRADE_ADMIN_ROLE、全局暂停，以及新 Factory 与 Hook/Router/LPManager 的 Registry、PoolManager、Factory 绑定一致。Router 升级检查从 Factory 固定不变改为允许绑定同一 PoolManager 的新 Factory。 | 属于新增治理/迁移流程，需复核组件升级顺序、暂停窗口、绑定一致性、旧 W/池的兼容及失败恢复。LPManager/Router 现有升级入口仍受未暂停门禁，需结合迁移脚本检查完整顺序。 |
| 新增 Securitize vendor Checker | 新增 `src/v1/vendor/SecuritizeTSVChecker.sol`（413 行），实现 DS token 服务查询、lost wallet、wind-down、流动性限制、权限与强退判断，并包含可升级/所有者管理逻辑。 | 原报告范围对 vendor 的描述存在差异：基础信息提及 vendor 修改，范围表又写排除 vendor。需明确该新增文件和 PermissionFlags 改动是否纳入补审；Checker 的相对 import/配套依赖与编译接入也需验证，本说明不认定其已可部署。 |

代码依据（固定 main SHA）：[Ledger](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/core/TSVVolumeLedgerV1.sol#L27)、[LP 强退及余额事件](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/libraries/TSVLPManagerLib.sol#L113)、[Router 入口](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/periphery/TSVSwapRouterV1.sol#L114)、[Factory 更换](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/core/TSVRegistryV1.sol#L276)、[暂停状态](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/core/TSVRegistryV1.sol#L721)、[存储类型](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/types/TSVTypes.sol#L60)、[权限位](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/vendor/permissionedPools/libraries/PermissionFlags.sol#L27)、[新增 Checker](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/vendor/SecuritizeTSVChecker.sol)。

## 子模块、SDK、脚本及交付差异

- `lib/dex-adapters` 指针从 `cfa52d8c3036907911084c1581258bf36bf82543` 更新为 `80800d5670012abe0f7363eecf12358cc50b813f`。已读取这两个固定子模块版本的 TSVAdapter 源码差异，未将当前本地子模块的未提交改动计入比较。
- [子模块固定版本对比](https://gitlab.okg.com/web3-dex/GitHub-Web3-DEX-Adapters-EVM/-/compare/cfa52d8c3036907911084c1581258bf36bf82543...80800d5670012abe0f7363eecf12358cc50b813f)：TSVAdapter 从 CallerAuth 签名/nonce/expiry 模型改为 owner 管理 DexRouter allowlist；MoreInfo 变为 `(key, expectedMultiplier, amountIn)` 三字段，无后台授权签名。卖 U 使用传入数量及 W 中预存 U；买 U 使用 Adapter 的 Q 余额，调用新版 direct 入口，并按输出类型处理转发。构造参数、调用权限和 payload 均需同步。这是依赖的业务变化，应纳入联动复核。
- 新增 Python XLayer 操作 SDK、协议部署/AA 操作、Factory 迁移及 XLayer 运维脚本；最新 main 的 `bd7f03e` 已将 SDK payload 对齐无签名三字段格式。历史提交消息中虽有 signed swap，不代表最终 main 仍采用签名模式。
- 新增部署与链上操作记录、Factory 迁移指南、LPManager multicall/ABI 指南，更新 ABI/storage-layout 文档，并移除旧中英文后端接入指南。需按最终接口同步部署清单和接入文档。
- `foundry.toml` 新增子模块 OpenZeppelin remapping 和脚本目录读写配置；编译器版本保持 `0.8.26`。此处只记录配置差异。

## 与已登记审计问题的对应关系

1. **报告基线需要澄清**：登记 commit `6402443` 中，LP 强退仍叫 `unwindPositionByOkx`，没有 `TsvPositionUnwound`/`IssuerPositionUnwound` 余额差汇总事件；报告 No.1/#9、No.3/#11 引用的函数名和事件代码来自后续版本。相关变更提交包括 `ad97058`、`f020ddd`、`8df17b3`、`8fbabc5`。因此需要审计方补充逐问题实际检查的 commit，不能将当前报告的所有代码片段视为登记基线的原文代码。
2. **No.3/#11 的 U 到账统计**：main 的 `8fbabc5` 已加入 `_settlementCurrency`，通过 Factory 将 W 映射至 U 后取余额，源码层面已针对该建议作修改；是否关闭仍应由审计复核确认。
3. **No.1/#9 的余额差下溢**：main 两条汇总事件仍直接使用 `after - before`，且 before 快照仍在 unsubscribe 回调前。改为读取 U 的提交不等同于修复余额减少问题；需继续复核 #9。
4. **No.2/#10 的身份列表、No.4/#12 的升级暂停门禁**：相应机制没有在此次差异中被直接移除，不能因为 main 前进就认定已修复。Factory 更换新增暂停要求，应与 #12 一并复核完整运维流程。
5. **No.6.11/#24 的 pauseMode 建议**：证券状态结构及 setter 已重写，需要针对新 mask/selector 语义重新确认建议是否仍适用；不自动沿用旧代码位置。
6. 其余 #13–#29 仍保留各自报告原文；本说明不批量关闭问题、不替代逐项验收或风险评级。

## 增量复核交付项

- [ ] 审计方确认本报告及各问题对应的实际代码 SHA，将登记基线与后续复核版本区分记录。
- [ ] 对上表的 Router、LP 强退/授权、Quota、暂停状态、Factory 迁移、权限位和 Checker 完成增量复核，并明确 vendor 与子模块范围。
- [ ] 验证 Registry/VolumeLedger 的存储变化、既有配置迁移，以及 Router/LPManager 新 ABI、库链接和构造参数。
- [ ] 对 #9/#11/#12/#24 等受变更影响的问题，按固定 main SHA 更新复核结论。
- [ ] 以干净 checkout 和记录的子模块指针运行编译及针对性回归，记录实际执行结果；源码已有测试变更不等于测试已通过。

已在 diff 中看到更新/新增的回归覆盖：`LPLinkedLibraries.t.sol`（直接授权、强退到账/fallback）、`ContractDirectSwap.t.sol`/`DexAdapter.t.sol`（入口与路由）、`Pauses.t.sol`（独立 bit 及 fuzz）、`VolumeLedgerAccounting.t.sol`/`VolumeLedgerSetUsedWad.t.sol`（额度）。本次为版本差异说明，仅进行了固定 SHA 的 git diff/log、源码及测试文本核对，未执行编译、测试、链上操作或完整安全审计。
