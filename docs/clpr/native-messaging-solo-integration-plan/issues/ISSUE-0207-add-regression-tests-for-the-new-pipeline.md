# ISSUE-0207: Add Regression Tests For The New Pipeline

Status: Planned

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Add targeted regression coverage that locks in the corrected architecture:

- Queue appends are transaction-correlated via `clprEnqueueMessage`.
- Bundle processing is ABI-free and delegates delivery to `0x16e` node-internal entry points.
- System-contract delivery performs middleware dispatch and reply enqueue using the canonical envelope bytes.

## Behavioral Change (What Users Notice)

- No intended behavior change.
- Faster detection of regressions during future refactors.

## Guardrails

- Tests should be targeted and fast. Prefer unit/integration tests over broad suite runs.
- Avoid adding non-deterministic timing-based assertions.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- New or updated tests in:
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/...`
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/...`
- Optional: targeted subprocess test coverage in `hedera-node/test-clients` if it adds value for message bundle workflows.

This repo (`hedera-smart-contracts`):

- No intended code changes.

## Implementation Tasks

1. Add a unit-level test that exercises `ClprEnqueueMessageHandler` end-to-end against writable stores:
2. Validate assigned id, store write, and running hash update.
3. Add a system-contract level test for `enqueueMessage(...)` and `enqueueMessageResponse(...)`:
4. Validate the synthetic dispatch body uses canonical bytes.
5. Add a system-contract level test for the node-internal delivery entry points:
6. Validate packed parsing, authorization gating, and reply enqueue via `clprEnqueueMessage`.
7. Add a bundle-handler test that:
8. Confirms it dispatches packed delivery calls and contains no ABI decoding logic.
9. If feasible and valuable, add a minimal `testSubprocess` test that:
10. Verifies CLPR config queries and a small message exchange path still work under `:test-clients:testSubprocess`.

## Test Plan

Consensus node:

- `cd ../hiero-consensus-node`
- `./gradlew :hiero-clpr-interledger-service-impl:test --no-daemon`
- `./gradlew :hedera-smart-contract-service-impl:test --no-daemon`
- If subprocess tests were added:
- `./gradlew :test-clients:testSubprocess --no-daemon`

Two-ledger SOLO E2E (this repo):

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Code shape:

- The test suite clearly enforces:
- enqueue via handler-only
- ABI-free bundle processing
- canonical bytes on wire

Behavior:

- All tests pass.
- The two-ledger SOLO E2E scenario succeeds unchanged.

## Implementation Log (Append As You Work)

- Notes:
- Commands run:
- Test results:
- E2E evidence directories:
- Completion summary:

