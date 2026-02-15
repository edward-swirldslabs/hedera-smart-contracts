# ISSUE-0011 Evidence

Date: 2026-02-12

## Summary

ISSUE-0011 completed by expanding consensus-side unit coverage for:

- route-header decode/shape/validation failures in both queue translators,
- callback failure/status mapping in `ClprProcessMessageBundleHandler`,
- unsigned ABI return-type conformance checks.

## Implemented Test Changes

In `../hiero-consensus-node`:

- `hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/clpr/enqueuemessage/ClprQueueEnqueueMessageTranslatorTest.java`
  - added malformed route bytes and wrong tuple-shape cases
  - added uint64 return-type conformance assertion
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseTranslatorTest.java`
  - added zero remote-ledger-id case
  - added malformed route bytes and wrong tuple-shape cases
  - added uint64 return-type conformance assertion
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprProcessMessageBundleHandlerTest.java`
  - added request-callback revert mapping + metadata-preservation case
  - added malformed request callback result -> `CLPR_INVALID_BUNDLE` case
  - added response-callback revert mapping + metadata-preservation case

## Gate Commands and Results

Required ISSUE-0011 commands:

1. `./gradlew :app-service-contract-impl:test --tests '*clpr*' --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 17 tests in 4.9s`
   - Build: `BUILD SUCCESSFUL`

2. `./gradlew :hiero-clpr-interledger-service-impl:test --tests '*clpr*' --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 130 tests in 4.4s`
   - Build: `BUILD SUCCESSFUL`

3. `./gradlew :app-service-contract-impl:test --tests '*ClprQueueEnqueueMessage*' --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 15 tests in 4.7s`
   - Build: `BUILD SUCCESSFUL`

Targeted validation runs (pre-gate):

- `./gradlew :app-service-contract-impl:test --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessage.ClprQueueEnqueueMessageTranslatorTest --tests com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr.enqueuemessageresponse.ClprQueueEnqueueMessageResponseTranslatorTest --no-daemon --console=plain`
  - Result: `SUCCESS: Executed 15 tests in 3.6s`
- `./gradlew :hiero-clpr-interledger-service-impl:test --tests org.hiero.interledger.clpr.impl.test.handler.ClprProcessMessageBundleHandlerTest --no-daemon --console=plain`
  - Result: `SUCCESS: Executed 22 tests in 3.1s`

## Notes

- Wildcard test filters must be quoted in shell commands (e.g., `--tests '*clpr*'`) to avoid shell glob expansion causing false "No tests found" failures.
