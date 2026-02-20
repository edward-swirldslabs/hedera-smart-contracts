# CLPR Scripts

This directory contains the operational scripts used to run the two-ledger CLPR native-messaging scenario in SOLO.

Canonical scenario reference:
- `docs/clpr/NATIVE_MESSAGING_SOLO_SCENARIO_REFERENCE.md`

The scenario validated by these scripts is:

1. Stand up two SOLO ledgers (source + destination).
2. Exchange `ClprLedgerConfiguration` state proofs once (the allowed CLPR bootstrap kick).
3. Deploy middleware/apps/connectors on both ledgers.
4. Send cross-ledger messages through the native CLPR messaging path (`ClprEndpointClient`, no external pump).
5. Verify connector failover behavior, connector2 depletion, connector2 top-off recovery, and connector2 re-depletion.
6. Optionally tail block-stream frames from block nodes for observability.

## Directory layout

- `native-messaging-solo/`
  - Main scenario automation scripts.
  - Includes bring-up, status, teardown, orchestration, scenario execution, and block-stream tailing.
- `shared/`
  - Shared JavaScript helpers reused by CLPR scripts.

## Script inventory

### `native-messaging-solo/`

- `run-e2e.sh`
  - Top-level orchestrator (recommended entrypoint).
  - Runs build -> deploy -> port-forward -> CLPR config exchange -> scenario -> evidence collection -> teardown.
- `run-e2e-phases.sh`
  - Sourced helper defining orchestration phase functions used by `run-e2e.sh`.
  - Not intended to be executed directly.
- `lib.sh`
  - Sourced shared shell library (env defaults, prereq checks, helper functions).
  - Not intended to be executed directly.
- `two-network-up.sh`
  - Creates and starts both SOLO deployments (source/destination), with optional mirror/relay/block-node components.
- `two-network-status.sh`
  - Health/status checks for both deployments.
- `two-network-down.sh`
  - Stops/destroys both deployments.
- `run-scenario.js`
  - Deploys CLPR contracts and executes the connector failover + depletion/top-off/re-depletion validation logic.
- `block-stream-tailer.js`
  - Live BN subscriber consumer using `grpcurl`; emits structured NDJSON metadata for CLPR-relevant block items/frames.
- `config/application-src.properties`
  - Source ledger app-property overrides for CLPR + queue system contract + dev throttles.
- `config/application-dst.properties`
  - Destination ledger app-property overrides for CLPR + queue system contract + dev throttles.

### `shared/`

- `connector-ids.js`
  - Deterministic connector-id derivation helper used by `run-scenario.js`.

## Recommended usage (one command)

From repo root:

