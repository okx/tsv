# 🔐 Security Review — tsv

---

## Scope

|  |  |
| --- | --- |
| **Mode** | filename — src/script security; test scenario coverage only; external repositories reference only; 12 perspectives grouped into 3 audit workers per pass |
| **Files reviewed** | `src/v1/types/TSVReports.sol` · `src/v1/types/TSVTypes.sol` · `src/v1/core/TSVVolumeLedgerV1.sol`<br>`src/v1/core/TSVDataInboxV1.sol` · `src/v1/core/TSVHookV1.sol` · `src/v1/core/TSVRegistryV1.sol`<br>`src/v1/legacy/IssuerShareSettlementAdapter.sol` · `src/v1/legacy/IAssetSettlementAdapter.sol` · `src/v1/libraries/ReportValidationLib.sol`<br>`src/v1/libraries/TradeDayLib.sol` · `src/v1/libraries/TSVDirectSettlementLib.sol` · `src/v1/periphery/TSVSwapRouterV1.sol`<br>`src/v1/periphery/TSVLPManagerV1.sol` · `src/v1/adapters/ERC8056DirectLegalShareAdapter.sol` · `src/v1/adapters/BackedAutoFeeLegalShareAdapter.sol`<br>`src/v1/deployment/TSVERC1967Proxy.sol` · `src/v1/deployment/TSVHookProxyFactoryV1.sol` · `src/v1/governance/TSVGovernanceAnchor.sol`<br>`src/v1/governance/TSVGoverned.sol` · `src/v1/interfaces/IDirectLegalShareAdapter.sol` · `script/DeployGovernanceV1.s.sol`<br>`script/check-test-layout.py` · `script/VerifyDeploymentV1.s.sol` · `script/DeployCoreV1.s.sol`<br>`script/ScriptEnvironment.sol` · `test/README.md` · `test/unit/legacy/TSVIssuerAdapter.t.sol`<br>`test/unit/v1/adapters/BackedAdapter.t.sol` · `test/unit/v1/adapters/ERC8056DirectLegalShareAdapter.t.sol` · `test/unit/v1/deployment/HookFactory.t.sol`<br>`test/unit/v1/governance/RecoveryAcrossProxies.t.sol` · `test/unit/v1/governance/DirectUpgrade.t.sol` · `test/unit/v1/governance/BatchBoundaries.t.sol`<br>`test/unit/v1/governance/StatefulGovernance.t.sol` · `test/unit/v1/governance/Initialization.t.sol` · `test/unit/v1/governance/Freeze.t.sol`<br>`test/unit/v1/governance/Recovery.t.sol` · `test/unit/v1/governance/FreezeAcrossProxies.t.sol` · `test/unit/v1/governance/ProxyBinding.t.sol`<br>`test/unit/v1/governance/BusinessRoles.t.sol` · `test/unit/v1/governance/Events.t.sol` · `test/unit/v1/governance/BatchUpgrade.t.sol`<br>`test/unit/v1/governance/RecoveryLifecycle.t.sol` · `test/unit/v1/governance/DeploymentChecks.t.sol` · `test/unit/v1/registry/Admission.t.sol`<br>`test/unit/v1/registry/Permissions.t.sol` · `test/unit/v1/registry/Configuration.t.sol` · `test/unit/v1/registry/Pauses.t.sol`<br>`test/unit/v1/registry/Lifecycle.t.sol` · `test/unit/v1/registry/PauseBoundaries.t.sol` · `test/unit/v1/registry/AdapterChanges.t.sol`<br>`test/unit/v1/trading/VolumeAccounting.t.sol` · `test/unit/v1/trading/Initialization.t.sol` · `test/unit/v1/reports/SplitFactorBoundaries.t.sol`<br>`test/unit/v1/reports/AdtvBatch.t.sol` · `test/unit/v1/reports/CalendarBoundaries.t.sol` · `test/unit/v1/reports/Bindings.t.sol`<br>`test/unit/v1/reports/CapCorrections.t.sol` · `test/unit/v1/reports/SplitFactor.t.sol` · `test/unit/v1/reports/Ingress.t.sol`<br>`test/unit/v1/reports/Reports.t.sol` · `test/unit/v1/reports/StatefulOperations.t.sol` · `test/unit/v1/reports/TradeDay.t.sol`<br>`test/unit/v1/reports/PayloadValidation.t.sol` · `test/integration/xlayer/deployment.json` · `test/integration/xlayer/README.md`<br>`test/integration/xlayer/DexRouterFlow.t.sol` · `test/integration/governance/README.md` · `test/integration/local/operations/OperationsFlows.t.sol`<br>`test/integration/local/operations/PoolCreationBoundaries.t.sol` · `test/integration/local/operations/SplitFactorFlows.t.sol` · `test/integration/local/governance/SixProxyMigration.t.sol`<br>`test/integration/local/governance/GovernanceLifecycle.t.sol` · `test/integration/local/registry/Admission.t.sol` · `test/integration/local/registry/Pauses.t.sol`<br>`test/integration/local/trading/DexAdapter.t.sol` · `test/integration/local/trading/StatefulTradingLP.t.sol` · `test/integration/local/trading/IssuerFailures.t.sol`<br>`test/integration/local/trading/Settlement.t.sol` · `test/integration/local/trading/Boundaries.t.sol` · `test/integration/local/trading/Accounting.t.sol`<br>`test/integration/local/trading/DeltaGuards.t.sol` · `test/integration/local/trading/Trading.t.sol` · `test/integration/local/trading/Precision.t.sol`<br>`test/integration/local/trading/HookCallbacks.t.sol` · `test/integration/local/liquidity/Liquidity.t.sol` · `test/integration/local/liquidity/PositionId.t.sol`<br>`test/integration/local/liquidity/IssuerFailures.t.sol` · `test/integration/local/liquidity/ForceExit.t.sol` · `test/integration/local/liquidity/Settlement.t.sol`<br>`test/integration/local/liquidity/Boundaries.t.sol` · `test/integration/local/liquidity/DeltaGuards.t.sol` · `test/integration/local/liquidity/HookCallbacks.t.sol`<br>`test/helpers/v1/DexRouterTestAdapter.sol` · `test/helpers/v1/MockIssuerTokens.sol` · `test/helpers/v1/LocalMocks.sol`<br>`test/helpers/v1/FoundationMocks.sol` · `test/helpers/v1/GovernanceHandler.sol` · `test/helpers/v1/TradingLPHandler.sol`<br>`test/helpers/v1/OperationsFixture.sol` · `test/helpers/v1/SplitFactorFixture.sol` · `test/helpers/v1/OperationsMocks.sol`<br>`test/helpers/v1/DirectUpgradeMock.sol` · `test/helpers/v1/ProtocolFixture.sol` · `test/helpers/v1/UpgradeDeployment.sol`<br>`test/helpers/v1/GovernanceUpgradeMocks.sol` · `test/helpers/v1/GovernanceFixture.sol` · `test/helpers/v1/OperationsHandler.sol`<br>`test/helpers/v1/FoundationFixture.sol` · `test/helpers/v1/SixProxyFixture.sol` |
| **Confidence threshold (1-100)** | 75 |
| **Passes** | 3 (pass 1 ran 3/3 agents, pass 2 ran 3/3 agents, pass 3 ran 3/3 agents) |
| **Memory** | 13 records before this scan · 13 after · `44012cb` |

