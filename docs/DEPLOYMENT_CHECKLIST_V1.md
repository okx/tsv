# TSV V1 全新部署与发布验收清单

版本：1.1，2026-10-03
目标链：X Layer，chainId `196`

本文是当前 V1 的**全新部署**清单。交易、运营和治理系统的业务流程见[三系统总览](./SYSTEMS_OVERVIEW.md)；本文负责部署顺序、地址绑定、配置完整性和发布后验收，不提供旧 TSV 实例迁移算法。

## 1. 部署边界

本次发布必须创建一组全新的 TSV 实例，不复用旧版本的代理地址或状态：

| 类别 | 部署内容 | V1 规则 |
| --- | --- | --- |
| 业务代理 | Registry、VolumeLedger、DataInbox、Hook、SwapRouter、LPManager | 六个地址全部新建；使用非空初始化数据部署 `TSVERC1967Proxy` |
| 治理合约 | `TSVGovernanceAnchor` | 非代理、不可升级；直接保存 Governor/Guardian/Council 和升级冻结状态，六代理只保存 Anchor 地址 |
| 外部依赖 | 官方 V4 `PoolManager`、SmartWalletSbt、发行方 Token、实现 `IDirectLegalShareAdapter` 的 Adapter | 地址、代码哈希、ABI/ERC-165 接口声明及法律换算依据必须写入发布清单 |
| 历史源码 | `src/v1/legacy/` 下的旧包装/赎回 Adapter | 只用于隔离回归测试，不部署、不登记、不写入核心配置 |

不得把旧 `TSVReceiptV1`、旧 `TSVSBTAdapterV1`、旧 Router 或旧 LP Manager 地址填入新清单。旧 LP 仓位和旧 SIP 日账不属于本部署状态，因此不执行迁移，也不保留兼容分支。

全新部署不代表以后可以忽略存储布局：六个业务代理在本次初始化后仍是 UUPS 代理，后续实现升级只能追加存储并通过存储布局检查。本次结构重构不要求与旧实例布局兼容，因为旧实例不在本次地址集合内。

## 2. 制品锁定

部署前将以下内容保存到同一个 manifest，并对 manifest 做版本化。字段模板见 [`DEPLOYMENT_MANIFEST_V1.example.json`](./DEPLOYMENT_MANIFEST_V1.example.json)：

- Git commit、工作区是否干净、Solidity `0.8.26`、Cancun、优化器参数、`viaIR = true` 和 OpenZeppelin 版本。
- `lib/v4-core`、`lib/soul-bound-token-1155`、`lib/TestToken/backed-token-contract` 的提交或源码哈希。
- 官方 `PoolManager` 地址、链 ID、运行时代码哈希和 V4 版本。
- 六个实现合约的运行时代码哈希、六个代理地址及 `tsvImplementation()` 返回值。
- Hook 工厂地址、CREATE2 salt、预测地址、实际地址及低 14 位权限校验结果。
- SBT、股票 Token、报价 Token、LegalShareAdapter 的地址、代码哈希、decimals、版本、ERC-165 接口声明和准入证据哈希。
- Governor、Guardian、RecoveryCouncil 以及每个业务角色的独立地址。

manifest 中不能只写“由多签控制”。链上只识别具体地址，必须记录每个地址当前承担的角色。

## 3. 治理合约部署顺序

仓库提供 [`DeployGovernanceV1.s.sol`](../script/DeployGovernanceV1.s.sol)、[`DeployCoreV1.s.sol`](../script/DeployCoreV1.s.sol) 和只读的 [`VerifyDeploymentV1.s.sol`](../script/VerifyDeploymentV1.s.sol)。先以目标链 RPC 对两者执行无 `--broadcast` 的模拟，再在已冻结 manifest、链 ID、官方 PoolManager 与 SBT 运行代码哈希核对后广播。Core 脚本在广播交易之外枚举 CREATE2 salt；模拟时按本仓库 Foundry CLI 的 `--disable-block-gas-limit` 关闭本地枚举的区块 gas 检查，实际广播的每笔交易仍须满足目标链 gas 限制。脚本从环境读取 `TSV_DEPLOYER_PRIVATE_KEY`，由密钥管理器注入，不能写入仓库或命令行文本。主要输入为 `TSV_CHAIN_ID`、`TSV_GOVERNOR`、`TSV_GUARDIAN`、`TSV_RECOVERY_COUNCIL`；第二阶段还需 `TSV_GOVERNANCE_ANCHOR`、`TSV_POOL_MANAGER`、`TSV_POOL_MANAGER_CODEHASH`、`TSV_SBT`、`TSV_SBT_CODEHASH`、`TSV_SBT_TOKEN_ID` 和 `TSV_DAY_START_OFFSET_SECONDS`。两个脚本只部署并验证其明确列出的合约；后续 Anchor/Registry/Ledger 绑定、资产与角色操作由治理身份分别执行。发布事务及代码哈希须回填 manifest。完成 Anchor、Registry、Ledger、SBT 绑定后，使用 `VerifyDeploymentV1` 只读检查六代理地址、实现、代码哈希、Hook 权限位及所有交叉引用；校验脚本还需从 manifest 注入六组 `TSV_*_IMPLEMENTATION` 和 `TSV_*_IMPLEMENTATION_CODEHASH`，以及六个代理地址 `TSV_REGISTRY`、`TSV_VOLUME_LEDGER`、`TSV_DATA_INBOX`、`TSV_HOOK`、`TSV_SWAP_ROUTER`、`TSV_LP_MANAGER`。

