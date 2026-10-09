# 🔐 Security Review — tsv

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename |
| **Files reviewed** | `src/v1/interfaces/IDirectLegalShareAdapter.sol` · `src/v1/interfaces/ITSVPermissionedRegistry.sol` · `src/v1/vendor/v4-router/interfaces/IMsgSender.sol`<br>`src/v1/vendor/v4-router/interfaces/IV4Router.sol` · `src/v1/vendor/v4-router/interfaces/IImmutableState.sol` · `src/v1/vendor/v4-router/base/BaseActionsRouter.sol`<br>`src/v1/vendor/v4-router/base/SafeCallback.sol` · `src/v1/vendor/v4-router/base/ImmutableState.sol` · `src/v1/vendor/v4-router/base/DeltaResolver.sol`<br>`src/v1/vendor/v4-router/V4Router.sol` · `src/v1/vendor/v4-router/hooks/permissionedPools/PermissionedV4Router.sol` · `src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol`<br>`src/v1/adapters/ERC8056DirectLegalShareAdapter.sol` · `src/v1/governance/TSVGovernanceAnchor.sol` · `src/v1/governance/TSVGoverned.sol`<br>`src/v1/periphery/TSVLPManagerV1.sol` · `src/v1/periphery/TSVSwapRouterV1.sol` · `src/v1/types/TSVReports.sol`<br>`src/v1/types/TSVTypes.sol` · `src/v1/vendor/v4-router/libraries/PathKey.sol` · `src/v1/vendor/v4-router/libraries/Actions.sol`<br>`src/v1/vendor/v4-router/libraries/ActionConstants.sol` · `src/v1/vendor/v4-router/libraries/BipsLibrary.sol` · `src/v1/vendor/v4-router/libraries/CalldataDecoder.sol`<br>`src/v1/libraries/TSVDirectSettlementLib.sol` · `src/v1/libraries/PermissionedValidationLib.sol` · `src/v1/libraries/TradeDayLib.sol`<br>`src/v1/libraries/ReportValidationLib.sol` · `src/v1/libraries/TSVPermissionedSettlementLib.sol` · `src/v1/core/TSVRegistryV1.sol`<br>`src/v1/core/TSVHookV1.sol` · `src/v1/core/TSVDataInboxV1.sol` · `src/v1/core/TSVVolumeLedgerV1.sol`<br>`src/v1/deployment/TSVERC1967Proxy.sol` · `src/v1/deployment/TSVHookProxyFactoryV1.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 (pass 1 ran 6/12 agents, pass 2 ran 3/12 (12 specialty tasks through reused threads) agents, pass 3 ran 3/12 (12 specialty tasks through reused threads) agents) |
| **Memory** | 13 records before this scan · 15 after · `444f87e` |

---

## Findings

[90] **1. Unfinished LP settlement rejects stock deposits and withdrawals**

`TSVLPManagerV1._settle` · Confidence: 90 · seen in 3/3 runs · NEW

**Description**
The LP manager rejects stock deposits and withdrawals because it checks W transfers instead of U; production Wrapped LP remains unfinished.

**Fix (Option A — block unfinished LP entries)**:

```diff
--- a/src/v1/periphery/TSVLPManagerV1.sol
+++ b/src/v1/periphery/TSVLPManagerV1.sol
@@
     ) private returns (BalanceDelta delta) {
         Position storage p = positions[positionId];
+        if (
+            (mode == LPOperationMode.OPEN || mode == LPOperationMode.INCREASE)
+                && (
+                    registry.getCurrency(Currency.unwrap(p.key.currency0)).underlying != address(0)
+                        || registry.getCurrency(Currency.unwrap(p.key.currency1)).underlying != address(0)
+                )
+        ) {
+            revert InvalidPool();
+        }
         activeContext = LPContext(poolId, positionId, p.tickLower, p.tickUpper, mode, p.salt, liquidityDelta);
```

**Fix (Option B — settle stocks in U and validate the LP wrapper)**:

```diff
--- a/src/v1/periphery/TSVLPManagerV1.sol
+++ b/src/v1/periphery/TSVLPManagerV1.sol
@@
 import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";
+import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
+import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";
@@
         if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
+        address underlying = registry.getCurrency(token).underlying;
+        if (underlying != address(0)) {
+            if (delta < 0) {
+                poolManager.sync(currency);
+                TSVPermissionedSettlementLib.payStock(token, underlying, owner, amount);
+                if (poolManager.settle() != amount) revert SettlementMismatch();
+            } else if (delta > 0) {
+                uint256 sourceBefore = IERC20(underlying).balanceOf(token);
+                uint256 ownerBefore = IERC20(underlying).balanceOf(owner);
+                poolManager.take(currency, owner, amount);
+                TSVPermissionedSettlementLib.assertDecrease(
+                    sourceBefore, IERC20(underlying).balanceOf(token), amount
+                );
+                TSVPermissionedSettlementLib.assertIncrease(
+                    ownerBefore, IERC20(underlying).balanceOf(owner), amount
+                );
+            }
+            return;
+        }
         if (delta < 0) {
--- a/src/v1/libraries/PermissionedValidationLib.sol
+++ b/src/v1/libraries/PermissionedValidationLib.sol
@@
                 ) || !_readBool(w, IPermissionsAdapter.allowedHooks.selector, r.hook())
+                || !_readBool(w, IPermissionsAdapter.allowedWrappers.selector, r.lpManager())
         ) revert PermissionedPolicyMismatch();
