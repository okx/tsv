# Pass 1 validation record

Runtime adaptation: three workers, four specialty lenses each. No structured raw FINDING or LEAD remained. Completeness: 0 unique (Contract, function) in raw, 0 covered in final.

| Candidate | Gate 1: execution | Gate 2: state | Gate 3: actor | Gate 4: harm | Disposition |
| --- | --- | --- | --- | --- | --- |
| LP zero-output minimum bypass | BLOCKS: `_settle` rejects zero amount below positive minimum (`delta >= 0`). Liquidity test covers it. | Not evaluated | Not evaluated | Not evaluated | Prior defect fixed in this snapshot. |
| Router minimum signed input delta | BLOCKS: `unlockCallback` rejects `int128.min` before settlement. | Not evaluated | Not evaluated | Not evaluated | Guarded. |
| Intraday legal-unit mix via replacement | ALLOWS unit-changing policy if operators select it. | Requires privileged replacement and recovery. | Requires operations contrary to explicit consistent-unit/new-day policy; no independent user amplifier established. | Not evaluated | Not issued as finding or lead; assess unit operations and multi-Currency coverage separately. |
| Mutable approved token/adapter implementation | Potential dependency behavior change. | Depends on admitted external upgrade authority and policy violation. | No independent unprivileged upgrade or amplifier demonstrated. | Not evaluated | Trust/acceptance scope, not retained vulnerability. |
| Relist stale open state | Existing market pause/sequence intentionally survives relisting; tests verify it. | Not evaluated | Not evaluated | Not evaluated | No policy violation or attacker path established. |
| Public CREATE2 duplicate predeployment | ALLOWS same intended address; initData is hashed. | Public predeployment is reachable. | Unprivileged duplicate deployer changes no authority/links. | No material asset harm established; deployment resilience only. | Not retained as security finding/lead. |
| Callback substitution and cross-contract reentry | Fixed PoolManager forwards original unlock data; operation/V4 locks interrupt unauthorized paths. | Not evaluated | Not evaluated | Not evaluated | No supported path established. |

This record does not certify the absence of vulnerabilities. Historic ledger rows remain archival; unraised rows are not carried forward as current confirmed findings.
