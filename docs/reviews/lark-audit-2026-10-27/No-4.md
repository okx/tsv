来源：[DEX - TSV 合约审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd)

报告审计 Commit：`6402443e9fc372e8aa52c9ba82cd3e84cb846493`；分支：`main`。

原文快照：2026-10-27T09:27:51Z（文档最后修改时间）。以下保留报告原文，截图为原图；仅转换排版，不代表已复核当前代码或确认修复状态。

## 报告原文

### No.4: 优化建议【不同合约的升级暂停检查不一致】（别术林）

| 位置 | 文件 | 风险状态 | 风险类型 | 风险级别 |
|---|---|---|---|---|
| Line -- | src/v1/core/TSVHookV1.sol<br>src/v1/periphery/TSVSwapRouterV1.sol<br>src/v1/periphery/TSVLPManagerV1.sol<br>src/v1/core/TSVRegistryV1.sol<br>src/v1/governance/TSVGoverned.sol<br>src/v1/core/TSVVolumeLedgerV1.sol | ❌  | Business Logic | 优化建议 |

风险描述及修改建议

风险描述

TSVHookV1、TSVSwapRouterV1 和 TSVLPManagerV1 仅允许在 Registry 未暂停时升级，而 TSVRegistryV1 和 TSVVolumeLedgerV1 不检查暂停状态，升级条件不一致。要求未暂停才能升级，也使“暂停 → 升级修复 → 恢复”的常规应急流程无法直接执行。

修改建议

建议统一取消升级流程中的 pause 状态检查，允许授权管理员在暂停或未暂停状态下执行升级。

相关代码

```solidity
// TSVHookV1.sol
function _authorizeUpgrade(address) internal view override {
    if (registry.isPaused()) revert InvalidOperation();
    if (!registry.hasRole(UPGRADE_ADMIN_ROLE, msg.sender)) revert UnauthorizedUpgrade();
}

// TSVSwapRouterV1.sol；TSVLPManagerV1.sol 的升级入口亦使用同一暂停门禁
function upgradeToAndCall(address newImplementation, bytes memory data)
    public
    payable
    override
    whenRegistryNotPaused
{
    UUPSUpgradeable.upgradeToAndCall(newImplementation, data);
}
```

问题反馈

| 项目方（产研）反馈 |  |
|---|---|
| 审计反馈 |  |

---