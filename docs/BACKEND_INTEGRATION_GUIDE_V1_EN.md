# TSV V1 Backend Integration Guide

This guide follows the structure of Uniswap's [Managing Liquidity](https://developers.uniswap.org/docs/protocols/v4/guides/managing-liquidity/overview) guide: prerequisites, ABI, encoding, and submission. **LP operations and swaps use different entry points and are described separately below.**

> Based on repository commit `70b5c2d0bff47084a0776b3412c8d86dff342be8`. Use proxy addresses for all business operations, and ensure that the ABI matches the version deployed on the target chain. Examples use ethers.js v6. The encoding functions generate calldata, and the submission examples reuse a Signer supplied by the integrating application. The integrator is responsible for obtaining quotes and signed authorizations.

This document uses three distinct terms: the **PermissionsAdapter token** is the stock-side asset held in the pool; the **underlying stock token** is the stock asset that users actually hold; and the **quote token** is the other asset in the pool. PermissionsAdapter tokens and underlying stock tokens have a 1:1 relationship in their smallest units. All examples below apply to ERC-20 pools, with transaction `value = 0`.

## I. LP Manager: Managing Liquidity

```text
User / operator with NFT approval → TSVLPManagerV1.modifyLiquidities
Administrator → TSVLPManagerV1.unwindPosition or unwindPositionByOkx
```

Ordinary liquidity additions and removals are executed by the direct caller of LP Manager. When additional funds are required, that caller is also the payer. A backend submitting a transaction on a user's behalf does not automatically make the user the executor. Mint, Increase, Decrease, Collect, and Burn all use `modifyLiquidities`; forced exits use separate entry points.

### 1. Entry-Point and Query ABIs

The following human-readable ABI can be passed directly to an ethers `Interface`. `PoolKey` is expanded into its complete tuple, and the ABI type of `PositionInfo` is `uint256`.

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

| Entry point | Purpose and caller requirements | Return value |
| --- | --- | --- |
| `modifyLiquidities(bytes,uint256)` | Ordinary LP operations by a user or an approved operator; payable | None |
| `initializePool(PoolKey,uint160)` | Pool creation by a caller with `POOL_CREATOR_ROLE`; payable | `int24 tick` |
| `unwindPosition(uint256,uint128,uint128,bytes)` | Forced exit initiated by a PermissionsAdapter contract owner; nonpayable | None |
| `unwindPositionByOkx(uint256,uint128,uint128,bytes)` | Forced exit initiated by a caller with `FORCE_EXIT_ADMIN_ROLE`; nonpayable | None |
| `approve(address,uint256)` / `setApprovalForAll(address,bool)` | NFT approval; does not authorize token payments | None |
| `multicall(bytes[])` | Executes multiple LP Manager calls from the same caller; any failure reverts the entire transaction | `bytes[]` containing the return data of each subcall |
| `modifyLiquiditiesWithoutUnlock(bytes,bytes[])` | Only for composed calls within an existing PoolManager unlock context; neither performs an unlock nor checks a deadline | None |

Use `modifyLiquidities` for ordinary transactions; do not call `unlockCallback` directly. Proxy initialization, upgrades, subscriptions, and Permit2 forwarding are outside the scope of this guide. Permit2 approval cannot replace the TokenApprove authorization described below.

### 2. Prerequisites and Approvals

Ordinary LP operations, including fee collection and ordinary position closure, perform the following checks:

| Check | Call or condition |
| --- | --- |
| Global and pool admission | `registry.isPaused() == false` and `registry.isLPAllowed(poolId) == true` |
| SBT | The executor, NFT owner, and explicitly specified recipient must each pass `registry.isSbtAllowed(0x0002, account)`; simply holding an arbitrary SBT is insufficient |
| NFT approval | When modifying an existing position, the executor must be `ownerOf(tokenId)`, `getApproved(tokenId)`, or an operator approved by the owner |
| Issuer admission for Mint / Increase | The PermissionsAdapter contract is verified by the Factory, allows the pool's Hook, and returns true for `permissionsAdapter.isAllowed(owner, 0x0002)` |
| Providing additional stock assets | The executor passes `permissionsAdapter.isAllowed(executor, 0x0002)`, and the PermissionsAdapter contract allows LP Manager as a wrapper |
| Payment approval | `approveProxy = lpManager.TOKEN_APPROVE_PROXY()`; `spender = approveProxy.tokenApprove()`; the payer approves that spender for the underlying stock token / quote token actually used for payment |
| Proxy configuration and balances | `approveProxy.isAllowedProxy(lpManagerAddress) == true`; the payer has sufficient balance and allowance |
| Asset delivery | The recipient passes the underlying stock token's actual transfer compliance checks |

ABIs for these checks:

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

