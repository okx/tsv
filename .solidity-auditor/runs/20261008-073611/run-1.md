# Run 1 — solidity-auditor

<!--RUN pass=1 of=3 stamp=20261008-073611 sha=444f87e agents=6/12-->

Pass 1 of 3 · 2026-10-08 · `444f87e` · 6/12 agents returned — access-control, economic-security, execution-trace, invariant, first-principles, asymmetry failed the tool content check.

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

**Fix (Option B — settle stocks in U)**:

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

<!--/F-->

## Leads

<!--F key=backedautofeelegalshareadapter|tolegalshares|unbounded-live-fee-accrual kind=LEAD agents=2-->

- **Issuer inactivity raises the cost of legal-share conversion** — `BackedAutoFeeLegalShareAdapter.toLegalShares` — Code smells: The adapter calls an issuer conversion method whose reference implementation repeats fee arithmetic for each elapsed period. — A trader faces higher swap gas after long issuer inactivity; we have not verified the admitted token's fee settings or a failed swap.

<!--/F-->
