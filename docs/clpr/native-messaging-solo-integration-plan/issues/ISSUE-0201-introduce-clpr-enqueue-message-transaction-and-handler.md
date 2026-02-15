# ISSUE-0201: Introduce `clprEnqueueMessage` Transaction And Handler

Status: Planned

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Create a transaction-correlated path for appending to the CLPR outbound message queue:

- Define a new transaction body `clprEnqueueMessage`.
- Implement `ClprEnqueueMessageHandler` as the only writer for outbound queue appends (eventually).
- Add unit tests for correctness and determinism.

This issue should not change the live two-ledger SOLO behavior yet. It introduces the new primitive that later issues will
integrate into system contracts and bundle processing.

## Behavioral Change (What Users Notice)

- No intended change in E2E behavior yet.
- New transaction type exists and can be dispatched synthetically by later components.

## Guardrails

- No ABI tooling, selectors, or Solidity knowledge in this handler.
- No changes to `hedera-smart-contracts` Solidity middleware/app/connector APIs.
- No new third-party dependencies.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- `hapi/hedera-protobuf-java-api/src/main/proto/interledger/clpr_enqueue_message.proto` (new)
- `hapi/hedera-protobuf-java-api/src/main/proto/services/transaction.proto` (modify, add tx body field)
- `hapi/hedera-protobuf-java-api/src/main/proto/services/basic_types.proto` (modify, add `HederaFunctionality`)
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprEnqueueMessageHandler.java` (new)
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/.../ClprEnqueueMessageHandlerTest.java` (new)
- `hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/dispatcher/TransactionHandlers.java` (modify)
- `hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/dispatcher/TransactionDispatcher.java` (modify)

This repo (`hedera-smart-contracts`):

- No intended code changes.

## Implementation Tasks

1. Add protobuf definition for `ClprEnqueueMessageTransactionBody`.
2. Wire the new transaction body into `TransactionBody.data` and a new `HederaFunctionality` enum value.
3. Implement `ClprEnqueueMessageHandler` with:
4. Validate CLPR enabled.
5. Validate ledger id present.
6. Validate payload has exactly one of `message` or `message_reply`.
7. Read queue metadata for the given ledger id.
8. Assign message id from `next_message_id`, compute running hash, store message value, increment metadata.
9. Wire handler into dispatcher plumbing.
10. Add unit tests proving:
11. `next_message_id` assignment and increment is correct.
12. running hash update matches `ClprMessageUtils.nextRunningHash(...)`.
13. invalid inputs fail with the expected status.

## Test Plan

Consensus node:

- `cd ../hiero-consensus-node`
- `./gradlew :hiero-clpr-interledger-service-impl:test --tests '*ClprEnqueueMessageHandlerTest*' --no-daemon`
- `./gradlew :app:assemble --no-daemon`

Two-ledger SOLO E2E (this repo):

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Code shape:

- `ClprEnqueueMessageHandler` exists and appends to outbound queue state without using ABI tooling.
- No new third-party dependencies were introduced in CLPR modules.
- Dispatcher wiring compiles and routes `clprEnqueueMessage` to the new handler.

Behavior:

- All targeted unit tests pass.
- The two-ledger SOLO E2E run succeeds unchanged.

## Implementation Log (Append As You Work)

- Notes:
- Commands run:
- Test results:
- E2E evidence directories:
- Completion summary:

