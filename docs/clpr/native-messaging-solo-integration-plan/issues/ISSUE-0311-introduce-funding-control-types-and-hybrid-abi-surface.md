# ISSUE-0311: Introduce Funding Control Types and Hybrid ABI Surface

Status: Done (2026-02-18)

## Objective

Add the foundational CLPR ABI/type model needed for hybrid funding recovery (connector-owned funds, middleware-managed cross-ledger state propagation), without changing behavior yet.

## Why

The current contracts lack explicit control-plane types for funding state transitions and do not expose a standard ABI surface for connector-to-middleware funding transition signaling.

We need a shared contract vocabulary before implementing behavior.

## Scope

### A. Add funding control types

Modify `contracts/solidity/clpr/types/ClprTypes.sol` to add:

- `ClprControlType`
- `ClprFundingState`
- `ClprFundingStateUpdate`
- `ClprControlEnvelope`

Evolve `ClprMiddlewareMessage` to separate route metadata from control metadata.

### B. Extend middleware interface

Modify `contracts/solidity/clpr/interfaces/IClprMiddleware.sol` to add:

- `onConnectorFundingStateTransition(...)`
- `publishConnectorFundingState(...)`
- `remoteFundingEpoch(...)` (view helper)

### C. Extend connector interface

Modify `contracts/solidity/clpr/interfaces/IClprConnector.sol` to add:

- `fundingState()`
- `fundingEpoch()`
- `reconcileFundingState()`
- `fundingHooksVersion()`

No transfer logic in this issue.

## Impacted Files (Expected)

- `contracts/solidity/clpr/types/ClprTypes.sol`
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
- `contracts/solidity/clpr/interfaces/IClprConnector.sol`
- `contracts/solidity/clpr/README.md` (if API tables exist)

## Acceptance Criteria

1. All new enum/struct/interface additions compile.
2. No middleware/connector runtime behavior changes yet (only API/type layer).
3. Existing CLPR tests are updated for compile-time ABI changes where needed.
4. `npx hardhat compile` passes.

## Out of Scope

- Funding state machine implementation.
- Connector deposit APIs.
- Middleware control message send/receive logic.
- SOLO scenario updates.

## Implementation Log

- Added control/funding type model in `contracts/solidity/clpr/types/ClprTypes.sol`:
  - `ClprControlType`
  - `ClprFundingState`
  - `ClprFundingStateUpdate`
  - `ClprControlEnvelope`
- Extended middleware ABI in `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`:
  - `onConnectorFundingStateTransition(...)`
  - `publishConnectorFundingState(...)`
  - `remoteFundingEpoch(...)`
- Extended connector ABI in `contracts/solidity/clpr/interfaces/IClprConnector.sol`:
  - `fundingState()`
  - `fundingEpoch()`
  - `reconcileFundingState()`
  - `fundingHooksVersion()`
- Validation:
  - `npx hardhat compile` (pass)

Completion summary:
- Shared ABI/type vocabulary for hybrid funding recovery is now in place and used by downstream implementation issues.
