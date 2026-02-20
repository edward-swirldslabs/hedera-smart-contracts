# ISSUE-0312: Add Funding-Aware Connector Base and Migrate Mock Connector

Status: Done (2026-02-18)

## Objective

Create a canonical base connector implementation that owns funding transition detection logic and require the mock connector to inherit it.

## Why

Hybrid architecture requires connector-owned funds, but correctness cannot depend on each custom connector implementer re-writing threshold transition logic.

A shared base implementation is the enforcement point.

## Scope

### A. Add new base connector contract

Create:

- `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol`

Responsibilities:

- Maintain local funding state (`UNDERFUNDED`/`AVAILABLE`)
- Maintain monotonic funding epoch
- Provide canonical deposit APIs:
  - `depositNative()`
  - `depositToken(uint256 amount)`
- Provide `reconcileFundingState()` for out-of-band transfers
- On state transition, call middleware hook once

### B. Migrate mock connector

Modify:

- `contracts/solidity/clpr/mocks/MockClprConnector.sol`

Changes:

- Inherit base connector
- Remove duplicated inline transition logic
- Keep existing CLPR connector semantics (authorize/notify/reimburse)

### C. Add/adjust events

Ensure transition and notify events are emitted with clear observability.

## Impacted Files (Expected)

- `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol` (new)
- `contracts/solidity/clpr/mocks/MockClprConnector.sol`
- `contracts/solidity/clpr/interfaces/IClprConnector.sol` (if final signatures need alignment)
- `test/solidity/clpr/*` (mock connector usage updates)

## Acceptance Criteria

1. Mock connector now uses base funding transition implementation.
2. `UNDERFUNDED -> AVAILABLE` and `AVAILABLE -> UNDERFUNDED` transitions increment epoch.
3. No transition means no epoch increment and no middleware notify.
4. `deposit*` and `reconcileFundingState()` behavior is covered by unit tests.
5. `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` passes.

## Out of Scope

- Middleware remote cache apply logic.
- Cross-ledger control envelope processing.
- SOLO scenario behavior changes.

## Implementation Log

- Added new base connector `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol` with:
  - canonical funding state machine (`Underfunded`/`Available`)
  - monotonic funding epoch
  - `depositNative()` / `depositToken(uint256)` APIs
  - `reconcileFundingState()` for out-of-band balance changes
  - middleware callback on transition only
- Migrated `contracts/solidity/clpr/mocks/MockClprConnector.sol` to inherit the base:
  - wiring for funding middleware via `registerWithMiddleware(...)`
  - explicit overrides for combined `IClprConnector` + base inheritance
  - reconcile calls after policy changes and reimbursements
- Validation:
  - `npx hardhat compile` (pass)
  - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` (pass)
  - `forge test --match-path test/foundry/ClprMiddleware.t.sol` (pass)

Completion summary:
- Funding transition behavior is centralized in one reusable connector base and the mock connector now uses it.
