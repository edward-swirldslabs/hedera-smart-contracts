# ISSUE-0202: System Contract Enqueue Dispatches `clprEnqueueMessage` (No Direct Writes)

Status: Done (2026-02-15)

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Refactor the CLPR Queue System Contract (`0x16e`) enqueue entrypoints so they no longer mutate CLPR queue state directly.
Instead, they must dispatch a synthetic `clprEnqueueMessage` transaction handled by `ClprEnqueueMessageHandler`.

This issue focuses only on outbound queue appends. Bundle processing will still use the existing path until later issues.

## Behavioral Change (What Users Notice)

- EVM calls to `enqueueMessage(...)` and `enqueueMessageResponse(...)` still succeed and return the same values.
- Outbound queue appends become transaction-correlated for block-stream traceability.
- The on-wire payload bytes should remain identical to the current baseline in this issue.

## Guardrails

- Do not change Solidity interfaces in `hedera-smart-contracts`.
- Do not change connector/app behavior.
- Preserve the current message payload encoding for now (wrapper removal happens later).
- Do not add cross-service writable store plumbing to the contract service. The system contract should translate and dispatch only.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HederaNativeOperations.java` (modify, add readable metadata store accessor)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HandleHederaNativeOperations.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/QueryHederaNativeOperations.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/` (modify tests for dispatch semantics)
- `hedera-node/hedera-file-service-impl/src/main/resources/genesis/throttles-dev.json` (modify, add missing CLPR ops so dispatch isn't always throttled in dev/SOLO)

This repo (`hedera-smart-contracts`):

- `scripts/clpr/native-messaging-solo/run-e2e.sh` (modify, port-forward supervisor hardening for repeatable SOLO runs)

## Implementation Tasks

1. Replace any direct CLPR store writes in the enqueue calls with synthetic dispatch of `clprEnqueueMessage`.
2. Preserve the current payload bytes written to the outbound queue (do not switch to canonical bytes yet).
3. Ensure the system contract can still deterministically return an assigned `messageId`:
4. Prefer pre-reading `next_message_id` and including it as `expected_message_id` in the synthetic tx body.
5. Add unit tests that prove:
6. `ClprQueueOperations.enqueue(...)` or equivalent direct write is no longer used in the system contract path.
7. The system contract dispatches exactly one `clprEnqueueMessage` tx with the expected ledger id and payload.
8. The returned `messageId` matches the value assigned by the handler.

## Test Plan

Consensus node:

- `cd ../hiero-consensus-node`
- `./gradlew :hedera-smart-contract-service-impl:test --tests '*ClprQueueEnqueue*' --no-daemon`
- `./gradlew :hiero-clpr-interledger-service-impl:test --no-daemon`
- `./gradlew :app:assemble --no-daemon`

Two-ledger SOLO E2E (this repo):

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Code shape:

- No direct writable CLPR store access from `hedera-smart-contract-service-impl` is required for queue appends.
- The enqueue system contract calls dispatch `clprEnqueueMessage` and do not call `ClprQueueOperations.enqueue(...)`.
- The outbound payload bytes are unchanged compared to the pre-issue baseline.

Behavior:

- All modified and new tests pass.
- The two-ledger SOLO E2E scenario succeeds unchanged.

## Implementation Log (Append As You Work)

- Notes:
- Refactored the CLPR Queue system contract enqueue calls (`enqueueMessage` + `enqueueMessageResponse`) to dispatch a synthetic `clprEnqueueMessage` transaction instead of directly mutating CLPR queue state.
- Preserved the existing outbound payload bytes (no canonical envelope changes yet) by reusing the pre-existing encode/decode helpers and only changing the write-path.
- Kept system contract determinism by pre-reading `nextMessageId` from the readable CLPR queue metadata store and dispatching with `expected_message_id=nextMessageId`. The system contract returns that same value as the assigned `messageId`.
- Root cause of the initial SOLO failure after the refactor: the synthetic dispatch returned `THROTTLED_AT_CONSENSUS` because `ClprEnqueueMessage` (and related CLPR ops) were missing from the dev throttle definitions; the throttle manager treats missing ops as always throttled.
- Fixed by adding `ClprUpdateMessageQueueMetadata`, `ClprProcessMessageBundle`, and `ClprEnqueueMessage` to `hedera-node/hedera-file-service-impl/src/main/resources/genesis/throttles-dev.json`.
- Hardened `scripts/clpr/native-messaging-solo/run-e2e.sh` with a lightweight port-forward supervisor to reduce docker-desktop port-forward disconnect flakes during repeated runs.
- Commands run:
- `cd ../hiero-consensus-node && ./gradlew :hedera-smart-contract-service-impl:test --tests '*ClprQueueEnqueue*' --no-daemon`
- `cd ../hiero-consensus-node && ./gradlew :hiero-clpr-interledger-service-impl:test --no-daemon`
- `cd ../hiero-consensus-node && ./gradlew :app:assemble --no-daemon`
- `bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build --keep`
- Test results:
- System contract enqueue translator tests: passing.
- CLPR interledger service tests: passing.
- E2E evidence directories:
- Failure evidence (dispatch throttled): `artifacts/clpr-native-messaging-solo/20260215T230443Z`
- Success evidence (after throttles fix): `artifacts/clpr-native-messaging-solo/20260215T231537Z`
- Success evidence (no-redeploy repeatability run): `artifacts/clpr-native-messaging-solo/20260215T233820Z`
- Completion summary:
- `0x16e` queue enqueue entrypoints no longer write queue state directly; outbound queue appends are now transaction-correlated via synthetic `clprEnqueueMessage` dispatch and `ClprEnqueueMessageHandler`.
