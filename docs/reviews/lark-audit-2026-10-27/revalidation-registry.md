# Registry 相关审计 Issue 定向复核

目标版本固定为 `90929552fd557fd67b9debafa905bafffb40ed86`（本次取得的远端 main）。当前工作区 HEAD 不作为判断依据。以下行号均来自 `git show 90929552:<path> | nl -ba`；SBT 依赖固定为该主仓版本记录的 `a4c53ccbf7de65a3f415a706d22a506a215b68fc`。仅分析既有问题，未运行测试、读取链上配置或推断部署治理地址。

## 汇总

| Issue | 当前状态 | 是否是成立的外部攻击漏洞 | 修复价值 / 建议优先级 |
|---|---|---|---|
| #10 SBT 身份列表无长度上限 | 仍存在，依赖管理员配置规模的可用性隐患 | 没有证明任意用户可扩容；不能据此认定任意用户 DoS | 有价值：限制长期不可回收成本，P2；当前仅少量稳定 ID 时不必作为上线阻断项 |
| #13 中心化风险 | 仍是现有信任模型；未证明有权限绕过 | 否，角色按设计行使权限不是漏洞 | 治理/运维措施价值高；无需删除权限或重写合约，建议“接受并跟踪治理措施” |
| #20 registerPool 重复 listed 检查 | 冗余仍存在，原建议在当前调用链上成立 | 否，重复检查只会多作保护 | 低价值，P3；可在常规整理时删除，保留亦可接受 |
| #23 setSbtConfig 重复 verify 检查 | 调用仍在，但“完全重复”论据不充分 | 否，未导致授权绕过或错误拒绝正常当前 SBT ID | 建议保留或标注用途；只为节省管理操作一次外部调用不值得改动 |
| #24 pauseMode & 3 冗余 | 表达式仍在；正常写入不变量下确实冗余 | 否，未证明可造成错误状态 | 几乎无修复价值，建议接受/关闭优化项，保留归一化逻辑合理 |
| #25 注册函数重复环境/listed 检查 | 两处防御检查仍在，在现有单调用点下确实重复 | 否，未发现安全影响 | 低价值，P3 或接受；仅删除重复的两个条件，不应删除 currency 唯一性检查 |

P2 表示建议有计划地完善的可用性/治理措施；P3 为可选整理，不代表安全等级。

## #10 / 报告 No.2：SBT 身份列表无长度上限

**结论：当前未修复，但应保留为依赖管理员配置规模的可用性隐患，而非未经证明的任意用户中风险 DoS。**

代码证据（`src/v1/core/TSVRegistryV1.sol`）：

- L91–92：`identityTokenIds` 明确为 append-only 数组。
- L324–334：`setSbtConfig` 要求 `DEFAULT_ADMIN_ROLE` 和非零 reasonCode；首次注册直接 `identityTokenIds.push(tokenId)`，没有长度上限。
- L339：设为 `NONE` 仅替换 `SbtIdentityConfig(true, permissions)`，不会删 ID。
- L343–346：`sbtTokenIds()` 返回完整数组。
- L362–384：`hasCredential`、`permissionsOf` 和 `isSbtAllowed` 都依赖 `_credentialState`；SBT paused 时 `permissionsOf` 提前返回 NONE。
- L784–791：每次遍历全量历史 ID，并逐项外部调用 `verify(owner, tokenId)`，没有找到所需权限后提前返回。
- `src/v1/periphery/TSVSwapRouterV1.sol` L252：实际 swap 路径调用 `isSbtAllowed`；`src/v1/libraries/TSVLPManagerLib.sol` L373、L388、L425–426：LP 操作同时对执行者与 owner 校验，故成本会累加。

**能触发什么，不能触发什么：**随着管理员合法累积大量不同身份类型，每次普通用户权限检查的成本线性增长。当前固定 SBT 的 `SmartWalletSbt.sol` L167–171 只是 `balanceOf(user, tokenId) > 0`，因此不同 ID 会形成不同 storage 读取。数组足够大时存在耗尽交易 gas 的机制。但是，只有 Registry default admin 能新增 ID，普通用户即使能领取许多 SBT，也不能将未登记 ID 追加进 Registry；现有代码证据不支持“外部用户低成本填满数组”。本次未读取链上 `sbtTokenIds`，不声称当前部署已经接近 gas 上限，也不虚构具体阈值。

**修复价值：有，但与实际规模相关。**如果系统计划仅登记少量稳定的权限类型，该问题目前通常不紧急；如果身份类型会按发行方、资产、地域不断增长，历史 ID 永不回收就会把运营变更永久带入交易成本，值得在规模扩大前修复。建议 P2：基于真实 SBT 和最坏调用次数测算一个上限，只约束首次添加，已登记 ID 的权限更新仍可用，并监控当前长度。需要更长期扩容时再考虑有明确语义的删除/分集合机制。

