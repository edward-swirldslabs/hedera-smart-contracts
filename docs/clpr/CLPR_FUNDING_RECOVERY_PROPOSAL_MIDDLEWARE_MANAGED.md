# CLPR Funding Recovery Proposal A: Middleware-Managed Connector Funding

## 1. Objective

This proposal makes middleware the single authority for connector fund custody, threshold state tracking, and cross-ledger funding-state synchronization.

Primary goals:

- Eliminate stale remote out-of-funds cache after destination connector top-up.
- Avoid periodic polling/heartbeat overhead.
- Trigger exactly-on-transition control signaling (low frequency, event-driven).
- Ensure deterministic behavior when one or both connectors in a pair become underfunded.

## 2. Design Summary

In this model, connector balances used for CLPR economics are not read from connector contract token/native balances. Instead, each middleware maintains a per-connector escrow ledger and charge-policy state. Funding calls go through middleware APIs, so middleware immediately knows when a connector crosses `UNDERFUNDED -> AVAILABLE`.

On threshold transitions, middleware enqueues a native CLPR control message to the remote middleware. Remote middleware updates cached `remoteStatusByDestinationConnector` and pre-reject logic is unblocked (or blocked) accordingly.

## 3. Contract and ABI Changes

## 3.1 `contracts/solidity/clpr/types/ClprTypes.sol`

Add explicit middleware control payload types.

### New enums

- `enum ClprControlType { None, ConnectorFundingStateUpdate, ConnectorFundingStateQuery, ConnectorFundingStateAck }`
- `enum ClprFundingState { Underfunded, Available }`

### New structs

- `struct ClprFundingStateUpdate {
    bytes32 connectorId;
    uint64 fundingEpoch;
    ClprFundingState state;
    ClprBalanceReport balanceReport;
  }`

- `struct ClprControlEnvelope {
    ClprControlType controlType;
    bytes payload;
  }`

### `ClprMiddlewareMessage` change

Current:

- `ClprBalanceReport balanceReport`
- `bytes data`

Proposed:

- `ClprBalanceReport balanceReport`
- `bytes routeData`
- `ClprControlEnvelope control`

Rationale:

- Keep route header and control data distinct.
- Avoid overloading `data` with both routing and control protocol bytes.

## 3.2 `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`

Add middleware funding APIs and control synchronization entrypoints.

### New external APIs

- `function topUpConnectorNative(bytes32 connectorId) external payable;`
- `function topUpConnectorToken(bytes32 connectorId, address token, uint256 amount) external;`
- `function connectorFundingState(bytes32 connectorId) external view returns (ClprTypes.ClprFundingState state, uint64 epoch);`
- `function localFundingLedger(bytes32 connectorId) external view returns (uint256 availableBalance, uint256 safetyThreshold, string memory unit, uint64 epoch, ClprTypes.ClprFundingState state);`
- `function publishConnectorFundingState(bytes32 connectorId) external;`

### Event additions

- `event ConnectorFunded(bytes32 indexed connectorId, address indexed funder, address token, uint256 amount, uint256 availableAfter, uint64 epoch);`
- `event ConnectorFundingStateTransition(bytes32 indexed connectorId, ClprTypes.ClprFundingState fromState, ClprTypes.ClprFundingState toState, uint64 epoch);`
- `event ConnectorFundingStatePublished(bytes32 indexed connectorId, uint64 epoch, bytes32 remoteLedgerId);`
- `event RemoteFundingStateApplied(bytes32 indexed connectorId, uint64 epoch, ClprTypes.ClprFundingState state, uint256 availableBalance, uint256 safetyThreshold);`

## 3.3 `contracts/solidity/clpr/interfaces/IClprConnector.sol`

In middleware-managed model, connectors are policy modules, not fund custodians.

### Changes

- Keep `minimumCharge()`, `maximumCharge()`, `authorize()`, `handleMessage()`, etc.
- Modify semantics of `getBalanceReport(outstandingCommitments)`:
  middleware may ignore connector-reported available balance and substitute middleware ledger values.
- Optionally add:
  `function fundingPolicy() external view returns (uint256 safetyThreshold, string memory unit);`

No connector transfer/funding API required in this model.

## 3.4 `contracts/solidity/clpr/interfaces/IClprQueue.sol`

No signature changes required.

Control envelopes use existing `enqueueMessage` and `enqueueMessageResponse` flows.

## 4. New Internal State (Middleware)

Add to `ClprMiddleware.sol`:

- `mapping(bytes32 => uint256) localAvailableBalanceByConnector;`
- `mapping(bytes32 => uint256) localSafetyThresholdByConnector;`
- `mapping(bytes32 => string) localUnitByConnector;`
- `mapping(bytes32 => uint64) fundingEpochByConnector;`
- `mapping(bytes32 => ClprTypes.ClprFundingState) fundingStateByConnector;`
- `mapping(bytes32 => uint64) lastPublishedEpochByConnector;`
- `mapping(bytes32 => uint64) lastAppliedRemoteEpochByDestinationConnector;`
- `mapping(bytes32 => bool) pendingFundingPublishByConnector;`

