# ISSUE-0005: Add Native Enqueue Operation in CLPR Service

Status: Done

Owner: Unassigned

Depends on:

- ISSUE-0004

## Goal

Introduce the minimal native CLPR operation needed to append outbound messages to the local CLPR queue from EVM system-contract calls, without changing higher-level CLPR endpoint semantics.

## Scope

In scope:

- Add native queue-append operation(s) callable from the EVM adapter.
- Persist new outbound queue entries into CLPR message state with correct running-hash updates and `next_message_id` handling.
- Support both request and response payload variants.
- Keep queue metadata semantics consistent with existing endpoint/bundle handlers (`sentMessageId` remains acknowledgment-tracked).

Out of scope:

- Changing existing config exchange protocol semantics.
- Reworking endpoint-client push/pull algorithm except where required for correctness.

## Requirements / References

- `../hiero-consensus-node/hapi/hedera-protobuf-java-api/src/main/proto/interledger/state/clpr/clpr_message_queue.proto`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`

## Acceptance Criteria

- Native enqueue path writes one message entry per call, monotonically increments queue ids, and updates running hash.
- Queue metadata remains valid and consumable by existing `getMessages` / `processMessageBundle` flows.
- No regression of existing CLPR config/queue baseline tests.
- Test-only queue seeding behavior is disabled or removed so enqueue behavior reflects real integration flow.
- The `TODO: REMOVE THIS TESTING CODE` path is removed or fully bypassed in production code path.

## Milestone Exit Criteria (Dependency Gate)

- A single-source enqueue path exists that is callable by the system-contract adapter and is covered by unit tests.
- Queue metadata updates are validated against pre/post snapshots for both message variants.
- Any new protobuf/functionality additions are documented with compatibility impact notes.
- If possible, implementation uses internal service operations and avoids expanding public HAPI protobuf transaction surface for adapter-only enqueue semantics.
- Full route-envelope validation and response-correlation routing are explicitly deferred to ISSUE-0007/0008/0009.

## Tests

- Unit:
  - New handler tests for queue append behavior (message id, running hash, state writes, invalid inputs).
  - Negative tests for invalid ledger id, missing queue metadata, and malformed payload bytes.
- HapiTest:
  - New HapiTest that submits enqueue op(s), queries queue metadata/messages, and validates ordering + payload.
- Solo:
  - Execute enqueue smoke against local custom node and verify state progression.

## Expected File Changes

In `../hiero-consensus-node`:

- `hedera-node/hiero-clpr-interledger-service*/` (native enqueue operation + correlation support)
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java` (remove queue seeding shortcut)
- New/updated CLPR queue operation classes in `hiero-clpr-interledger-service-impl`
- Corresponding unit tests under `hedera-node/.../src/test`

In `hedera-smart-contracts`:

- No mandatory changes.

## Risk Areas

- Protobuf/enum additions may create cross-module blast radius.
- Queue metadata consistency bugs can break remote bundle processing.

## Completion Notes (2026-02-12)

- Implemented native enqueue helper in consensus repo:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java`
- Removed synthetic queue seeding from queue init path:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`
- Added unit coverage:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/ClprQueueOperationsTest.java`
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprUpdateMessageQueueMetadataHandlerTest.java`
- Updated CLPR subprocess baseline expectations after removing synthetic messages:
  - `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
- Evidence and command outputs recorded in:
  - `docs/clpr/native-queue-integration-plan/issue-0005-evidence.md`
