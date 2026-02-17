<!-- SPDX-License-Identifier: Apache-2.0 -->

# Native Messaging SOLO Clean Rerun Playbook

## Purpose

Use this playbook when an agent needs a deterministic, clean validation run of the two-ledger native messaging scenario and wants artifacts that are easy to compare between runs.

This captures the working sequence validated on **2026-02-16** with:

- `Scenario passed`
- `decode_error=0` in both block-stream tailer feeds

Evidence run:

- `artifacts/clpr-native-messaging-solo/20260216T210811Z/`

## Preconditions

- Repo root: `hedera-smart-contracts`
- Solo CLI available (`solo --version` -> `0.55.0`)
- `docker-desktop` Kubernetes context active
- Consensus node local build artifacts already available when using `--no-build`

## 1) Remove old run artifacts

```bash
find artifacts/clpr-native-messaging-solo -mindepth 1 -maxdepth 1 -exec rm -rf {} +
```

Validation:

```bash
find artifacts/clpr-native-messaging-solo -mindepth 1 -maxdepth 1 -type d
```

Expected: no output before the new run starts.

## 2) Clean stale local SOLO deployment metadata (if present)

List local deployment configs:

```bash
CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_HOME=$HOME/.solo-integration \
  solo deployment config list -c docker-desktop
```

If `solo-int-src` or `solo-int-dst` exist in config but not in Kubernetes, delete stale entries:

```bash
CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_HOME=$HOME/.solo-integration \
  solo deployment config delete --deployment solo-int-src -q || true

CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_HOME=$HOME/.solo-integration \
  solo deployment config delete --deployment solo-int-dst -q || true
```

## 3) Run the clean rerun

Recommended deterministic run for native messaging verification:

```bash
CLPR_SOLO_HOME=$HOME/.solo-integration \
SOLO_HOME=$HOME/.solo-integration \
SOLO_SKIP_CLUSTER_SETUP=true \
SOLO_ENABLE_BLOCK_NODE=true \
SOLO_ENABLE_MIRROR=false \
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build
```

Why these flags:

- `SOLO_SKIP_CLUSTER_SETUP=true` avoids concurrent cluster-scoped mutation.
- `SOLO_ENABLE_BLOCK_NODE=true` preserves CN->BN observability and tailer artifacts.
- `SOLO_ENABLE_MIRROR=false` avoids mirror ingress/RBAC flake in this lane when mirror is not under test.
- `--no-build` keeps reruns fast when CN artifacts are already prepared.

## 4) Validate pass/fail and decode health

Find the only run directory:

```bash
ls -1dt artifacts/clpr-native-messaging-solo/* | head -n 1
```

Check scenario outcome:

```bash
cat artifacts/clpr-native-messaging-solo/<runId>/scenario.log
```

Expected:

```text
Scenario passed
```

Check block-stream decode errors:

```bash
for side in src dst; do
  f="artifacts/clpr-native-messaging-solo/<runId>/block-stream-${side}.ndjson"
  n=$(rg -c '"type":"decode_error"' "$f" || true)
  n=${n:-0}
  echo "${side} decode_error=${n}"
done
```

Expected:

- `src decode_error=0`
- `dst decode_error=0`

Optional quick feed sanity:

```bash
for side in src dst; do
  f="artifacts/clpr-native-messaging-solo/<runId>/block-stream-${side}.ndjson"
  echo "$side lines=$(wc -l < "$f" | tr -d ' ')"
done
```

## 5) Known failure signatures and fixes

### A) Stale deployment config causes setup failures

Symptom:

- Solo reports deployment already exists or setup commands fail before namespace creation.

Fix:

- Delete stale local deployment config entries for `solo-int-src` / `solo-int-dst` (Section 2).

### B) Mirror ingress RBAC ownership conflict (mirror-enabled runs)

Symptom:

- Helm install fails due to existing `ClusterRole` or `ClusterRoleBinding` named `mirror-ingress-controller` owned by another namespace/release.

Fix:

```bash
kubectl delete clusterrole mirror-ingress-controller --ignore-not-found
kubectl delete clusterrolebinding mirror-ingress-controller --ignore-not-found
```

Then rerun with mirror enabled only if mirror behavior is in scope.

### C) Teardown appears stuck on deleting secrets

Symptom:

- `consensus network destroy` stays on `Deleting Secrets in namespace ...` for a while.

Interpretation:

- Usually transient; wait for completion unless hard timeout is exceeded.

### D) Orphaned local port-forward processes from prior runs

Cleanup:

```bash
pkill -f 'kubectl port-forward -n solo-int-src' || true
pkill -f 'kubectl port-forward -n solo-int-dst' || true
```

### E) Block-stream tailer still reports decode errors

Symptom:

- `decode_error > 0` in `block-stream-*.ndjson` after rerun.

Checks:

- Confirm the runner and tailer are using consensus-node protobuf imports first (to avoid schema drift against current CN block item encoding):
  - `scripts/clpr/native-messaging-solo/run-e2e.sh`
  - `scripts/clpr/native-messaging-solo/block-stream-tailer.js`
- Re-run with fresh artifacts after confirming import-path order.

Escalation:

- If decode errors persist even with the expected import ordering, capture the failing run bundle and compare:
  - `deployment.json`
  - `block-stream-src.log`
  - `block-stream-dst.log`
  - `block-stream-src.ndjson`
  - `block-stream-dst.ndjson`

## 6) Expected artifacts to preserve

In `artifacts/clpr-native-messaging-solo/<runId>/` keep at minimum:

- `scenario.log`
- `config-exchange.log`
- `block-stream-src.ndjson`
- `block-stream-dst.ndjson`
- `block-stream-src.log`
- `block-stream-dst.log`
- `hgcaa-src.log`
- `hgcaa-dst.log`
- `swirlds-src.log`
- `swirlds-dst.log`
- `deployment.json`
- `run-manifest.env`

## 7) Related docs

- `docs/clpr/README.md`
- `docs/clpr/BLOCK_STREAM_TAILER_RUNBOOK.md`
- `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md`
- `docs/clpr/block-node-solo-viability-2026-02-16.md`
- `docs/clpr/native-messaging-solo-integration-plan/README.md`
