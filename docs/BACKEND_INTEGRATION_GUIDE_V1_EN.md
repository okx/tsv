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

## III. Volume Ledger: Backend Daily Volume Quotas

```text
Backend account holding VOLUME_ORACLE_ROLE → TSVVolumeLedgerV1.setQuota / setUsedWad
```

This section is based on `TSVVolumeLedgerV1` at commit `74d6317bfd896f9836808554c67a1a4fe4b2ed37`. The quota-setting entry point is **`setQuota`**. The newly added **`setUsedWad`** corrects accumulated volume; see Section 6. `multicall` supports batches across securities; see Section 7. Call the Volume Ledger proxy directly to set total daily quotas for multiple EST days of one security. The function is nonpayable, returns no value, and requires `value = 0`.

### 1. Prerequisites and ABI

The calling account must hold **`VOLUME_ORACLE_ROLE` in the Registry referenced by the Ledger**, meaning `registry.hasRole(keccak256("VOLUME_ORACLE_ROLE"), caller) == true`. Use the target security's nonzero Registry ID for `securityId`. Quotas are shared by `securityId + ESTDay`: multiple pools for the same security consume the same quota, with no separate allocation per pool or user.

The examples in this section can be used independently:

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

| Parameter | ABI type | Requirements |
| --- | --- | --- |
| `securityId` | `bytes32` | The nonzero target security ID; not a poolId or token address |
| `values` | `tuple(uint256 ESTDay,uint256 amount)[]` | Days and quotas for one security; future days can be configured in advance; the backend should supply a nonempty array with no duplicate days |
| `values[i].ESTDay` | `uint256` | An integer epoch day calculated with the formula below; not a Unix timestamp or `YYYYMMDD` |
| `values[i].amount` | `uint256` | Total daily quota in **legal-share WAD (1 share = `10^18`)**; for example, 1,000 shares is `1000n * 10n ** 18n`, not a quote-token amount or underlying-token raw amount |
| `reasonCode` | `bytes32` | A backend-defined reason code shared by the batch; emitted unchanged, with no validation of its business meaning |

### 2. Resolving securityId from a Token and Reading Daily Quotas

The exact usage getter is **`usedWad`**, not `usdWad`. It returns consumed legal-share WAD, not a USD amount. All queries below are `view` calls requiring only a Provider; no Signer or `VOLUME_ORACLE_ROLE` is needed.

First obtain the corresponding Registry address through `ledger.registry()`, then query according to the stock token address available:

| Known address | Call sequence to obtain `securityId` |
| --- | --- |
| The user's underlying stock token, `underlyingToken` | `registry.getUnderlying(underlyingToken).securityId` |
| The pool's stock-side `PermissionsAdapter` address | First call `underlyingToken = registry.getCurrencyUnderlying(permissionsAdapterAddress)`, then `registry.getUnderlying(underlyingToken).securityId` |

**Do not generate `securityId` by hashing a token symbol or address, and do not supply a quote-token address.** An unknown PermissionsAdapter returns a zero underlying address; an unknown underlying returns a default record with `securityId == 0`. The backend should reject either case. `registered` indicates whether the underlying may be used to register new pools; a false value alone is not a reason to discard its stored security ID or historical volume.

| Query | Result |
| --- | --- |
| `ledger.currentESTDay()` | The EST day at the queried block |
| `ledger.Quota(securityId, day)` | Total daily quota; note the uppercase `Q` in the method name |
| `ledger.usedWad(securityId, day)` | Accumulated daily volume; both buys and sells consume quota without offsetting each other |

The example below returns the security ID, daily quota, usage, and remaining quota together. All calls use the same `blockTag` to keep reads consistent across day boundaries or intervening trades. Explicitly set `tokenKind` to either `"underlying"` or `"permissionsAdapter"`.

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
// Underlying stock token: readDailyVolume(provider, volumeLedgerAddress, underlyingToken, "underlying")
// Pool stock side: readDailyVolume(provider, volumeLedgerAddress, permissionsAdapterAddress, "permissionsAdapter")
```

The returned `quotaWad`, `usedWad`, and `remainingWad` are `bigint` values. The `*Shares` display fields are decimal strings; do not convert them to floating-point numbers for quota calculations. Pass the resolved `securityId` directly to a subsequent `setQuota` call. To query a specific date, replace the result of `currentESTDay()` with an `ESTDay` calculated using Section 3.

### 3. EST Day: Converting a UTC Unix Timestamp

**The input must be a Unix timestamp (UTC+0 basis, in seconds). Subtract 5 hours directly, divide by the number of seconds in a day, and round down. Do not convert the timestamp to local time or EST first and then subtract another 5 hours.**

```text
ESTDay = floor((unixTimestampSeconds - 5 × 3600) / 86400)
       = floor((unixTimestampSeconds - 18000) / 86400)

