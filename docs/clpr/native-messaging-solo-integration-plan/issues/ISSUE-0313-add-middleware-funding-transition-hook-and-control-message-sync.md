# ISSUE-0313: Add Middleware Funding Transition Hook and Control Message Sync

Status: Done (2026-02-18)

## Objective

Implement middleware-side handling of connector funding transitions and propagate transition updates to the remote middleware via native CLPR messaging.

## Why

Topping up a destination connector must clear stale out-of-funds cache on source middleware without polling.

Transition-triggered control messages provide low-overhead synchronization.

## Scope

### A. Middleware local transition hook

Modify `contracts/solidity/clpr/middleware/ClprMiddleware.sol`:

- Implement `onConnectorFundingStateTransition(...)` with strict auth:
  - caller must be the registered connector contract for `connectorId`
- Deduplicate/ignore stale transitions via local epoch tracking

### B. Build and enqueue control messages

When local transition accepted:

- Build control envelope `ConnectorFundingStateUpdate`
- Enqueue over existing queue API (no new transport)

### C. Apply inbound control messages

Add control envelope handling in inbound message path:

- Parse control message before app-level dispatch
- Apply remote cache update only when epoch is newer
- Update `remoteStatusByDestinationConnector` and remote funding epoch

### D. Observability

Add temporary or durable events/logs for:

- local transition observed
- control enqueued
- remote update applied/ignored (stale)

## Impacted Files (Expected)

- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- `contracts/solidity/clpr/types/ClprTypes.sol` (if helper packing changes needed)
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
- `contracts/solidity/clpr/middleware/*` helper libs if extracted

## Acceptance Criteria

1. Middleware accepts funding transition hook only from registered connector address.
2. Middleware enqueues exactly one control update per accepted new epoch.
3. Remote middleware applies only strictly newer epochs.
4. Control updates do not require an application-level message send.
5. Existing message transport remains native queue + existing CLPR messaging layer.

## Out of Scope

- Scenario script changes.
- New connector business policy.
- Polling/heartbeat loops.

## Implementation Log

- Implemented connector-authenticated funding transition hook in `contracts/solidity/clpr/middleware/ClprMiddleware.sol`:
  - `onConnectorFundingStateTransition(...)` enforces caller is the registered connector for `connectorId`
  - stale/local-duplicate epochs are ignored
- Added middleware control-plane publication and apply logic:
  - `_publishFundingStateUpdate(...)` builds/enqueues a `ClprControlEnvelope`
  - `_handleControlMessage(...)` parses inbound control envelopes
  - `_applyRemoteFundingStateUpdate(...)` applies only newer epochs
- Added funding observability events in middleware:
  - `LocalFundingTransitionObserved`
  - `FundingControlEnqueued`
  - `RemoteFundingStateApplied`
- Updated `contracts/solidity/clpr/mocks/MockClprQueue.sol` for bidirectional middleware sends and one-way control messages.
- Validation:
  - `npx hardhat compile` (pass)
  - `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat` (pass)
  - `forge test --match-path test/foundry/ClprMiddleware.t.sol` (pass)

Completion summary:
- Middleware now synchronizes connector funding transitions across ledgers using native queue transport and control envelopes.
