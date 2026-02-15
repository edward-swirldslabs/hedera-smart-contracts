# ISSUE-0009: Wire Native Bundle Processing to Middleware Contract Callbacks

Status: Completed (2026-02-12, consensus-side callback wiring)

Owner: Unassigned

Depends on:

- ISSUE-0007
- ISSUE-0008

## Goal

When native CLPR processes inbound bundles, invoke Solidity middleware callback entrypoints (`handleMessage`, `handleMessageResponse`) so queue transport drives real middleware/application state transitions.

## Scope

In scope:

- Decode queued payload envelope bytes back into middleware ABI structs.
- Resolve target middleware contract address from envelope/correlation (with configured fallback only where ADR allows).
- On inbound request message:
  - execute middleware `handleMessage(...)`,
  - capture returned response envelope,
  - enqueue response via native queue path.
- On inbound response message:
  - execute middleware `handleMessageResponse(...)`.
- Preserve exactly-once processing assumptions from native queue semantics.
- Support adapter envelope compatibility proven in ISSUE-0007/0008 (no alternate payload format).
- Preserve route-header envelope compatibility from ISSUE-0007/0008 and use it to route callback response payloads.

Out of scope:

- Generalized smart-contract orchestration framework.
- Non-EVM middleware implementations.

## Requirements / References

- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/.../ClprProcessMessageBundleHandler.java`
- CLPR requirements around messaging-to-middleware API (`REQ-MW-042`, `REQ-MW-047`).

## Exactly-Once Callback State Machine (Normative)

- Pre-callback gate:
  - Validate bundle ordering/integrity.
  - Reject duplicate/stale/out-of-order bundles before callback invocation.
- Callback attempt:
  - Invoke `handleMessage(...)` or `handleMessageResponse(...)` exactly once for an accepted bundle.
- Post-callback commit:
  - Advance queue processed/sent tracking only after successful callback outcome.
  - On callback revert/failure, persist deterministic failure outcome without marking the bundle as successfully processed.
- Retry behavior:
  - Retries are driven only by queue semantics for non-committed bundles; no duplicate callback for already committed bundles.

## Acceptance Criteria

- Processing a remote request bundle mutates destination middleware/app state.
- Processing a remote response bundle mutates source middleware/app state.
- Duplicate/out-of-order bundles are still rejected by native queue logic before callback.
- No off-chain JavaScript relayer is required for request/response forwarding.
- Callback failure semantics are deterministic and do not corrupt queue metadata progression.
- Stale/duplicate bundle attempts do not execute middleware callbacks (asserted by callback invocation counters/events).
- Processed markers (or equivalent metadata) are written only after successful callback commit.
- Callback path decodes the same request envelope fields used at enqueue (`version`, `remoteLedgerId`, middleware targets, `callData`) with deterministic validation failures.

## Milestone Exit Criteria (Dependency Gate)

- Callback executor integration is wired and covered for both request and response branches.
- There is an explicit state-machine note describing callback outcomes:
  - success,
  - middleware/application revert,
  - malformed payload,
  - duplicate/out-of-order rejection.
- At least one two-ledger HapiTest proves full request->response cycle with middleware state assertions on both ledgers.
- Callback target resolution order and failure behavior (envelope target missing/invalid) is explicitly tested and documented.
- State-machine tests assert when callback execution is attempted vs skipped and when a bundle is marked committed.
- End-to-end checkpoint note explicitly records whether Solidity route-header population is provided by production middleware (ISSUE-0010) or by temporary test harness payload builders.
- Callback authorization model is explicitly validated in downstream integration issues (ISSUE-0010/0012), since direct synthetic callback dispatch in this issue does not yet guarantee `onlyQueue` middleware authorization.

## Tests

- Unit:
  - Bundle payload decode and callback routing tests.
  - Failure-path tests (callback revert/exception handling).
- Queue metadata integrity tests after callback failure.
- Tests that stale/out-of-order bundles fail before callback execution.
- HapiTest:
  - New suite proving request and response callbacks fire across two ledgers.
- Solo:
  - Two-ledger scenario where source app receives final response via native queue callbacks.

## Expected File Changes

In `../hiero-consensus-node`:

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`
- New CLPR callback executor component, likely under:
  - `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/`
- Smart-contract service integration helpers (if needed) under:
  - `hedera-node/hedera-smart-contract-service-impl/src/main/java/...`
- BDD tests in:
  - `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/`

In `hedera-smart-contracts`:

- No API changes expected.
- Optional additional events in middleware/apps for callback traceability.

## Risk Areas

- Re-entrancy/recursive enqueue patterns if callback flow is not isolated.
- Gas/account context for node-initiated middleware callback execution.
- Failure semantics mismatch between native handler and middleware expectations.

## Completion Notes

- Implemented callback envelope processing in:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`
- Added callback-path unit coverage in:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprProcessMessageBundleHandlerTest.java`
- Evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0009-evidence.md`
- Residual integration explicitly carried into downstream issues:
  - middleware callback authorization alignment (`onlyQueue`) and full end-to-end native callback proof in ISSUE-0010/0012.