Registry uses the argument order `isSbtAllowed(permission, account)`, while the PermissionsAdapter contract uses `isAllowed(account, permission)`. The ABI type of permission is **`bytes2`**. `0x0002` represents ordinary LP permission; `0x0004` is used only to query forced-exit eligibility on the PermissionsAdapter contract.

### 3. Common Parameters

| Parameter | Type and requirements |
| --- | --- |
| `poolKey` | `(address currency0,address currency1,uint24 fee,int24 tickSpacing,address hooks)`; use a registered key with `currency0 < currency1`; use the PermissionsAdapter address for the stock side |
| `tokenId` | `uint256`, the position NFT ID; query its pool and liquidity through `getPoolAndPositionInfo` and `getPositionLiquidity`, and first confirm that the NFT exists |
| `liquidity` | `uint256`, measured in liquidity units rather than token amounts; calculate it from the pool price, tick range, and asset budget |
| `amount0Max/1Max` | `uint128`, maximum principal payments, measured in the smallest units of currency0/1 |
| `amount0Min/1Min` | `uint128`, minimum principal amounts received on removal; excludes fees collected in addition to principal |
| `recipient` | `address`; receives the NFT during Mint and the actual assets during TAKE_PAIR; using an explicit recipient address is recommended |
| `hookData` | `bytes`; either `0x` or the ABI encoding of a single `uint256 expectedMultiplier`; must be exactly 32 bytes when nonempty |
| `deadline` | `uint256`, Unix time in seconds; ordinary LP calls fail when `block.timestamp > deadline` |

For nonempty `hookData`, read the multiplier in two steps: obtain the `legalShareAdapter` address from `registry.getUnderlying(underlyingToken)`, then call `currentMultiplier(underlyingToken)` on that contract. The value must be nonzero and must match at execution time. Encode it as `abiCoder.encode(["uint256"], [expectedMultiplier])`. `poolId` is the keccak256 hash of the standard ABI encoding of the complete PoolKey; calculate it with `keccak256(abiCoder.encode([lpPoolKeyType], [poolKey]))`.

### 4. Encoding and Submitting Ordinary LP Operations

Mint, Increase, Decrease, Collect, and Burn all use the common wrapper below. Each byte in `actions` corresponds to one `params[i]`. Each parameter set uses standard ABI encoding; only the action opcodes are concatenated directly as bytes.

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

| Action | Opcode | Type order within a single `params[i]` |
| --- | --- | --- |
| `MINT_POSITION` | `0x02` | `PoolKey,int24,int24,uint256,uint128,uint128,address,bytes` |
| `INCREASE_LIQUIDITY` | `0x00` | `uint256,uint256,uint128,uint128,bytes` |
| `DECREASE_LIQUIDITY` | `0x01` | `uint256,uint256,uint128,uint128,bytes` |
| `BURN_POSITION` | `0x03` | `uint256,uint128,uint128,bytes` |
| `SETTLE_PAIR` | `0x0d` | `address,address` |
| `TAKE_PAIR` | `0x11` | `address,address,address` |
| `CLOSE_CURRENCY` | `0x12` | `address` |

The functions below reuse this section's `abiCoder`, `lpInterface`, `lpPoolKeyType`, and `buildLpTransaction`. Use `bigint` for all large integers. Prices and amounts must come from actual queries and quotes; do not calculate them directly using JavaScript floating-point numbers.

#### Mint: Create a Position

`tickLower < tickUpper`; both ticks must align with `poolKey.tickSpacing` and fall within the valid tick range. `recipient` receives the nontransferable position NFT.

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

The action sequence is `MINT_POSITION → SETTLE_PAIR`. In a successful receipt, filter for `Transfer` events emitted by the LP Manager address. The event with a zero `from` address identifies the new `tokenId`; do not infer the final ID by reading `nextTokenId` before submission.

#### Increase: Add Liquidity

The action sequence is `INCREASE_LIQUIDITY → CLOSE_CURRENCY → CLOSE_CURRENCY`. It handles both additional payments and any surplus arising from accrued fees. Surplus funds are returned to the executor.

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

#### Decrease: Remove Liquidity

The action sequence is `DECREASE_LIQUIDITY → TAKE_PAIR`. `liquidity` must not exceed the position's current liquidity. Principal and fees are sent to `recipient`, and the NFT remains intact.

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

#### Collect: Collect Fees

There is no separate collect entry point. Reuse Decrease with both the liquidity change and minimum principal amounts set to zero. Ordinary LP requirements for SBT eligibility, NFT approval, and pool admission still apply.

```javascript
function buildCollectTransaction(input) {
  return buildDecreaseTransaction({
    ...input, liquidity: 0n, amount0Min: 0n, amount1Min: 0n,
  });
}
```

#### Burn: Close a Position Normally

