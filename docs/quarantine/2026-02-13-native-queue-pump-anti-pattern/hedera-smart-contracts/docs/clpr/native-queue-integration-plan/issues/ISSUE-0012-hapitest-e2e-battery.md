# ISSUE-0012: HapiTest E2E Battery (Single and Two-Ledger)

Status: Completed (2026-02-12)

Owner: Unassigned

Depends on:

- ISSUE-0009
- ISSUE-0010
- ISSUE-0011

## Goal

Establish HapiTest-level evidence that middleware contract flows operate through native CLPR queue transport without JSON-RPC relay dependency.

Completion summary (2026-02-12):

- Added and validated focused native-queue Hapi suites:
  - single-ledger callback failure/non-progression path,
  - two-ledger request/response round-trip path.
- Ran primary gate command via `:test-clients:testSubprocess` with both suites under
  `contracts.systemContract.clprQueue.enabled=true`.
- Captured durable execution evidence in:
  - `artifacts/clpr-native-queue/issue-0012/20260212T144802Z/testSubprocess-native-queue.log`
  - `docs/clpr/native-queue-integration-plan/issue-0012-evidence.md`

## Scope

In scope:

- Add focused single-ledger HapiTest for enqueue/callback basic flow.
- Add two-ledger HapiTest covering:
  - config sharing bootstrap,
  - source middleware send,
  - destination middleware handling,
  - response delivery back to source.
- Validate connector-aware routing behavior used by current middleware prototype.
- Keep all scenarios on HAPI/gRPC paths without dependency on JSON-RPC relay.
- Scenario setup explicitly configures connector remote middleware mapping on source-ledger middleware before sends.

Out of scope:

- Long-run chaos/performance testing.

## Requirements / References

- Existing suites:
  - `ClprMessagesSuite`
  - `ClprShipOfTheseusSuite`
- CLPR contract semantics in this repo:
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol`

## Gating Policy (Normative)

- Primary execution gate for this issue is `:test-clients:testSubprocess` with explicit `--tests` target.
- `:test-clients:hapiTestMultiNetwork` is non-gating for this issue.
- `ClprShipOfTheseusSuite` is non-gating for this issue (reference only; too long for iterative gate).
- Hapi test configs for this issue must enable CLPR queue system contract:
  - `contracts.systemContract.clprQueue.enabled=true`
- If callback sender differs from queue contract in the test environment, setup must configure trusted callback caller accordingly before callback assertions.

## Acceptance Criteria

- New HapiTests fail on regressions in callback/queue path and pass on correct behavior.
- Tests are deterministic enough for repeated local execution.
- Evidence includes transaction ids and explicit assertions on contract state/events.
- Test scenarios include both success and intentional failure paths (e.g., malformed payload/callback revert) with explicit expected outcomes.
- Test pass/fail classification is based on HAPI transaction outcomes and contract assertions, not Solo gRPC-Web setup side effects.
- At least one scenario asserts native queue adapter path execution (e.g., queue metadata progression and/or selector-path evidence) with `contracts.systemContract.clprQueue.enabled=true`.
- At least one scenario explicitly proves callback authorization compatibility (`onlyQueue`/equivalent) under native callback path.
- Failure-path scenarios explicitly assert queue/correlation non-progression when callback dispatch fails (status propagated, no false success advancement).

## Milestone Exit Criteria (Dependency Gate)

- New suite(s) provide:
  - single-ledger callback flow validation,
  - two-ledger request/response flow validation,
  - at least one failure-path validation.
- Each scenario records queue metadata snapshots and contract-state assertions at named checkpoints.
- Retry/time-window behavior is documented to control flaky timing assertions.
- Milestone evidence clearly distinguishes:
  - baseline CLPR messaging regression (`ClprMessagesSuite`),
  - native queue adapter/callback path coverage (new suites).
- Milestone evidence explicitly states callback caller identity assumptions and where authorization is enforced.
- Milestone evidence includes at least one malformed-payload or malformed-route case with expected status mapping and invariant checks.

## Tests

- Unit:
  - N/A in this issue.
- HapiTest:
  - New suite(s), e.g. `ClprMiddlewareNativeQueueSuite` and `ClprMiddlewareTwoLedgerNativeQueueSuite`.
  - Include checkpoint assertions for enqueue id progression, callback execution, and final response delivery.
  - Primary gate command:
    - `./gradlew :test-clients:testSubprocess --tests '<SuiteClass>' --rerun-tasks --no-daemon --console=plain`
  - Do not assume `:test-clients:hapiTestMultiNetwork` supports `--tests` filtering.
  - Do not rely on historical synthetic queue-id milestones from removed test-seeding behavior.
- Solo:
  - Optional dry-run in local two-network deployment before moving to dedicated Solo issue.

## Expected File Changes

In `../hiero-consensus-node`:

- `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/` (new or updated suites)
- Supporting utility helpers under `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/spec/` if needed.

In `hedera-smart-contracts`:

- Possible ABI artifact or deployment helper updates if HapiTests need contract bytecode/ABI references.

## Risk Areas

- Test flakiness from timing/race in asynchronous queue transport.
- Incomplete assertion coverage causing false positives.
- Environment noise from Solo control-plane quirks obscuring true CLPR behavior unless assertions are anchored to HAPI receipts and queue metadata.

## Completion Notes (2026-02-12)

- Completion state:
  - Completed with focused native-queue Hapi E2E coverage.
- Primary gate command:
  - `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMiddlewareNativeQueueSuite' --tests 'com.hedera.services.bdd.suites.interledger.ClprMiddlewareTwoLedgerNativeQueueSuite' --rerun-tasks --no-daemon --console=plain`
- Verified outcomes:
  - Single-ledger callback failure path covered with metadata non-progression assertions.
  - Two-ledger request/response path covered with destination and source callback assertions.
  - HAPI/gRPC-only path validated with queue system contract enabled.
- Evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0012-evidence.md`
  - `artifacts/clpr-native-queue/issue-0012/20260212T144802Z/testSubprocess-native-queue.log`
- Notes:
  - Non-gating startup race (`NoSuchFileException` in subprocess logs) is documented in the evidence file and addressed as mitigation input for ISSUE-0013 orchestration.
