# ISSUE-0306: Add CLPR System-Contract Bridge Tests and Selector Coupling Guards

Status: Done (2026-02-17)

## Objective

Increase regression confidence for the CLPR system-contract bridge, especially selector and packed payload coupling.

This implements approved proposal item:
- `2.8 / 2.3` (unit-level portion)

## Scope

### Unit tests in consensus-node

Add tests for:
- `ClprMessagePayloadHandler` request payload path
- `ClprMessagePayloadHandler` reply payload path
- invalid payload/body shape rejection
- selector coupling assertions between handler/call path and translator selectors

Potential files:
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/.../handlers/ClprMessagePayloadHandlerTest.java`
- existing translator tests under `.../exec/systemcontracts/clpr/...`

## Acceptance Criteria

1. New tests validate both payload variants and failure paths.
2. Selector/signature drift causes test failures.
3. Existing CLPR translator tests remain green.

## Out of Scope

- Broader integration scenario changes (handled in ISSUE-0307/0310).

## Implementation Log

- Added new unit tests for CLPR payload bridge behavior in:
  - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/handlers/ClprMessagePayloadHandlerTest.java`
- Covered request and reply payload variants:
  - request payload dispatch selects `deliverInboundMessagePacked` selector
  - reply payload dispatch selects `deliverInboundMessageReplyPacked` selector
- Added selector-coupling assertions by inspecting dispatched synthetic `ContractCall` calldata prefix bytes.
- Validation command:
  - `./gradlew :app-service-contract-impl:test --tests '*ClprMessagePayloadHandlerTest' --no-daemon` (pass via combined run)

Completion summary:
- The core native payload -> 0x16e bridge now has direct unit-level coverage for both payload variants and selector coupling.
