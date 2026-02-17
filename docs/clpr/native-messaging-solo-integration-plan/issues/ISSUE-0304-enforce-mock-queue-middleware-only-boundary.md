# ISSUE-0304: Enforce Middleware-Only Sender Boundary in MockClprQueue

Status: Done (2026-02-17)

## Objective

Align `MockClprQueue` with intended middleware boundary semantics by requiring middleware-authorized sender on enqueue APIs.

This implements approved proposal item:
- `2.4 / 1.3.3`

## Why

Without sender constraints, tests can bypass middleware boundary rules and create false confidence.

## Scope

### Solidity changes

Modify:
- `contracts/solidity/clpr/mocks/MockClprQueue.sol`

Add sender checks for:
- `enqueueMessage(...)`
- `enqueueMessageResponse(...)`

Use existing error style / event style consistent with current CLPR contracts.

### Tests

Update/add tests in:
- `test/solidity/clpr/clprMiddleware.js`
- `test/foundry/ClprMiddleware.t.sol`

Add negative tests proving unauthorized direct queue sender is rejected.

## Acceptance Criteria

1. Unauthorized direct queue enqueue calls revert.
2. Middleware-driven enqueue flows still pass.
3. Test coverage includes both positive and negative sender-boundary paths.

## Out of Scope

- Changing queue interface shape.
- Introducing authorization roles beyond middleware-boundary check.

## Implementation Log

- Implemented middleware-only queue boundary checks in:
  - `contracts/solidity/clpr/mocks/MockClprQueue.sol`
    - added `MiddlewareOnly()` error
    - `enqueueMessage(...)` now requires `msg.sender == sourceMiddleware`
    - `enqueueMessageResponse(...)` now requires `msg.sender == destinationMiddleware`
- Added regression tests:
  - JS integration:
    - `test/solidity/clpr/clprMiddleware.js`
    - new test `rejects direct queue enqueue calls from non-middleware callers`
  - Foundry:
    - `test/foundry/ClprMiddleware.t.sol`
    - new test `test_RevertWhenNonMiddlewareCallsQueueEnqueueApis`
- Validation:
  - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` (pass)
  - `forge test --match-path test/foundry/ClprMiddleware.t.sol` (pass)

Completion summary:
- Queue mocks now enforce middleware boundary semantics and no longer allow direct external enqueue bypasses.