```bash
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

This is the canonical flow and should be the default unless you need manual phase control.

### `run-e2e.sh` options

```bash
--no-build      Skip `../hiero-consensus-node` build (`:app:assemble`)
--no-redeploy   Reuse existing deployments; do not recreate
--keep          Keep deployments running after scenario
-h|--help       Show script help
```

### `run-e2e.sh` key environment overrides

- Core environment:
  - `CLPR_SOLO_HOME` (if set, exported as `SOLO_HOME`)
  - `SOLO_HOME`
  - `SOLO_SKIP_CLUSTER_SETUP`
  - `SOLO_CLUSTER_CONTEXT` (default `docker-desktop`)
  - `SOLO_CLUSTER_REF` (default `solo-shared`)
  - `CN_LOCAL_BUILD_PATH` (default `../hiero-consensus-node/hedera-node/data`)
- Deployment names/namespaces:
  - `SOLO_SRC_DEPLOYMENT` / `SOLO_DST_DEPLOYMENT`
  - `SOLO_SRC_NAMESPACE` / `SOLO_DST_NAMESPACE`
- Runtime component toggles:
  - `SOLO_ENABLE_BLOCK_NODE` (forced default `true` by `run-e2e.sh` unless explicitly set)
  - `SOLO_ENABLE_MIRROR` (forced default `true` by `run-e2e.sh` unless explicitly set)
  - `SOLO_ENABLE_RELAY`
  - `CLPR_ENABLE_BLOCK_STREAM_TAILER` (default `true` in `run-e2e.sh`)
- Local forwarded ports:
  - `SRC_GRPC_LOCAL_PORT` (default `51211`)
  - `DST_GRPC_LOCAL_PORT` (default `52211`)
  - `SRC_BN_LOCAL_PORT` (default `54080`)
  - `DST_BN_LOCAL_PORT` (default `54081`)
- Tailer outputs/filtering:
  - `CLPR_BLOCK_STREAM_SRC_NDJSON`, `CLPR_BLOCK_STREAM_DST_NDJSON`
  - `CLPR_BLOCK_STREAM_SRC_LOG`, `CLPR_BLOCK_STREAM_DST_LOG`
  - `CLPR_BLOCK_STREAM_LOG_ALL`
  - `CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS`
  - `CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS`
  - `CLPR_BLOCK_STREAM_MATCH_KEYWORDS`
- Scenario signing/runtime:
  - `OPERATOR_ID` (default `0.0.2`)
  - `OPERATOR_KEY` (default read from `../hiero-consensus-node/hedera-node/data/onboard/GenesisPrivKey.txt`)
  - `NODE_ACCOUNT_ID` (default `0.0.3`)
  - `HEDERA_MAX_ATTEMPTS` (default `30`)
  - `HEDERA_REQUEST_TIMEOUT_MS` (default `60000`)

## Manual phase-by-phase usage (all scripts)

Use this when you need explicit control of each stage.

### 1) Bring up both ledgers

```bash
bash scripts/clpr/native-messaging-solo/two-network-up.sh --force
```

Notes:
- `--force` tears down existing deployments first if they already exist.
- Uses `config/application-src.properties` and `config/application-dst.properties` by default.

### 2) Verify health

```bash
bash scripts/clpr/native-messaging-solo/two-network-status.sh
```

### 3) Port-forward source/destination gRPC endpoints

```bash
kubectl -n "${SOLO_SRC_NAMESPACE:-solo-int-src}" port-forward --address 127.0.0.1 pod/network-node1 51211:50211
kubectl -n "${SOLO_DST_NAMESPACE:-solo-int-dst}" port-forward --address 127.0.0.1 pod/network-node1 52211:50211
```

Keep both commands running in separate terminals.

### 4) Compile and run CLPR config-exchange tool (bootstrap kick)

```bash
CN_REPO_DIR="${CN_REPO_DIR:-../hiero-consensus-node}"
JAVA_OUT_DIR="/tmp/clpr-java-classes"
mkdir -p "$JAVA_OUT_DIR"

CLASSPATH_CN="$CN_REPO_DIR/hedera-node/data/lib/*:$CN_REPO_DIR/hedera-node/data/apps/*"
javac -cp "$CLASSPATH_CN" -d "$JAVA_OUT_DIR" tools/clpr/ClprConfigExchange.java

java -cp "$JAVA_OUT_DIR:$CLASSPATH_CN" tools.clpr.ClprConfigExchange \
  --a 127.0.0.1:51211 \
  --b 127.0.0.1:52211 \
  --out /tmp/clpr-config-exchange.env
```

Load resulting env values:

```bash
set -a
source /tmp/clpr-config-exchange.env
set +a
```

### 5) Run scenario logic

```bash
SRC_GRPC_ENDPOINT=127.0.0.1:51211 \
DST_GRPC_ENDPOINT=127.0.0.1:52211 \
SRC_LEDGER_ID_HEX="$CLPR_A_LEDGER_ID_HEX" \
DST_LEDGER_ID_HEX="$CLPR_B_LEDGER_ID_HEX" \
RUN_DIR=/tmp/clpr-manual-run \
node scripts/clpr/native-messaging-solo/run-scenario.js
```

### 6) (Optional) Start block-stream tailers

```bash
node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
  --endpoint 127.0.0.1:54080 \
  --label src \
  --deployment-file /tmp/clpr-manual-run/deployment.json \
  --output-file /tmp/clpr-manual-run/block-stream-src.ndjson

node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
  --endpoint 127.0.0.1:54081 \
  --label dst \
  --deployment-file /tmp/clpr-manual-run/deployment.json \
  --output-file /tmp/clpr-manual-run/block-stream-dst.ndjson
