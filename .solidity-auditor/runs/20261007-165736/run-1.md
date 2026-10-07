# Run 1 — solidity-auditor

<!--RUN pass=1 of=1 stamp=20261007-165736 sha=fd3bcfc agents=12/12-->

Pass 1 of 1 · 2026-10-07 · `fd3bcfc` · 12/12 agents returned. Findings describe the frozen pre-fix snapshot. The fix excerpts show the user-approved repair; two read-only follow-up reviews found no regression.

## Findings

<!--F key=tsvpermissionedsettlementlib|stockinventory|donation-blocks-swaps conf=90 kind=FINDING agents=1,3,4-->

[90] **A U transfer blocks every swap for that U**

`TSVPermissionedSettlementLib.stockInventory` · Confidence: 90

**Description**
An attacker sends one raw U to the Router or PoolManager, so every swap for that U fails.

**Fix**

```diff
--- a/src/v1/libraries/TSVPermissionedSettlementLib.sol
+++ b/src/v1/libraries/TSVPermissionedSettlementLib.sol
@@ -16,6 +16,8 @@
         uint256 collateral;
         uint256 supply;
         uint256 pmBalance;
+        uint256 pmUnderlyingBalance;
+        uint256 routerUnderlyingBalance;
     }

     function stockInventory(address w, address u, address pm, address participant)
@@ -26,10 +28,19 @@
         s.collateral = IERC20(u).balanceOf(w);
         s.supply = IERC20(w).totalSupply();
         s.pmBalance = IERC20(w).balanceOf(pm);
+        s.pmUnderlyingBalance = IERC20(u).balanceOf(pm);
+        s.routerUnderlyingBalance = IERC20(u).balanceOf(address(this));
         if (
-            s.collateral < s.supply || s.pmBalance != s.supply || IERC20(u).balanceOf(pm) != 0
-                || IERC20(u).balanceOf(address(this)) != 0 || IERC20(w).balanceOf(address(this)) != 0
+            s.collateral < s.supply || s.pmBalance != s.supply || IERC20(w).balanceOf(address(this)) != 0
                 || IERC20(w).balanceOf(participant) != 0
+        ) revert SettlementMismatch();
+    }
+
+    /// @dev Unsolicited U and balances owned by other PM pools cannot fund this operation.
+    function assertUnderlyingUnchanged(StockInventory memory before_, StockInventory memory after_) internal pure {
+        if (
+            before_.pmUnderlyingBalance != after_.pmUnderlyingBalance
+                || before_.routerUnderlyingBalance != after_.routerUnderlyingBalance
         ) revert SettlementMismatch();
     }

@@ -46,6 +57,7 @@
         transferExact(u, payer, w, amount);
         IPermissionsAdapter(w).wrapToPoolManager(amount);
         StockInventory memory after_ = stockInventory(w, u, pm, payer);
+        assertUnderlyingUnchanged(before_, after_);
         assertIncrease(before_.collateral, after_.collateral, amount);
         assertIncrease(before_.supply, after_.supply, amount);
         assertIncrease(before_.pmBalance, after_.pmBalance, amount);
@@ -62,6 +74,7 @@
         uint256 amount
     ) internal view {
         StockInventory memory after_ = stockInventory(w, u, pm, recipient);
+        assertUnderlyingUnchanged(before_, after_);
         assertDecrease(before_.collateral, after_.collateral, amount);
         assertDecrease(before_.supply, after_.supply, amount);
         assertDecrease(before_.pmBalance, after_.pmBalance, amount);
--- a/src/v1/periphery/TSVSwapRouterV1.sol
+++ b/src/v1/periphery/TSVSwapRouterV1.sol
@@ -151,9 +151,12 @@
         activePayloadHash = keccak256(payload);
         activePolicyHash = policy;
         activeRequestHash = _requestHash(request, p0, p1);
-        activeStockSurplus = _stockSurplus(p0, p1);
+        TSVPermissionedSettlementLib.StockInventory memory before_ = _stockInventory(p0, p1);
+        activeStockSurplus = before_.collateral - before_.supply;
         bytes memory result = poolManager.unlock(payload);
         if (!callbackConsumed) revert InvalidCallbackContext();
+        // Memory survives unlock and covers U changes on either the stock or quote transfer path.
+        TSVPermissionedSettlementLib.assertUnderlyingUnchanged(before_, _stockInventory(p0, p1));
         BalanceDelta delta;
         (actualIn, actualOut, delta) = abi.decode(result, (uint256, uint256, BalanceDelta));
         if (
@@ -198,7 +201,8 @@
         if (policy != activePolicyHash || _requestHash(request, p0, p1) != activeRequestHash) {
             revert InvalidCallbackContext();
         }
-        if (_stockSurplus(p0, p1) != activeStockSurplus) revert SettlementMismatch();
+        TSVPermissionedSettlementLib.StockInventory memory inventory = _stockInventory(p0, p1);
+        if (inventory.collateral - inventory.supply != activeStockSurplus) revert SettlementMismatch();
         return abi.encode(activeAmountIn, activeAmountOut, _delta(request.zeroForOne));
     }

@@ -287,12 +291,15 @@
         return PermissionedValidationLib.swapPlans(address(registry), address(poolManager), key, participant);
     }

-    function _stockSurplus(SettlementLegPlan memory p0, SettlementLegPlan memory p1) private view returns (uint256) {
+    function _stockInventory(SettlementLegPlan memory p0, SettlementLegPlan memory p1)
+        private
+        view
+        returns (TSVPermissionedSettlementLib.StockInventory memory)
+    {
         SettlementLegPlan memory stock = p0.kind == SettlementAssetKind.PERMISSIONED_STOCK ? p0 : p1;
-        TSVPermissionedSettlementLib.StockInventory memory inventory = TSVPermissionedSettlementLib.stockInventory(
+        return TSVPermissionedSettlementLib.stockInventory(
             stock.currency, stock.underlying, address(poolManager), activeSettlementParticipant
         );
-        return inventory.collateral - inventory.supply;
     }

     function _checkRequest(SwapRequest memory request) private view {
```

<!--/F-->

<!--F key=permissionedvalidationlib|validateinitialinventory|donation-blocks-admission conf=90 kind=FINDING agents=1,5,root-->

[90] **A U transfer blocks new W admission**

`PermissionedValidationLib.validateInitialInventory` · Confidence: 90

**Description**
An attacker sends one raw U to the PoolManager, so the Registry rejects every new W for that U.

**Fix**

```diff
--- a/src/v1/libraries/PermissionedValidationLib.sol
+++ b/src/v1/libraries/PermissionedValidationLib.sol
@@ -69,13 +69,13 @@
         return TSVSwapValidationLib.plans(ITSVPermissionedRegistry(registry), pm, key, participant);
     }

-    /// @notice First-admission inventory only; reapproval deliberately does not invoke this check.
+    /// @notice First-admission W inventory only; unrelated PM U balances do not affect admission.
+    /// @dev Reapproval deliberately does not invoke this check.
     function validateInitialInventory(address pm, address w, address u) external view {
         if (
             _staticWord(w, IERC20.totalSupply.selector, 0, 4) != 0
                 || _staticWord(w, IERC20.balanceOf.selector, uint160(pm), 36) != 0
                 || _staticWord(u, IERC20.balanceOf.selector, uint160(w), 36) == 0
-                || _staticWord(u, IERC20.balanceOf.selector, uint160(pm), 36) != 0
                 || IPoolManager(pm).protocolFeesAccrued(Currency.wrap(w)) != 0
         ) revert InvalidPermissionedConfig();
     }
```

<!--/F-->

## Leads

_None._
