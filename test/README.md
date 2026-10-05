# 测试目录与维护方式

测试按业务场景组织。共享 fixture 只准备环境和提供构造/快照/断言工具，不包含 `test*` 或 `invariant*`；测试套件只继承 fixture，避免继承另一个套件后重复执行。

尚待补测和验收的工作统一记录在[测试缺口清单](../docs/TEST_GAPS_V1.md)，按固定 ID 管理；已执行结果见[覆盖矩阵](../docs/TEST_COVERAGE_V1.md)。

## 从哪里开始

| 要验证的行为 | 目录 / 文件 |
| --- | --- |
| Governor 单笔升级、Guardian 冻结、身份恢复、角色保护、代理绑定、批量升级、治理事件 | `unit/v1/governance/` |
| 交易 + LP 随机序列、独立仓位/额度/资产模型 | `integration/local/trading/StatefulTradingLP.t.sol` |
| 固定区块链上 DexRouter/授权合约 → 固定上游 TSVAdapter → TSV/V4/LP | `integration/xlayer/DexRouterFlow.t.sol` |
| 治理随机操作序列 | `unit/v1/governance/StatefulGovernance.t.sol` |
| CREATE/CREATE2 预测与 Hook 权限地址 | `unit/v1/deployment/HookFactory.t.sol` |
| 证券/Token/池准入与业务暂停 | `unit/v1/registry/` |
| ADTV、quota、市场报告、拆并股系数和 UTC 日切 | `unit/v1/reports/` |
| 拆/并股系数、边界/拒绝、真实 V4 自动生效 | `unit/v1/reports/SplitFactor*.t.sol`、`integration/local/operations/SplitFactorFlows.t.sol` |
| 报告/日切随机交错与独立季度日历模型 | `unit/v1/reports/StatefulOperations.t.sol` |
| 真实 V4 下的报告更正、跨月、20/28 小时过渡日、上下架及 Adapter 变更 | `integration/local/operations/` |
| 成交量计量、共享额度和交易暂停门禁 | `unit/v1/trading/VolumeAccounting.t.sol` |
| 法律股数换算 | `unit/v1/adapters/` |
| 真实 V4 直接/Adapter 交易、精确输入/输出、结算失败回滚 | `integration/local/trading/` |
| 仓位生命周期、Position ID、Receipt、强制退出 | `integration/local/liquidity/` |
| 六组件 V2 迁移、已有资金/业务状态保留、冻结中恢复 | `integration/local/governance/` |
| 真实 V4 准入和暂停门禁 | `integration/local/registry/` |
| 历史结算 Adapter | `unit/legacy/`，不计入当前 V1 交易路径覆盖 |

后续交易用例放入 `unit/v1/trading/` 或 `integration/local/trading/`；治理用例放入对应的 `governance/`。固定区块 DEX 集成已在 `integration/xlayer/` 落地；真实生产资产/TSV 与多签演练仍按 `integration/governance/` 及发布清单另行验收。不要创建始终通过或自动跳过的占位测试。

## 公共环境

| Fixture / helper | 用途 |
| --- | --- |
| `helpers/v1/GovernanceFixture.sol` | 固定 Anchor、独立 Guardian/Council、单个 Registry 代理 |
| `helpers/v1/SixProxyFixture.sol` | 六个真实 UUPS 代理和组件链接；Hook 地址安装用于权限单元测试，CREATE2 由部署套件验证 |
| `helpers/v1/FoundationFixture.sol` | Registry、Ledger、Inbox 与准入/报告构造工具 |
| `helpers/v1/OperationsFixture.sol` / `OperationsMocks.sol` | 报告元数据、失败状态快照与区分 tokenId 的 SBT 故障夹具 |
| `helpers/v1/SplitFactorFixture.sol` | 继承运营环境，集中构造系数报告及接受/拒绝状态快照 |
| `helpers/v1/OperationsHandler.sol` | 八类报告/额度/系数/时间/排期/权限操作；独立维护 ADTV、quota、线性因子检查点、去重、来源序号和 UTC 日期/边界 |
| `helpers/v1/ProtocolFixture.sol` | 真实本地 V4 PoolManager、行为 mock、已注资的 LP 仓位 |
| `helpers/v1/GovernanceUpgradeMocks.sol` | 追加存储的兼容 V2、失败迁移、外部写入、授权回调和角色测试替身 |
| `helpers/v1/TradingLPHandler.sol` | 十类操作混合序列；独立计算每笔法定股数、每日额度、两 owner 的仓位/Receipt、资产守恒及 V4 零欠款 |
| `helpers/v1/TSVAdapterFixture.sol` | 为真实上游 TSVAdapter 构造 EIP-2098 测试签名、单次 nonce 和 caller/refund marker；不重实现兑换逻辑 |
| `helpers/v1/GovernanceHandler.sol` | 独立维护身份、审批、冻结与实现地址模型；随机合法/非法调用后比较实际状态 |

