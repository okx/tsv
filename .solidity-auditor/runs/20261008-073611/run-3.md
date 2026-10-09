# Run 3 — solidity-auditor

<!--RUN pass=3 of=3 stamp=20261008-073611 sha=444f87e agents=3/12-->

Pass 3 of 3 · 2026-10-08 · `444f87e` · 3/12 agents returned.

The runtime refused new agent threads. All twelve specialty tasks completed through three reused threads; this pass has less independent coverage than twelve separate agents. No production source was edited.

## Findings

<!--F key=tsvlpmanagerv1|-settle|permissioned-lp-settlement-mismatch conf=90 kind=FINDING agents=3-->

[90] **Unfinished LP settlement rejects stock deposits and withdrawals**

`TSVLPManagerV1._settle` · Confidence: 90

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

<!--/F-->

## Leads

<!--F key=backedautofeelegalshareadapter|tolegalshares|unbounded-live-fee-accrual kind=LEAD agents=3-->

- **Issuer inactivity raises the cost of legal-share conversion** — `BackedAutoFeeLegalShareAdapter.toLegalShares` — Code smells: The adapter calls an issuer view with one loop per elapsed period; neither this view nor U transfers updates the checkpoint. — Traders repeat past fee calculations on each swap when fees apply; production settings and a failed swap remain unverified.

<!--/F-->