**修复陷阱：不能直接跳过或删除 permissions=NONE 的身份来“优化”。**当前 `hasCredential` 明确独立于权限（L359–364），禁用操作权限并不等于撤销身份；`hasIdentity` 也独立查询登记身份（L349–356）。删除历史 NONE 身份会改变身份可见性，应把“是否有身份”与“是否有操作权限”的集合、查询语义分别设计，并作迁移。治理恶意把上限设成危险值也不是本项的外部攻击论据。

## #13 / 报告 No.5：中心化风险

**结论：仍是协议的既有信任模型，不能按代码缺陷认定“未修复漏洞”。**

代码证据：

- `src/v1/governance/TSVGoverned.sol` L15–24 定义分工角色；L32–36 在初始化时把 default admin 和 upgrade admin 授予传入的 `admin`；L40–41 对升级显式验证 upgrade role。
- Registry L245–247、L324–326：组件绑定和 SBT 配置要求 default admin；L392–394 的 `setTierPolicy` 当前已使用 `SYMBOL_ADMIN_ROLE`；L470–476、L654–656 等资产、池管理入口分别受 symbol role 限制。
- Registry L721–723、L751–755：证券暂停用 HALT_REPORTER_ROLE，全局暂停/恢复分别要求 PAUSER/RESUMER role。
- Registry L276–305：新增 Factory 更换要求 UPGRADE_ADMIN_ROLE、全局暂停、代码存在以及多组件绑定一致性检查，并非普通用户可更换。
- `src/v1/core/TSVVolumeLedgerV1.sol` L44–59：quota/usedWad 更新要求 VOLUME_ORACLE_ROLE，L89–90 升级要求 upgrade role。
- `src/v1/periphery/TSVSwapRouterV1.sol` L99–106：Adapter allowlist 由 default admin 管理。
- `src/v1/periphery/TSVLPManagerV1.sol` L139–143：TSV 强退要求 FORCE_EXIT_ADMIN_ROLE；L180–181：发行方强退先校验 issuer admin。注意当前 TSV 管理员强退分支已取消 LP 的 issuer-eligibility 前置条件，应修正文案，不能继续笼统描述两条路径完全相同。

这里未找到普通用户绕过角色、把权限授予自己或抢先初始化等具体利用路径。上述角色能进行业务治理，是系统设计，不因为权限高就构成低风险代码漏洞。初始化接收一个 `address` 也不能证明它是单签 EOA，该地址完全可能是多签或 timelock；本次没有读取实际角色持有人，不能声称治理措施已经落实或缺失。

**修复价值：治理措施有真实价值，代码上的“去掉管理员”无直接价值。**对合规证券协议，应保留必要的暂停、额度与强退能力；应通过多签、岗位分离、升级延迟（保留应急流程）、关键角色/参数监控、备份和撤销闲置权限降低失陷与误操作风险。已有分角色常量只提供分权能力，不等于部署时确实分权。建议将该 issue 作为接受信任模型及部署验收清单，提交真实多签/角色/升级控制证据后关闭或持续跟踪，不应宣称在本次代码版本中“修复中心化”。

## #20 / 报告 No.6.7：registerPool 重复 listed 检查

**结论：仍存在的低价值优化项，报告的局部冗余判断成立。**

执行路径和证据（Registry）：

1. L583–591：仅绑定的 LPManager 可调用；两侧必须通过 `_assetAllowed`。
2. L854–858：Q 返回 quote registered；W 返回 `config.registered && securities[config.securityId].listed`。
3. L592–595：从同一 `currencyUnderlying -> underlyings` 映射取证券，要求恰好一侧有非零 securityId，并选出股票侧的 securityId。
4. L596–597：再次读取该同一证券的 `listed`，否定则 revert。

在这些步骤之间没有外部调用、没有证券状态写入；正常存储不变量下，L597 检查不可能在 `_assetAllowed` 返回 true 后单独失败。因此移除该行不会放开未上市股票建池。但是这只是重复 warm storage 读取/分支，未测量优化器后的实际 gas 差，且建池不是高频 swap 路径。

**修复价值低，建议 P3/可接受。**可在清理代码时删 L597 并保留未上市股票拒绝建池回归；如果希望使 `registerPool` 的核心不变量局部可见，保留也合理。不属于需要阻断发布的漏洞，更不应删除上游 `_assetAllowed` 或后续 exactly-one-stock 检查来追求同一优化。

## #23 / 报告 No.6.10：setSbtConfig 的 verify 检查

已查看报告原始截图 `In7PbvmSioYqrfxyraHlwHDagqS.png`，红框是 `try ISmartWalletSbtV1(participantSbt).verify(address(this), tokenId)`，不是 `participantSbt != 0` 本身。

**结论：代码仍在；“bindComponents 已完全检查，所以一定冗余”不完全成立，建议保留防御性校验。**

