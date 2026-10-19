# DexRouter 与签名版 TSVAdapter

适配实现以 `lib/dex-adapters` 子模块固定的上游提交 `5be1e7f8963979c637adae9f21077a6c4100c5a8`为准。本次版本仅卖出使用 `CallerAuth` 与签名精确输入金额，买入使用实时余额且免签名。旧版构造函数和仅两个字段的 `MoreInfo` 编码不兼容；买入仍需编码新版完整结构。

## 资金路径

```text
买入：用户 Q → DexRouter → TSVAdapter → TSV PoolManager → 用户 U
卖出：用户 U → PermissionsAdapter W → TSV PoolManager → 用户 Q
```

买入的 DexRouter hop 使用 `assetTo = TSVAdapter`；卖出的 hop 使用 `assetTo = W`。`TSVAdapter` 读取 W/Q 池的 PoolKey，通过 TSV Router 的 `settlementCurrency(W)` 把 W 映射为 U。用户在 DexRouter 上只需授权 X Layer 的 `DEX_TOKEN_APPROVE`；买入时 Adapter 另对 TSV Router 临时批准本笔 Q，调用后清零。

卖出仅交易后端签名的 `amountIn`，W 中可 wrap 的 U 必须不少于该值，剩余 U 保留；这限制交易金额，但不证明 W 中资金的归属。买入使用执行时 `Q.balanceOf(adapter)` 全余额（含历史 Q），无需预知前序跳产出的准确金额。两侧实际输入均以结算币 raw units 计，范围为 `1..int128.max`。

## `MoreInfo` ABI

```solidity
struct MoreInfo {
    ITSVSwapRouter.PoolKey key;
    uint256 expectedMultiplier;
    uint256 amountIn;
    address[] allowedCallers;
    uint256 nonce;
    uint256 deadline;
    bytes authSig; // EIP-2098 compact signature, r || vs, exactly 64 bytes
}
```

整个结构以 `abi.encode(info)` 编码。买入填 `amountIn = nonce = deadline = 0`、`allowedCallers = []`、`authSig = 0x`；不校验授权、不消费 nonce。卖出签名是 EIP-191 personal-sign，哈希使用 `abi.encode`：

```solidity
payloadHash = keccak256(abi.encode(
    key, expectedMultiplier, amountIn, zeroForOne, participant, deadline
));
inner = keccak256(abi.encode(
    adapterAddress, payloadHash, allowedCallers, nonce, block.chainid
));
digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
```

`participant` 来自 DexRouter calldata 尾部的 caller marker；`to` 是 DexRouter 执行时传给 Adapter 的接收地址，不参与签名。当前操作器构造单跳交易，要求 participant、`to` 和最终 receiver 都是实际交易钱包。`allowedCallers` 当前只包含部署配置里的 `DEX_ROUTER`。卖出 nonce 成功使用后不能重放；卖出签名有效期与 DexRouter 外层 deadline 使用同一个截止时间。买入 MoreInfo.deadline 为 0，但 DexRouter 外层 deadline 仍为有效的未来时间。

## 交互操作

从仓库根目录运行：

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
python3 script/xlayer/operate.py
```

菜单 14 会收集买卖方向、W/U、PoolKey、精确输入金额、最小输出、multiplier、有效秒数，并仅在卖出时询问 nonce。SDK `amount_in` / `TSV_DEX_AMOUNT_IN` 始终是 DexRouter 实际转入金额，买入也必须大于 0，不可与 MoreInfo.amountIn 混淆。Foundry 脚本按方向读取环境变量：

- `XLAYER_PRIVATE_KEY`：发送交易的钱包，也必须是持有 TSV `SWAP_ALLOWED` SBT 的 participant。
- `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY`：仅卖出需要的后端 swap 授权签名私钥，买入不读取；其地址必须等于已部署 Adapter 的 `AUTH_SIGNER()`。

签名私钥只放在 `script/xlayer/.env.xlayer` 或进程环境。它不会作为 `Operation.inputs` 传入，也不会写入日志。脚本仅卖出检查 Adapter 的 `AUTH_SIGNER()` 和 nonce；两侧均检查 DexRouter allowlist、TSV Router Adapter allowlist、TokenApproveProxy 路由，以及 W/U 的链上映射。若 TokenApprove allowance 不够，会在广播时先创建本笔的精确额度，再调用 DexRouter。授权和 swap 是两笔独立交易；如果授权成功后 swap 失败，该精确额度仍会留在 TokenApprove，需手动撤销或被后续交易消耗。模拟通过后必须输入 `BROADCAST`。

## 部署约束

签名版 TSVAdapter 的构造函数新增 `authSigner`，旧 Adapter 是不可升级的普通合约。旧地址不能靠更新配置获得签名功能；需先部署新版本、设置 DexRouter allowlist、让 TSV Router 管理员允许新 Adapter，并将 `deployment.json` 中的 `TSV_DEX_ADAPTER` 更新为新地址。广播前脚本会核对 Adapter ABI 和两层 allowlist；未完成配置时模拟会失败。

此操作器只构造单跳 LEGACY 路由。买入时 DexRouter 转入 Q、Adapter 使用实时全余额，MoreInfo 不签名；卖出时签名金额是本笔要 wrap 的 U。TSV Router、Registry、SBT、W 发行方权限、池状态、multiplier、滑点和日额度仍由链上组件校验。

`to` 的移除改变了卖出签名 digest。即使旧部署支持相同 MoreInfo ABI，也不能使用新版签名；必须部署与固定子模块相同逻辑的 Adapter，并重新设置 TSV allowlist。此 MR 不修改线上部署地址或广播交易。
