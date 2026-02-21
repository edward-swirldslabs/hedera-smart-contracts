<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLPR Operations

Operational playbook for running, debugging, and maintaining the CLPR two-ledger native messaging scenario.

## Clean Rerun Playbook

Use this when you need a deterministic, clean validation run.

### 1. Remove old run artifacts

```bash
find artifacts/clpr-native-messaging-solo -mindepth 1 -maxdepth 1 -exec rm -rf {} +
```

Verify no old runs remain:

```bash
find artifacts/clpr-native-messaging-solo -mindepth 1 -maxdepth 1 -type d
# Expected: no output
```

### 2. Clean stale Solo deployment metadata

List local deployment configs:

```bash
SOLO_HOME=$HOME/.solo-integration solo deployment config list -c docker-desktop
```

If `solo-int-src` or `solo-int-dst` exist in config but not in Kubernetes, delete them:

```bash
SOLO_HOME=$HOME/.solo-integration solo deployment config delete --deployment solo-int-src -q || true
SOLO_HOME=$HOME/.solo-integration solo deployment config delete --deployment solo-int-dst -q || true
```

### 3. Run the clean rerun

Recommended deterministic command:

```bash
CLPR_SOLO_HOME=$HOME/.solo-integration \
SOLO_HOME=$HOME/.solo-integration \
SOLO_SKIP_CLUSTER_SETUP=true \
SOLO_ENABLE_BLOCK_NODE=true \
SOLO_ENABLE_MIRROR=false \
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build
```

Why these flags:
- `SOLO_SKIP_CLUSTER_SETUP=true`: Avoids concurrent cluster-scoped mutation.
- `SOLO_ENABLE_BLOCK_NODE=true`: Preserves CN→BN observability and tailer artifacts.
- `SOLO_ENABLE_MIRROR=false`: Avoids mirror ingress/RBAC flake when mirror is not under test.
- `--no-build`: Keeps reruns fast when consensus node artifacts are already prepared.

### 4. Validate pass/fail

```bash
run_id=$(ls -1dt artifacts/clpr-native-messaging-solo/* | head -n 1 | xargs basename)
cat "artifacts/clpr-native-messaging-solo/$run_id/scenario.log"
# Expected: Scenario passed
```

### 5. Validate block-stream decode health (if block node enabled)

```bash
for side in src dst; do
  f="artifacts/clpr-native-messaging-solo/$run_id/block-stream-${side}.ndjson"
  n=$(rg -c '"type":"decode_error"' "$f" || true)
  n=${n:-0}
  echo "${side} decode_error=${n}"
done
# Expected: src decode_error=0, dst decode_error=0
```

## Known Failure Signatures and Fixes

### A. Stale deployment config causes setup failures

**Symptom**: Solo reports deployment already exists or setup commands fail before namespace creation.

**Fix**: Delete stale local deployment config entries for `solo-int-src` / `solo-int-dst` (see section 2 above).

### B. Mirror ingress RBAC ownership conflict (mirror-enabled runs)

**Symptom**: Helm install fails due to existing `ClusterRole` or `ClusterRoleBinding` named `mirror-ingress-controller` owned by another namespace/release.

**Fix**:

```bash
kubectl delete clusterrole mirror-ingress-controller --ignore-not-found
kubectl delete clusterrolebinding mirror-ingress-controller --ignore-not-found
```

Then rerun with mirror enabled only if mirror behavior is in scope.

### C. Teardown appears stuck on deleting secrets

**Symptom**: `consensus network destroy` stays on "Deleting Secrets in namespace..." for a while.

**Interpretation**: Usually transient; wait for completion unless hard timeout is exceeded.

### D. Orphaned port-forward processes from prior runs

**Fix**:

```bash
pkill -f 'kubectl port-forward -n solo-int-src' || true
pkill -f 'kubectl port-forward -n solo-int-dst' || true
```

### E. Block-stream tailer reports decode errors

**Symptom**: `decode_error > 0` in `block-stream-*.ndjson` after rerun.

**Checks**:
- Confirm the runner and tailer are using consensus-node protobuf imports (to avoid schema drift).
- Re-run with fresh artifacts after confirming import-path order.

**Escalation**: If decode errors persist, capture the failing run bundle and compare `deployment.json`, `block-stream-*.log`, and `block-stream-*.ndjson`.

### F. Solo cluster context mismatch

**Symptom**: Solo commands fail with connection refused or unreachable endpoint.

**Fix**: The default cluster context is `docker-desktop`. If your cluster is different (e.g., `kind-solo`):

```bash
# Check available contexts
kubectl config get-contexts

# Reconnect Solo cluster-ref
solo cluster-ref config connect -c solo-shared --context kind-solo -q

# Set the override for E2E runs
export SOLO_CLUSTER_CONTEXT=kind-solo
```

## Block-Stream Tailer Usage

The block-stream tailer provides live block-node observability for CLPR-relevant transactions.

### Auto-start (via E2E runner)

