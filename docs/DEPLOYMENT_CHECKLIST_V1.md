# TSV V1 全新部署与发布验收清单

版本：1.0，2026-10-01  
目标链：X Layer，chainId `196`

本文是当前 V1 的**全新部署**清单。交易、运营和治理系统的业务流程见[三系统总览](./SYSTEMS_OVERVIEW.md)；本文负责部署顺序、地址绑定、配置完整性和发布后验收，不提供旧 TSV 实例迁移算法。

## 1. 部署边界

本次发布必须创建一组全新的 TSV 实例，不复用旧版本的代理地址或状态：

| 类别 | 部署内容 | V1 规则 |
| --- | --- | --- |
| 业务代理 | Registry、VolumeLedger、DataInbox、Hook、SwapRouter、LPManager | 六个地址全部新建；使用非空初始化数据部署 `TSVERC1967Proxy` |
| 治理合约 | `TSVUpgradeTimelock`、`TSVBusinessAuthority`、`TSVEmergencyUpgradeController`、`TSVGovernanceAnchor` | 非代理；本发布首次部署并互相绑定，六代理只保存 Anchor 地址 |
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
       anchor, timelock, emergencyController,
       poolManager, registry, ledger
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

4. Anchor 六代理绑定成功后，由 Timelock 分别调用 `setUpgradeTarget(proxy, true)`，将六个业务代理加入事故升级名单。Controller 会拒绝 Anchor 列表以外的地址；首次部署的 Timelock 必须已经绑定该 Anchor。Controller 保持 `frozen = true`，直到事故升级单独通过启用验收。

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

1. 登记 `securityId`、Tier、池内 Currency 和适用的 LegalShareAdapter；Token 初始保持 `UNREVIEWED`。
2. 通过准入审查后，提交批准证据并将 Token 切换为 `APPROVED`。
3. 提交初始市场状态和当前适用月份 ADTV；仅在需要覆盖某计量日硬上限时提交 quota。
4. 由 `POOL_CREATOR` 调用 `LPManager.initializePool`。Registry pending、V4 initialize 和 Registry active 必须在同一交易完成。
5. 核对 PoolKey、PoolId、Hook 地址、初始价格及状态，并写入 manifest。

## 7. 发布后最小验收

发布脚本成功后，必须保存每项交易 receipt、事件和状态快照：

- 六个业务代理和四个治理合约的地址、代码哈希及绑定关系。
- Hook 地址权限位、实现地址和初始化事件。
- SBT 配置、角色授予、资产配置和 TokenStatus。
- `INITIAL_OPEN`/`INITIAL_HALTED`、ADTV、可选 quota 的 reportId 和 sequence。
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
- 任一资产仍为 `UNREVIEWED` 却尝试建池
- 使用了旧代理、旧 Receipt、旧 SBT Adapter 或 legacy Adapter
- Hook 初始化中 Router/LP Manager 地址未经过预测和实际地址比对

## 9. 治理根迁移

本节适用于六个业务代理已绑定同一固定 `TSVGovernanceAnchor` 后的治理根换址，不适用于首次部署。当前实现要求 RecoveryCouncil 提议，**当前 Guardian** 独立批准；治理三合约本身不是代理，每次换址都要部署新的 Timelock、BusinessAuthority 和 EmergencyUpgradeController。链上尚未部署，以下步骤须先在固定区块 fork 和发布候选实例上完整演练。

### 9.1 迁移前准备

1. 从 Anchor 读取 `epoch`、`guardianEpoch`、`guardian`、`recoveryCouncil`、当前三地址及 `proxies(0..5)`；六代理顺序固定为 Registry、Ledger、DataInbox、Hook、Router、LPManager。核对每个代理的 `governanceAnchor()` 和实际 ERC-1967 实现地址。
2. 保存旧根的待执行 Timelock 操作与事故控制器状态。需要停交易时，先由独立 `EMERGENCY_PAUSER_ROLE` 暂停并保存交易哈希。迁移不会自动暂停或清理业务角色。
3. 部署候选三合约，使候选 Timelock 的 Governor、Guardian、RecoveryCouncil 与候选 Authority/Controller 一致；新 Controller 保持 `frozen=true`。
4. 候选 Timelock 自身排期并执行 `bindBusinessAuthority`、`bindEmergencyController`、`nominateGovernanceAnchor(anchor)`。再通过候选 Timelock 为六代理逐个执行 `setUpgradeTarget(proxy,true)`。读取核对所有绑定、角色、代码哈希和允许名单；候选代码哈希写入发布 manifest。Anchor 只验证可调用状态与相互绑定，不替代代码审计。

### 9.2 双批准与原子执行

1. RecoveryCouncil 调用 `anchor.proposeRoot(newTimelock,newAuthority,newController,salt,evidenceHash)`，记录返回的 proposal ID、当前两个 epoch、三地址和证据。
2. 当前 Guardian 独立核对同一个 ID 后调用 `approveRoot(id)`。Guardian 可在执行前调用 `revokeRootApproval(id)`；Council 可调用 `cancelRoot(id)`。两种身份须独立控制。
3. 任意执行者调用 `executeRoot(id)`。Anchor 再次检查三合约绑定、当前 Guardian/Council、候选 Controller 冻结和六代理升级允许名单，然后原子切换三地址并激活新 Timelock 的 Anchor 绑定。任一校验失败则全部回滚。

### 9.3 执行后核验

- 核对 Anchor `epoch` 增加 1、六代理的 `businessAuthority()` / `upgradeTimelock()` / `emergencyUpgradeController()` 同时切换；旧 Timelock/Controller 对任一代理升级应回滚，新 Timelock 的受控测试排期应能执行。
- 核对 Registry 的 Token/Pool/暂停、Ledger 用量、LP 仓位和 Receipt 未变化；测试原 owner 强退仍可按 `minOut` 原子执行。
- 旧 Timelock 已排期操作不转移到新 Timelock。旧操作虽可能还能在旧合约内执行，但不能再通过六代理的 UUPS 授权。继续监控旧合约事件和外部依赖。
- 更新部署 manifest、索引器治理地址和事故 runbook，再按业务审批解除暂停。

### 9.4 Governor / Guardian 身份恢复

身份恢复不是三合约换址。RecoveryCouncil 只能排期精确的 `recoverAuthorities(newGovernor,newGuardian,evidenceHash)`；当前 Guardian 必须对该 Timelock operation ID 调用 `approveRecovery(id)`，否则任何 executor 都无法执行。Guardian 不能取消受保护排期，但可调用 `revokeRecoveryApproval(id)`。更换 Guardian 的同一交易会同步 Anchor Guardian 并递增 `guardianEpoch`，旧 Anchor 迁移提案因此失效。若 Council 与 Guardian 同时失联，当前 Anchor 没有链上后门恢复入口。