UTC timestamp interval for a given ESTDay:
[ESTDay × 86400 + 18000, (ESTDay + 1) × 86400 + 18000)
```

This matches `(block.timestamp - 5 hours) / 1 days` in the contract's `currentESTDay()`. **EST is fixed at UTC−5 throughout the year, with no daylight saving time. Do not use `America/New_York` timezone rules, which switch to EDT (UTC−4).** The day changes at **05:00:00 UTC**, which is 00:00:00 in fixed EST. UTC times from 00:00 through 04:59:59 still belong to the previous EST day.

| UTC time | Unix timestamp (seconds) | Fixed EST time (UTC−5) | `ESTDay` |
| --- | --- | --- | --- |
| `2026-10-12T04:59:59Z` | `1791781199` | `2026-10-11 23:59:59` | `20737` |
| `2026-10-12T05:00:00Z` | `1791781200` | `2026-10-12 00:00:00` | `20738` |
| `2026-10-13T04:59:59Z` | `1791867599` | `2026-10-12 23:59:59` | `20738` |
| `2026-10-13T05:00:00Z` | `1791867600` | `2026-10-13 00:00:00` | `20739` |

The backend can reuse the conversion below. JavaScript's `Date.now()` returns milliseconds, so divide by 1,000 first. `block.timestamp` is already in seconds; do not divide it by 1,000 again.

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

When setting the current day's quota, use the latest on-chain block's `timestamp` for conversion and cross-check it against the Ledger's `currentESTDay()`; treat server time as an auxiliary reference. `setQuota` writes to the supplied `ESTDay` and does not replace it with the day on which the transaction executes. Configure the next day's quota in advance to avoid an unconfigured quota when the day changes at 05:00 UTC.

### 4. Encoding and Submission

Keep the field names `ESTDay` and `amount` in `values`, and use `bigint` for both days and amounts.

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

// Example batch; the application supplies securityId, reasonCode, the proxy address, and oracleSigner.
const values = [
  { ESTDay: targetESTDay, amount: 1000n * 10n ** 18n },
  { ESTDay: targetESTDay + 1n, amount: 1200n * 10n ** 18n },
];
```

### 5. Overwrite Semantics and Result Verification

**`amount` is the total daily quota, not an increment or the remaining quota.** Each item directly overwrites `Quota[securityId][ESTDay]` without resetting `usedWad[securityId][ESTDay]`. For example, if 300 shares have been used out of a 1,000-share quota, changing the total to 1,200 leaves 900 shares available. The contract allows a quota to be reduced below usage, but subsequent positive-volume trades fail until sufficient quota is available or a new, configured day begins.

An unconfigured day has a quota of 0. Setting `amount = 0` also prevents subsequent positive-volume trades for that security and day; it does not mean unlimited volume or restoration of a default quota. Usage is counted independently for each day, and quotas do not roll over automatically. Trade validation uses the EST day derived from `block.timestamp` at execution.

The contract accepts an empty array, resulting in no writes or events. Duplicate days in a batch are overwritten sequentially, with the last item taking effect and an event emitted for each item. The backend should validate days and amounts before submission to avoid writing to the wrong day.

In the successful receipt, filter `QuotaSet` events emitted by the **Volume Ledger proxy address** and verify `securityId`, `ESTDay`, `amount`, and `reasonCode`. Read `Quota(securityId, ESTDay)` and `usedWad(securityId, ESTDay)` to calculate remaining quota as `max(Quota - usedWad, 0)`; subsequent trades or quota updates may change the values read.