`GovernorExecutor` 验证合约账户调用治理入口及授权回调，不代表 Safe 或生产多签的签名、门槛、模块和执行方式已经验证。V2 替身证明示例布局的兼容性，每个真实候选版本仍需单独核验布局和迁移。

## 常用命令

也可在仓库根目录执行 `make test`、`make test-governance`、`make test-trading`、`make test-liquidity`、`make test-operations`、`make test-invariants`、`make test-xlayer` 或 `make check`。各领域快捷命令同时选择对应的单元与本地集成用例。

```sh
# 目录规则和全套不联网回归（包含治理、交易/LP invariant）
python3 script/check-test-layout.py
forge test --summary

# 分层运行
FOUNDRY_PROFILE=unit forge test --summary
FOUNDRY_PROFILE=local forge test --summary

# 单独运行治理、交易和仓位测试
forge test --match-path 'test/unit/v1/governance/*.t.sol'
forge test --match-path 'test/integration/local/trading/*.t.sol'
forge test --match-path 'test/integration/local/liquidity/*.t.sol'
make test-operations
# 系数专项和独立运营模型
forge test --match-contract 'TSV(SplitFactor.*|StatefulOperations)Test' --fuzz-seed 0x20261004

# 随机序列：默认每项性质 64 轮，每轮 32 步；提高强度或复现失败
FOUNDRY_INVARIANT_RUNS=256 FOUNDRY_INVARIANT_DEPTH=128 forge test --match-contract TSVStatefulGovernanceTest
forge test --match-contract TSVStatefulTradingLPTest --fuzz-seed <失败日志中的seed>
forge test --match-contract TSVStatefulOperationsTest --fuzz-seed <失败日志中的seed>

# 固定区块链上 DEX 集成；可选设置 XLAYER_RPC_URL 为同链 archive RPC
make test-xlayer

# 插桩覆盖率；行/分支覆盖率不能替代业务场景和状态序列检查
make coverage
forge fmt --check
git diff --check
```

## 新用例怎么写

1. 按业务行为选择目录，一个文件聚焦一类规则，一个测试聚焦一个成功或失败原因。
2. 名称写清动作与预期，例如 `testReproposingCancelledProposalRequiresFreshGuardianApproval`。矩阵/随机测试说明生成范围与共同规则。
3. 按“准备 → 操作 → 验证”书写；先构造参数，再设置 `vm.prank`/`vm.expectRevert`，避免参数中的外部 getter 或新部署消耗下一次调用的作弊码。
4. 跨 `vm.warp` 多次生成报告/请求时用 `vm.getBlockTimestamp()` 取得当前时间，避免优化器缓存测试合约内的 `block.timestamp`。已定义错误时校验具体 selector；失败交易同时比较实现地址、业务快照和外部写入，不能只检查发生回滚。
5. 新增共享 mock 放在 `helpers/v1/`。优先复用原子性快照和请求构造器，避免把业务断言藏在部署测试里。
6. 新增生产环境用例必须记录链、固定区块、地址/codehash、真实多签配置和受控测试账户；缺少配置时保留待验收说明，不伪装成通过结果。

全部原有具名用例保留，Position ID 套件改为继承无用例的 `ProtocolFixture`，不再重复执行整套协议集成测试。通过数量因此不能直接与旧目录中的继承计数比较。

覆盖矩阵、实际执行记录与未验收边界见 [TEST_COVERAGE_V1.md](../docs/TEST_COVERAGE_V1.md)。覆盖率只能辅助发现未触达路径；不能用单一百分比代表全部场景已验证。

运营入口逐项 review、新增用例和链下验收缺口见 [OPERATIONS_TEST_REVIEW_V1.md](../docs/OPERATIONS_TEST_REVIEW_V1.md)。运营单元 fixture 的 Hook 写入只验证账本，资金完整路径使用 `integration/local/operations/` 中的真实 V4。

覆盖率使用独立的 `coverage` profile（`out/coverage`、`cache/coverage`），避免插桩编译反复使普通测试缓存失效。首次完整 via-IR 编译较久，后续仅修改的套件需要重编译。