- Registry L256–262：绑定时只尝试 `paused()` 与 `verify(address(this), 0)`，并不枚举未来要配置的 tokenId。
- L329–333：配置某个具体 tokenId 时再次调用 `verify(address(this), tokenId)`；`returns(bool) {}` 没有要求 true，因此它只是“该 ID 的校验调用当前能成功返回合法 bool”的健康检查，不验证 Registry 自身持有身份、也不验证身份曾发行。
- L330 可能拦截自定义/已升级 SBT 在特定 ID 下的 revert 或错误 ABI。SBT 本身是可升级依赖：固定依赖 `SmartWalletSbt.sol` L235–239 允许其 default admin 升级。一次绑定成功不能逻辑上保证后续每个 ID/每个时间点调用均成功。
- 对本次固定 SBT 实现 a4c53ccb，L167–171 的 verify 只读 ERC-1155 balance（非零 Registry 地址、任意 uint256 ID 正常返回），故该检查对当前实现没有增加“tokenId 合法性”约束。

**修复价值：单纯删除很低，保留有 fail-fast 价值。**该调用在管理员登记/修改 ID 时发生，不会在每次交易中额外多一次；它可以在写入 append-only ID 前提前发现当前具体 ID 的异常。对未来可升级/自定义 SBT，删除它还可能允许把会 revert 的 ID 永久追加到全量权限遍历，反而恶化 #10。建议接受/保留并将注释改为健康检查，避免声称它校验 tokenId 存在。即使删除也不是安全修复，不能据此关闭为“漏洞已修复”。

## #24 / 报告 No.6.11：pauseMode 的 & 3

已查看截图 `BwqibEbu6ovHh1xtWAqlTSKpg0d.png`，建议针对 `_getSecurityPauseMode` 中 `return securities[securityId].pauseMode & 3;`。

**结论：表达式仍存在，在当前正常写入不变量下确实可省，但没有证明需要修复。**

- Registry L744–745 仍与截图一致。
- `src/v1/types/TSVTypes.sol` L71–77 将存储字段定义为 uint8 的两位 mask。
- Registry L728 先归一化旧值；L732 的 selectedBits 只可能为 1/2/3（非法枚举值在 ABI 解码时拒绝）；L736 的 OR/AND 操作在旧值 0..3 上闭合；L738 为唯一 pauseMode 直接写入。默认值也是 0。因此，不存在经公开 setter 生成第 2 位以上非零 bit 的路径。
- L455–458 的 getSecurity 和 L706–707 查询使用此 helper；运行业务门禁 L885–889 本来就只检测 TRADE/LP 的对应 bit。
- 现有 `Pauses.t.sol` L94–125 包含独立 bit 模型 fuzz、ALL 开关和未知证券默认值的测试文本，未在本次执行。

**修复价值接近零。**位掩码成本很小，现有表达式让返回值显式归一化，也保持查询在高位异常时和实际门禁关注低位的语义一致；存储迁移/错误升级的问题不能靠这里删 mask 修复。建议按接受的微优化关闭或保留，不必安排独立补丁。若必须改，应在同一状态逻辑整理中处理并保留完整状态转移回归，不能称其为安全问题。

## #25 / 报告 No.6.12：注册函数重复检查

已查看截图 `LWTob1buSoZ8pMx3Mtll9AdLgcf.png`，红框明确是内部 `_requireEnvironment()` 和 `!securities[registerParam.securityId].listed`，不是 `currencyUnderlying[currency] != 0`。

**结论：当前单调用点下这两处检查仍重复，属于低价值可选整理。**

- Registry L470–491：外部 `registerPermissionedCurrency` 校验 role/reason/securityId，L480 已调用 `_requireEnvironment()`。新证券分支 L482–487 直接设置 listed=true；既有证券分支 L488–489 在 !listed 时 revert。随后才调用内部 helper。
- Registry L815–821：内部 helper 又检查 `_requireEnvironment()` 与证券 listed；L803–805 显示环境检查只是 Factory 地址非零。
- 全文件只有 L491 这一个 `_registerPermissionedCurrency` 调用点；外部环境检查与内部检查之间只有内部 tier 状态更新和事件，没有外部调用，不能重入改变 Factory/listed。因此在当前调用图上重复部分不会独立拒绝任何请求。
- 同一个 if 中的 `currencyUnderlying[currency] != address(0)` 是包装币重复注册防护，上游没有替代它，必须保留。后续 canonicalUnderlying 绑定一致性及 adapter 验证也均非本条建议的删除范围。

**修复价值低，P3 或接受保留。**管理员注册资产的频次低，重复条件使 helper 的预置条件易读，未来新增内部调用点时仍有保护。若选择精简，优先二选一地明确校验职责：让 helper 负责，移除外层重复环境检查；或者在外层保持保证并给 helper 写明前置条件，只删内部重复部分。两种方式必须保留外层新建/已存在证券及错误参数的完整语义，不宜为微量 gas 改动任何权限、存储布局或事件时序。

## 额外测试文本观察（不计入这 6 个问题）

固定 main 的 `test/unit/v1/registry/Permissions.t.sol` L83–99 仍期待仅拥有 SYMBOL_ADMIN_ROLE 的 operator 调用 `setTierPolicy` 被 DEFAULT_ADMIN_ROLE 拒绝，然而当前 Registry L392–394 已将该入口改为 SYMBOL_ADMIN_ROLE。此用例文本与代码不一致，测试若执行很可能在这里失败；这不能被误认为上述优化项的复现失败或新权限绕过。主线程需要在测试报告里记录实际执行结果。
