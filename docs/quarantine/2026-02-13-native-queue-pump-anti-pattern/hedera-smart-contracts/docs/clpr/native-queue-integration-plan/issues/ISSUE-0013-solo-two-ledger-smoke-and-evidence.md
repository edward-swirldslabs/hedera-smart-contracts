# ISSUE-0013: Solo Two-Ledger Smoke Orchestration and Evidence Capture

Status: Complete (2026-02-13)

Owner: Unassigned

Depends on:

- ISSUE-0012

## Goal

Create a repeatable Solo smoke scenario that deploys contracts to two ledgers, executes the native queue flow through HAPI, and captures proof artifacts for each stage.

## Scope

In scope:

- Orchestration script(s) for:
  - deploying contracts to both ledgers,
  - running required config exchange bootstrap,
  - sending source app transactions via HAPI Ethereum transaction path,
  - asserting destination and source state transitions.
- Evidence capture bundle (tx ids, queue metadata snapshots, contract state queries, relevant pod logs).
- Mandatory preflight + cleanup contract:
  - preflight verifies no concurrent Solo controller is active,
  - preflight verifies required Kubernetes namespaces and service ports are available,
  - preflight verifies custom config includes `contracts.systemContract.clprQueue.enabled=true`,
  - preflight verifies/normalizes subprocess test workspace state (`build/*-test`) to avoid stale log-file startup races,
  - cleanup runs on both success and failure to avoid stale-state contamination.

Out of scope:

- CI-grade stress/perf/chaos test loops.

## Requirements / References

- `docs/clpr/native-queue-integration-plan/solo-custom-build-runbook.md`
- `docs/clpr/SOLO_TWO_NETWORK_CLPR_BRIDGE_NOTES.md`
- HapiTest suites added in ISSUE-0012.

## Acceptance Criteria

- One command executes the two-ledger smoke and returns pass/fail.
- Failure mode captures diagnostics automatically in a timestamped folder.
- Success output shows end-to-end evidence, not only "script exited 0".
- Smoke output identifies each stage checkpoint (deploy, bootstrap, send, destination handle, response deliver) with explicit pass/fail status.
- Invocation/evidence path remains HAPI/gRPC only (no JSON-RPC relay dependency).
- Smoke report separates known Solo operational warnings (such as gRPC-Web endpoint update failures) from true CLPR scenario failures.
- Baseline smoke gate does not depend on long-running `ClprShipOfTheseusSuite`; use focused suites/checkpoints for fast validation.
- Queue checkpoints should be invariant-based (ordering/correlation/emptiness), not tied to synthetic preseeded message counts.
- Smoke runner enforces single-controller assumption (one agent/process owns Solo and cluster lifecycle for the duration of the run).
- Smoke evidence includes explicit callback authorization pass/fail checks for middleware callback operations.
- Smoke setup explicitly includes source connector remote-middleware mapping configuration before first send.
- Smoke includes at least one negative callback checkpoint proving fail-path invariants (queue metadata/correlation state unchanged on callback failure).
- Smoke runbook includes explicit mitigation for intermittent subprocess startup failure
  (`NoSuchFileException: build/<network>-test/node0/output/hgcaa.log`), including clean-build and rerun strategy.

## Milestone Exit Criteria (Dependency Gate)

- `run-two-ledger-smoke.sh` exits non-zero on first failed checkpoint and always writes an evidence bundle.
- Evidence bundle includes at minimum:
  - source and destination transaction ids,
  - HAPI transaction receipts/status for source invoke and callback-side operations,
  - evidence of native queue adapter execution path (queue state deltas and/or adapter selector-path traces),
  - queue metadata before/after snapshots,
  - key contract state assertions,
  - relevant consensus node logs.
- Runbook documents expected runtime and resource prerequisites for a clean run.
- Evidence bundle includes preflight report and cleanup report with pass/fail for each check.
- Evidence bundle includes explicit config snapshot proving `contracts.systemContract.clprQueue.enabled=true` on participating networks.
- Evidence bundle includes callback authorization configuration snapshot (trusted callback caller set/unset and expected behavior).
- Evidence bundle includes fail-path invariants for callback failure checkpoints:
  - expected callback failure status,
  - unchanged queue metadata/correlation snapshots pre/post failure.
- Milestone notes classify known subprocess startup race signatures separately from functional CLPR failures.

## Tests

- Unit:
  - Script utility parsing/tests if present.
- HapiTest:
  - Optional invocation of targeted HapiTest as part of smoke pipeline.
- Solo:
  - Required: full two-ledger smoke run using custom node build and native queue.
  - Required: one clean-slate rerun to verify repeatability and stale-state resistance.
  - Required: preflight failure must abort before deployment and still emit diagnostics.
  - Required: include one execution using startup-race mitigation path (`--rerun-tasks` and/or cleaned `build/*-test`) and record its effect.

## Expected File Changes

In `hedera-smart-contracts`:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh` (new)
- `scripts/clpr/native-queue/deploy-two-ledger-contracts.js` (new, HAPI-driven)
- `scripts/clpr/native-queue/run-source-invocations.js` (new)
- `scripts/clpr/native-queue/collect-evidence.sh` (new)
- `test/network/clpr/native-queue/README.md` (new)

In `../hiero-consensus-node`:

- Optional helper hooks only if required for smoother local test execution.

## Risk Areas

- Solo environment fragility and stale state between runs.
- Insufficient evidence capture to diagnose intermittent failures.
- Control-plane/runtime drift after stop/start operations can invalidate naive health assumptions.

## Progress Notes (2026-02-12)

- Current execution status:
  - In progress, not complete.
- Implemented orchestration artifacts:
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh`
  - `scripts/clpr/native-queue/deploy-two-ledger-contracts.js`
  - `scripts/clpr/native-queue/run-source-invocations.js`
  - `scripts/clpr/native-queue/collect-evidence.sh`
  - `test/network/clpr/native-queue/README.md`
- Implemented bootstrap helper in consensus repo:
  - `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueueBootstrapMain.java`
- Latest observed run state:
  - Preflight and queue enablement checks pass on both namespaces.
  - `:test-clients:compileJava` passes.
  - Bootstrap succeeds and prints both ledger ids.
  - Deploy succeeds on both ledgers via HAPI/gRPC.
  - Round-trip requires an explicit "pump" step that emulates connector delivery:
    - `getMessages(...)` on source, then `clprProcessMessageBundle` on destination
    - `getMessages(...)` on destination, then `clprProcessMessageBundle` on source
  - Assertions must be invariant-based, not tied to message id == 1 (message ids persist across runs for the same ledger id).
## Completion Notes (2026-02-13)

- Smoke runner passes end-to-end in Solo two-ledger setup using HAPI/gRPC only.
- Evidence bundle (PASS):
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/smoke-summary.md`
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/logs/bootstrap.log`
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/logs/deploy.log`
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/logs/pump.log`
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/logs/invoke.log`
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/k8s/src/network-node1-hgcaa.tail.log`
  - `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/k8s/dst/network-node1-hgcaa.tail.log`
