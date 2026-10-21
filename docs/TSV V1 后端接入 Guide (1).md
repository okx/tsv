# TSV V1 后端接入 Guide

![Image](https://internal-api-drive-stream-sg.larksuite.com/space/api/box/stream/download/authcode/?code=M2UxYTZkNzUzZDRhYzhlNDdmZjg3YThhMGYxYWJhY2VfNjc1MDdjOTg1ODBiYmJkOTMzNzg3YzE4NDFiZWZjNTdfSUQ6NzY5NjM2MTg2NDQzMDcxODcyN18xNzkyNDg1NzQ5OjE3OTI1NzIxNDlfVjM)

本指南按 Uniswap [Managing Liquidity](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/overview) 的方式组织：前置条件、ABI、编码、提交。**LP 与 Swap 的调用入口不同，以下分别说明。**

> 基于下方 X Layer 部署清单及 `docs/artifacts/` 中对应的合约 ABI。所有业务调用使用代理地址，ABI 须与目标链部署版本一致。示例使用 ethers\.js v6，编码函数生成 calldata；提交示例复用业务方提供的 Signer。报价及签名授权由接入方负责。

本文使用三个完整名称：**PermissionsAdapter 代币**是池内股票侧资产；**底层股票代币**是用户实际持有的股票资产；**报价代币**是池内另一侧资产。PermissionsAdapter 代币与底层股票代币的最小单位数量为 1:1。以下均针对 ERC\-20 池，交易 `value = 0`。

# 测试合约地址：

```json
{
  "network": "X Layer Mainnet",
  "chainId": 196,
  "deploymentDate": "2026-10-14",
  "deploymentStatus": "confirmed",
  "sourceVerification": false,
  "proxies": {
    "TSVRegistryV1": "0x2233ea2044ffa04ccceeef0b9adfe0799505a908",
    "TSVVolumeLedgerV1": "0x4fbffbe7ca5ce0fc3af30c9f305e0f6365ff3bc2",
    "TSVSwapRouterV1": "0xe5df3ab010bb20094f490dfcf61b6e2d9a3311c8",
    "TSVLPManagerV1": "0xf73d8683b948564d2795c62a2a909012ea168d29",
    "TSVHookV1": "0xbc6d8c8a8b681872a93554116f01268f80c9ffff"
  },
  "factories": {
    "PermissionsAdapterFactory": "0x92cdb229613da8ca45e375cf69df4b3b645ff48d",
    "TSVHookProxyFactoryV1": "0x3c3e76f4beb314713901183ed6e511928e1d2a99",
    "SmartWalletFactory": "0x1eb8d87d616f31591cfd21f30458c8168b1c1b80"
  }
}
```

可以申请仓库阅读权限：https://gitlab\.okg\.com/web3\-dex/tsv

[TSV合约地址（主网测试/预发）](https://okg-block.sg.larksuite.com/wiki/Jafww6KotiXI0GkecnUln4kfgqd?from=vcFollow)

## 0、系统中的 Token 与准入

TSV 是交易协议，**没有另行发行供用户持有的“TSV 股票代币”**。用户持有发行方的底层股票代币；池内使用对应的 PermissionsAdapter 代币（`wrapToken`）；另一侧使用报价代币。仓位 NFT 和身份 SBT 也不是这三类可交换资产。

### `underlyingToken` 与 `wrapToken`

|名称|合约地址及用途|
|---|---|
|**底层股票代币**、**股票代币**、`underlyingToken`（例如 SET）|同一个底层 ERC\-20 地址；用户或发行方实际持有、收付的股票资产。本接入示例的代币提供 ERC\-8056 `uiMultiplier()`。|
|**PermissionsAdapter 代币**、`wrapToken`<br>|同一个 PermissionsAdapter 合约地址；该合约本身也是 ERC\-20，是池内股票侧的 `currency0` 或 `currency1`。PoolManager 持有该代币；底层股票代币存放在 PermissionsAdapter 中。`wrapToken` 与 `underlyingToken` 是不同地址。|
|**报价代币**|池内另一侧的 ERC\-20 资产，如USDT；不属于上述 1:1 对应关系。|

已完成 Factory 验证和 Registry 注册的池内股票侧资产满足：`PermissionsAdapter(wrapToken).PERMISSIONED_TOKEN() == factory.verifiedPermissionsAdapterOf(wrapToken) == registry.getCurrencyUnderlying(wrapToken) == underlyingToken`。`registry.getUnderlying(underlyingToken)` 则返回其 `securityId`、`legalShareAdapter` 和 `rawDecimals`。这里的 `legalShareAdapter`（本接入使用 `ERC8056DirectLegalShareAdapter`）只是股数换算合约，**不是** PermissionsAdapter 代币。

**1:1 的准确口径是 ERC\-20 原始最小单位。**

PermissionsAdapter 已收到 `n` 个可用的底层股票代币最小单位后，`wrapToPoolManager(n)` 向 PoolManager 铸造 `n` 个 PermissionsAdapter 代币最小单位；从 PoolManager 转出时，销毁相同数量的 PermissionsAdapter 代币并向接收方交付相同数量的底层股票代币。Registry 注册时还要求两种代币的 `decimals` 相等。这里的 1:1 不表示一个原始代币单位恒等于一股，也不表示两个合约地址相同。

[ERC\-8056](https://eips.ethereum.org/EIPS/eip-8056) 规定 `uiMultiplier()` 采用 18 位精度（`1e18` 表示 1 倍），用于把原始 ERC\-20 数量换算为展示数量；`balanceOf`、`transfer`、`transferFrom` 和 `totalSupply` 仍使用原始数量。TSV 的 `ERC8056DirectLegalShareAdapter` 读取**底层股票代币**的 `uiMultiplier()`，计算 `legalSharesWad = floor(rawAmount × uiMultiplier / 10^decimals)`。例如底层代币有 6 位精度，`rawAmount = 1,000,000` 时，倍数从 `1e18` 变为 `2e18`，对应的法定股数从 1 股变为 2 股；底层代币和 PermissionsAdapter 代币各自对应的原始数量仍是 `1,000,000`，两者的最小单位 1:1 不变。后端应分别保存原始代币数量和按当前倍数计算的股数。

**与 xStocks 的区别：**按 [xStocks 文档](https://docs.xstocks.fi/docs/dividends-and-stock-splits)，其 EVM 代币通过 rebase 调整 `balanceOf()` 返回的余额；本接入的 ERC\-8056 底层代币在倍率变化时保持 ERC\-20 原始余额不变，另读 `uiMultiplier()` 换算股数。不要把 xStocks 的余额变化、底层代币的 UI 倍数变化、以及 `underlyingToken`/`wrapToken` 的原始单位 1:1 包装混为一谈。

**准入分层：**Factory 的 `PermissionsAdapterCreated` / `PermissionsAdapterVerified` 只证明 wrapper 的创建 / 验证；Factory 可公开调用，事件本身不代表 TSV 已上币。Registry 的 `PermissionedCurrencyRegistered(currency, underlying, securityId, reasonCode)` 确认股票侧准入，`QuoteTokenRegistered` 确认报价侧准入；`UnderlyingBound` 只在某底层代币首次绑定证券时发出，同一证券可有多个发行方底层代币或多个 wrapper。Registry 的 `PoolRegistered(poolId, securityId, tierId, lifecycle)` 与同笔交易中 PoolManager 的 `Initialize` 确认具体池。仅注册 token 不保证已有池；已建池能否执行 Swap / 普通 LP，还须实时查询 `isTradable(poolId)` / `isLPAllowed(poolId)`，并遵守其他身份与合规校验。底层代币不要求统一实现 ERC\-8056；其他固定原始余额、可提供可验证股数换算的发行方方案须有匹配的 `legalShareAdapter` 并通过 Registry 校验。本接入示例使用 ERC\-8056。

股票侧 Registry 注册会校验 wrapper 已由 Factory 验证、绑定本系统 PoolManager、指向真实底层代币、有可用的 allowlist checker，且两种代币地址不同、`decimals` 相同且不超过 18；`legalShareAdapter` 须支持 TSV 换算接口并绑定该底层代币。报价侧须作为独立原始 ERC\-20 注册，不能是已识别的股票侧资产或系统合约。发行方底层代币还须满足**倍率变化不重算 ERC\-20 原始余额**的业务准入要求；当前链上注册校验并不能独自证明发行方未来的代币行为。

### TSV 池中的 CET 识别

#### 前置条件

- 已连接目标网络，并配置对应的 Registry 代理地址。
- 事件追踪还需要 PoolManager 地址和可由 RPC 支持的区块范围。PoolManager 地址可从目标链 Registry 代理的 `permissionedPoolManager()` Getter 获取；也可从该链部署清单的 `dependencies.poolManager` 读取，并核对 `chainId` 与 Registry 地址。Getter 查询需要已知 `poolId`。

#### 方式一：事件追踪

**事件追踪：**监听对应 PoolManager 的 Uniswap v4 `Initialize`，并与同笔交易 Registry 的 `PoolRegistered` 按 `poolId` 配对，以确认这是 TSV 已注册池。读取 `Initialize.currency0/1`，逐个调用该 TSV Registry 的 `getCurrencyUnderlying(currency)`：返回非零 `underlyingToken` 的池币地址是 WCET（池内 PermissionsAdapter / wrapper），返回值是 CET（发行方底层股票代币）。调用 `getUnderlying(CET)` 取得 `securityId` 等信息，并与 `getPool(poolId).securityId` 核对。返回零表示不是已登记的 TSV WCET；不可用 symbol、名称或 Factory 创建事件推断 CET。另一个池币应通过报价代币注册记录确认。

#### 事件追踪 JS 示例

以下 ethers.js v6 脚本用于**事件追踪**。先配置 `provider`、`registryAddress` 和有界区块范围；脚本通过 Registry 的 `permissionedPoolManager()` 自动读取 PoolManager 地址，将 `Initialize` 与同笔交易的 `PoolRegistered` 配对，再校验 PoolKey 并解析币种。Uniswap v4 的池通过单一 PoolManager 初始化，`Initialize` 事件提供完整 PoolKey，参见[Uniswap v4 PoolManager 文档](https://developers.uniswap.org/docs/protocols/v4/concepts/poolmanager)和[读取池储备指南](https://developers.uniswap.org/docs/protocols/v4/guides/reading-pool-reserves)。

```JavaScript
import { Contract, ZeroAddress, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "event PoolRegistered(bytes32 indexed poolId,bytes32 indexed securityId,uint8 indexed tierId,uint8 lifecycle)",
  "function permissionedPoolManager() view returns (address)",
  "function getPool(bytes32) view returns (tuple(tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bytes32 securityId,uint8 tierId,uint8 lifecycle,uint256 tickCount,uint256 poolSecurityIndex))",
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getQuoteToken(address quote) view returns (tuple(uint8 rawDecimals,bool registered))",
], provider);
const poolManagerAddress = await registry.permissionedPoolManager();
const poolManager = new Contract(poolManagerAddress, [
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
], provider);

const [registeredLogs, initializeLogs] = await Promise.all([
  registry.queryFilter(registry.filters.PoolRegistered(), fromBlock, toBlock),
  poolManager.queryFilter(poolManager.filters.Initialize(), fromBlock, toBlock),
]);
const registrationTxByPoolId = new Map(registeredLogs.map(log => [log.args.poolId.toLowerCase(), log.transactionHash.toLowerCase()]));

for (const log of initializeLogs) {
  const poolId = log.args.id;
  if (registrationTxByPoolId.get(poolId.toLowerCase()) !== log.transactionHash.toLowerCase()) continue;

  // Pin reads to the Initialize block and verify the registered PoolKey.
  const pool = await registry.getPool(poolId, { blockTag: log.blockNumber });
  const key = pool.key;
  if (pool.securityId === ZeroHash ||
      key.currency0.toLowerCase() !== log.args.currency0.toLowerCase() ||
      key.currency1.toLowerCase() !== log.args.currency1.toLowerCase() ||
      key.hooks.toLowerCase() !== log.args.hooks.toLowerCase() ||
      Number(key.fee) !== Number(log.args.fee) ||
      Number(key.tickSpacing) !== Number(log.args.tickSpacing)) continue;

  const [underlying0, underlying1] = await Promise.all([
    registry.getCurrencyUnderlying(log.args.currency0, { blockTag: log.blockNumber }),
    registry.getCurrencyUnderlying(log.args.currency1, { blockTag: log.blockNumber }),
  ]);
  // A valid TSV pool has exactly one registered stock-side WCET.
  if ((underlying0 === ZeroAddress) === (underlying1 === ZeroAddress)) continue;

  const wcet = underlying0 !== ZeroAddress ? log.args.currency0 : log.args.currency1;
  const cet = underlying0 !== ZeroAddress ? underlying0 : underlying1;
  const quote = underlying0 === ZeroAddress ? log.args.currency0 : log.args.currency1;
  const [underlyingRecord, quoteRecord] = await Promise.all([
    registry.getUnderlying(cet, { blockTag: log.blockNumber }),
    registry.getQuoteToken(quote, { blockTag: log.blockNumber }),
  ]);
  if (!quoteRecord.registered || underlyingRecord.securityId !== pool.securityId) continue;
  console.log({ poolId, wcet, cet, quote, securityId: pool.securityId, blockNumber: log.blockNumber });
}
```

#### 方式二：Getter 查询

如果已经有 `poolId`，不必回扫创建事件。先读 `registry.getPool(poolId).key` 取 `currency0/1`，再分别调用 `getCurrencyUnderlying`；唯一返回非零底层代币地址的一侧为 WCET，该返回地址为 CET。用 `getUnderlying(CET).securityId` 与 PoolRecord 的 `securityId` 对照，并用 `getQuoteToken` 核对另一侧报价币。报价币的 `registered=false` 仅表示不能用于新建池，不会抹去已建池的资产身份。

#### Getter 查询 JS 示例

以下 ethers.js v6 脚本**只负责按已知 poolId 查询并解析 WCET → CET**：

```JavaScript
import { Contract, ZeroAddress, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "function getPool(bytes32) view returns (tuple(tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bytes32 securityId,uint8 tierId,uint8 lifecycle,uint256 tickCount,uint256 poolSecurityIndex))",
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getQuoteToken(address quote) view returns (tuple(uint8 rawDecimals,bool registered))",
], provider);

const pool = await registry.getPool(poolId);
if (pool.securityId === ZeroHash) throw new Error("Unknown TSV pool");
const { currency0, currency1 } = pool.key;
const [underlying0, underlying1] = await Promise.all([
  registry.getCurrencyUnderlying(currency0),
  registry.getCurrencyUnderlying(currency1),
]);
if ((underlying0 === ZeroAddress) === (underlying1 === ZeroAddress)) {
  throw new Error("Pool must have exactly one registered TSV WCET");
}

const wcet = underlying0 !== ZeroAddress ? currency0 : currency1;
const cet = underlying0 !== ZeroAddress ? underlying0 : underlying1;
const quote = underlying0 === ZeroAddress ? currency0 : currency1;
const [underlyingRecord, quoteRecord] = await Promise.all([
  registry.getUnderlying(cet),
  registry.getQuoteToken(quote),
]);
if (underlyingRecord.securityId !== pool.securityId) {
  throw new Error("Pool token mapping does not match its TSV Registry records");
}
console.log({ poolId, wcet, cet, quote, quoteCurrentlyRegistered: quoteRecord.registered, securityId: pool.securityId });
```

## 一、LP Manager：管理流动性

```Plaintext
用户 / 已获 NFT 授权的 operator → TSVLPManagerV1.modifyLiquidities
管理员 → TSVLPManagerV1.unwindPosition 或 unwindPositionByTsv
```

普通增减仓由 LP Manager 的直接调用者执行；涉及补款时，该调用者也是付款人。后端代发不会自动把用户识别为执行者。Mint、Increase、Decrease、Collect、Burn 都使用 `modifyLiquidities`，强退使用独立入口。

### LP 事件监听与 Token 关联

|监听地址与事件|用途|
|---|---|
|Registry 代理：`PermissionedCurrencyRegistered(currency, underlying, securityId, reasonCode)`、`UnderlyingBound(underlying, securityId, legalShareAdapter, rawDecimals, reasonCode)`、`QuoteTokenRegistered(quote, rawDecimals, reasonCode)`|建立准入的 wrapper → 底层代币 → 证券及报价代币映射；`UnderlyingBound` 仅首次绑定时出现。|
|Registry 代理：`QuoteTokenDisabled`、`UnderlyingPoolRegisterDisabled`、`UnderlyingLegalShareAdapterChanged`、`SecurityDelisted`|更新后续建池准入、换算合约及证券状态；停用新池注册不等于删除既有池。|
|Registry 代理：`PoolRegistered(poolId, securityId, tierId, lifecycle)`、`PoolLifecycleChanged`、`SecurityStatusChanged`、`EmergencyPauseChanged`|识别 TSV 池及后续状态变化；事件触发后回读当前状态。|
|PoolManager：`Initialize(id, currency0, currency1, fee, tickSpacing, hooks, sqrtPriceX96, tick)`|获取完整 PoolKey；只保留 `id == PoolRegistered.poolId` 且 `hooks == registry.hook()` 的池。|
|TSV LP Manager 代理：ERC\-721 `Transfer(from, to, tokenId)`、`ModifyPosition(id, sender, tickLower, tickUpper, liquidityDelta, salt)`|跟踪仓位 NFT 的铸造 / 销毁及普通流动性变化；`salt == bytes32(tokenId)`，`id == poolId`。|
|PoolManager：`ModifyLiquidity(id, sender, tickLower, tickUpper, liquidityDelta, salt)`|核对底层 v4 流动性变化；此处 `sender` 是 LP Manager，不能据此识别 NFT 持有人。|

索引所需的核心事件 ABI（按实际发出事件的合约地址过滤）：

```JavaScript
const tsvIndexEventAbi = [
  "event PermissionsAdapterCreated(address indexed permissionsAdapter,address indexed permissionedToken)",
  "event PermissionsAdapterVerified(address indexed permissionsAdapter,address indexed permissionedToken)",
  "event UnderlyingBound(address indexed underlying,bytes32 indexed securityId,address legalShareAdapter,uint8 rawDecimals,bytes32 reasonCode)",
  "event PermissionedCurrencyRegistered(address indexed currency,address indexed underlying,bytes32 indexed securityId,bytes32 reasonCode)",
  "event QuoteTokenRegistered(address indexed quote,uint8 rawDecimals,bytes32 reasonCode)",
  "event QuoteTokenDisabled(address indexed quote,bytes32 reasonCode)",
  "event UnderlyingPoolRegisterDisabled(address indexed underlying,bytes32 reasonCode)",
  "event UnderlyingLegalShareAdapterChanged(address indexed underlying,address oldAdapter,address newAdapter,bytes32 reasonCode)",
  "event SecurityDelisted(bytes32 indexed securityId,bytes32 reasonCode)",
  "event PoolRegistered(bytes32 indexed poolId,bytes32 indexed securityId,uint8 indexed tierId,uint8 lifecycle)",
  "event PoolLifecycleChanged(bytes32 indexed poolId,bytes32 indexed securityId,uint8 oldLifecycle,uint8 newLifecycle,bytes32 reasonCode)",
  "event SecurityStatusChanged(bytes32 indexed securityId,uint8 oldPauseMode,uint8 newPauseMode)",
  "event EmergencyPauseChanged(bool enabled,address indexed operator,bytes32 reasonCode)",
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
  "event ModifyPosition(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
];
```

建议按 `(chainId, contractAddress, blockHash, transactionHash, logIndex)` 去重，并按区块 hash 处理链重组回滚。同一笔 `initializePool` 交易先由 Registry 发出 `PoolRegistered`，再由 PoolManager 发出 `Initialize`；Factory 的创建 / 验证可能在更早的**其他交易**。索引池时，用 `Initialize.id` 联结 `PoolRegistered.poolId`，再用 `registry.getPool(poolId).key` 校验完整 Key；不要仅凭 Hook 地址或 Factory 事件认定准入。对 `currency0/1` 各调用 `registry.getCurrencyUnderlying(currency)`：非零的一侧是 PermissionsAdapter 代币，返回值才是发行方底层股票代币；另一侧结合 `QuoteTokenRegistered` 历史和 `registry.getQuoteToken(currency)` 确认报价代币；后续 `registered=false` 只表示暂停新池准入，不抹去已有池的资产身份。再由 `registry.getUnderlying(underlyingToken)` 取 `securityId`、`legalShareAdapter` 和精度，并与池的 `securityId` 对齐。Factory 的 `verifiedPermissionsAdapterOf(wrapToken)` 和 wrapper 的 `PERMISSIONED_TOKEN()` 可交叉核验映射；它们不能替代 Registry 准入。

### 市场暂停 / 恢复状态

#### 前置条件

- 已配置目标 TSV Registry 代理地址及 Provider。
- 可用 `securityId` 追踪证券级状态；判断某个池的可操作状态则需要 `poolId`。

#### 方式一：事件追踪

`applySecurityStatus(...)` 成功执行后，Registry 发出 `SecurityStatusChanged(securityId, oldPauseMode, newPauseMode)`。事件提供证券 ID 和变更前后的完整状态码，但不包含 `poolId`。用 `registry.getSecurity(securityId).poolIds` 取得该证券关联的池 ID；暂停位保存在证券记录而非单个池记录中，因此该 `securityId` 下所有 `poolIds` 共用同一 `pauseMode`，这是证券级暂停 / 恢复，不是单池操作。`poolIds` 是累积列表，可能包含已退市池；各池的有效 `isTradable` / `isLPAllowed` 结果仍可能因池生命周期或全局紧急暂停等其他条件不同。

协议级全局紧急暂停是另一项独立状态：监听 Registry 的 `EmergencyPauseChanged(enabled, operator, reasonCode)` 追踪它；它不属于某个 `securityId`，也不会修改任何证券的 `pauseMode`。

```JavaScript
import { Contract } from "ethers";

const registry = new Contract(registryAddress, [
  "event SecurityStatusChanged(bytes32 indexed securityId,uint8 oldPauseMode,uint8 newPauseMode)",
  "event EmergencyPauseChanged(bool enabled,address indexed operator,bytes32 reasonCode)",
  "function getSecurity(bytes32) view returns (tuple(bytes32 securityId,uint8 tierId,bool listed,bytes32[] poolIds,uint32 listedPoolCount,uint8 pauseMode))",
  "function isPaused() view returns (bool)",
], provider);

function decodePauseMode(value, globalPaused = false) {
  const code = Number(value);
  const tradePaused = (code & 0b01) !== 0;
  const addRemoveLpPaused = (code & 0b10) !== 0;
  return {
    swap: globalPaused || tradePaused ? "PAUSED" : "UNPAUSED",
    addRemoveLP: globalPaused || addRemoveLpPaused ? "PAUSED" : "UNPAUSED",
  };
}

registry.on("SecurityStatusChanged", async (securityId, _oldPauseMode, newPauseMode, event) => {
  const [security, globalPaused] = await Promise.all([
    registry.getSecurity(securityId, { blockTag: event.log.blockNumber }),
    registry.isPaused(),
  ]);
  const pauseStatus = decodePauseMode(newPauseMode, globalPaused);
  console.log({
    securityId,
    pauseStatus,
    poolIds: security.poolIds,
    blockNumber: event.log.blockNumber,
  });
});

registry.on("EmergencyPauseChanged", (enabled, operator, reasonCode, event) => {
  console.log({
    globalPause: enabled ? "GLOBAL_PAUSED" : "GLOBAL_UNPAUSED",
    operator,
    reasonCode,
    blockNumber: event.log.blockNumber,
  });
});
```

#### 方式二：Getter 查询

##### 情况一：已知 `poolId`

调用 `getPool(poolId)` 确认池已注册后，直接调用 `isTradable(poolId)` / `isLPAllowed(poolId)` 查询该池当前是否允许 Swap / 普通 LP，并以这两个池级 Getter 的结果生成最终 `pauseStatus`。它们已反映池生命周期、全局暂停等条件，无需再用证券级 `pauseMode` 覆盖。

```JavaScript
import { Contract, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "function getPool(bytes32) view returns (tuple(tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bytes32 securityId,uint8 tierId,uint8 lifecycle,uint256 tickCount,uint256 poolSecurityIndex))",
  "function isTradable(bytes32 poolId) view returns (bool)",
  "function isLPAllowed(bytes32 poolId) view returns (bool)",
], provider);

const pool = await registry.getPool(poolId);
if (pool.securityId === ZeroHash) throw new Error("Unknown TSV pool");
const [swapAllowed, lpAllowed] = await Promise.all([
  registry.isTradable(poolId),
  registry.isLPAllowed(poolId),
]);
const pauseStatus = {
  swap: swapAllowed ? "UNPAUSED" : "PAUSED",
  addRemoveLP: lpAllowed ? "UNPAUSED" : "PAUSED",
};
console.log(pauseStatus);
```

##### 情况二：已知 `securityId`

直接调用 `getSecurity(securityId)` 读取证券级 `pauseMode` 和该证券关联的全部 `poolIds`。此场景最终以 `decodePauseMode(pauseMode, globalPaused)` 得到的证券级 `pauseStatus` 为准；同一证券下的所有 `poolIds` 共用该证券级暂停状态。若要判断某个池当前是否实际允许 Swap / 普通 LP，则以该池的 `isTradable(poolId)` / `isLPAllowed(poolId)` 返回值为准，它们还反映池生命周期等池级条件。

```JavaScript
import { Contract } from "ethers";

const registry = new Contract(registryAddress, [
  "function getSecurity(bytes32) view returns (tuple(bytes32 securityId,uint8 tierId,bool listed,bytes32[] poolIds,uint32 listedPoolCount,uint8 pauseMode))",
  "function isPaused() view returns (bool)",
], provider);

function decodePauseMode(value, globalPaused = false) {
  const code = Number(value);
  const tradePaused = (code & 0b01) !== 0;
  const addRemoveLpPaused = (code & 0b10) !== 0;
  return {
    swap: globalPaused || tradePaused ? "PAUSED" : "UNPAUSED",
    addRemoveLP: globalPaused || addRemoveLpPaused ? "PAUSED" : "UNPAUSED",
  };
}

const security = await registry.getSecurity(securityId);
const globalPaused = await registry.isPaused();
const pauseStatus = decodePauseMode(security.pauseMode, globalPaused);
console.log({
  securityId,
  listed: security.listed,
  pauseStatus,
  poolIds: security.poolIds,
});
```

##### 情况三：已知 CET 地址

CET 是发行方底层股票代币地址。先调用 `getUnderlying(cetAddress)` 取其 `securityId`，再调用 `getSecurity(securityId)` 查询共享的暂停状态和关联池。此场景最终以 `decodePauseMode(pauseMode, globalPaused)` 得到的证券级 `pauseStatus` 为准；该证券下的所有 `poolIds` 共用此证券级暂停状态。若要判断某个池当前是否实际允许 Swap / 普通 LP，则以该池的 `isTradable(poolId)` / `isLPAllowed(poolId)` 返回值为准。不要把池内 WCET 地址传给此路径。

```JavaScript
import { Contract, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "function getUnderlying(address) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getSecurity(bytes32) view returns (tuple(bytes32 securityId,uint8 tierId,bool listed,bytes32[] poolIds,uint32 listedPoolCount,uint8 pauseMode))",
  "function isPaused() view returns (bool)",
], provider);

function decodePauseMode(value, globalPaused = false) {
  const code = Number(value);
  const tradePaused = (code & 0b01) !== 0;
  const addRemoveLpPaused = (code & 0b10) !== 0;
  return {
    swap: globalPaused || tradePaused ? "PAUSED" : "UNPAUSED",
    addRemoveLP: globalPaused || addRemoveLpPaused ? "PAUSED" : "UNPAUSED",
  };
}

const underlying = await registry.getUnderlying(cetAddress);
if (underlying.securityId === ZeroHash) throw new Error("Unknown CET address");
const security = await registry.getSecurity(underlying.securityId);
const globalPaused = await registry.isPaused();
const pauseStatus = decodePauseMode(security.pauseMode, globalPaused);
console.log({
  cetAddress,
  securityId: underlying.securityId,
  pauseStatus,
  poolIds: security.poolIds,
});
```

#### 状态码解析

`SecurityRecord.pauseMode` / `SecurityStatusChanged` 的状态码是两位掩码，不是 `SecurityPauseMode` 枚举序号；事件里的 `oldPauseMode` 和 `newPauseMode` 都是完整掩码。JS 标签定义如下：

- `UNPAUSED`（`00`）：TRADE 与 LP 暂停位都未设置；仅表示未被这两个证券级暂停位拦截，其他准入条件仍需满足。
- `TRADE_PAUSED`（`01`）：设置 TRADE 位，阻止该证券关联池的 Swap；不设置 LP 暂停位。
- `ADD_REMOVE_LP_PAUSED`（`10`）：设置 LP 位，`isLPAllowed(poolId)` 会因该证券暂停位而拒绝普通 LP 仓位操作；不设置 TRADE 暂停位。
- `TRADE_AND_ADD_REMOVE_LP_PAUSED`（`11`）：两个暂停位都设置，Swap 和普通 LP 仓位操作都会被证券级暂停位拦截。

`pauseMode` 表示证券级暂停位，不等同于单池最终是否可操作；池生命周期、全局紧急暂停等其他条件仍可能影响结果。池级判断以 `isTradable` / `isLPAllowed` 的返回值为准。

按位判断当前证券暂停状态：`tradePaused = (pauseMode & 0b01) != 0`，`addRemoveLpPaused = (pauseMode & 0b10) != 0`；只有 `pauseMode == 0` 时，这两个证券级暂停位都未暂停。全局暂停单独读取 `globalPaused = registry.isPaused()`，是布尔值而不是 `pauseMode` 的第三个位。合并两种暂停来源时，对 Swap 和普通 LP 操作分别使用逻辑或：`swapPaused = globalPaused || tradePaused`，`addRemoveLpPaused = globalPaused || addRemoveLpPaused`；未暂停则分别是 `!globalPaused && !tradePaused` 和 `!globalPaused && !addRemoveLpPaused`。示例中的 `decodePauseMode(pauseMode, globalPaused)` 将这些结果合并成一个 `pauseStatus`，其中分别标出 `swap` 和 `addRemoveLP` 当前是 `PAUSED` 还是 `UNPAUSED`。这些公式只表示暂停门控；池能否实际操作仍以 `isTradable(poolId)` / `isLPAllowed(poolId)` 为准。

全局状态不在这四个 `pauseMode` 标签内：`isPaused() == true` 表示 `GLOBAL_PAUSED`，协议级紧急暂停会阻止全局普通 Swap / LP 操作；`false` 表示 `GLOBAL_UNPAUSED`。它与任意证券的 `pauseMode` 可以同时存在，因此后端应分别记录全局布尔值和证券级两位掩码。通过 `setEmergencyPauseEnable(enabled, reasonCode)` 修改；`enabled=true` 需要 `EMERGENCY_PAUSER_ROLE`，`false` 需要 `EMERGENCY_RESUMER_ROLE`，且 `reasonCode` 必须非零。

#### 暂停 / 恢复调用

`applySecurityStatus(securityId, mode, enable, reasonCode)` 中，`mode` 选择要修改的操作，`enable=true` 暂停（置位），`enable=false` 恢复（清位）。枚举与掩码对应关系是 `TRADE=0 → 0001`、`LP=1 → 0010`、`ALL=2 → 0011`。例如当前仅 LP 暂停（`0010`），调用 `TRADE, true` 后为 `0010 | 0001 = 0011`；再调用 `TRADE, false` 后为 `0011 & ~0001 = 0010`，只恢复交易，LP 仍暂停。调用 `ALL, false` 清除两位（`0010 & ~0011 = 0000`）；`ALL, true` 则同时暂停两项，结果为 `0011`。

调用者必须具有 `HALT_REPORTER_ROLE`，目标证券必须已上市，`reasonCode` 必须非零；若所选位已经是目标状态、调用不会改变任何位，合约以 `InvalidStatus` 回滚。每次成功调用后应以回执中的 `SecurityStatusChanged` 和 `getSecurity` 回读确认。

LP 索引请监听 **TSV LP Manager 代理地址**，而不是原版 Uniswap PositionManager 地址。普通 Mint 的 `Transfer` 零地址 → 接收人给出 `tokenId`；`ModifyPosition.salt` 关联同一仓位，增减流动性看 `liquidityDelta`，收手续费时它可能为零；Burn / 强退的 `Transfer` 持有人 → 零地址表示 NFT 销毁。强退类型还要看第 6 节的 `IssuerPositionUnwound` / `TsvPositionUnwound`，发行方强退的逐资产接收人看 `CurrencyUnwound`；不能只看 v4 的 `ModifyLiquidity`。用户余额、付款授权及资产标签应关注**底层股票代币**和报价代币；wrapper 是池内记账资产，用户通常不持有。最终以交易回执及仓位 / Registry 回读为准。

### 1\. 入口与查询 ABI

以下 human\-readable ABI 可直接传入 ethers `Interface`。`PoolKey` 已展开为完整 tuple；`PositionInfo` 的 ABI 类型为 `uint256`。

```JavaScript
import { AbiCoder, Interface, keccak256 } from "ethers";

const lpPoolKeyType = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const lpAbi = [
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function modifyLiquiditiesWithoutUnlock(bytes actions,bytes[] params) payable",
  `function initializePool(${lpPoolKeyType} key,uint160 sqrtPriceX96) payable returns (int24 tick)`,
  "function unwindPosition(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "function unwindPositionByTsv(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function approve(address spender,uint256 tokenId)",
  "function setApprovalForAll(address operator,bool approved)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner,address operator) view returns (bool)",
  `function getPoolAndPositionInfo(uint256 tokenId) view returns (${lpPoolKeyType} poolKey,uint256 info)`,
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function registry() view returns (address)",
  "function FORCE_EXIT_ADMIN_ROLE() view returns (bytes32)",
  "function POOL_CREATOR_ROLE() view returns (bytes32)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed id)",
  "event CurrencyUnwound(uint256 indexed tokenId,address indexed currency,address indexed recipient,address caller,address lp,uint256 amount,bool asClaim)",
  "event IssuerPositionUnwound(uint256 indexed tokenId,address indexed lpOwner,address indexed issuer,address token0,address token1,uint256 lpReceivedAmount0,uint256 issuerReceivedAmount0,uint256 lpReceivedAmount1,uint256 issuerReceivedAmount1)",
  "event TsvPositionUnwound(uint256 indexed tokenId,address indexed lpOwner,address indexed issuer,address token0,address token1,uint256 lpReceivedAmount0,uint256 issuerReceivedAmount0,uint256 lpReceivedAmount1,uint256 issuerReceivedAmount1)",
];

const abiCoder = AbiCoder.defaultAbiCoder();
const lpInterface = new Interface(lpAbi);
```

|入口|用途及调用条件|返回值|
|---|---|---|
|`modifyLiquidities(bytes,uint256)`|用户或已授权 operator 的普通 LP 操作；payable|无|
|`initializePool(PoolKey,uint160)`|`POOL_CREATOR_ROLE` 创建池；payable|`int24 tick`|
|`unwindPosition(uint256,uint128,uint128,bytes)`|PermissionsAdapter 合约 owner 发起强退；nonpayable|无|
|`unwindPositionByTsv(uint256,uint128,uint128,bytes)`|`FORCE_EXIT_ADMIN_ROLE` 发起强退；nonpayable|无|
|`approve(address,uint256)` / `setApprovalForAll(address,bool)`|NFT 授权；不提供 Token 支付授权|无|
|`multicall(bytes[])`|同一调用者执行多项 LP Manager 调用；任一失败全部回滚|各子调用返回的 `bytes[]`|
|`modifyLiquiditiesWithoutUnlock(bytes,bytes[])`|仅供已有 PoolManager unlock 上下文的组合调用；不负责 unlock，也不检查 deadline|无|

普通交易用 `modifyLiquidities`，不要直接调用 `unlockCallback`。代理初始化、升级、订阅及 Permit2 转发不在本指南范围内；普通 LP 付款须直接授权 LP Manager 代理，Permit2 / TokenApprove 授权不能替代。

### 2\. 前置条件与授权

普通 LP 操作，包括领取手续费和普通关闭仓位，均检查：

|检查项|调用或条件|
|---|---|
|全局及池准入|`registry.isPaused() == false`，`registry.isLPAllowed(poolId) == true`|
|SBT|执行者、NFT owner、显式收款人均通过 `registry.isSbtAllowed(0x0002, account)`；仅持有任意 SBT 不够|
|NFT 授权|修改已有仓位时，执行者为 `ownerOf(tokenId)`、`getApproved(tokenId)` 或 owner 的 operator|
|Mint / Increase 发行方准入|PermissionsAdapter 合约已被 Factory 验证、允许池 Hook，且 `permissionsAdapter.isAllowed(owner, 0x0002)`|
|补充股票资产|执行者通过 `permissionsAdapter.isAllowed(executor, 0x0002)`；PermissionsAdapter 合约允许 LP Manager 作为 wrapper|
|付款授权|付款人将实际支付的底层股票代币 / 报价代币直接 `approve` 给 **LP Manager 代理地址**|
|余额与 allowance|付款人余额足够，且 `allowance(payer, lpManagerAddress)` 足够|
|交付|收款人能通过底层股票代币的实际转账合规检查|

用于上述检查的 ABI：

```JavaScript
const lpRegistryAbi = [
  "function isPaused() view returns (bool)",
  "function isLPAllowed(bytes32 poolId) view returns (bool)",
  "function isSbtAllowed(bytes2 permission,address account) view returns (bool)",
  "function hasRole(bytes32 role,address account) view returns (bool)",
  "function getCurrencyUnderlying(address currency) view returns (address)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
];
const lpPermissionsAdapterAbi = [
  "function owner() view returns (address)",
  "function isAllowed(address account,bytes2 permission) view returns (bool)",
  "function allowedHooks(address hook) view returns (bool)",
  "function allowedWrappers(address wrapper) view returns (bool)",
];
const lpTokenAbi = [
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
];
const lpFactoryAbi = [
  "function verifiedPermissionsAdapterOf(address adapter) view returns (address underlyingToken)",
];
const lpLegalShareAdapterAbi = [
  "function currentMultiplier(address underlyingToken) view returns (uint256)",
];
```

Registry 的顺序是 `isSbtAllowed(permission, account)`，PermissionsAdapter 合约的顺序是 `isAllowed(account, permission)`；permission 的 ABI 类型为 **`bytes2`**。`0x0002` 为普通 LP 权限；`0x0004` 仅用于 PermissionsAdapter 合约的强退资格查询。

### 3\. 公共参数

|参数|类型与要求|
|---|---|
|`poolKey`|`(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)`；使用已注册 Key，`currency0 < currency1`；股票侧填 PermissionsAdapter 地址|
|`tokenId`|`uint256`，仓位 NFT ID；用 `getPoolAndPositionInfo`、`getPositionLiquidity` 查询池及流动性，先确认 NFT 存在|
|`liquidity`|`uint256`，流动性单位，不是 Token 数量；按池价、tick 区间和资产预算计算|
|`amount0Max/1Max`|`uint128`，本金支付上限；按 currency0/1 的最小单位计量|
|`amount0Min/1Min`|`uint128`，移除本金最低金额；不包括额外领取的手续费|
|`recipient`|`address`；Mint 时接收 NFT，TAKE\_PAIR 时接收实际资产；建议使用真实地址|
|`hookData`|`bytes`；可为 `0x`，或一个 `uint256 expectedMultiplier` 的 ABI 编码，非空必须为 32 字节<br>如果hookdata=`expectedMultiplier`，合约会检查`expectedMultiplier`与SET的multipiler一致；<br>如果hookdata = 0x，合约会跳过`expectedMultiplier`的检查|
|`deadline`|`uint256`，Unix 秒；`block.timestamp > deadline` 时普通 LP 调用失败|

非空 `hookData` 的倍数需分两步读取：先从 `registry.getUnderlying(underlyingToken)` 取得 `legalShareAdapter` 地址，再对该合约调用 `currentMultiplier(underlyingToken)`；必须非零且与执行时一致。编码方式为 `abiCoder.encode(["uint256"], [expectedMultiplier])`。`poolId` 是完整 PoolKey 的标准 ABI 编码的 keccak256，可用 `keccak256(abiCoder.encode([lpPoolKeyType], [poolKey]))` 计算。

### 4\. 普通 LP 的编码与提交

Mint、Increase、Decrease、Collect、Burn 均使用下面的公共封装。`actions` 每个字节对应一个 `params[i]`；各参数用标准 ABI 编码，只有 action 指令按字节直接拼接。

```JavaScript
function buildLpTransaction(lpManagerAddress, actions, params, deadline) {
  if ((actions.length - 2) / 2 !== params.length) throw new Error("actions/params mismatch");
  const unlockData = abiCoder.encode(["bytes", "bytes[]"], [actions, params]);
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("modifyLiquidities", [unlockData, deadline]),
    value: 0n,
  };
}
```

|Action|指令|单个 `params[i]` 的类型顺序|
|---|---|---|
|`MINT_POSITION`|`0x02`|`PoolKey,int24,int24,uint256,uint128,uint128,address,bytes`|
|`INCREASE_LIQUIDITY`|`0x00`|`uint256,uint256,uint128,uint128,bytes`|
|`DECREASE_LIQUIDITY`|`0x01`|`uint256,uint256,uint128,uint128,bytes`|
|`BURN_POSITION`|`0x03`|`uint256,uint128,uint128,bytes`|
|`SETTLE_PAIR`|`0x0d`|`address,address`|
|`TAKE_PAIR`|`0x11`|`address,address,address`|
|`CLOSE_CURRENCY`|`0x12`|`address`|

下文函数复用本章的 `abiCoder`、`lpInterface`、`lpPoolKeyType` 和 `buildLpTransaction`。所有大整数使用 `bigint`；价格与数量须来自真实查询和报价，不能直接用 JavaScript 浮点数计算。

#### Mint：新建仓位

`tickLower < tickUpper`，两者均对齐 `poolKey.tickSpacing` 且位于合法 tick 范围；`recipient` 接收不可转让的仓位 NFT。

```JavaScript
function buildMintTransaction(input) {
  const { lpManagerAddress, poolKey, tickLower, tickUpper, liquidity,
    amount0Max, amount1Max, recipient, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(
      [lpPoolKeyType, "int24", "int24", "uint256", "uint128", "uint128", "address", "bytes"],
      [poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData],
    ),
    abiCoder.encode(["address", "address"], [poolKey.currency0, poolKey.currency1]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x020d", params, deadline);
}
```

指令为 `MINT_POSITION → SETTLE_PAIR`。成功回执中，筛选 LP Manager 地址发出的 `Transfer` 事件，`from` 为零地址的记录给出新 `tokenId`；不要靠发送前读取 `nextTokenId` 推断最终 ID。

#### Increase：增加流动性

指令为 `INCREASE_LIQUIDITY → CLOSE_CURRENCY → CLOSE_CURRENCY`，同时处理补款和已有手续费产生的剩余款项；剩余款项返回执行者。

```JavaScript
function buildIncreaseTransaction(input) {
  const { lpManagerAddress, poolKey, tokenId, liquidity, amount0Max,
    amount1Max, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(["uint256", "uint256", "uint128", "uint128", "bytes"],
      [tokenId, liquidity, amount0Max, amount1Max, hookData]),
    abiCoder.encode(["address"], [poolKey.currency0]),
    abiCoder.encode(["address"], [poolKey.currency1]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x001212", params, deadline);
}
```

#### Decrease：减少流动性

指令为 `DECREASE_LIQUIDITY → TAKE_PAIR`。`liquidity` 不超过仓位现有流动性；本金及手续费发送给 `recipient`，NFT 保留。

```JavaScript
function buildDecreaseTransaction(input) {
  const { lpManagerAddress, poolKey, tokenId, liquidity, amount0Min,
    amount1Min, recipient, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(["uint256", "uint256", "uint128", "uint128", "bytes"],
      [tokenId, liquidity, amount0Min, amount1Min, hookData]),
    abiCoder.encode(["address", "address", "address"],
      [poolKey.currency0, poolKey.currency1, recipient]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x0111", params, deadline);
}
```

#### Collect：领取手续费

没有独立 collect 入口；复用 Decrease，将流动性变化及本金最低金额设为零。仍须满足普通 LP 的 SBT、NFT 授权和池准入要求。

```JavaScript
function buildCollectTransaction(input) {
  return buildDecreaseTransaction({
    ...input, liquidity: 0n, amount0Min: 0n, amount1Min: 0n,
  });
}
```

#### Burn：普通关闭仓位

指令为 `BURN_POSITION → TAKE_PAIR`。移除全部流动性、结算手续费并销毁 NFT；仍须满足普通 LP 前置条件。

```JavaScript
function buildBurnTransaction(input) {
  const { lpManagerAddress, poolKey, tokenId, amount0Min, amount1Min,
    recipient, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(["uint256", "uint128", "uint128", "bytes"],
      [tokenId, amount0Min, amount1Min, hookData]),
    abiCoder.encode(["address", "address", "address"],
      [poolKey.currency0, poolKey.currency1, recipient]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x0311", params, deadline);
}
```

### 5\. Initialize Pool：创建池

入口为 `initializePool(PoolKey key,uint160 sqrtPriceX96) payable returns (int24 tick)`。

调用者须持有 `POOL_CREATOR_ROLE`，Registry 全局未暂停；PermissionsAdapter 合约、报价代币和证券配置须已准入，至少一侧为 Factory 已验证且 owner 非零的 PermissionsAdapter 合约。池注册和初始化任一失败都会整笔回滚。

`sqrtPriceX96 = floor(sqrt(currency1Raw / currency0Raw) × 2^96)`，按两种资产的最小单位计算，并满足 v4 价格范围；计算时须考虑 decimals。

```JavaScript
function buildInitializePoolTransaction(lpManagerAddress, poolKey, sqrtPriceX96) {
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("initializePool", [poolKey, sqrtPriceX96]),
    value: 0n,
  };
}
```

### 6\. Unwind：管理员强制关闭

两个独立入口均直接调用 LP Manager 代理，无返回值、不可携带原生币，也无需组装 actions。

|前置条件 / 行为|`unwindPosition`|`unwindPositionByTsv`|
|---|---|---|
|调用者|池内任一已验证 PermissionsAdapter 合约的 `owner()`|Registry 的 `FORCE_EXIT_ADMIN_ROLE` 持有者|
|仓位资格|NFT 存在；至少一侧已验证 PermissionsAdapter 合约的 `isAllowed(lp, 0x0004)` 为 true|同左|
|SBT / NFT 授权|不要求 LP 或管理员通过普通 LP SBT 校验，也无需 LP 预先授权 NFT|同左|
|暂停与池准入|全局未暂停；当前版本强退绕过普通 `isLPAllowed`，执行 Hook 时仍检查已注册池及 Hook 身份|同左|
|接收人|每种资产先尝试 LP；失败后仅权限资产尝试该 PermissionsAdapter 合约 owner；仍失败则整笔回滚|两种资产直接发给 LP；任一交付失败则整笔回滚|
|结果|销毁 NFT；不会向用户交付无法赎回的 claim 作为兜底|销毁 NFT|

参数均为 `(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)`；没有 `recipient` 和 `deadline`。`hookData` 规则与普通 LP 相同。**SBT 被撤销不自动等于允许 unwind**，必须实际查询 PermissionsAdapter 合约的 `UNWIND_ALLOWED = 0x0004`。

```JavaScript
function buildIssuerUnwindTransaction(input) {
  const { lpManagerAddress, tokenId, amount0Min, amount1Min, hookData = "0x" } = input;
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("unwindPosition",
      [tokenId, amount0Min, amount1Min, hookData]),
    value: 0n,
  };
}

function buildTsvUnwindTransaction(input) {
  const { lpManagerAddress, tokenId, amount0Min, amount1Min, hookData = "0x" } = input;
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("unwindPositionByTsv",
      [tokenId, amount0Min, amount1Min, hookData]),
    value: 0n,
  };
}
```

发行方强退发出 `IssuerPositionUnwound`，每种非零资产的最终接收人由 `CurrencyUnwound` 给出；TSV 管理员强退发出 `TsvPositionUnwound`，资产直接交付 LP，不走 `CurrencyUnwound` 路径。汇总事件中的 `token0/token1` 是池内 currency 地址；股票侧实际到账应核对底层股票代币的 `Transfer` 和余额。当前版本 `withdrawClaim(address,uint256,address)` 已禁用；普通 LP 入口不能提交 `MINT_6909` 或 `UNWIND_WITH_FALLBACK`。

### 7\. LP 交易提交

以下复用业务钱包提供的 ethers `Signer`，必须与本次操作要求的执行者或管理员一致：

```JavaScript
async function submitLpTransaction(signer, transaction) {
  const from = await signer.getAddress();
  await signer.provider.call({ ...transaction, from });
  const gasLimit = await signer.estimateGas(transaction);
  const response = await signer.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}
// 例：submitLpTransaction(userSigner, buildMintTransaction(mintInput))
// 强退：将 userSigner 换成符合相应权限的管理员 Signer。
```

模拟通过不保证上链时状态不变。常见失败：`RegistryPaused()` 为全局暂停；`PoolNotAllowed()` 为普通 LP 准入失败；`Unauthorized()` 须结合 SBT、发行方及 NFT 授权排查；`LpUnWindable()` 为不满足强退资格；`UnAcceptableScenario()` 为发行方强退无法交付资产。

## 二、Swap Router：单池精确输入兑换

```Plaintext
用户 → Okx DexRouter -> Okx DexRouter Adapter → TSVSwapRouterV1.swapExactInputFromContract
用户 / AA wallet → TSVSwapRouterV1.swapExactInput
```

`swapExactInput` 可由用户或 AA wallet 直接调用；两个 `FromContract` 入口的直接调用者必须是已获授权的合约 Adapter。本章的预付款入口中，`participant` 是身份校验主体；实际付款人和池内输出接收人都是直接调用 Router 的 Adapter。Adapter 再按自己的规则将输出交付外部 `to`。外部交易入口的 calldata 取决于所接入 Adapter 的 ABI，不能由 TSV Router 的 ABI 推导。

这里的 Adapter 是外部交易接入合约，与池中的 `PermissionsAdapter` 合约是不同角色。

### 1\. Swap 入口与查询 ABI

这一章可独立使用，不依赖 LP 的 actions 或编码器。

```JavaScript
import { Interface } from "ethers";

const swapPoolKeyType = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const swapRequestType = `tuple(${swapPoolKeyType} key,bool zeroForOne,uint128 amountSpecified,uint128 limitAmount,uint64 deadline,uint256 expectedMultiplier)`;
const swapRouterAbi = [
  `function swapExactInput(${swapRequestType} request) returns (uint256 actualIn,uint256 actualOut)`,
  `function swapExactInputFromContractDirect(${swapRequestType} request,address payer,address participant,address recipient) returns (uint256 actualIn,uint256 actualOut)`,
  `function swapExactInputFromContract(${swapRequestType} request,address participant) returns (uint256 actualIn,uint256 actualOut)`,
  "function settlementCurrency(address currency) view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool allowed)",
  "function setAdapterAllowed(address adapter,bool allowed)",
  "function registry() view returns (address)",
];
const swapInterface = new Interface(swapRouterAbi);
```

三个 Swap 入口均为 nonpayable，返回 `(uint256 actualIn,uint256 actualOut)`；内部自行组装 Swap、Settle、Take，后端不传 LP `actions` 或 `unlockData`。`swapExactInput(request)` 由调用者自己付款、接收输出并接受身份检查，无需 Adapter allowlist。`swapExactInputFromContractDirect` 的股票输入须先存入 PermissionsAdapter，并传 `payer = address(0)`；报价代币输入传 `payer = msg.sender`，由 Router 在结算时从调用 Adapter 直接划给 PoolManager；`recipient` 必须等于 `participant`。`swapExactInputFromContract` 从调用合约付款并向该合约交付，`participant` 仍是权限主体。后两个入口要求调用合约进入 allowlist；`setAdapterAllowed` 仅供 Registry 的 `DEFAULT_ADMIN_ROLE` 配置调用者。

### 2\. Swap 前置条件与授权

|检查项|调用或条件|
|---|---|
|调用者|`swapExactInput` 由用户或 AA wallet 自行调用；两个 `FromContract` 入口要求 `router.isAdapterAllowed(adapterAddress) == true`，且由该合约实际发起调用|
|全局及池准入|`registry.isPaused() == false`；`registry.isTradable(poolId) == true`；Key 为已注册且绑定正确 Hook 的池|
|SBT|`registry.isSbtAllowed(0x0001, participant) == true`|
|发行方准入|PermissionsAdapter 合约已被验证且允许该 Hook；`swappingEnabled() == true`；`isAllowed(participant, 0x0001) == true`|
|股票输入包装|若输入为底层股票代币，PermissionsAdapter 合约须允许 **Swap Router 代理地址**作为 wrapper|
|报价状态|deadline 未过期；倍数快照匹配；成交量额度允许本次交易|

三个入口的资金来源和授权不同：

|入口|付款人与输入授权|Router 的输出接收人|
|---|---|---|
|`swapExactInput(request)`|调用者持有输入代币，并直接授权 **Swap Router 代理地址**；调用者本人接受 SBT 与发行方权限检查|同一调用者|
|`swapExactInputFromContract(request, participant)`|调用 Router 的已授权合约先持有输入代币，并授权 **Swap Router 代理地址**；Router 从该合约拉取输入，`participant` 只接受权限检查|同一调用合约；外部 Adapter 可再交付给 `to`|
|`swapExactInputFromContractDirect(request, payer, participant, recipient)`|输入 SET：先由 AA wallet 将 SET 存入 PermissionsAdapter，`payer = address(0)`，Router 不再拉 SET；输入报价代币：`payer = msg.sender`，调用 Adapter 持币并授权 **Swap Router 代理地址**，Router 在结算时直接划给 PoolManager|显式 `recipient == participant`；输出 SET 时将 `participant` 设为接收 SET 的 AA wallet|

三个入口在 Router 内都不调用 TokenApprove；若外部 DexRouter 通过 TokenApprove 从用户收取输入，那是 Router 之前的上游步骤，不能替代调用者或 Adapter 对 Router 的授权。Router 检查实际权限主体的 SBT；直结算入口还强制 `recipient == participant`。输出 SET 时，底层代币的转账合规检查仍可能拒绝接收人。

查询和 Token 授权 ABI：

```JavaScript
const swapRegistryAbi = [
  "function isPaused() view returns (bool)",
  "function isTradable(bytes32 poolId) view returns (bool)",
  "function isSbtAllowed(bytes2 permission,address account) view returns (bool)",
  "function getCurrencyUnderlying(address currency) view returns (address)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
];
const swapPermissionsAdapterAbi = [
  "function isAllowed(address account,bytes2 permission) view returns (bool)",
  "function allowedHooks(address hook) view returns (bool)",
  "function allowedWrappers(address wrapper) view returns (bool)",
  "function swappingEnabled() view returns (bool)",
];
const swapTokenAbi = [
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
];
const swapLegalShareAdapterAbi = [
  "function currentMultiplier(address underlyingToken) view returns (uint256)",
];
```

对池 currency 调用 `router.settlementCurrency(currency)` 可取得实际结算代币地址：股票侧返回底层股票代币地址，报价侧返回报价代币自身。预付款入口要求 Adapter 先收到实际输入代币，再由 Adapter 对 Router 授权；若外部 DexRouter 要求用户授权 TokenApprove，该上游授权不能替代 Adapter 对 Router 的授权。

#### Swap 资金流（SET）

以下将底层股票代币称为 **SET**。PoolKey 的股票侧填 **PermissionsAdapter 代币**，不能填 SET；`zeroForOne` 由实际 `currency0/currency1` 排序决定，不能固定为买入或卖出。下表描述本章的 `swapExactInputFromContract`：Router 的付款人和输出接收人均为直接调用它的 Adapter，`participant` 仅用于身份与交易权限校验。

|方向|输入及池内结算|输出交付|
|---|---|---|
|SET → 报价代币|外部流程先将 SET 交给 Adapter；Router 用 Adapter 的授权，将 `amountSpecified` 个 SET 从 Adapter 直接转到 PermissionsAdapter；后者以已收到的 SET 为储备，向 PoolManager 铸造等量 PermissionsAdapter 代币，结清池内股票侧债务|PoolManager 将报价代币交给 Adapter；Adapter 再将本次输出交给外部 `to`|
|报价代币 → SET|外部流程先将报价代币交给 Adapter；Router 在结算时将实际输入量从 Adapter **直接转到 PoolManager**，结清报价代币债务；Router 不持有这笔报价代币|PoolManager 将 PermissionsAdapter 代币转给 Adapter；PermissionsAdapter 在该转账中销毁池内代币，并从自身储备向 Adapter 交付等量 SET；Adapter 再将本次 SET 输出交给外部 `to`|

Router 在资金转移前检查已授权调用者、池和 `participant` 的交易权限；随后执行 `SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL`，并要求实际输入等于 `amountSpecified`。因此，**若直接调用者是独立于 AA wallet 的 DexRouter Adapter，这条预付款流程会让 SET 经过该 Adapter，不能满足“SET 只在 AA wallet 与 PermissionsAdapter 之间转移”**。AA wallet 自己交易可使用 `swapExactInput(request)`，由钱包直接付款和接收输出，无需 Adapter allowlist。

若采用直结算入口满足该 SET 约束：卖出 SET 时，AA wallet 先在同一原子交易中将 SET 转到 PermissionsAdapter，调用时 `payer = address(0)`，Router 不再次转 SET；买入 SET 时，`payer` 为调用 Adapter，报价代币由该 Adapter 直接交给 PoolManager，`participant` 与 `recipient` 均设为接收 SET 的 AA wallet，PermissionsAdapter 将 SET 直接交给该钱包。Router 强制两者相等，但不核验该地址是否属于 AA wallet，接入方须保证传入正确的权限主体。若预存 SET 和 Swap 分属两笔交易，后者失败不会回滚前者的预存。

### 3\. SwapRequest 参数

|字段|ABI 类型|要求|
|---|---|---|
|`key`|`tuple(address,address,uint24,int24,address)`|顺序为 currency0、currency1、fee、tickSpacing、hooks；股票侧填 PermissionsAdapter 地址|
|`zeroForOne`|`bool`|true：currency0 → currency1；false：反向|
|`amountSpecified`|`uint128`|精确输入最小单位数量，`0 < amountSpecified <= 2^127 - 1`|
|`limitAmount`|`uint128`|最低输出最小单位数量，必须大于 0|
|`deadline`|`uint64`|Unix 秒，不是毫秒|
|`expectedMultiplier`|`uint256`|报价时读取的非零倍数；执行时必须一致|
|`participant`|`address`，仅两个 `FromContract` 入口的参数|用户或 AA wallet 身份；预付款入口只用它做权限检查，不从其地址付款；直结算入口要求它等于 `recipient`|
|`payer`|`address`，仅直结算入口的第二个参数|股票输入必须为零地址；报价代币输入必须为调用 Router 的 Adapter 地址|
|`recipient`|`address`，仅直结算入口的第四个参数|必须等于 `participant`；其他两个入口的输出固定交给直接调用者|

倍数读取顺序：先用 `registry.getUnderlying(underlyingToken)` 找到 `legalShareAdapter`，再对该合约调用 `currentMultiplier(underlyingToken)`。价格或倍数变化后应重新报价，不只替换快照数值。

### 4\. 编码 Adapter → Router 调用

`request` 必须包含上表前六个字段，保持原字段名。金额、deadline、expectedMultiplier 使用 `bigint`。

```JavaScript
function buildSwapRouterCall(input) {
  const { routerAddress, poolKey, zeroForOne, amountIn, amountOutMin,
    deadline, expectedMultiplier, participant } = input;
  const request = {
    key: poolKey,
    zeroForOne,
    amountSpecified: amountIn,
    limitAmount: amountOutMin,
    deadline,
    expectedMultiplier,
  };
  return {
    to: routerAddress,
    data: swapInterface.encodeFunctionData("swapExactInputFromContract",
      [request, participant]),
    value: 0n,
  };
}

function buildCallerBoundSwapCall(input) {
  const { routerAddress, poolKey, zeroForOne, amountIn, amountOutMin,
    deadline, expectedMultiplier } = input;
  const request = {
    key: poolKey, zeroForOne, amountSpecified: amountIn,
    limitAmount: amountOutMin, deadline, expectedMultiplier,
  };
  return {
    to: routerAddress,
    data: swapInterface.encodeFunctionData("swapExactInput", [request]),
    value: 0n,
  };
}
```

`buildSwapRouterCall` 供已授权 Adapter 执行内部调用，不要直接交给用户钱包的 `sendTransaction`。调用前 Adapter 须已持有输入资产并向 Router 授权。`buildCallerBoundSwapCall` 可由用户或 AA wallet 直接提交，但须先持有输入资产并授权 Router。完整外部 DexRouter 交易还需外部入口的 ABI。

### 5\. 模拟与结果解析

下面模拟的是内部调用，`adapterAddress` 必须是允许的 Adapter，且在该区块已有足够输入余额和对 Router 的授权；实际外部流程若在同笔交易中才注入资产或授权，应模拟完整外部交易。

```JavaScript
async function simulateSwapRouterCall(provider, adapterAddress, input) {
  const call = buildSwapRouterCall(input);
  const result = await provider.call({ ...call, from: adapterAddress });
  const [actualIn, actualOut] = swapInterface.decodeFunctionResult(
    "swapExactInputFromContract", result,
  );
  return { actualIn, actualOut };
}
```

成功时 `actualIn == amountSpecified` 且 `actualOut >= limitAmount`；未全部消耗输入会整笔回滚。交易回执本身不包含 Solidity 返回值，入账须解析实际成交 / 资产转账日志，不能把模拟输出当成已成交数量。

常见失败：`AdapterNotAllowed()` 为直接调用者未授权；`Expired()` 为过期；`PoolNotTradable()` 为池不可交易；`MultiplierChanged()` 为报价倍数已变；`SlippageExceeded()` 为本路由检查到输入未全部成交或无有效输出，v4 也可能返回自身的最低输出错误。

## 三、Volume Ledger：后端设置每日成交量额度

```Plaintext
持有 VOLUME_ORACLE_ROLE 的后端账户 → TSVVolumeLedgerV1.setQuota / setUsedWad
```

本章使用下方部署清单对应的 `TSVVolumeLedgerV1` ABI。`setQuota` 为一个证券设置持续生效的每日总额度；`setUsedWad` 修正指定 EST day 的已累计成交量，见第 6 节；`multicall` 支持跨证券批量调用，见第 7 节。直接调用 Volume Ledger 代理；两个写入入口均为 nonpayable，无返回值，`value = 0`。

### 1\. 前置条件与 ABI

调用账户须持有 **Ledger 所引用 Registry 中的 \*\*\*\*\*\*\*\*****`VOLUME_ORACLE_ROLE`**，即 `registry.hasRole(keccak256("VOLUME_ORACLE_ROLE"), caller) == true`。`securityId` 使用 Registry 中目标证券的非零 ID；额度按 `securityId` 设置，成交量按 `securityId + ESTDay` 记录。同一证券的多个池共同消耗当日额度，不按池或用户单独分配。

本章示例可独立使用：

```JavaScript
import { Contract, Interface, ZeroAddress, ZeroHash, formatUnits } from "ethers";

const volumeLedgerAbi = [
  "function multicall(bytes[] data) returns (bytes[] results)",
  "function registry() view returns (address)",
  "function currentESTDay() view returns (uint256)",
  "function Quota(bytes32 securityId) view returns (uint256)",
  "function usedWad(bytes32 securityId,uint256 ESTDay) view returns (uint256)",
  "function setQuota(bytes32 securityId,uint256 amount,bytes32 reasonCode)",
  "function setUsedWad(bytes32 securityId,tuple(uint256 ESTDay,uint256 amount)[] values,bytes32 reasonCode)",
  "event QuotaSet(bytes32 indexed securityId,uint256 amount,bytes32 reasonCode)",
  "event UsedWadSet(bytes32 indexed securityId,uint256 indexed ESTDay,uint256 amount,bytes32 reasonCode)",
];
const volumeLedgerInterface = new Interface(volumeLedgerAbi);
const volumeRegistryAbi = [
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getSecurityPauseMode(bytes32 securityId) view returns (uint8 mode)",
  "function applySecurityStatus(bytes32 securityId,uint8 mode,bool enable,bytes32 reasonCode)",
];
```

|参数|ABI 类型|要求|
|---|---|---|
|`securityId`|`bytes32`|目标证券 ID，不能为零；不是 poolId 或代币地址|
|`amount`|`uint256`|持续生效的每日总额度，单位为 **legal\-share WAD（1 股 = ****`10^18`****）**；例如 1,000 股为 `1000n * 10n ** 18n`，不是报价代币金额或底层代币 raw amount|
|`reasonCode`|`bytes32`|后端约定的非零原因码；原样写入事件，合约不校验其业务含义|

### 2\. 从 Token 获取 securityId 并查询当日额度

累计量的准确接口名为 **`usedWad`**，表示已使用的 legal\-share WAD，单位不是美元。以下查询均为 `view`，只需 Provider，无需 Signer 或 `VOLUME_ORACLE_ROLE`。

先通过 `ledger.registry()` 取得对应 Registry 地址，再按已知的股票 Token 类型查询：

|已知地址|获取 `securityId` 的调用链|
|---|---|
|用户持有的底层股票代币 `underlyingToken`|`registry.getUnderlying(underlyingToken).securityId`|
|池内股票侧 `PermissionsAdapter` 地址|先 `underlyingToken = registry.getCurrencyUnderlying(permissionsAdapterAddress)`，再 `registry.getUnderlying(underlyingToken).securityId`|

**不要自行对 token symbol 或地址做 hash 来生成 ****`securityId`****，也不要传入报价代币地址。** 未知 PermissionsAdapter 返回零底层地址，未知底层代币返回默认记录（`securityId == 0`），后端应报错。`registered` 表示该底层代币是否允许用于注册新池，不应仅因其为 false 就丢弃已存储的证券 ID 或历史成交量。

|查询|返回含义|
|---|---|
|`ledger.currentESTDay()`|查询区块对应的 EST day|
|`ledger.Quota(securityId)`|该证券持续生效的每日总额度上限，注意方法名首字母大写|
|`ledger.usedWad(securityId, day)`|当日已累计成交量，买卖都消耗额度，不按方向抵消|

下面一次返回证券 ID、当日上限、累计量和剩余额度。所有调用固定在同一个 `blockTag`，避免跨日或期间成交导致读取口径不一致；`tokenKind` 必须明确是 `"underlying"` 或 `"permissionsAdapter"`。

```JavaScript
async function readDailyVolume(provider, volumeLedgerAddress, stockTokenAddress, tokenKind) {
  if (!["underlying", "permissionsAdapter"].includes(tokenKind)) {
    throw new Error("Expected underlying or permissionsAdapter tokenKind");
  }
  const blockTag = await provider.getBlockNumber();
  const atBlock = { blockTag };
  const ledger = new Contract(volumeLedgerAddress, volumeLedgerAbi, provider);
  const registryAddress = await ledger.registry(atBlock);
  const registry = new Contract(registryAddress, volumeRegistryAbi, provider);
  const underlyingToken = tokenKind === "permissionsAdapter"
    ? await registry.getCurrencyUnderlying(stockTokenAddress, atBlock)
    : stockTokenAddress;
  if (underlyingToken === ZeroAddress) throw new Error("Unknown underlying token");
  const { securityId } = await registry.getUnderlying(underlyingToken, atBlock);
  if (securityId === ZeroHash) throw new Error("Unknown securityId");
  const ESTDay = await ledger.currentESTDay(atBlock);
  const [quotaWad, usedWad] = await Promise.all([
    ledger.Quota(securityId, atBlock),
    ledger.usedWad(securityId, ESTDay, atBlock),
  ]);
  const remainingWad = quotaWad > usedWad ? quotaWad - usedWad : 0n;
  return {
    blockTag, underlyingToken, securityId, ESTDay, quotaWad, usedWad, remainingWad,
    quotaShares: formatUnits(quotaWad, 18),
    usedShares: formatUnits(usedWad, 18),
    remainingShares: formatUnits(remainingWad, 18),
  };
}
// 底层股票代币：readDailyVolume(provider, volumeLedgerAddress, underlyingToken, "underlying")
// 池内股票侧：readDailyVolume(provider, volumeLedgerAddress, permissionsAdapterAddress, "permissionsAdapter")
```

返回的 `quotaWad`、`usedWad`、`remainingWad` 是 `bigint`；用于展示的 `*Shares` 是十进制字符串，不要转换为浮点数参与额度计算。读取到的 `securityId` 可直接用于后续 `setQuota`；如需查询指定日期，使用第 3 节换算得到的 `ESTDay` 查询 `usedWad`，`Quota` 仍只按 `securityId` 查询。

### 3\. EST day：从 UTC Unix timestamp 换算

**输入必须是 Unix timestamp（UTC\+0 基准、秒），直接减去 5 小时，再除以一天的秒数并向下取整。不要先将 timestamp 转为本地时间或 EST 后再次减 5 小时。**

```Plaintext
ESTDay = floor((unixTimestampSeconds - 5 × 3600) / 86400)
       = floor((unixTimestampSeconds - 18000) / 86400)

某个 ESTDay 的 UTC 时间区间：
[ESTDay × 86400 + 18000, (ESTDay + 1) × 86400 + 18000)
```

这与合约 `currentESTDay()` 的 `(block.timestamp - 5 hours) / 1 days` 一致。**全年固定 EST = UTC−5，不启用夏令时；不要使用会切换到 EDT（UTC−4）的 ****`America/New_York`**** 时区规则。** 日界线为 UTC **05:00:00**，即固定 EST 的 00:00:00；UTC 00:00 至 04:59:59 仍属于前一个 EST day。

|UTC 时间|Unix timestamp（秒）|固定 EST 时间（UTC−5）|`ESTDay`|
|---|---|---|---|
|`2026-10-12T04:59:59Z`|`1791781199`|`2026-10-11 23:59:59`|`20737`|
|`2026-10-12T05:00:00Z`|`1791781200`|`2026-10-12 00:00:00`|`20738`|
|`2026-10-13T04:59:59Z`|`1791867599`|`2026-10-12 23:59:59`|`20738`|
|`2026-10-13T05:00:00Z`|`1791867600`|`2026-10-13 00:00:00`|`20739`|

后端可直接复用以下换算。JavaScript 的 `Date.now()` 返回毫秒，须先除以 1,000；`block.timestamp` 已是秒，不要再除以 1,000。

```JavaScript
function toESTDay(unixTimestampSeconds) {
  if (typeof unixTimestampSeconds !== "bigint" || unixTimestampSeconds < 18000n) {
    throw new Error("Expected Unix seconds as bigint, >= 18000");
  }
  return (unixTimestampSeconds - 18000n) / 86400n;
}

const nowUnixSeconds = BigInt(Math.floor(Date.now() / 1000));
const currentESTDay = toESTDay(nowUnixSeconds);
const targetESTDay = toESTDay(1791781200n); // 20738n: 2026-10-12 EST
```

查询“当前日”累计量时，建议用最新链上区块的 `timestamp` 换算，并与 Ledger 的 `currentESTDay()` 核对；服务器时间只用于辅助。`setQuota` 不接收 `ESTDay`，新额度立即用于该证券此后的成交校验；跨 UTC 05:00 时，累计量切换到新日期的独立计数。Ledger 不保存历史额度版本。

### 4\. 编码与提交

`amount` 使用 `bigint`；`setQuota` 不接收日期。

```JavaScript
function buildSetQuotaTransaction(volumeLedgerAddress, securityId, amount, reasonCode) {
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("setQuota", [securityId, amount, reasonCode]),
    value: 0n,
  };
}

async function submitSetQuotaTransaction(oracleSigner, input) {
  const { volumeLedgerAddress, securityId, amount, reasonCode } = input;
  const transaction = buildSetQuotaTransaction(volumeLedgerAddress, securityId, amount, reasonCode);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}

// 示例：securityId、reasonCode、代理地址及 oracleSigner 由业务方提供。
const amount = 1000n * 10n ** 18n; // 此证券后续每天的总额度
```

### 5\. 覆盖语义与结果核对

**`amount`**\*\* 是持续生效的每日总额度，不是追加额度或剩余额度。\*\* 调用直接覆盖 `Quota[securityId]`，不会重置任何日期的 `usedWad[securityId][ESTDay]`。例如当日已用 300 股、总额度 1,000 股，改为 1,200 股后当日剩余 900 股。合约允许将额度降至当日已用量以下，但之后的正成交量交易会因超额失败，直到额度或累计量被调整，或进入使用独立累计量的新一天。

未配置的证券额度默认为 0；设置 `amount = 0` 会阻止该证券后续所有正成交量交易，不表示无限额。每天独立计数，但每天使用同一个当前 `Quota[securityId]`；成交校验使用执行时 `block.timestamp` 对应的 EST day。

`setQuota` 每次仅写入一个证券的一个额度；重复写入以最后一笔成功交易为准。后端应在提交前校验证券 ID 和额度。

成功回执中，筛选 **Volume Ledger 代理地址**发出的 `QuotaSet`，核对 `securityId`、`amount`、`reasonCode`；该事件没有 `ESTDay`。可读取 `Quota(securityId)` 和 `usedWad(securityId, ESTDay)`，按 `max(Quota - usedWad, 0)` 计算指定日期剩余额度；后续交易或额度更新可能改变读取结果。

`setQuota` 常见失败：`InvalidConfig()` 为 `reasonCode` 为零；`Unauthorized()` 为调用者没有 `VOLUME_ORACLE_ROLE`；`InvalidInput()` 为 `securityId` 为零。`QuotaExceeded(bytes32,uint256)` 出现在后续 Swap 的成交量记账阶段，第二个参数也是上述 EST day 整数；超额时整笔 Swap 回滚。

### 6\. Set Used WAD：后端修正当日累计量

`setUsedWad(bytes32 securityId,DailyQuota[] values,bytes32 reasonCode)` 使用 `DailyQuota` tuple，和 `setQuota` 一样要求 Registry 的 `VOLUME_ORACLE_ROLE` 与非零 `reasonCode`。nonpayable，无返回值。调用前确认目标链的 Ledger 实现已包含此接口。

**此处 ****`values[i].amount`**** 是修正后的已累计总量（legal\-share WAD），直接覆盖 ****`usedWad[securityId][ESTDay]`****，不会修改 ****`Quota`****。** 可以调高、调低或设为 0；也允许写入超过额度的累计量，此时后续正成交量交易将失败，直到额度或累计量被调整到足够容纳新成交量。后续成交在修正后的值上继续累加。

例如总额度 1,000 股、累计量 300 股：`setUsedWad` 写入 200 股后，剩余变为 800 股；`setQuota` 写入 1,200 股则只改变总额度，累计量保持原值。两种写入不要混用。

一次调用仅针对一个 `securityId`，可批量修正多个日期；空数组不写入，重复日期以最后一项为准，每项均发出 `UsedWadSet` 事件。`reasonCode` 为零时返回 `InvalidConfig()`；`securityId` 为零时返回 `InvalidInput()`；调用者缺少角色时返回 `Unauthorized()`。历史、当前和未来日期均按传入值写入，合约不限制日期范围。

```JavaScript
function buildSetUsedWadTransaction(volumeLedgerAddress, securityId, values, reasonCode) {
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("setUsedWad", [securityId, values, reasonCode]),
    value: 0n,
  };
}

async function submitSetUsedWadTransaction(oracleSigner, input) {
  const { volumeLedgerAddress, securityId, values, reasonCode } = input;
  const transaction = buildSetUsedWadTransaction(volumeLedgerAddress, securityId, values, reasonCode);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}
// 将目标日累计量修正为 200 股：values = [{ ESTDay: targetESTDay, amount: 200n * 10n ** 18n }]
```

成功回执中筛选 Ledger 代理发出的 `UsedWadSet`，核对证券、日期、新累计量及原因码，再用第 2 节查询回读。**这是绝对值覆盖，没有旧值或版本校验；基于旧查询结果构造修正值，可能覆盖查询后、修正交易执行前新增的成交量。** 后端须协调成交与修正操作的时序，并记录修正原因；单次模拟不能消除这一并发问题。

### 7\. Multicall：跨证券批量设置

Ledger 继承 OpenZeppelin `Multicall`，提供 `multicall(bytes[] data) returns (bytes[] results)`。直接调用 Ledger 代理，`value = 0`；按数组顺序执行各子调用，保留原始 `msg.sender`，每个子调用仍检查自身权限。**任一子调用失败，整笔交易的状态及事件全部回滚。**

单个 `setQuota` / `setUsedWad` 仍只处理一个证券，但可用 `multicall` 将不同 `securityId` 的写入合并为一笔交易，也可组合额度设置和累计量修正。`data` 的每项是完整函数 calldata（含 selector），不是仅包含参数的 ABI 编码；目标均为当前 Ledger，不接受外部合约目标地址。

```JavaScript
function buildVolumeMulticallTransaction(volumeLedgerAddress, updates) {
  const calls = updates.map(({ method, securityId, amount, values, reasonCode }) => {
    if (!["setQuota", "setUsedWad"].includes(method)) {
      throw new Error("Expected setQuota or setUsedWad");
    }
    return method === "setQuota"
      ? volumeLedgerInterface.encodeFunctionData(method, [securityId, amount, reasonCode])
      : volumeLedgerInterface.encodeFunctionData(method, [securityId, values, reasonCode]);
  });
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("multicall", [calls]),
    value: 0n,
  };
}

async function submitVolumeMulticallTransaction(oracleSigner, volumeLedgerAddress, updates) {
  const transaction = buildVolumeMulticallTransaction(volumeLedgerAddress, updates);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}
// setQuota 项：{ method: "setQuota", securityId, amount, reasonCode }
// setUsedWad 项：{ method: "setUsedWad", securityId, values, reasonCode }
```

返回的 `results[i]` 为第 i 项的 ABI 编码返回值；两个写入函数均无返回值，对应 `0x`。交易回执应按 Ledger 代理地址解析 `QuotaSet` / `UsedWadSet` 事件。同一证券的额度或同一证券同一天的累计量重复设置时，最后一次写入生效。该封装只允许两个后端写入方法；合约的 `multicall` 本身可组合其他公开入口，但不会绕过角色或 Hook 调用者检查。

### 8\. Multiplier 变化：同步换算 Quota 与 usedWad

**Ledger 不会随 multiplier 变化自动更新额度或累计量。** 当前 `ERC8056DirectLegalShareAdapter` 的换算为 `legalSharesWad = floor(rawAmount × multiplier / 10^decimals)`。下面的算法用于保持同一原始 Token 数量所对应的额度和累计量，将二者统一换算到新 multiplier 的股数口径；假设 Token decimals 和 Adapter 换算方式不变。

#### 换算公式与取整

设 `Mold` 为这份额度及累计量当前使用的倍率，`Mnew` 为即将采用的新倍率，二者必须大于 0。`Mold` 必须来自后端保存的计量口径记录，不能在倍率生效后把链上最新倍率同时当成新旧值。

```Plaintext
quotaNewWad = floor(quotaOldWad × Mnew / Mold)
usedNewWad  = ceil(usedOldWad × Mnew / Mold)
remainingNewWad = max(quotaNewWad - usedNewWad, 0)
```

比例是 **新倍率 / 旧倍率**，不是反过来。两个 multiplier 使用相同精度，比例中精度相消，不要额外乘除 `10^18`。先做整数乘法，再做整数除法；全部使用 `bigint`，不要先计算浮点比例。额度向下取整、累计量向上取整是本指南的后端保守换算规则，避免换算舍入增加可用额度；不是 `setQuota` / `setUsedWad` 内置的取整逻辑。

|旧倍率 → 新倍率|旧总额度 / 旧累计量（股）|新总额度 / 新累计量（股）|新剩余额度（股）|
|---|---|---|---|
|`1e18 → 2e18`|`1000 / 300`|`2000 / 600`|`1400`|
|`2e18 → 1e18`|`1000 / 300`|`500 / 150`|`350`|

不足 1 WAD 最小单位也要按公式处理：例如 `Mold = 3e18`、`Mnew = 2e18`、`quotaOldWad = 10`、`usedOldWad = 4`，结果为 `quotaNewWad = 6`、`usedNewWad = 3`，剩余 3；此例单位是 WAD 最小整数单位，不是整股。不要把 `usedNewWad` 截断到 `quotaNewWad`，也不要先缩放剩余额度再反推累计量。

#### 后端执行顺序

1. **锁定证券并暂停成交。** 对 `(chainId, ledgerAddress, securityId)` 建立后端排他任务，暂停其他额度/累计量写入。须在新倍率生效前暂停该证券所有池的 Swap，并等待暂停确认。`HALT_REPORTER_ROLE` 可调用 `applySecurityStatus(securityId, 0, true, reasonCode)` 设置 TRADE 暂停位；参数 `mode` 是操作选择枚举（`TRADE=0`、`LP=1`、`ALL=2`），而 `getSecurityPauseMode` 返回的是位掩码（`0` 未暂停、`1` TRADE、`2` LP、`3` ALL）。合约保留未选中的暂停位；恢复时只清除本任务设置的 TRADE 位，调用 `applySecurityStatus(securityId, 0, false, reasonCode)`，两次调用均要求非零 `reasonCode`，无状态变化会回滚。若交易本已暂停则不重复调用，也不得替其他管理员解除暂停。该权限与 `VOLUME_ORACLE_ROLE` 不同，仅停止后端报价不能阻止链上其他交易入口。

2. **确定目标日期及旧口径快照。** 暂停确认后，在同一区块读取 `currentESTDay()`、证券的单个 `Quota` 及目标日的 `usedWad`，并记录区块号、区块 hash、原值和 `Mold`。当前 EST day 必须使用第 3 节公式。`Quota` 只换算一次；仍使用旧倍率口径的未来日期累计量也要换算，已按新口径修正的日期不得重复换算。默认保留已结束日期的历史账；跨 UTC 05:00 后须重新确认恢复交易当天的累计量口径。

3. **确认新倍率及适用范围。** 从 `registry.getUnderlying(underlyingToken).legalShareAdapter` 获取 Adapter，再调用 `currentMultiplier(underlyingToken)` 确认 `Mnew` 已生效；此前可先依据发行方已确认的计划准备计算。只有该证券所有累计量和额度使用同一旧口径，且所有相关底层 Token 采用同一换算比例时，才能对证券总量整体缩放。多个池共享 `securityId`，每个证券每天只换算一次，不能逐池重复写入。

4. **计算并原子写入。** 按上述公式生成单个 `quotaNewWad` 和目标日期的 `usedValues`，在一次 Ledger `multicall` 中执行 `setQuota(securityId, quotaNewWad, reasonCode)` 和 `setUsedWad(securityId, usedValues, reasonCode)`。提交账户须有 `VOLUME_ORACLE_ROLE`；完整批次先模拟、估算 gas，再提交。保持成交、其他写入及进一步倍率变更协调暂停，直到核对完成。Registry 暂停操作和外部 Token 的倍率更新不属于 Ledger `multicall` 的原子范围。

5. **核对后恢复。** 成功回执中核对单个 `QuotaSet` 和全部 `UsedWadSet`；在该回执区块回读额度、累计量与新倍率。确认成功后，后端将证券额度和各目标日累计量的计量口径标记为 `Mnew`，记录交易 hash 和变更事件唯一 ID，再恢复本任务暂停的操作，保留其他管理员设置的暂停状态。失败则维持暂停并处理，不先恢复交易。

`currentMultiplier` 的查询 ABI 为 `function currentMultiplier(address underlyingToken) view returns (uint256)`。Ledger 两个 setter 不接收预期旧值或 multiplier，`multicall` 只保证两次写入原子性，不保证快照仍有效；后台锁、链上暂停和倍率变更协调不能省略。

#### 计算与组装示例

下面复用第 7 节的提交函数。`quotaWad` 是该证券的单个额度，`snapshots` 是同一暂停区块读取的目标日期累计量数组，各项格式为 `{ ESTDay, usedWad }`；这些值均尚未从 `oldMultiplier` 换算到 `newMultiplier`。

```JavaScript
function buildMultiplierSyncUpdates(input) {
  const { securityId, quotaWad, oldMultiplier, newMultiplier, snapshots, reasonCode } = input;
  const maxUint256 = (1n << 256n) - 1n;
  const checkUint256 = (value) => {
    if (typeof value !== "bigint" || value < 0n || value > maxUint256) {
      throw new Error("Expected uint256 bigint");
    }
  };
  checkUint256(oldMultiplier);
  checkUint256(newMultiplier);
  checkUint256(quotaWad);
  if (oldMultiplier === 0n || newMultiplier === 0n) throw new Error("Zero multiplier");
  if (snapshots.length === 0) throw new Error("Empty snapshots");
  const seenDays = new Set();
  const usedValues = [];
  for (const { ESTDay, usedWad } of snapshots) {
    [ESTDay, usedWad].forEach(checkUint256);
    if (seenDays.has(ESTDay)) throw new Error("Duplicate ESTDay");
    seenDays.add(ESTDay);
    const usedNewWad = (usedWad * newMultiplier + oldMultiplier - 1n) / oldMultiplier;
    checkUint256(usedNewWad);
    usedValues.push({ ESTDay, amount: usedNewWad });
  }
  const quotaNewWad = (quotaWad * newMultiplier) / oldMultiplier;
  checkUint256(quotaNewWad);
  return [
    { method: "setQuota", securityId, amount: quotaNewWad, reasonCode },
    { method: "setUsedWad", securityId, values: usedValues, reasonCode },
  ];
}
// const updates = buildMultiplierSyncUpdates(syncInput);
// await submitVolumeMulticallTransaction(oracleSigner, volumeLedgerAddress, updates);
```

#### 重试与已混合口径的处理

后端按证券、日期和倍率变更事件记录处理状态，不要只用 `Mold/Mnew` 这一对数值去重，因为同一倍率变化可能再次发生。网络超时先查原交易回执和链上值；重试只使用已保存的绝对目标值，且须确认暂停仍有效、任务尚未完成、没有后续倍率或管理员修改。**不要读取已经换算后的值再乘同一个比例；恢复成交后也不能重放旧的绝对值，否则会覆盖新增成交量。** `reasonCode` 仅用于事件追溯，合约不据此去重。

如果新倍率生效后已有成交，`usedWad` 可能同时包含旧口径和新口径，不能将整个累计量乘 `Mnew/Mold`。须先暂停，按交易执行顺序和实际倍率分段重建：旧口径部分换算，新口径部分保持不变。例如旧口径累计 300 股，倍率翻倍后又按新口径成交 50 股，正确新累计量为 `300 × 2 + 50 = 650`，不是 `(300 + 50) × 2 = 700`。历史管理员修正和先前同步也要纳入口径记录。单独的 `VolumeUsed` 事件不包含 multiplier，不能仅凭当前倍率推导过去每笔的口径。

上述算法缩放的是已存储的 WAD 总量，可能与按新倍率逐笔重算原始成交量存在最小单位舍入差异；若要求逐笔重算一致，需保存各笔 raw amount 并重新执行 Adapter 的向下取整规则。只有当前总量、没有可信旧倍率和分段记录时，无法可靠恢复混合口径，应保持暂停并完成对账后再写入。

## 源码依据

- LP：TSVLPManagerV1、校验与强退逻辑、继承的 PositionManager。

- Swap：TSVSwapRouterV1、SwapRequest、Hook。

---

# English Version：

This guide follows the structure of Uniswap's [Managing Liquidity](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/overview) guide: prerequisites, ABI, encoding, and submission\. **LP operations and swaps use different entry points and are described separately below\.**

> Based on the X Layer deployment manifest below and its matching contract ABIs in `docs/artifacts/`\. Use proxy addresses for all business operations, and ensure that the ABI matches the version deployed on the target chain\. Examples use ethers\.js v6\. The encoding functions generate calldata, and the submission examples reuse a Signer supplied by the integrating application\. The integrator is responsible for obtaining quotes and signed authorizations\.

This document uses three distinct terms: the **PermissionsAdapter token** is the stock\-side asset held in the pool; the **underlying stock token** is the stock asset that users actually hold; and the **quote token** is the other asset in the pool\. PermissionsAdapter tokens and underlying stock tokens have a 1:1 relationship in their smallest units\. All examples below apply to ERC\-20 pools, with transaction `value = 0`\.

# Test Contract Addresses:

```json
{
  "network": "X Layer Mainnet",
  "chainId": 196,
  "deploymentDate": "2026-10-14",
  "deploymentStatus": "confirmed",
  "sourceVerification": false,
  "proxies": {
    "TSVRegistryV1": "0x2233ea2044ffa04ccceeef0b9adfe0799505a908",
    "TSVVolumeLedgerV1": "0x4fbffbe7ca5ce0fc3af30c9f305e0f6365ff3bc2",
    "TSVSwapRouterV1": "0xe5df3ab010bb20094f490dfcf61b6e2d9a3311c8",
    "TSVLPManagerV1": "0xf73d8683b948564d2795c62a2a909012ea168d29",
    "TSVHookV1": "0xbc6d8c8a8b681872a93554116f01268f80c9ffff"
  },
  "factories": {
    "PermissionsAdapterFactory": "0x92cdb229613da8ca45e375cf69df4b3b645ff48d",
    "TSVHookProxyFactoryV1": "0x3c3e76f4beb314713901183ed6e511928e1d2a99",
    "SmartWalletFactory": "0x1eb8d87d616f31591cfd21f30458c8168b1c1b80"
  }
}
```

[TSV合约地址（主网测试/预发）](https://okg-block.sg.larksuite.com/wiki/Jafww6KotiXI0GkecnUln4kfgqd?from=vcFollow)

## 0\. Tokens in the System and Admission

TSV is a trading protocol and **does not issue a separate user\-held “TSV stock token”**\. Users hold the issuer's underlying stock token; the pool uses its PermissionsAdapter token \(`wrapToken`\) on the stock side and a quote token on the other side\. The position NFT and identity SBT are separate from these three exchangeable assets\.

### `underlyingToken` and `wrapToken`

|Name|Contract address and role|
|---|---|
|**Underlying stock token**, `underlyingToken` \(for example, SET\)|The issuer's ERC\-20 token held and transferred by users; in this integration it exposes the ERC\-8056 `uiMultiplier()`\.|
|**PermissionsAdapter token**, `wrapToken`|The PermissionsAdapter contract is itself an ERC\-20 token and is the stock\-side `currency0` or `currency1` in PoolKey\. PoolManager holds it; the underlying stock tokens backing it are held by PermissionsAdapter\. Its address differs from `underlyingToken`\.|
|**Quote token**|The ERC\-20 asset on the other side, such as USDT; it is outside the stock token's 1:1 wrapper relationship\.|

For a Factory\-verified and Registry\-registered stock currency, `PermissionsAdapter(wrapToken).PERMISSIONED_TOKEN() == factory.verifiedPermissionsAdapterOf(wrapToken) == registry.getCurrencyUnderlying(wrapToken) == underlyingToken`\. `registry.getUnderlying(underlyingToken)` returns its `securityId`, `legalShareAdapter`, and `rawDecimals`\. The `legalShareAdapter` \(here `ERC8056DirectLegalShareAdapter`\) is a share\-conversion contract, **not** the PermissionsAdapter token\.

**The 1:1 relationship is in raw ERC\-20 smallest units\.** After PermissionsAdapter receives `n` available underlying stock token units, `wrapToPoolManager(n)` mints `n` PermissionsAdapter token units to PoolManager\. When PoolManager transfers those wrapper units out, they are burned and the same number of underlying stock token units is delivered to the recipient\. Registry also requires equal `decimals` for the pair\. This does not mean one raw token unit always equals one share or that the two contracts have the same address\.

[ERC\-8056](https://eips.ethereum.org/EIPS/eip-8056) specifies an 18\-decimal `uiMultiplier()` \(`1e18` means 1×\) for converting raw ERC\-20 amounts to displayed amounts; `balanceOf`, `transfer`, `transferFrom`, and `totalSupply` continue to use raw amounts\. TSV's `ERC8056DirectLegalShareAdapter` reads `uiMultiplier()` from the **underlying stock token** and computes `legalSharesWad = floor(rawAmount × uiMultiplier / 10^decimals)`\. With 6 decimals and `rawAmount = 1,000,000`, a multiplier change from `1e18` to `2e18` changes the legal\-share amount from 1 to 2 shares, while the raw underlying and wrapper amounts remain `1,000,000` each\. The backend should store raw token amounts and multiplier\-based share amounts separately\.

**Compared with xStocks:** [xStocks documents](https://docs.xstocks.fi/docs/dividends-and-stock-splits) describe EVM rebasing that changes the balance returned by `balanceOf()`\. The ERC\-8056 underlying token in this integration keeps its raw ERC\-20 balance unchanged when its multiplier changes and exposes `uiMultiplier()` for share conversion\. Do not conflate xStocks balance changes, the underlying token's UI multiplier, and the raw\-unit 1:1 underlying/wrapper conversion\.

**Admission has distinct stages:** Factory's `PermissionsAdapterCreated` / `PermissionsAdapterVerified` only establish creation / verification of a wrapper\. Factory calls are public, so these events alone do not mean TSV has listed it\. Registry's `PermissionedCurrencyRegistered(currency, underlying, securityId, reasonCode)` admits the stock currency, while `QuoteTokenRegistered` admits a quote token\. `UnderlyingBound` is emitted only when an underlying is first bound to a security; one security may have multiple issuer underlying tokens or wrappers\. Registry's `PoolRegistered(poolId, securityId, tierId, lifecycle)` and PoolManager's `Initialize` in the same transaction identify a specific pool\. Token registration does not guarantee an initialized pool\. For an existing pool, query `isTradable(poolId)` / `isLPAllowed(poolId)` at execution time and apply the remaining identity and compliance checks\. The protocol does not require every underlying to implement ERC\-8056: another issuer design with stable raw balances and verifiable share conversion needs a matching `legalShareAdapter` that passes Registry checks\. This integration uses ERC\-8056\.

For stock admission, Registry checks that Factory has verified the wrapper, that it is bound to this system's PoolManager and the actual underlying, that its allowlist checker is valid, that the two token addresses differ, and that their `decimals` match and do not exceed 18\. The `legalShareAdapter` must support TSV's conversion interface and bind to that underlying\. A quote must be registered separately as an original ERC\-20 and cannot be an identified stock\-side asset or system contract\. Issuer underlying tokens must also meet the **business admission rule that multiplier updates do not rebase raw ERC\-20 balances**; registration checks alone cannot prove how an issuer token will behave in the future\.

### CET Identification in TSV Pools

#### Prerequisites

- Connect to the target network and configure its Registry proxy address.
- Event tracking also requires the PoolManager address and an RPC-supported block range. Read the address from `permissionedPoolManager()` on the target chain's Registry proxy, or from `dependencies.poolManager` in that chain's deployment manifest; verify the `chainId` and Registry address. Getter queries require a known `poolId`.

#### Path 1: Event Tracking

**Event tracking:** Listen for Uniswap v4 `Initialize` from the relevant PoolManager and pair it with the Registry `PoolRegistered` event from the same transaction by `poolId` to confirm TSV admission\. Read `Initialize.currency0/1` and call `getCurrencyUnderlying(currency)` on the TSV Registry for each\. The pool currency whose call returns a nonzero `underlyingToken` address is WCET (the in\-pool PermissionsAdapter / wrapper); that returned address is CET (the issuer's underlying stock token)\. Call `getUnderlying(CET)` for its `securityId` and match it to `getPool(poolId).securityId`\. A zero return means the currency is not a registered TSV WCET; do not infer CET from its symbol, name, or a Factory creation event\. Confirm the other currency as the quote token from Registry records\.

#### Event Tracking JS Example

This ethers.js v6 script is for **event tracking**\. Configure `provider`, `registryAddress`, and a bounded block range; the script reads the PoolManager address from Registry's `permissionedPoolManager()`, pairs `Initialize` with `PoolRegistered` from the same transaction, verifies the PoolKey, and resolves the token mapping\. Uniswap v4 initializes pools through a singleton PoolManager, and `Initialize` provides the full PoolKey; see the [Uniswap v4 PoolManager docs](https://developers.uniswap.org/docs/protocols/v4/concepts/poolmanager) and [Reading Pool Reserves guide](https://developers.uniswap.org/docs/protocols/v4/guides/reading-pool-reserves)\.

```JavaScript
import { Contract, ZeroAddress, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "event PoolRegistered(bytes32 indexed poolId,bytes32 indexed securityId,uint8 indexed tierId,uint8 lifecycle)",
  "function permissionedPoolManager() view returns (address)",
  "function getPool(bytes32) view returns (tuple(tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bytes32 securityId,uint8 tierId,uint8 lifecycle,uint256 tickCount,uint256 poolSecurityIndex))",
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getQuoteToken(address quote) view returns (tuple(uint8 rawDecimals,bool registered))",
], provider);
const poolManagerAddress = await registry.permissionedPoolManager();
const poolManager = new Contract(poolManagerAddress, [
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
], provider);

const [registeredLogs, initializeLogs] = await Promise.all([
  registry.queryFilter(registry.filters.PoolRegistered(), fromBlock, toBlock),
  poolManager.queryFilter(poolManager.filters.Initialize(), fromBlock, toBlock),
]);
const registrationTxByPoolId = new Map(registeredLogs.map(log => [log.args.poolId.toLowerCase(), log.transactionHash.toLowerCase()]));

for (const log of initializeLogs) {
  const poolId = log.args.id;
  if (registrationTxByPoolId.get(poolId.toLowerCase()) !== log.transactionHash.toLowerCase()) continue;

  const pool = await registry.getPool(poolId, { blockTag: log.blockNumber });
  const key = pool.key;
  if (pool.securityId === ZeroHash ||
      key.currency0.toLowerCase() !== log.args.currency0.toLowerCase() ||
      key.currency1.toLowerCase() !== log.args.currency1.toLowerCase() ||
      key.hooks.toLowerCase() !== log.args.hooks.toLowerCase() ||
      Number(key.fee) !== Number(log.args.fee) ||
      Number(key.tickSpacing) !== Number(log.args.tickSpacing)) continue;

  const [underlying0, underlying1] = await Promise.all([
    registry.getCurrencyUnderlying(log.args.currency0, { blockTag: log.blockNumber }),
    registry.getCurrencyUnderlying(log.args.currency1, { blockTag: log.blockNumber }),
  ]);
  if ((underlying0 === ZeroAddress) === (underlying1 === ZeroAddress)) continue;

  const wcet = underlying0 !== ZeroAddress ? log.args.currency0 : log.args.currency1;
  const cet = underlying0 !== ZeroAddress ? underlying0 : underlying1;
  const quote = underlying0 === ZeroAddress ? log.args.currency0 : log.args.currency1;
  const [underlyingRecord, quoteRecord] = await Promise.all([
    registry.getUnderlying(cet, { blockTag: log.blockNumber }),
    registry.getQuoteToken(quote, { blockTag: log.blockNumber }),
  ]);
  if (!quoteRecord.registered || underlyingRecord.securityId !== pool.securityId) continue;
  console.log({ poolId, wcet, cet, quote, securityId: pool.securityId, blockNumber: log.blockNumber });
}
```

#### Path 2: Getter Query

If you already have a `poolId`, you do not need to scan creation events. Read `registry.getPool(poolId).key` for `currency0/1`, then call `getCurrencyUnderlying` for each. The only side returning a nonzero underlying token is WCET, and the returned address is CET. Match `getUnderlying(CET).securityId` with the PoolRecord security and verify the other side with `getQuoteToken`. A quote token's `registered=false` only blocks new pool creation; it does not erase the identity of an existing pool\.

#### Getter Query JS Example

This ethers.js v6 script **only resolves WCET → CET from a known poolId**:

```JavaScript
import { Contract, ZeroAddress, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "function getPool(bytes32) view returns (tuple(tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bytes32 securityId,uint8 tierId,uint8 lifecycle,uint256 tickCount,uint256 poolSecurityIndex))",
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getQuoteToken(address quote) view returns (tuple(uint8 rawDecimals,bool registered))",
], provider);

const pool = await registry.getPool(poolId);
if (pool.securityId === ZeroHash) throw new Error("Unknown TSV pool");
const { currency0, currency1 } = pool.key;
const [underlying0, underlying1] = await Promise.all([
  registry.getCurrencyUnderlying(currency0),
  registry.getCurrencyUnderlying(currency1),
]);
if ((underlying0 === ZeroAddress) === (underlying1 === ZeroAddress)) {
  throw new Error("Pool must have exactly one registered TSV WCET");
}

const wcet = underlying0 !== ZeroAddress ? currency0 : currency1;
const cet = underlying0 !== ZeroAddress ? underlying0 : underlying1;
const quote = underlying0 === ZeroAddress ? currency0 : currency1;
const [underlyingRecord, quoteRecord] = await Promise.all([
  registry.getUnderlying(cet),
  registry.getQuoteToken(quote),
]);
if (underlyingRecord.securityId !== pool.securityId) {
  throw new Error("Pool token mapping does not match its TSV Registry records");
}
console.log({ poolId, wcet, cet, quote, quoteCurrentlyRegistered: quoteRecord.registered, securityId: pool.securityId });
```

## I\. LP Manager: Managing Liquidity

```Plaintext
User / operator with NFT approval → TSVLPManagerV1.modifyLiquidities
Administrator → TSVLPManagerV1.unwindPosition or unwindPositionByTsv
```

Ordinary liquidity additions and removals are executed by the direct caller of LP Manager\. When additional funds are required, that caller is also the payer\. A backend submitting a transaction on a user's behalf does not automatically make the user the executor\. Mint, Increase, Decrease, Collect, and Burn all use `modifyLiquidities`; forced exits use separate entry points\.

### LP Event Monitoring and Token Resolution

|Emitter and event|Purpose|
|---|---|
|Registry proxy: `PermissionedCurrencyRegistered(currency, underlying, securityId, reasonCode)`, `UnderlyingBound(underlying, securityId, legalShareAdapter, rawDecimals, reasonCode)`, `QuoteTokenRegistered(quote, rawDecimals, reasonCode)`|Build the admitted wrapper → underlying → security mapping and identify quote tokens\. `UnderlyingBound` appears only for the first binding\.|
|Registry proxy: `QuoteTokenDisabled`, `UnderlyingPoolRegisterDisabled`, `UnderlyingLegalShareAdapterChanged`, `SecurityDelisted`|Update future pool admission, conversion contract, and security status\. Disabling registration for new pools does not remove existing pools\.|
|Registry proxy: `PoolRegistered(poolId, securityId, tierId, lifecycle)`, `PoolLifecycleChanged`, `SecurityStatusChanged`, `EmergencyPauseChanged`|Identify TSV pools and subsequent status changes; read current state after an event\.|
|PoolManager: `Initialize(id, currency0, currency1, fee, tickSpacing, hooks, sqrtPriceX96, tick)`|Obtain the full PoolKey; retain pools where `id == PoolRegistered.poolId` and `hooks == registry.hook()`\.|
|TSV LP Manager proxy: ERC\-721 `Transfer(from, to, tokenId)`, `ModifyPosition(id, sender, tickLower, tickUpper, liquidityDelta, salt)`|Track position NFT creation / destruction and ordinary liquidity changes; `salt == bytes32(tokenId)` and `id == poolId`\.|
|PoolManager: `ModifyLiquidity(id, sender, tickLower, tickUpper, liquidityDelta, salt)`|Cross\-check core v4 liquidity changes\. Here `sender` is LP Manager, so it does not identify the NFT owner\.|

Core event ABIs for indexing \(filter by the emitting contract address\):

```JavaScript
const tsvIndexEventAbi = [
  "event PermissionsAdapterCreated(address indexed permissionsAdapter,address indexed permissionedToken)",
  "event PermissionsAdapterVerified(address indexed permissionsAdapter,address indexed permissionedToken)",
  "event UnderlyingBound(address indexed underlying,bytes32 indexed securityId,address legalShareAdapter,uint8 rawDecimals,bytes32 reasonCode)",
  "event PermissionedCurrencyRegistered(address indexed currency,address indexed underlying,bytes32 indexed securityId,bytes32 reasonCode)",
  "event QuoteTokenRegistered(address indexed quote,uint8 rawDecimals,bytes32 reasonCode)",
  "event QuoteTokenDisabled(address indexed quote,bytes32 reasonCode)",
  "event UnderlyingPoolRegisterDisabled(address indexed underlying,bytes32 reasonCode)",
  "event UnderlyingLegalShareAdapterChanged(address indexed underlying,address oldAdapter,address newAdapter,bytes32 reasonCode)",
  "event SecurityDelisted(bytes32 indexed securityId,bytes32 reasonCode)",
  "event PoolRegistered(bytes32 indexed poolId,bytes32 indexed securityId,uint8 indexed tierId,uint8 lifecycle)",
  "event PoolLifecycleChanged(bytes32 indexed poolId,bytes32 indexed securityId,uint8 oldLifecycle,uint8 newLifecycle,bytes32 reasonCode)",
  "event SecurityStatusChanged(bytes32 indexed securityId,uint8 oldPauseMode,uint8 newPauseMode)",
  "event EmergencyPauseChanged(bool enabled,address indexed operator,bytes32 reasonCode)",
  "event Initialize(bytes32 indexed id,address indexed currency0,address indexed currency1,uint24 fee,int24 tickSpacing,address hooks,uint160 sqrtPriceX96,int24 tick)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed tokenId)",
  "event ModifyPosition(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
  "event ModifyLiquidity(bytes32 indexed id,address indexed sender,int24 tickLower,int24 tickUpper,int256 liquidityDelta,bytes32 salt)",
];
```

Deduplicate using `(chainId, contractAddress, blockHash, transactionHash, logIndex)` and roll back orphaned block hashes after chain reorganizations\. In one `initializePool` transaction, Registry emits `PoolRegistered` before PoolManager emits `Initialize`; Factory creation / verification can occur in **earlier, separate transactions**\. Join `Initialize.id` to `PoolRegistered.poolId`, then verify the full key with `registry.getPool(poolId).key`\. Neither the Hook address alone nor Factory events prove TSV admission\. For each `currency0/1`, call `registry.getCurrencyUnderlying(currency)`: a nonzero result marks the PermissionsAdapter token, and that result is the issuer's underlying stock token\. Identify the other side from historical `QuoteTokenRegistered` events and `registry.getQuoteToken(currency)`; a later `registered=false` only blocks new pool admission and does not erase an existing pool's asset identity\. Then read `registry.getUnderlying(underlyingToken)` for `securityId`, `legalShareAdapter`, and decimals, and match the security to the pool\. Factory's `verifiedPermissionsAdapterOf(wrapToken)` and the wrapper's `PERMISSIONED_TOKEN()` can cross\-check the mapping; they do not replace Registry admission\.

### Market Pause / Resume Status

#### Prerequisites

- Configure the target TSV Registry proxy address and a Provider.
- Use `securityId` to track security-level status; use `poolId` to check whether a specific pool currently permits operations.

#### Path 1: Event Tracking

After a successful `applySecurityStatus(...)` call, the Registry emits `SecurityStatusChanged(securityId, oldPauseMode, newPauseMode)`. The event contains the security ID and complete before / after status codes, but no `poolId`. Call `registry.getSecurity(securityId).poolIds` to obtain pools associated with the security. The pause bits are stored on the security record, not per pool, so every `poolId` under that `securityId` shares the same `pauseMode`; this is a security-wide pause / resume, not a per-pool operation. `poolIds` is append-only and may include delisted pools. A pool's effective `isTradable` / `isLPAllowed` result can still differ because of other conditions such as pool lifecycle or the global emergency pause.

The protocol-wide emergency pause is a separate state: track it through the Registry's `EmergencyPauseChanged(enabled, operator, reasonCode)` event. It is not associated with a `securityId` and does not change any security's `pauseMode`.

```JavaScript
import { Contract } from "ethers";

const registry = new Contract(registryAddress, [
  "event SecurityStatusChanged(bytes32 indexed securityId,uint8 oldPauseMode,uint8 newPauseMode)",
  "event EmergencyPauseChanged(bool enabled,address indexed operator,bytes32 reasonCode)",
  "function getSecurity(bytes32) view returns (tuple(bytes32 securityId,uint8 tierId,bool listed,bytes32[] poolIds,uint32 listedPoolCount,uint8 pauseMode))",
  "function isPaused() view returns (bool)",
], provider);

function decodePauseMode(value, globalPaused = false) {
  const code = Number(value);
  const tradePaused = (code & 0b01) !== 0;
  const addRemoveLpPaused = (code & 0b10) !== 0;
  return {
    swap: globalPaused || tradePaused ? "PAUSED" : "UNPAUSED",
    addRemoveLP: globalPaused || addRemoveLpPaused ? "PAUSED" : "UNPAUSED",
  };
}

registry.on("SecurityStatusChanged", async (securityId, _oldPauseMode, newPauseMode, event) => {
  const [security, globalPaused] = await Promise.all([
    registry.getSecurity(securityId, { blockTag: event.log.blockNumber }),
    registry.isPaused(),
  ]);
  const pauseStatus = decodePauseMode(newPauseMode, globalPaused);
  console.log({
    securityId,
    pauseStatus,
    poolIds: security.poolIds,
    blockNumber: event.log.blockNumber,
  });
});

registry.on("EmergencyPauseChanged", (enabled, operator, reasonCode, event) => {
  console.log({
    globalPause: enabled ? "GLOBAL_PAUSED" : "GLOBAL_UNPAUSED",
    operator,
    reasonCode,
    blockNumber: event.log.blockNumber,
  });
});
```

#### Path 2: Getter Queries

Given a `poolId`, call `registry.isTradable(poolId)` and `registry.isLPAllowed(poolId)` directly to determine whether that pool currently permits swaps / ordinary LP operations. To read the security-level pause status, first get `securityId` from `registry.getPool(poolId).securityId`, then call `registry.getSecurity(securityId)` and read `pauseMode`. If `securityId` is already known, call `getSecurity(securityId)` directly.

##### Case 1: Known `poolId`

Call `getPool(poolId)` to confirm the pool is registered, then call `isTradable(poolId)` / `isLPAllowed(poolId)` directly and use these pool-level Getter results to produce the final `pauseStatus`. They already reflect pool lifecycle, global pause, and other conditions; do not override them with the security-level `pauseMode`.

```JavaScript
import { Contract, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "function getPool(bytes32) view returns (tuple(tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks) key,bytes32 securityId,uint8 tierId,uint8 lifecycle,uint256 tickCount,uint256 poolSecurityIndex))",
  "function isTradable(bytes32 poolId) view returns (bool)",
  "function isLPAllowed(bytes32 poolId) view returns (bool)",
], provider);

const pool = await registry.getPool(poolId);
if (pool.securityId === ZeroHash) throw new Error("Unknown TSV pool");
const [swapAllowed, lpAllowed] = await Promise.all([
  registry.isTradable(poolId),
  registry.isLPAllowed(poolId),
]);
const pauseStatus = {
  swap: swapAllowed ? "UNPAUSED" : "PAUSED",
  addRemoveLP: lpAllowed ? "UNPAUSED" : "PAUSED",
};
console.log(pauseStatus);
```

##### Case 2: Known `securityId`

Call `getSecurity(securityId)` directly to read the security-level `pauseMode` and every associated `poolId`. In this case, the final security-level `pauseStatus` is `decodePauseMode(pauseMode, globalPaused)`; all pools under that security share this security-level pause state. To determine whether a particular pool currently allows swaps / ordinary LP, use that pool's `isTradable(poolId)` / `isLPAllowed(poolId)` return values as the final authority; these also reflect pool-level conditions such as lifecycle.

```JavaScript
import { Contract } from "ethers";

const registry = new Contract(registryAddress, [
  "function getSecurity(bytes32) view returns (tuple(bytes32 securityId,uint8 tierId,bool listed,bytes32[] poolIds,uint32 listedPoolCount,uint8 pauseMode))",
  "function isPaused() view returns (bool)",
], provider);

function decodePauseMode(value, globalPaused = false) {
  const code = Number(value);
  const tradePaused = (code & 0b01) !== 0;
  const addRemoveLpPaused = (code & 0b10) !== 0;
  return {
    swap: globalPaused || tradePaused ? "PAUSED" : "UNPAUSED",
    addRemoveLP: globalPaused || addRemoveLpPaused ? "PAUSED" : "UNPAUSED",
  };
}

const security = await registry.getSecurity(securityId);
const globalPaused = await registry.isPaused();
const pauseStatus = decodePauseMode(security.pauseMode, globalPaused);
console.log({
  securityId,
  listed: security.listed,
  pauseStatus,
  poolIds: security.poolIds,
});
```

##### Case 3: Known CET address

CET is the issuer's underlying stock-token address. Call `getUnderlying(cetAddress)` to obtain its `securityId`, then call `getSecurity(securityId)` to read the shared pause state and associated pools. In this case, the final security-level `pauseStatus` is `decodePauseMode(pauseMode, globalPaused)`; all pools under that security share this security-level pause state. To determine whether a particular pool currently allows swaps / ordinary LP, use that pool's `isTradable(poolId)` / `isLPAllowed(poolId)` return values as the final authority. Do not pass the in-pool WCET address to this path.

```JavaScript
import { Contract, ZeroHash } from "ethers";

const registry = new Contract(registryAddress, [
  "function getUnderlying(address) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getSecurity(bytes32) view returns (tuple(bytes32 securityId,uint8 tierId,bool listed,bytes32[] poolIds,uint32 listedPoolCount,uint8 pauseMode))",
  "function isPaused() view returns (bool)",
], provider);

function decodePauseMode(value, globalPaused = false) {
  const code = Number(value);
  const tradePaused = (code & 0b01) !== 0;
  const addRemoveLpPaused = (code & 0b10) !== 0;
  return {
    swap: globalPaused || tradePaused ? "PAUSED" : "UNPAUSED",
    addRemoveLP: globalPaused || addRemoveLpPaused ? "PAUSED" : "UNPAUSED",
  };
}

const underlying = await registry.getUnderlying(cetAddress);
if (underlying.securityId === ZeroHash) throw new Error("Unknown CET address");
const security = await registry.getSecurity(underlying.securityId);
const globalPaused = await registry.isPaused();
const pauseStatus = decodePauseMode(security.pauseMode, globalPaused);
console.log({
  cetAddress,
  securityId: underlying.securityId,
  pauseStatus,
  poolIds: security.poolIds,
});
```

#### Decode the Status Code

The code in `SecurityRecord.pauseMode` and `SecurityStatusChanged` is a two\-bit mask, not a `SecurityPauseMode` enum ordinal; `oldPauseMode` and `newPauseMode` are complete masks. The JS labels mean:

- `UNPAUSED` (`00`): neither the TRADE nor LP pause bit is set; other admission checks still apply.
- `TRADE_PAUSED` (`01`): the TRADE bit is set, blocking swaps for pools associated with the security; the LP pause bit is not set.
- `ADD_REMOVE_LP_PAUSED` (`10`): the LP bit is set, so `isLPAllowed(poolId)` rejects ordinary LP position operations because of this security pause; the TRADE pause bit is not set.
- `TRADE_AND_ADD_REMOVE_LP_PAUSED` (`11`): both bits are set, so the security pause blocks both swaps and ordinary LP position operations.

`pauseMode` represents security-level pause bits, not a pool's complete effective permission; pool lifecycle, global emergency pause, and other conditions can also affect the result. Use `isTradable` / `isLPAllowed` for the pool\-level checks\.

The global state is not one of the four `pauseMode` labels: `isPaused() == true` means `GLOBAL_PAUSED`, and the protocol\-wide emergency pause blocks ordinary swaps / LP operations; `false` means `GLOBAL_UNPAUSED`. It can coexist with any security `pauseMode`, so backends should store the global boolean separately from the two\-bit security mask. It is changed through `setEmergencyPauseEnable(enabled, reasonCode)`: `enabled=true` requires `EMERGENCY_PAUSER_ROLE`, `false` requires `EMERGENCY_RESUMER_ROLE`, and `reasonCode` must be nonzero.

Use bit tests to decode the security mask: `tradePaused = (pauseMode & 0b01) != 0` and `addRemoveLpPaused = (pauseMode & 0b10) != 0`; both security pause bits are clear only when `pauseMode == 0`. Read the global pause separately as the boolean `globalPaused = registry.isPaused()`; it is not a third bit in `pauseMode`. Combine them with logical OR for each operation: `swapPaused = globalPaused || tradePaused` and `addRemoveLpPaused = globalPaused || addRemoveLpPaused`; the corresponding operations are not blocked by these pause gates only when `!globalPaused && !tradePaused` or `!globalPaused && !addRemoveLpPaused`. In the examples, `decodePauseMode(pauseMode, globalPaused)` combines these into one `pauseStatus` object whose `swap` and `addRemoveLP` fields each indicate `PAUSED` or `UNPAUSED`. These formulas cover pause gates only; use `isTradable(poolId)` / `isLPAllowed(poolId)` for the final pool permission checks.

#### Pause / Resume Call

In `applySecurityStatus(securityId, mode, enable, reasonCode)`, `mode` selects the operation to update, and `enable=true` pauses (sets bits) while `enable=false` resumes (clears bits)\. The enum to mask mapping is `TRADE=0 → 0001`, `LP=1 → 0010`, and `ALL=2 → 0011`\. For example, if only LP is paused (`0010`), calling `TRADE, true` results in `0010 | 0001 = 0011`; then calling `TRADE, false` results in `0011 & ~0001 = 0010`, resuming only trading while LP stays paused\. Calling `ALL, false` clears both bits (`0010 & ~0011 = 0000`); `ALL, true` pauses both and results in `0011`\.

The caller must have `HALT_REPORTER_ROLE`, the target security must be listed, and `reasonCode` must be nonzero\. If the selected bits are already in the requested state and the call changes no bits, the contract reverts with `InvalidStatus`\. After a successful call, confirm the receipt's `SecurityStatusChanged` event and read back `getSecurity`\.

For LP indexing, monitor the **TSV LP Manager proxy**, not the original Uniswap PositionManager address\. On ordinary Mint, `Transfer` from the zero address gives the new `tokenId`; `ModifyPosition.salt` joins it to the position\. `liquidityDelta` distinguishes increases and decreases, and may be zero for fee collection\. On Burn / forced exit, `Transfer` to the zero address shows NFT destruction\. Also read `IssuerPositionUnwound` / `TsvPositionUnwound` in Section 6 to identify the forced\-exit path, and `CurrencyUnwound` for each recipient on the issuer path; a v4 `ModifyLiquidity` event alone is insufficient\. For user balances, payment approvals, and asset labels, focus on the **underlying stock token** and quote token; users normally do not hold the wrapper\. Confirm results from the receipt and current position / Registry reads\.

### 1\. Entry\-Point and Query ABIs

The following human\-readable ABI can be passed directly to an ethers `Interface`\. `PoolKey` is expanded into its complete tuple, and the ABI type of `PositionInfo` is `uint256`\.

```JavaScript
import { AbiCoder, Interface, keccak256 } from "ethers";

const lpPoolKeyType = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const lpAbi = [
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function modifyLiquiditiesWithoutUnlock(bytes actions,bytes[] params) payable",
  `function initializePool(${lpPoolKeyType} key,uint160 sqrtPriceX96) payable returns (int24 tick)`,
  "function unwindPosition(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "function unwindPositionByTsv(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function approve(address spender,uint256 tokenId)",
  "function setApprovalForAll(address operator,bool approved)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner,address operator) view returns (bool)",
  `function getPoolAndPositionInfo(uint256 tokenId) view returns (${lpPoolKeyType} poolKey,uint256 info)`,
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function registry() view returns (address)",
  "function FORCE_EXIT_ADMIN_ROLE() view returns (bytes32)",
  "function POOL_CREATOR_ROLE() view returns (bytes32)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed id)",
  "event CurrencyUnwound(uint256 indexed tokenId,address indexed currency,address indexed recipient,address caller,address lp,uint256 amount,bool asClaim)",
  "event IssuerPositionUnwound(uint256 indexed tokenId,address indexed lpOwner,address indexed issuer,address token0,address token1,uint256 lpReceivedAmount0,uint256 issuerReceivedAmount0,uint256 lpReceivedAmount1,uint256 issuerReceivedAmount1)",
  "event TsvPositionUnwound(uint256 indexed tokenId,address indexed lpOwner,address indexed issuer,address token0,address token1,uint256 lpReceivedAmount0,uint256 issuerReceivedAmount0,uint256 lpReceivedAmount1,uint256 issuerReceivedAmount1)",
];

const abiCoder = AbiCoder.defaultAbiCoder();
const lpInterface = new Interface(lpAbi);
```

|Entry point|Purpose and caller requirements|Return value|
|---|---|---|
|`modifyLiquidities(bytes,uint256)`|Ordinary LP operations by a user or an approved operator; payable|None|
|`initializePool(PoolKey,uint160)`|Pool creation by a caller with `POOL_CREATOR_ROLE`; payable|`int24 tick`|
|`unwindPosition(uint256,uint128,uint128,bytes)`|Forced exit initiated by a PermissionsAdapter contract owner; nonpayable|None|
|`unwindPositionByTsv(uint256,uint128,uint128,bytes)`|Forced exit initiated by a caller with `FORCE_EXIT_ADMIN_ROLE`; nonpayable|None|
|`approve(address,uint256)` / `setApprovalForAll(address,bool)`|NFT approval; does not authorize token payments|None|
|`multicall(bytes[])`|Executes multiple LP Manager calls from the same caller; any failure reverts the entire transaction|`bytes[]` containing the return data of each subcall|
|`modifyLiquiditiesWithoutUnlock(bytes,bytes[])`|Only for composed calls within an existing PoolManager unlock context; neither performs an unlock nor checks a deadline|None|

Use `modifyLiquidities` for ordinary transactions; do not call `unlockCallback` directly\. Proxy initialization, upgrades, subscriptions, and Permit2 forwarding are outside the scope of this guide\. Ordinary LP payments require direct approval to the LP Manager proxy; Permit2 / TokenApprove approval does not replace it\.

### 2\. Prerequisites and Approvals

Ordinary LP operations, including fee collection and ordinary position closure, perform the following checks:

|Check|Call or condition|
|---|---|
|Global and pool admission|`registry.isPaused() == false` and `registry.isLPAllowed(poolId) == true`|
|SBT|The executor, NFT owner, and explicitly specified recipient must each pass `registry.isSbtAllowed(0x0002, account)`; simply holding an arbitrary SBT is insufficient|
|NFT approval|When modifying an existing position, the executor must be `ownerOf(tokenId)`, `getApproved(tokenId)`, or an operator approved by the owner|
|Issuer admission for Mint / Increase|The PermissionsAdapter contract is verified by the Factory, allows the pool's Hook, and returns true for `permissionsAdapter.isAllowed(owner, 0x0002)`|
|Providing additional stock assets|The executor passes `permissionsAdapter.isAllowed(executor, 0x0002)`, and the PermissionsAdapter contract allows LP Manager as a wrapper|
|Payment approval|The payer directly approves the **LP Manager proxy address** for the underlying stock token / quote token actually used for payment|
|Balance and allowance|The payer has sufficient balance and `allowance(payer, lpManagerAddress)`|
|Asset delivery|The recipient passes the underlying stock token's actual transfer compliance checks|

ABIs for these checks:

```JavaScript
const lpRegistryAbi = [
  "function isPaused() view returns (bool)",
  "function isLPAllowed(bytes32 poolId) view returns (bool)",
  "function isSbtAllowed(bytes2 permission,address account) view returns (bool)",
  "function hasRole(bytes32 role,address account) view returns (bool)",
  "function getCurrencyUnderlying(address currency) view returns (address)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
];
const lpPermissionsAdapterAbi = [
  "function owner() view returns (address)",
  "function isAllowed(address account,bytes2 permission) view returns (bool)",
  "function allowedHooks(address hook) view returns (bool)",
  "function allowedWrappers(address wrapper) view returns (bool)",
];
const lpTokenAbi = [
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
];
const lpFactoryAbi = [
  "function verifiedPermissionsAdapterOf(address adapter) view returns (address underlyingToken)",
];
const lpLegalShareAdapterAbi = [
  "function currentMultiplier(address underlyingToken) view returns (uint256)",
];
```

Registry uses the argument order `isSbtAllowed(permission, account)`, while the PermissionsAdapter contract uses `isAllowed(account, permission)`\. The ABI type of permission is **`bytes2`**\. `0x0002` represents ordinary LP permission; `0x0004` is used only to query forced\-exit eligibility on the PermissionsAdapter contract\.

### 3\. Common Parameters

|Parameter|Type and requirements|
|---|---|
|`poolKey`|`(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)`; use a registered key with `currency0 < currency1`; use the PermissionsAdapter address for the stock side|
|`tokenId`|`uint256`, the position NFT ID; query its pool and liquidity through `getPoolAndPositionInfo` and `getPositionLiquidity`, and first confirm that the NFT exists|
|`liquidity`|`uint256`, measured in liquidity units rather than token amounts; calculate it from the pool price, tick range, and asset budget|
|`amount0Max/1Max`|`uint128`, maximum principal payments, measured in the smallest units of currency0/1|
|`amount0Min/1Min`|`uint128`, minimum principal amounts received on removal; excludes fees collected in addition to principal|
|`recipient`|`address`; receives the NFT during Mint and the actual assets during TAKE\_PAIR; using an explicit recipient address is recommended|
|`hookData`|`bytes`; either `0x` or the ABI encoding of a single `uint256 expectedMultiplier`; must be exactly 32 bytes when nonempty|
|`deadline`|`uint256`, Unix time in seconds; ordinary LP calls fail when `block.timestamp > deadline`|

For nonempty `hookData`, read the multiplier in two steps: obtain the `legalShareAdapter` address from `registry.getUnderlying(underlyingToken)`, then call `currentMultiplier(underlyingToken)` on that contract\. The value must be nonzero and must match at execution time\. Encode it as `abiCoder.encode(["uint256"], [expectedMultiplier])`\. `poolId` is the keccak256 hash of the standard ABI encoding of the complete PoolKey; calculate it with `keccak256(abiCoder.encode([lpPoolKeyType], [poolKey]))`\.

### 4\. Encoding and Submitting Ordinary LP Operations

Mint, Increase, Decrease, Collect, and Burn all use the common wrapper below\. Each byte in `actions` corresponds to one `params[i]`\. Each parameter set uses standard ABI encoding; only the action opcodes are concatenated directly as bytes\.

```JavaScript
function buildLpTransaction(lpManagerAddress, actions, params, deadline) {
  if ((actions.length - 2) / 2 !== params.length) throw new Error("actions/params mismatch");
  const unlockData = abiCoder.encode(["bytes", "bytes[]"], [actions, params]);
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("modifyLiquidities", [unlockData, deadline]),
    value: 0n,
  };
}
```

|Action|Opcode|Type order within a single `params[i]`|
|---|---|---|
|`MINT_POSITION`|`0x02`|`PoolKey,int24,int24,uint256,uint128,uint128,address,bytes`|
|`INCREASE_LIQUIDITY`|`0x00`|`uint256,uint256,uint128,uint128,bytes`|
|`DECREASE_LIQUIDITY`|`0x01`|`uint256,uint256,uint128,uint128,bytes`|
|`BURN_POSITION`|`0x03`|`uint256,uint128,uint128,bytes`|
|`SETTLE_PAIR`|`0x0d`|`address,address`|
|`TAKE_PAIR`|`0x11`|`address,address,address`|
|`CLOSE_CURRENCY`|`0x12`|`address`|

The functions below reuse this section's `abiCoder`, `lpInterface`, `lpPoolKeyType`, and `buildLpTransaction`\. Use `bigint` for all large integers\. Prices and amounts must come from actual queries and quotes; do not calculate them directly using JavaScript floating\-point numbers\.

#### Mint: Create a Position

`tickLower < tickUpper`; both ticks must align with `poolKey.tickSpacing` and fall within the valid tick range\. `recipient` receives the nontransferable position NFT\.

```JavaScript
function buildMintTransaction(input) {
  const { lpManagerAddress, poolKey, tickLower, tickUpper, liquidity,
    amount0Max, amount1Max, recipient, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(
      [lpPoolKeyType, "int24", "int24", "uint256", "uint128", "uint128", "address", "bytes"],
      [poolKey, tickLower, tickUpper, liquidity, amount0Max, amount1Max, recipient, hookData],
    ),
    abiCoder.encode(["address", "address"], [poolKey.currency0, poolKey.currency1]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x020d", params, deadline);
}
```

The action sequence is `MINT_POSITION → SETTLE_PAIR`\. In a successful receipt, filter for `Transfer` events emitted by the LP Manager address\. The event with a zero `from` address identifies the new `tokenId`; do not infer the final ID by reading `nextTokenId` before submission\.

#### Increase: Add Liquidity

The action sequence is `INCREASE_LIQUIDITY → CLOSE_CURRENCY → CLOSE_CURRENCY`\. It handles both additional payments and any surplus arising from accrued fees\. Surplus funds are returned to the executor\.

```JavaScript
function buildIncreaseTransaction(input) {
  const { lpManagerAddress, poolKey, tokenId, liquidity, amount0Max,
    amount1Max, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(["uint256", "uint256", "uint128", "uint128", "bytes"],
      [tokenId, liquidity, amount0Max, amount1Max, hookData]),
    abiCoder.encode(["address"], [poolKey.currency0]),
    abiCoder.encode(["address"], [poolKey.currency1]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x001212", params, deadline);
}
```

#### Decrease: Remove Liquidity

The action sequence is `DECREASE_LIQUIDITY → TAKE_PAIR`\. `liquidity` must not exceed the position's current liquidity\. Principal and fees are sent to `recipient`, and the NFT remains intact\.

```JavaScript
function buildDecreaseTransaction(input) {
  const { lpManagerAddress, poolKey, tokenId, liquidity, amount0Min,
    amount1Min, recipient, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(["uint256", "uint256", "uint128", "uint128", "bytes"],
      [tokenId, liquidity, amount0Min, amount1Min, hookData]),
    abiCoder.encode(["address", "address", "address"],
      [poolKey.currency0, poolKey.currency1, recipient]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x0111", params, deadline);
}
```

#### Collect: Collect Fees

There is no separate collect entry point\. Reuse Decrease with both the liquidity change and minimum principal amounts set to zero\. Ordinary LP requirements for SBT eligibility, NFT approval, and pool admission still apply\.

```JavaScript
function buildCollectTransaction(input) {
  return buildDecreaseTransaction({
    ...input, liquidity: 0n, amount0Min: 0n, amount1Min: 0n,
  });
}
```

#### Burn: Close a Position Normally

The action sequence is `BURN_POSITION → TAKE_PAIR`\. It removes all liquidity, settles fees, and burns the NFT\. All ordinary LP prerequisites still apply\.

```JavaScript
function buildBurnTransaction(input) {
  const { lpManagerAddress, poolKey, tokenId, amount0Min, amount1Min,
    recipient, deadline, hookData = "0x" } = input;
  const params = [
    abiCoder.encode(["uint256", "uint128", "uint128", "bytes"],
      [tokenId, amount0Min, amount1Min, hookData]),
    abiCoder.encode(["address", "address", "address"],
      [poolKey.currency0, poolKey.currency1, recipient]),
  ];
  return buildLpTransaction(lpManagerAddress, "0x0311", params, deadline);
}
```

### 5\. Initialize Pool: Create a Pool

The entry point is `initializePool(PoolKey key,uint160 sqrtPriceX96) payable returns (int24 tick)`\.

The caller must hold `POOL_CREATOR_ROLE`, and Registry must not be globally paused\. The PermissionsAdapter contract, quote token, and security configuration must already be admitted\. At least one side must be a Factory\-verified PermissionsAdapter contract with a nonzero owner\. Failure of either pool registration or initialization reverts the entire transaction\.

`sqrtPriceX96 = floor(sqrt(currency1Raw / currency0Raw) × 2^96)`, calculated using the smallest units of both assets and within the v4 price range\. Account for token decimals in the calculation\.

```JavaScript
function buildInitializePoolTransaction(lpManagerAddress, poolKey, sqrtPriceX96) {
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("initializePool", [poolKey, sqrtPriceX96]),
    value: 0n,
  };
}
```

### 6\. Unwind: Administrator\-Initiated Forced Closure

Both dedicated entry points call the LP Manager proxy directly\. They return no value, do not accept native currency, and do not require an action sequence\.

|Prerequisite / behavior|`unwindPosition`|`unwindPositionByTsv`|
|---|---|---|
|Caller|The `owner()` of either verified PermissionsAdapter contract in the pool|A holder of Registry's `FORCE_EXIT_ADMIN_ROLE`|
|Position eligibility|The NFT exists, and at least one verified PermissionsAdapter contract in the pool returns true for `isAllowed(lp, 0x0004)`|Same as `unwindPosition`|
|SBT / NFT approval|Neither the LP nor the administrator needs to pass ordinary LP SBT checks, and prior NFT approval from the LP is not required|Same as `unwindPosition`|
|Pause and pool admission|No global pause; in this version, forced exits bypass ordinary `isLPAllowed` checks, while Hook execution still checks pool registration and Hook identity|Same as `unwindPosition`|
|Recipient|For each asset, delivery to the LP is attempted first\. If that fails, delivery to the corresponding PermissionsAdapter contract owner is attempted only for permissioned assets\. If delivery still fails, the entire transaction reverts|Both assets are sent directly to the LP; failure to deliver either asset reverts the entire transaction|
|Result|Burns the NFT; does not deliver an unredeemable claim to the user as a fallback|Burns the NFT|

Both entry points take `(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)`\. There is no `recipient` or `deadline` parameter\. `hookData` follows the same rules as ordinary LP operations\. **Revocation of an SBT does not automatically make a position eligible for unwind**; query the PermissionsAdapter contract's `UNWIND_ALLOWED = 0x0004` permission explicitly\.

```JavaScript
function buildIssuerUnwindTransaction(input) {
  const { lpManagerAddress, tokenId, amount0Min, amount1Min, hookData = "0x" } = input;
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("unwindPosition",
      [tokenId, amount0Min, amount1Min, hookData]),
    value: 0n,
  };
}

function buildTsvUnwindTransaction(input) {
  const { lpManagerAddress, tokenId, amount0Min, amount1Min, hookData = "0x" } = input;
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("unwindPositionByTsv",
      [tokenId, amount0Min, amount1Min, hookData]),
    value: 0n,
  };
}
```

Issuer\-initiated unwinds emit `IssuerPositionUnwound`, with `CurrencyUnwound` identifying the final recipient of each nonzero asset\. TSV\-administrator unwinds emit `TsvPositionUnwound` and deliver assets directly to the LP without `CurrencyUnwound`\. The aggregate events' `token0/token1` are pool currency addresses; confirm actual stock delivery from underlying stock token `Transfer` logs and balances\. In this version, `withdrawClaim(address,uint256,address)` is disabled, and ordinary LP entry points cannot submit `MINT_6909` or `UNWIND_WITH_FALLBACK`\.

### 7\. Submitting LP Transactions

The following example reuses the ethers `Signer` supplied by the application's wallet\. It must represent the executor or administrator required for the operation:

```JavaScript
async function submitLpTransaction(signer, transaction) {
  const from = await signer.getAddress();
  await signer.provider.call({ ...transaction, from });
  const gasLimit = await signer.estimateGas(transaction);
  const response = await signer.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}
// Example: submitLpTransaction(userSigner, buildMintTransaction(mintInput))
// Forced exit: replace userSigner with an administrator Signer holding the required permissions.
```

A successful simulation does not guarantee that state will remain unchanged before execution on\-chain\. Common failures include: `RegistryPaused()` for a global pause; `PoolNotAllowed()` for failed ordinary LP admission; `Unauthorized()`, which requires checking SBT eligibility, issuer permissions, and NFT approval; `LpUnWindable()` for failure to meet forced\-exit eligibility; and `UnAcceptableScenario()` when an issuer\-initiated unwind cannot deliver the assets\.

## II\. Swap Router: Single\-Pool Exact\-Input Swaps

```Plaintext
User → external trading entry point / adapter contract → TSVSwapRouterV1.swapExactInputFromContract
User / AA wallet → TSVSwapRouterV1.swapExactInput
```

`swapExactInput` can be called directly by a user or AA wallet; the direct caller of either `FromContract` entry point must be an authorized adapter contract\. On the prefunded entry point described here, `participant` is the identity checked for trading permission; the adapter calling Router is both the payer and the recipient of pool output\. The adapter then delivers output to the external `to` address under its own rules\. Calldata for an external trading entry point depends on the integrated adapter's ABI and cannot be derived from the TSV Router ABI\.

Here, an adapter is an external trading integration contract\. Its role differs from that of the pool's `PermissionsAdapter` contract\.

### 1\. Swap Entry\-Point and Query ABIs

This section can be used independently and does not depend on LP actions or encoders\.

```JavaScript
import { Interface } from "ethers";

const swapPoolKeyType = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const swapRequestType = `tuple(${swapPoolKeyType} key,bool zeroForOne,uint128 amountSpecified,uint128 limitAmount,uint64 deadline,uint256 expectedMultiplier)`;
const swapRouterAbi = [
  `function swapExactInput(${swapRequestType} request) returns (uint256 actualIn,uint256 actualOut)`,
  `function swapExactInputFromContractDirect(${swapRequestType} request,address payer,address participant,address recipient) returns (uint256 actualIn,uint256 actualOut)`,
  `function swapExactInputFromContract(${swapRequestType} request,address participant) returns (uint256 actualIn,uint256 actualOut)`,
  "function settlementCurrency(address currency) view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool allowed)",
  "function setAdapterAllowed(address adapter,bool allowed)",
  "function registry() view returns (address)",
];
const swapInterface = new Interface(swapRouterAbi);
```

All three swap entry points are nonpayable and return `(uint256 actualIn,uint256 actualOut)`\. They construct the Swap, Settle, and Take operations internally; the backend does not supply LP `actions` or `unlockData`\. `swapExactInput(request)` pays from, delivers to, and checks the identity of the caller without an adapter allowlist\. For `swapExactInputFromContractDirect`, stock input must already be deposited in PermissionsAdapter with `payer = address(0)`; quote\-token input uses `payer = msg.sender`, with Router transferring it directly from the calling adapter to PoolManager during settlement\. `recipient` must equal `participant`\. `swapExactInputFromContract` pays from and delivers to the calling contract while still checking `participant`'s permissions\. The two `FromContract` entry points require an allowlisted calling contract; only holders of Registry's `DEFAULT_ADMIN_ROLE` can configure it with `setAdapterAllowed`\.

### 2\. Swap Prerequisites and Approvals

|Check|Call or condition|
|---|---|
|Caller|`swapExactInput` is called by the user or AA wallet; the two `FromContract` entry points require `router.isAdapterAllowed(adapterAddress) == true` and a call from that contract|
|Global and pool admission|`registry.isPaused() == false`; `registry.isTradable(poolId) == true`; the key identifies a registered pool bound to the correct Hook|
|SBT|`registry.isSbtAllowed(0x0001, participant) == true`|
|Issuer admission|The PermissionsAdapter contract is verified and allows the Hook; `swappingEnabled() == true`; `isAllowed(participant, 0x0001) == true`|
|Wrapping stock input|If the input is the underlying stock token, the PermissionsAdapter contract must allow the **Swap Router proxy address** as a wrapper|
|Quote state|The deadline has not expired; the multiplier snapshot matches; the trading\-volume quota permits the trade|

The three entry points differ in who pays and where Router delivers output:

|Entry point|Payer and input approval|Router output recipient|
|---|---|---|
|`swapExactInput(request)`|The caller holds the input token and directly approves the **Swap Router proxy address**; the caller is also checked for SBT and issuer permission|The same caller|
|`swapExactInputFromContract(request, participant)`|The approved calling contract already holds the input token and approves the **Swap Router proxy address**\. Router pulls input from that contract; `participant` is checked only for permission|The same calling contract; an external adapter may forward output to `to`|
|`swapExactInputFromContractDirect(request, payer, participant, recipient)`|SET input: the AA wallet deposits SET in PermissionsAdapter first, `payer = address(0)`, and Router does not pull SET again\. Quote\-token input: `payer = msg.sender`; the calling adapter holds the tokens and approves the **Swap Router proxy address**, which transfers them directly to PoolManager during settlement|Explicit `recipient == participant`; for SET output, set `participant` to the receiving AA wallet|

None of the three entry points calls TokenApprove inside Router\. If the external DexRouter uses TokenApprove to collect a user's input, that upstream step occurs before Router execution and does not replace the caller's or adapter's approval to Router\. Router checks the actual permission subject's SBT; the direct\-settlement entry point also requires `recipient == participant`\. Delivery of SET can still fail the underlying token's transfer compliance checks\.

Query and token\-approval ABIs:

```JavaScript
const swapRegistryAbi = [
  "function isPaused() view returns (bool)",
  "function isTradable(bytes32 poolId) view returns (bool)",
  "function isSbtAllowed(bytes2 permission,address account) view returns (bool)",
  "function getCurrencyUnderlying(address currency) view returns (address)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
];
const swapPermissionsAdapterAbi = [
  "function isAllowed(address account,bytes2 permission) view returns (bool)",
  "function allowedHooks(address hook) view returns (bool)",
  "function allowedWrappers(address wrapper) view returns (bool)",
  "function swappingEnabled() view returns (bool)",
];
const swapTokenAbi = [
  "function approve(address spender,uint256 amount) returns (bool)",
  "function allowance(address owner,address spender) view returns (uint256)",
  "function balanceOf(address owner) view returns (uint256)",
];
const swapLegalShareAdapterAbi = [
  "function currentMultiplier(address underlyingToken) view returns (uint256)",
];
```

Call `router.settlementCurrency(currency)` for a pool currency to obtain the actual settlement token address\. For the stock side, it returns the underlying stock token address; for the quote side, it returns the quote token itself\. The prefunded entry point requires the adapter to receive the actual input token first and approve Router\. If the external DexRouter requires the user to approve TokenApprove, that upstream approval does not replace the adapter's approval to Router\.

#### Swap Fund Flow \(SET\)

Below, **SET** means the underlying stock token\. Put the **PermissionsAdapter token**, not SET, on the stock side of PoolKey\. Derive `zeroForOne` from the actual `currency0/currency1` order rather than fixing it by buy/sell direction\. The table describes `swapExactInputFromContract`: the contract calling Router both pays and receives pool output, while `participant` is checked for identity and trading permission only\.

|Direction|Input and pool settlement|Output delivery|
|---|---|---|
|SET → quote token|The external flow first gives SET to the adapter\. Using the adapter's approval, Router transfers `amountSpecified` SET directly from the adapter to PermissionsAdapter\. Backed by the received SET, PermissionsAdapter mints an equal amount of PermissionsAdapter tokens to PoolManager to settle the pool's stock\-side debt|PoolManager delivers the quote token to the adapter, which forwards this trade's output to the external `to` address|
|Quote token → SET|The external flow first gives quote tokens to the adapter\. During settlement, Router transfers the actual input amount **directly from the adapter to PoolManager** to settle the quote\-token debt; Router does not hold these quote tokens|PoolManager transfers PermissionsAdapter tokens to the adapter\. During that transfer, PermissionsAdapter burns the pool\-side tokens and delivers an equal amount of SET from its backing balance to the adapter, which forwards this trade's SET output to the external `to` address|

Router checks the authorized caller, pool, and `participant`'s trading permission before moving funds\. It then executes `SWAP_EXACT_IN_SINGLE → SETTLE_ALL → TAKE_ALL` and requires actual input to equal `amountSpecified`\. **If the direct caller is a DexRouter adapter distinct from the AA wallet, this prefunded flow passes SET through that adapter and cannot satisfy the requirement that SET move only between the AA wallet and PermissionsAdapter**\. An AA wallet trading for itself can use `swapExactInput(request)` to pay and receive directly, without adapter allowlisting\.

The direct\-settlement entry point can satisfy that SET rule: to sell SET, the AA wallet first transfers SET into PermissionsAdapter in the same atomic transaction, passes `payer = address(0)`, and Router does not transfer SET again\. To buy SET, `payer` is the calling adapter, which sends quote tokens directly to PoolManager; set both `participant` and `recipient` to the receiving AA wallet so PermissionsAdapter delivers SET straight to it\. Router enforces equality but does not verify that the address belongs to an AA wallet, so the integration must supply the correct permission subject\. If the SET deposit and swap are separate transactions, a failed swap does not revert the earlier deposit\.

### 3\. SwapRequest Parameters

|Field|ABI type|Requirements|
|---|---|---|
|`key`|`tuple(address,address,uint24,int24,address)`|Ordered as currency0, currency1, fee, tickSpacing, hooks; use the PermissionsAdapter address for the stock side|
|`zeroForOne`|`bool`|true: currency0 → currency1; false: the reverse direction|
|`amountSpecified`|`uint128`|Exact input amount in the token's smallest units, with `0 < amountSpecified <= 2^127 - 1`|
|`limitAmount`|`uint128`|Minimum output amount in the token's smallest units; must be greater than 0|
|`deadline`|`uint64`|Unix time in seconds, not milliseconds|
|`expectedMultiplier`|`uint256`|The nonzero multiplier read when quoting; must match at execution time|
|`participant`|`address`, only on the two `FromContract` entry points|The user or AA\-wallet identity; the prefunded entry point checks it without pulling payment from it, and the direct\-settlement entry point requires it to equal `recipient`|
|`payer`|`address`, only the second argument on the direct\-settlement entry point|The zero address for stock input; the calling adapter address for quote\-token input|
|`recipient`|`address`, only the fourth argument on the direct\-settlement entry point|Must equal `participant`; the other two entry points deliver output to their direct caller|

Read the multiplier in this order: obtain `legalShareAdapter` from `registry.getUnderlying(underlyingToken)`, then call `currentMultiplier(underlyingToken)` on that contract\. If the price or multiplier changes, obtain a new quote rather than merely replacing the snapshot value\.

### 4\. Encoding the Adapter → Router Call

`request` must contain the first six fields in the table above, with their original field names\. Use `bigint` for amounts, deadline, and expectedMultiplier\.

```JavaScript
function buildSwapRouterCall(input) {
  const { routerAddress, poolKey, zeroForOne, amountIn, amountOutMin,
    deadline, expectedMultiplier, participant } = input;
  const request = {
    key: poolKey,
    zeroForOne,
    amountSpecified: amountIn,
    limitAmount: amountOutMin,
    deadline,
    expectedMultiplier,
  };
  return {
    to: routerAddress,
    data: swapInterface.encodeFunctionData("swapExactInputFromContract",
      [request, participant]),
    value: 0n,
  };
}

function buildCallerBoundSwapCall(input) {
  const { routerAddress, poolKey, zeroForOne, amountIn, amountOutMin,
    deadline, expectedMultiplier } = input;
  const request = {
    key: poolKey, zeroForOne, amountSpecified: amountIn,
    limitAmount: amountOutMin, deadline, expectedMultiplier,
  };
  return {
    to: routerAddress,
    data: swapInterface.encodeFunctionData("swapExactInput", [request]),
    value: 0n,
  };
}
```

`buildSwapRouterCall` is for internal execution by an authorized adapter, not for a user wallet's `sendTransaction`\. The adapter must hold input and approve Router first\. A user or AA wallet may submit `buildCallerBoundSwapCall` directly after holding input and approving Router\. A complete external DexRouter transaction also needs that external entry point's ABI\.

### 5\. Simulation and Result Interpretation

The example below simulates the internal call\. `adapterAddress` must be an allowed adapter with enough input balance and Router allowance at the simulated block\. If the external flow funds or approves the adapter within the same transaction, simulate that complete transaction instead\.

```JavaScript
async function simulateSwapRouterCall(provider, adapterAddress, input) {
  const call = buildSwapRouterCall(input);
  const result = await provider.call({ ...call, from: adapterAddress });
  const [actualIn, actualOut] = swapInterface.decodeFunctionResult(
    "swapExactInputFromContract", result,
  );
  return { actualIn, actualOut };
}
```

On success, `actualIn == amountSpecified` and `actualOut >= limitAmount`\. If the full input amount is not consumed, the entire transaction reverts\. A transaction receipt does not itself contain Solidity return values\. For accounting, parse the actual trade / asset\-transfer logs; do not treat simulated output as the executed trade amount\.

Common failures include: `AdapterNotAllowed()` when the direct caller is unauthorized; `Expired()` when the deadline has passed; `PoolNotTradable()` when the pool is not tradable; `MultiplierChanged()` when the quoted multiplier has changed; and `SlippageExceeded()` when this router detects an incomplete input fill or no valid output\. v4 may also return its own minimum\-output error\.

## III\. Volume Ledger: Backend Daily Volume Quotas

```Plaintext
Backend account holding VOLUME_ORACLE_ROLE → TSVVolumeLedgerV1.setQuota / setUsedWad
```

This section uses the `TSVVolumeLedgerV1` ABI matching the deployment manifest below\. `setQuota` sets one security's persistent daily quota; `setUsedWad` corrects usage for specified EST days \(Section 6\), and `multicall` batches calls across securities \(Section 7\)\. Call the Volume Ledger proxy directly\. Both write functions are nonpayable, return no value, and require `value = 0`\.

### 1\. Prerequisites and ABI

The calling account must hold **`VOLUME_ORACLE_ROLE`**\*\* in the Registry referenced by the Ledger\*\*, meaning `registry.hasRole(keccak256("VOLUME_ORACLE_ROLE"), caller) == true`\. Use the target security's nonzero Registry ID for `securityId`\. The quota is keyed by `securityId`, while usage is keyed by `securityId + ESTDay`\. Multiple pools for the same security consume the same daily quota, with no separate allocation per pool or user\.

The examples in this section can be used independently:

```JavaScript
import { Contract, Interface, ZeroAddress, ZeroHash, formatUnits } from "ethers";

const volumeLedgerAbi = [
  "function multicall(bytes[] data) returns (bytes[] results)",
  "function registry() view returns (address)",
  "function currentESTDay() view returns (uint256)",
  "function Quota(bytes32 securityId) view returns (uint256)",
  "function usedWad(bytes32 securityId,uint256 ESTDay) view returns (uint256)",
  "function setQuota(bytes32 securityId,uint256 amount,bytes32 reasonCode)",
  "function setUsedWad(bytes32 securityId,tuple(uint256 ESTDay,uint256 amount)[] values,bytes32 reasonCode)",
  "event QuotaSet(bytes32 indexed securityId,uint256 amount,bytes32 reasonCode)",
  "event UsedWadSet(bytes32 indexed securityId,uint256 indexed ESTDay,uint256 amount,bytes32 reasonCode)",
];
const volumeLedgerInterface = new Interface(volumeLedgerAbi);
const volumeRegistryAbi = [
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
  "function getSecurityPauseMode(bytes32 securityId) view returns (uint8 mode)",
  "function applySecurityStatus(bytes32 securityId,uint8 mode,bool enable,bytes32 reasonCode)",
];
```

|Parameter|ABI type|Requirements|
|---|---|---|
|`securityId`|`bytes32`|The nonzero target security ID; not a poolId or token address|
|`amount`|`uint256`|The persistent daily quota in **legal\-share WAD \(1 share = ****`10^18`****\)**; for example, 1,000 shares is `1000n * 10n ** 18n`, not a quote\-token amount or underlying\-token raw amount|
|`reasonCode`|`bytes32`|A nonzero backend\-defined reason code; emitted unchanged, with no validation of its business meaning|

### 2\. Resolving securityId from a Token and Reading Daily Quotas

The exact usage getter is **`usedWad`**, not `usdWad`\. It returns consumed legal\-share WAD, not a USD amount\. All queries below are `view` calls requiring only a Provider; no Signer or `VOLUME_ORACLE_ROLE` is needed\.

First obtain the corresponding Registry address through `ledger.registry()`, then query according to the stock token address available:

|Known address|Call sequence to obtain `securityId`|
|---|---|
|The user's underlying stock token, `underlyingToken`|`registry.getUnderlying(underlyingToken).securityId`|
|The pool's stock\-side `PermissionsAdapter` address|First call `underlyingToken = registry.getCurrencyUnderlying(permissionsAdapterAddress)`, then `registry.getUnderlying(underlyingToken).securityId`|

**Do not generate ****`securityId`**** by hashing a token symbol or address, and do not supply a quote\-token address\.** An unknown PermissionsAdapter returns a zero underlying address; an unknown underlying returns a default record with `securityId == 0`\. The backend should reject either case\. `registered` indicates whether the underlying may be used to register new pools; a false value alone is not a reason to discard its stored security ID or historical volume\.

|Query|Result|
|---|---|
|`ledger.currentESTDay()`|The EST day at the queried block|
|`ledger.Quota(securityId)`|Persistent daily quota for the security; note the capitalized method name|
|`ledger.usedWad(securityId, day)`|Accumulated daily volume; both buys and sells consume quota without offsetting each other|

The example below returns the security ID, daily quota, usage, and remaining quota together\. All calls use the same `blockTag` to keep reads consistent across day boundaries or intervening trades\. Explicitly set `tokenKind` to either `"underlying"` or `"permissionsAdapter"`\.

```JavaScript
async function readDailyVolume(provider, volumeLedgerAddress, stockTokenAddress, tokenKind) {
  if (!["underlying", "permissionsAdapter"].includes(tokenKind)) {
    throw new Error("Expected underlying or permissionsAdapter tokenKind");
  }
  const blockTag = await provider.getBlockNumber();
  const atBlock = { blockTag };
  const ledger = new Contract(volumeLedgerAddress, volumeLedgerAbi, provider);
  const registryAddress = await ledger.registry(atBlock);
  const registry = new Contract(registryAddress, volumeRegistryAbi, provider);
  const underlyingToken = tokenKind === "permissionsAdapter"
    ? await registry.getCurrencyUnderlying(stockTokenAddress, atBlock)
    : stockTokenAddress;
  if (underlyingToken === ZeroAddress) throw new Error("Unknown underlying token");
  const { securityId } = await registry.getUnderlying(underlyingToken, atBlock);
  if (securityId === ZeroHash) throw new Error("Unknown securityId");
  const ESTDay = await ledger.currentESTDay(atBlock);
  const [quotaWad, usedWad] = await Promise.all([
    ledger.Quota(securityId, atBlock),
    ledger.usedWad(securityId, ESTDay, atBlock),
  ]);
  const remainingWad = quotaWad > usedWad ? quotaWad - usedWad : 0n;
  return {
    blockTag, underlyingToken, securityId, ESTDay, quotaWad, usedWad, remainingWad,
    quotaShares: formatUnits(quotaWad, 18),
    usedShares: formatUnits(usedWad, 18),
    remainingShares: formatUnits(remainingWad, 18),
  };
}
// Underlying stock token: readDailyVolume(provider, volumeLedgerAddress, underlyingToken, "underlying")
// Pool stock side: readDailyVolume(provider, volumeLedgerAddress, permissionsAdapterAddress, "permissionsAdapter")
```

The returned `quotaWad`, `usedWad`, and `remainingWad` are `bigint` values\. The `*Shares` display fields are decimal strings; do not convert them to floating\-point numbers for quota calculations\. Pass the resolved `securityId` directly to a subsequent `setQuota` call\. To query a specific date, use an `ESTDay` calculated using Section 3 for `usedWad`; `Quota` is still queried only by `securityId`\.

### 3\. EST Day: Converting a UTC Unix Timestamp

**The input must be a Unix timestamp \(UTC\+0 basis, in seconds\)\. Subtract 5 hours directly, divide by the number of seconds in a day, and round down\. Do not convert the timestamp to local time or EST first and then subtract another 5 hours\.**

```Plaintext
ESTDay = floor((unixTimestampSeconds - 5 × 3600) / 86400)
       = floor((unixTimestampSeconds - 18000) / 86400)

UTC timestamp interval for a given ESTDay:
[ESTDay × 86400 + 18000, (ESTDay + 1) × 86400 + 18000)
```

This matches `(block.timestamp - 5 hours) / 1 days` in the contract's `currentESTDay()`\. **EST is fixed at UTC−5 throughout the year, with no daylight saving time\. Do not use ****`America/New_York`**** timezone rules, which switch to EDT \(UTC−4\)\.** The day changes at **05:00:00 UTC**, which is 00:00:00 in fixed EST\. UTC times from 00:00 through 04:59:59 still belong to the previous EST day\.

|UTC time|Unix timestamp \(seconds\)|Fixed EST time \(UTC−5\)|`ESTDay`|
|---|---|---|---|
|`2026-10-12T04:59:59Z`|`1791781199`|`2026-10-11 23:59:59`|`20737`|
|`2026-10-12T05:00:00Z`|`1791781200`|`2026-10-12 00:00:00`|`20738`|
|`2026-10-13T04:59:59Z`|`1791867599`|`2026-10-12 23:59:59`|`20738`|
|`2026-10-13T05:00:00Z`|`1791867600`|`2026-10-13 00:00:00`|`20739`|

The backend can reuse the conversion below\. JavaScript's `Date.now()` returns milliseconds, so divide by 1,000 first\. `block.timestamp` is already in seconds; do not divide it by 1,000 again\.

```JavaScript
function toESTDay(unixTimestampSeconds) {
  if (typeof unixTimestampSeconds !== "bigint" || unixTimestampSeconds < 18000n) {
    throw new Error("Expected Unix seconds as bigint, >= 18000");
  }
  return (unixTimestampSeconds - 18000n) / 86400n;
}

const nowUnixSeconds = BigInt(Math.floor(Date.now() / 1000));
const currentESTDay = toESTDay(nowUnixSeconds);
const targetESTDay = toESTDay(1791781200n); // 20738n: 2026-10-12 EST
```

When querying current\-day usage, use the latest on\-chain block's `timestamp` for conversion and cross\-check it against the Ledger's `currentESTDay()`; treat server time as an auxiliary reference\. `setQuota` takes no `ESTDay`; the new quota applies immediately to subsequent trades for that security\. At 05:00 UTC, usage switches to the new day's independent counter\. The Ledger does not retain historical quota versions\.

### 4\. Encoding and Submission

Use `bigint` for `amount`; `setQuota` takes no day argument\.

```JavaScript
function buildSetQuotaTransaction(volumeLedgerAddress, securityId, amount, reasonCode) {
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("setQuota", [securityId, amount, reasonCode]),
    value: 0n,
  };
}

async function submitSetQuotaTransaction(oracleSigner, input) {
  const { volumeLedgerAddress, securityId, amount, reasonCode } = input;
  const transaction = buildSetQuotaTransaction(volumeLedgerAddress, securityId, amount, reasonCode);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}

// Example: the application supplies securityId, reasonCode, the proxy address, and oracleSigner.
const amount = 1000n * 10n ** 18n; // This security's quota on subsequent days
```

### 5\. Overwrite Semantics and Result Verification

**`amount`**\*\* is the persistent daily quota, not an increment or the remaining quota\.\*\* A call overwrites `Quota[securityId]` without resetting `usedWad[securityId][ESTDay]` for any day\. For example, if 300 shares have been used today out of a 1,000\-share quota, changing the total to 1,200 leaves 900 shares available today\. The contract allows a quota to be reduced below today's usage, but subsequent positive\-volume trades fail until quota or usage is adjusted, or a new day begins with its separate usage counter\.

An unconfigured security has a quota of 0\. Setting `amount = 0` prevents all subsequent positive\-volume trades for that security; it does not mean unlimited volume\. Usage is counted independently for each day, but each day uses the current `Quota[securityId]`\. Trade validation uses the EST day derived from `block.timestamp` at execution\.

Each `setQuota` call writes one quota for one security\. On repeated successful writes, the latest one takes effect\. The backend should validate the security ID and amount before submission\.

In the successful receipt, filter `QuotaSet` events emitted by the **Volume Ledger proxy address** and verify `securityId`, `amount`, and `reasonCode`; this event has no `ESTDay`\. Read `Quota(securityId)` and `usedWad(securityId, ESTDay)` to calculate remaining quota for that day as `max(Quota - usedWad, 0)`; subsequent trades or quota updates may change the values read\.

Common `setQuota` failures: `InvalidConfig()` means `reasonCode` is zero; `Unauthorized()` means the caller lacks `VOLUME_ORACLE_ROLE`; `InvalidInput()` means `securityId` is zero\. `QuotaExceeded(bytes32,uint256)` occurs during volume accounting for a subsequent swap\. Its second argument is the same EST day integer defined above, and exceeding the quota reverts the entire swap\.

### 6\. Set Used WAD: Backend Corrections to Daily Usage

The entry point is `setUsedWad(bytes32 securityId,DailyQuota[] values,bytes32 reasonCode)`\. It uses the `DailyQuota` tuple and, like `setQuota`, requires Registry's `VOLUME_ORACLE_ROLE` and a nonzero `reasonCode`\. It is nonpayable and returns no value\. Before calling it, confirm that the target chain's Ledger implementation includes this interface\.

**Here, ****`values[i].amount`**** is the corrected accumulated total in legal\-share WAD\. It directly overwrites ****`usedWad[securityId][ESTDay]`**** without changing ****`Quota`****\.** Usage can be increased, decreased, or set to 0\. Values above quota are also accepted; subsequent positive\-volume trades fail until the quota or usage is adjusted to accommodate new volume\. Subsequent trades accumulate on top of the corrected value\.

For example, with a 1,000\-share quota and 300 shares used, writing 200 shares through `setUsedWad` leaves 800 shares available\. Writing 1,200 shares through `setQuota` changes only the quota, preserving existing usage\. Keep these two operations distinct\.

Each call targets one `securityId` and can correct multiple days\. An empty array performs no writes; duplicate days use the last value, and each item emits `UsedWadSet`\. A zero `reasonCode` reverts with `InvalidConfig()`; a zero `securityId` with `InvalidInput()`; and a caller without the role with `Unauthorized()`\. Past, current, and future days are written exactly as supplied; the contract imposes no date\-range restriction\.

```JavaScript
function buildSetUsedWadTransaction(volumeLedgerAddress, securityId, values, reasonCode) {
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("setUsedWad", [securityId, values, reasonCode]),
    value: 0n,
  };
}

async function submitSetUsedWadTransaction(oracleSigner, input) {
  const { volumeLedgerAddress, securityId, values, reasonCode } = input;
  const transaction = buildSetUsedWadTransaction(volumeLedgerAddress, securityId, values, reasonCode);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}
// Correct target-day usage to 200 shares: values = [{ ESTDay: targetESTDay, amount: 200n * 10n ** 18n }]
```

Filter `UsedWadSet` events from the Ledger proxy in the successful receipt, verify the security, day, new usage, and reason code, then read back using Section 2\. **This is an absolute overwrite with no previous\-value or version check\. A correction based on an earlier query may overwrite volume recorded between that query and execution of the correction transaction\.** The backend must coordinate trades and corrections and record the reason; a successful simulation does not eliminate this concurrency issue\.

### 7\. Multicall: Batch Updates Across Securities

The Ledger inherits OpenZeppelin `Multicall`, exposing `multicall(bytes[] data) returns (bytes[] results)`\. Call the Ledger proxy directly with `value = 0`\. Subcalls execute in array order, preserve the original `msg.sender`, and each enforce their own permissions\. **If any subcall fails, all state changes and events from the transaction are reverted\.**

Each individual `setQuota` / `setUsedWad` call still targets one security\. Use `multicall` to combine writes for different `securityId` values in one transaction, or to combine quota updates with usage corrections\. Each `data` item must be complete function calldata, including the selector, rather than just ABI\-encoded parameters\. All subcalls target the current Ledger; external target addresses are not accepted\.

```JavaScript
function buildVolumeMulticallTransaction(volumeLedgerAddress, updates) {
  const calls = updates.map(({ method, securityId, amount, values, reasonCode }) => {
    if (!["setQuota", "setUsedWad"].includes(method)) {
      throw new Error("Expected setQuota or setUsedWad");
    }
    return method === "setQuota"
      ? volumeLedgerInterface.encodeFunctionData(method, [securityId, amount, reasonCode])
      : volumeLedgerInterface.encodeFunctionData(method, [securityId, values, reasonCode]);
  });
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("multicall", [calls]),
    value: 0n,
  };
}

async function submitVolumeMulticallTransaction(oracleSigner, volumeLedgerAddress, updates) {
  const transaction = buildVolumeMulticallTransaction(volumeLedgerAddress, updates);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}
// setQuota item: { method: "setQuota", securityId, amount, reasonCode }
// setUsedWad item: { method: "setUsedWad", securityId, values, reasonCode }
```

Each `results[i]` contains the ABI\-encoded return value of subcall i; both write functions return no value, so their results are `0x`\. Parse `QuotaSet` / `UsedWadSet` events from the Ledger proxy in the transaction receipt\. Repeated writes to a security's quota, or to its usage on the same day, use the last value\. This helper permits only the two backend write methods\. The contract's `multicall` can combine other public entry points, but does not bypass role or Hook caller checks\.

### 8\. Multiplier Changes: Synchronizing Quota and usedWad

**The Ledger does not automatically update quotas or usage when the multiplier changes\.** The current `ERC8056DirectLegalShareAdapter` computes `legalSharesWad = floor(rawAmount × multiplier / 10^decimals)`\. The algorithm below preserves the underlying raw\-token quantities represented by the quota and usage, restating both in the new multiplier's share units\. It assumes unchanged token decimals and Adapter conversion logic\.

#### Formula and Rounding

Let `Mold` be the multiplier basis currently used by these quota and usage values, and `Mnew` the new multiplier\. Both must be positive\. Obtain `Mold` from the backend's persisted accounting\-basis record; after activation, do not use the latest on\-chain multiplier as both the old and new value\.

```Plaintext
quotaNewWad = floor(quotaOldWad × Mnew / Mold)
usedNewWad  = ceil(usedOldWad × Mnew / Mold)
remainingNewWad = max(quotaNewWad - usedNewWad, 0)
```

The ratio is **new multiplier / old multiplier**, not its inverse\. Both multipliers have the same precision, which cancels in the ratio; do not multiply or divide by an additional `10^18`\. Multiply integers before dividing, use `bigint` throughout, and do not calculate a floating\-point ratio first\. Rounding quota down and usage up is this guide's conservative backend conversion policy, intended to avoid increasing available quota through rounding\. Neither setter implements this rounding internally\.

|Old → new multiplier|Old quota / usage \(shares\)|New quota / usage \(shares\)|New remaining quota \(shares\)|
|---|---|---|---|
|`1e18 → 2e18`|`1000 / 300`|`2000 / 600`|`1400`|
|`2e18 → 1e18`|`1000 / 300`|`500 / 150`|`350`|

Apply the formula even at the smallest WAD unit\. For example, `Mold = 3e18`, `Mnew = 2e18`, `quotaOldWad = 10`, and `usedOldWad = 4` produce `quotaNewWad = 6`, `usedNewWad = 3`, and remaining quota 3\. These example amounts are integer WAD units, not whole shares\. Do not clamp `usedNewWad` to `quotaNewWad`, or scale remaining quota first and infer usage from it\.

#### Backend Execution Order

1. **Lock the security and pause trading\.** Acquire a backend exclusive job for `(chainId, ledgerAddress, securityId)` and stop other quota/usage writers\. Pause swaps across every pool of the security before the new multiplier activates, and wait for confirmation\. A `HALT_REPORTER_ROLE` holder can call `applySecurityStatus(securityId, 0, true, reasonCode)` to set the TRADE pause bit\. The `mode` argument is an operation selector enum \(`TRADE=0`, `LP=1`, `ALL=2`\), while `getSecurityPauseMode` returns a bitmask \(`0` unpaused, `1` TRADE, `2` LP, `3` ALL\)\. The contract preserves unselected bits\. On restoration, clear only the TRADE bit set by this job with `applySecurityStatus(securityId, 0, false, reasonCode)`\. Both calls require a nonzero `reasonCode`, and a no\-op reverts\. Do not repeat a pause already in effect or clear one imposed by another administrator\. This role differs from `VOLUME_ORACLE_ROLE`; stopping backend quotes alone does not block other on\-chain trading entry points\.

2. **Choose days and snapshot the old basis\.** After pause confirmation, read `currentESTDay()`, the security's single `Quota`, and `usedWad` for target days at the same block\. Record its number and hash, original values, and `Mold`\. Derive the current EST day using Section 3\. Convert `Quota` once; also convert future\-day usage still on the old basis, but do not reconvert usage already corrected to the new basis\. Keep completed days as historical records by default\. If the process crosses 05:00 UTC, recheck the usage basis of the day on which trading resumes\.

3. **Confirm the new multiplier and scope\.** Resolve the Adapter through `registry.getUnderlying(underlyingToken).legalShareAdapter`, then call `currentMultiplier(underlyingToken)` to confirm that `Mnew` is active\. Calculations may be prepared earlier from an issuer\-confirmed schedule\. Scale a security's aggregate only if all affected quota and usage values share the same old basis and all related underlying tokens use the same conversion ratio\. Pools sharing a `securityId` share its usage; convert each security/day once, rather than once per pool\.

4. **Calculate and write atomically\.** Generate one `quotaNewWad` and `usedValues` for target days using the formulas above\. Execute `setQuota(securityId, quotaNewWad, reasonCode)` and `setUsedWad(securityId, usedValues, reasonCode)` in one Ledger `multicall`\. The signer must hold `VOLUME_ORACLE_ROLE`\. Simulate and estimate gas for the full batch before submitting it\. Keep trading, other writes, and further multiplier changes coordinated and paused until verification completes\. Registry pause operations and the external token's multiplier update are outside the atomic scope of Ledger `multicall`\.

5. **Verify before resuming\.** Check the single `QuotaSet` and every `UsedWadSet` in the successful receipt, then read back quota, usage, and the new multiplier at the receipt block\. After confirmation, mark the security quota's basis and each target day's usage basis as `Mnew`, and record the transaction hash and unique change\-event ID\. Restore only operations paused by this job, preserving pauses imposed by other administrators\. On failure, keep trading paused while resolving the issue\.

The multiplier query ABI is `function currentMultiplier(address underlyingToken) view returns (uint256)`\. Neither Ledger setter accepts an expected old value or multiplier\. `multicall` makes the two writes atomic but does not verify snapshot freshness; backend locking, an on\-chain pause, and coordination of multiplier changes remain necessary\.

#### Calculation and Batch Construction

The example reuses the submission helper from Section 7\. `quotaWad` is the security's single quota; `snapshots` contains target\-day usage read at the same paused block, each shaped as `{ ESTDay, usedWad }`\. None of these values has already been converted from `oldMultiplier` to `newMultiplier`\.

```JavaScript
function buildMultiplierSyncUpdates(input) {
  const { securityId, quotaWad, oldMultiplier, newMultiplier, snapshots, reasonCode } = input;
  const maxUint256 = (1n << 256n) - 1n;
  const checkUint256 = (value) => {
    if (typeof value !== "bigint" || value < 0n || value > maxUint256) {
      throw new Error("Expected uint256 bigint");
    }
  };
  checkUint256(oldMultiplier);
  checkUint256(newMultiplier);
  checkUint256(quotaWad);
  if (oldMultiplier === 0n || newMultiplier === 0n) throw new Error("Zero multiplier");
  if (snapshots.length === 0) throw new Error("Empty snapshots");
  const seenDays = new Set();
  const usedValues = [];
  for (const { ESTDay, usedWad } of snapshots) {
    [ESTDay, usedWad].forEach(checkUint256);
    if (seenDays.has(ESTDay)) throw new Error("Duplicate ESTDay");
    seenDays.add(ESTDay);
    const usedNewWad = (usedWad * newMultiplier + oldMultiplier - 1n) / oldMultiplier;
    checkUint256(usedNewWad);
    usedValues.push({ ESTDay, amount: usedNewWad });
  }
  const quotaNewWad = (quotaWad * newMultiplier) / oldMultiplier;
  checkUint256(quotaNewWad);
  return [
    { method: "setQuota", securityId, amount: quotaNewWad, reasonCode },
    { method: "setUsedWad", securityId, values: usedValues, reasonCode },
  ];
}
// const updates = buildMultiplierSyncUpdates(syncInput);
// await submitVolumeMulticallTransaction(oracleSigner, volumeLedgerAddress, updates);
```

#### Retries and Mixed Accounting Bases

Track processing by security, day, and multiplier\-change event\. Do not deduplicate only by the `Mold/Mnew` pair, because the same transition can occur again\. After a network timeout, check the original receipt and on\-chain values first\. Retry only the saved absolute target values, after confirming that the pause is still active, the job has not completed, and no later multiplier or administrator changes have occurred\. **Do not read already\-converted values and multiply them by the same ratio again\. Do not replay old absolute values after trading resumes, as doing so would overwrite new volume\.** `reasonCode` is only for event tracing; the contract does not use it for deduplication\.

If trades have occurred after the new multiplier activated, `usedWad` may mix old and new units\. Do not multiply the entire total by `Mnew/Mold`\. Pause first and reconstruct usage in execution order, partitioned by the actual multiplier: convert old\-basis usage and leave new\-basis usage unchanged\. For example, if old\-basis usage is 300 shares and another 50 shares trade under the doubled multiplier, the correct new total is `300 × 2 + 50 = 650`, not `(300 + 50) × 2 = 700`\. Include historical administrator corrections and earlier synchronizations in the basis records\. `VolumeUsed` alone does not contain a multiplier, so the current multiplier cannot establish the basis of each past trade\.

This algorithm scales stored WAD aggregates\. It can differ by rounding units from recalculating each raw trade under the new multiplier\. If exact per\-trade recalculation is required, retain each raw amount and reapply the Adapter's floor\-rounding rule\. A current aggregate without trustworthy old multipliers and segment records is insufficient to reconstruct mixed\-basis usage reliably; keep trading paused until reconciliation is complete\.

## Source References

- LP: TSVLPManagerV1, validation and unwind logic, and the inherited PositionManager\.

- Swap: TSVSwapRouterV1, SwapRequest, and Hook\.
