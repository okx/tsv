# LP 相关既有审计问题定向复核

固定代码版本：`90929552fd557fd67b9debafa905bafffb40ed86`（本次远端 main）。结论基于该版本的源码、入口及依赖调用链，未将本地 HEAD 或脏子模块作为目标。本文件仅分析既有问题，不是全仓安全审计；未运行测试，由主线程统一补充测试证据。

| Issue | 原报告 | 当前判断 | 修复价值及建议优先级 |
|---|---|---|---|
| #9 | No.1 回调致强退余额差下溢 | 仍成立，真实强退 DoS | 高；P1，建议修复 |
| #11 | No.3 W 余额导致事件漏报 U | 已修复 | 无需重复修改；复核回归后可关闭 |
| #14 | No.6.1 主合约不需 reserve gap | 代码仍有 gap；原建议的“仅抽象合约需要”论断不成立 | 无安全修复价值，建议解释后关闭 |
| #15 | No.6.2 constructor/initialize Registry 重复 | 仍存在配置冗余，但不是代理未初始化漏洞 | 低；P3 可清理 constructor 配置，勿直接将 proxy storage 字段改 immutable |
| #16 | No.6.3 强退临时状态魔法值 | 仍存在，可读性建议成立 | 低；P3 顺手整理 |
| #18 | No.6.5 不支持的 from-deltas 分支 | 仍存在不可达分支，入口已拒绝 | 低；P3 删除死分支，非安全修复 |
| #19 | No.6.6 MINT_6909/UNWIND 重复拒绝 | 最终拒绝结果确有重叠；提前拒绝有意图/错误语义价值 | 很低；保留也合理，不建议为 gas 单独改动 |
| #28 | No.6.15 approval 应校验 SBT | approval 未检查，但执行时已有权限检查；无法据此证明绕过 | 无需安全修复；若业务另有“委托也须持证”要求，再统一设计 |
| #29 | 问题1 累计原始本金超 int128 单次强退 | 条件成立，代码未消除；现实触发依赖极大原始资产量 | 中等、条件化；P2 先证明准入上界；若不能排除再做限额/分段退出设计 |

优先级是本次工程建议，P1=应优先修改，P2=按业务风险安排，P3=维护清理；不自动改变原审计风险级别。

## #9 — 仍成立，建议优先修复

**源码证据。** `TSVLPManagerLib.sol:125–132` 在 unsubscribe 前读取 LP 的实际结算 U/Q 余额；`153–162` 在销毁和交付后直接计算 `settlement.balanceOf(lp) - before`。发行方路径的 `185–188`、`220–230` 同样先快照再回调、最后作无保护减法。`451–470` 的 unsubscribe 确实会调用 LP 选择的 Subscriber；catch 仅吞掉回调本身的 revert，不阻断回调已成功完成的普通 ERC20 转出。

**可达路径。** 合法 LP 可以是实现 ISubscriber 的合约钱包，也可授权 Subscriber 转走自己原有 Q。该 LP 正常持仓并将该合约设为 subscriber（`Notifier.sol:43–63` 只校验 NFT owner/approval 和 PM locked）。强退前它持有 1,000 Q，强退仓位仅将收到 10 Q；在 notifyUnsubscribe 中转走原有 1,000 Q 并正常返回，最终余额 10 Q，汇总事件参数计算 `10 - 1,000` 触发 Panic(0x11)。这些 Q 不必有转账回调、扣费等特殊行为，标准 ERC20 即可。管理器的 isNotLocked 不限制外部钱包转自己的 Q，角色检查也只约束发起强退的人，不约束被动回调。

**影响。** 整笔回滚恢复 NFT、subscription、池计数及 Q 余额，LP 下次仍可重复该行为。虽然攻击者自己的仓位保持未退出，影响是管理方无法强退和潜在阻塞要求计数清零的池/证券下架，因此不只是自伤。

**价值与建议。** 保持为实际可用性问题，P1。最低改法是把退出前快照移到 unsubscribe 及重挂清理之后；汇总事件仍建议用非负安全差值，避免观察性事件造成核心操作回滚。余额下降时不能 unchecked 后伪造巨大数值；可返回 0 并额外记录异常，或使用可靠的实际交付记账。若允许任意带回调的出款资产，仅挪动快照不覆盖交付阶段回调转账，安全差值/交付记账更稳健。修复需同时覆盖 TSV 和发行方两个事件分支、LP/发行方到账路径；回归应断言恶意 unsubscribe 后强退完成、NFT 和池计数正确。

## #11 — 已修复，可在回归复核后关闭

**源码证据。** `TSVLPManagerLib.sol:125–129`、`182–185` 先解析 `settlement0/1`；`236–242` 的 `_settlementCurrency` 调用 Factory 的 `verifiedPermissionsAdapterOf(W)`，返回 U；无 underlying 时才返回原 currency。随后所有 recipient snapshots 及 TSV 事件末端余额都用已解析的结算资产。

**验证依据。** 当前测试 `LPLinkedLibraries.t.sol:43–112` 故意让 W 的 LP 和发行方余额保持 0，断言两种汇总事件仍报告 U；`114–131` 覆盖发行方 fallback 到账，`135–141` 是对应观测余额 mock。修复提交为 `8fbabc5`。本分工仅确认测试存在和源码意图，不能声称已实际跑过。

**剩余边界。** 事件的 token0/token1 仍表示池中 W/Q，金额表示结算 U/Q 原始单位；这是代码 `45/58` 已明示的事件格式，接入方应映射资产。#9 的无保护减法仍在，不能把本项修复当作 #9 也已修复。

## #14 — 原建议论断不成立，无需按其删除 gap

**源码证据。** `TSVLPManagerV1.sol:63–65` 仍保留 storage Registry 后的 `uint256[48] private __gap`，这是可升级代理实现。固定数组预留存储布局不会在部署时逐槽 SSTORE 48 个零，因此不存在由此必然造成的大额运行 gas 问题。

**判断。** “只有抽象合约才需要 reserve gap”不是有效规则。抽象基类使用 gap 常见，是为了给子类留出相对稳定位置；具体可升级实现同样可以选择预留 slot，未来 V2 可能继承该实现。当前实现作为 leaf 时，append-only 增加字段并不强制要求 gap，因此 gap 可以说“不是必需”，但不能说“错误”。没有权限绕过、资产损失或实际 DoS 路径。

**建议。** 无需安全修复；答复“保留为升级布局约定”并关闭该优化项即可。如果决定采用另一种布局策略，应通过完整 storage-layout diff 有意消费/缩减 gap，而不是机械按报告删除。尤其不能把本项同 Registry/Quota 的真实 storage 变更混为一谈。

## #15 — 配置冗余仍在，但当前 proxy 初始化正确

**源码证据。** `TSVLPManagerV1.sol:79–101` 的 constructor 校验 `_registry` 合约代码并写 implementation storage；`106–108` 的 initializer 再校验并写 proxy storage。constructor 同时 `_disableInitializers()`，因此实现合约不能被重新初始化；proxy 的 ERC721 状态也在 initializer 明确初始化。

**判断。** 报告关于“构造 storage 赋值不会自动初始化 proxy”的描述正确，但代码没有误依赖这种行为；proxy 正确使用 initialize。问题是多一个实现合约参数会造成工具/部署认知成本，可以传入与 proxy initializer 不同的 Registry，但这个 implementation storage 值不会控制 proxy 的日常权限。

**建议。** P3 可删除 constructor 的 Registry 参数和实现合约存储赋值，将配置来源集中于 atomic proxy initialize，同时更新部署脚本/构造参数。不要为了消除冗余就直接将已部署 proxy 的 storage `registry` 改成 immutable：那会把 Registry 绑定改为实现级配置，改变升级/校验语义且需要独立 storage/部署兼容评估。未发现当前授权漏洞，不应按安全修复阻塞发布。

## #16 — 魔法值仍在，可读性清理有低成本价值

**源码证据。** `TSVLPManagerV1.sol:338` 在授权 burn 时写 `bytes32(uint256(1))`，`352` 以同一值判断 `isUnwindActive`。整个授权 callback 先在 `323–327` 比较并消费 exact callback hash，burn 后在 `340` 归零；零/哈希/活动状态区分与注释匹配。

**判断及价值。** 目前两处一致，没有由重复字面量直接构成的权限绕过。定义共享 `UNWIND_ACTIVE_FLAG` 便于将来保持两处同步，属于 P3 可读性维护；不要为这项宣称修复了强退授权漏洞。不要改动回调哈希承诺、零态、burn 前后恢复的实际时序。

## #18 — 确有不可达分支，不是可利用的功能入口

**源码证据。** 报告截图指 `TSVLPManagerLib.sol:379–382` 的 `MINT_POSITION_FROM_DELTAS` 分支。当前 `TSVLPManagerV1.sol:356–364` 只有 MINT/INCREASE/DECREASE/BURN 四种正常 position actions 调到 `_handlePositionAction`；其他 action 进入 settlement validator，`TSVLPManagerLib.sol:411–415` allowlist 不含任何 FROM_DELTAS，故 revert。授权强退 dispatcher（`322–347`）也不接受 FROM_DELTAS。

**验证依据。** `LPLinkedLibraries.t.sol:298–328` 明确覆盖两个 modify entry points 对 INCREASE_FROM_DELTAS / MINT_FROM_DELTAS 的 UnsupportedAction 回滚。

**建议。** P3 可以删掉 library 的未使用分支，减少维护误导和 bytecode；不应开放外层 dispatcher 使其“有用”。当前拒绝逻辑有效，不需安全修复，也不应以此声称 FROM_DELTAS 旧有 sandwich 风险可经 TSV 到达。

## #19 — 逻辑重叠存在，但提前拒绝并非必须移除