The action sequence is `BURN_POSITION → TAKE_PAIR`. It removes all liquidity, settles fees, and burns the NFT. All ordinary LP prerequisites still apply.

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

### 5. Initialize Pool: Create a Pool

The entry point is `initializePool(PoolKey key,uint160 sqrtPriceX96) payable returns (int24 tick)`.

The caller must hold `POOL_CREATOR_ROLE`, and Registry must not be globally paused. The PermissionsAdapter contract, quote token, and security configuration must already be admitted. At least one side must be a Factory-verified PermissionsAdapter contract with a nonzero owner. Failure of either pool registration or initialization reverts the entire transaction.

`sqrtPriceX96 = floor(sqrt(currency1Raw / currency0Raw) × 2^96)`, calculated using the smallest units of both assets and within the v4 price range. Account for token decimals in the calculation.

```javascript
function buildInitializePoolTransaction(lpManagerAddress, poolKey, sqrtPriceX96) {
  return {
    to: lpManagerAddress,
    data: lpInterface.encodeFunctionData("initializePool", [poolKey, sqrtPriceX96]),
    value: 0n,
  };
}
```

### 6. Unwind: Administrator-Initiated Forced Closure

Both dedicated entry points call the LP Manager proxy directly. They return no value, do not accept native currency, and do not require an action sequence.

| Prerequisite / behavior | `unwindPosition` | `unwindPositionByOkx` |
| --- | --- | --- |
| Caller | The `owner()` of either verified PermissionsAdapter contract in the pool | A holder of Registry's `FORCE_EXIT_ADMIN_ROLE` |
| Position eligibility | The NFT exists, and at least one verified PermissionsAdapter contract in the pool returns true for `isAllowed(lp, 0x0004)` | Same as `unwindPosition` |
| SBT / NFT approval | Neither the LP nor the administrator needs to pass ordinary LP SBT checks, and prior NFT approval from the LP is not required | Same as `unwindPosition` |
| Pause and pool admission | No global pause; in this version, forced exits bypass ordinary `isLPAllowed` checks, while Hook execution still checks pool registration and Hook identity | Same as `unwindPosition` |
| Recipient | For each asset, delivery to the LP is attempted first. If that fails, delivery to the corresponding PermissionsAdapter contract owner is attempted only for permissioned assets. If delivery still fails, the entire transaction reverts | Both assets are sent directly to the LP; failure to deliver either asset reverts the entire transaction |
| Result | Burns the NFT; does not deliver an unredeemable claim to the user as a fallback | Burns the NFT |

Both entry points take `(uint256 tokenId,uint128 amount0Min,uint128 amount1Min,bytes hookData)`. There is no `recipient` or `deadline` parameter. `hookData` follows the same rules as ordinary LP operations. **Revocation of an SBT does not automatically make a position eligible for unwind**; query the PermissionsAdapter contract's `UNWIND_ALLOWED = 0x0004` permission explicitly.

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

For issuer-initiated unwinds, the `CurrencyUnwound` event identifies the final recipient of each asset with a nonzero amount. OKX-initiated unwinds do not use this delivery-event path. In this version, `withdrawClaim(address,uint256,address)` is disabled, and ordinary LP entry points cannot submit `MINT_6909` or `UNWIND_WITH_FALLBACK`.

### 7. Submitting LP Transactions

The following example reuses the ethers `Signer` supplied by the application's wallet. It must represent the executor or administrator required for the operation:

