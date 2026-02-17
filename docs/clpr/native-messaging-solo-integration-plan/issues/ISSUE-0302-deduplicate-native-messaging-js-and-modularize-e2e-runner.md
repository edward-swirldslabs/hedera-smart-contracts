# ISSUE-0302: Deduplicate Native-Messaging JS Helpers and Modularize E2E Runner Phases

Status: Done (2026-02-17)

## Objective

Reduce duplication in `hedera-smart-contracts` native messaging scripts and make orchestration phases reusable.

This implements approved proposal items:
- `2.5 / 2.1`
- `2.7 / 2.2.2`

## Why

The current scripts are operationally sound but still carry duplicate utility logic and a large orchestrator script body.

## Scope

### JS helper deduplication

- Extract connector-id and shared scenario helper logic from:
  - `scripts/clpr/native-messaging-solo/run-scenario.js`
  - `test/solidity/clpr/clprMiddleware.js` (where runtime compatibility permits)
- Introduce shared helper module(s), e.g.:
  - `scripts/clpr/native-messaging-solo/lib-connectors.js`
  - `test/solidity/clpr/support/connectorIds.js` (if test/runtime boundaries require)

### Shell modularization slice

- Split major orchestration phases from `scripts/clpr/native-messaging-solo/run-e2e.sh` into sourced phase functions:
  - build/setup
  - deploy/up
  - port-forward/readiness
  - config exchange
  - scenario execution
  - evidence collection
  - cleanup/teardown

Suggested file:
- `scripts/clpr/native-messaging-solo/run-e2e-phases.sh`

### Documentation updates

Update usage docs to reflect modularized script surfaces:
- `docs/clpr/README.md`
- `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md`
- `AGENTS.md` (pointer-level updates only)

## Acceptance Criteria

1. Duplicate connector-id formula code is eliminated from primary script/test paths.
2. `run-e2e.sh` orchestrates through phase functions with equivalent behavior.
3. Existing run command remains stable:
   - `bash scripts/clpr/native-messaging-solo/run-e2e.sh`
4. Docs match new structure and entrypoints.

## Out of Scope

- New test scenario semantics.
- SOLO topology changes.

## Implementation Log

- Added shared connector-id derivation helper:
  - `scripts/clpr/shared/connector-ids.js`
- Updated consumers to use shared helper:
  - `scripts/clpr/native-messaging-solo/run-scenario.js`
  - `test/solidity/clpr/clprMiddleware.js`
- Validation so far:
  - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` (pass)
- Added sourced phase module for SOLO E2E orchestration:
  - `scripts/clpr/native-messaging-solo/run-e2e-phases.sh`
- Updated orchestrator to use phase functions:
  - `scripts/clpr/native-messaging-solo/run-e2e.sh`
- Documentation updates for script layout:
  - `docs/clpr/README.md`
  - `AGENTS.md`
- Validation so far:
  - `bash -n scripts/clpr/native-messaging-solo/run-e2e.sh` (pass)
  - `bash -n scripts/clpr/native-messaging-solo/run-e2e-phases.sh` (pass)
  - `bash scripts/clpr/native-messaging-solo/run-e2e.sh --help` (pass)

Completion summary:
- Connector-id derivation is deduplicated across scenario runner and contract tests.
- E2E runner orchestration is now phase-modularized with a dedicated sourced phase file while preserving entrypoint compatibility.
