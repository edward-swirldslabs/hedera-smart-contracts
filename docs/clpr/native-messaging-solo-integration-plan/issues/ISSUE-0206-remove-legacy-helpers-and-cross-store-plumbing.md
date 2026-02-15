# ISSUE-0206: Remove Legacy Helpers And Cross-Store Plumbing

Status: Planned

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Finish converging to the minimal production-intended architecture by removing transitional code:

- Remove legacy wrapper support (if any remains).
- Remove queue mutation helpers that bypass transaction correlation.
- Remove any cross-service writable store plumbing introduced to let system contracts directly write CLPR state.

After this issue, queue appends should happen only via `clprEnqueueMessage` transactions.

## Behavioral Change (What Users Notice)

- No intended behavior change in the two-ledger SOLO scenario.
- Internal code becomes smaller, cleaner, and aligned with traceability requirements.

## Guardrails

- No direct CLPR queue state writes from system-contract call code.
- No ABI artifacts in CLPR messaging handlers.
- No new third-party dependencies.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java` (delete or reduce to test-only)
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/ClprQueueOperationsTest.java` (update or delete)
- Any CLPR wrapper envelope encoders/decoders introduced only for the prior implementation (delete)
- Any contract-service cross-store writable accessors for CLPR stores (remove)
- Unit tests (update for deletions)

This repo (`hedera-smart-contracts`):

- Docs may need updates if any terminology still references wrappers.

## Implementation Tasks

1. Remove `ClprQueueOperations` from runtime usage:
2. Delete it, or move it behind test sources if it is still useful as a test helper.
3. Remove any remaining wrapper envelope encoding/decoding code paths that are no longer needed after ISSUE-0205.
4. Remove any `hedera-smart-contract-service-impl` access to writable CLPR stores if it exists on this branch.
5. Update tests to ensure:
6. All queue appends happen via `ClprEnqueueMessageHandler`.
7. Delivery and enqueue paths still function end-to-end.

## Test Plan

Consensus node:

- `cd ../hiero-consensus-node`
- `./gradlew :hedera-smart-contract-service-impl:test --no-daemon`
- `./gradlew :hiero-clpr-interledger-service-impl:test --no-daemon`
- `./gradlew :app:assemble --no-daemon`

Two-ledger SOLO E2E (this repo):

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Code shape:

- `ClprQueueOperations` is not used by runtime code paths.
- System-contract layer does not write CLPR queue state directly.
- Bundle processing remains ABI-free.

Behavior:

- All tests pass.
- The two-ledger SOLO E2E scenario succeeds unchanged.

## Implementation Log (Append As You Work)

- Notes:
- Commands run:
- Test results:
- E2E evidence directories:
- Completion summary:
