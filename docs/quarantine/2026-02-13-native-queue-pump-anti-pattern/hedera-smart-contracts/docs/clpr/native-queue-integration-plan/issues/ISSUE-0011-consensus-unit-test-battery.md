# ISSUE-0011: Consensus-Side Unit Test Battery for Queue Adapter

Status: Completed (2026-02-12)

Owner: Unassigned

Depends on:

- ISSUE-0006
- ISSUE-0007
- ISSUE-0008
- ISSUE-0009

## Goal

Add a comprehensive unit-test battery in `hiero-consensus-node` that verifies system-contract decoding, native queue state transitions, callback execution boundaries, and failure semantics.

## Scope

In scope:

- System-contract selector, calldata, and return-value tests.
- Queue append/running-hash correctness tests.
- Invalid payload and revert-mapping tests.
- Callback failure tests (middleware revert, malformed payload, missing contract target).

Out of scope:

- End-to-end two-network orchestration.

## Requirements / References

- CLPR requirements: `REQ-MW-041`, `REQ-MW-042`, `REQ-MW-047`, `REQ-MSG-015`, `REQ-MSG-016`
- Existing system-contract test patterns in HTS/HAS/HSS modules.

## Acceptance Criteria

- Unit tests cover all new selectors and primary error conditions.
- Coverage includes happy path + malformed payload + callback failure + duplicate handling.
- Test suite is stable and fast enough for frequent local runs.
- Tests clearly separate adapter-layer failures from CLPR-handler failures to reduce debugging ambiguity.
- Adapter tests include ABI type-conformance checks for unsigned values used in envelopes and return values.
- Handler tests explicitly cover callback authorization outcomes (`authorized`, `unauthorized`) and resulting queue metadata behavior.
- Unit matrix includes route-header decode failures for both request and response envelopes (`bad bytes`, wrong tuple shape, unsupported version, zero remote ledger id).

## Milestone Exit Criteria (Dependency Gate)

- A test matrix document maps each new behavior to at least one unit test class.
- Unit suite includes deterministic fixtures for request and response payloads reused in higher-level tests.
- Required unit command set and expected runtime envelope are documented for repeatable local verification.
- Fixtures include locked selector/hash vectors from `queue-adapter-design-notes.md`.
- Matrix includes callback caller-identity assumptions and expected status mapping (e.g., middleware revert vs invalid bundle decode).
- Matrix includes explicit assumptions for:
  - source connector remote middleware mapping present/missing,
  - trusted callback caller configured/unconfigured.

## Required Behavior-to-Test Matrix (Initial Skeleton)

- Selector/address routing and collision checks:
  - `ClprQueueSystemContractRoutingTest`
- Request decode/enqueue happy + malformed calldata:
  - `ClprQueueEnqueueMessageTranslatorTest`
- Response decode/enqueue + correlation validation:
  - `ClprQueueEnqueueMessageResponseTranslatorTest`
  - Phase split requirement:
    - phase 1 asserts ISSUE-0008 route-header + `original_message_id` structural validation,
    - phase 2 asserts ISSUE-0009 correlation-state lookup behavior.
- Route-header decode/validation and envelope fidelity:
  - `ClprQueueEnqueueMessageTranslatorTest` (request)
  - `ClprQueueEnqueueMessageResponseTranslatorTest` (response)
- Native enqueue metadata/running-hash invariants:
  - `ClprQueueOperationsTest`
- Bundle callback success/failure and exactly-once commit rules:
  - `ClprProcessMessageBundleHandlerTest`
  - include explicit callback auth guard cases

## Required Unit Commands (Gate Inputs)

- `./gradlew :app-service-contract-impl:test --tests *clpr* --no-daemon --console=plain`
- `./gradlew :hiero-clpr-interledger-service-impl:test --tests *clpr* --no-daemon --console=plain`
- `./gradlew :app-service-contract-impl:test --tests *ClprQueueEnqueueMessage* --no-daemon --console=plain`

## Tests

- Unit:
  - New test classes under smart-contract-service and CLPR handler modules.
  - Command examples are documented for targeted runs and full module runs.
- HapiTest:
  - N/A in this issue.
- Solo:
  - N/A in this issue.

## Expected File Changes

In `../hiero-consensus-node`:

- `hedera-node/hedera-smart-contract-service-impl/src/test/java/.../systemcontracts/clpr/` (new tests)
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/.../handlers/` (new tests)
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/.../` (new codec/adapter tests)

In `hedera-smart-contracts`:

- No changes required.

## Risk Areas

- Fragile tests tied to implementation internals instead of contract behavior.
- Missing edge-case coverage for ABI decoding and correlation fields.

## Completion Notes

- Added missing adapter negative-path unit tests for route-header decoding and validation:
  - malformed route header bytes -> `CLPR_QUEUE_BAD_ROUTE_ENVELOPE`
  - wrong route-header tuple shape -> `CLPR_QUEUE_BAD_ROUTE_ENVELOPE`
  - response zero remote-ledger-id -> `CLPR_QUEUE_INVALID_REMOTE_LEDGER_ID`
- Added explicit ABI unsigned-type conformance checks for `uint64` return values in queue adapter translators.
- Added callback failure/status-mapping handler tests for request and response callback paths:
  - callback revert status is propagated as `HandleException.status`
  - queue metadata remains unchanged when callback fails
  - malformed callback return payload maps to `CLPR_INVALID_BUNDLE`
- Completed command gate matrix with quoted wildcard patterns to avoid shell expansion issues.
- Evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0011-evidence.md`
