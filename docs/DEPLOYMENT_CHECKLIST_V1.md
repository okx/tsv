# TSV V1 全新部署与发布验收清单

版本：1.0，2026-10-01  
目标链：X Layer，chainId `196`

本文是当前 V1 的**全新部署**清单。它解决的是部署顺序、地址绑定、配置完整性和发布后验收，不提供旧 TSV 实例迁移算法。

## 1. 部署边界

本次发布必须创建一组全新的 TSV 实例，不复用旧版本的代理地址或状态：

| 类别 | 部署内容 | V1 规则 |
| --- | --- | --- |
| 业务代理 | Registry、VolumeLedger、DataInbox、Hook、SwapRouter、LPManager | 六个地址全部新建；使用非空初始化数据部署 `TSVERC1967Proxy` |
| 治理合约 | `TSVUpgradeTimelock`、`TSVBusinessAuthority`、`TSVEmergencyUpgradeController`、`TSVGovernanceAnchor` | 非代理；本发布首次部署并互相绑定，六代理只保存 Anchor 地址 |
| 外部依赖 | 官方 V4 `PoolManager`、SmartWalletSbt、发行方 Token、LegalShareAdapter | 地址、代码哈希和 ABI 必须写入发布清单 |
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
- SBT、股票 Token、报价 Token、LegalShareAdapter 的地址、代码哈希、decimals、版本和准入证据哈希。
- Governor、Guardian、RecoveryCouncil、Executor 以及每个业务角色的独立地址。

manifest 中不能只写“由多签控制”。链上只识别具体地址，必须记录每个地址当前承担的角色。

## 3. 治理合约部署顺序

仓库提供 [`DeployGovernanceV1.s.sol`](../script/DeployGovernanceV1.s.sol)、[`DeployCoreV1.s.sol`](../script/DeployCoreV1.s.sol) 和只读的 [`VerifyDeploymentV1.s.sol`](../script/VerifyDeploymentV1.s.sol)。先以目标链 RPC 对两者执行无 `--broadcast` 的模拟，再在已冻结 manifest、链 ID、官方 PoolManager 与 SBT 运行代码哈希核对后广播。Core 脚本在广播交易之外枚举 CREATE2 salt；模拟时按本仓库 Foundry CLI 的 `--disable-block-gas-limit` 关闭本地枚举的区块 gas 检查，实际广播的每笔交易仍须满足目标链 gas 限制。脚本从环境读取 `TSV_DEPLOYER_PRIVATE_KEY`，由密钥管理器注入，不能写入仓库或命令行文本。主要输入为 `TSV_CHAIN_ID`、`TSV_GOVERNOR`、`TSV_GUARDIAN`、`TSV_RECOVERY_COUNCIL`、`TSV_EXECUTOR`；第二阶段还需 `TSV_GOVERNANCE_ANCHOR`、`TSV_BUSINESS_AUTHORITY`、`TSV_UPGRADE_TIMELOCK`、`TSV_EMERGENCY_CONTROLLER`、`TSV_POOL_MANAGER`、`TSV_POOL_MANAGER_CODEHASH`、`TSV_SBT`、`TSV_SBT_CODEHASH`、`TSV_SBT_TOKEN_ID` 和 `TSV_DAY_START_OFFSET_SECONDS`。两个脚本只部署并验证其明确列出的合约；中间 Timelock 绑定、后续 Anchor/Registry/Ledger 绑定、资产与角色操作由治理身份分别执行。发布事务及代码哈希须回填 manifest。完成 Anchor、Registry、Ledger、SBT 绑定后，使用 `VerifyDeploymentV1` 只读检查六代理地址、实现、代码哈希、Hook 权限位及所有交叉引用；校验脚本还需从 manifest 注入六组 `TSV_*_IMPLEMENTATION` 和 `TSV_*_IMPLEMENTATION_CODEHASH`，以及六个代理地址 `TSV_REGISTRY`、`TSV_VOLUME_LEDGER`、`TSV_DATA_INBOX`、`TSV_HOOK`、`TSV_SWAP_ROUTER`、`TSV_LP_MANAGER`。

按下列顺序部署，避免治理合约之间出现未绑定状态：

1. 部署 `TSVUpgradeTimelock(governor, guardian, recoveryCouncil, executors)`。
2. 使用该 Timelock 部署 `TSVBusinessAuthority(governor, timelock)`。
3. 使用该 Timelock 地址部署 `TSVEmergencyUpgradeController(governor, guardian, timelock)`。
4. 部署 `TSVGovernanceAnchor(timelock, authority, controller)`。
5. 通过 Timelock 自身排期并执行 `bindBusinessAuthority`、`bindEmergencyController` 和 `bindGovernanceAnchor`。这些都是独立排期和执行交易。
6. 读取并核对：
   - `businessAuthority.upgradeTimelock() == timelock`
   - `emergencyController.upgradeTimelock() == timelock`
   - 两者的 governor/guardian 与 Timelock 一致
   - Timelock 的 `PROPOSER_ROLE`、`CANCELLER_ROLE`、`EXECUTOR_ROLE` 与 manifest 一致
   - `timelock.governanceAnchor() == anchor`，Anchor 的治理三地址及 Guardian/Council 与 Timelock 一致
7. 治理绑定未完成前，不部署可接收用户资金的业务池，也不授予业务角色。

Timelock 的普通升级延迟由每次排期指定；本清单不为它设置业务层面的最小或最大延迟。事故控制器首次部署保持 `frozen = true`，除非完成独立的事故升级启用验收。

## 4. 六个业务代理部署顺序

所有代理均使用 `TSVERC1967Proxy(implementation, initData)`，`initData` 必须非空。不要采用“先部署空代理、稍后再初始化”的两步方式。