1. 部署 `TSVGovernanceAnchor(governor, guardian, recoveryCouncil)`；直接设置 Governor/Guardian/Council。
2. 回填 Anchor 地址及三身份到 manifest 与第二阶段环境变量。
3. 核对 Anchor 的 Governor/Guardian/Council 与配置一致且三身份非零、彼此独立。
4. 核验 Anchor 初始 `upgradesFrozen=false`、`freezeEpoch=0`，回填 manifest；全部升级仅在未冻结时开放，只有当前 Guardian 能冻结/解冻。

治理部署无需 bootstrap 绑定、升级排期或专用 Executor。

## 4. 六个业务代理部署顺序

所有代理均使用 `TSVERC1967Proxy(implementation, initData)`，`initData` 必须非空。不要采用“先部署空代理、稍后再初始化”的两步方式。

### 4.1 先部署无循环依赖的组件

1. 部署 Registry 实现和代理，调用：

   ```solidity
   TSVRegistryV1.initialize(anchor)
   ```

2. 部署 VolumeLedger 实现和代理，调用：

   ```solidity
   TSVVolumeLedgerV1.initialize(anchor, registry, dayStartOffsetSeconds)
   ```

3. 部署 DataInbox 实现和代理，调用：

   ```solidity
   TSVDataInboxV1.initialize(anchor, registry, ledger)
   ```

### 4.2 预计算 Hook 所需地址

Hook 初始化需要 Router 和 LP Manager 的最终代理地址。Router 本身不保存 Hook 地址，因此这里没有 Router↔Hook 的循环依赖。部署脚本须先确定 Router 和 LP Manager 地址，再以这两个地址构造 Hook 初始化数据并预测 Hook 地址：

- 使用 CREATE 地址或 nonce 预计算 Router/LP Manager 代理地址；或
- 使用等价的确定性部署工厂计算这两个代理地址。

不得在 Hook 初始化数据中使用临时 Router/LP Manager 地址或零地址。

部署前至少验证：

```text
Router 代理地址、LP Manager 代理地址
        ↓
Hook initialize 的 initData
        ↓
Hook 工厂 predict(implementation, initData, salt)
        ↓
Hook 地址低 14 位 == 0x3FFF
```

### 4.3 部署 Router、LP Manager 和 Hook

1. 部署 Router 代理，调用：

   ```solidity
   TSVSwapRouterV1.initialize(
       anchor,
       poolManager, registry, ledger
   )
   ```

2. 部署 LP Manager 代理，调用：

   ```solidity
   TSVLPManagerV1.initialize(
       anchor,
       poolManager, registry
   )
   ```

3. 用 `TSVHookProxyFactoryV1` 部署 Hook 代理，调用：

   ```solidity
   TSVHookV1.initialize(
       anchor,
       poolManager, registry, ledger, router, lpManager
   )
   ```

4. 验证 Hook 代理地址低 14 位为 `0x3FFF`，且 `tsvImplementation()` 等于预期实现。

### 4.4 完成跨合约绑定

按以下顺序调用一次性绑定入口：

1. `Registry.bindComponents(hook, lpManager, dataInbox)`
2. `VolumeLedger.bindWriters(hook, dataInbox)`
3. `GovernanceAnchor.bindProxies([registry, volumeLedger, dataInbox, hook, swapRouter, lpManager])`

4. 核验六代理均读取同一固定 Anchor，演练 Guardian 全局冻结后逐个/批量升级均拒绝；Governor/Council 解冻拒绝，由当前 Guardian 显式解冻后恢复升级。冻结不会阻断业务操作。

然后逐项读取：

- Registry 的 `hook/lpManager/dataInbox`
- VolumeLedger 的 `hook/dataInbox`
- Router 的 `poolManager/registry/ledger`
- LP Manager 的 `poolManager/registry`
- Hook 的 `poolManager/registry/ledger/router/lpManager`
- 六代理 `governanceAnchor()` 指向同一个 Anchor，且 Anchor 保存的六地址顺序正确

