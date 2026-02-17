# ISSUE-0310: Full CLPR Regression and SOLO Verification Gate

Status: Done (2026-02-17)

## Objective

Establish the final verification gate for this implementation wave so we do not declare completion without repeatable proof across unit tests, Hapi subprocess tests, and two-ledger SOLO end-to-end runs.

## Scope

### A. Regression command matrix

Run and record outcomes for all impacted surfaces.

Hedera-smart-contracts:
- `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat`
- `forge test --match-path test/foundry/ClprMiddleware.t.sol`

Consensus-node:
- CLPR unit/system-contract tests touched by issues `0301..0309`
- `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMessagesSuite'`

SOLO:
- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`
- repeat full clean run three times with evidence capture

### B. Evidence and reproducibility

For each command/run, capture:
- command line used
- start/end timestamps
- pass/fail result
- artifact/log output directory
- if failed, first failing assertion and suspected root cause

### C. Issue closure discipline

Issue closes only after:
- `ISSUE-0307` and `ISSUE-0308` are complete
- 3/3 clean SOLO runs pass with no manual interventions between scenario phases
- documentation pointers are updated for reuse by future AI agents

## Impacted Files (Expected)

- issue logs in `docs/clpr/native-messaging-solo-integration-plan/issues/`
- run reports in `docs/clpr/` and/or `artifacts/`
- any final script/readme updates required to reproduce the matrix

## Acceptance Criteria

1. All new and modified tests pass in both repositories.
2. `ClprMessagesSuite` passes with middleware/system-contract/native-queue intent preserved.
3. Three independent clean SOLO runs complete successfully.
4. Evidence paths are documented and reproducible by another developer.

## Out of Scope

- New feature additions beyond approved issue set.
- Production-hardening tasks explicitly deferred in prior approvals.

## Implementation Log

- Regression commands completed (2026-02-17):
  - Hedera-smart-contracts:
    - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat`
      - PASS (`6 passing`)
    - `forge test --match-path test/foundry/ClprMiddleware.t.sol`
      - PASS (`6 passed; 0 failed`)
  - Consensus-node:
    - `./gradlew :app-service-contract-impl:test --tests '*clpr*' --no-daemon --console=plain`
      - PASS (`SUCCESS: Executed 38 tests`)
    - `./gradlew :hiero-clpr-interledger-service-impl:test --no-daemon --console=plain`
      - PASS (`SUCCESS: Executed 133 tests`)
    - `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMessagesSuite' --no-daemon --console=plain`
      - PASS (`1 passing`, `BUILD SUCCESSFUL`)
- Evidence logs captured:
  - `/tmp/hsc_clpr_hardhat.log`
  - `/tmp/hsc_clpr_foundry.log`
  - `/tmp/clpr_contract_impl_tests.log`
  - `/tmp/clpr_interledger_impl_tests.log`
  - `/tmp/clpr_suite_run.log`
- Remaining gate work:
  - Completed.

- SOLO clean-run gate (3/3 successful):
  - Execution profile:
    - `CLPR_SOLO_HOME=/tmp/solo-clpr-0310-bn`
    - `SOLO_ENABLE_BLOCK_NODE=true`
    - `SOLO_ENABLE_MIRROR=false` (required to avoid Solo mirror ingress cluster-scoped release collision across two namespaces)
    - `CLPR_ENABLE_BLOCK_STREAM_TAILER=true`
    - `SOLO_SKIP_CLUSTER_SETUP=true`
  - Run 1:
    - Log: `/tmp/clpr_solo_run1.log`
    - Evidence: `artifacts/clpr-native-messaging-solo/20260217T203348Z`
    - Result: PASS (`E2E run completed successfully`)
  - Run 2:
    - Log: `/tmp/clpr_solo_run2.log`
    - Evidence: `artifacts/clpr-native-messaging-solo/20260217T204237Z`
    - Result: PASS (`E2E run completed successfully`)
  - Run 3:
    - Log: `/tmp/clpr_solo_run3.log`
    - Evidence: `artifacts/clpr-native-messaging-solo/20260217T205129Z`
    - Result: PASS (`E2E run completed successfully`)
  - All three runs completed with clean teardown (`Two-network teardown completed`) and no manual intervention between scenario phases.
- Environment notes captured during execution:
  - Avoid stale deployment-name collisions in `~/.solo` by using an isolated `CLPR_SOLO_HOME` per gate run.
  - For two independent namespaces in one cluster, keep `SOLO_ENABLE_MIRROR=false` in this gate profile to avoid Solo mirror ingress cluster-scoped ownership collisions.

Completion summary:
- Regression matrix is green across both repositories, and the 3/3 SOLO clean-run verification gate passed with captured evidence.
