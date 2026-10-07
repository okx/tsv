# TSV Adapter 实现与测试依赖

## 固定实现

- 仓库：https://gitlab.okg.com/web3-dex/GitHub-Web3-DEX-Adapters-EVM
- 提交：`e38c6b109875893ad037677eb8d8221fa4b5687b`
- 子模块：`lib/dex-adapters`
- 实现：`src/adapters/uniswap-v4/TSVAdapter.sol`，在固定上游版本上仅增加 W→U / Q→Q 的收付币种解析。
- 初始化：`git submodule update --init lib/dex-adapters`。

Foundry 的上下文 remapping 将该子模块的 `@interfaces` 和 `@libraries` 限定在其自己的源码中。

## 与旧测试夹具的差异

真实 Adapter 构造参数为 `(tsvRouter, authSigner)`。`MoreInfo` 编码为 `(PoolKey key, uint64 expiry, address[] allowedCallers, uint256 nonce, bytes authSig)`。后端签名绑定 Adapter、池、expiry、允许的调用合约、单次 nonce 及 chainId，签名为 64 字节 EIP-2098 格式。测试使用固定的测试专用签名 key，不配置生产签名密钥。

`sellBase` 卖 currency0，`sellQuote` 卖 currency1。签名和 TSV 请求的 PoolKey 为 W/Q；Adapter 通过 Router 的 `settlementCurrency` 解析实际收付币种，W 映射为 U，Q 保持 Q。输入金额为 Adapter 的当前输入币余额，既有输入币余额也参与兑换；仅本次新增输出转发给 `to`。部分成交的剩余输入退给 refund marker 中的地址。兑换后清除 TSV Router allowance。

身份来自倒数第 64 字节的 caller marker，退款地址来自最后 32 字节的 ORIGIN_PAYER；必须有规范 ABI calldata 加恰好两个 marker。旧夹具从 refund marker 提取 SBT 身份的行为已删除。

上游 Adapter 的 TSV 请求采用 `limitAmount=1`、`deadline=block.timestamp`，交易滑点及订单期限由外部 DexRouter 负责；`expiry` 单独控制签名有效期。本地 callback 测试仅验证 Adapter/TSV 交互，外部 DexRouter 全局 minReturnAmount 的原子回滚由 fork 测试验证。

## 测试

- `test/integration/local/trading/DexAdapter.t.sol`：签名可信来源、marker 格式、SBT 与收款/退款地址区分、双向兑换、余额语义、授权清理、部分成交退款、签名重放及过期。
- `test/integration/xlayer/DexRouterFlow.t.sol.deferred`（仍待 Wrapped LP 与目标链迁移）：使用固定区块真实 DexRouter、TSVAdapter 和本地部署的 TSV/V4。保留双向、拆单、多跳、AA、指定 receiver、全局滑点、部分成交和暂停等场景。
- `test/helpers/v1/TSVAdapterFixture.sol`：只生成签名和路由数据，实际兑换由上游 TSVAdapter 执行。Router 边界测试中的小型调用 mock 仍仅用于隔离 Router 权限和暂停行为。

运行：

```sh
FOUNDRY_PROFILE=local forge test --match-path 'test/integration/local/trading/*.t.sol' --summary
```

本依赖不代表已部署生产 Adapter；正式签名服务、真实生产资产及生产 SBT 仍须按上线流程验收。

## Wrapped 模式验证记录（2026-10-08）

本地交易目录 42 项通过，0 失败、0 跳过；其中现有 TSVAdapter 的 11 项用例使用真实 W/Q 池、U/Q 收付，覆盖双向兑换、退款、用户身份、白名单、授权清理、签名与 Router 三个入口的重入拒绝。XLayer 用例仍延期，未计入本次通过数。

## 历史 DIRECT 模式验证记录

本地交易目录回归：52 通过，0 失败，0 跳过，其中上游 Adapter 接入用例 9 项。固定区块 XLayer DEX 套件：11 通过，0 失败，0 跳过。验证期间工作区存在并行的哈希参数清理，完整 fork 验证使用本次开始时提交 `a8e577a` 加本次 Adapter 改动的隔离快照；不把此结果解释为并行修改的全项目验证。
