来源：[DEX - TSV 合约审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd)

报告审计 Commit：`6402443e9fc372e8aa52c9ba82cd3e84cb846493`；分支：`main`。

原文快照：2026-10-27T09:27:51Z（文档最后修改时间）。以下保留报告原文，截图为原图；仅转换排版，不代表已复核当前代码或确认修复状态。

## 报告原文

### No.2: 中风险【SBT 身份列表无长度上限，权限校验可能耗尽 gas】（吴晓涛）

| 位置 | 文件 | 风险状态 | 风险类型 | 风险级别 |
|---|---|---|---|---|
| Lines 269–291、315–331、729–737 | src/v1/core/TSVRegistryV1.sol | ❌  | Out Of Gas | 中风险 |

风险描述及修改建议

风险描述

setSbtConfig 在首次注册 tokenId 时将其永久追加到 identityTokenIds；当前没有长度上限及移除机制，权限设为 NONE 后该 ID 仍保留在数组中。_credentialState 每次遍历整个列表，并对每个 ID 外部调用 participantSbt.verify；permissionsOf、isSbtAllowed 和 hasCredential 均依赖该遍历。

随着管理员登记的身份类型增长，交易和流动性操作中的权限校验成本线性增长；同一业务流程对多个参与者重复校验时，成本会进一步累积。列表过大可能使链上调用超过可用 gas，并使完整列表查询受到 RPC gas／响应限制。注册仅允许 DEFAULT_ADMIN_ROLE，故该项属于依赖管理员配置规模的潜在可用性风险，不能据此认定任意用户可以低成本填满列表。

修改建议

对可登记的身份类型设置明确且经过最坏情况测算的数量上限，避免历史禁用 ID 无限参与交易路径遍历；需要移除时维护可控的活跃身份集合。长期可考虑由调用者提供身份凭证并逐项验证。

相关代码

```solidity
// TSVRegistryV1.sol，节选
if (!sbtIdentityConfig[tokenId].registered) identityTokenIds.push(tokenId);
sbtIdentityConfig[tokenId] = SbtIdentityConfig(true, permissions);

function _credentialState(address owner) private view returns (bool held, PermissionFlag permissions) {
    for (uint256 i; i < identityTokenIds.length; ++i) {
        uint256 tokenId = identityTokenIds[i];
        if (ISmartWalletSbtV1(participantSbt).verify(owner, tokenId)) {
            held = true;
            permissions = permissions | sbtIdentityConfig[tokenId].permissions;
        }
    }
}
```

问题反馈

| 项目方（产研）反馈 |  |
|---|---|
| 审计反馈 |  |

---