# Config Exchange Baseline Evidence (Issue-0003)

Date: 2026-02-12

Note: This document captures pre-ISSUE-0005 behavior when queue initialization preseeded synthetic messages. After ISSUE-0005, queue-count checkpoints were updated to empty-queue baseline semantics.

## Scope

Baseline validation of native CLPR configuration exchange and queue metadata progression using:

- `ClprMessagesSuite`

The long-running `ClprShipOfTheseusSuite` was intentionally excluded from this baseline gate.

## Commands Used

```bash
cd ../hiero-consensus-node
./gradlew :test-clients:testSubprocess \
  --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite \
  --rerun-tasks --no-daemon --console=plain
```

Executed twice to validate repeatability.

## Evidence Artifacts

- Run #1 log:
  - `artifacts/clpr-native-queue/issue-0003/20260212T045324Z/clpr-messages-testSubprocess-rerun.log`
- Run #2 log:
  - `artifacts/clpr-native-queue/issue-0003/20260212T045626Z/clpr-messages-testSubprocess-rerun2.log`

## Pass/Fail Markers

Run #1:

- `1 passing`: `20260212T045324Z/clpr-messages-testSubprocess-rerun.log:4137`
- `BUILD SUCCESSFUL`: `20260212T045324Z/clpr-messages-testSubprocess-rerun.log:4142`

Run #2:

- `1 passing`: `20260212T045626Z/clpr-messages-testSubprocess-rerun2.log:4127`
- `BUILD SUCCESSFUL`: `20260212T045626Z/clpr-messages-testSubprocess-rerun2.log:4132`

## Configuration Exchange / Queue Checkpoints

Representative Run #1 checkpoints:

- Public network endpoint publication override applied:
  - `...rerun.log:3247` (`clpr.publicizeNetworkAddresses=true`)
- Publish/pull loop starts:
  - `...rerun.log:3283`
- Successful publish/pull checkpoint:
  - `...rerun.log:3289`
- Queue metadata progression observed:
  - `sent id 5`: `...rerun.log:3436`
  - `sent id 10`: `...rerun.log:3660`
  - `sent id 15`: `...rerun.log:3890`
  - `sent id 20`: `...rerun.log:4124`
- Stale bundle protection on already-seen ranges:
  - `...rerun.log:3441`
  - `...rerun.log:3665`
  - `...rerun.log:3894`
- Additional successful publish/pull checkpoints:
  - `...rerun.log:3588`
  - `...rerun.log:3812`
  - `...rerun.log:4045`
  - `...rerun.log:4126`

Representative Run #2 checkpoints (same pattern):

- Successful publish/pull:
  - `...rerun2.log:3278`
  - `...rerun2.log:4044`
  - `...rerun2.log:4118`
- Queue metadata progression:
  - `sent id 5`: `...rerun2.log:3425`
  - `sent id 10`: `...rerun2.log:3649`
  - `sent id 15`: `...rerun2.log:3887`
  - `sent id 20`: `...rerun2.log:4116`

## Known Non-Gating Behaviors Observed

- Periodic `INVALID_TRANSACTION` pre-check stack traces from `ClprSetLedgerConfigurationHandler.pureChecks` during endpoint publish attempts.
- These occur while the suite continues progressing and ultimately passes in both runs.

This baseline treats those events as non-gating for current dev-mode behavior, because:

- queue metadata convergence is observed,
- publish/pull completion checkpoints are observed,
- final suite status is pass.

## Conclusion

Issue-0003 baseline gate is satisfied:

- configuration exchange behavior is exercised and repeatable,
- directional queue synchronization checkpoints are visible in logs,
- two forced reruns complete with passing status.
