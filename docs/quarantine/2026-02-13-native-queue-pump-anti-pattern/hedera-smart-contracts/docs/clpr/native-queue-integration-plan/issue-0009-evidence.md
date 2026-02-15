# ISSUE-0009 Evidence

Date (UTC): 2026-02-12T06:31:11Z  
Consensus repo head during validation: `f84a46c99e`

## Implemented Files

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/module-info.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprProcessMessageBundleHandlerTest.java`

## Validation Commands

1. Callback handler unit tests

```bash
./gradlew :hiero-clpr-interledger-service-impl:test \
  --tests org.hiero.interledger.clpr.impl.test.handler.ClprProcessMessageBundleHandlerTest \
  --no-daemon --console=plain
```

Result:

- `SUCCESS: Executed 19 tests in 3.1s`
- `BUILD SUCCESSFUL`

2. Queue translator unit tests (native queue adapter envelope path)

```bash
./gradlew :app-service-contract-impl:test \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessage.ClprQueueEnqueueMessageTranslatorTest \
  --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessageresponse.ClprQueueEnqueueMessageResponseTranslatorTest \
  --no-daemon --console=plain
```

Result:

- `SUCCESS: Executed 10 tests in 3.3s`
- `BUILD SUCCESSFUL`

3. Baseline CLPR regression (required fast gate)

```bash
./gradlew :test-clients:testSubprocess \
  --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite \
  --rerun-tasks --no-daemon --console=plain
```

Result:

- `SUCCESS: Executed 1 tests in 47.7s`
- `BUILD SUCCESSFUL in 2m 52s`

## Notes

- A parallel attempt to run translator tests at the same time as `:test-clients:testSubprocess` failed in `:hapi:generatePbjSource` due generated-source directory contention.  
  Fix: run the translator command sequentially (alone), which passed.
