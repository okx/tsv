## 当前处理结果：已实施优化，已关闭

**最终结论为“已实施全部 active 上下文清零”，不是“接受现状、不做修改”。** 早期“不实施额外清零”的评论只保留为历史讨论，已被项目方后续决定和实际提交取代。

### 实施内容

两个修复分支的 `_swap()` 均在 `PoolManager.unlock()` 完整返回后，先将 `activeAmountIn/activeAmountOut` 缓存为 `actualIn/actualOut`，完成最终输入校验，再清零以下六个字段：

- `activeParticipant`
- `activeRecipient`
- `activeInputCurrency`
- `activePayer`
- `activeAmountIn`
- `activeAmountOut`

返回金额保持正确，回调期间仍使用本次完整上下文。存储字段声明及顺序不变，未修改权限、重入锁或两个版本各自的收款策略。架构文档已同步更新。

### 已提交并推送

| 版本线 | 修复分支 | 提交 |
|---|---|---|
| audit（正确基线 `42a690d682536adb603b9adbf4eb4af1ce7dd1cb`） | `audit/2026-10-27-6402443-fix` | [e1011f8323aee59f3dcbe40b5e5840c95959c26a](https://gitlab.okg.com/web3-dex/tsv/-/commit/e1011f8323aee59f3dcbe40b5e5840c95959c26a) |
| main（基线 `90929552fd557fd67b9debafa905bafffb40ed86`） | `main-audit` | [a004092110b0812e9da43e14c8ac077dcf33136b](https://gitlab.okg.com/web3-dex/tsv/-/commit/a004092110b0812e9da43e14c8ac077dcf33136b) |

上述实现已在两个修复分支落地，尚未直接合并到原始 main；合约当前未部署。

### 验证结果

审计修复分支 **19/19**、main-audit **21/21**，合计 **40 项针对性测试通过，0 失败**，并通过 `git diff --check`。

覆盖三个交易入口的买卖方向、返回值与实际到账、不同参与者连续交易、成功后六字段归零、失败交易回滚、回调期间有效上下文与重入拒绝。测试运行范围为 `TSVSwapContextCleanupTest`、`TSVContractDirectSwapTest`、`TSVWrappedSwapTest`，不是全套回归。

完整实施过程、运行配置及日志：[最终修复记录](https://gitlab.okg.com/web3-dex/tsv/-/issues/27#note_11528417)。

---

来源：[DEX - TSV 合约审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd)。原报告快照：2026-10-27T09:27:51Z。初次登记的 `6402443` 审计 commit 已由项目方更正为上述 `42a690d`；分支名称保留历史命名。以下保留原报告问题内容。

## 报告原文

### No.6: 优化建议【其他优化建议】（所有审计人员）

其他优化项列表，第 14 项

**No**

14

**代码位置**

src/v1/periphery/TSVSwapRouterV1.sol

**描述**

![VI8EbzzwwoOsAExBj8MlmvCtgqg](/uploads/02bc3060e0d5de8cbe368ef25e5f534a/VI8EbzzwwoOsAExBj8MlmvCtgqg.png) (报告原图 1262x462)

**建议**

swap操作结束建议删除activeParticipant/activeRecipient/activeInputCurrency/activePayer这些状态变量

**反馈**

（原文为空）