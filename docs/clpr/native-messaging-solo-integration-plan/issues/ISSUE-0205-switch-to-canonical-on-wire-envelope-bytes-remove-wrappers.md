# ISSUE-0205: Switch To Canonical On-Wire Envelope Bytes (Remove Wrappers)

Status: Planned

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Make the bytes stored on-wire in CLPR queue payloads canonical:

- `ClprMessage.message_data` must equal `abi.encode(ClprTypes.ClprMessage)`.
- `ClprMessageReply.message_reply_data` must equal `abi.encode(ClprTypes.ClprMessageResponse)`.

This issue removes the need for non-canonical wrapper envelopes in the queue payload bytes.

## Behavioral Change (What Users Notice)

- No user-facing Solidity API changes are intended.
- Wire payload bytes change shape, but the end-to-end behavior of the two-ledger SOLO scenario remains the same.

## Guardrails

- No wrapper envelopes remain in the messaging layer.
- Only application/connector/middleware payload fields remain opaque bytes.
- Avoid changes to middleware/app/connector Solidity contracts unless a hard incompatibility is proven.

## Files Impacted

Consensus node (`../hiero-consensus-node`):

- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java` (modify)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java` (modify)
- Unit tests in `hedera-smart-contract-service-impl` (modify or add)

This repo (`hedera-smart-contracts`):

- Ideally no changes.
- If a Solidity change is truly unavoidable, the issue must document why and keep it localized.

## Implementation Tasks

1. Update `enqueueMessage(...)` system-contract call to store canonical bytes:
2. `message_data := input[4:]` (strip selector, no re-encoding).
3. Update `enqueueMessageResponse(...)` system-contract call to store canonical bytes:
4. `message_reply_data := input[4:]` (strip selector, no re-encoding).
5. Update request delivery entry point to decode canonical request bytes and call middleware `handleMessage(...)`.
6. Capture the middleware return bytes and use them as canonical `message_reply_data` when enqueueing a reply.
7. Update reply delivery entry point to decode canonical response bytes and call middleware `handleMessageResponse(...)`.
8. Add tests that prove:
9. Outbound queue payload bytes are now canonical and stable.
10. No wrapper encoding path is required for the end-to-end scenario.
11. The two-ledger SOLO scenario still succeeds with canonical bytes.

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

- Queue payload bytes are canonical (`abi.encode(ClprMessage)` and `abi.encode(ClprMessageResponse)`).
- No wrapper envelope encoding is required to route/deliver inbound messages.

Behavior:

- All tests pass.
- The two-ledger SOLO E2E scenario succeeds unchanged from the user’s perspective.

## Implementation Log (Append As You Work)

- Notes:
- Commands run:
- Test results:
- E2E evidence directories:
- Completion summary:
