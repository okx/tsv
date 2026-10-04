# Security Audit Report — TSV V1 Protocol and Fizz Tooling

| Item | Value |
|---|---|
| Project | TSV V1 Foundry/Solidity protocol and repository-local Fizz tools |
| Date | 2026-10-02 |
| Git branch / revision | `main` / `2aa95a7` |
| Tech stack | Solidity 0.8.26, Foundry; JavaScript and shell helper tooling |
| Scan mode | Deep |
| Auditor | Codex |
| Risk posture | MEDIUM |

## Executive Summary

- **Total findings:** 5 — Critical: 0, High: 0, Medium: 4, Low: 1.
- **Coverage:** 10 of 11 dimensions covered; D6 skipped because no first-party outbound HTTP client was found.
- **Most dangerous issue:** Fizz's `fizz_sync.js` builds a shell command from project and directory arguments before calling `execSync`. A crafted path can run commands as the local operator when handler regeneration is reached.
- **Protocol scope:** No confirmed vulnerability was found in the reviewed on-chain V1 contract flows. The confirmed findings affect repository-local developer tooling.
- **Top remediation actions:**
  1. Restrict the selector UI to loopback, remove wildcard CORS, authenticate state-changing requests, and cap request bodies.
  2. Escape every JSON value embedded into the selector's inline script.
  3. Validate generated contract names and enforce handler-directory containment; change the Fizz sync subprocess to an argv-based API.

## Scope and Method

The deep audit covered `src/v1/**`, `script/**`, root Foundry/dependency/deployment configuration, and `.agents/skills/fizz/scripts/**`. It traced contract authorization, ownership, callback decoding, business workflows, file operations, process execution, temporary HTTP behavior, dependency pins, and malicious-code indicators.

The repository was on `main` at `2aa95a7` before the audit. No source files were changed. No build, tests, fuzzers, installation commands, local servers, or HTTP requests were run. Ignored local `.env` values were not inspected.

## Attack Surface Map

| Surface | Method / entry point | Authentication or trust boundary | Relevant data flow |
|---|---|---|---|
| Fizz function selector | Temporary `GET /` | No application authentication; server binds without a host restriction | Contract and selection metadata → generated inline JavaScript |
| Fizz function selector | Temporary `POST /save` | No caller, Origin, or Host validation; wildcard CORS | HTTP JSON → configured selection file |
| Fizz handler generation | Local CLI, documented Fizz Step 7 | Operator launches the generator; selection JSON is trusted without validating `contract.name` | Selection name → output path → generated Solidity file |
| Fizz sync | Local CLI with `--apply-handlers` and detected contract drift | Operator launches the CLI; project and directory arguments are interpolated into a shell command | CLI arguments → `execSync` |
| TSV V1 protocol | 139 public/external Solidity declarations across Registry, Router, LP Manager, Hook, Ledger, Inbox, and governance components | EVM caller identity plus role, ownership, PoolManager, and active-operation checks | User trades/liquidity operations and authorized governance/report updates |

The selector chooses an ephemeral port and prints a loopback URL, but `server.listen(0)` omits a host and the source comment says it listens on all interfaces. Same-host reachability exists while the tool is running; LAN and browser reachability depend on network/browser policy and access to the printed ephemeral port. This is a temporary developer tool, not a production service.

## Findings

| ID | Severity | Category | Location | CWE | Vulnerable operation | Summary |
|---|---|---|---|---|---|---|
| S-01 | MEDIUM | D1 XSS | `.agents/skills/fizz/scripts/select_functions.js:117-125,247-249` | CWE-79 | `JSON.stringify` values inserted into inline `<script>` | A literal script-closing sequence in contract or selection metadata can execute JavaScript in the selector origin. |
| S-02 | MEDIUM | D1 Command Injection | `.agents/skills/fizz/scripts/fizz_sync.js:629-632` | CWE-78 | Interpolated command passed to `execSync` | Crafted project or directory paths can break out of double quotes and execute shell commands during handler regeneration. |
| S-03 | MEDIUM | D2 Authentication / D8 Configuration | `.agents/skills/fizz/scripts/select_functions.js:548-580,611-616` | CWE-306 | Unauthenticated `POST /save`; wildcard CORS; all-interface listener | A reachable client can read the selector UI and overwrite the configured selection file. |
| S-04 | MEDIUM | D5 Path Traversal | `.agents/skills/fizz/scripts/generate_handlers.js:347-362` | CWE-22 | Unvalidated `contract.name` used by `path.join` then `writeFileSync` | A forged selection name can write a generated Solidity file outside the handler directory when the operator later runs the generator. |
| S-05 | LOW | D10 Supply Chain | `.agents/skills/fizz/scripts/ensure_foundry.sh:116-121` | — | `forge install` without a tag or commit | The Fizz setup helper may add an unpinned `forge-std` checkout because it checks a path that this project does not use. |

