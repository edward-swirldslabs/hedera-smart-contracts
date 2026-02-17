# ISSUE-0305: Add Internal-Only Transaction Abuse Tests for CLPR Internal Operations

Status: Done (2026-02-17)

## Objective

Add regression tests that fail when non-system/user-originated transactions attempt CLPR internal operations.

This implements approved proposal item:
- `2.2 / 1.2.2`

## Why

Internal-only transaction boundaries are critical; regression tests are needed to prevent accidental exposure.

## Scope

Add/extend tests in `../hiero-consensus-node` for:
- `clprEnqueueMessage`
- `clprHandleMessagePayload`
- any other CLPR internal-only operation currently guarded as non-user

Likely file areas:
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/.../handler/`
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/.../handlers/`
- `hedera-node/test-clients/...` if Hapi-level validation is needed

## Acceptance Criteria

1. Tests explicitly assert user-originated attempts are rejected.
2. Tests fail if guard behavior regresses.
3. Existing CLPR unit suites remain green.

## Out of Scope

- Redesigning payer/signature policy TODOs (explicitly denied for this phase).

## Implementation Log

- Added/validated internal-only abuse coverage for CLPR internal transaction handlers:
  - New preHandle/user-transaction rejection test in:
    - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/handlers/ClprMessagePayloadHandlerTest.java`
  - Existing enqueue internal-only guard test was retained and executed:
    - `.../hiero-clpr-interledger-service-impl/.../ClprEnqueueMessageHandlerTest.preHandleThrowsForUserTransaction`
- Validation command:
  - `./gradlew :app-service-contract-impl:test --tests '*ClprMessagePayloadHandlerTest' :hiero-clpr-interledger-service-impl:test --tests '*ClprEnqueueMessageHandlerTest.preHandleThrowsForUserTransaction' --no-daemon` (pass)

Completion summary:
- Internal CLPR operations now have direct regression coverage that fails if user-originated transaction guards regress.
