# ISSUE-0301: Extract CLPR Codecs and Slim Delivery Call Orchestration

Status: Done (2026-02-17)

## Objective

Refactor CLPR system-contract delivery path code so codec/parsing logic is separated from orchestration logic.

This implements approved proposal items:
- `2.1 / 1.2.1`
- `2.5 / 2.1`
- `2.10 / 4.2.2`

## Why

Current delivery call classes mix:
- packed byte parsing
- ABI tuple route/header parsing and patching
- orchestration/dispatch flow

This increases duplication, review complexity, and drift risk.

## Scope

Create shared codec utilities and migrate call classes to use them.

### New classes (consensus-node)

- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/codec/ClprPackedInputCodec.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/codec/ClprCanonicalEnvelopeCodec.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/codec/ClprRouteHeaderCodec.java`

### Modified classes (consensus-node)

- `.../clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java`
- `.../clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java`
- (if beneficial for dedup) `.../clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java`
- (if beneficial for dedup) `.../clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java`

### Tests

Add/update unit tests for codecs under:
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/.../exec/systemcontracts/clpr/codec/`

## Acceptance Criteria

1. Delivery call classes no longer own repeated selector prepend/strip helpers and low-level packed parsing.
2. New codec tests cover malformed length, empty payload, and bad route-header decode paths.
3. Existing CLPR translator/system-contract tests remain green.
4. No functional behavior change relative to current integrated pipeline.

## Out of Scope

- Changing CLPR functional semantics.
- Introducing new external dependencies.
- Production hardening beyond current prototype guardrails.

## Implementation Log

- Implemented shared CLPR codec utilities in consensus-node:
  - `.../clpr/codec/ClprPackedInputCodec.java`
  - `.../clpr/codec/ClprCanonicalEnvelopeCodec.java`
  - `.../clpr/codec/ClprRouteHeaderCodec.java`
- Refactored call orchestrators to consume codec utilities and removed inline helper duplication:
  - `.../clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java`
  - `.../clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java`
  - `.../clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java`
  - `.../clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java`
- Added codec tests:
  - `.../test/.../clpr/codec/ClprPackedInputCodecTest.java`
  - `.../test/.../clpr/codec/ClprCanonicalEnvelopeCodecTest.java`
  - `.../test/.../clpr/codec/ClprRouteHeaderCodecTest.java`
- Validation:
  - `./gradlew :app-service-contract-impl:compileJava :app-service-contract-impl:compileTestJava --no-daemon` (pass)
  - `./gradlew :app-service-contract-impl:test --tests '*ClprPackedInputCodecTest' --tests '*ClprRouteHeaderCodecTest' --tests '*ClprCanonicalEnvelopeCodecTest' --no-daemon` (pass)

Completion summary:
- Delivery and enqueue call classes now focus on orchestration and dispatch.
- Packed input parsing, route-header handling, and canonical envelope encode/decode logic were centralized and unit-tested.
