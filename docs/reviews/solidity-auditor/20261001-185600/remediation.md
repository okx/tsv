# Solidity Auditor 三轮审计：修复与剩余风险

审计于 2026-10-01 完成，共三轮，每轮 12 个专项审查 agent。机器生成的原始报告及逐轮结果见同目录 `full-report.md` 和 `run-1.md` 至 `run-3.md`。审计基线 Git HEAD 为 `f597879`；审计时的工作区已包含 Hook/Router 简化变更。以下 LP 修复是在三轮审计结束后完成的。

## 已修复

`TSVLPManagerV1._settle` 现在在 `delta >= 0` 时校验 `minOut`。若流动性操作某一侧的 delta 为零，正的 `minPoolOut` 会回滚，不能再跳过用户设定的最低输出。

回归测试 `testClosePositionEnforcesMinimumForZeroDeltaCurrency` 在区间边界创建单侧仓位，要求零输出侧至少收到 1 个 raw 单位，并确认 `SlippageExceeded` 回滚且仓位和 Receipt 保留。

## 仍需按运维流程控制

审计确认：更换某个 Token 的法律股数 Adapter 后，Ledger 会将新单位成交量加到当日已有的旧单位用量中。Registry 允许 Token 级暂停满足替换门槛，也没有链上次日恢复门槛。若有权限的角色在次日和新单位报告就绪前恢复交易，交易者可能使用不匹配的旧额度。

V1 的已批准流程依赖运营人员执行以下步骤；当前合约不强制完整等待和报告匹配条件：

1. 在法律单位生效前暂停整个 `securityId`，并对需替换 Adapter 的 Currency 另加 Token 暂停或使用全局暂停。
2. 替换 Adapter 后保持证券暂停，至少等到下一个 UTC 计量日开始。
3. 提交适用于新单位的 ADTV，并检查或清理不兼容的 quota；确认该证券准备恢复的所有 Token 均输出相同法律单位。
4. 核对 Adapter 快照、报告和审批证据后，再清除暂停。

因此该项风险由角色流程缓解，但尚无链上防错机制。若要求合约本身阻止过早恢复，需要增加安全级法律单位版本/生效门槛，并将报告绑定到该单位版本。

## 其他待核实线索

- Adapter 或池内 Token 若使用代理，当前运行时代码哈希不能证明其实现逻辑保持不变；需核实实际准入部署是否使用可升级代理。
- Security 重新上市保留旧市场状态；需确认报告流程是否要求重新提交 OPEN 报告。
- DataInbox 接受 `uint64.max` 序号后，该报告键无法再接受更高序号；触发者需要受信任的报告角色，列为待跟踪线索。

同一法律单位内普通 multiplier 更新符合准入标准，不视为单位混用漏洞；审计中出现的这类候选项未纳入漏洞报告。

## 验证

- `FOUNDRY_PROFILE=local forge test --match-path test/integration/local/TSVProtocolLocal.t.sol`：23 passed。
- `FOUNDRY_PROFILE=unit forge test`：40 passed。