Common `setQuota` failures: `Unauthorized()` means the caller lacks `VOLUME_ORACLE_ROLE`; `InvalidInput()` means `securityId` is zero. `QuotaExceeded(bytes32,uint256)` occurs during volume accounting for a subsequent swap. Its second argument is the same EST day integer defined above, and exceeding the quota reverts the entire swap.

### 6. Set Used WAD: Backend Corrections to Daily Usage

The new entry point is `setUsedWad(bytes32 securityId,DailyQuota[] values,bytes32 reasonCode)`. It shares the `DailyQuota` tuple, Registry's `VOLUME_ORACLE_ROLE`, and the EST day conversion rules with `setQuota`. It is nonpayable and returns no value. Before calling it, confirm that the target chain's Ledger implementation includes this new interface.

**Here, `values[i].amount` is the corrected accumulated total in legal-share WAD. It directly overwrites `usedWad[securityId][ESTDay]` without changing `Quota`.** Usage can be increased, decreased, or set to 0. Values above quota are also accepted; subsequent positive-volume trades fail until the quota or usage is adjusted to accommodate new volume. Subsequent trades accumulate on top of the corrected value.

For example, with a 1,000-share quota and 300 shares used, writing 200 shares through `setUsedWad` leaves 800 shares available. Writing 1,200 shares through `setQuota` changes only the quota, preserving existing usage. Keep these two operations distinct.

Each call targets one `securityId` and can correct multiple days. An empty array performs no writes; duplicate days use the last value, and each item emits `UsedWadSet`. A zero `securityId` reverts with `InvalidInput()`, and a caller without the role receives `Unauthorized()`. Past, current, and future days are written exactly as supplied; the contract imposes no date-range restriction.

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
// Correct target-day usage to 200 shares: values = [{ ESTDay: targetESTDay, amount: 200n * 10n ** 18n }]
```

Filter `UsedWadSet` events from the Ledger proxy in the successful receipt, verify the security, day, new usage, and reason code, then read back using Section 2. **This is an absolute overwrite with no previous-value or version check. A correction based on an earlier query may overwrite volume recorded between that query and execution of the correction transaction.** The backend must coordinate trades and corrections and record the reason; a successful simulation does not eliminate this concurrency issue.

### 7. Multicall: Batch Updates Across Securities

The Ledger inherits OpenZeppelin `Multicall`, exposing `multicall(bytes[] data) returns (bytes[] results)`. Call the Ledger proxy directly with `value = 0`. Subcalls execute in array order, preserve the original `msg.sender`, and each enforce their own permissions. **If any subcall fails, all state changes and events from the transaction are reverted.**

Each individual `setQuota` / `setUsedWad` call still targets one security. Use `multicall` to combine writes for different `securityId` values in one transaction, or to combine quota updates with usage corrections. Each `data` item must be complete function calldata, including the selector, rather than just ABI-encoded parameters. All subcalls target the current Ledger; external target addresses are not accepted.

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
// Each updates item: { method: "setQuota" or "setUsedWad", securityId, values, reasonCode }
// Items may use different securityId values; values has the same format as the individual calls above.
```

Each `results[i]` contains the ABI-encoded return value of subcall i; both write functions return no value, so their results are `0x`. Parse `QuotaSet` / `UsedWadSet` events from the Ledger proxy in the transaction receipt. When the same field for the same security and day is written repeatedly, the last write takes effect. This helper permits only the two backend write methods. The contract's `multicall` can combine other public entry points, but does not bypass role or Hook caller checks.

## Source References

- LP: [TSVLPManagerV1](../src/v1/periphery/TSVLPManagerV1.sol), [validation and unwind logic](../src/v1/libraries/TSVLPManagerLib.sol), and the [inherited PositionManager](../src/v1/vendor/permissionedPools/PositionManager.sol).
- Swap: [TSVSwapRouterV1](../src/v1/periphery/TSVSwapRouterV1.sol), [SwapRequest](../src/v1/types/TSVTypes.sol), and [Hook](../src/v1/core/TSVHookV1.sol).
- Volume Ledger: `setQuota`, `setUsedWad`, `currentESTDay`, and `recordSwap` in [TSVVolumeLedgerV1](../src/v1/core/TSVVolumeLedgerV1.sol).
