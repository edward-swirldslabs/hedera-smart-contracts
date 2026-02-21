<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLPR Testing

All test instructions for the CLPR middleware, covering single-ledger unit/integration tests and the two-ledger SOLO native messaging E2E test.

## Single-Ledger Tests

These run fast against mocked queue contracts and do not require Kubernetes, Solo, or a consensus node build.

### Hardhat

```bash
npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat
```

**What it tests** (one `describe` block, ~6 `it` cases):
- `rejects middleware deployment with zero queue address` — constructor validation
- `rejects source app deployment with zero middleware address` — constructor validation
- `rejects echo app deployment with zero middleware address` — constructor validation
- `allows configured trusted callback caller in addition to queue` — `trustedCallbackCaller` authorization for native bundle dispatch path
- `rejects direct queue enqueue calls from non-middleware callers` — access control on mock queue
- `sends 3 messages with connector preference + failover and enforces destination funds safety threshold` — the main behavioral test: connector 1 denies, connector 2 accepts then runs out of funds, middleware pre-rejects based on cached remote status, connector 3 picks up

**What you'll see**: Hardhat compiles contracts (first run takes ~30s, subsequent runs use cache), then runs the test suite. Output looks like:

```
  @solidityequiv1 CLPR Middleware MVP Connectors
    ✓ rejects middleware deployment with zero queue address
    ✓ rejects source app deployment with zero middleware address
    ...
    ✓ sends 3 messages with connector preference + failover...

  6 passing (Xs)
```

A passing run takes ~5-15 seconds after compilation.

### Foundry

```bash
forge test --match-path test/foundry/ClprMiddleware.t.sol
```

**What it tests**: The same behavioral coverage as Hardhat — constructor validation, trusted callback caller, connector failover and funds policy — at the Solidity/unit level using Foundry's VM.

**What you'll see**: Foundry compiles and runs the test functions. Output looks like:

```
[PASS] testRejectZeroQueueAddress() (gas: ...)
[PASS] testSendWithFailover() (gas: ...)
...
```

A passing run takes a few seconds.

### Two-Ledger Bridged Test (JSON-RPC Relay Path)

```bash
npx hardhat test test/network/clpr/clprBridgeRelayedQueue.js --network hardhat
```

This test uses `MockClprRelayedQueue` with an off-chain relayer loop. It validates the queue contract ABI but does **not** exercise the native messaging transport.

**Known issue**: When targeting live Solo networks via JSON-RPC relay, this test is flaky because the relay depends on Mirror Node ingestion health. Record stream signature production can stall, blocking mirror ingestion and causing relay `eth_sendRawTransaction` to fail with "resource not found" for the sender address. The gRPC/native messaging path (below) is the reliable baseline. See `OPERATIONS.md` for details on JSON-RPC relay limitations.

## Two-Solo E2E Native Messaging Test

This is the primary validation: two independent Solo ledgers communicating via the in-node native messaging layer with no external pump.

### What the Test Does

1. Deploys two Solo consensus node networks (source + destination) with a custom consensus node build that includes the CLPR queue system contract at `0x16e`.
2. Performs a one-time `ClprLedgerConfiguration` exchange between ledgers (the only allowed external "kick").
3. Deploys CLPR middleware, connectors, and apps to both ledgers.
4. Sends 4 cross-ledger messages through the connector failover scenario:
   - **Message 1**: Connector 1 denies authorization → Connector 2 accepts → round-trip succeeds. The request travels from source to destination via `ClprEndpointClient` gRPC, destination middleware calls `EchoApplication.handleMessage(...)`, and the response returns the same way.
   - **Message 2**: Same as message 1. Destination connector 2's funds decrease further (reimbursement deducts from balance).
   - **Message 3**: Connector 1 denies → source middleware checks cached remote status from message 2's response and learns connector 2 is out-of-funds → pre-rejects connector 2 before even calling the queue → Connector 3 accepts → round-trip succeeds via connector 3.
   - **Message 4**: Same failover path to Connector 3 → round-trip succeeds.
5. Asserts all round-trips complete correctly and writes `Scenario passed` to `scenario.log`.

### Prerequisites

| Requirement | Minimum Version | Check Command |
|---|---|---|
| Solo CLI | 0.55.0 | `solo --version` |
| kubectl | recent | `kubectl version --client` |
| Java (JDK) | 21+ | `java -version` |
| Node.js | 18+ | `node --version` |
| npm dependencies | installed | Run `npm install` in this repo |
| Kubernetes cluster | running | `kubectl cluster-info` |
| Consensus node repo | checked out | `git -C ../hiero-consensus-node branch --show-current` → `23652-clpr-middleware-integration` (or successor) |