```

### 7) Tear down

```bash
bash scripts/clpr/native-messaging-solo/two-network-down.sh
```

Use `--keep-config` to preserve deployment config metadata:

```bash
bash scripts/clpr/native-messaging-solo/two-network-down.sh --keep-config
```

## Detailed per-script reference

### `two-network-up.sh`

Usage:

```bash
bash scripts/clpr/native-messaging-solo/two-network-up.sh [--force]
```

Behavior:
- Ensures Solo cluster-ref exists (unless `SOLO_SKIP_CLUSTER_SETUP=true`).
- Creates two deployments (source/destination).
- Generates keys, deploys consensus nodes, applies local CN build artifacts.
- Optionally adds block node, mirror, relay.
- Runs `two-network-status.sh` at the end.

### `two-network-status.sh`

Usage:

```bash
bash scripts/clpr/native-messaging-solo/two-network-status.sh
```

Behavior:
- Verifies namespace/pod/service health.
- Verifies CLPR properties are enabled in node `application.properties`.
- Optionally checks block-node and mirror importer health according to toggles.
- Returns non-zero on failed checks.

### `two-network-down.sh`

Usage:

```bash
bash scripts/clpr/native-messaging-solo/two-network-down.sh [--keep-config]
```

Behavior:
- Stops nodes, destroys optional relay/mirror/block-node components.
- Destroys consensus networks.
- Removes local deployment configs unless `--keep-config` is set.

### `run-scenario.js`

Usage:

```bash
SRC_GRPC_ENDPOINT=<host:port> \
DST_GRPC_ENDPOINT=<host:port> \
SRC_LEDGER_ID_HEX=<0x...> \
DST_LEDGER_ID_HEX=<0x...> \
node scripts/clpr/native-messaging-solo/run-scenario.js
```

Required env:
- `SRC_GRPC_ENDPOINT`
- `DST_GRPC_ENDPOINT`
- `SRC_LEDGER_ID_HEX`
- `DST_LEDGER_ID_HEX`

Optional env:
- `RUN_DIR` (writes `deployment.json` here)
- `OPERATOR_ID` (default `0.0.2`)
- `OPERATOR_KEY` or `GENESIS_PRIVKEY_PATH`
- `NODE_ACCOUNT_ID` (default `0.0.3`)
- `TRUSTED_CALLBACK_CALLER` (defaults to operator EVM address)
- `HEDERA_MAX_ATTEMPTS`
- `HEDERA_REQUEST_TIMEOUT_MS`

Behavior:
- Deploys middleware/connectors/apps to both ledgers.
- Configures connector relationships and callback trust.
- Sends 6 messages total:
  - first 2 use connector2 after connector1 denial,
  - next 2 pre-reject connector2 and fail over to connector3,
  - top-off destination connector2, then send 2 more where connector2 succeeds once and is pre-rejected again.
- Validates funding-state control updates and connector attempt counters.
- Exits non-zero on assertion failure.

### `block-stream-tailer.js`

Usage:

```bash
node scripts/clpr/native-messaging-solo/block-stream-tailer.js --endpoint <host:port> [options]
```

Options:
- `--label <name>`
- `--start-block <n>`
- `--deployment-file <path>`
- `--output-file <path>`
- `--reconnect-delay-ms <ms>`
- `--import-path <dir>` (repeatable)
- `--match-item-kind <name>` (repeatable)
- `--match-response-kind <kind>` (repeatable)
- `--match-keyword <text>` (repeatable)
- `--log-all`

Behavior:
- Subscribes to BN stream via `grpcurl` and reconnects on stream drops.
- Emits NDJSON `frame` and `block_item` records.
- Detects CLPR relevance by keywords and deployment identifiers.
- Emits `decode_error` records when a frame cannot be decoded and advances cursor to continue live tailing.

### `run-e2e-phases.sh` / `lib.sh`

These are internal sourced modules used by `run-e2e.sh`.

- Do not execute directly.
- Edit here when changing shared orchestration behavior, defaults, or phase decomposition.

### `shared/connector-ids.js`

Internal helper used by `run-scenario.js` for deterministic source/destination connector id derivation.

## Outputs and evidence

`run-e2e.sh` writes run artifacts under:

- `artifacts/clpr-native-messaging-solo/<RUN_ID>/`

Common files include:
- `run-manifest.env`
- `config-exchange.log`
- `config-exchange.env`
- `scenario.log`
- `deployment.json`
- `port-forward-*.log`
- `block-stream-*.ndjson` / `block-stream-*.log` (if tailers enabled)
- `node-*.log`, `hgcaa-*.log`, `swirlds-*.log`, mirror/block-node logs (best effort)

## Prerequisites

At minimum:
- `solo` CLI
- `kubectl`
- `java` + `javac`
- `node` + dependencies installed (`npm install` in this repo)

For block-stream tailing:
- `grpcurl`
- sibling repos available locally for proto import resolution:
  - `../hiero-consensus-node`
  - `../hiero-block-node`

## Related runbooks

- `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md`
- `docs/clpr/BLOCK_STREAM_TAILER_RUNBOOK.md`
- `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md`
- `docs/clpr/NATIVE_MESSAGING_SOLO_AFTER_ACTION_REPORT.md`
