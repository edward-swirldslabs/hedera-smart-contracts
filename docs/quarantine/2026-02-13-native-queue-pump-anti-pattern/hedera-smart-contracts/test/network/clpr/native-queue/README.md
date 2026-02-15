# Native Queue Two-Ledger Smoke

This directory documents the Solo smoke scenario for native CLPR queue integration.

## Purpose

- Validate the end-to-end callback path across two separate CLPR-enabled ledgers.
- Keep execution on HAPI/gRPC paths only (no JSON-RPC relay dependency).
- Produce a timestamped evidence bundle for both success and failure runs.

## One-Command Smoke

From repository root:

```bash
export CLPR_SRC_OPERATOR_KEY='<src-operator-key>'
export CLPR_DST_OPERATOR_KEY='<dst-operator-key>'
scripts/clpr/native-queue/run-two-ledger-smoke.sh
```

## What The Runner Does

1. Runs Solo preflight/status checks for both ledgers.
2. Verifies `contracts.systemContract.clprQueue.enabled=true` in both deployments.
3. Opens gRPC port-forwards to each ledger.
4. Runs CLPR bootstrap via `ClprNativeQueueBootstrapMain` in `hiero-consensus-node`:
   - local config proof fetch,
   - cross-ledger config submission,
   - remote config visibility wait,
   - queue metadata initialization.
5. Deploys `ClprMiddlewareHarness` contracts to each ledger via HAPI.
6. Sends one source message via HAPI.
7. Pumps native-queue message bundles (emulates connector delivery) via `ClprNativeQueuePumpMain` in `hiero-consensus-node`.
8. Waits for:
   - destination `handleMessage` callback state,
   - source `handleMessageResponse` callback state.
9. Collects evidence under:
   - `artifacts/clpr-native-queue/issue-0013/<RUN_ID>/`

## Key Evidence Files

- `bootstrap.log`
- `deploy.log`
- `pump.log`
- `invoke.log`
- `deployment.json`
- `invoke-result.json`
- `k8s/src/network-node1-root.log`
- `k8s/dst/network-node1-root.log`
- `k8s/src/network-node1-hgcaa.tail.log`
- `k8s/dst/network-node1-hgcaa.tail.log`
- `k8s/src/network-node1-swirlds.tail.log`
- `k8s/dst/network-node1-swirlds.tail.log`
- `smoke-summary.md`

## Notes

- The runner enforces a single-controller assumption for Solo lifecycle ownership.
- Startup race mitigation for Gradle subprocess artifacts is applied with `--rerun-tasks`.
- Assertions are invariant-based (payload correlation) and do not assume message id starts at 1.
