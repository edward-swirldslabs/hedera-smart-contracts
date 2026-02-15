# ISSUE-0007: Implement `enqueueMessage` Request Path (EVM -> Native CLPR Queue)

Status: Done

Owner: Unassigned

Depends on:

- ISSUE-0005
- ISSUE-0006

## Goal

Implement the `IClprQueue.enqueueMessage(ClprMessage)` call end-to-end from Solidity to native CLPR queue state, returning a stable `messageId` to middleware.

## Scope

In scope:

- Decode `ClprMessage` calldata in system contract.
- Marshal to native queue payload representation using the ISSUE-0004 request envelope format.
- Persist as outbound queue message entry for target remote ledger.
- Return assigned message id to EVM caller.

Out of scope:

- Response enqueue path.
- Destination middleware execution path for received messages.

## Requirements / References

- `contracts/solidity/clpr/interfaces/IClprQueue.sol`
- `contracts/solidity/clpr/types/ClprTypes.sol`
- `../hiero-consensus-node/.../ClprMessageQueueMetadata` and message store handlers
- `docs/clpr/native-queue-integration-plan/queue-adapter-design-notes.md` (Envelope format v1)

## Normative Request Envelope (v1)

Queue payload for `message.message_data` must encode exactly:

- `uint8 version`
- `bytes32 remoteLedgerId`
- `address sourceMiddleware`
- `address destinationMiddleware`
- `bytes callData` (full calldata for `enqueueMessage(...)`)

Notes:

- `version` is locked to `1` for this issue.
- `callData` must include selector `0x8cfaaa60`.
- Route header source for this issue is `ClprMessage.middlewareMessage.data`, encoded as ABI tuple:
  - `(uint8 version, bytes32 remoteLedgerId, address sourceMiddleware, address destinationMiddleware)`

## Acceptance Criteria

- Middleware call to `enqueueMessage(...)` succeeds and receives non-zero id.
- Queue metadata increments consistently (`nextMessageId` and running hash state).
- Payload bytes can be later retrieved in message bundles.
- Destination ledger identifier selection is validated and incorrect routing attempts fail with typed errors.
- Route envelope validation rejects missing/invalid `remoteLedgerId` and unsupported envelope versions.
- `sentMessageId` remains acknowledgement-tracked and is not advanced by enqueue.
- Message-id and metadata invariants are explicit and tested:
  - Fresh queue with `nextMessageId=1` returns ids `1,2,3` for three sequential enqueues.
  - After those enqueues, `nextMessageId=4` and `sentMessageId` is unchanged.
- Request-path implementation replaces ISSUE-0006 scaffolding stub behavior (`CLPR_QUEUE_NOT_IMPLEMENTED`) for `enqueueMessage(...)`.

## Milestone Exit Criteria (Dependency Gate)

- A golden encode/decode fixture for `ClprMessage` is checked in and used by both unit tests and HapiTests.
- Message id monotonicity is verified across at least 3 sequential enqueue calls in one transaction stream.
- Failure paths (bad connector/destination payload shape) are covered with expected revert/status mapping.
- Fixture includes selector + calldata hash and envelope hash (as recorded in `queue-adapter-design-notes.md`).
- Fixture records full envelope field decode (including `version`, ledger id, middleware addresses) and fails on any field drift.

## Tests

- Unit:
  - Calldata decode -> native payload conversion.
  - Queue append state transition tests.
  - Golden fixture tests for field-by-field payload fidelity.
- HapiTest:
  - Deploy minimal contract that calls `enqueueMessage`; verify returned id and queue query values.
- Solo:
  - Single-network smoke proving enqueue through system-contract address in a custom node deployment.

## Expected File Changes

In `../hiero-consensus-node`:

- CLPR queue system-contract translator/call implementation files from ISSUE-0006.
- CLPR native enqueue handler introduced in ISSUE-0005.
- Potential helper codec classes for ABI payload conversion.
- Unit and BDD test additions for enqueue request path.

In `hedera-smart-contracts`:

- Optional tiny harness contract in `contracts/solidity/clpr/mocks/` for isolated enqueue testing.
- Optional matching test in `test/solidity/clpr/`.

## Risk Areas

- Encoding mismatch that only appears when remote ledger processes bundles.
- Non-deterministic message-id assignment under failure/retry conditions.
- Leaving ISSUE-0006 scaffolding revert path active on request selector.

## Completion Notes (2026-02-12)

- Replaced `enqueueMessage(...)` scaffolding stub with real request-path enqueue wiring in consensus node.
- Added CLPR queue adapter call implementation that:
  - decodes `ClprMessage` calldata,
  - decodes route header from `middlewareMessage.data`,
  - validates route header (`version==1`, non-zero `remoteLedgerId`),
  - builds envelope bytes `(uint8,bytes32,address,address,bytes)`,
  - calls `ClprQueueOperations.enqueue(...)`,
  - returns ABI-encoded `(uint64 messageId)`.
- Added native store accessors in smart-contract execution scope:
  - `HederaNativeOperations.writableClprMessageQueueMetadataStore()`
  - `HederaNativeOperations.writableClprMessageStore()`
- Added/expanded unit coverage for:
  - request-path success and message-id return,
  - bad calldata,
  - unsupported route version,
  - zero remote-ledger-id route rejection.
- Validation evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0007-evidence.md`
