# TSV V1 后端接入 Guide

本指南按 Uniswap [Managing Liquidity](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/overview) 的方式组织：前置条件、ABI、编码、提交。**LP 与 Swap 的调用入口不同，以下分别说明。**

> 基于仓库提交 `70b5c2d0bff47084a0776b3412c8d86dff342be8`。所有业务调用使用代理地址，ABI 须与目标链部署版本一致。示例使用 ethers.js v6，编码函数生成 calldata；提交示例复用业务方提供的 Signer。报价及签名授权由接入方负责。

本文使用三个完整名称：**PermissionsAdapter 代币**是池内股票侧资产；**底层股票代币**是用户实际持有的股票资产；**报价代币**是池内另一侧资产。PermissionsAdapter 代币与底层股票代币的最小单位数量为 1:1。以下均针对 ERC-20 池，交易 `value = 0`。

## 一、LP Manager：管理流动性

```text
用户 / 已获 NFT 授权的 operator → TSVLPManagerV1.modifyLiquidities
管理员 → TSVLPManagerV1.unwindPosition 或 unwindPositionByOkx
```

普通增减仓由 LP Manager 的直接调用者执行；涉及补款时，该调用者也是付款人。后端代发不会自动把用户识别为执行者。Mint、Increase、Decrease、Collect、Burn 都使用 `modifyLiquidities`，强退使用独立入口。

### 1. 入口与查询 ABI

以下 human-readable ABI 可直接传入 ethers `Interface`。`PoolKey` 已展开为完整 tuple；`PositionInfo` 的 ABI 类型为 `uint256`。

```javascript
import { AbiCoder, Interface, keccak256 } from "ethers";

const lpPoolKeyType = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const lpAbi = [
  "function modifyLiquidities(bytes unlockData,uint256 deadline) payable",
  "function modifyLiquiditiesWithoutUnlock(bytes actions,bytes[] params) payable",
  `function initializePool(${lpPoolKeyType} key,uint160 sqrtPriceX96) payable returns (int24 tick)`,
  "function unwindPosition(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "function unwindPositionByOkx(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)",
  "function multicall(bytes[] data) payable returns (bytes[] results)",
  "function approve(address spender,uint256 tokenId)",
  "function setApprovalForAll(address operator,bool approved)",
  "function ownerOf(uint256 tokenId) view returns (address)",
  "function getApproved(uint256 tokenId) view returns (address)",
  "function isApprovedForAll(address owner,address operator) view returns (bool)",
  `function getPoolAndPositionInfo(uint256 tokenId) view returns (${lpPoolKeyType} poolKey,uint256 info)`,
  "function getPositionLiquidity(uint256 tokenId) view returns (uint128 liquidity)",
  "function TOKEN_APPROVE_PROXY() view returns (address)",
  "function registry() view returns (address)",
  "function FORCE_EXIT_ADMIN_ROLE() view returns (bytes32)",
  "function POOL_CREATOR_ROLE() view returns (bytes32)",
  "event Transfer(address indexed from,address indexed to,uint256 indexed id)",
  "event CurrencyUnwound(uint256 indexed tokenId,address indexed currency,address indexed recipient,address caller,address lp,uint256 amount,bool asClaim)",
];

const abiCoder = AbiCoder.defaultAbiCoder();
const lpInterface = new Interface(lpAbi);
```

| 入口 | 用途及调用条件 | 返回值 |
| --- | --- | --- |
| `modifyLiquidities(bytes,uint256)` | 用户或已授权 operator 的普通 LP 操作；payable | 无 |
| `initializePool(PoolKey,uint160)` | `POOL_CREATOR_ROLE` 创建池；payable | `int24 tick` |
| `unwindPosition(uint256,uint128,uint128,bytes)` | PermissionsAdapter 合约 owner 发起强退；nonpayable | 无 |
| `unwindPositionByOkx(uint256,uint128,uint128,bytes)` | `FORCE_EXIT_ADMIN_ROLE` 发起强退；nonpayable | 无 |
| `approve(address,uint256)` / `setApprovalForAll(address,bool)` | NFT 授权；不提供 Token 支付授权 | 无 |
| `multicall(bytes[])` | 同一调用者执行多项 LP Manager 调用；任一失败全部回滚 | 各子调用返回的 `bytes[]` |
| `modifyLiquiditiesWithoutUnlock(bytes,bytes[])` | 仅供已有 PoolManager unlock 上下文的组合调用；不负责 unlock，也不检查 deadline | 无 |

普通交易用 `modifyLiquidities`，不要直接调用 `unlockCallback`。代理初始化、升级、订阅及 Permit2 转发不在本指南范围内；下面的 TokenApprove 授权不能由 Permit2 授权替代。

### 2. 前置条件与授权

普通 LP 操作，包括领取手续费和普通关闭仓位，均检查：

| 检查项 | 调用或条件 |
| --- | --- |
| 全局及池准入 | `registry.isPaused() == false`，`registry.isLPAllowed(poolId) == true` |
| SBT | 执行者、NFT owner、显式收款人均通过 `registry.isSbtAllowed(0x0002, account)`；仅持有任意 SBT 不够 |
| NFT 授权 | 修改已有仓位时，执行者为 `ownerOf(tokenId)`、`getApproved(tokenId)` 或 owner 的 operator |
| Mint / Increase 发行方准入 | PermissionsAdapter 合约已被 Factory 验证、允许池 Hook，且 `permissionsAdapter.isAllowed(owner, 0x0002)` |
| 补充股票资产 | 执行者通过 `permissionsAdapter.isAllowed(executor, 0x0002)`；PermissionsAdapter 合约允许 LP Manager 作为 wrapper |
| 付款授权 | `approveProxy = lpManager.TOKEN_APPROVE_PROXY()`；`spender = approveProxy.tokenApprove()`；付款人对该 spender 授权实际支付的底层股票代币 / 报价代币 |
| Proxy 配置与余额 | `approveProxy.isAllowedProxy(lpManagerAddress) == true`；付款人余额和 allowance 足够 |
| 交付 | 收款人能通过底层股票代币的实际转账合规检查 |

用于上述检查的 ABI：

```javascript
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
const lpApproveProxyAbi = [
  "function tokenApprove() view returns (address)",
  "function isAllowedProxy(address proxy) view returns (bool)",
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

### 3. 公共参数

| 参数 | 类型与要求 |
| --- | --- |
| `poolKey` | `(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)`；使用已注册 Key，`currency0 < currency1`；股票侧填 PermissionsAdapter 地址 |
| `tokenId` | `uint256`，仓位 NFT ID；用 `getPoolAndPositionInfo`、`getPositionLiquidity` 查询池及流动性，先确认 NFT 存在 |
| `liquidity` | `uint256`，流动性单位，不是 Token 数量；按池价、tick 区间和资产预算计算 |
| `amount0Max/1Max` | `uint128`，本金支付上限；按 currency0/1 的最小单位计量 |
| `amount0Min/1Min` | `uint128`，移除本金最低金额；不包括额外领取的手续费 |
| `recipient` | `address`；Mint 时接收 NFT，TAKE_PAIR 时接收实际资产；建议使用真实地址 |
| `hookData` | `bytes`；可为 `0x`，或一个 `uint256 expectedMultiplier` 的 ABI 编码，非空必须为 32 字节 |
| `deadline` | `uint256`，Unix 秒；`block.timestamp > deadline` 时普通 LP 调用失败 |

非空 `hookData` 的倍数需分两步读取：先从 `registry.getUnderlying(underlyingToken)` 取得 `legalShareAdapter` 地址，再对该合约调用 `currentMultiplier(underlyingToken)`；必须非零且与执行时一致。编码方式为 `abiCoder.encode(["uint256"], [expectedMultiplier])`。`poolId` 是完整 PoolKey 的标准 ABI 编码的 keccak256，可用 `keccak256(abiCoder.encode([lpPoolKeyType], [poolKey]))` 计算。

### 4. 普通 LP 的编码与提交

Mint、Increase、Decrease、Collect、Burn 均使用下面的公共封装。`actions` 每个字节对应一个 `params[i]`；各参数用标准 ABI 编码，只有 action 指令按字节直接拼接。

```javascript
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

| Action | 指令 | 单个 `params[i]` 的类型顺序 |
| --- | --- | --- |
| `MINT_POSITION` | `0x02` | `PoolKey,int24,int24,uint256,uint128,uint128,address,bytes` |
| `INCREASE_LIQUIDITY` | `0x00` | `uint256,uint256,uint128,uint128,bytes` |
| `DECREASE_LIQUIDITY` | `0x01` | `uint256,uint256,uint128,uint128,bytes` |
| `BURN_POSITION` | `0x03` | `uint256,uint128,uint128,bytes` |
| `SETTLE_PAIR` | `0x0d` | `address,address` |
| `TAKE_PAIR` | `0x11` | `address,address,address` |
| `CLOSE_CURRENCY` | `0x12` | `address` |

下文函数复用本章的 `abiCoder`、`lpInterface`、`lpPoolKeyType` 和 `buildLpTransaction`。所有大整数使用 `bigint`；价格与数量须来自真实查询和报价，不能直接用 JavaScript 浮点数计算。

#### Mint：新建仓位

`tickLower < tickUpper`，两者均对齐 `poolKey.tickSpacing` 且位于合法 tick 范围；`recipient` 接收不可转让的仓位 NFT。

```javascript
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

```javascript
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

```javascript
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

```javascript
function buildCollectTransaction(input) {
  return buildDecreaseTransaction({
    ...input, liquidity: 0n, amount0Min: 0n, amount1Min: 0n,
  });
}
```

#### Burn：普通关闭仓位

指令为 `BURN_POSITION → TAKE_PAIR`。移除全部流动性、结算手续费并销毁 NFT；仍须满足普通 LP 前置条件。

```javascript
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

### 5. Initialize Pool：创建池

入口为 `initializePool(PoolKey key,uint160 sqrtPriceX96) payable returns (int24 tick)`。

调用者须持有 `POOL_CREATOR_ROLE`，Registry 全局未暂停；PermissionsAdapter 合约、报价代币和证券配置须已准入，至少一侧为 Factory 已验证且 owner 非零的 PermissionsAdapter 合约。池注册和初始化任一失败都会整笔回滚。

