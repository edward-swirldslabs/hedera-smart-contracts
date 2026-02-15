# ISSUE-0006 Evidence

Date: 2026-02-12

## Scope Completed

- CLPR queue system-contract scaffolding added in `hiero-consensus-node`:
  - Address mapping at `0x16E`.
  - Config gate `systemContract.clprQueue.enabled`.
  - Call factory + call attempt + translators.
  - Typed revert behavior for disabled gate, unsupported selector, and malformed calldata.
- Selector lock evidence:
  - `enqueueMessage(...)` => `0x8cfaaa60`
  - `enqueueMessageResponse(...)` => `0xb26aa82b`

## Validation Commands

1. Targeted scaffolding tests:

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

- `SUCCESS: Executed 9 tests in 4.3s`
- `BUILD SUCCESSFUL`

2. CLPR baseline regression (required fast gate):

```bash
./gradlew :test-clients:testSubprocess \
  --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite \
  --rerun-tasks --no-daemon --console=plain
```

Observed result:

- `1 passing (47.6s)`
- `BUILD SUCCESSFUL in 2m 12s`

## Implementation Notes

- Known selectors currently route to scaffolding stub reason `CLPR_QUEUE_NOT_IMPLEMENTED`.
- ISSUE-0007 and ISSUE-0008 must replace that stub path with real enqueue behavior via native CLPR queue operations.