`run-e2e.sh` automatically starts two tailers (source + destination) when `CLPR_ENABLE_BLOCK_STREAM_TAILER=true` (default). This requires `SOLO_ENABLE_BLOCK_NODE=true`.

### Manual standalone start

```bash
node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
  --endpoint 127.0.0.1:54080 \
  --label src \
  --start-block 0 \
  --deployment-file artifacts/clpr-native-messaging-solo/<runId>/deployment.json \
  --output-file artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.ndjson
```

### Filter flags

```bash
# Filter by response kind and item kind
--match-response-kind block_items
--match-item-kind event_transaction
--match-keyword clpr

# Emit every frame
--log-all
```

Filter semantics:
- Within one filter type (e.g., multiple `--match-item-kind`): OR matching.
- Across filter types: AND matching.

Runner equivalents (CSV-separated):

```bash
CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS=block_items \
CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS=event_transaction,transaction_result \
CLPR_BLOCK_STREAM_MATCH_KEYWORDS=clpr,enqueue \
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

### NDJSON record types

The tailer emits three record types:

1. **`frame`**: Per-gRPC-response metadata (block number, item count, CLPR relevance)
2. **`block_item`**: Per-block-item detail (item kind, entities, item summary, CLPR relevance)
3. **`decode_error`**: When grpcurl cannot decode a block (cursor, error detail, skip action)

### Query examples

Show only CLPR-relevant block items:

```bash
jq -c 'select(.recordType=="block_item" and .clprRelated==true)' \
  artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.ndjson
```

Frame-level CLPR item counts:

```bash
jq -c 'select(.recordType=="frame") | {blockNumber, clprItemCount, clprItemKinds}' \
  artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.ndjson
```

## Block Node Configuration

### When to enable

Enable block node (`SOLO_ENABLE_BLOCK_NODE=true`) when you need:
- Block-stream tailer observability
- CN→BN→Mirror ingestion path (instead of record-stream→MinIO→Mirror)

### Solo block node deployment

Solo has first-class block-node commands. When block node mapping exists, Solo configures consensus nodes with:
- `blockStream.streamMode=BOTH`
- `blockStream.writerMode=FILE_AND_GRPC`
- `block-nodes.json` with the block node FQDN

### Caveats

- Solo's automatic mirror↔block-node wiring is currently disabled in code (`blockNodeSchemas = []`). When deploying mirror alongside block node, explicit mirror values/env configuration is needed for the `blocknode` importer profile.
- One-shot flows require explicit enablement (`ONE_SHOT_WITH_BLOCK_NODE=true`).
- Mirror readiness can lag while DB migrations complete on fresh deployments.

## JSON-RPC Relay Notes

### Why it is flaky

The JSON-RPC relay depends on Mirror Node for account/alias resolution. When Mirror ingestion stalls (e.g., record stream signature files not produced), the relay rejects transactions with "resource not found" errors even though the consensus node is healthy.

Root cause observed: consensus node produced 10-byte `.rcd.gz` files with no `.rcd_sig` markers, preventing the uploader from sending to MinIO, blocking mirror importer entirely.

### When to use it

- **Prefer native gRPC path** for CLPR correctness testing. The native messaging E2E test (`run-e2e.sh`) uses gRPC exclusively and does not depend on mirror or relay.
- Use JSON-RPC relay only for compatibility checks or when EVM tooling (Hardhat, ethers.js) is specifically under test.
- If relay-based tests fail, use consensus node gRPC as the source of truth and check mirror ingestion health before attributing failures to CLPR middleware.

### Diagnostic commands for stuck mirror ingestion

```bash
# Check mirror importer for "no new signature files"
kubectl -n <ns> logs deploy/mirror-1-importer --tail=200

# Check consensus node record stream file sizes (10-byte files = broken)
kubectl -n <ns> exec network-node1-0 -c root-container -- sh -lc \
  'find /opt/hgcapp/recordStreams -maxdepth 3 -type f -printf "%p %s\n" | sort | tail -n 50'

# Contrast: events streams should be healthy
kubectl -n <ns> exec network-node1-0 -c root-container -- sh -lc \
  'find /opt/hgcapp/eventsStreams -maxdepth 3 -type f -printf "%p %s\n" | sort | tail -n 50'
```

## Preserved Artifacts

Each E2E run should preserve at minimum:

| File | Purpose |
|---|---|
| `scenario.log` | Pass/fail outcome |
| `config-exchange.log` | Bootstrap exchange output |
| `deployment.json` | Contract addresses and ledger IDs |
| `run-manifest.env` | Run parameters |
| `hgcaa-src.log` / `hgcaa-dst.log` | Consensus node logs (CLPR_OBS traces) |
| `swirlds-src.log` / `swirlds-dst.log` | Consensus platform logs |
| `block-stream-src.ndjson` / `block-stream-dst.ndjson` | Block-stream structured feed |
| `block-stream-src.log` / `block-stream-dst.log` | Block-stream tailer process logs |