`sqrtPriceX96 = floor(sqrt(currency1Raw / currency0Raw) × 2^96)`，按两种资产的最小单位计算，并满足 v4 价格范围；计算时须考虑 decimals。

```javascript
function buildInitializePoolTransaction(lpManagerAddress, poolKey, sqrtPriceX96) {
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("initializePool", [poolKey, sqrtPriceX96]),
    value: 0n,
  };
}
```

### 6. Unwind：管理员强制关闭

两个独立入口均直接调用 LP Manager 代理，无返回值、不可携带原生币，也无需组装 actions。

| 前置条件 / 行为 | `unwindPosition` | `unwindPositionByOkx` |
| --- | --- | --- |
| 调用者 | 池内任一已验证 PermissionsAdapter 合约的 `owner()` | Registry 的 `FORCE_EXIT_ADMIN_ROLE` 持有者 |
| 仓位资格 | NFT 存在；至少一侧已验证 PermissionsAdapter 合约的 `isAllowed(lp, 0x0004)` 为 true | 同左 |
| SBT / NFT 授权 | 不要求 LP 或管理员通过普通 LP SBT 校验，也无需 LP 预先授权 NFT | 同左 |
| 暂停与池准入 | 全局未暂停；当前版本强退绕过普通 `isLPAllowed`，执行 Hook 时仍检查已注册池及 Hook 身份 | 同左 |
| 接收人 | 每种资产先尝试 LP；失败后仅权限资产尝试该 PermissionsAdapter 合约 owner；仍失败则整笔回滚 | 两种资产直接发给 LP；任一交付失败则整笔回滚 |
| 结果 | 销毁 NFT；不会向用户交付无法赎回的 claim 作为兜底 | 销毁 NFT |

参数均为 `(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)`；没有 `recipient` 和 `deadline`。`hookData` 规则与普通 LP 相同。**SBT 被撤销不自动等于允许 unwind**，必须实际查询 PermissionsAdapter 合约的 `UNWIND_ALLOWED = 0x0004`。

```javascript
function buildIssuerUnwindTransaction(input) {
  const { lpManagerAddress, tokenId, amount0Min, amount1Min, hookData = "0x" } = input;
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("unwindPosition",
      [tokenId, amount0Min, amount1Min, hookData]),
    value: 0n,
  };
}

function buildOkxUnwindTransaction(input) {
  const { lpManagerAddress, tokenId, amount0Min, amount1Min, hookData = "0x" } = input;
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("unwindPositionByOkx",
      [tokenId, amount0Min, amount1Min, hookData]),
    value: 0n,
  };
}
```

发行方强退的 `CurrencyUnwound` 事件给出每种非零资产最终接收人；OKX 强退不走该交付事件路径。当前版本 `withdrawClaim(address,uint256,address)` 已禁用；普通 LP 入口不能提交 `MINT_6909` 或 `UNWIND_WITH_FALLBACK`。

### 7. LP 交易提交

以下复用业务钱包提供的 ethers `Signer`，必须与本次操作要求的执行者或管理员一致：

```javascript
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

```text
用户 → 外部交易入口 / 合约 Adapter → TSVSwapRouterV1.swapExactInputFromAdapterDirect
```

**Swap Router 的直接调用者必须是已获授权的合约 Adapter，不能是用户 EOA。** `participant` 是实际付款和身份校验的用户；`recipient` 是输出资产接收人。本章只定义 Adapter 调用 TSV Router 的接口；用户发送给外部交易入口的 calldata 取决于所接入 Adapter 的 ABI，不能由这两个目标合约推导。

这里的 Adapter 是外部交易接入合约，与池中的 `PermissionsAdapter` 合约是不同角色。

### 1. Swap 入口与查询 ABI

这一章可独立使用，不依赖 LP 的 actions 或编码器。

```javascript
import { Interface } from "ethers";

const swapPoolKeyType = "tuple(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)";
const swapRequestType = `tuple(${swapPoolKeyType} key,bool zeroForOne,uint128 amountSpecified,uint128 limitAmount,uint64 deadline,uint256 expectedMultiplier)`;
const swapRouterAbi = [
  `function swapExactInputFromAdapterDirect(${swapRequestType} request,address participant,address recipient) returns (uint256 actualIn,uint256 actualOut)`,
  "function settlementCurrency(address currency) view returns (address)",
  "function isAdapterAllowed(address adapter) view returns (bool allowed)",
  "function setAdapterAllowed(address adapter,bool allowed)",
  "function registry() view returns (address)",
];
const swapInterface = new Interface(swapRouterAbi);
```

主入口是 nonpayable，返回 `(uint256 actualIn,uint256 actualOut)`；内部自行组装 Swap、Settle、Take，后端不传 LP `actions` 或 `unlockData`。`setAdapterAllowed` 仅供 Registry 的 `DEFAULT_ADMIN_ROLE` 配置调用者，不能由普通用户自行授权。

### 2. Swap 前置条件与授权

| 检查项 | 调用或条件 |
| --- | --- |
| 调用者 | `router.isAdapterAllowed(adapterAddress) == true`，且由该合约实际发起调用 |
| 全局及池准入 | `registry.isPaused() == false`；`registry.isTradable(poolId) == true`；Key 为已注册且绑定正确 Hook 的池 |
| SBT | `registry.isSbtAllowed(0x0001, participant) == true` |
| 发行方准入 | PermissionsAdapter 合约已被验证且允许该 Hook；`swappingEnabled() == true`；`isAllowed(participant, 0x0001) == true` |
| 股票输入包装 | 若输入为底层股票代币，PermissionsAdapter 合约须允许 **Swap Router 代理地址**作为 wrapper |
| 余额与授权 | participant 持有足够输入资产，并对 **Swap Router 代理地址**授权输入代币；此入口不使用 LP 的 TokenApprove |
| 接收人 | participant、recipient 均非零；recipient 满足实际输出资产的接收条件 |
| 报价状态 | deadline 未过期；倍数快照匹配；市场报告及成交量额度允许本次交易 |

Router 显式检查 participant 的 SBT；不会把 recipient 当成 participant 再执行一次同样的 SBT 检查。输出底层股票代币时，其转账合规检查仍可能拒绝 recipient。

查询和 Token 授权 ABI：

```javascript
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

