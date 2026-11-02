# 定向验证用例

来源：main 90929552fd557fd67b9debafa905bafffb40ed86。

将 AuditRevalidation.t.sol 放在该版本工作树的 test/unit/v1/deployment/ 下，按汇总报告里的 CLI remapping 和 skip 设置运行。测试文件仅用于复核，未修改主工作区生产合约。

该用例引用现有 LPLinkedFixture 与真实 v4-core Pool。#9 使用 PoolManager 替身，#29 使用真实 Pool library 但不包含资金结算。6项PASS代表问题复现/门禁验证成立，不代表修复已完成。
