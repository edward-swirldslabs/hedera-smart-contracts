# CLPR Requirements vs Current Middleware Implementation (Deep Comparison)

Date: 2026-02-18  
Scope: Solidity CLPR middleware implementation in this repository  
Requirements baseline: `hiero-ledger/hiero-consensus-node#23333` docs (head SHA `f4ead8e34b52a96c484a126f09bb4f701f93ace4`)

## Assessment Method

I compared:
- Requirement docs from PR #23333 (`README`, `status`, `iteration-plan`, and all files under `requirements/`)
- Current Solidity implementation and interfaces in `contracts/solidity/clpr/`
- Current contract tests in `test/solidity/clpr/clprMiddleware.js` and `test/foundry/ClprMiddleware.t.sol`

Status legend used below:
- `Implemented` = requirement behavior is present and exercised in current code/tests.
- `Partial` = behavior exists in simplified form, or is missing part of the normative requirement.
- `Not Implemented` = no matching behavior in this repository’s middleware prototype.

## 1) What Is Implemented Effectively

### 1.1 Application-facing semantics are strong

Implemented behaviors include:
- App send API returns `ClprSendMessageStatus` with middleware-assigned `appMsgId` and failure metadata (`contracts/solidity/clpr/types/ClprTypes.sol:84` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:348`).
- Per-application monotonic message IDs for every send attempt, including rejections (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:348`).
- App payload opacity preserved through middleware (`contracts/solidity/clpr/types/ClprTypes.sol:54` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:543`).
- Source app gets response callback with original `appMsgId` (`contracts/solidity/clpr/apps/SourceApplication.sol:163` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:616`).

High-confidence evidence in tests:
- Six-message flow with failover and response callbacks is validated end-to-end in both Hardhat and Foundry suites (`test/solidity/clpr/clprMiddleware.js:348`, `test/foundry/ClprMiddleware.t.sol:280`).

### 1.2 Connector authorization and destination handling are well realized

Implemented behaviors include:
- Source connector authorization gate before enqueue (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:400`).
- Connector deny path correctly blocks enqueue (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:417`).
- Effective max charge = min(application max, connector max) (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:422`).
- Destination connector absence/underfunded checks before app execution (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:480` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:518`).
- Destination connector notification receives `(ClprMessage, ClprMessageResponse, Billing)` and can return connector response (`contracts/solidity/clpr/interfaces/IClprConnector.sol:53` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:697`).
- Reimbursement is synchronous and best-effort non-fatal to flow (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:565`).

### 1.3 Remote funds awareness and pre-enqueue rejection are solid

Implemented behaviors include:
- Source tracks remote connector status from inbound responses (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:722`).
- Source blocks pre-enqueue when it has evidence destination connector is underfunded (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:385`).
- Source notifies source connector when pre-enqueue OOF rejection happens (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:683`).
- Outstanding commitments tracked and reduced on response (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:448` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:590`).

### 1.4 Funding-state transition control plane is robust for prototype goals

Implemented behaviors include:
- Connectors expose funding hooks (`fundingState`, `fundingEpoch`, `reconcileFundingState`) and transition notifications (`contracts/solidity/clpr/interfaces/IClprConnector.sol:77`).
- Base connector implements transition state machine and middleware callback (`contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol:132`).
- Middleware publishes cross-ledger funding updates as control envelopes and applies them with epoch ordering (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:747`, `contracts/solidity/clpr/middleware/ClprMiddleware.sol:833`).
- Topoff recovery and re-deplete behavior is covered in both test stacks (`test/solidity/clpr/clprMiddleware.js:476`, `test/foundry/ClprMiddleware.t.sol:319`).

## 2) What Is Not Yet Implemented

### 2.1 Major unimplemented requirement areas

1. Cryptographic connector identity and protocol create transaction model:
- Not implemented: REQ-CONN-007, 016, 018, 023, 026.
- Current prototype uses direct contract self-registration (`registerConnector`) instead of protocol transaction handlers (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:249`).

