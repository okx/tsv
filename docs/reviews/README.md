# 评审与审计归档

这里集中保存历史评审报告和机器生成的审计产物。各报告描述其评审时点的代码；后续源码变化可能使结论过期。

## 2026-10-01

- [全仓库复核](COMPREHENSIVE_REVIEW_2026-10-01.md)
- [安全审计报告](SECURITY_AUDIT_2026-10-01.md)
- [Pashov X-Ray 总览](x-ray-2026-10-01/x-ray.md)：另含[入口映射](x-ray-2026-10-01/entry-points.md)、[不变量目录](x-ray-2026-10-01/invariants.md)和[架构图](x-ray-2026-10-01/architecture.svg)。
- [Solidity Auditor 三轮审计报告](solidity-auditor/20261001-160945/full-report.md)：同目录保存三轮记录、审计范围和当次记忆快照。审计时的 Git HEAD 为 `797e7b8`。
- [Solidity Auditor 三轮复审报告](solidity-auditor/20261001-185600/full-report.md)：发现 LP 零 delta 最低输出缺口并已修复；Adapter 法律单位切换仍依赖运维流程。修复和验证结果见[状态说明](solidity-auditor/20261001-185600/remediation.md)。审计基线为 `f597879`，LP 修复在审计结束后完成。

## 其他评审

- [协议技术可行性评审](PROTOCOL_FEASIBILITY_REVIEW.md)
- [2026-09-30 安全评审](SECURITY_REVIEW_2026-09-30.md)
- [TSV V1 人工 Review 工作台](TSV_V1_MANUAL_REVIEW.html)

Fizz 已安装，但本次未生成 fuzz suite：运行所需的 Medusa 和 Echidna 不在环境中。