对池 currency 调用 `router.settlementCurrency(currency)` 可取得实际结算代币地址：股票侧返回底层股票代币地址，报价侧返回报价代币自身。用户应对这个实际输入代币执行 `approve(routerAddress, amountIn)`。

### 3. SwapRequest 参数

| 字段 | ABI 类型 | 要求 |
| --- | --- | --- |
| `key` | `tuple(address,address,uint24,int24,address)` | 顺序为 currency0、currency1、fee、tickSpacing、hooks；股票侧填 PermissionsAdapter 地址 |
| `zeroForOne` | `bool` | true：currency0 → currency1；false：反向 |
| `amountSpecified` | `uint128` | 精确输入最小单位数量，`0 < amountSpecified <= 2^127 - 1` |
| `limitAmount` | `uint128` | 最低输出最小单位数量，必须大于 0 |
| `deadline` | `uint64` | Unix 秒，不是毫秒 |
| `expectedMultiplier` | `uint256` | 报价时读取的非零倍数；执行时必须一致 |
| `participant` | `address`，request 外的第二个参数 | 原始用户，同时是实际付款人 |
| `recipient` | `address`，request 外的第三个参数 | 输出资产接收人 |

倍数读取顺序：先用 `registry.getUnderlying(underlyingToken)` 找到 `legalShareAdapter`，再对该合约调用 `currentMultiplier(underlyingToken)`。价格或倍数变化后应重新报价，不只替换快照数值。

### 4. 编码 Adapter → Router 调用

`request` 必须包含上表前六个字段，保持原字段名。金额、deadline、expectedMultiplier 使用 `bigint`。

```javascript
function buildSwapRouterCall(input) {
  const { routerAddress, poolKey, zeroForOne, amountIn, amountOutMin,
    deadline, expectedMultiplier, participant, recipient } = input;
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
    data: swapInterface.encodeFunctionData("swapExactInputFromAdapterDirect",
      [request, participant, recipient]),
    value: 0n,
  };
}
```

该结果供已授权 Adapter 执行内部调用，**不要直接交给用户钱包 `sendTransaction`**。Adapter 必须按其自身授权规则绑定 participant、输入数量和 recipient；完整用户交易还需外部入口的 ABI。

### 5. 模拟与结果解析

下面模拟的是内部调用，`adapterAddress` 必须是允许的 Adapter。它不能替代对完整外部交易的模拟。

```javascript
async function simulateSwapRouterCall(provider, adapterAddress, input) {
  const call = buildSwapRouterCall(input);
  const result = await provider.call({ ...call, from: adapterAddress });
  const [actualIn, actualOut] = swapInterface.decodeFunctionResult(
    "swapExactInputFromAdapterDirect", result,
  );
  return { actualIn, actualOut };
}
```

成功时 `actualIn == amountSpecified` 且 `actualOut >= limitAmount`；未全部消耗输入会整笔回滚。交易回执本身不包含 Solidity 返回值，入账须解析实际成交 / 资产转账日志，不能把模拟输出当成已成交数量。

常见失败：`AdapterNotAllowed()` 为直接调用者未授权；`Expired()` 为过期；`PoolNotTradable()` 为池不可交易；`MultiplierChanged()` 为报价倍数已变；`SlippageExceeded()` 为本路由检查到输入未全部成交或无有效输出，v4 也可能返回自身的最低输出错误。

## 三、Volume Ledger：后端设置每日成交量额度

```text
持有 VOLUME_ORACLE_ROLE 的后端账户 → TSVVolumeLedgerV1.setQuota / setUsedWad
```

本章基于提交 `74d6317bfd896f9836808554c67a1a4fe4b2ed37` 的 `TSVVolumeLedgerV1`，额度设置入口为 **`setQuota`**；本次新增的 **`setUsedWad`** 用于修正已累计成交量，见第 6 节；`multicall` 支持跨证券批量调用，见第 7 节。直接调用 Volume Ledger 代理，为一个证券批量设置多个 EST day 的每日总额度；nonpayable，无返回值，`value = 0`。

### 1. 前置条件与 ABI

调用账户须持有 **Ledger 所引用 Registry 中的 `VOLUME_ORACLE_ROLE`**，即 `registry.hasRole(keccak256("VOLUME_ORACLE_ROLE"), caller) == true`。`securityId` 使用 Registry 中目标证券的非零 ID；额度按 `securityId + ESTDay` 共享，同一证券的多个池共同消耗，不按池或用户单独分配。

