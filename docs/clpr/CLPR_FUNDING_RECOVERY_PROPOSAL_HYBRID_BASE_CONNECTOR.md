# CLPR Funding Recovery Proposal B: Hybrid Model with Mandatory Base Connector Funding Implementation

## 1. Objective

This proposal preserves connector-owned asset custody but removes correctness risk from arbitrary connector implementations by requiring connectors to inherit a canonical base funding implementation.

Primary goals:

- Keep funding and balance truth at connector level (asset-aware, minimal middleware custody risk).
- Standardize threshold transition detection and state reporting via shared base contract logic.
- Trigger low-frequency, transition-only control messages (`UNDERFUNDED -> AVAILABLE` at minimum).
- Restore source middleware eligibility after destination top-up without redeploy/reset.

## 2. Design Summary

- Connectors must extend a new abstract base contract, for example `ClprFundingAwareConnectorBase`.
- Base contract provides canonical deposit/reconcile APIs, funding state machine, epoch tracking, and middleware notification hook.
- Middleware remains protocol orchestrator: when notified, it enqueues a native CLPR control message to remote middleware.
- Remote middleware applies funding-state update with epoch-based idempotency.

This is a split-responsibility model:

- Connector: asset math + threshold transitions.
- Middleware: cross-ledger synchronization + remote cache updates.

## 3. Contract and ABI Changes

## 3.1 `contracts/solidity/clpr/types/ClprTypes.sol`

Same control schema as Proposal A so both approaches share wire compatibility.

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

### `ClprMiddlewareMessage` evolution

Proposed fields:

- `ClprBalanceReport balanceReport`
- `bytes routeData`
- `ClprControlEnvelope control`

## 3.2 `contracts/solidity/clpr/interfaces/IClprConnector.sol`

Add mandatory funding-awareness ABI for compatibility checks and middleware callbacks.

### New methods

- `function fundingState() external view returns (ClprTypes.ClprFundingState);`
- `function fundingEpoch() external view returns (uint64);`
- `function reconcileFundingState() external;`
- `function fundingHooksVersion() external pure returns (uint32);`

### New events

- `event FundingStateTransition(bytes32 indexed connectorId, ClprTypes.ClprFundingState fromState, ClprTypes.ClprFundingState toState, uint64 epoch, uint256 availableBalance, uint256 safetyThreshold);`
- `event FundingNotifiedMiddleware(bytes32 indexed connectorId, uint64 epoch, ClprTypes.ClprFundingState state);`

## 3.3 `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`

Add connector-to-middleware funding transition hook.

### New methods

- `function onConnectorFundingStateTransition(bytes32 connectorId, uint64 fundingEpoch, ClprTypes.ClprFundingState state, ClprTypes.ClprBalanceReport calldata report) external;`
- `function publishConnectorFundingState(bytes32 connectorId) external;`
- `function remoteFundingEpoch(bytes32 destinationConnectorId) external view returns (uint64);`

### Access rule

- `onConnectorFundingStateTransition` callable only by registered connector contract for `connectorId`.

### Event additions

- `event LocalFundingTransitionObserved(bytes32 indexed connectorId, uint64 epoch, ClprTypes.ClprFundingState state);`
- `event FundingControlEnqueued(bytes32 indexed connectorId, uint64 epoch, bytes32 remoteLedgerId);`
- `event RemoteFundingStateApplied(bytes32 indexed connectorId, uint64 epoch, ClprTypes.ClprFundingState state, uint256 availableBalance, uint256 safetyThreshold);`

## 3.4 Base connector contract ABI

Add new abstract contract:

- `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol`

### Canonical funding entrypoints

- `function depositNative() external payable;`
- `function depositToken(uint256 amount) external;`
- `function reconcileFundingState() public virtual override;`

### Internal hooks for custom connectors

- `function _postFundingMaintenance() internal virtual;`
- `function _notifyMiddlewareFundingTransition(ClprTypes.ClprFundingState fromState, ClprTypes.ClprFundingState toState, uint64 epoch) internal;`

### Behavior

- Computes `beforeState` and `afterState` around every deposit/reconcile.
- If state transitioned, increments epoch and notifies middleware.
- If no transition, no notify.

## 3.5 `contracts/solidity/clpr/interfaces/IClprQueue.sol`

No signature changes required.

## 4. New Internal State

## 4.1 In base connector

- `ClprTypes.ClprFundingState _fundingState;`
- `uint64 _fundingEpoch;`
- `uint256 _safetyThreshold;`
- `string _localUnit;`
- `address _middleware;`
- `bool _notifyInProgress;` (reentrancy guard for notify path)

Existing balance reads remain connector-native:

- native balance: `address(this).balance`
- token balance: `IERC20(token).balanceOf(address(this))`

## 4.2 In middleware

