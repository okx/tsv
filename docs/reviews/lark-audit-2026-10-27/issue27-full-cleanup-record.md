<!-- tsv-issue27-full-context-cleanup-implemented-20261029 -->
## 后续决定及实施记录：六个 active 字段全部清零

项目方在进一步讨论后明确选择实施清理，要求 activeAmountIn/activeAmountOut 同时清零。本记录取代此前“保留三个地址旧值、不实施额外清零”的处理决定；原分析作为历史讨论保留。

### 实现方式

两个修复分支的 `_swap()` 都统一为：

```solidity
poolManager.unlock(payload);
actualIn = activeAmountIn;
actualOut = activeAmountOut;
if (actualIn != request.amountSpecified) revert SlippageExceeded();
// V4 exact-input action enforces the input and minimum-output limits.
// Callbacks are complete and return amounts are cached; clear the full swap context.
activeParticipant = address(0);
activeRecipient = address(0);
activeInputCurrency = address(0);
activePayer = address(0);
activeAmountIn = 0;
activeAmountOut = 0;
```

- PoolManager 全部回调结束后才清理，回调期间的身份、收款人、币种、付款方及金额上下文保持有效。
- actualIn/actualOut 先缓存到返回变量，再清理存储，实际返回金额不会变成零。
- 最终输入检查先完成，成功交易才走清理；失败交易通过 EVM 回滚恢复调用前状态。
- 未删除或重排任何 storage 字段，未新增生产 getter；角色、入口约束、重入锁及结算逻辑保持原有规则。
- 同步更新架构文档说明上下文生命周期。此为部署前代码调整，不涉及已部署合约的升级成本；也未宣称清零一定节省 gas。

### 提交

- `audit/2026-10-27-6402443-fix`：[e1011f8](https://gitlab.okg.com/web3-dex/tsv/-/commit/e1011f8323aee59f3dcbe40b5e5840c95959c26a)，19 项针对性测试通过。
- `main-audit`：[a004092](https://gitlab.okg.com/web3-dex/tsv/-/commit/a004092110b0812e9da43e14c8ac077dcf33136b)，21 项针对性测试通过。

两个提交均已推送至对应远端修复分支，原始审计基线及 main 没有被直接修改。

### 验证

新增 SwapContextCleanup 集成用例使用真实 PoolManager/Router/Hook/Registry 路径，覆盖：

1. 三个交易入口的买入、卖出共六种路径，断言实际付款/到账与返回金额一致，成功后六个私有存储字段均为零。
2. 不同 participant 连续交易，分别付款和收款，无上一笔上下文串用。
3. 成功后再发生额度超限的失败交易，完整匹配 V4 包装的 QuotaExceeded 错误，并核对余额、池状态及空上下文保持不变。
4. 结算 token 回调中仍可读取当前身份、输入币、付款方及输入金额，嵌套 swap 仍被 ContractLocked 拒绝；回调返回后全部清理。

同时运行既有 ContractDirectSwap 和 WrappedSwap 回归。审计分支中两项旧测试原先使用任意收款人，与正确 audit 基线要求 recipient=participant 不一致；本次仅调整测试以符合该规则，并补充两个方向均拒绝无关 recipient 的回归，没有放宽生产收款规则。两个版本的收款策略差异保持原样。

最终：审计修复分支 **19/19**、main-audit **21/21**，合计 **40 项通过、0 失败**。通过 git diff --check。

测试使用 FOUNDRY_PROFILE=local 和 CLI @uniswap/v4-core/src/ remapping；跳过 DexAdapter.t.sol、尚未配齐 import 的 SecuritizeTSVChecker.sol 及脚本。结果为上述三个 suite 的针对性回归，不是完整测试套件或真实 DexRouter 端到端认证。

日志：
- [issue27-audit-cleanup-tests.log](/uploads/13ea191ed7cd69f28dc951ca7f605309/issue27-audit-cleanup-tests.log)
- [issue27-main-cleanup-tests.log](/uploads/8f2bdd6ff6797d1921c8c9942b86d713/issue27-main-cleanup-tests.log)