---

## Findings

_None — this scan raised no findings._

---

## Leads

_Vulnerability trails with concrete code smells where the full exploit path could not be completed in one analysis pass. These are not false positives — they are high-signal leads for manual review. Not scored._

_None._

---

## Known from earlier scans

_Recorded by earlier scans of this repo, not raised again by this one. Not re-checked — a record here may be fixed, or may still be live and missed. `.solidity-auditor/memory.tsv`._

| Scans | Kind | Location | Title |
|---|---|---|---|
| 1 | LEAD | `TSVDataInboxV1.accept` | A maximum report sequence can block later reports |
| 1 | FINDING | `TSVLPManagerV1.settle` | A zero output bypasses the LP minimum |
| 2 | LEAD | `TSVRegistryV1.registerToken` | Adapter proxy logic may change after registration |
| 1 | LEAD | `TSVRegistryV1.registerToken` | Token proxy behavior may change after approval |
| 1 | LEAD | `TSVRegistryV1.relistSecurity` | Relisting can reuse an old open market status |
| 2 | FINDING | `TSVRegistryV1.replaceLegalShareAdapter` | Adapter replacement can mix legal-share units within the daily cap |
| 1 | LEAD | `TSVSwapRouterV1._settle` | Settlement trusts approved token behavior |
| 1 | LEAD | `TSVSwapRouterV1.initialize-unlockcallback` | Callback trusts the configured PoolManager |
| 1 | LEAD | `TSVSwapRouterV1.swapexactinput-swapexactoutput` | Swap mode appears in both the selector and request |
| 1 | LEAD | `TSVSwapRouterV1.unlockcallback-swap` | Callback returns a delta only used by the outer event |
| 1 | LEAD | `TSVSwapRouterV1.unlockCallback` | The minimum signed input delta cannot be settled |
| 1 | LEAD | `TSVSwapRouterV1.validate-swap` | Router reads the trade day twice |
| 1 | LEAD | `TSVSwapRouterV1.validate` | Router repeats the PoolKey equality check |

---

> ⚠️ This review was performed by an AI assistant. AI analysis can never verify the complete absence of vulnerabilities and no guarantee of security is given. Team security reviews, bug bounty programs, and on-chain monitoring are strongly recommended. For a consultation regarding your projects' security, visit [https://www.pashov.com](https://www.pashov.com)
