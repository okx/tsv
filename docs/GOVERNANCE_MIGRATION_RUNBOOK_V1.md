# TSV V1 治理根迁移操作清单

适用范围：六个业务代理已绑定同一固定 `TSVGovernanceAnchor`。三治理合约本身不是代理；每次换址都部署新的 Timelock、BusinessAuthority、EmergencyUpgradeController。当前实现要求 RecoveryCouncil 提议，**当前 Guardian** 批准。链上尚未部署，以下步骤须先在固定区块 fork 和发布候选实例上完整演练。

## 迁移前

1. 从 Anchor 读取 `epoch`、`guardianEpoch`、`guardian`、`recoveryCouncil`、当前三地址及 `proxies(0..5)`；六代理顺序固定为 Registry、Ledger、DataInbox、Hook、Router、LPManager。核对每个代理的 `governanceAnchor()` 和实际 ERC-1967 实现地址。
2. 保存旧根的待执行 Timelock 操作与事故控制器状态。需要停交易时先由独立 `EMERGENCY_PAUSER_ROLE` 暂停，并保存交易哈希。迁移不会自动暂停或清理业务角色。
3. 部署候选三合约，使候选 Timelock 的 Governor、Guardian、RecoveryCouncil 与候选 Authority/Controller 一致；新 Controller 保持 `frozen=true`。
4. 候选 Timelock 自身排期并执行 `bindBusinessAuthority`、`bindEmergencyController`、`nominateGovernanceAnchor(anchor)`。再通过候选 Timelock 为六代理逐个执行 `setUpgradeTarget(proxy,true)`。读取核对所有绑定、角色、代码哈希和允许名单；候选代码哈希写入发布 manifest，链上 Anchor 只验证可调用状态与相互绑定，不替代代码审计。

## 双批准与执行

1. RecoveryCouncil 调用 `anchor.proposeRoot(newTimelock,newAuthority,newController,salt,evidenceHash)`，记录返回的 proposal ID、当前两个 epoch、三地址和证据。
2. 当前 Guardian 独立核对同一个 ID 后调用 `approveRoot(id)`。Guardian 可在执行前 `revokeRootApproval(id)`；Council 可 `cancelRoot(id)`。不得让两身份由同一签名控制流程代签。
3. 任意执行者调用 `executeRoot(id)`。Anchor 再次检查三合约绑定、当前 Guardian/Council、候选 Controller 冻结和六代理升级允许名单，然后原子切换三地址并激活新 Timelock 的 Anchor 绑定。任一校验失败则全部回滚。

## 执行后

- 核对 Anchor `epoch` 增加 1、六代理 `businessAuthority()`/`upgradeTimelock()`/`emergencyUpgradeController()` 同时切换；旧 Timelock/Controller 对任一代理升级应回滚，新 Timelock 的受控测试排期应能执行。
- 核对 Registry 的 Token/Pool/暂停、Ledger 用量、Router nonce、LP 仓位和 Receipt 未变化；测试原 owner 强退仍可按 `minOut` 原子执行。
- 旧 Timelock 已排期操作不转移到新 Timelock；旧操作虽可能还能在旧合约内执行，但不能再通过六代理的 UUPS 授权。继续监控旧合约事件和外部依赖。
- 更新部署 manifest、索引器治理地址和事故 runbook，再按业务审批解除暂停。

## Governor/Guardian 身份恢复

身份恢复不是三合约换址。RecoveryCouncil 只能排期精确的 `recoverAuthorities(newGovernor,newGuardian,evidenceHash)`；当前 Guardian 必须对该 Timelock operation ID 调用 `approveRecovery(id)`，否则任何 executor 都无法执行。Guardian 不能取消受保护排期，但可 `revokeRecoveryApproval(id)`。更换 Guardian 的同一交易会同步 Anchor Guardian 并递增 `guardianEpoch`，旧的 Anchor 迁移提案因此失效。若 Council 与 Guardian 同时失联，当前 Anchor 没有链上后门恢复入口。
