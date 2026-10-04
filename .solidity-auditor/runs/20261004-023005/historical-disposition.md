# 既有 ledger 记录的本次处置

本次启动时 `.solidity-auditor/memory.tsv` 有 13 条历史记录。ledger 记录历史，不表示本次确认仍有 13 个问题。技能只累计本次通过判定的 finding/lead，不自动删除已修复、旧版本或不再适用的记录。本次为显式目录范围审查，未执行全仓库名称剪枝。

下表解释本次未重新上报的原因；完整逐轮判定见 `gate-checks-run-*.md`。对外部升级、发行方语义、报告源和部署产物的信任边界，本次不提供外部仓库安全结论。

| 历史类别 / 位置 | 当前证据与处置 |
| --- | --- |
| `zero-delta-min-output-bypass` / LP settlement | 当前 `_settle` 在 `delta >= 0` 时校验最低输出，零输出且正最低值回滚；已有 `Liquidity.t.sol` 直接回归。历史机制已修复。 |
| `signed-delta-settlement-boundary` / Router callback | 当前 callback 显式拒绝 `int128.min` 输入；两方向 delta guard 用例存在。未保留漏洞或 lead。 |
| `intra-day-unit-mix` / Registry adapter replacement | 代码没有 unit epoch；当前政策要求统一单位、提前暂停和新日恢复。未证明符合这些前提的普通用户利用链。管理员违背明确单位政策不作为本次漏洞；保留测试/操作验收建议。 |
| `mutable-adapter-implementation` / Registry admission | 不证明外部 Adapter 的升级安全；依赖被批准实现、升级权限及监控。未证明独立普通用户升级/篡改入口，未作为本次漏洞。 |
| `mutable-token-implementation` / Registry admission | 同上，Token proxy 的外部升级权限和准入证据需要独立验收。本次不 review 外部仓库。 |
| `mutable-token-implementation` / Router settlement | 精确余额 debit/credit 和 settle acknowledgement 均存在；未证明支持的 Token 行为下绕过这些检查的普通用户链。外部 Token 信任边界仍适用。 |
| `stale-market-status-on-relist` / Registry relisting | 当前政策明确保留 market pause 和 sequence；现有测试验证该行为。没有证明与规范冲突的可利用路径。 |
| `sequence-saturation-lock` / Inbox acceptance | 报告要求获授权角色；最大 sequence 无普通用户可控入口。未证明合法普通业务下的可利用链。 |
| `external-poolmanager-trust` / Router initialize/callback | 固定 PoolManager 是当前设计依赖；部署脚本检查代码及 codehash。未证明普通用户可以替换 callback 的调用者或传入数据。 |
| `redundant-trade-day-read` / Router validation | 重复读取是历史质量/耗 gas 记录，不是本次安全 finding/lead。 |
| `redundant-pool-key-check` / Router validation | 当前源码及调用链已精简；重复校验本身也不构成漏洞。 |
| `duplicated-swap-mode` / Router exact-input/output | 当前调用模式由两个 selector 的固定布尔值派生，未证明用户可制造冲突。 |
| `redundant-callback-return-data` / Router callback | 返回 delta 用于事件，不是可利用的安全缺陷；不作为本次 finding/lead。 |

未来针对真实生产依赖或不同准入前提审查时，应重新判定相关信任边界；本表不能替代外部对象审计。