本章示例可独立使用：

```javascript
import { Contract, Interface, ZeroAddress, ZeroHash, formatUnits } from "ethers";

const volumeLedgerAbi = [
  "function multicall(bytes[] data) returns (bytes[] results)",
  "function registry() view returns (address)",
  "function currentESTDay() view returns (uint256)",
  "function Quota(bytes32 securityId,uint256 ESTDay) view returns (uint256)",
  "function usedWad(bytes32 securityId,uint256 ESTDay) view returns (uint256)",
  "function setQuota(bytes32 securityId,tuple(uint256 ESTDay,uint256 amount)[] values,bytes32 reasonCode)",
  "function setUsedWad(bytes32 securityId,tuple(uint256 ESTDay,uint256 amount)[] values,bytes32 reasonCode)",
  "event QuotaSet(bytes32 indexed securityId,uint256 indexed ESTDay,uint256 amount,bytes32 reasonCode)",
  "event UsedWadSet(bytes32 indexed securityId,uint256 indexed ESTDay,uint256 amount,bytes32 reasonCode)",
];
const volumeLedgerInterface = new Interface(volumeLedgerAbi);
const volumeRegistryAbi = [
  "function getCurrencyUnderlying(address currency) view returns (address underlying)",
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals,bool registered))",
];
```

| 参数 | ABI 类型 | 要求 |
| --- | --- | --- |
| `securityId` | `bytes32` | 目标证券 ID，不能为零；不是 poolId 或代币地址 |
| `values` | `tuple(uint256 ESTDay,uint256 amount)[]` | 同一证券的日期及额度数组；可以提前设置未来日期；后端应传入非空且日期不重复的数组 |
| `values[i].ESTDay` | `uint256` | 按下面公式计算的 epoch day 整数；不是 Unix timestamp，也不是 `YYYYMMDD` |
| `values[i].amount` | `uint256` | 当日总额度，单位为 **legal-share WAD（1 股 = `10^18`）**；例如 1,000 股为 `1000n * 10n ** 18n`，不是报价代币金额或底层代币 raw amount |
| `reasonCode` | `bytes32` | 后端约定的原因码，同一批次共用；原样写入事件，合约不校验其业务含义 |

### 2. 从 Token 获取 securityId 并查询当日额度

累计量的准确接口名为 **`usedWad`**，表示已使用的 legal-share WAD，单位不是美元。以下查询均为 `view`，只需 Provider，无需 Signer 或 `VOLUME_ORACLE_ROLE`。

先通过 `ledger.registry()` 取得对应 Registry 地址，再按已知的股票 Token 类型查询：

| 已知地址 | 获取 `securityId` 的调用链 |
| --- | --- |
| 用户持有的底层股票代币 `underlyingToken` | `registry.getUnderlying(underlyingToken).securityId` |
| 池内股票侧 `PermissionsAdapter` 地址 | 先 `underlyingToken = registry.getCurrencyUnderlying(permissionsAdapterAddress)`，再 `registry.getUnderlying(underlyingToken).securityId` |

**不要自行对 token symbol 或地址做 hash 来生成 `securityId`，也不要传入报价代币地址。** 未知 PermissionsAdapter 返回零底层地址，未知底层代币返回默认记录（`securityId == 0`），后端应报错。`registered` 表示该底层代币是否允许用于注册新池，不应仅因其为 false 就丢弃已存储的证券 ID 或历史成交量。

| 查询 | 返回含义 |
| --- | --- |
| `ledger.currentESTDay()` | 查询区块对应的 EST day |
| `ledger.Quota(securityId, day)` | 当日总额度上限，注意方法名首字母大写 `Q` |
| `ledger.usedWad(securityId, day)` | 当日已累计成交量，买卖都消耗额度，不按方向抵消 |

下面一次返回证券 ID、当日上限、累计量和剩余额度。所有调用固定在同一个 `blockTag`，避免跨日或期间成交导致读取口径不一致；`tokenKind` 必须明确是 `"underlying"` 或 `"permissionsAdapter"`。

```javascript
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
    ledger.Quota(securityId, ESTDay, atBlock),
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

返回的 `quotaWad`、`usedWad`、`remainingWad` 是 `bigint`；用于展示的 `*Shares` 是十进制字符串，不要转换为浮点数参与额度计算。读取到的 `securityId` 可直接用于后续 `setQuota`；如需查询指定日期，使用第 3 节换算得到的 `ESTDay` 替换 `currentESTDay()` 的结果。

### 3. EST day：从 UTC Unix timestamp 换算

**输入必须是 Unix timestamp（UTC+0 基准、秒），直接减去 5 小时，再除以一天的秒数并向下取整。不要先将 timestamp 转为本地时间或 EST 后再次减 5 小时。**

```text
ESTDay = floor((unixTimestampSeconds - 5 × 3600) / 86400)
       = floor((unixTimestampSeconds - 18000) / 86400)