任一地址不一致都必须停止发布，不得继续登记资产或初始化池。

## 5. SBT 和业务角色配置

### 5.1 SBT 配置

先调用：

```solidity
Registry.setSbtConfig(sbt, tokenId, evidenceHash)
```

当前实现会在配置时读取 `paused()` 和 `verify(address, tokenId)`，用于确认目标地址具备所需 ABI。未配置 SBT 时，`hasCredential` 和 `isEligible` 明确回滚 `SbtNotConfigured()`；这属于 fail-closed 行为。

配置后必须验证：

- 有资格地址：`isEligible(user) == true`
- 无资格地址：`isEligible(user) == false`
- SBT paused：`isEligible(user) == false`
- `verify` 调用失败：交易回滚
- SBT 配置事件包含正确的旧地址、新地址、tokenId 和证据哈希

### 5.2 业务角色

通过 Governor 给具体地址授予：

- `SYMBOL_ADMIN_ROLE`
- `POOL_CREATOR_ROLE`
- `HALT_REPORTER_ROLE`
- `VOLUME_ORACLE_ROLE`
- `EMERGENCY_PAUSER_ROLE`
- `EMERGENCY_RESUMER_ROLE`
- `REVOKE_EXIT_EXECUTOR_ROLE`
- `FORCE_EXIT_ADMIN_ROLE`

每个角色至少配置一个独立地址，并把地址写入 manifest。用户直连 Router 时，调用者本人是 participant；若启用外部 DEX Adapter 路径，必须先由 Governor 将已审查的 Adapter 加入 Router 白名单，且 Adapter 从可信 DexRouter caller marker 解析 participant 后由 Router 执行 SBT 校验。退款地址 marker 不能代替 participant 身份。

## 6. 资产、报告和池配置

资产准入证据和实例边界以[代币准入标准](./TOKEN_ADMISSION_STANDARD_V1.md)为准；本节只列上线时的执行顺序：

1. 完成链下审查后，由 `SYMBOL_ADMIN` 一次调用 `admitSecurity`，登记 `securityId`、Tier、首个 Currency 和 LegalShareAdapter 并批准 Token；输入 status=APPROVED、reviewHash 非零，市场默认 OPEN。证据未齐不得准入。
2. 报价 Currency 若未准入，调用 `registerToken` 登记即批准；已有上市证券的新增 Currency 也使用此入口。
3. 由 `VOLUME_ORACLE` 提交当前适用月份 ADTV；quota 仅在需要覆盖某计量日硬上限时提交。拆/并股按公告提前提交 SplitFactor，默认系数1无需报告；仅可选择未来计量日开始。报告服务须固定 ADTV 来源月月末单位、kind=3 独立序号和最新待生效项版本，复核绝对 quota 及未来日切起点。无需首次开市报告。
4. 由 `POOL_CREATOR` 调用 `LPManager.initializePool`。Registry pending、V4 initialize 和 Registry active 必须在同一交易完成；建池和 ADTV 可按任意顺序执行。
5. 核对 PoolKey、PoolId、Hook 地址、初始价格及状态，写入 manifest；LP 可在 ADTV 前提供流动性，首笔股票 Swap 前必须有有效 ADTV。

## 7. 发布后最小验收

发布脚本成功后，必须保存每项交易 receipt、事件和状态快照：

- 六个业务代理和一个固定治理合约的地址、代码哈希及绑定关系。
- Hook 地址权限位、实现地址和初始化事件。
- SBT 配置、角色授予、资产配置和 TokenStatus。
- 准入后默认 OPEN、marketSequence=0；ADTV、可选 quota、SplitFactor 排期/取消及后续 HALT/RESUME 的 reportId 和 sequence；新 Ledger/Inbox ABI 与索引器同时发布，已有实例升级核对追加布局并建议原子批量升级二者。
- 四种紧急暂停范围及 TRADE/LP/ALL 模式、市场 HALT 叠加与 RESUME 部分恢复；索引器读取新事件模式字段、marketPauseMode 和三参数 activePauseCount。
- 使用本版准入、Token/Market 状态及暂停/MarketReport ABI 首次部署，不作为旧合约存储的原地迁移实现。
- 至少一个普通 ERC-20 报价资产和一个 Backed-compatible 股票资产及 Adapter 的登记结果。
- 一个股票/报价币池的初始化结果和 PoolId。
- 一笔成功 Swap：实际输入、实际输出、`SwapExecuted`、`SwapAccounted`、usedWad。
- 一次 LP 开仓、部分减仓、关闭和强退的 Receipt/余额变化。
- 一个拒绝用例：SBT 无资格、SBT paused、缺 ADTV、TokenStatus 非 APPROVED、旧 TSLAx 结算配置。

