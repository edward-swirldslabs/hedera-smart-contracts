# ISSUE-0008: Implement `enqueueMessageResponse` Path

Status: Done

Owner: Unassigned

Depends on:

- ISSUE-0007

## Goal

Implement `IClprQueue.enqueueMessageResponse(ClprMessageResponse)` so response envelopes are appended to the native queue as reply payloads with deterministic ids and stable routing envelope validation.

## Scope

In scope:

- Decode `ClprMessageResponse` calldata and preserve `original_message_id` correlation data.
- Append response payload as queue reply variant.
- Return response queue id to caller.
- Validate malformed/invalid response route envelope fields.
- Validate malformed/missing `original_message_id`.
- Resolve destination routing from response route header bytes in this issue; persist/lookup correlation state is deferred to ISSUE-0009.
- Allow temporary harness-generated route fixtures for adapter tests until Solidity middleware route-header population is completed (ISSUE-0010).

Out of scope:

- Destination/source middleware callback execution.

## Requirements / References

- `contracts/solidity/clpr/interfaces/IClprQueue.sol`
- `contracts/solidity/clpr/types/ClprTypes.sol`
- `../hiero-consensus-node/hapi/.../clpr_message_queue.proto` (message vs message_reply)
- `docs/clpr/native-queue-integration-plan/queue-adapter-design-notes.md` (response envelope and routing rules)

## Routing Scope (Normative for ISSUE-0008)

- `enqueueMessageResponse(...)` extracts a route header from:
  - `ClprMessageResponse.middlewareResponse.middlewareMessage.data`
- Route header format for this issue is:
  - `(uint8 version, bytes32 remoteLedgerId, address targetMiddleware)`
- Response-path correlation-state persistence/lookup is explicitly deferred to ISSUE-0009 callback integration.

## Acceptance Criteria

- Middleware can enqueue response envelopes via system contract with deterministic ids.
- Correlation id (`original_message_id`) remains available to receiving side.
- Queue metadata and running hash remain valid after mixed request/response traffic.
- Response payload encoding preserves middleware status and connector/application response bytes without truncation.
- Response enqueue fails fast on invalid/zero `original_message_id`.
- `sentMessageId` remains acknowledgement-tracked and is not advanced by enqueue operations.
- Response-path implementation replaces ISSUE-0006 scaffolding stub behavior (`CLPR_QUEUE_NOT_IMPLEMENTED`) for `enqueueMessageResponse(...)`.
- Response envelope stores full response selector calldata (`0xb26aa82b...`) in envelope `callData`.
- Route-envelope validation rejects unsupported route version and zero/invalid remote-ledger id with typed revert reasons.

## Milestone Exit Criteria (Dependency Gate)

- A golden encode/decode fixture for `ClprMessageResponse` is checked in and shared across adapter tests.
- Mixed-flow test (request + response interleaving) proves queue ordering and message-id integrity.
- Error behavior for invalid/zero `original_message_id` is explicitly asserted and documented.
- Fixture includes selector + calldata hash and response-envelope hash from ISSUE-0004 notes.
- Deferred note is captured that correlation lookup coverage moves to ISSUE-0009.

## Tests

- Unit:
  - ABI decode for response struct.
  - Correlation-field validation tests.
  - Golden fixture tests for response envelope fidelity.
  - ABI type-conformance checks for unsigned numeric fields (`uint64` encode/decode expectations).
- HapiTest:
  - End-to-end request enqueue + response enqueue + queue readback assertions.
- Solo:
  - Single-network smoke with mixed request/response enqueue operations.

## Execution Preconditions

- Hapi/Solo scenarios in this issue must set:
  - `contracts.systemContract.clprQueue.enabled=true`

## Expected File Changes

In `../hiero-consensus-node`:

- CLPR queue system-contract translator/call logic for second selector.
- Native enqueue handler support for reply payload variant.
- Unit/HapiTest updates for response-path route validation and mixed-flow non-regression behavior.

In `hedera-smart-contracts`:

- Optional harness test updates in `test/solidity/clpr/`.

## Risk Areas

- Correlation metadata loss during translation.
- Inconsistent interpretation of "request" vs "response" payload variants.
- Leaving ISSUE-0006 scaffolding revert path active on response selector.

## Completion Notes (2026-02-12)

- Replaced `enqueueMessageResponse(...)` scaffolding stub with real response-path enqueue wiring in consensus node.
- Added response adapter call implementation that:
  - decodes `ClprMessageResponse` calldata,
  - validates `original_message_id > 0`,
  - decodes route header from `middlewareResponse.middlewareMessage.data`,
  - validates route header (`version==1`, non-zero `remoteLedgerId`),
  - builds reply envelope bytes `(uint8,address,bytes)`,
  - calls `ClprQueueOperations.enqueue(...)`,
  - returns ABI-encoded `(uint64 messageId)`.
- Added/expanded unit coverage for:
  - response-path success and message-id return,
  - bad calldata,
  - unsupported route version,
  - invalid original message id.
- Validation evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0008-evidence.md`
