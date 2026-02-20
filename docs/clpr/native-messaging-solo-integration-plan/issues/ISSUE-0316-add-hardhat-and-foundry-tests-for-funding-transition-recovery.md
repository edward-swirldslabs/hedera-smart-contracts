# ISSUE-0316: Add Hardhat and Foundry Tests for Funding-Transition Recovery

Status: Done (2026-02-18)

## Objective

Add deterministic contract-level coverage for hybrid funding transition sync and connector2 top-off/re-deplete behavior.

## Why

Scenario scripts are necessary but not sufficient. We need repeatable contract test coverage that fails quickly when regression is introduced.

## Scope

### A. Hardhat tests

Add/extend tests under:

- `test/solidity/clpr/clprMiddleware.js`
- or split into dedicated files (recommended):
  - `test/solidity/clpr/clprFundingRecovery.js`

Test matrix:

- single-side underfunded -> top-off -> available -> underfunded again
- stale epoch update ignored
- duplicate update idempotent

### B. Foundry tests

Add mirrored tests:

- `test/foundry/ClprFundingRecovery.t.sol` (new)

### C. Assertions

Validate:

- funding epoch monotonicity
- pre-reject toggling correctness
- connector2 authorize/reject counts across transitions

## Impacted Files (Expected)

- `test/solidity/clpr/*.js`
- `test/foundry/*.t.sol`
- `test/constants.js` if new contracts are referenced by constants

## Acceptance Criteria

1. New tests fail before implementation and pass after implementation.
2. Existing CLPR tests remain green.
3. Hardhat and Foundry command targets are documented.

## Out of Scope

- SOLO orchestration scripts.
- Consensus-node Java tests (unless needed due to ABI coupling changes).

## Implementation Log

- Expanded `test/solidity/clpr/clprMiddleware.js`:
  - 6-message flow coverage
  - connector2 depletion -> topoff -> re-deplete transitions
  - source connector authorize/sendRejected counters across the full cycle
  - remote funding epoch assertions (`1 -> 2 -> 3`)
- Expanded `test/foundry/ClprMiddleware.t.sol` with the same behavior:
  - added helper methods to keep test readable and avoid stack-depth issues
  - mirrored assertions for counters, balances, and epochs
- Updated test setup in both suites:
  - destination middleware now configured with source middleware as remote peer for each destination connector
    so funding-state control updates can flow back to source.
- Validation:
  - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` (pass)
  - `forge test --match-path test/foundry/ClprMiddleware.t.sol` (pass)

Completion summary:
- Hardhat and Foundry now enforce the hybrid recovery behavior and fail fast on regressions in the top-off/re-deplete cycle.