### 4.1 先部署无循环依赖的组件

1. 部署 Registry 实现和代理，调用：

   ```solidity
   TSVRegistryV1.initialize(anchor, timelock, emergencyController)
   ```

2. 部署 VolumeLedger 实现和代理，调用：

   ```solidity
   TSVVolumeLedgerV1.initialize(anchor, timelock, emergencyController, registry, dayStartOffsetSeconds)
   ```

3. 部署 DataInbox 实现和代理，调用：

   ```solidity
   TSVDataInboxV1.initialize(anchor, timelock, emergencyController, registry, ledger)
   ```

### 4.2 处理 Hook、Router、LP Manager 的地址关系

Hook 的初始化需要 Router 和 LP Manager 地址，Router 初始化又需要最终 Hook 地址。发布脚本必须使用以下任一方式解决循环：

- 使用确定性部署或 nonce 预计算，先得到 Router/LP Manager 的最终代理地址，再用 Hook 工厂预测最终 Hook 地址；或
- 使用等价的部署工厂一次性预计算全部代理地址。

不得用临时 Hook 地址、零地址或部署后无法修改的占位地址。Router 的 `hook` 一旦初始化就作为安全边界使用。

确定性地址计算至少要在部署前验证：

```text
Router 代理地址、LP Manager 代理地址
        ↓
Hook initialize 的 initData
        ↓
Hook 工厂 predict(implementation, initData, salt)
        ↓
Hook 地址低 14 位 == 0x3FFF
        ↓
Router.initialize(..., predictedHook)
Hook.initialize(..., actualRouter, actualLpManager)
```

### 4.3 部署 Router、LP Manager 和 Hook

1. 使用最终预测的 Hook 地址部署 Router 代理，调用：

   ```solidity
   TSVSwapRouterV1.initialize(
       anchor, timelock, emergencyController,
       poolManager, registry, ledger, hook
   )
   ```

2. 部署 LP Manager 代理，调用：

   ```solidity
   TSVLPManagerV1.initialize(
       anchor, timelock, emergencyController,
       poolManager, registry
   )
   ```

3. 用 `TSVHookProxyFactoryV1` 部署 Hook 代理，调用：

   ```solidity
   TSVHookV1.initialize(
       anchor, timelock, emergencyController,
       poolManager, registry, ledger, router, lpManager
   )
   ```

4. 验证 Hook 代理地址低 14 位为 `0x3FFF`，且 `tsvImplementation()` 等于预期实现。

### 4.4 完成跨合约绑定

按以下顺序调用一次性绑定入口：

1. `Registry.bindComponents(hook, lpManager, dataInbox)`
2. `VolumeLedger.bindWriters(hook, dataInbox)`
3. `GovernanceAnchor.bindProxies([registry, volumeLedger, dataInbox, hook, swapRouter, lpManager])`

然后逐项读取：

- Registry 的 `hook/lpManager/dataInbox`
- VolumeLedger 的 `hook/dataInbox`
- Router 的 `poolManager/registry/ledger/hook`
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

每个角色至少配置一个独立地址，并把地址写入 manifest。不得把“聚合器地址”直接当作用户资格地址；用户交易中的 `participant` 仍必须通过 Router 的签名和 SBT 校验。

## 6. 资产、报告和池配置

对每个资产按以下顺序执行：

1. 登记 `securityId` 和 Tier。
2. 登记 Pool Currency、`userToken == poolCurrency`、`DIRECT_ERC20` 和 LegalShareAdapter。
3. 保持资产为 `UNREVIEWED`，完成代码、余额稳定性、精确转账、权益公式和法律证据审查。
4. 提交资产批准证据并切换为 `APPROVED`。
5. 提交 `INITIAL_OPEN` 或 `INITIAL_HALTED` 市场状态。
6. 提交当前适用月份的 ADTV；日配额只在需要覆盖某一计量日硬上限时提交。
7. 由 `POOL_CREATOR` 调用 `LPManager.initializePool`。该入口必须在同一交易中完成 Registry pending、V4 initialize 和 Registry active 三个步骤。
8. 读取 PoolKey、PoolId、Hook 地址、初始价格和状态，写入 manifest。

股票 Currency 与股票 Currency 不得组成交易对。Tesla 实例的池和用户只收付 wTSLAx，不能把 TSLAx 或 legacy Adapter 填入 `TokenConfig`。

## 7. 发布后最小验收

发布脚本成功后，必须保存每项交易 receipt、事件和状态快照：

- 六个业务代理和四个治理合约的地址、代码哈希及绑定关系。
- Hook 地址权限位、实现地址和初始化事件。
- SBT 配置、角色授予、资产配置和 TokenStatus。
- `INITIAL_OPEN`/`INITIAL_HALTED`、ADTV、可选 quota 的 reportId 和 sequence。
- 至少一个普通 ERC-20 报价资产和一个 `ERC8056TestToken` 股票资产的登记结果。
- 一个股票/报价币池的初始化结果和 PoolId。
- 一笔成功 Swap：实际输入、实际输出、`SwapExecuted`、`SwapAccounted`、usedWad。
- 一次 LP 开仓、部分减仓、关闭和强退的 Receipt/余额变化。
- 一个拒绝用例：SBT 无资格、SBT paused、缺 ADTV、TokenStatus 非 APPROVED、旧 TSLAx 结算配置。

所有失败用例都必须证明用户、PoolManager、仓位、Receipt、usedWad 和 nonce 回到交易前状态。

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
- 任一资产仍为 `UNREVIEWED` 却尝试建池
- 使用了旧代理、旧 Receipt、旧 SBT Adapter 或 legacy Adapter
- Router/LP/Hook 的循环地址未经过预测和实际地址比对
