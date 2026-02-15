# Solo Custom Build Runbook (Issue-0002)

Status: Active  
Last updated: 2026-02-12

## Purpose

Bring up two Solo deployments using locally built consensus node artifacts from `../hiero-consensus-node`, with deterministic naming and baseline CLPR-enabled configuration.

## Scripts

- `scripts/clpr/native-queue/solo-two-network-up.sh`
- `scripts/clpr/native-queue/solo-two-network-status.sh`
- `scripts/clpr/native-queue/solo-two-network-down.sh`

## Preconditions

- Solo CLI v0.55.0 is installed.
- Kubernetes context is reachable (default: `docker-desktop`).
- Local consensus artifacts exist at:
  - `../hiero-consensus-node/hedera-node/data`

Quick preflight:

```bash
solo --version
kubectl config current-context
ls -la ../hiero-consensus-node/hedera-node/data
```

## Default Naming

- Cluster ref: `solo-clpr-native`
- Source deployment/namespace: `solo-clpr-native-src`
- Destination deployment/namespace: `solo-clpr-native-dst`

## Bring Up

```bash
scripts/clpr/native-queue/solo-two-network-up.sh
```

Force clean recreation:

```bash
scripts/clpr/native-queue/solo-two-network-up.sh --force
```

## Health Check

```bash
scripts/clpr/native-queue/solo-two-network-status.sh
```

What the status check validates:

- Local deployment config exists for both deployments.
- Namespace exists for each deployment.
- Consensus node pod is running in each namespace.
- `haproxy-node1-svc` exists in each namespace.
- `clpr.clprEnabled=true` can be found in node `application.properties`.

## CLPR Configuration Baseline

The bring-up script uses these config files during network deploy:

- `scripts/clpr/native-queue/config/application-src.properties`
- `scripts/clpr/native-queue/config/application-dst.properties`

Current defaults:

- both ledgers: `clpr.clprEnabled=true`
- source ledger: `clpr.publicizeNetworkAddresses=false`
- destination ledger: `clpr.publicizeNetworkAddresses=true`

## Teardown

```bash
scripts/clpr/native-queue/solo-two-network-down.sh
```

Keep local deployment config entries:

```bash
scripts/clpr/native-queue/solo-two-network-down.sh --keep-config
```

## Restart Validation (Issue-0002 test)

```bash
solo consensus node stop -d "${SOLO_SRC_DEPLOYMENT:-solo-clpr-native-src}" -i "${SOLO_NODE_ALIASES:-node1}" -q
scripts/clpr/native-queue/solo-two-network-status.sh || true
solo consensus node start -d "${SOLO_SRC_DEPLOYMENT:-solo-clpr-native-src}" -i "${SOLO_NODE_ALIASES:-node1}" -q
scripts/clpr/native-queue/solo-two-network-status.sh
```

Expected:

- control-plane phase transitions to `stopped` after stop,
- control-plane phase transitions back toward `configured`/`started` after start,
- status script passes after restart.

Note:

- In this local-build dev mode setup, `solo consensus node stop` does not always immediately terminate the running pod/JVM.
- Use control-plane phase checks for stop/start verification instead of assuming runtime process shutdown.

Control-plane phase check:

```bash
kubectl get configmap solo-remote-config -n "${SOLO_SRC_NAMESPACE:-solo-clpr-native-src}" -o jsonpath='{.data.remote-config-data}' \
  | awk '/consensusNodes:/{f=1} f && /phase:/{print $2; exit}'
```

## Diagnostics Capture

When status fails, collect:

```bash
kubectl get pods -n "${SOLO_SRC_NAMESPACE:-solo-clpr-native-src}" -o wide
kubectl get pods -n "${SOLO_DST_NAMESPACE:-solo-clpr-native-dst}" -o wide
kubectl -n "${SOLO_SRC_NAMESPACE:-solo-clpr-native-src}" logs statefulset/network-node1 --tail=300
kubectl -n "${SOLO_DST_NAMESPACE:-solo-clpr-native-dst}" logs statefulset/network-node1 --tail=300
```

Also inspect run manifests written by `solo-two-network-up.sh`:

- `artifacts/clpr-native-queue/issue-0002/<RUN_ID>/run-manifest.env`

## Known Failure Signatures

- `consensus node start` failure at `set gRPC Web endpoint` with `INVALID_NODE_ID`:
  - Seen during both source and destination bring-up in this environment.
  - Mitigation in script: treat this signature as non-blocking if post-start runtime health checks pass.
