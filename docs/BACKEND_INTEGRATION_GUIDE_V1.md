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
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals))",
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
  "function getUnderlying(address underlyingToken) view returns (tuple(bytes32 securityId,address legalShareAdapter,uint8 rawDecimals))",
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

## 源码依据

- LP：[TSVLPManagerV1](../src/v1/periphery/TSVLPManagerV1.sol)、[校验与强退逻辑](../src/v1/libraries/TSVLPManagerLib.sol)、[继承的 PositionManager](../src/v1/vendor/permissionedPools/PositionManager.sol)。
- Swap：[TSVSwapRouterV1](../src/v1/periphery/TSVSwapRouterV1.sol)、[SwapRequest](../src/v1/types/TSVTypes.sol)、[Hook](../src/v1/core/TSVHookV1.sol)。