```javascript
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

A successful simulation does not guarantee that state will remain unchanged before execution on-chain. Common failures include: `RegistryPaused()` for a global pause; `PoolNotAllowed()` for failed ordinary LP admission; `Unauthorized()`, which requires checking SBT eligibility, issuer permissions, and NFT approval; `LpUnWindable()` for failure to meet forced-exit eligibility; and `UnAcceptableScenario()` when an issuer-initiated unwind cannot deliver the assets.

## II. Swap Router: Single-Pool Exact-Input Swaps

```text
User → external trading entry point / adapter contract → TSVSwapRouterV1.swapExactInputFromAdapterDirect
```

**The direct caller of Swap Router must be an authorized adapter contract, not a user EOA.** `participant` is the user whose identity is checked and who actually pays; `recipient` receives the output assets. This section defines only the interface through which an adapter calls TSV Router. The calldata that a user sends to the external trading entry point depends on the integrated adapter's ABI and cannot be derived from the two target contracts covered in this guide alone.

Here, an adapter is an external trading integration contract. Its role differs from that of the pool's `PermissionsAdapter` contract.

### 1. Swap Entry-Point and Query ABIs

This section can be used independently and does not depend on LP actions or encoders.

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

The main entry point is nonpayable and returns `(uint256 actualIn,uint256 actualOut)`. It constructs the Swap, Settle, and Take operations internally; the backend does not supply LP `actions` or `unlockData`. Only holders of Registry's `DEFAULT_ADMIN_ROLE` can use `setAdapterAllowed` to configure authorized callers. Ordinary users cannot authorize themselves.

### 2. Swap Prerequisites and Approvals

| Check | Call or condition |
| --- | --- |
| Caller | `router.isAdapterAllowed(adapterAddress) == true`, and that contract actually initiates the call |
| Global and pool admission | `registry.isPaused() == false`; `registry.isTradable(poolId) == true`; the key identifies a registered pool bound to the correct Hook |
| SBT | `registry.isSbtAllowed(0x0001, participant) == true` |
| Issuer admission | The PermissionsAdapter contract is verified and allows the Hook; `swappingEnabled() == true`; `isAllowed(participant, 0x0001) == true` |
| Wrapping stock input | If the input is the underlying stock token, the PermissionsAdapter contract must allow the **Swap Router proxy address** as a wrapper |
| Balance and approval | The participant holds sufficient input assets and approves the **Swap Router proxy address** for the input token; this entry point does not use LP's TokenApprove |
| Recipient | Both participant and recipient are nonzero; recipient meets the receipt requirements of the actual output asset |
| Quote state | The deadline has not expired; the multiplier snapshot matches; market reports and trading-volume quotas permit the trade |

Router explicitly checks the participant's SBT. It does not treat the recipient as the participant and repeat the same SBT check. When delivering the underlying stock token, that token's transfer compliance checks may still reject the recipient.

Query and token-approval ABIs:

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

Call `router.settlementCurrency(currency)` for a pool currency to obtain the actual settlement token address. For the stock side, it returns the underlying stock token address; for the quote side, it returns the quote token itself. The user should call `approve(routerAddress, amountIn)` on this actual input token.

### 3. SwapRequest Parameters

| Field | ABI type | Requirements |
| --- | --- | --- |
| `key` | `tuple(address,address,uint24,int24,address)` | Ordered as currency0, currency1, fee, tickSpacing, hooks; use the PermissionsAdapter address for the stock side |
| `zeroForOne` | `bool` | true: currency0 → currency1; false: the reverse direction |
| `amountSpecified` | `uint128` | Exact input amount in the token's smallest units, with `0 < amountSpecified <= 2^127 - 1` |
| `limitAmount` | `uint128` | Minimum output amount in the token's smallest units; must be greater than 0 |
| `deadline` | `uint64` | Unix time in seconds, not milliseconds |
| `expectedMultiplier` | `uint256` | The nonzero multiplier read when quoting; must match at execution time |
| `participant` | `address`, the second argument outside request | The original user, who is also the actual payer |
| `recipient` | `address`, the third argument outside request | The output asset recipient |

Read the multiplier in this order: obtain `legalShareAdapter` from `registry.getUnderlying(underlyingToken)`, then call `currentMultiplier(underlyingToken)` on that contract. If the price or multiplier changes, obtain a new quote rather than merely replacing the snapshot value.

### 4. Encoding the Adapter → Router Call

`request` must contain the first six fields in the table above, with their original field names. Use `bigint` for amounts, deadline, and expectedMultiplier.

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

The resulting call is intended for internal execution by an authorized adapter. **Do not pass it directly to a user wallet's `sendTransaction`.** The adapter must bind the participant, input amount, and recipient under its own authorization rules. Constructing the complete user transaction also requires the external entry point's ABI.

### 5. Simulation and Result Interpretation

The example below simulates the internal call. `adapterAddress` must be an allowed adapter. This does not replace simulation of the complete external transaction.

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

On success, `actualIn == amountSpecified` and `actualOut >= limitAmount`. If the full input amount is not consumed, the entire transaction reverts. A transaction receipt does not itself contain Solidity return values. For accounting, parse the actual trade / asset-transfer logs; do not treat simulated output as the executed trade amount.

Common failures include: `AdapterNotAllowed()` when the direct caller is unauthorized; `Expired()` when the deadline has passed; `PoolNotTradable()` when the pool is not tradable; `MultiplierChanged()` when the quoted multiplier has changed; and `SlippageExceeded()` when this router detects an incomplete input fill or no valid output. v4 may also return its own minimum-output error.

## Source References

- LP: [TSVLPManagerV1](../src/v1/periphery/TSVLPManagerV1.sol), [validation and unwind logic](../src/v1/libraries/TSVLPManagerLib.sol), and the [inherited PositionManager](../src/v1/vendor/permissionedPools/PositionManager.sol).
- Swap: [TSVSwapRouterV1](../src/v1/periphery/TSVSwapRouterV1.sol), [SwapRequest](../src/v1/types/TSVTypes.sol), and [Hook](../src/v1/core/TSVHookV1.sol).
