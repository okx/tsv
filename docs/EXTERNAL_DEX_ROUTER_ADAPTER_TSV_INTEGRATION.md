# DexRouter 与签名版 TSVAdapter

适配实现以 `lib/dex-adapters` 子模块固定的上游 `main` 代码为准。本次版本包含 `CallerAuth` 与签名精确输入金额；旧版构造函数和无签名 `MoreInfo` 均不兼容。

## 资金路径

```text
买入：用户 Q → DexRouter → TSVAdapter → TSV PoolManager → 用户 U
卖出：用户 U → PermissionsAdapter W → TSV PoolManager → 用户 Q
```

买入的 DexRouter hop 使用 `assetTo = TSVAdapter`；卖出的 hop 使用 `assetTo = W`。`TSVAdapter` 读取 W/Q 池的 PoolKey，通过 TSV Router 的 `settlementCurrency(W)` 把 W 映射为 U。用户在 DexRouter 上只需授权 X Layer 的 `DEX_TOKEN_APPROVE`；买入时 Adapter 另对 TSV Router 临时批准本笔 Q，调用后清零。

Adapter 只交易后端签名的 `amountIn`。买入前 Adapter 的 Q 余额和卖出前 W 中可 wrap 的 U 余额都必须不少于该值；超出签名金额的余额会保留。金额单位是 U 或 Q 的 raw units，范围为 `1..int128.max`。这限制本笔交易最多能花多少，并不证明 W 中的 U 属于某个入金人。

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

整个结构以 `abi.encode(info)` 编码。签名是 EIP-191 personal-sign，哈希使用 `abi.encode`：

```solidity
payloadHash = keccak256(abi.encode(
    key, expectedMultiplier, amountIn, zeroForOne, participant, to, deadline
));
inner = keccak256(abi.encode(
    adapterAddress, payloadHash, allowedCallers, nonce, block.chainid
));
digest = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", inner));
```

`participant` 来自 DexRouter calldata 尾部的 caller marker；`to` 是传给 Adapter 的接收地址。当前操作器构造单跳交易，要求 participant、`to` 和最终 receiver 都是实际交易钱包。`allowedCallers` 当前只包含部署配置里的 `DEX_ROUTER`。Nonce 成功使用后不能重放；签名有效期与 DexRouter 外层 deadline 使用同一个截止时间。

## 交互操作

从仓库根目录运行：

```sh
test -f script/xlayer/.env.xlayer || cp script/xlayer/.env.xlayer.example script/xlayer/.env.xlayer
python3 script/xlayer/operate.py
```

菜单 14 会收集买卖方向、W/U、PoolKey、精确输入金额、最小输出、multiplier、nonce 和有效秒数。Foundry 脚本会从本地环境读取两把不同用途的密钥：

- `XLAYER_PRIVATE_KEY`：发送交易的钱包，也必须是持有 TSV `SWAP_ALLOWED` SBT 的 participant。
- `TSV_SWAP_AUTH_SIGNER_PRIVATE_KEY`：后端 swap 授权签名私钥；其地址必须等于已部署 Adapter 的 `AUTH_SIGNER()`。

签名私钥只放在 `script/xlayer/.env.xlayer` 或进程环境。它不会作为 `Operation.inputs` 传入，也不会写入日志。脚本会检查 Adapter 的 `AUTH_SIGNER()`、DexRouter allowlist、TSV Router Adapter allowlist、TokenApproveProxy 路由，以及 W/U 的链上映射。若 TokenApprove allowance 不够，会在广播时先创建本笔的精确额度，再调用 DexRouter。授权和 swap 是两笔独立交易；如果授权成功后 swap 失败，该精确额度仍会留在 TokenApprove，需手动撤销或被后续交易消耗。模拟通过后必须输入 `BROADCAST`。

## 部署约束

签名版 TSVAdapter 的构造函数新增 `authSigner`，旧 Adapter 是不可升级的普通合约。旧地址不能靠更新配置获得签名功能；需先部署新版本、设置 DexRouter allowlist、让 TSV Router 管理员允许新 Adapter，并将 `deployment.json` 中的 `TSV_DEX_ADAPTER` 更新为新地址。广播前脚本会核对 Adapter ABI 和两层 allowlist；未完成配置时模拟会失败。

此操作器只构造单跳 LEGACY 路由。买入时实际签名金额必须是分配到 TSV hop 的 Q；卖出时签名金额是本笔要 wrap 的 U。TSV Router、Registry、SBT、W 发行方权限、池状态、multiplier、滑点和日额度仍由链上组件校验。