Reuse existing:

- `remoteStatusByDestinationConnector`
- `outstandingCommitmentsByDestinationConnector`

## 5. State Machine

## 5.1 Local funding state per connector

States:

- `UNDERFUNDED` when `availableBalance <= safetyThreshold`
- `AVAILABLE` when `availableBalance > safetyThreshold`

Transitions:

- `UNDERFUNDED -> AVAILABLE`: increment epoch, mark publish pending.
- `AVAILABLE -> UNDERFUNDED`: increment epoch, mark publish pending (optional but recommended).
- Same-state changes: no epoch increment, no publish.

## 5.2 Remote cache apply rules

On inbound control update:

- Reject if connector not paired/known.
- Reject if `incomingEpoch <= lastAppliedRemoteEpoch` (stale/duplicate).
- Apply `remoteStatusByDestinationConnector` values.
- Update `lastAppliedRemoteEpoch`.
- Clear/set `remote.unavailable` based on state.

Idempotency is guaranteed by epoch monotonicity.

## 6. Control Message Logic

## 6.1 Publish trigger

Publish when either transition occurs; minimum required by this user story is `UNDERFUNDED -> AVAILABLE`.

Suggested policy:

- Always publish both transition directions for deterministic remote behavior.
- Enforce cooldown window to avoid spam from fragmented top-ups.

## 6.2 Control payload build

Middleware builds a `ClprMessage` with:

- `applicationMessage.recipientId = address(0)` sentinel for middleware-control path.
- `middlewareMessage.control.controlType = ConnectorFundingStateUpdate`
- `middlewareMessage.control.payload = abi.encode(ClprFundingStateUpdate{...})`
- Route header in `middlewareMessage.routeData`.

Destination middleware `handleMessage` must route control envelopes before application dispatch.

## 7. Call Flows

## 7.1 One connector drops below threshold, then gets topped up

1. `send()` attempts through connector pair `A2 -> B2`.
2. Destination middleware charges `B2`; local available falls to threshold.
3. Destination middleware transitions B2 `AVAILABLE -> UNDERFUNDED`, epoch increments, publishes state update to source.
4. Source applies remote state; subsequent `send()` pre-rejects connector 2.
5. Operator calls `topUpConnector*` on destination middleware for B2.
6. Destination middleware updates available balance and detects `UNDERFUNDED -> AVAILABLE`.
7. Destination publishes control update with new epoch.
8. Source applies update; connector 2 is eligible again.
9. Next source send can authorize/enqueue through connector 2.

## 7.2 Both connectors drop below threshold at same time

1. Both pairs `A2` and `B2` independently transition to `UNDERFUNDED`; each side publishes state update.
2. Both source-side middleware caches mark remote connector underfunded; both sides pre-reject traffic via connector 2.
3. Operator tops up only `A2` first:
   - A middleware transitions `UNDERFUNDED -> AVAILABLE`, publishes update to B.
   - B cache sees remote available but local `B2` still underfunded, so B still cannot send via B2.
4. Operator tops up `B2`:
   - B publishes `UNDERFUNDED -> AVAILABLE` to A.
   - A now sees remote available; both directions restored.

This breaks the deadlock deterministically without polling.

## 8. Edge Cases and Handling

- Duplicate control messages: ignored via epoch.
- Out-of-order delivery: stale epochs rejected.
- Top-up while already available: no publish.
- Partial top-up below threshold: no state transition, no publish.
- Out-of-band token transfers to connector contract: irrelevant in this model; middleware ledger is source of truth.
- Failed control enqueue: keep `pendingFundingPublishByConnector=true`; retry on next top-up/admin `publishConnectorFundingState`.
- Pair mismatch: reject update if connector pairing metadata mismatches expected remote ledger/connector.

## 9. Files to Add/Modify

Modify:

- `contracts/solidity/clpr/types/ClprTypes.sol`
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
- `contracts/solidity/clpr/interfaces/IClprConnector.sol` (semantics + optional funding policy getter)
- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- `contracts/solidity/clpr/mocks/MockClprConnector.sol` (remove balance-as-truth assumptions)
- `test/solidity/clpr/*.js` and `test/foundry/*.t.sol` for transition and deadlock cases

Add:

- `contracts/solidity/clpr/middleware/lib/ClprFundingControlCodec.sol` (encode/decode helpers)
- `contracts/solidity/clpr/middleware/lib/ClprFundingStateMachine.sol`

## 10. Pros and Cons

### Pros

- Uniform correctness in one place (middleware).
- No dependence on custom connector implementation quality for funding transitions.
- Deterministic control-plane behavior; no polling or heartbeat spend.
- Easy to enforce protocol invariants and audits.

### Cons

- Middleware becomes custody layer (higher security and compliance burden).
- Asset transfer logic expands middleware complexity.
- More invasive change to current connector economic model.
- Larger blast radius if middleware funding logic has defects.

## 11. Fit Assessment

This model is strongest for strict protocol control and uniform behavior, but it is architecturally heavier. It trades connector implementer freedom for central correctness and central custody risk.