### S-01 — Inline script terminator enables selector XSS

**Score:** Reachability +2 (attacker-controlled project metadata requires the user to run guided selection) + Impact +2 (JavaScript can alter selector state) + Complexity -2 (specific local workflow) + Defenses 0 = **2, MEDIUM**.

The selector reads `contracts.json` and optional selection metadata, serializes them with `JSON.stringify`, then interpolates the strings into an inline script. JSON serialization does not escape `<`; a literal `</script>` in a value can terminate the HTML script element. Script execution can then submit a forged selection to the selector's `POST /save` route. `--auto` exits before opening the UI, so the issue requires guided selection on attacker-controlled metadata.

**Fix:** Escape `<` as the literal `\\u003c` sequence in every value embedded in inline script, or move the data into a non-executable JSON element and parse its text content. Continue rendering user-controlled labels with `textContent`.

### S-02 — CLI paths reach a shell command

**Score:** Reachability +1 (local operator invokes the CLI) + Impact +3 (command execution) + Complexity -2 (crafted path plus `--apply-handlers` and drift conditions) + Defenses 0 = **2, MEDIUM**.

`fizz_sync.js` interpolates `projectRoot`, `suiteRelDir`, `metaRelDir`, and a derived selection path into a double-quoted command string, then invokes `execSync`. Double quotes do not prevent command substitution or quote termination. The path inputs come from CLI arguments. The vulnerable branch requires handler application and added or changed contracts.

**Fix:** Pass the script and values as separate arguments using `execFileSync(process.execPath, [genScript, projectRoot, '--suite-dir', opts.suiteRelDir, '--meta-dir', opts.metaRelDir, '--selection', scopedPath, '--force'], { stdio: 'inherit' })`.

### S-03 — Temporary selector has unauthenticated network routes

**Score:** Reachability +3 (no authentication on a reachable endpoint) + Impact +1 (limited to developer-tool selection state) + Complexity -2 (temporary local workflow and ephemeral port) + Defenses 0 = **2, MEDIUM**.

The selector accepts any JSON array on `POST /save` and writes it to the configured selection path. It does not authenticate callers or validate Origin/Host, and the server accepts wildcard CORS preflights. The request body is accumulated without a size limit. A client that can reach the temporary service can also read the UI through `GET /`. This affects later Fizz inputs; it does not directly modify deployed protocol state.

**Fix:** Bind the server explicitly to `127.0.0.1`, remove wildcard CORS for this same-origin UI, validate the request origin/host, add a per-run token or equivalent caller check for `POST /save`, and reject request bodies above a small fixed size.

### S-04 — Handler name can escape the output directory

**Score:** Reachability +3 (unauthenticated client can post while selector runs) + Impact +1 (constrained generated-source file write) + Complexity -2 (operator must continue to the documented generator step) + Defenses 0 = **2, MEDIUM**.

The selector persists caller-provided selection entries. Later, `generate_handlers.js` checks only that `contract.name` is truthy, joins that name to `handlersDir`, then writes the generated file. A name containing traversal segments can place the `Handler.sol` output outside `test/fizz/handlers`; existing non-stub files are skipped unless `--force` is used. The related `generate_suite.js` already uses a Solidity identifier allowlist, but the handler generator does not.

**Fix:** Apply the same Solidity identifier allowlist before path construction, then resolve the output and verify it remains beneath `handlersDir` using a path-separator-aware containment check.

### S-05 — Fizz setup may fetch an unpinned helper dependency

**Score:** Reachability +1 (developer invokes setup) + Impact +1 (tooling-only dependency drift) + Complexity -2 (specific setup path; no current production dependency change) + Defenses 0 = **0, LOW**.

