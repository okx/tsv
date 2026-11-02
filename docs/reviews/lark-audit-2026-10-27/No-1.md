来源：[DEX - TSV 合约审计报告](https://okg-block.sg.larksuite.com/docx/NYPSdzQruohPBOx90CUlFrTegbd)

报告审计 Commit：`6402443e9fc372e8aa52c9ba82cd3e84cb846493`；分支：`main`。

原文快照：2026-10-27T09:27:51Z（文档最后修改时间）。以下保留报告原文，截图为原图；仅转换排版，不代表已复核当前代码或确认修复状态。

## 报告原文

### No.1: 中风险【订阅回调可使强制退出的余额差计算下溢】（别术林，吴晓涛）

| 位置 | 文件 | 风险状态 | 风险类型 | 风险级别 |
|---|---|---|---|---|
| Line -- | src/v1/libraries/TSVLPManagerLib.sol | ❌  | Denial of Service | 中风险 |

风险描述及修改建议

风险描述

unwindPositionByTsv 与 unwindPosition 在调用 subscriber.notifyUnsubscribe 之前读取 LP／发行方钱包余额，完成仓位销毁及资产交付后，再以 after − before 构造退出事件。LP 可控制订阅回调，在回调中转走自己原先持有的普通报价资产，使最终余额低于快照值。事件参数中的 uint256 减法会触发 Panic(0x11)，导致整个强退交易回滚。

例如：LP 原有 1,000 Q，本仓位退出获得 10 Q；订阅回调转走原有 1,000 Q 后正常返回，最终余额为 10 Q，事件计算 10 − 1,000 时回滚。回滚同时恢复仓位、订阅和余额，因此同一行为可重复阻止该仓位强退，并可能阻塞要求仓位计数归零的池子／证券下架。

修改建议

计算余额差额前，应先比较退出前后余额，仅在 after >= before 时执行减法，避免因余额减少触发算术下溢，导致整个强制退出交易回滚。

相关代码

```solidity
/// @dev Original TSV exit body; state mappings and immutable dependencies are explicit parameters.
function unwindPositionByTsv(
    UnwindParams memory p,
    mapping(uint256 => PositionInfo) storage positionInfo,
    mapping(uint256 => ISubscriber) storage subscriber,
    mapping(uint256 => address) storage approvals
) external {
    ...
    uint256 lpBalance0Before = poolKey.currency0.balanceOf(lp);
    uint256 lpBalance1Before = poolKey.currency1.balanceOf(lp);
    ...
    emit TsvPositionUnwound(
        tokenId,
        lp,
        issuer,
        Currency.unwrap(poolKey.currency0),
        Currency.unwrap(poolKey.currency1),
        //@audit-issue Medium 潜在的 DoS 攻击，lp 在 notifier 中将账户本来持有的代币转移走，导致 after 的资产反而小于 before 的资产
        //@audit-issue Low 对于 W 资产，lp 的账户余额永远都是0，应该获取 W 对应的 U 的账户余额
        poolKey.currency0.balanceOf(lp) - lpBalance0Before,
        0,
        poolKey.currency1.balanceOf(lp) - lpBalance1Before,
        0
    );
}

function unwindPosition(
    UnwindParams memory p,
    mapping(uint256 => PositionInfo) storage positionInfo,
    mapping(uint256 => ISubscriber) storage subscriber,
    mapping(uint256 => address) storage approvals
) external {
    ...
    RecipientBalances memory beforeBalances = _recipientBalances(poolKey, lp, issuer);
    ...
    RecipientBalances memory afterBalances = _recipientBalances(poolKey, lp, issuer);
    emit IssuerPositionUnwound(
        tokenId,
        lp,
        issuer,
        Currency.unwrap(poolKey.currency0),
        Currency.unwrap(poolKey.currency1),
        //@audit-issue Medium 潜在的 DoS 攻击，lp 在 notifier 中将账户本来持有的代币转移走，导致 after 的资产反而小于 before 的资产
        //@audit-issue Low 对于 W 资产，lp 的账户余额永远都是0，应该获取 W 对应的 U 的账户余额
        issuerReceived0 ? 0 : afterBalances.lp0 - beforeBalances.lp0,
        issuerReceived0 ? afterBalances.issuer0 - beforeBalances.issuer0 : 0,
        issuerReceived1 ? 0 : afterBalances.lp1 - beforeBalances.lp1,
        issuerReceived1 ? afterBalances.issuer1 - beforeBalances.issuer1 : 0
    );
}
```

问题反馈

| 项目方（产研）反馈 |  |
|---|---|
| 审计反馈 |  |

---