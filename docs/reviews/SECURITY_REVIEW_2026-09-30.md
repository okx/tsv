# TSV V1 全仓库静态安全评审（历史快照）

**日期：**2026-09-30  
**对象：**当前工作区 `src/v1/`、`test/`、`foundry.toml`、依赖与相关设计文档  
**性质：**2026-09-30 的单人源码评审快照；当时没有运行测试、部署、链上写交易或形式化验证。本文保留当日问题清单，不是当前代码的最终状态，也不是“无漏洞”证明。当前交易、运营和治理流程见[三系统总览](../SYSTEMS_OVERVIEW.md)；实现状态以[实现与缺口清单](../IMPLEMENTATION_STATUS_V1.md)和当前源码为准。

## 当前版本覆盖说明

本文件中的部分发现已因后续实现或设计变更而失效：

| 原发现 | 当前状态 |
| --- | --- |
| F-05 发送方额外扣费未检查 | **已修复**。当前 Router/LP Manager 同时检查发送方减少、PoolManager 余额变化和最终接收方增加；本地故障币回归已覆盖。 |
| F-03 Registry 保存固定比例导致无法更新 | **已修订**。当前 Registry 要求兼容比例字段为零，固定比例由 `StaticLegalShareAdapter` 提供；日内公司行动单位换算仍属于 GAP-03。 |
| F-04 SIP 窗口线性增长 | **已移除对应路径**。当前使用自动 UTC 计量日，不再有 SIP 窗口数组；日切配置的边界和检查点见编码规格 §7。 |
| Swap Router 调用模型 | **已调整**。当前 ABI 要求 `msg.sender == participant`，不接受用户签名验签或第三方代提交；本快照中对应的旧设计仅作历史记录。 |

F-01（发行方动态 getter 的最坏 gas/异常状态）和 F-02（发行方代理升级由链下监控发现）仍是生产准入的外部风险，不能仅凭本地测试关闭。

## 结论

**该快照结论是当时不应生产发布。**第一方合约的普通用户资金路径没有发现可直接重现的无权限绕过 Hook 的漏洞；当时仍存在发行方乘数读取、发送方额外扣费、固定比例更新和依赖锁定问题。后续代码已修复本地双侧精确转账检查并改为直接结算/自动 UTC 日切，但真实发行方证据、公司行动单位流程、依赖锁定和生产测试门槛仍需单独完成。

以下“高/中/低”按攻击或触发条件、影响、现有防护与真实可达性综合排序。发行方相关结论是**源码层面已证实的条件风险**；没有实际代理参数、权限和 fork 写路径证据，不能声称现网 TSLAx 已触发。


| 编号   | 可达性                 | 影响                | 触发复杂度           | 已有防护                | 评级    |
| ---- | ------------------- | ----------------- | --------------- | ------------------- | ----- |
| F-01 | 发行方可改参数；时间也能使累计周期增长 | 股票池交易和原币退出可能整体不可用 | 需特定参数、长期停更或乘数边界 | TSV 失败原子回滚，但没有可用性兜底 | 高（条件） |
| F-05 | **历史发现，已修复** | 旧快照中的发送方额外扣费风险 | 需特定转账语义 | 当前代码双侧精确余额检查；真实发行方仍需准入验证 | 已关闭（本地） |
| F-02 | 发行方可升级代理            | 新实现沿用旧审批          | 需实际升级与语义变化      | 链下监测、人工暂停           | 中     |
| F-03 | 企业行动或口径更正后触发        | 额度计量失准或资产停用       | 需发生口径变化         | Adapter 版本化/参数快照；日内统一单位换算仍待定        | 中（当前缺口）     |
| F-04 | **历史 SIP 窗口问题，路径已移除** | 当前自动 UTC 日切不使用窗口数组 | 不适用       | 日切检查点按生效日查询   | 已关闭（设计变更）     |




## 已确认的问题与条件风险



### F-01 高（历史旧结算路径）：AutoFee 乘数读取无上限，能阻断旧 TSLAx 包装交易及旧 LP 原币退出

