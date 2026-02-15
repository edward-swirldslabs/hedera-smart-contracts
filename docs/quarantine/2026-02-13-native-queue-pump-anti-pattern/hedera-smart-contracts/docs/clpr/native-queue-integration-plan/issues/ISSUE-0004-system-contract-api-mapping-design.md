# ISSUE-0004: Queue System-Contract API and Address Mapping Design

Status: Done

Owner: Unassigned

Depends on:

- ISSUE-0001
- ISSUE-0003

## Goal

Define the exact adapter contract boundary from Solidity `IClprQueue` calls to native CLPR queue operations, including system-contract address mapping, selector mapping, payload encoding strategy, and failure mapping.

## Scope

In scope:

- Keep Solidity queue interface unchanged:
  - `enqueueMessage(ClprMessage)`
  - `enqueueMessageResponse(ClprMessageResponse)`
- Decide and document single system-contract address and function selectors.
- Define ABI <-> native payload transformation:
  - option A: pass full ABI-encoded CLPR message bytes as opaque queue payload,
  - option B: field-by-field translation to protobuf structures.
- Define response codes and revert semantics for failed enqueue.
- Define how middleware target contract identity is encoded in queue payload so callback routing is deterministic.

Out of scope:

- Implementation of translators/calls.
- Deployment scripts.

## Requirements / References

- `contracts/solidity/clpr/interfaces/IClprQueue.sol`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ProcessorModule.java`
- `../hiero-consensus-node/hedera-node/docs/design/clpr-service-design.md`
- `../hiero-consensus-node/hapi/hedera-protobuf-java-api/src/main/proto/interledger/state/clpr/clpr_message_queue.proto`
  - note: queue payload schema currently exposes opaque bytes (`message_data`, `message_reply_data`), which strongly influences adapter strategy.

## Acceptance Criteria

- Design doc/ADR exists and is reviewed.
- It explicitly states what fields are preserved end-to-end and what remains opaque.
- It defines message-id return behavior and typed error mapping.
- It defines a compatibility contract that states no change to Solidity `IClprQueue` signatures.

## Milestone Exit Criteria (Dependency Gate)

- ADR includes:
  - system-contract address selection and collision check rationale,
  - selector table with exact signatures and 4-byte ids,
  - ABI/protobuf mapping matrix per field,
  - failure mapping table from native errors to EVM revert/status behavior.
- ADR includes rationale for callback target addressing (how destination/source middleware contract address is carried).
- `queue-adapter-design-notes.md` includes concrete examples for both request and response payloads.

## Tests

- Unit:
  - Design-level selector and ABI decoding test vectors documented, including malformed input vectors.
- HapiTest:
  - N/A in this design issue.
- Solo:
  - N/A in this design issue.

## Expected File Changes

In `../hiero-consensus-node`:

- `hedera-node/docs/clpr/adrs/` (new ADR)
- `hedera-node/docs/clpr/implementation/` (integration note update)

In `hedera-smart-contracts`:

- `docs/clpr/native-queue-integration-plan/queue-adapter-design-notes.md` (new)

## Risk Areas

- Choosing encoding strategy that is hard to evolve.
- Inconsistent error mapping between system contract and middleware expectations.

## Completion Notes (2026-02-12)

- Added ADR in consensus-node repo:
  - `../hiero-consensus-node/hedera-node/docs/clpr/adrs/ADR-0001-clpr-queue-system-contract-api-mapping.md`
- Added implementation note in consensus-node repo:
  - `../hiero-consensus-node/hedera-node/docs/clpr/implementation/queue-adapter-integration-notes.md`
- Added this repo's design vectors/examples:
  - `docs/clpr/native-queue-integration-plan/queue-adapter-design-notes.md`
  - `docs/clpr/native-queue-integration-plan/issue-0004-evidence.md`
- Locked design decisions:
  - queue system-contract address: `0x16E`,
  - selector table:
    - `enqueueMessage` -> `0x8cfaaa60`
    - `enqueueMessageResponse` -> `0xb26aa82b`
  - payload strategy: opaque ABI payload transport with route envelope,
  - failure mapping: enqueue failures must revert/halt so Solidity middleware `try/catch` behavior remains unchanged.
