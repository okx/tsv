# TSV V1 当前测试维护规格

本文规定新增/修改测试时应保护的当前代码行为。实际 suites、fixtures 和执行命令列于 [`../test/README.md`](../test/README.md)；测试文件是执行证据，本文件不是另一套 ABI 来源。

## 1. 状态和准入

修改 Registry、Hook 或 `PermissionedValidationLib` 时，测试应覆盖：

- 单次组件绑定、Factory/PM/SBT 依赖校验及角色拒绝；
- W→U→securityId canonical 关系，W/Q 身份区分、decimals、legal-share adapter 绑定和多 W 共用 U；
- 首次 security+tier slot 与后续追加 W 的差异；
- PoolKey 完整身份、必须恰一侧 W、一侧 Q，Hook/PoolManager 参数、重复池拒绝；
- `LIST`/`PAUSE`/`DELIST` lifecycle、NFT count、证券暂停模式和单独的全局暂停门禁；
- SBT identities 权限并集、SBT paused 返回 NONE、无权限/未配置身份的失败行为。

测试不能假设 disabled U/Q 会关闭旧池，不能假设 relist security 会自动恢复 DELIST 池，也不能将 `isTradable`/`isLPAllowed` 当作包含 global pause 的完整执行判断。

## 2. Ledger 和 Hook 记账

新增 quota 测试应按代码验证直接值语义，而不是 ADTV/Tier 公式：

- quota 按 securityId + fixed EST epoch day 存储，缺省为 0；
- `setQuota` 保留 usedWad；`setUsedWad` 可调低、设零或高于 quota；
- 空数组、重复 day 和输入顺序按循环逐项写入；
- `recordSwap` 仅允许 Registry 当前 Hook，检查 delta 方向和唯一非零股票 legal-share leg；超额回滚；
- Hook 只记 PoolManager 的实际 delta；验证 Router caller、pool gate、global pause 及 expectedMultiplier 执行快照；Hook 返回零 delta，donate 拒绝。

当前日计算为 `(block.timestamp - 5 hours) / 1 days`，固定 UTC-5。测试应使用链上函数或精确 epoch 计算，不能采用 DST-aware 时区结果。

## 3. Router 和 W/U/Q 结算

交易集成应验证：

- Adapter 路径的 Router 调用者是 allowlist 中的合约，participant 单独作为 SBT/issuer 权限主体；caller-bound 路径强制 `participant == payer == recipient == msg.sender` 且不依赖 Adapter allowlist；
- exact-input 请求金额范围、deadline、最小输出和全额 input fill；部分成交整体回滚；
- W 输入时 U→W→PoolManager；W 输出时 W→U；Q 直接作为 quote settlement；
- `expectedMultiplier` 在 Hook beforeSwap/afterSwap 均有效；过期快照回滚；
- actual pool delta 只记一次，quota 和失败回滚覆盖同一 security 的多个池。

不要增加 exact-output、multi-hop、ADTV report 或 partial-fill refund 成功断言，除非相应源码能力先被实现。

## 4. LP、升级和测试替身

LP 测试应区分普通 position action、settlement action 和授权 unwind：

- 普通 position 检查 executor 与 NFT owner 的 SBT LP permission、issuer/hook 资格和 pool gate；
- 两个 `*_FROM_DELTAS` mint/increase action 应拒绝；`withdrawClaim` 应拒绝；
- mint/burn 只在成功后增减 Registry NFT count；DELlST 限制和 pause 边界按 Registry/Hook/Manager 分层核对；
- unwind callback 只允许授权的 full burn/settlement，不允许普通 callback 重用；全局 pause 阻止 unwind；
- 对强退还应覆盖 quote receiver 拒绝和可能超出 `int128` 的完整 delta 风险；当前无有权 partial-unwind 入口。

使用真实本地 PoolManager 的 integration suites 验证跨合约结算。使用 mock 的 library/consumer unit suites 只证明其隔离范围内的逻辑，不应将 mock 断言写成生产资产或全拓扑证据。当前没有 X Layer fork `.t.sol`，需新增该类 suite 才能声明链上集成覆盖。

## 5. 运行和结果记录

按 [`test/README.md`](../test/README.md) 和 `Makefile` 选择命令。修改测试后执行适用的 Forge suites、格式/布局检查，并在报告中标明 commit、命令和结果。文档中的历史审计运行数不能复制为当前提交的通过数。