The helper checks for `$PROJECT_ROOT/lib/forge-std` and runs `forge install foundry-rs/forge-std` without a release or commit if that path is missing. This project remaps `forge-std` to `lib/v4-core/lib/forge-std/src/`, so the helper may add a second checkout. No install was run and no dependency state changed during this audit.

**Fix:** Make the helper recognize the configured nested remapping or install an explicitly pinned tag/commit, and pin the Foundry/Fuzzer CLI versions used by the project.

## Coverage Matrix

| Dimension | Status | Findings / notes |
|---|---|---|
| D1 Injection | ✅ Covered | S-01 XSS; S-02 command injection. SQLi, SSTI, GraphQL, and XXE skipped because the corresponding surfaces were absent. |
| D2 Authentication | ✅ Covered | S-03 on the temporary selector; JWT skipped because there is no token/session system. |
| D3 Authorization | ✅ Covered | No confirmed IDOR or missing function-level authorization in active V1 flows. Legacy adapter is isolated from the active deployment graph. |
| D4 Deserialization | ✅ Covered | No unsafe object deserialization; five fixed-type ABI decode sites were traced and checked. |
| D5 File Operations | ✅ Covered | S-04 path traversal; upload/download and archive extraction surfaces absent. |
| D6 SSRF | ⏭️ Skipped | No first-party outbound HTTP client or URL-fetch flow. |
| D7 Cryptography | ✅ Covered | No hardcoded-secret or weak-crypto finding. Sensitive-data logging was skipped after no sensitive runtime values were found flowing to log sinks. |
| D8 Configuration | ✅ Covered | S-03 covers the selector's all-interface binding and wildcard CORS; no separate duplicate finding. No production deployment misconfiguration was verified. |
| D9 Business Logic | ✅ Covered | No confirmed protocol workflow, accounting, quota, pause, or governance logic vulnerability. Zero-delay governance is a documented operational assumption. |
| D10 Supply Chain | ✅ Covered | S-05 tooling pinning gap; dependency/advisory inventory below. |
| D11 Malicious Code | ✅ Covered | No malicious-code behavior found in reviewed Solidity, deployment, or Fizz tooling files. |

## Supply-Chain and Compiler Notes

- The project locks OpenZeppelin Contracts and Contracts Upgradeable at 5.5.0 with recorded Soldeer checksum and integrity values. The advisory review was a targeted upstream spot-check, not a complete software-composition scan; no checked advisory was confirmed as affecting the resolved 5.5.0 version. See the [OpenZeppelin advisory register](https://github.com/OpenZeppelin/openzeppelin-contracts/security/advisories).
- The checked-in Uniswap v4-core implementation is part of the project tree but its upstream tag/commit is not recorded. Its upstream repository currently lists no published security advisories; this does not replace an implementation review. See [Uniswap v4-core security](https://github.com/Uniswap/v4-core/security).
- Foundry pins Solidity 0.8.26 with `via_ir = true`. Solidity's upstream known-bugs list records SOL-2026-6, affecting 0.8.26 through 0.8.36 under via-IR for custom errors passed to `require` with named arguments in an order different from the declaration; it is fixed in 0.8.37 and rated very low. No first-party `require(...)` call was found in `src/` or `script/`, so no authored-code trigger was identified. Third-party implementation code was not reviewed for this compiler pattern. See [Solidity's known-bugs list](https://docs.soliditylang.org/en/latest/bugs.html).
- Four root Git submodules are pinned to commits; their trees are outside first-party implementation review. Two OpenZeppelin dependencies are locked. Fuzz-tool versions for Forge, Medusa, and Echidna are not constrained consistently; Medusa and Echidna were unavailable in the local environment.

## Remediation Plan

1. **First:** Fix S-03's selector exposure and add request-size limits. This constrains both direct selector tampering and the input route used by S-04.
2. **Next:** Fix S-01's script-safe serialization and S-04's contract-name validation/path containment.
3. **Then:** Replace S-02's shell command string with argv-based process execution.
4. **Hardening:** Pin Fizz dependency and CLI versions or update setup detection to follow the project's configured Foundry remapping.

No remediation changes have been applied. Manual verification after fixes should confirm that the selector is reachable only over loopback, untrusted metadata cannot execute in the page, forged names cannot write outside the handler directory, and shell metacharacters remain literal arguments.