**Important**: `npm install` must be run in the `hedera-smart-contracts` repo before the E2E test. The scenario runner uses `@hashgraph/sdk` and other Node.js dependencies that are not bundled. If you skip this, you'll get `Error HHE22` during the Hardhat compile phase or module-not-found errors during the scenario phase.

### Step-by-Step from Scratch

#### 1. Build the consensus node

```bash
cd ../hiero-consensus-node
./gradlew :app:assemble
cd ../hedera-smart-contracts
```

This produces `hedera-node/data/apps/HederaNode.jar` and ~199 library JARs under `hedera-node/data/lib/`. Solo copies these into running containers so they run your code instead of the default release bits.

Build time: ~1 minute (mostly cached after first build).

#### 2. Install npm dependencies

```bash
npm install
```

This installs ~1000 packages including `@hashgraph/sdk`, `hardhat`, and `ethers`. Required before the E2E test can compile contracts or run the scenario.

#### 3. Ensure a Kubernetes cluster is running

The scripts default to `docker-desktop` as the cluster context. If you use a Kind cluster:

```bash
# Example: create a kind cluster named "solo"
kind create cluster --name solo

# Set the cluster context override (kind prefixes context names with "kind-")
export SOLO_CLUSTER_CONTEXT=kind-solo
```

Verify the cluster is reachable:

```bash
kubectl cluster-info
```

#### 4. Run the E2E test (one command)

```bash
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

Common options:

```bash
# Skip consensus node rebuild (faster reruns)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build

# Keep clusters running after the test (for debugging)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep

# Reuse existing deployments (no teardown/recreate)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-redeploy
```

#### 5. Verify results

Find the run directory:

```bash
ls -1dt artifacts/clpr-native-messaging-solo/* | head -n 1
```

Check scenario outcome:

```bash
cat artifacts/clpr-native-messaging-solo/<runId>/scenario.log
```

Expected: `Scenario passed`

### What You'll See During the E2E Run

The runner prints UTC-timestamped log lines to the terminal. Here's the sequence of phases and what to expect in each:

**Phase 1: Build** (~1 min, or skipped with `--no-build`)
```
[2026-02-21T03:40:00Z] Building consensus node artifacts into: ../hiero-consensus-node/hedera-node/data
```
You'll see Gradle output (task names, progress). This is the `./gradlew :app:assemble` build.

**Phase 2: Deploy two Solo networks** (~5-8 min)
```
[2026-02-21T03:41:00Z] Deploying two SOLO networks (force recreate for repeatability)
```
This is the longest phase. You'll see extensive Solo CLI output: deployment config creation, key generation, Helm chart installation, node setup, local build patching, and node startup. Each Solo command prints its own progress. Watch for `consensus node start` completing on both ledgers.

**Phase 3: Port-forwards and block-stream validation** (~30s)
```
[2026-02-21T03:48:00Z] Starting gRPC port-forwards
[2026-02-21T03:48:05Z] Starting block-node port-forwards
[2026-02-21T03:48:10Z] Verified block-stream wiring for 'source' ledger ...
[2026-02-21T03:48:15Z] Verified block-stream wiring for 'destination' ledger ...
[2026-02-21T03:48:20Z] Verified block-node stream availability for 'source' ...
[2026-02-21T03:48:25Z] Verified block-node stream availability for 'destination' ...
```

**Phase 4: Compile and config exchange** (~30s)
```
[2026-02-21T03:48:30Z] Compiling Solidity (Hardhat) to ensure artifacts are current
[2026-02-21T03:48:45Z] Compiling CLPR config-exchange tool
[2026-02-21T03:49:00Z] Running CLPR config exchange kick (and waiting for queue metadata init)
```
Hardhat compile output appears, then the Java config-exchange tool compiles and runs (output goes to `config-exchange.log`).

**Phase 5: Scenario execution** (~1-2 min, **terminal goes quiet**)
```
[2026-02-21T03:49:30Z] Starting live block-stream tailers (CN->BN subscriber feeds)
[2026-02-21T03:49:35Z] Running scenario runner
```

**After "Running scenario runner" the terminal goes silent.** The Node.js scenario runner (`run-scenario.js`) writes all its output to `scenario.log`, not to the terminal. This is the phase where contracts are deployed, messages are sent, and cross-ledger round-trips happen. It typically takes 1-2 minutes.

**How to monitor the silent scenario phase** (in a separate terminal):
```bash
# Watch the scenario log in real-time
tail -f artifacts/clpr-native-messaging-solo/*/scenario.log

