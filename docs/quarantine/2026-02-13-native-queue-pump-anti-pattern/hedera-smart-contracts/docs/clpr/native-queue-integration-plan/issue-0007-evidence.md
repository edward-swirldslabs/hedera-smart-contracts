# ISSUE-0007 Evidence

Date: 2026-02-12

## Scope Completed

- Implemented `enqueueMessage(...)` request path in CLPR queue system-contract adapter:
  - decode `ClprMessage` from calldata,
  - decode route header from `ClprMessage.middlewareMessage.data`,
  - validate route version and remote ledger id,
  - encode request envelope `(uint8,bytes32,address,address,bytes)`,
  - enqueue via `ClprQueueOperations.enqueue(...)`,
  - return ABI-encoded `(uint64)` message id.
- Added writable CLPR store access methods to native operations scope for smart-contract execution.
- Added request-path unit tests for success and typed failure paths.

## Validation Commands

1. Targeted adapter/system-contract tests:

```bash
./gradlew :app-service-contract-impl:test \
  --tests com.hedera.node.app.service.contract.impl.test.exec.processors.ProcessorModuleTest \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.ClprQueueSystemContractTest \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.ClprQueueCallAttemptTest \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessage.ClprQueueEnqueueMessageTranslatorTest \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessageresponse.ClprQueueEnqueueMessageResponseTranslatorTest \
  --no-daemon --console=plain
```

Observed result:

- `SUCCESS: Executed 12 tests in 3.8s`
- `BUILD SUCCESSFUL`

2. CLPR baseline regression gate:

```bash
./gradlew :test-clients:testSubprocess \
  --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite \
  --rerun-tasks --no-daemon --console=plain
```

Observed result:

- `SUCCESS: Executed 1 tests in 47.8s`
- `BUILD SUCCESSFUL in 2m 33s`

## Notable Observations

- ABI numeric typing is strict in adapter/tests:
  - `uint8` encode expects `Integer`,
  - `uint64` encode expects `BigInteger`.
- CLPR queue system contract remains gated by config:
  - `contracts.systemContract.clprQueue.enabled` must be `true` for Hapi/Solo execution paths.