- **位置：**[BackedAutoFeeTokenImplementation.sol](../../lib/TestToken/backed-token-contract/contracts/BackedAutoFeeTokenImplementation.sol#L265)、[BackedAutoFeeLegalShareAdapter.sol](../../src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol#L29)、[IssuerShareSettlementAdapter.sol](../../src/v1/legacy/IssuerShareSettlementAdapter.sol#L87)、[TSVLPManagerV1.sol](../../src/v1/periphery/TSVLPManagerV1.sol#L150)。
- **关键源码：**
  ```solidity
  periodsPassed = (block.timestamp - lastTimeFeeApplied) / periodLength;
  if (feePerPeriod > 0) {
      for (uint256 index = 0; index < periodsPassed; index++) {
          currentMultiplier = (currentMultiplier * (1e18 - feePerPeriod)) / 1e18;
      }
  }
  ```
- **证据：**发行方 `getCurrentMultiplier()` 计算 `periodsPassed = (block.timestamp - lastTimeFeeApplied) / periodLength`，且 `feePerPeriod > 0` 时执行 `for (uint256 index = 0; index < periodsPassed; index++)`。初始化和 `setPeriodLength()` 均未检查 `periodLength > 0`；`updateFeePerPeriod()` 未限制费率小于 `1e18`；`setLastTimeFeeApplied()` 允许未来时间。[相关 setter](../../lib/TestToken/backed-token-contract/contracts/BackedAutoFeeTokenImplementation.sol#L392) 都先执行 `updateMultiplier`。历史 TSV 动态股数适配器每次快照都调用该 getter；旧结算适配器的 `balanceOf()` 也依赖发行方动态余额逻辑。旧 LP 强退同样要完成 Wrapped 赎回和底层交付，失败时整个交易回滚。当前 V1 只直接收付 wTSLAx，不在 Router/LP Manager 中调用该旧结算适配器；该结论仍作为真实 wTSLAx 动态 getter 的外部准入风险保留。
- **触发与影响：**发行方将 `periodLength` 置零，getter 除零；把上次计费时间设到未来，getter 暂时下溢；把费率设到不小于 `1e18`，到下一周期时减法下溢；或者在正费率下很长时间不推进状态，getter 随累计周期线性耗 gas。因相关 setter 自身先读乘数，错误状态可能无法通过 setter 直接修复。相关资产的 Swap、LP 操作和强退可能全部回滚。若乘数衰减到零，TSV `snapshot()` 会拒绝；发行方自身 `_updateMultiplier()` 也拒绝零乘数。不存在 TSV 侧可绕过发行方 getter/转账限制的安全交付路径。
- **边界：**是否会在目标链实际发生取决于 TSLAx 代理的真实配置、可升级实现、发行方维护频率和 gas 限额；本次未验证这些链上条件。TSV 无法通过单纯提高交易 gas 永久解决。
- **修复：**准入时读取并留存 `periodLength`、`feePerPeriod`、上次计费时间、实现版本；设定链上可验证的最大累计周期与非零乘数门槛，超限时立即暂停新交易；与发行方确认可恢复的状态推进流程和最坏情况 gas。对强退提供独立的、经过法务许可且实际可执行的救济流程；不能把“必能强退原币”写成无条件保证。
- **验证：**用所固定的 Backed 源码部署实际 AutoFee+Wrapped，覆盖零周期、超限费率、未来上次计费时间、最大正常停更期、超长停更期、乘数趋零、制裁及暂停；分别测 Swap、正常退出、强退在链 gas 限额内的结果。
- **类别：**CWE-400（资源耗尽）；可用性与资金退出风险。**严重性：高，条件触发。**



### F-05（历史发现，已修复）：单侧到账检查漏掉发送方额外扣费

- **位置：**[TSVSwapRouterV1.sol](../../src/v1/periphery/TSVSwapRouterV1.sol#L229)、[TSVLPManagerV1.sol](../../src/v1/periphery/TSVLPManagerV1.sol#L220)、[PoolManager.sol](../../lib/v4-core/src/PoolManager.sol#L289)。
- **关键源码：**

  ```solidity
  uint256 beforeBalance = IERC20(token).balanceOf(participant);
  poolManager.take(currency, participant, amount);
  if (IERC20(token).balanceOf(participant) != beforeBalance + amount) revert SettlementMismatch();
  ```

- **历史证据：**该段描述的是 2026-09-30 代码快照。当前 Router/LP Manager 已对输入和输出同时核对发送方、PoolManager 和接收方的 raw 差额；当前路径没有 Wrapper Adapter 结算。
- **触发与影响：**假设已批准 Token 的 `transfer(100)` 从发送者扣 105，接收者得 100，额外 5 被销毁或送给收费账户。输出交易中用户实收 100，TSV 检查通过，V4 却只把 100 记入账，PoolManager 实际损失 105，逐笔累积可使池内资产短缺；输入交易中 PoolManager 实收 100，结算通过，但用户被扣 105。若发行方代理后来引入此行为，F-02 会让旧批准继续生效。接收方少收的典型转账税已由当前检查拦截，本项针对**发送方额外扣费**。
- **边界：**需要准入了这种 Token 或发行方后续改变转账逻辑；固定且已独立验证的标准 ERC20 不触发。合约无法仅靠地址、decimals 或代码哈希字段证明精确转账语义。
- **当前处理：**本地实现已执行上述双侧检查；真实发行方代理仍须通过同样的准入和升级后回归门禁。
- **验证：**构造“发送方扣 105、接收方得 100”的测试 Token，分别走股票输入/输出 Swap、LP 开仓和退出，以及 Wrapped Currency 路径；修复后所有路径必须原子回滚且日额度、仓位、Receipt 不变。
- **类别：**CWE-682（资金会计错误）；**严重性：高，条件触发。**

### F-02 中：发行方代理升级后，Registry 的批准状态不会自动失效

- **位置：**[TSVTypes.sol](../../src/v1/types/TSVTypes.sol#L16)、[TSVRegistryV1.sol](../../src/v1/core/TSVRegistryV1.sol#L156)、[TSVRegistryV1.sol](../../src/v1/core/TSVRegistryV1.sol#L201)、[TSVRegistryV1.sol](../../src/v1/core/TSVRegistryV1.sol#L375)。
- **证据：**`TokenConfig` 存了 `userImplementationHash`、`poolImplementationHash`，但 `setTokenStatus(APPROVED)` 只复核两个**代理 runtime** `codehash`；`isTradable()` 只看状态、市场、暂停。ERC-1967 代理切换实现时，其代理 runtime 字节码一般不变。
- **影响：**发行方可以升级 TSLAx/wTSLAx 的乘数、赎回、制裁或转账语义后，TSV 继续把原批准记录用于新交易。现有链下监测是必要运维控制，但链上不会自动失效。若新语义不符合准入假设，可产生错误计量或资产无法交付。
- **修复：**把发行方实现版本/可验证的实现哈希变成资产的有效性门槛。对无法从另一合约直接读取 ERC-1967 存储槽的代理，可使用发行方公开实现 getter、受信任报告签名、或者监测器提交新版本并先暂停再复审；任何方法都要能阻止旧审批继续流通。复审后更新 `reviewHash` 与实现证据，并明确开放旧 LP 原资产退出的条件。
- **验证：**本地模拟代理实现升级而 runtime `codehash` 不变，证明现版 `isTradable()` 仍为真；修复版应在升级信号后阻止新 Swap，并覆盖旧仓位退出。
- **类别：**CWE-841（状态机控制不完整）；**严重性：中，需发行方实现变化。**



### F-03 中：固定余额股票的换股比无法在同一资产上更新（历史表述已修订）

- **位置：**[TSVRegistryV1.sol](../../src/v1/core/TSVRegistryV1.sol#L185)、[TSVRegistryV1.sol](../../src/v1/core/TSVRegistryV1.sol#L237)、[TSVRegistryV1.sol](../../src/v1/core/TSVRegistryV1.sol#L201)。
- **当前证据：**Registry 注册时要求兼容字段 `sharesPerWholeTokenWad` 和 `ratioEvidenceHash` 为零；固定比例由 Adapter 的快照提供。更换 Adapter 仍需暂停/无活跃池、递增版本和新依据；日内 `usedWad` 单位换算尚未编码。
- **影响：**如发生拆股、合股或法律计量口径更正，原币地址仍在使用时，治理不能仅通过更换静态 Adapter 使新股数口径生效。若不暂停，日额度可能继续按旧比例计量；若暂停，则需要升级 Registry 或迁移资产才能恢复。该问题对普通 ERC20 股票资产尤其重要。
- **修复：**定义生效时间、旧日额度和现有 LP 的处理规则后，增加“暂停资产 → 提交新比率及证据 → 校验 Adapter → 原子更新配置 → 复审启用”的治理路径。不能只放松 Adapter 校验，否则配置与 Adapter 将相互矛盾。
- **验证：**用 1:1 普通 ERC20 股票模拟 2:1 拆股，检查变更前后同一池的成交计量、现有仓位和交易日切换。
- **类别：**CWE-682（计算口径生命周期）；**严重性：中，需企业行动或更正。**



### F-04 低：未来交易日窗口更正成本随历史窗口数增长（已移除路径）

- **位置：**[TSVVolumeLedgerV1.sol](../../src/v1/core/TSVVolumeLedgerV1.sol#L87)、[TSVVolumeLedgerV1.sol](../../src/v1/core/TSVVolumeLedgerV1.sol#L99)。
- **历史证据：**该段描述的是已经移除的 SIP 日历窗口实现。当前 VolumeLedger 使用自动 UTC 计量日和按生效日排序的日切检查点。
- **影响：**长期运行或预报大量短窗口后，更正未来窗口的 gas 随历史增长，可能无法在目标链 gas 限额内执行。对正常 Swap 的 `currentTradeDay()` 使用二分查找，故风险集中在更正运维。
- **修复：**增加 `windowStartUTC => index+1` 索引，并限制待报窗口的时间范围或批次；对历史窗口采用可证明的安全裁剪规则，避免破坏已用额度审计。
- **验证：**测 1、365、10,000 个窗口下的更正 gas，并在目标链单笔 gas 上限内保留余量。
- **类别：**CWE-400；**严重性：低，运营可用性。**



## 发布阻断项，不计为可利用漏洞

1. **V4 源码未锁定在当前 Git 树。**[foundry.toml](../../foundry.toml#L13) 从 `lib/v4-core/` 编译，而当前 `git ls-files --stage lib/v4-core` 没有记录，该目录是未跟踪文件；[.gitmodules](../../.gitmodules#L1) 仅列 SBT 和 Backed。需要将 V4 锁定为明确 commit 的子模块或经完整性校验的依赖，并记录 artifact/source hash。否则其他环境无法重现本次所审计字节码。SBT 和 Backed 当前分别记录为 `a4c53ccbf7de65a3f415a706d22a506a215b68fc` 与 `35859e8c755698eeeef96ef15beef5fcd6b978cc`。
2. **测试尚未完成且本次未执行。**[IMPLEMENTATION_STATUS_V1.md](../IMPLEMENTATION_STATUS_V1.md#L11) 记载目录重组前 37 个通过用例，但重组后只检查了编译；实际 SBT/Backed 集成、固定区块 X Layer fork、EIP-712 独立向量、ERC-1271、随机序列/不变量、升级存储布局、最坏 gas 与部署清单仍缺。详见 [TEST_SPEC_V1.md](../TEST_SPEC_V1.md#L114)。现有本地交易集成使用真实 V4 PoolManager，但发行方资产和 SBT 是行为 mock；这不足以验证三协议组合。
3. **实际发行方/法律前提未完成签署和链上核对。**“显示 TSLAx 数量等于法律股数”、wTSLAx 的实际赎回/制裁规则、目标代理实现与管理员权限、原 owner 被拒收时 V1 整笔回滚的法律可接受性，都需要在 `APPROVED` 前形成可追溯证据。此项不能由 Solidity 单独证明。
4. **当前工作区尚不是可审计提交。**`git status --short` 显示大多数 `src/`、`test/`、`docs/` 和 `foundry.toml` 未跟踪，本报告只对应 2026-09-30 当前文件内容。上线前需要冻结提交、依赖版本、编译器与构建产物，并重新核对差异。



## 路径核对与有效控制


| 路径                                               | 本次观察                                                                                                                                                    |
| ------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Swap：Router → V4 unlock → Hook → Ledger → settle | Router 校验资格、池、签名/nonce、限价；Hook 只接受指定 PoolManager 与 Router，使用实际 V4 delta 计双侧股票额度；失败随同一交易回滚。未发现可由任意调用者直接绕过 Hook 成交的路径。                                    |
| LP：Manager → V4 → 原 owner                        | Receipt 禁止转让；常规退出需 owner 与资格；强退仅授权角色，交付原 owner，底层拒收会回滚。强退可用性仍受 F-01 和发行方制裁控制。                                                                           |
| 动态股票（历史旧结算路径）                       | 旧 Adapter 用 `sharesOf`、Wrapped 总量/余额及前后状态校验；发行方 `transferSharesFrom` 的 allowance 是显示数量，Adapter 按此授权。该路径不属于当前 V1；当前 wTSLAx 仅直接结算，动态法律股数按实际 V4 wTSLAx delta 与当前 multiplier 计量，仍需真实代理验证。 |
| 普通 ERC20 股票                                      | `DIRECT_ERC20` 当前检查发送方、PoolManager 和接收方的实际 raw 差额；固定比例由 Adapter 提供，企业行动单位更新仍受 GAP-03 约束。                                                                                  |
| 报告/额度                                            | EIP-712 域、角色签名、sequence、reportId、截止时间及双侧额度原子消费均有控制；报告可用性和 oracle 正确性是外部信任前提。                                                                            |
| 治理/升级                                            | UUPS 只允许 Timelock 或事故 Controller；事故路径默认冻结、指定代理白名单；恢复 Council 操作受保护。每笔延迟可由排期指定且没有最小值，符合已确定的治理设计，但实施时治理地址和执行人必须单独核对。                                      |




## 覆盖与限制


| 维度              | 结果                                                                                       |
| --------------- | ---------------------------------------------------------------------------------------- |
| D1 注入、D4 反序列化   | 检查 ABI decode、回调 data hash、签名消息边界；无 SQL/命令执行面。                                           |
| D2 身份认证、D3 授权   | 检查 Router/LP/SBT、报告签名、角色、回调 caller、UUPS/Timelock/事故升级；已覆盖全部主要状态修改入口。                     |
| D5 文件操作、D6 SSRF | 合约无文件系统或 HTTP 调用面，不适用。                                                                   |
| D7 密码学          | 检查 EIP-712、SignatureChecker、nonce/reportId、CREATE2 地址承诺；未发现显式签名重放入口，独立向量与 ERC-1271 测试仍缺。 |
| D8 配置、D9 业务逻辑   | 检查池准入、双标的额度、暂停、日切、股票单位、结算、强退、企业行动；F-01 至 F-05。                                           |
| D10 供应链         | 核对 V4/SBT/Backed/OZ 路径与锁定状态；F-01 及 V4 发布阻断项。仅做有限的公开安全公告核查，没有给出全部依赖无 CVE 的结论。             |
| D11 恶意代码        | 搜索动态调用、自毁、`tx.origin`、低级调用、外部 URL、隐藏执行等模式；第一方命中为已说明的代理升级和错误转发，没有发现明确后门。                  |


本评审没有实际执行 `forge test`、模糊测试、链上 fork、部署演练或完整第三方协议独立审计；不能据此声称所有边界已被覆盖。对 F-01、F-02、F-03 与 F-05 的修复应先写回 [CODING_SPEC_V1.md](../CODING_SPEC_V1.md)，再补相应自动化用例与独立复审。
