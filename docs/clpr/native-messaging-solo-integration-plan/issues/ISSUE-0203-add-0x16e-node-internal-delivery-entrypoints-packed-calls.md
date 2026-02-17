# ISSUE-0203: Add `0x16e` Node-Internal Delivery Entry Points (Packed Calls)

Status: Done

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Add node-internal delivery entry points on the CLPR Queue System Contract (`0x16e`) that:

- Accept inbound message bytes from bundle processing using a packed binary call-data format.
- Perform all ABI decoding in the system-contract layer (where ABI tooling already exists).
- Dispatch synthetic middleware callbacks.
- Enqueue reply messages by dispatching `clprEnqueueMessage` (transaction-correlated queue appends).

These entry points are a bridge between native CLPR messaging and the EVM middleware, and they allow the messaging-layer
bundle handler to become ABI-free in later issues.

## Behavioral Change (What Users Notice)

- No intended change to the existing end-to-end flow yet.
- New system-contract selectors exist at `0x16e` but are not yet used by bundle processing.

## Guardrails

- These entry points are node-internal and must not require Ethereum ABI encoding to call them.
- They must be gated so arbitrary EVM users cannot trigger inbound delivery.
- They must not mutate outbound queue state directly. Replies are enqueued via `clprEnqueueMessage` dispatch only.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageTranslator.java` (new)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java` (new)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyTranslator.java` (new)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java` (new)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ClprQueueTranslatorsModule.java` (modify, register translators)
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/` (new tests)

This repo (`hedera-smart-contracts`):

- No intended code changes.

## Implementation Tasks

1. Define selectors for the two node-internal methods and register their translators.
2. Implement packed call-data parsing.
3. Implement request delivery call:
4. Parse `sourceLedgerId`, `inboundMessageId`, and `messageData` bytes from the packed input.
5. Decode `messageData` into the request envelope (legacy wrapper compatibility may be required until ISSUE-0205).
6. Dispatch synthetic `ContractCall` to destination middleware `handleMessage(...)`.
7. Capture return bytes as the response envelope bytes.
8. Dispatch synthetic `clprEnqueueMessage` to enqueue a `message_reply` payload under `sourceLedgerId`.
9. Implement reply delivery call:
10. Parse response bytes from packed input.
11. Decode to find the correct middleware target and dispatch `handleMessageResponse(...)`.
12. Gate both entry points so they can only be invoked by the expected synthetic caller identity used by bundle processing.
13. Add unit tests for:
14. packed parsing correctness.
15. selector routing and translator registration.
16. authorization gating behavior.
17. reply enqueue uses synthetic `clprEnqueueMessage` dispatch, not direct store writes.

## Test Plan

Consensus node:

- `cd ../hiero-consensus-node`
- `./gradlew :hedera-smart-contract-service-impl:test --tests '*DeliverInbound*' --no-daemon`
- `./gradlew :app:assemble --no-daemon`

Two-ledger SOLO E2E (this repo):

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Code shape:

- The two node-internal delivery entry points exist in the `0x16e` system contract translator set.
- Bundle processing can call them using packed bytes (no ABI encoder required at the caller).
- Entry points are gated against arbitrary EVM callers.
- Replies are enqueued only via `clprEnqueueMessage` dispatch.

Behavior:

- All new unit tests pass.
- The two-ledger SOLO E2E scenario succeeds unchanged.

## Implementation Log (Append As You Work)

- Notes:
- Added two new node-internal `0x16e` selectors using packed call-data parsing:
  - `deliverInboundMessagePacked(bytes)` -> request delivery + reply enqueue via `clprEnqueueMessage`.
  - `deliverInboundMessageReplyPacked(bytes)` -> response delivery callback to middleware.
- Added superuser-only gating to prevent arbitrary EVM callers from invoking node-internal delivery methods.
- Registered translators in the CLPR queue translator module and added routing coverage in `ClprQueueCallAttemptTest`.
- Added targeted translator tests to validate packed parsing, auth gating, selector routing, and dispatch behavior.
- Commands run:
- `cd ../hiero-consensus-node`
- `./gradlew :app-service-contract-impl:test --tests '*ClprQueueDeliverInboundMessageTranslatorTest' --tests '*ClprQueueDeliverInboundMessageReplyTranslatorTest' --tests '*ClprQueueCallAttemptTest' --no-daemon`
- `cd /Users/user/IdeaProjects/hedera-smart-contracts`
- `CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true SOLO_CLUSTER_REF=solo-shared bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep`
- Test results:
- `:app-service-contract-impl:test` targeted suite passed (12 passing tests for the added delivery entrypoints + call-attempt routing).
- Two-ledger SOLO e2e passed.
- E2E evidence directories:
- `artifacts/clpr-native-messaging-solo/20260216T145203Z`
- Completion summary:
- ISSUE-0203 acceptance criteria satisfied. The new `0x16e` node-internal delivery entry points are in place, properly gated, tested, and validated by the existing two-ledger SOLO scenario.
