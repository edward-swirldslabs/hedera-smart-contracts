# ISSUE-0204: Refactor Bundle Handler To Use `0x16e` Delivery (Remove ABI From Messaging)

Status: Done

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Refactor `ClprProcessMessageBundleHandler` to:

- Remove all ABI artifacts and ABI encode/decode logic from the CLPR messaging module.
- Dispatch per-message delivery to the queue system contract (`0x16e`) via the node-internal packed entry points added in ISSUE-0203.
- Stop constructing custom request/response wrapper envelopes in the messaging layer.
- Stop enqueueing replies from the bundle handler; reply enqueue must happen in the system-contract layer via `clprEnqueueMessage`.

After this issue, `hiero-clpr-interledger-service-impl` should no longer depend on `headlong`.

## Behavioral Change (What Users Notice)

- No intended change in the two-ledger SOLO E2E behavior.
- The implementation becomes production-intended:
- Messaging-layer bundle processing becomes proto/state-proof and synthetic-dispatch only.
- ABI knowledge and middleware dispatch move to the system-contract layer.

## Guardrails

- No `com.esaulpaugh.headlong.abi.*` usage in `hiero-clpr-interledger-service-impl`.
- No hard-coded Solidity signatures or tuple layouts in messaging handlers.
- No new message transport. Must continue to rely on `ClprEndpointClient`.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java` (modify)
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/module-info.java` (modify, remove `headlong` requirement)
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprProcessMessageBundleHandlerTest.java` (modify or add tests)

This repo (`hedera-smart-contracts`):

- No intended code changes.

## Implementation Tasks

1. Identify all ABI artifacts in `ClprProcessMessageBundleHandler` and delete them.
2. Replace per-message processing with:
3. For inbound request payloads, dispatch a synthetic `ContractCall` to `0x16e` deliver-inbound-message selector using packed call data.
4. For inbound reply payloads, dispatch a synthetic `ContractCall` to `0x16e` deliver-inbound-reply selector using packed call data.
5. Ensure the handler updates `received_message_id` and running hash metadata exactly as before.
6. Remove `headlong` from the CLPR messaging module:
7. Delete `requires transitive com.esaulpaugh.headlong;` from `module-info.java`.
8. Ensure compilation proves no transitive ABI dependency remains.
9. Add or update unit tests proving:
10. The handler no longer references ABI tooling.
11. The handler dispatches the expected synthetic contract calls (including correct packed bytes).
12. The handler still advances received metadata correctly.

## Test Plan

Consensus node:

- `cd ../hiero-consensus-node`
- `./gradlew :hiero-clpr-interledger-service-impl:test --tests '*ClprProcessMessageBundleHandler*' --no-daemon`
- `./gradlew :app:assemble --no-daemon`

Two-ledger SOLO E2E (this repo):

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Code shape:

- `hiero-clpr-interledger-service-impl` no longer depends on headlong and contains no ABI artifacts.
- Bundle processing delegates message and reply delivery to `0x16e` entry points via packed call data.

Behavior:

- All modified and new tests pass.
- The two-ledger SOLO E2E scenario succeeds unchanged.

## Implementation Log (Append As You Work)

- Notes:
- Refactored `ClprProcessMessageBundleHandler` to remove ABI decode/encode behavior and delegate per-message delivery to `0x16e` node-internal selectors with packed call data.
- Removed direct reply enqueue and any direct outbound queue append behavior from bundle processing; queue appends now occur only through `clprEnqueueMessage` dispatch in the system-contract layer.
- Removed `headlong` dependency from module runtime (`module-info.java` no longer requires `com.esaulpaugh.headlong`).
- Updated handler tests to validate the new semantics:
  - bundle handling performs synthetic dispatches,
  - queue metadata (`receivedMessageId`, running hash) still advances correctly,
  - outbound queue metadata is not mutated directly by bundle handler logic.
- Commands run:
- `cd ../hiero-consensus-node`
- `./gradlew :hiero-clpr-interledger-service-impl:test --tests '*ClprProcessMessageBundleHandlerTest' --no-daemon`
- `./gradlew :hiero-clpr-interledger-service-impl:test --no-daemon`
- `./gradlew :app:assemble --no-daemon`
- `cd /Users/user/IdeaProjects/hedera-smart-contracts`
- `CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true SOLO_CLUSTER_REF=solo-shared bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep`
- Test results:
- `ClprProcessMessageBundleHandlerTest` passed (22 passing).
- Full `:hiero-clpr-interledger-service-impl:test` passed (141 passing).
- `:app:assemble` passed.
- Two-ledger SOLO e2e passed with the refactored handler.
- E2E evidence directories:
- `artifacts/clpr-native-messaging-solo/20260216T150509Z`
- Completion summary:
- ISSUE-0204 acceptance criteria satisfied. Messaging-layer ABI handling was removed from bundle processing, `headlong` was removed from runtime module dependencies, and the end-to-end SOLO scenario still succeeds unchanged.
