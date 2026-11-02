<!-- tsv-issue27-superseded-by-implementation -->
> **后续决定已变更：项目方已选择清零全部六个 active 字段，两个修复分支均已实施。请以[后续实施记录](https://gitlab.okg.com/web3-dex/tsv/-/issues/27#note_11528417)为当前结论。以下“不实施清零”内容仅保留为历史讨论。**

<!-- tsv-issue27-accept-current-context-lifecycle-20261029 -->
## 处理结论：保留当前上下文生命周期，不实施额外清零，本项关闭

项目方已确认接受当前设计。**本项按“已解释并接受优化建议，无需代码修改”关闭，不标记为已实施全部 active 字段清零的修复。**

> **2026-10-29 更正：项目方确认当前合约尚未部署。原“生产部署/升级成本”理由不适用，已删除并改正；本评论其余代码隔离分析及未测量 gas 差的事实保持不变。**

### 1. 两个基线的实际状态

本次讨论采用的正确 audit 基线为 `42a690d682536adb603b9adbf4eb4af1ce7dd1cb`，main 基线为 `90929552fd557fd67b9debafa905bafffb40ed86`。两者在本项上下文管理上的行为一致：

| 字段 | swap 成功结束后的状态 |
|---|---|
| activeParticipant | 保留最近一笔值 |
| activeRecipient | 保留最近一笔值 |
| activeInputCurrency | 保留最近一笔值 |
| activePayer | 已在 poolManager.unlock 返回后设置为 address(0) |

因此原建议将 activePayer 也列为需要补清理的字段并不准确；剩余三个字段保留旧值的现象确实存在，但“值仍在 storage”不等于“上一笔交易的授权或收款信息仍可生效”。

代码：[audit 的上下文赋值、unlock 与清理](https://gitlab.okg.com/web3-dex/tsv/-/blob/42a690d682536adb603b9adbf4eb4af1ce7dd1cb/src/v1/periphery/TSVSwapRouterV1.sol#L239)、[main 对应逻辑](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/periphery/TSVSwapRouterV1.sol#L248)。

### 2. 现有隔离机制足以限制旧值的用途

1. **每笔新交易先覆盖上下文，再执行付款和 PoolManager.unlock。** 新交易的 participant、recipient、inputCurrency、payer 都来自本笔请求与入口约束；不存在正常下一笔 swap 自动沿用上一笔值的路径。
2. **交易空闲时不暴露旧 participant 为有效身份。** msgSender() 明确以 locker 为门禁，locker=0 时返回 address(0)，而不是直接返回 storage 中最近一笔 participant。[audit msgSender](https://gitlab.okg.com/web3-dex/tsv/-/blob/42a690d682536adb603b9adbf4eb4af1ce7dd1cb/src/v1/periphery/TSVSwapRouterV1.sol#L167)、[main msgSender](https://gitlab.okg.com/web3-dex/tsv/-/blob/90929552fd557fd67b9debafa905bafffb40ed86/src/v1/periphery/TSVSwapRouterV1.sol#L176)。
3. **结算回调仅接受固定 PoolManager。** 普通外部地址不能直接调用 unlockCallback，让旧 recipient/payer 被用于任意结算。[SafeCallback](https://gitlab.okg.com/web3-dex/tsv/-/blob/42a690d682536adb603b9adbf4eb4af1ce7dd1cb/src/v1/vendor/v4-router/base/SafeCallback.sol#L15)。
4. **三个 swap 入口均使用 isNotLocked。** 同一交易执行期间不能嵌套开启另一笔 swap 覆盖上下文；固定 v4-periphery 的锁在进入时设置，退出时清零。两个主仓基线使用相同的 v4-periphery commit `9969eec44cfdf07e24b41de47f40276a58401976`。

综合上述路径，本次未发现攻击者复用旧 participant、旧 recipient 或旧 inputCurrency 获取权限、重定向资金或发起扣款的可执行路径。本项不作为已确认的授权或结算漏洞处理。

### 3. 不额外清零的成本与收益判断

**Gas：需要完整周期实测，不能机械判断清零必然更省或必然更贵。**

当前是下一笔交易将旧非零地址直接覆盖为本笔地址；全部清零则会增加交易末尾的存储清理，并使下一笔从零重新写入地址。清零可能产生退款，但实际退款受限制；下一笔写入成本、原始槽值及执行路径也会影响最终结果。本次没有做两种实现的 gas benchmark，不声称已经证明某个固定净 gas 差。

额外清零具有明确的维护可读性收益，但没有在当前权限隔离下证明新增安全收益；也没有实测证明它具有净 gas 收益。

**执行顺序：上下文在回调完成前仍是必要数据。**

participant 用于权限主体识别、recipient 用于交付、inputCurrency 用于结算一致性检查、payer 用于付款。任何清理都必须放在完整 unlock/回调链结束之后。若在统一清理时同时处理 activeAmountIn/Out，还需要先缓存返回金额。调整生命周期需要回归正常交换、失败回滚、重入及不同 Adapter 入口，不能仅增加 delete 后假定没有影响。

**当前尚未部署：生产升级成本不适用于本项目，不作为不优化的理由。**

根据项目方补充，目前合约尚未部署。原评论以已部署代理、生产发布窗口和既有代理存储兼容性说明本项改动成本，带入了不适用的前提，现予以撤回。该优化完全可以在首次部署前实施，不存在为本项升级现有生产合约的成本。

是否清零应根据当前代码的安全收益、维护可读性和实测 gas 决定：现有上下文隔离下尚未发现必须依赖额外清零才能阻断的攻击路径；清零可以提高生命周期的可读性；净 gas 差尚未测量，不能据此断言一定更贵或更省。因此“不清零”是基于目前安全必要性不足及尚无性能收益证据的可选设计决定，而不是由生产升级成本阻止修改。

如决定在首次部署前清零，可直接安排实现和回归，验证清理发生在完整回调结束之后，且不影响返回值。清理运行时数据应使用赋零/delete 等方式，不需要删除字段声明；首次部署前若另行调整存储布局，应作为设计变更统一核对，不套用已部署代理的迁移前提。

### 4. 最终决定与后续约束

- 保留当前 activePayer 在 unlock 返回后清零的逻辑。
- activeParticipant、activeRecipient、activeInputCurrency 保持当前行为，不增加统一清零。
- 继续依赖并保持：新交易先覆盖上下文、空闲 msgSender 返回零、onlyPoolManager 回调限制及交易入口重入锁。
- 未来若新增读取这些字段的入口、调整回调或锁的生命周期，应重新核对旧值是否能在交易外生效；不能未经分析扩展其用途。
- 若未来进行交易上下文或瞬态存储的整体重构，可在有 benchmark 与完整回归的前提下统一处理，无需为本项单独改动。

**关闭理由：现有机制未形成可利用的旧上下文复用路径；额外清零的安全与性能收益未获证明，属于可接受的不实施优化项。** 原报告正文及风险分类保留作为审计历史记录。