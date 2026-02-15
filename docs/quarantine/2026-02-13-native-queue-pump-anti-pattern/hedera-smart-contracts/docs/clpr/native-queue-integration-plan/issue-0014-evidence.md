# ISSUE-0014 Evidence

Date: 2026-02-13

## Summary

ISSUE-0014 hardening/cleanup is complete by:

- Removing temporary debug marker patterns from both repos.
- Hardening Solo smoke evidence collection to be best-effort and include consensus file logs.
- Updating docs/runbooks to match the implemented two-ledger Solo native-queue smoke workflow.
- Recording a regression run matrix across Solidity tests, Java unit tests, HapiTest subprocess suites, and Solo smoke.

## Cleanup Verification

Temporary debug markers:

1. `rg "TEMP-DEBUG\\(CLPR-NQ-" .` (both repos)
   - Result: no matches
2. `rg "TEMP DEBUG|TEMP-DEBUG" ...`
   - Result: no matches in native-queue implementation/test code (plan docs may still reference the strings in acceptance text)

## Regression Commands and Results

hedera-smart-contracts (this repo):

1. `npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat`
   - Result: `5 passing`
2. `forge test --match-path test/foundry/ClprMiddleware.t.sol`
   - Result: `5 passed`

../hiero-consensus-node:

1. Unit (targeted):
   - `./gradlew :hiero-clpr-interledger-service-impl:test --tests '*ClprProcessMessageBundleHandlerTest*' --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 22 tests in 3.4s` (build successful)
2. Unit (targeted, system-contract translators):
   - `./gradlew :app-service-contract-impl:test --tests '*ClprQueueEnqueueMessageTranslatorTest*' --tests '*ClprQueueEnqueueMessageResponseTranslatorTest*' --tests '*ClprQueueCallAttemptTest*' --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 17 tests in 6.2s` (build successful)
3. HapiTest subprocess (targeted):
   - `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMiddlewareTwoLedgerNativeQueueSuite' --rerun-tasks --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 1 tests in 59.2s` (build successful)

Solo (native queue two-ledger smoke, HAPI/gRPC only):

1. `scripts/clpr/native-queue/run-two-ledger-smoke.sh`
   - Result: `PASS`
   - Evidence bundle:
     - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/smoke-summary.md`