- `mapping(bytes32 => uint64) lastObservedLocalFundingEpochByConnector;`
- `mapping(bytes32 => uint64) lastPublishedFundingEpochByConnector;`
- `mapping(bytes32 => uint64) lastAppliedRemoteFundingEpochByDestinationConnector;`
- Reuse `remoteStatusByDestinationConnector` and `outstandingCommitmentsByDestinationConnector`.

## 5. State Machine

## 5.1 Connector-local machine

States:

- `UNDERFUNDED`: `available <= safetyThreshold`
- `AVAILABLE`: `available > safetyThreshold`

Transitions:

- `UNDERFUNDED -> AVAILABLE`: epoch++, notify middleware.
- `AVAILABLE -> UNDERFUNDED`: epoch++, notify middleware (recommended).
- Same-state deposit/reconcile: no epoch change, no notify.

## 5.2 Middleware apply machine

- Accept local transition notify only from registered connector address.
- If `fundingEpoch <= lastObservedLocalFundingEpoch`: ignore duplicate/stale.
- Update local tracking and enqueue control update to remote.
- Remote middleware applies only if `incomingEpoch > lastAppliedRemoteFundingEpoch`.

## 6. Call Flows

## 6.1 One connector drops below threshold then is funded above threshold

### Phase A: drop below threshold

1. Source middleware sends through connector pair `A2 -> B2`.
2. Destination connector `B2` reimburses until `available <= threshold`.
3. `B2` transitions `AVAILABLE -> UNDERFUNDED`, epoch increments, calls `onConnectorFundingStateTransition`.
4. Destination middleware enqueues control update to source.
5. Source applies remote underfunded state and pre-rejects new sends via `A2`.

### Phase B: top-up and restore

1. Operator calls `B2.depositNative()` or `B2.depositToken(amount)`.
2. Base connector computes transition and detects `UNDERFUNDED -> AVAILABLE`.
3. Base connector increments epoch and notifies destination middleware.
4. Destination middleware enqueues control update.
5. Source middleware applies update; `remoteStatusByDestinationConnector[B2]` now available.
6. Next send from source can use connector 2 again.

## 6.2 Both connectors drop below threshold at same time

1. Both connectors transition to `UNDERFUNDED`; each side publishes update.
2. Both source middleware instances pre-reject connector-2 sends.
3. Top-up only `A2` first:
   - `A2` transitions to `AVAILABLE`, publishes to B.
   - B remote cache now sees A available, but local `B2` still underfunded, so B cannot send via `B2`.
4. Top-up `B2`:
   - `B2` publishes availability to A.
   - Both sides now have local+remote available; pair is fully restored.

## 7. Exact Logic and Edge Cases

## 7.1 Direct transfer edge case

ERC20 direct transfer to connector bypasses `depositToken` and therefore bypasses transition logic.

Mitigation:

- Expose `reconcileFundingState()` and require operational tooling to call it when out-of-band transfers are used.
- Encourage canonical deposit APIs for all automated top-ups.

## 7.2 Fragmented top-ups

If multiple small top-ups occur while still underfunded:

- No transition until crossing threshold.
- Only one publish at transition point.

## 7.3 Reorg/replay/duplication

- Epoch-gated application prevents stale duplicates from regressing state.

## 7.4 Connector implementation drift

Mitigation by policy:

- Middleware registration requires `fundingHooksVersion()` match expected value.
- Optionally reject connectors not inheriting required base behavior.

## 7.5 Cross-ledger deadlock concerns

- Control messages are transition-triggered, not periodic.
- Threshold should be configured high enough that one recovery exchange remains economically safe.
- For prototype behavior, middleware control handling should not require destination connector reimbursement.

## 8. Files to Add/Modify

Modify:

- `contracts/solidity/clpr/types/ClprTypes.sol`
- `contracts/solidity/clpr/interfaces/IClprConnector.sol`
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- `contracts/solidity/clpr/mocks/MockClprConnector.sol` (inherit base, remove duplicated transition logic)

Add:

- `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol`
- `contracts/solidity/clpr/middleware/lib/ClprFundingControlCodec.sol`
- `contracts/solidity/clpr/middleware/lib/ClprFundingStateMachine.sol`

Tests:

- New unit tests for base connector transition behavior.
- Middleware tests for hook auth, epoch dedupe, control enqueue/apply.
- Network tests for both required scenarios (single-side and dual-side underfunding).

## 9. Pros and Cons

### Pros

- Preserves connector-owned funds and token/native semantics.
- Standardizes critical transition logic via shared base class.
- Middleware remains protocol layer, not custody layer.
- Lower blast radius than middleware-custody model.

### Cons

- Requires connector developers to inherit base implementation.
- Out-of-band transfers still require `reconcileFundingState()` discipline.
- Slightly more moving parts than pure middleware-central model.

## 10. Fit Assessment

This model best matches the cost-fairness and architectural separation goals:

- No heartbeat/poll cost drain.
- Event-driven, low-frequency control-plane signaling.
- Strong consistency with lower custody/security burden than middleware-managed funds.
- Practical path to enforce universal behavior through required base connector inheritance.

