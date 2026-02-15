# ISSUE-0104: Queue System Contract (Minimal Adapter to Native Queue)

Status: Done (2026-02-14)

Notes:

- System contract address: `0x000000000000000000000000000000000000016e`
- SOLO activation flag (per ledger):
  - `contracts.systemContract.clprQueue.enabled=true`

## Goal

Ensure the consensus node provides an EVM System Contract that implements the queue API expected by the CLPR middleware, and that it bridges to the existing native queue operations used by the native messaging layer.

## Requirements (Must Be True)

- EVM contracts enqueue requests and responses via the Queue System Contract.
- The Queue System Contract does not invent a new message transport.
- The native messaging layer consumes the same native queue state populated by the Queue System Contract.
- Changes in `../hiero-consensus-node` are minimal beyond system contract implementation and wiring.

## Constraints

- Avoid Solidity API changes in this repo. Prefer making the system contract compatible with the existing `IClprQueue` API.
- Avoid connector/app changes.
- Do not add a “pump” or “shipper” helper to compensate for missing endpoint connectivity.

## Tasks

- Verify the system contract address and activation configuration in SOLO.
- Verify ABI mapping between Solidity `IClprQueue` and the system contract methods.
- Confirm queue writes are durable in node state and visible to the native queue consumers.
- Confirm queue reads used by middleware callbacks can observe responses that arrived from the remote ledger.
- Add minimal consensus-node unit tests for:
  - method selector mapping
  - basic enqueue/dequeue semantics
  - revert behavior on invalid inputs

## Acceptance Criteria

- A simple EVM call can enqueue at least one CLPR message request into the native queue.
- The queue contents are observable by the native messaging layer without any external intervention.
- No additional message transport code was introduced outside the existing endpoint client and messaging handlers.