2. Message bundles, config-update transport rules, and out-of-band config recovery:
- Not implemented: REQ-MSG-002, 006, 007, 008, 009, 011, 012.
- Current queue abstractions are message-level only (`contracts/solidity/clpr/interfaces/IClprQueue.sol:13`).

3. Typed enqueue failure catalog:
- Not implemented: REQ-MSG-014 and REQ-MW-044.
- Current send path catches enqueue failures without typed reason propagation (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:433`).

4. State proof interfaces and verification model in middleware integration surface:
- Not implemented in this repository: REQ-PROOF-001, 002, 003.

### 2.2 Important partials that still leave behavior gaps

- REQ-MW-010 (value forwarding app -> connector): not present (`send` is non-payable).
- REQ-MW-012 (connector metadata size limits): no explicit limit checks.
- REQ-MW-027 (source connector receives full context on response): current source notification only passes connector response and application response separately, not full `(ClprMessage, ClprMessageResponse, ClprConnectorResponse)` context.
- REQ-MW-049 (mark unavailable and reject further sends): middleware sets `unavailable=true` on `ConnectorAbsent`, but current pre-enqueue gate does not reject on `unavailable` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:664` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:742`).
- REQ-CONN-019 mismatch handling: mismatch currently maps to `ConnectorAbsent` status; explicit mismatch semantics + penalty policy are not fully represented.
- REQ-MSG-001/015/016 strict messaging semantics are only partially modeled by mocks; they are not formalized against real messaging-layer guarantees in this repo.

## 3) What Is Implemented Beyond the Requirements

The current implementation includes capabilities not explicitly required in PR #23333 MVP text:

1. Funding-control message plane with epoch ordering
- `ClprControlEnvelope`, `ConnectorFundingStateUpdate`, `ConnectorFundingStateQuery/Ack` enum values, cross-ledger publish/apply flow.
- Files: `contracts/solidity/clpr/types/ClprTypes.sol:26`, `contracts/solidity/clpr/middleware/ClprMiddleware.sol:747`.

2. Connector base class for funding-aware behavior
- Reusable base with deposit + reconcile + transition callbacks.
- File: `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol`.

3. Explicit route headers embedded in middleware metadata
- Request and response route data ABI-encoded and validated.
- Files: `contracts/solidity/clpr/middleware/ClprMiddleware.sol:656`, `contracts/solidity/clpr/middleware/ClprMiddleware.sol:888`.

4. Optional trusted callback caller
- Middleware supports a trusted callback override in addition to queue contract.
- File: `contracts/solidity/clpr/middleware/ClprMiddleware.sol:236`.

5. Rich observability and scenario behavior
- Extensive events for registration, enqueue, handling, penalties, funding transitions.
- Files: `contracts/solidity/clpr/middleware/ClprMiddleware.sol:137`, `contracts/solidity/clpr/mocks/MockClprConnector.sol:78`, `contracts/solidity/clpr/apps/SourceApplication.sol:57`.

6. Source application connector failover helpers
- `sendWithFailover` and `sendWithFailoverFromFirst` are implementation conveniences beyond minimal requirement wording.
- File: `contracts/solidity/clpr/apps/SourceApplication.sol:115`.

## 4) How To Improve Alignment Between Implementation and Requirements

### 4.1 Resolve requirement-level semantic mismatches

1. Resolve REQ-MW-033 vs REQ-MW-049 tension
- Today REQ-MW-033 says “don’t block unknown/stale”; REQ-MW-049 says block when unavailable/missing.
- Recommendation: clarify precedence rules:
  - Unknown/stale funding data => allow send.
  - Explicit unavailable evidence (e.g., connector_absent response or registry event) => reject send.

2. Clarify mismatch semantics for connector pairing failures
- Add explicit requirement status for connector-pair mismatch vs connector absence, and define required penalty behavior.

3. Clarify how strict “exactly once” applies at middleware boundary vs messaging layer
- Requirements should state which layer owns dedupe/order enforcement and what middleware must verify.

### 4.2 Tighten implementation to declared MVP contract shape

1. Add typed enqueue error propagation path (`REQ-MSG-014`, `REQ-MW-044`).
2. Add connector metadata size-limit checks (`REQ-MW-012`).
3. Implement full-context source connector callback contract (`REQ-MW-027`).
4. Enforce unavailable-based pre-enqueue rejection (`REQ-MW-049`) while preserving unknown/stale allowance (`REQ-MW-033`).

### 4.3 Keep docs synchronized with actual maturity

PR #23333 `status.md` currently says iteration-0 now / iteration-1 next, while this codebase is materially beyond IT1. Update docs so current iteration and behavior baseline are consistent with observed implementation and tests.

## 5) Recommendations To Fill Gaps In Both Requirements and Implementation

### 5.1 Implementation recommendations

1. Add explicit typed send failure for enqueue failures
- Introduce queue-level error enum and return path to map into `ClprSendFailureReason` (or extended failure type).

2. Implement metadata-size validation guardrails
- Bound `connectorMessage.data`, `connectorResponse.data`, and middleware metadata payloads before enqueue/forward.

3. Enforce unavailable connector pre-reject
- Use `remote.unavailable` in pre-enqueue gate with explicit failure reason/side and connector notification.

4. Add context-rich source connector callback
- Extend source connector callback API to include full request/response context; keep current callbacks for backward compatibility only if required.

5. Add targeted regression tests for each gap above
- Both Hardhat and Foundry suites should include explicit pass/fail tests for each requirement delta.

### 5.2 Requirements/documentation recommendations

1. Separate “prototype acceptance” from “production acceptance”
- Add a conformance profile table: prototype-minimum, MVP-strict, production-hardened.

2. Explicitly classify requirement ownership by layer
- Tag each requirement as middleware, messaging layer, connector, protocol transaction handler, or cross-layer.

3. Add an authoritative requirement-to-test matrix with exact test IDs
- Current traceability file is coarse; extend with exact test names and expected signals.

## 6) Proposed Next Increments (Moderate Size, High Value)

### Increment A: Unavailable Connector Semantics Hardening

Goal:
- Fully align with REQ-MW-049 while preserving REQ-MW-033 behavior.

Changes:
- Use `remote.unavailable` as explicit pre-enqueue reject condition.
- Add clear reset behavior when availability is restored.

Value:
- Removes a correctness gap in connector lifecycle behavior.

### Increment B: Typed Queue Failure Surface

Goal:
- Close REQ-MSG-014 and REQ-MW-044.

Changes:
- Add typed enqueue failure catalog in queue interface and middleware mapping.
- Return actionable failure reason to apps/connectors.

Value:
- Better operator diagnostics and deterministic failure semantics.

### Increment C: Connector Metadata Boundaries

Goal:
- Close REQ-MW-012.

Changes:
- Add max-size checks for connector and middleware opaque data fields.
- Add tests for boundary and over-limit rejection behavior.

Value:
- Predictable resource use and safer envelope handling.

### Increment D: Full-Context Source Connector Callback

Goal:
- Close REQ-MW-027.

Changes:
- Add API + middleware callback carrying full response context.
- Keep current callbacks only as compatibility shim if needed.

Value:
- Improves connector auditability, reconciliation, and policy expressiveness.

### Increment E: Requirements/Test Conformance Matrix Upgrade

Goal:
- Improve development steering and review quality.

Changes:
- Add machine-readable matrix (requirement ID -> contract behavior -> test case).
- Add CI checks for matrix drift (missing tests for implemented requirements).

Value:
- Prevents silent divergence between requirement intent and implementation reality.

---

## Coverage Matrix (All Requirement IDs)

### Applications (`applications-interop-contract.md`)

- Implemented: REQ-APP-001, REQ-APP-002, REQ-APP-003, REQ-APP-004, REQ-APP-005, REQ-APP-006, REQ-APP-007, REQ-APP-008, REQ-APP-009, REQ-APP-010, REQ-APP-011, REQ-APP-012, REQ-APP-013
- Partial: REQ-APP-008a (supported behaviorally; no dedicated explicit conformance assertion)
- Not Implemented: none

### Connectors (`connectors-economics-and-behavior.md`)

- Implemented: REQ-CONN-001, REQ-CONN-002, REQ-CONN-004a, REQ-CONN-005a, REQ-CONN-006, REQ-CONN-008, REQ-CONN-011, REQ-CONN-012, REQ-CONN-013, REQ-CONN-014, REQ-CONN-017, REQ-CONN-020, REQ-CONN-025, REQ-CONN-029
- Partial: REQ-CONN-003, REQ-CONN-004, REQ-CONN-005, REQ-CONN-009, REQ-CONN-010, REQ-CONN-015, REQ-CONN-019, REQ-CONN-022, REQ-CONN-024, REQ-CONN-027, REQ-CONN-028
- Not Implemented: REQ-CONN-007, REQ-CONN-016, REQ-CONN-018, REQ-CONN-021, REQ-CONN-023, REQ-CONN-026

### Message Formats (`messaging-message-formats.md`)

- Implemented: REQ-MSG-FMT-001, REQ-MSG-FMT-002, REQ-MSG-FMT-003, REQ-MSG-FMT-004, REQ-MSG-FMT-006, REQ-MSG-FMT-007, REQ-MSG-FMT-008, REQ-MSG-FMT-009, REQ-MSG-FMT-010, REQ-MSG-FMT-011, REQ-MSG-FMT-012, REQ-MSG-FMT-013, REQ-MSG-FMT-014, REQ-MSG-FMT-015, REQ-MSG-FMT-016, REQ-MSG-FMT-017, REQ-MSG-FMT-018, REQ-MSG-FMT-019, REQ-MSG-FMT-021
- Partial: REQ-MSG-FMT-005, REQ-MSG-FMT-020
- Not Implemented: none

### Queue and Bundles (`messaging-queue-and-bundles.md`)

- Implemented: REQ-MSG-003, REQ-MSG-004, REQ-MSG-010
- Partial: REQ-MSG-001, REQ-MSG-005, REQ-MSG-013, REQ-MSG-015, REQ-MSG-016
- Not Implemented: REQ-MSG-002, REQ-MSG-006, REQ-MSG-007, REQ-MSG-008, REQ-MSG-009, REQ-MSG-011, REQ-MSG-012, REQ-MSG-014

### State Proofs (`messaging-state-proofs.md`)

- Implemented: none
- Partial: REQ-PROOF-004 (middleware queue-gating assumes pre-verified input path)
- Not Implemented: REQ-PROOF-001, REQ-PROOF-002, REQ-PROOF-003

### Middleware APIs and Semantics (`middleware-apis-and-semantics.md`)

- Implemented: REQ-MW-001, REQ-MW-002, REQ-MW-004, REQ-MW-005, REQ-MW-006, REQ-MW-007, REQ-MW-008, REQ-MW-009, REQ-MW-011, REQ-MW-013, REQ-MW-013a, REQ-MW-016, REQ-MW-018, REQ-MW-019, REQ-MW-019a, REQ-MW-019b, REQ-MW-019d, REQ-MW-020, REQ-MW-021, REQ-MW-022, REQ-MW-022a, REQ-MW-023, REQ-MW-024, REQ-MW-025, REQ-MW-028, REQ-MW-028a, REQ-MW-029, REQ-MW-030, REQ-MW-031, REQ-MW-032, REQ-MW-032a, REQ-MW-033, REQ-MW-034, REQ-MW-034a, REQ-MW-035, REQ-MW-036, REQ-MW-037, REQ-MW-038, REQ-MW-040, REQ-MW-041, REQ-MW-042, REQ-MW-045, REQ-MW-046, REQ-MW-050, REQ-MW-051, REQ-MW-052, REQ-MW-053, REQ-MW-054, REQ-MW-055
- Partial: REQ-MW-003, REQ-MW-010, REQ-MW-012, REQ-MW-014, REQ-MW-015, REQ-MW-017, REQ-MW-019c, REQ-MW-026, REQ-MW-027, REQ-MW-039, REQ-MW-043, REQ-MW-047, REQ-MW-048
- Not Implemented: REQ-MW-044, REQ-MW-049
