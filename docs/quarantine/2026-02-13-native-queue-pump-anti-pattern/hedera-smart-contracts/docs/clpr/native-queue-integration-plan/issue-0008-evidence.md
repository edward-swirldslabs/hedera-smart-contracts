# ISSUE-0008 Evidence

Date: 2026-02-12

## Scope Completed

- Implemented `enqueueMessageResponse(...)` response path in CLPR queue system-contract adapter:
  - decode `ClprMessageResponse` from calldata,
  - validate `original_message_id` (`>0`),
  - decode response route header from `middlewareResponse.middlewareMessage.data`,
  - validate route version and remote ledger id,
  - encode response envelope `(uint8,address,bytes)`,
  - enqueue via `ClprQueueOperations.enqueue(...)`,
  - return ABI-encoded `(uint64)` message id.
- Added response-path unit tests for success and typed failure paths.
- Verified no regression in CLPR baseline Hapi suite.

## Validation Commands

1. Targeted response/request translator tests:

```bash
./gradlew :app-service-contract-impl:test \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessageresponse.ClprQueueEnqueueMessageResponseTranslatorTest \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessage.ClprQueueEnqueueMessageTranslatorTest \
  --no-daemon --console=plain
```

Observed result:

- `SUCCESS: Executed 10 tests in 3.4s`
- `BUILD SUCCESSFUL`

2. CLPR baseline regression gate:

```bash
./gradlew :test-clients:testSubprocess \
  --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite \
  --rerun-tasks --no-daemon --console=plain
```

Observed result:

- `SUCCESS: Executed 1 tests in 47.8s`
- `BUILD SUCCESSFUL in 2m 26s`

## Notable Observations

- Response-path routing currently depends on route-header bytes included in the response payload.
- Correlation-state lookup by `original_message_id` is deferred to callback integration work in ISSUE-0009.
- Baseline `ClprMessagesSuite` pass alone is a non-regression signal; it does not by itself prove queue system-contract path execution unless `contracts.systemContract.clprQueue.enabled=true` and native queue selectors are invoked in test flow.