所有失败用例都必须证明用户、PoolManager、仓位、Receipt 和 usedWad 回到交易前状态。

## 8. 交付物和停止条件

交付包至少包含：

- 本文 manifest 和部署交易清单
- 六个代理及实现 ABI
- Hook salt、预测地址和权限位证明
- 治理合约绑定证明
- 资产准入和外部发行方证据
- 角色地址表和暂停/强退 runbook
- 索引器事件起始区块与地址白名单
- 构建、测试和固定区块验收结果

出现以下任一情况，发布状态必须保持 `NOT_READY`：

- 任一绑定地址与 manifest 不一致
- Hook 权限位不是 `0x3FFF`
- SBT 未配置或 ABI 校验失败
- wTSLAx 仍缺少发行方/法务准入证据
- 任一资产未准入（`ABSENT`）或为 `DISABLED` 却尝试建池
- 使用了旧代理、旧 Receipt、旧 SBT Adapter 或 legacy Adapter
- Hook 初始化中 Router/LP Manager 地址未经过预测和实际地址比对

## 9. 治理身份恢复和升级

固定 Anchor 直接保存三治理身份和升级开关，不提供治理组件更换或根迁移入口。Anchor 不可升级；本版本用于全新部署。Governor 和 Guardian 地址通过受保护身份恢复更新，Council 地址固定。

### 9.1 Governor / Guardian 身份恢复

1. 保存 Governor/Guardian/Council、epoch、guardianEpoch、upgradesFrozen/freezeEpoch/freezeId 及业务状态快照。Governor 有风险时，由当前 Guardian 先冻结全部升级；业务暂停通过独立入口处理。
2. Council 调用 `anchor.proposeRecovery(newGovernor,newGuardian,salt,evidenceHash)`，记录返回 ID。新身份必须非零、彼此不同、不同于 Council，不得对调旧 Governor/Guardian，且至少变化一个。
3. 当前 Guardian 核对后 `approveRecovery(id)`；可撤回批准，Council 可取消提案。
4. 任意地址执行 `executeRecovery(id)`，Anchor 再校验批准与两个 epoch 后，在同笔直接更新 Governor/Guardian；失败全部回滚。每次成功递增 epoch，Guardian 变化还递增 guardianEpoch，旧批准失效。
5. 核验六代理仍指向同一 Anchor，旧 Governor 失去默认管理员和升级权，新 Governor 接管默认管理员；升级冻结状态保留，Guardian 变化后由新 Guardian 接管冻结/解冻权。运营角色、Token/Pool/暂停、Ledger 用量、LP 仓位和 Receipt 保留。
6. 回填 manifest、索引器与操作手册。当前 Guardian 无法批准或 Council 无法提案时，Anchor 没有绕过批准的恢复入口。

### 9.2 单笔升级操作

1. 部署并核验新实现代码、layout 与接口兼容性。
2. 读取 `anchor.upgradesFrozen()`；已冻结时须当前 Guardian 按当前 freezeId 显式解冻。单代理由当前 Governor 多签直接调用 `proxy.upgradeToAndCall(newImplementation,initData)`；多代理由 Governor 调用 `anchor.upgradeBatch(targets,implementations,initData)`，目标只能为已绑定六代理，按数组顺序执行。
3. 批量初始化调用者为 Anchor；候选迁移函数须兼容该身份及 `upgradeContextActive()`，否则整批回滚。单代理初始化调用者为 Governor。
4. 核对升级 receipt、`Upgraded` 事件、实现地址和初始化后的业务状态；任何一步失败整笔回滚。升级无需排期或等待。

### 9.3 Guardian 全局冻结/解冻

1. 风险发生时，当前 Guardian 调用 `anchor.freezeUpgrades(reasonHash)`；原因非零，记录返回 freezeId 与 `UpgradesFrozen` 事件。此后六代理单独/批量升级全部拒绝，Governor 无法解冻。
2. Council 与当前 Guardian 可继续完成身份恢复；核验 upgradesFrozen、freezeEpoch、freezeId 均保持原值。业务暂停须通过独立暂停入口处理。
3. 风险解除后，由当前 Guardian 调用 `anchor.unfreezeUpgrades(expectedFreezeId,evidenceHash)`；ID 必须匹配当前冻结，证据非零。Guardian 轮换后由新 Guardian 解冻。
4. 核验事件、实现地址及业务状态，并将最新冻结状态回填 manifest。该开关不能回滚冻结交易之前已完成的升级。
