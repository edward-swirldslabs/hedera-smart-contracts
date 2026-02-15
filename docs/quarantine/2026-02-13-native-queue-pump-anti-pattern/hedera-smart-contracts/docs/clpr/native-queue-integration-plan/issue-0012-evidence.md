# ISSUE-0012 Evidence

Date: 2026-02-12

## Summary

ISSUE-0012 completed by validating native-queue Hapi E2E coverage with two focused suites:

- `ClprMiddlewareNativeQueueSuite`
  - single-ledger callback failure path
  - asserts callback failure does not advance queue metadata or callback-visible state
- `ClprMiddlewareTwoLedgerNativeQueueSuite`
  - two-ledger request/response round trip
  - asserts destination callback and source response callback behavior

Both suites execute via `:test-clients:testSubprocess` using HAPI/gRPC paths only.

## Gate Commands and Results

Primary ISSUE-0012 gate:

1. `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMiddlewareNativeQueueSuite' --tests 'com.hedera.services.bdd.suites.interledger.ClprMiddlewareTwoLedgerNativeQueueSuite' --rerun-tasks --no-daemon --console=plain`
   - Result: `SUCCESS: Executed 2 tests in 1m 48s`
   - Build: `BUILD SUCCESSFUL in 4m 51s`
   - Artifact: `artifacts/clpr-native-queue/issue-0012/20260212T144802Z/testSubprocess-native-queue.log`

Observed operational note (non-gating, reproducibility caveat):

- A non-`--rerun-tasks` run failed at network startup with
  `NoSuchFileException: build/<network>-test/node0/output/hgcaa.log`
  during subprocess readiness checks.
- Failure artifact:
  - `artifacts/clpr-native-queue/issue-0012/20260212T144718Z/testSubprocess-native-queue.log`

## Acceptance Mapping

- Success path covered:
  - two-ledger request -> destination callback -> response callback.
- Failure path covered:
  - callback revert with explicit metadata non-progression assertions.
- Queue adapter path coverage:
  - both suites run with `contracts.systemContract.clprQueue.enabled=true`.
- HAPI-only path:
  - no JSON-RPC relay dependency in the suite setup/execution path.