```

**Fix (Option C — block new stock position creation)**:

```diff
--- a/src/v1/periphery/TSVLPManagerV1.sol
+++ b/src/v1/periphery/TSVLPManagerV1.sol
@@
         bytes32 poolId = PoolId.unwrap(key.toId());
         _requireUserPool(poolId, key, bounds.deadline);
+        if (
+            registry.getCurrency(Currency.unwrap(key.currency0)).underlying != address(0)
+                || registry.getCurrency(Currency.unwrap(key.currency1)).underlying != address(0)
+        ) revert InvalidPool();
         if (liquidity == 0 || liquidity > uint128(type(int128).max)) revert InvalidPosition();
```

**Fix (Option D — settle stocks in U with LP wrapper authorization and U approvals)**:

```diff
--- a/src/v1/periphery/TSVLPManagerV1.sol
+++ b/src/v1/periphery/TSVLPManagerV1.sol
@@
 import {ERC721Upgradeable} from "@openzeppelin/contracts-upgradeable/token/ERC721/ERC721Upgradeable.sol";
+import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
@@
 import {TSVDirectSettlementLib} from "tsv-v1/libraries/TSVDirectSettlementLib.sol";
+import {TSVPermissionedSettlementLib} from "tsv-v1/libraries/TSVPermissionedSettlementLib.sol";
@@
         if (delta < 0 && amount > maxIn) revert SlippageExceeded();
         if ((delta >= 0 || mode == LPOperationMode.FORCE_EXIT) && amount < minOut) revert SlippageExceeded();
+        address underlying = registry.getCurrency(token).underlying;
+        if (underlying != address(0)) {
+            if (delta < 0) {
+                poolManager.sync(currency);
+                TSVPermissionedSettlementLib.payStock(token, underlying, owner, amount);
+                if (poolManager.settle() != amount) revert SettlementMismatch();
+            } else if (delta > 0) {
+                uint256 collateralBefore = IERC20(underlying).balanceOf(token);
+                uint256 ownerBefore = IERC20(underlying).balanceOf(owner);
+                poolManager.take(currency, owner, amount);
+                TSVPermissionedSettlementLib.assertDecrease(
+                    collateralBefore, IERC20(underlying).balanceOf(token), amount
+                );
+                TSVPermissionedSettlementLib.assertIncrease(
+                    ownerBefore, IERC20(underlying).balanceOf(owner), amount
+                );
+            }
+            return;
+        }
         if (delta < 0) {
             TSVDirectSettlementLib.settleFrom(poolManager, currency, token, owner, amount);
```

---

Findings List

| # | Confidence | Title |
|---|---|---|
| 1 | [90] | Unfinished LP settlement rejects stock deposits and withdrawals |

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

- **Issuer inactivity raises the cost of legal-share conversion** — `BackedAutoFeeLegalShareAdapter.toLegalShares` · seen in 3/3 runs · NEW — Code smells: The adapter calls an issuer view with one loop per elapsed period; neither this view nor U transfers updates the checkpoint. — Traders repeat past fee calculations on each swap when fees apply; production settings and a failed swap remain unverified.

---

## Known from earlier scans

_Recorded by earlier scans of this repo, not raised again by this one. Not re-checked — a record here may be fixed, or may still be live and missed. `.solidity-auditor/memory.tsv`._

| Scans | Kind | Location | Title |
|---|---|---|---|
| 1 | LEAD | `TSVDataInboxV1.accept` | A maximum report sequence can block later reports |
| 1 | FINDING | `TSVLPManagerV1.settle` | A zero output bypasses the LP minimum |
| 2 | LEAD | `TSVRegistryV1.registertoken` | Adapter proxy logic may change after registration |
| 1 | LEAD | `TSVRegistryV1.registertoken` | Token proxy behavior may change after approval |
| 1 | LEAD | `TSVRegistryV1.relistSecurity` | Relisting can reuse an old open market status |
| 2 | FINDING | `TSVRegistryV1.replacelegalshareadapter` | Adapter replacement can mix legal-share units within the daily cap |
| 1 | LEAD | `TSVSwapRouterV1._settle` | Settlement trusts approved token behavior |
| 1 | LEAD | `TSVSwapRouterV1.initialize-unlockcallback` | Callback trusts the configured PoolManager |
| 1 | LEAD | `TSVSwapRouterV1.swapexactinput-swapexactoutput` | Swap mode appears in both the selector and request |
| 1 | LEAD | `TSVSwapRouterV1.unlockcallback-swap` | Callback returns a delta only used by the outer event |
| 1 | LEAD | `TSVSwapRouterV1.unlockCallback` | The minimum signed input delta cannot be settled |
| 1 | LEAD | `TSVSwapRouterV1.validate-swap` | Router reads the trade day twice |
| 1 | LEAD | `TSVSwapRouterV1.validate` | Router repeats the PoolKey equality check |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
