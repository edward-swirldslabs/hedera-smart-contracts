# ISSUE-0006: CLPR Queue System-Contract Scaffolding and Wiring

Status: Done

Owner: Unassigned

Depends on:

- ISSUE-0004
- ISSUE-0005

## Goal

Create the system-contract skeleton in consensus node smart-contract service so Solidity calls to the CLPR queue address are decoded and routed to native CLPR operations.

## Scope

In scope:

- Add a dedicated CLPR queue system-contract address mapping in `ProcessorModule` at `0x16E`.
- Add call factory/call attempt/translator/call classes for queue methods.
- Implement ABI selector decoding for `enqueueMessage` and `enqueueMessageResponse`.
- Return typed revert/status codes on unsupported selectors or malformed calldata.
- Add config gate for CLPR queue system-contract enable/disable behavior.

Out of scope:

- Full end-to-end payload execution on destination middleware.
- Deployment scripts.

## Requirements / References

- Existing system-contract patterns:
  - `.../exec/systemcontracts/hts/`
  - `.../exec/systemcontracts/has/`
  - `.../exec/systemcontracts/hss/`
- `contracts/solidity/clpr/interfaces/IClprQueue.sol`
- `docs/clpr/native-queue-integration-plan/queue-adapter-design-notes.md`

## Locked Constants (Normative)

- System-contract address: `0x16E`
- Selector `enqueueMessage(...)`: `0x8cfaaa60`
- Selector `enqueueMessageResponse(...)`: `0xb26aa82b`
- Contracts config gate key: `systemContract.clprQueue.enabled` (under `contracts.*` namespace)

## Revert/Status Mapping (Normative)

- Gate disabled:
  - EVM result: revert with reason `CLPR_QUEUE_DISABLED`
  - HAPI receipt: `CONTRACT_REVERT_EXECUTED`
- Unsupported selector:
  - EVM result: revert with reason `CLPR_QUEUE_UNSUPPORTED_SELECTOR`
  - HAPI receipt: `CONTRACT_REVERT_EXECUTED`
- Malformed calldata for known selector:
  - EVM result: revert with reason `CLPR_QUEUE_BAD_CALLDATA`
  - HAPI receipt: `CONTRACT_REVERT_EXECUTED`

## Acceptance Criteria

- Queue system-contract address resolves in EVM execution path.
- Calls reach translators and produce deterministic routing results.
- Non-queue selectors fail cleanly.
- Gas/revert behavior for malformed calldata is deterministic and documented.
- Scaffolding keeps business logic thin: translation/routing only, with queue mutation delegated to native service operations.
- Address and selector values match ADR-0001 exactly.
- Adapter call path composes with `ClprQueueOperations.enqueue(...)` (introduced in ISSUE-0005) instead of duplicating queue mutation logic.

## Milestone Exit Criteria (Dependency Gate)

- `ProcessorModule` wiring is in place with an explicit test asserting address mapping uniqueness.
- Call attempt and translator layers are present for both queue methods, even if downstream behavior is stubbed.
- A contract-call smoke test demonstrates selector dispatch to CLPR queue system contract.
- CLPR queue methods are registered in `SystemContractMethodRegistry` with coverage for selector collisions/mismatches.

## Tests

- Unit:
  - Selector decode tests.
  - Translator dispatch tests.
  - Invalid calldata and unsupported-selector tests.
  - Address collision test ensuring CLPR queue address does not overlap existing system contracts.
- HapiTest:
  - Basic contract call that hits system-contract address and returns expected status.
- Solo:
  - N/A for this scaffolding issue.

## Expected File Changes

In `../hiero-consensus-node`:

- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ProcessorModule.java`
- `hedera-node/hedera-config/src/main/java/com/hedera/node/config/data/ContractsConfig.java` (new `systemContract.clprQueue.enabled` gate)
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ClprQueueTranslatorsModule.java`
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/ClprQueueSystemContract.java`
- New package, e.g.:
  - `.../exec/systemcontracts/clpr/ClprQueueCallFactory.java`
  - `.../exec/systemcontracts/clpr/ClprQueueCallAttempt.java`
  - `.../exec/systemcontracts/clpr/ClprQueueRevertCall.java`
  - `.../exec/systemcontracts/clpr/enqueuemessage/ClprQueueEnqueueMessageTranslator.java`
  - `.../exec/systemcontracts/clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseTranslator.java`
- Corresponding tests under:
  - `hedera-node/hedera-smart-contract-service-impl/src/test/java/.../exec/systemcontracts/clpr/`

In `hedera-smart-contracts`:

- No mandatory changes.

## Risk Areas

- Address/selector collisions with existing system contracts.
- Incorrect gas/revert handling at adapter boundary.

## Completion Notes (2026-02-12)

- Implemented CLPR queue system-contract scaffolding at `0x16E` with Dagger wiring in `ProcessorModule`.
- Added config gate in `ContractsConfig` with property key `systemContract.clprQueue.enabled`.
- Added selector dispatch for:
  - `enqueueMessage(...)` => `0x8cfaaa60`
  - `enqueueMessageResponse(...)` => `0xb26aa82b`
- Implemented typed revert mapping:
  - disabled gate => `CLPR_QUEUE_DISABLED`
  - unsupported selector => `CLPR_QUEUE_UNSUPPORTED_SELECTOR`
  - malformed calldata for known selectors => `CLPR_QUEUE_BAD_CALLDATA`
- Known selectors currently return scaffolding stub reason `CLPR_QUEUE_NOT_IMPLEMENTED`; ISSUE-0007/0008 must replace this with real enqueue behavior.
- Validation evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0006-evidence.md`