某个 ESTDay 的 UTC 时间区间：
[ESTDay × 86400 + 18000, (ESTDay + 1) × 86400 + 18000)
```

这与合约 `currentESTDay()` 的 `(block.timestamp - 5 hours) / 1 days` 一致。**全年固定 EST = UTC−5，不启用夏令时；不要使用会切换到 EDT（UTC−4）的 `America/New_York` 时区规则。** 日界线为 UTC **05:00:00**，即固定 EST 的 00:00:00；UTC 00:00 至 04:59:59 仍属于前一个 EST day。

| UTC 时间 | Unix timestamp（秒） | 固定 EST 时间（UTC−5） | `ESTDay` |
| --- | --- | --- | --- |
| `2026-10-12T04:59:59Z` | `1791781199` | `2026-10-11 23:59:59` | `20737` |
| `2026-10-12T05:00:00Z` | `1791781200` | `2026-10-12 00:00:00` | `20738` |
| `2026-10-13T04:59:59Z` | `1791867599` | `2026-10-12 23:59:59` | `20738` |
| `2026-10-13T05:00:00Z` | `1791867600` | `2026-10-13 00:00:00` | `20739` |

后端可直接复用以下换算。JavaScript 的 `Date.now()` 返回毫秒，须先除以 1,000；`block.timestamp` 已是秒，不要再除以 1,000。

```javascript
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

设置“当前日”时，建议用最新链上区块的 `timestamp` 换算，并与 Ledger 的 `currentESTDay()` 核对；服务器时间只用于辅助。`setQuota` 按传入的 `ESTDay` 写入，不会自动替换为交易执行当天。应提前设置下一日额度，避免跨 UTC 05:00 时新一天未配置额度。

### 4. 编码与提交

`values` 中的字段名保持 `ESTDay` 和 `amount`，日期及数量均用 `bigint`。

```javascript
function buildSetQuotaTransaction(volumeLedgerAddress, securityId, values, reasonCode) {
  return {
    to: volumeLedgerAddress,
    data: volumeLedgerInterface.encodeFunctionData("setQuota", [securityId, values, reasonCode]),
    value: 0n,
  };
}

async function submitSetQuotaTransaction(oracleSigner, input) {
  const { volumeLedgerAddress, securityId, values, reasonCode } = input;
  const transaction = buildSetQuotaTransaction(volumeLedgerAddress, securityId, values, reasonCode);
  const from = await oracleSigner.getAddress();
  await oracleSigner.provider.call({ ...transaction, from });
  const gasLimit = await oracleSigner.estimateGas(transaction);
  const response = await oracleSigner.sendTransaction({ ...transaction, gasLimit });
  return await response.wait();
}

// 示例批次；securityId、reasonCode、代理地址及 oracleSigner 由业务方提供。
const values = [
  { ESTDay: targetESTDay, amount: 1000n * 10n ** 18n },
  { ESTDay: targetESTDay + 1n, amount: 1200n * 10n ** 18n },
];
```

### 5. 覆盖语义与结果核对

**`amount` 是当日总额度，不是追加额度或剩余额度。** 每项直接覆盖 `Quota[securityId][ESTDay]`，不会重置 `usedWad[securityId][ESTDay]`。例如已用 300 股、总额度 1,000 股，改为 1,200 股后剩余 900 股。合约允许将额度降至已用量以下，但之后的正成交量交易会因超额失败，直到额度足够或进入已配置的新一天。

未配置的日期额度默认为 0；设置 `amount = 0` 也会阻止该证券该日的后续正成交量交易，不表示无限额或恢复默认额度。每日独立计数，额度不会自动结转；成交校验使用执行时 `block.timestamp` 对应的 EST day。

合约允许空数组（不写入、不发事件）；同一批次重复日期会依次覆盖，以最后一项为准，每项均发出事件。后端应在提交前校验日期与数量，避免误写到错误日期。

成功回执中，筛选 **Volume Ledger 代理地址**发出的 `QuotaSet`，核对 `securityId`、`ESTDay`、`amount`、`reasonCode`。可读取 `Quota(securityId, ESTDay)` 和 `usedWad(securityId, ESTDay)`，按 `max(Quota - usedWad, 0)` 计算剩余额度；后续交易或额度更新可能改变读取结果。

`setQuota` 常见失败：`Unauthorized()` 为调用者没有 `VOLUME_ORACLE_ROLE`；`InvalidInput()` 为 `securityId` 为零。`QuotaExceeded(bytes32,uint256)` 出现在后续 Swap 的成交量记账阶段，第二个参数也是上述 EST day 整数；超额时整笔 Swap 回滚。

### 6. Set Used WAD：后端修正当日累计量

新增入口为 `setUsedWad(bytes32 securityId,DailyQuota[] values,bytes32 reasonCode)`；与 `setQuota` 共用 `DailyQuota` tuple、Registry 的 `VOLUME_ORACLE_ROLE` 以及 EST day 换算规则。nonpayable，无返回值。调用前确认目标链的 Ledger 实现已包含此新增接口。

**此处 `values[i].amount` 是修正后的已累计总量（legal-share WAD），直接覆盖 `usedWad[securityId][ESTDay]`，不会修改 `Quota`。** 可以调高、调低或设为 0；也允许写入超过额度的累计量，此时后续正成交量交易将失败，直到额度或累计量被调整到足够容纳新成交量。后续成交在修正后的值上继续累加。

例如总额度 1,000 股、累计量 300 股：`setUsedWad` 写入 200 股后，剩余变为 800 股；`setQuota` 写入 1,200 股则只改变总额度，累计量保持原值。两种写入不要混用。

一次调用仅针对一个 `securityId`，可批量修正多个日期；空数组不写入，重复日期以最后一项为准，每项均发出 `UsedWadSet` 事件。`securityId` 为零时返回 `InvalidInput()`，调用者缺少角色时返回 `Unauthorized()`。历史、当前和未来日期均按传入值写入，合约不限制日期范围。

```javascript
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

### 7. Multicall：跨证券批量设置

Ledger 继承 OpenZeppelin `Multicall`，提供 `multicall(bytes[] data) returns (bytes[] results)`。直接调用 Ledger 代理，`value = 0`；按数组顺序执行各子调用，保留原始 `msg.sender`，每个子调用仍检查自身权限。**任一子调用失败，整笔交易的状态及事件全部回滚。**

单个 `setQuota` / `setUsedWad` 仍只处理一个证券，但可用 `multicall` 将不同 `securityId` 的写入合并为一笔交易，也可组合额度设置和累计量修正。`data` 的每项是完整函数 calldata（含 selector），不是仅包含参数的 ABI 编码；目标均为当前 Ledger，不接受外部合约目标地址。

```javascript
function buildVolumeMulticallTransaction(volumeLedgerAddress, updates) {
  const calls = updates.map(({ method, securityId, values, reasonCode }) => {
    if (!["setQuota", "setUsedWad"].includes(method)) {
      throw new Error("Expected setQuota or setUsedWad");
    }
    return volumeLedgerInterface.encodeFunctionData(method, [securityId, values, reasonCode]);
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
// updates 每项：{ method: "setQuota" 或 "setUsedWad", securityId, values, reasonCode }
// 各项可以使用不同 securityId；values 的格式与前述单函数调用相同。
```

返回的 `results[i]` 为第 i 项的 ABI 编码返回值；两个写入函数均无返回值，对应 `0x`。交易回执应按 Ledger 代理地址解析 `QuotaSet` / `UsedWadSet` 事件。重复设置同一证券同一天的同一字段时，最后一次写入生效。该封装只允许两个后端写入方法；合约的 `multicall` 本身可组合其他公开入口，但不会绕过角色或 Hook 调用者检查。

### 8. Multiplier 变化：同步换算 Quota 与 usedWad

**Ledger 不会随 multiplier 变化自动更新额度或累计量。** 当前 `ERC8056DirectLegalShareAdapter` 的换算为 `legalSharesWad = floor(rawAmount × multiplier / 10^decimals)`。下面的算法用于保持同一原始 Token 数量所对应的额度和累计量，将二者统一换算到新 multiplier 的股数口径；假设 Token decimals 和 Adapter 换算方式不变。

#### 换算公式与取整

设 `Mold` 为这份额度及累计量当前使用的倍率，`Mnew` 为即将采用的新倍率，二者必须大于 0。`Mold` 必须来自后端保存的计量口径记录，不能在倍率生效后把链上最新倍率同时当成新旧值。

```text
quotaNewWad = floor(quotaOldWad × Mnew / Mold)
usedNewWad  = ceil(usedOldWad × Mnew / Mold)
remainingNewWad = max(quotaNewWad - usedNewWad, 0)
```

比例是 **新倍率 / 旧倍率**，不是反过来。两个 multiplier 使用相同精度，比例中精度相消，不要额外乘除 `10^18`。先做整数乘法，再做整数除法；全部使用 `bigint`，不要先计算浮点比例。额度向下取整、累计量向上取整是本指南的后端保守换算规则，避免换算舍入增加可用额度；不是 `setQuota` / `setUsedWad` 内置的取整逻辑。

| 旧倍率 → 新倍率 | 旧总额度 / 旧累计量（股） | 新总额度 / 新累计量（股） | 新剩余额度（股） |
| --- | --- | --- | --- |
| `1e18 → 2e18` | `1000 / 300` | `2000 / 600` | `1400` |
| `2e18 → 1e18` | `1000 / 300` | `500 / 150` | `350` |

不足 1 WAD 最小单位也要按公式处理：例如 `Mold = 3e18`、`Mnew = 2e18`、`quotaOldWad = 10`、`usedOldWad = 4`，结果为 `quotaNewWad = 6`、`usedNewWad = 3`，剩余 3；此例单位是 WAD 最小整数单位，不是整股。不要把 `usedNewWad` 截断到 `quotaNewWad`，也不要先缩放剩余额度再反推累计量。

#### 后端执行顺序

1. **锁定证券并暂停成交。** 对 `(chainId, ledgerAddress, securityId)` 建立后端排他任务，暂停其他额度/累计量写入。须在新倍率生效前暂停该证券所有池的 Swap，并等待暂停确认。当前 Registry 可由 `HALT_REPORTER_ROLE` 调用 `applySecurityStatus(securityId, mode)`：保留原暂停位并设置 `TRADE` 位（`NONE=0`、`TRADE=1`、`LP=2`、`ALL=3`，目标为 `oldMode | 1`）；若已经暂停交易则不重复调用。该权限与 `VOLUME_ORACLE_ROLE` 不同，仅停止后端报价不能阻止链上其他交易入口。
2. **确定目标日期及旧口径快照。** 暂停确认后，在同一区块读取 `currentESTDay()`、目标日的 `Quota` 和 `usedWad`，并记录区块号、区块 hash、原值和 `Mold`。当前 EST day 必须使用第 3 节公式。未来已配置且仍使用旧倍率口径的日期也要换算；已按新口径配置的日期不得重复换算。默认保留已结束日期的历史账，跨 UTC 05:00 后须重新确认恢复交易当天及预配置日期均已覆盖。
3. **确认新倍率及适用范围。** 从 `registry.getUnderlying(underlyingToken).legalShareAdapter` 获取 Adapter，再调用 `currentMultiplier(underlyingToken)` 确认 `Mnew` 已生效；此前可先依据发行方已确认的计划准备计算。只有该证券所有累计量和额度使用同一旧口径，且所有相关底层 Token 采用同一换算比例时，才能对证券总量整体缩放。多个池共享 `securityId`，每个证券每天只换算一次，不能逐池重复写入。
4. **计算并原子写入。** 按上述公式生成两个相同日期集合的数组，在一次 Ledger `multicall` 中执行 `setQuota(securityId, quotaValues, reasonCode)` 和 `setUsedWad(securityId, usedValues, reasonCode)`。提交账户须有 `VOLUME_ORACLE_ROLE`；完整批次先模拟、估算 gas，再提交。保持成交、其他写入及进一步倍率变更协调暂停，直到核对完成。Registry 暂停操作和外部 Token 的倍率更新不属于 Ledger `multicall` 的原子范围。
5. **核对后恢复。** 成功回执中核对全部 `QuotaSet` / `UsedWadSet`；在该回执区块回读额度、累计量与新倍率。确认成功后，后端将各目标日的计量口径标记为 `Mnew`，记录交易 hash 和变更事件唯一 ID，再恢复本任务暂停的操作，保留其他管理员设置的暂停状态。失败则维持暂停并处理，不先恢复交易。

`currentMultiplier` 的查询 ABI 为 `function currentMultiplier(address underlyingToken) view returns (uint256)`。Ledger 两个 setter 不接收预期旧值或 multiplier，`multicall` 只保证两次写入原子性，不保证快照仍有效；后台锁、链上暂停和倍率变更协调不能省略。

#### 计算与组装示例

下面复用第 7 节的提交函数。`snapshots` 是同一暂停区块读取的目标日期数组，各项格式为 `{ ESTDay, quotaWad, usedWad }`，且均尚未从 `oldMultiplier` 换算到 `newMultiplier`。

```javascript
function buildMultiplierSyncUpdates(input) {
  const { securityId, oldMultiplier, newMultiplier, snapshots, reasonCode } = input;
  const maxUint256 = (1n << 256n) - 1n;
  const checkUint256 = (value) => {
    if (typeof value !== "bigint" || value < 0n || value > maxUint256) {
      throw new Error("Expected uint256 bigint");
    }
  };
  checkUint256(oldMultiplier);
  checkUint256(newMultiplier);
  if (oldMultiplier === 0n || newMultiplier === 0n) throw new Error("Zero multiplier");
  if (snapshots.length === 0) throw new Error("Empty snapshots");
  const seenDays = new Set();
  const quotaValues = [];
  const usedValues = [];
  for (const { ESTDay, quotaWad, usedWad } of snapshots) {
    [ESTDay, quotaWad, usedWad].forEach(checkUint256);
    if (seenDays.has(ESTDay)) throw new Error("Duplicate ESTDay");
    seenDays.add(ESTDay);
    const quotaNewWad = (quotaWad * newMultiplier) / oldMultiplier;
    const usedNewWad = (usedWad * newMultiplier + oldMultiplier - 1n) / oldMultiplier;
    checkUint256(quotaNewWad);
    checkUint256(usedNewWad);
    quotaValues.push({ ESTDay, amount: quotaNewWad });
    usedValues.push({ ESTDay, amount: usedNewWad });
  }
  return [
    { method: "setQuota", securityId, values: quotaValues, reasonCode },
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

- LP：[TSVLPManagerV1](../src/v1/periphery/TSVLPManagerV1.sol)、[校验与强退逻辑](../src/v1/libraries/TSVLPManagerLib.sol)、[继承的 PositionManager](../src/v1/vendor/permissionedPools/PositionManager.sol)。
- Swap：[TSVSwapRouterV1](../src/v1/periphery/TSVSwapRouterV1.sol)、[SwapRequest](../src/v1/types/TSVTypes.sol)、[Hook](../src/v1/core/TSVHookV1.sol)。
- Volume Ledger：[TSVVolumeLedgerV1](../src/v1/core/TSVVolumeLedgerV1.sol) 的 `setQuota`、`setUsedWad`、`currentESTDay` 与 `recordSwap`。
- Multiplier：[ERC8056DirectLegalShareAdapter](../src/v1/adapters/ERC8056DirectLegalShareAdapter.sol) 的 `currentMultiplier` / `toLegalShares`；证券交易暂停使用 [Registry](../src/v1/core/TSVRegistryV1.sol) 的 `applySecurityStatus`。