**源码证据。** `TSVLPManagerLib.sol:398–399` 以 Unauthorized 提前拒绝普通用户执行 MINT_6909/UNWIND_WITH_FALLBACK；同函数 `411–415` 的 settlement allowlist 也不会允许这两种 action。若删掉前者，最终仍会在后者拒绝，但会先执行 `401` 的外部 SBT 权限检查，且错误从 Unauthorized 变为 UnsupportedAction（或先受 SBT 失败影响）。

**判断。** 报告说最终允许/拒绝结果重复是对的，但早返回表达“claims 专用于授权 unwind”的安全边界，省掉无意义的外部权限查询，具有代码意图和失败语义价值。未发现漏洞，也未测到应该优先优化的 gas 浪费。

**建议。** 可说明提前拒绝是有意为之而关闭优化项。若统一整顿 allowlist/error 设计，可重构一次集中判定，保留两 action 仅经承诺强退 callback 可达的边界；无需为该项单独变更。

## #28 — 无 SBT 的 approval 仍允许，但无法绕过执行时合规门禁

**源码证据。** `TSVLPManagerV1.sol:227–252` 的 approve/setApprovalForAll/permit/permitForAll 只加暂停门禁，delegate 关系的确不要求 SBT。执行 position action 时，`TSVLPManagerLib.sol:373/388` 分别检查 executor 和 NFT owner 的 `LIQUIDITY_ALLOWED` SBT，`389` 检查池生命周期门禁；正常 settlement 在 `401` 检查 executor，显式 recipient 在 `402–410` 再检查 recipient。底层 `PositionManager.sol:158–160/299/347/424` 仍保留 NFT approval 检查；`PermissionedPositionManager.sol:145–154` 禁止 NFT 转让。

**可达性判断。** 给一个无 SBT 地址 approve 并不等于它可以增/减仓、burn 或收资产：未持证 executor 在库的第一道检查就被挡住。approve 也不能赋予 FORCE_EXIT_ADMIN_ROLE 或 issuer 身份。subscribe/unsubscribe 使用 NFT 授权而非 SBT，但那是用户主动授权的通知管理能力，不等于获得 liquidity 权限；本项没有给出由此绕过既有资产合规边界的路径。

**建议。** 不作为安全漏洞修复，解释“委托关系与执行时资格分离”后关闭/接受。若业务明确要求“建立委托时对方也必须持证”，可作为产品策略变更另做；应同时覆盖四条 approval/permit 路径，保留 spender=0、approved=false 等撤销能力。只在 approve 时校验也不能替代每次执行校验，因为 SBT/权限会在授权后撤销；额外审批门禁还会妨碍给未申请 SBT 的工具合约预授权。

## #29 — 极大原始资产量下条件成立，优先明确准入上界

**源码证据。** 两强退路径最终都调用 `PositionManager.sol:422–448` 的 `_burn`，读取并一次性移除该 tokenId 全部 liquidity。核心 `lib/v4-core/src/libraries/Pool.sol:206–235` 把整笔本金 token delta 转为 int128；同文件 `189–192` 也将累计 feesOwed 转 int128。每次增仓单次的 delta 上限和每 tick 的 liquidity cap 不会普遍保证同一 NFT 的累计 raw token 本金小于 int128.max。`PermissionedValidationLib.sol:160–166` 的 decimals≤18 不等价于 totalSupply/raw amount 上限。

**具体条件示例。** 取 tickSpacing=60，range [-887220,-887160]，当前价在 lower 或其下，token0 单边；每次增加 `2**71` liquidity，单次 amount0 约为 `1.30e38`，小于 int128.max≈`1.70e38`；两次合计约 `2.60e38`，超过该上限。总 liquidity `2**72` 约 `4.72e21`，远低于该 tickSpacing 的 per-tick liquidity cap（约 `1.15e34`）。因此不能以 core liquidity cap 或单次 add 合法为理由排除累计本金问题。具体精确整数额应以主线程 TickMath/SqrtPriceMath 回归为准，此处分工未跑代码测试。

**现实前提与严重性。** 构造要求准入币能提供超过 `1.7e38` raw units 的单一仓位资产；18 decimals 时已相当于约 `1.7e20` 个完整 token，6 decimals 时约 `1.7e32` 个。这远超通常证券/主流稳定币供应规模。源码虽不排除，但不能据此声称当前实际获准入资产/线上仓位已能触发，也不能宣称任意用户可低成本攻击。若已证明所有准入资产未来发行上限均不足此量，理论本金路径无现实影响。

**修复价值。** 条件化 P2。建议先形成资产准入/仓位最坏价格 raw amount 上界及证据，尤其考虑未来增发、替换资产和 decimals。若业务上界排除本金及累计费用超限，可记录接受的工程边界，不必为理论极值直接引入复杂分段强退。若无法建立该保证，应该约束 cumulative raw 风险或设计授权分段减仓/结算及最终 burn；仅加一条注释不算修复。累计 fees 的 int128 限制是另一条相关边界，单纯分段本金并不会自动拆开 core 一次计提的全部费用，设计应覆盖收费结算与异常恢复。当前源码 NatSpec 已明确披露上界风险，但披露不改变可达性。
