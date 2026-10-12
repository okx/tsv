# Governance integration test boundary

This directory contains no executable `.t.sol` suite. The current source uses AccessControl and UUPS roles rooted at `TSVRegistryV1`; it does not include Governor, Guardian, RecoveryCouncil, Governance Anchor, batch upgrade freeze, or identity-recovery contracts.

Current role and upgrade tests are under `test/unit/v1/governance/` and `test/unit/v1/deployment/`. Production key custody, multi-signature procedures, role assignment, and target-chain upgrade rehearsal require separate deployment evidence.