# Or watch the consensus node logs for CLPR_OBS boundary traces
# (these show message enqueue, bundle processing, and delivery in real-time)
run_id=$(ls -1dt artifacts/clpr-native-messaging-solo/* | head -n 1 | xargs basename)
tail -f "artifacts/clpr-native-messaging-solo/$run_id/hgcaa-src.log" | grep CLPR_OBS
```

Note: `hgcaa-*.log` files are only written during the evidence collection phase (after the scenario), so to watch CLPR_OBS traces live during the scenario, use:
```bash
kubectl -n solo-int-src exec network-node1-0 -c root-container -- \
  tail -f /opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log | grep CLPR_OBS
```

**Phase 6: Evidence collection and teardown** (~1-2 min)
```
[2026-02-21T03:51:00Z] Collecting evidence (best-effort)
[2026-02-21T03:51:30Z] E2E run completed successfully. Evidence: artifacts/clpr-native-messaging-solo/<runId>
```

If the scenario fails, you'll see an error exit instead. The cleanup trap still collects evidence and tears down.

### How to Tell If the Scenario Succeeded

**Primary check**: `scenario.log` contains `Scenario passed`.

**If it failed**, `scenario.log` will contain a Node.js error trace showing which assertion failed. Common failure patterns:

- Timeout waiting for a response → `ClprEndpointClient` may not be cycling (check `hgcaa-*.log` for `CLPR Endpoint:` lines)
- Contract deployment revert → usually a Hardhat compile issue or stale ABI (run `npx hardhat compile` first)
- Connection refused → port-forwards died (check `port-forward-*.log`)

### Verifying What Happened After a Run

Once the run completes, the evidence artifacts let you reconstruct exactly what happened:

```bash
run_id=$(ls -1dt artifacts/clpr-native-messaging-solo/* | head -n 1 | xargs basename)
dir="artifacts/clpr-native-messaging-solo/$run_id"

# 1. Did the scenario pass?
cat "$dir/scenario.log"

# 2. What contracts were deployed and what are their addresses?
cat "$dir/deployment.json" | python3 -m json.tool

# 3. Did the config exchange succeed? (look for "setConfiguration" success)
cat "$dir/config-exchange.log"

# 4. Did CLPR messages flow through the source node?
#    (look for CLPR_OBS lines showing enqueue, bundle publish, response handling)
grep CLPR_OBS "$dir/hgcaa-src.log" | head -20

# 5. Did CLPR messages arrive at the destination node?
#    (look for bundle processing and inbound delivery)
grep CLPR_OBS "$dir/hgcaa-dst.log" | head -20

# 6. Block-stream decode health (if block node was enabled)
for side in src dst; do
  f="$dir/block-stream-${side}.ndjson"
  [ -f "$f" ] || continue
  n=$(grep -c '"recordType":"decode_error"' "$f" || true)
  echo "${side} decode_error=${n:-0}"
done
```

### Environment Variables Reference

Key overrides for `run-e2e.sh`:

| Variable | Default | Purpose |
|---|---|---|
| `SOLO_CLUSTER_CONTEXT` | `docker-desktop` | Kubernetes context |
| `SOLO_CLUSTER_REF` | `solo-shared` | Solo cluster reference name |
| `SOLO_SKIP_CLUSTER_SETUP` | `false` | Skip cluster-ref setup (set `true` if cluster-ref already exists) |
| `SOLO_ENABLE_BLOCK_NODE` | `true` | Deploy block nodes for observability |
| `SOLO_ENABLE_MIRROR` | `true` | Deploy mirror nodes |
| `SOLO_ENABLE_RELAY` | `false` | Deploy JSON-RPC relays |
| `CLPR_ENABLE_BLOCK_STREAM_TAILER` | `true` | Start block-stream tailers |
| `CN_LOCAL_BUILD_PATH` | `../hiero-consensus-node/hedera-node/data` | Path to consensus node build artifacts |
| `CLPR_SOLO_HOME` | - | If set, exported as `SOLO_HOME` |

Full environment variable reference: `scripts/clpr/README.md`

### Expected Run Time

- Full clean run (build + deploy + scenario + teardown): ~10-15 minutes
- Fast rerun (`--no-build`): ~8-12 minutes
- Hot path (`--no-build --no-redeploy`): ~1-2 minutes

### Evidence Artifacts

Each run produces artifacts under `artifacts/clpr-native-messaging-solo/<runId>/`:

| File | Content | How to use it |
|---|---|---|
| `scenario.log` | Pass/fail outcome | `cat` it — should say `Scenario passed` |
| `deployment.json` | Deployed contract addresses and ledger IDs | `python3 -m json.tool` to see middleware/connector/app addresses |
| `config-exchange.log` | Config exchange tool output | Check for `setConfiguration` success and queue metadata values |
| `run-manifest.env` | Run environment and parameters | Documents what flags/ports/toggles were used |
| `hgcaa-src.log` / `hgcaa-dst.log` | Consensus node app logs | `grep CLPR_OBS` to see message flow boundary traces |
| `swirlds-src.log` / `swirlds-dst.log` | Consensus platform logs | Check for platform errors or state transitions |
| `block-stream-src.ndjson` / `block-stream-dst.ndjson` | Block-stream structured feed | `jq 'select(.clprRelated==true)'` to see CLPR block items |
| `block-stream-src.log` / `block-stream-dst.log` | Tailer process logs | Check for tailer errors or decode issues |

### Troubleshooting

#### Solo cluster context mismatch

**Symptom**: Solo commands fail with connection refused or unreachable endpoint.

**Cause**: The default cluster context is `docker-desktop`, but your active cluster may be different (e.g., `kind-solo`).

**Fix**: Set `SOLO_CLUSTER_CONTEXT` to match your active Kubernetes context:

```bash
# Check available contexts
kubectl config get-contexts

# Use the correct one
export SOLO_CLUSTER_CONTEXT=kind-solo
```

If the Solo cluster-ref is pointing to a stale context, reconnect it:

```bash
solo cluster-ref config connect -c solo-shared --context kind-solo -q
```

#### Stale deployment configs

**Symptom**: Solo reports deployment already exists, or setup commands fail before namespace creation.

**Fix**: Delete stale local deployment config entries. If you used a custom `SOLO_HOME`, prefix the command with it:

```bash
solo deployment config delete --deployment solo-int-src -q || true
solo deployment config delete --deployment solo-int-dst -q || true
```

#### Block-stream tailer requires block node

**Symptom**: `CLPR_ENABLE_BLOCK_STREAM_TAILER=true requires SOLO_ENABLE_BLOCK_NODE=true`

**Fix**: Either enable block node (`SOLO_ENABLE_BLOCK_NODE=true`) or disable the tailer:

```bash
SOLO_ENABLE_BLOCK_NODE=false CLPR_ENABLE_BLOCK_STREAM_TAILER=false \
  bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build
```

#### Hardhat not installed / npm dependencies missing

**Symptom**: `Error HHE22: Trying to use a non-local installation of Hardhat`, or `Cannot find module '@hashgraph/sdk'`

**Fix**: Run `npm install` in the `hedera-smart-contracts` repo root.

#### Orphaned port-forwards from prior runs

**Symptom**: Port already in use, or stale connections to old deployments.

**Fix**:

```bash
pkill -f 'kubectl port-forward -n solo-int-src' || true
pkill -f 'kubectl port-forward -n solo-int-dst' || true
```

#### Mirror ingress RBAC conflict (mirror-enabled runs)

**Symptom**: Helm install fails due to existing `ClusterRole` named `mirror-ingress-controller` owned by another release.

**Fix**:

```bash
kubectl delete clusterrole mirror-ingress-controller --ignore-not-found
kubectl delete clusterrolebinding mirror-ingress-controller --ignore-not-found
```

#### Scenario runner hangs (no progress for >3 minutes)

**Symptom**: Terminal shows "Running scenario runner" and nothing happens for a long time.

**Diagnosis**: In a separate terminal:

```bash
# Check if the scenario runner process is alive
ps aux | grep run-scenario

# Check if gRPC port-forwards are still alive
ps aux | grep 'kubectl port-forward'

# If port-forwards died, the scenario runner is blocked waiting for gRPC responses
# Kill the run (Ctrl+C) and restart
```

The most common cause is port-forward instability on `docker-desktop`. The runner includes a port-forward supervisor that auto-restarts, but if the underlying cluster is unhealthy, the supervisor can't help.
