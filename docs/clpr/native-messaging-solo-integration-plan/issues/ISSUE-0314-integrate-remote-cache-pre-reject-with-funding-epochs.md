# ISSUE-0314: Integrate Remote Cache Pre-Reject with Funding Epoch Semantics

Status: Done (2026-02-18)

## Objective

Refine source middleware pre-reject logic so connector rejection/acceptance behavior is epoch-aware and deterministic after funding-state sync updates.

## Why

Current pre-reject behavior only considers cached balance values. Hybrid funding recovery introduces explicit state epochs that must gate stale/duplicate updates and cache transitions.

## Scope

### A. Pre-reject logic refinement

In `ClprMiddleware.sol`, ensure `_isRemoteOutOfFunds(...)` and related gating logic:

- Uses the latest applied remote epoch data
- Correctly clears remote-unavailable/out-of-funds state after `UNDERFUNDED -> AVAILABLE`
- Avoids accidental reuse of stale underfunded cache state

### B. Cache coherence invariants

Add invariants/assertions (where practical):

- applied epoch monotonicity
- state/balance coherence (`available <= threshold` implies underfunded)

### C. Connector2-specific scenario alignment

Ensure behavior supports this sequence:

1. connector2 underfunded -> pre-reject
2. top-up transition update arrives -> connector2 allowed once/multiple until depleted
3. connector2 underfunded again -> pre-reject resumes

## Impacted Files (Expected)

- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- `test/solidity/clpr/*` tests for cache epoch behavior
- `test/foundry/*` if mirrored tests are added

## Acceptance Criteria

1. Pre-reject behavior toggles correctly based on latest remote epoch/state.
2. Stale update replay cannot re-open or re-close connector state incorrectly.
3. Re-depletion transitions back to underfunded/pre-reject without manual reset.
4. Hardhat/foundry CLPR tests pass.

## Out of Scope

- Scenario script additions.
- Additional connector policy surfaces not needed for epoch correctness.

## Implementation Log

- Refined pre-reject behavior in `contracts/solidity/clpr/middleware/ClprMiddleware.sol`:
  - `_isRemoteOutOfFunds(...)` now rejects when post-threshold capacity is below remote `minimumCharge`
  - remote cache is toggled by newer funding epochs via `_applyRemoteFundingStateUpdate(...)`
- Added remote epoch tracking:
  - `localFundingEpochByConnector`
  - `remoteFundingEpoch`
- Enforced monotonic apply semantics:
  - inbound control updates with stale/duplicate epochs are ignored
  - connectorId mismatch between envelope key and balance report key is ignored
- Validation:
  - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` (pass)
  - `forge test --match-path test/foundry/ClprMiddleware.t.sol` (pass)

Completion summary:
- Remote cache gating now has explicit epoch semantics and deterministic reopen/reclose behavior for connector2 after funding transitions.
