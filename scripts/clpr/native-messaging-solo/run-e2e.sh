#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"
# shellcheck source=./run-e2e-phases.sh
source "$SCRIPT_DIR/run-e2e-phases.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Runs the full two-ledger SOLO scenario using native CLPR messaging (ClprEndpointClient) with no off-chain pump:

1) Build consensus-node local artifacts (optional)
2) Deploy two SOLO networks (source + destination)
3) Port-forward gRPC endpoints to localhost
4) Perform the one-time CLPR config exchange "kick" (and wait for queue metadata initialization)
5) Deploy contracts to both ledgers and run the connector failover + topoff/re-deplete scenario
6) Stream block-node metadata in parallel (CLPR relevance scan)
7) Collect evidence and teardown

Options:
  --no-build           Skip building ../hiero-consensus-node artifacts
  --no-redeploy        Do not destroy/recreate SOLO deployments (assume they already exist and are healthy)
  --keep               Keep SOLO deployments running after the scenario (no teardown)
  -h, --help           Show this help

Environment overrides:
  CLPR_SOLO_HOME               (optional; if set, exported as SOLO_HOME for all Solo CLI commands)
  SOLO_HOME                    (optional; Solo local state dir; set for parallel workstreams to avoid ~/.solo collisions)
  SOLO_SRC_NAMESPACE           (default: solo-int-src; k8s namespace for the source ledger)
  SOLO_DST_NAMESPACE           (default: solo-int-dst; k8s namespace for the destination ledger)
  SOLO_SKIP_CLUSTER_SETUP      (optional; when true, skip 'solo cluster-ref config setup' to avoid concurrent cluster-scoped operations)
  CN_LOCAL_BUILD_PATH          (default: ../hiero-consensus-node/hedera-node/data)
  SRC_GRPC_LOCAL_PORT          (default: 51211)
  DST_GRPC_LOCAL_PORT          (default: 52211)
  SOLO_ENABLE_BLOCK_NODE       (default: true in this runner)
  SOLO_ENABLE_MIRROR           (default: true in this runner)
  CLPR_ENABLE_BLOCK_STREAM_TAILER (default: true)
  SRC_BN_LOCAL_PORT            (default: 54080; source block-node local port)
  DST_BN_LOCAL_PORT            (default: 54081; destination block-node local port)
  CLPR_BLOCK_STREAM_SRC_NDJSON (default: block-stream-src.ndjson under run dir; absolute path allowed)
  CLPR_BLOCK_STREAM_DST_NDJSON (default: block-stream-dst.ndjson under run dir; absolute path allowed)
  CLPR_BLOCK_STREAM_SRC_LOG    (default: block-stream-src.log under run dir; absolute path allowed)
  CLPR_BLOCK_STREAM_DST_LOG    (default: block-stream-dst.log under run dir; absolute path allowed)
  CLPR_BLOCK_STREAM_LOG_ALL    (default: false; pass --log-all to tailers)
  CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS (optional CSV; e.g. event_transaction,transaction_result)
  CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS (optional CSV; e.g. block_items,end_of_block)
  CLPR_BLOCK_STREAM_MATCH_KEYWORDS (optional CSV substrings; case-insensitive)
  OPERATOR_ID                 (default: 0.0.2)
  OPERATOR_KEY                (default: read from ../hiero-consensus-node/hedera-node/data/onboard/GenesisPrivKey.txt)
  NODE_ACCOUNT_ID             (default: 0.0.3)
  HEDERA_MAX_ATTEMPTS          (default: 30; scenario runner Hedera JS SDK retries)
  HEDERA_REQUEST_TIMEOUT_MS    (default: 60000; scenario runner Hedera JS SDK request timeout in ms)
USAGE
}

DO_BUILD=true
DO_REDEPLOY=true
KEEP=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-build)
      DO_BUILD=false
      shift
      ;;
    --no-redeploy)
      DO_REDEPLOY=false
      shift
      ;;
    --keep)
      KEEP=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_prereqs

# For this end-to-end runner, default to CN->BN->MN topology.
# `lib.sh` initializes these toggles to "false" for generic tooling, so detect whether the caller explicitly
# provided an environment override via `printenv` before applying this runner's defaults.
if printenv SOLO_ENABLE_BLOCK_NODE >/dev/null 2>&1; then
  SOLO_ENABLE_BLOCK_NODE="${SOLO_ENABLE_BLOCK_NODE}"
else
  SOLO_ENABLE_BLOCK_NODE="true"
fi
if printenv SOLO_ENABLE_MIRROR >/dev/null 2>&1; then
  SOLO_ENABLE_MIRROR="${SOLO_ENABLE_MIRROR}"
else
  SOLO_ENABLE_MIRROR="true"
fi
CLPR_ENABLE_BLOCK_STREAM_TAILER="${CLPR_ENABLE_BLOCK_STREAM_TAILER:-true}"
export SOLO_ENABLE_BLOCK_NODE
export SOLO_ENABLE_MIRROR
write_run_manifest
cat >>"$RUN_MANIFEST" <<MANIFEST_EXTRA
CLPR_ENABLE_BLOCK_STREAM_TAILER=$CLPR_ENABLE_BLOCK_STREAM_TAILER
MANIFEST_EXTRA

# Ensure nested helper scripts (two-network-up/down/status) reuse this run's artifact directory.
export RUN_ID
export ARTIFACT_ROOT

SRC_GRPC_LOCAL_PORT="${SRC_GRPC_LOCAL_PORT:-51211}"
DST_GRPC_LOCAL_PORT="${DST_GRPC_LOCAL_PORT:-52211}"
SRC_BN_LOCAL_PORT="${SRC_BN_LOCAL_PORT:-54080}"
DST_BN_LOCAL_PORT="${DST_BN_LOCAL_PORT:-54081}"

resolve_run_path() {
  local value="$1"
  if [[ "$value" = /* ]]; then
    printf '%s' "$value"
  else
    printf '%s' "$RUN_DIR/$value"
  fi
}

CLPR_BLOCK_STREAM_SRC_NDJSON="$(resolve_run_path "${CLPR_BLOCK_STREAM_SRC_NDJSON:-block-stream-src.ndjson}")"
CLPR_BLOCK_STREAM_DST_NDJSON="$(resolve_run_path "${CLPR_BLOCK_STREAM_DST_NDJSON:-block-stream-dst.ndjson}")"
CLPR_BLOCK_STREAM_SRC_LOG="$(resolve_run_path "${CLPR_BLOCK_STREAM_SRC_LOG:-block-stream-src.log}")"
CLPR_BLOCK_STREAM_DST_LOG="$(resolve_run_path "${CLPR_BLOCK_STREAM_DST_LOG:-block-stream-dst.log}")"
CLPR_BLOCK_STREAM_LOG_ALL="${CLPR_BLOCK_STREAM_LOG_ALL:-false}"
CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS="${CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS:-}"
CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS="${CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS:-}"
CLPR_BLOCK_STREAM_MATCH_KEYWORDS="${CLPR_BLOCK_STREAM_MATCH_KEYWORDS:-}"
mkdir -p \
  "$(dirname "$CLPR_BLOCK_STREAM_SRC_NDJSON")" \
  "$(dirname "$CLPR_BLOCK_STREAM_DST_NDJSON")" \
  "$(dirname "$CLPR_BLOCK_STREAM_SRC_LOG")" \
  "$(dirname "$CLPR_BLOCK_STREAM_DST_LOG")"

SRC_GRPC_ENDPOINT="127.0.0.1:${SRC_GRPC_LOCAL_PORT}"
DST_GRPC_ENDPOINT="127.0.0.1:${DST_GRPC_LOCAL_PORT}"
SRC_BN_ENDPOINT="127.0.0.1:${SRC_BN_LOCAL_PORT}"
DST_BN_ENDPOINT="127.0.0.1:${DST_BN_LOCAL_PORT}"
cat >>"$RUN_MANIFEST" <<MANIFEST_PORTS
SRC_GRPC_LOCAL_PORT=$SRC_GRPC_LOCAL_PORT
DST_GRPC_LOCAL_PORT=$DST_GRPC_LOCAL_PORT
SRC_BN_LOCAL_PORT=$SRC_BN_LOCAL_PORT
DST_BN_LOCAL_PORT=$DST_BN_LOCAL_PORT
CLPR_BLOCK_STREAM_SRC_NDJSON=$CLPR_BLOCK_STREAM_SRC_NDJSON
CLPR_BLOCK_STREAM_DST_NDJSON=$CLPR_BLOCK_STREAM_DST_NDJSON
CLPR_BLOCK_STREAM_SRC_LOG=$CLPR_BLOCK_STREAM_SRC_LOG
CLPR_BLOCK_STREAM_DST_LOG=$CLPR_BLOCK_STREAM_DST_LOG
CLPR_BLOCK_STREAM_LOG_ALL=$CLPR_BLOCK_STREAM_LOG_ALL
CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS=$CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS
CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS=$CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS
CLPR_BLOCK_STREAM_MATCH_KEYWORDS=$CLPR_BLOCK_STREAM_MATCH_KEYWORDS
MANIFEST_PORTS

CN_REPO_DIR="${CN_REPO_DIR:-$PROJECT_ROOT/../hiero-consensus-node}"

EVIDENCE_COLLECTED=false

collect_output_logs() {
  local namespace="$1"
  local label="$2"

  local pod
  pod="$(find_node_pod "$namespace")"
  if [[ -z "$pod" ]]; then
    warn "No network-node1 pod found in namespace '$namespace' (skipping output log capture)"
    return 0
  fi

  kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc 'ls -la /opt/hgcapp/services-hedera/HapiApp2.0/output || true' \
    >"$RUN_DIR/output-dir-${label}.txt" 2>&1 || true

  kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc 'tail -n 2000 /opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log || true' \
    >"$RUN_DIR/hgcaa-${label}.log" 2>&1 || true

  kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc 'tail -n 2000 /opt/hgcapp/services-hedera/HapiApp2.0/output/swirlds.log || true' \
    >"$RUN_DIR/swirlds-${label}.log" 2>&1 || true
}

collect_evidence() {
  if [[ "$EVIDENCE_COLLECTED" == "true" ]]; then
    return 0
  fi

  log "Collecting evidence (best-effort)"

  kubectl -n "$SOLO_SRC_NAMESPACE" get pods -o wide >"$RUN_DIR/k8s-src-pods.txt" 2>&1 || true
  kubectl -n "$SOLO_DST_NAMESPACE" get pods -o wide >"$RUN_DIR/k8s-dst-pods.txt" 2>&1 || true
  kubectl -n "$SOLO_SRC_NAMESPACE" get svc >"$RUN_DIR/k8s-src-svc.txt" 2>&1 || true
  kubectl -n "$SOLO_DST_NAMESPACE" get svc >"$RUN_DIR/k8s-dst-svc.txt" 2>&1 || true

  kubectl -n "$SOLO_SRC_NAMESPACE" logs statefulset/network-node1 -c root-container --tail=800 >"$RUN_DIR/node-src.log" 2>&1 || true
  kubectl -n "$SOLO_DST_NAMESPACE" logs statefulset/network-node1 -c root-container --tail=800 >"$RUN_DIR/node-dst.log" 2>&1 || true

  if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
    # Prefer statefulset logs; fall back to deployment for older Solo chart/resource variants.
    kubectl -n "$SOLO_SRC_NAMESPACE" logs statefulset/block-node-1 --tail=800 >"$RUN_DIR/block-node-src.log" 2>&1 \
      || kubectl -n "$SOLO_SRC_NAMESPACE" logs deploy/block-node-1 --tail=800 >"$RUN_DIR/block-node-src.log" 2>&1 \
      || true
    kubectl -n "$SOLO_DST_NAMESPACE" logs statefulset/block-node-1 --tail=800 >"$RUN_DIR/block-node-dst.log" 2>&1 \
      || kubectl -n "$SOLO_DST_NAMESPACE" logs deploy/block-node-1 --tail=800 >"$RUN_DIR/block-node-dst.log" 2>&1 \
      || true
  fi

  if [[ "$SOLO_ENABLE_MIRROR" == "true" ]]; then
    kubectl -n "$SOLO_SRC_NAMESPACE" logs deploy/mirror-1-importer --tail=800 >"$RUN_DIR/mirror-importer-src.log" 2>&1 || true
    kubectl -n "$SOLO_DST_NAMESPACE" logs deploy/mirror-1-importer --tail=800 >"$RUN_DIR/mirror-importer-dst.log" 2>&1 || true
  fi

  collect_output_logs "$SOLO_SRC_NAMESPACE" "src"
  collect_output_logs "$SOLO_DST_NAMESPACE" "dst"

  kubectl -n "$SOLO_SRC_NAMESPACE" get configmap network-node-hapi-app-cm -o yaml >"$RUN_DIR/cm-src-network-node-hapi-app-cm.yaml" 2>&1 || true
  kubectl -n "$SOLO_DST_NAMESPACE" get configmap network-node-hapi-app-cm -o yaml >"$RUN_DIR/cm-dst-network-node-hapi-app-cm.yaml" 2>&1 || true

  EVIDENCE_COLLECTED=true
}

cleanup() {
  set +e
  collect_evidence || true
  if [[ -n "${PF_SRC_PID:-}" ]]; then
    kill "$PF_SRC_PID" 2>/dev/null || true
    wait "$PF_SRC_PID" 2>/dev/null || true
  fi
  if [[ -n "${PF_DST_PID:-}" ]]; then
    kill "$PF_DST_PID" 2>/dev/null || true
    wait "$PF_DST_PID" 2>/dev/null || true
  fi
  if [[ -n "${PF_SRC_BN_PID:-}" ]]; then
    kill "$PF_SRC_BN_PID" 2>/dev/null || true
    wait "$PF_SRC_BN_PID" 2>/dev/null || true
  fi
  if [[ -n "${PF_DST_BN_PID:-}" ]]; then
    kill "$PF_DST_BN_PID" 2>/dev/null || true
    wait "$PF_DST_BN_PID" 2>/dev/null || true
  fi
  if [[ -n "${TAILER_SRC_PID:-}" ]]; then
    kill "$TAILER_SRC_PID" 2>/dev/null || true
    wait "$TAILER_SRC_PID" 2>/dev/null || true
  fi
  if [[ -n "${TAILER_DST_PID:-}" ]]; then
    kill "$TAILER_DST_PID" 2>/dev/null || true
    wait "$TAILER_DST_PID" 2>/dev/null || true
  fi
  if [[ "$KEEP" != "true" && "$DO_REDEPLOY" == "true" ]]; then
    "$SCRIPT_DIR/two-network-down.sh" || true
  fi
}
trap cleanup EXIT

log "Run directory: $RUN_DIR"

phase_build_consensus_artifacts
phase_prepare_cluster_and_networks

log "Starting gRPC port-forwards"
SRC_POD="$(find_node_pod "$SOLO_SRC_NAMESPACE")"
DST_POD="$(find_node_pod "$SOLO_DST_NAMESPACE")"
[[ -n "$SRC_POD" ]] || die "No network-node1 pod found in namespace '$SOLO_SRC_NAMESPACE'"
[[ -n "$DST_POD" ]] || die "No network-node1 pod found in namespace '$SOLO_DST_NAMESPACE'"

if [[ "$CLPR_ENABLE_BLOCK_STREAM_TAILER" == "true" ]]; then
  require_cmd grpcurl
fi

# Port-forwards are prone to intermittent disconnects on docker-desktop. Wrap them in lightweight supervisors that
# restart on failure so the scenario runner doesn't hang on dropped port-forward streams.
start_port_forward_supervisor() {
  local out_var="$1"
  local namespace="$2"
  local target="$3"
  local local_port="$4"
  local remote_port="$5"
  local log_file="$6"
  local pid_file="$7"

  (
    set -euo pipefail
    child_pid=""
    trap '[[ -n "${child_pid:-}" ]] && kill "$child_pid" 2>/dev/null || true' EXIT
    trap '[[ -n "${child_pid:-}" ]] && kill "$child_pid" 2>/dev/null || true; exit 0' INT TERM

    while true; do
      kubectl -n "$namespace" port-forward --address 127.0.0.1 "$target" "${local_port}:${remote_port}" \
        >>"$log_file" 2>&1 &
      child_pid=$!
      echo "$child_pid" >"$pid_file"
      wait "$child_pid" || true
      # If the port-forward drops (common on docker-desktop), wait briefly and restart.
      sleep 1
    done
  ) &

  printf -v "$out_var" '%s' "$!"
}

# Port-forward directly to the consensus pod's gRPC port to avoid intermittent proxy/service forwarding flakes.
start_port_forward_supervisor PF_SRC_PID "$SOLO_SRC_NAMESPACE" "pod/${SRC_POD}" "$SRC_GRPC_LOCAL_PORT" "50211" \
  "$RUN_DIR/port-forward-src.log" "$RUN_DIR/port-forward-src.pid"
start_port_forward_supervisor PF_DST_PID "$SOLO_DST_NAMESPACE" "pod/${DST_POD}" "$DST_GRPC_LOCAL_PORT" "50211" \
  "$RUN_DIR/port-forward-dst.log" "$RUN_DIR/port-forward-dst.pid"

if [[ "$CLPR_ENABLE_BLOCK_STREAM_TAILER" == "true" ]]; then
  [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]] || die "CLPR_ENABLE_BLOCK_STREAM_TAILER=true requires SOLO_ENABLE_BLOCK_NODE=true"
  SRC_BN_SVC="$(find_block_node_service "$SOLO_SRC_NAMESPACE")"
  DST_BN_SVC="$(find_block_node_service "$SOLO_DST_NAMESPACE")"
  [[ -n "$SRC_BN_SVC" ]] || die "Could not find block-node service in namespace '$SOLO_SRC_NAMESPACE'"
  [[ -n "$DST_BN_SVC" ]] || die "Could not find block-node service in namespace '$SOLO_DST_NAMESPACE'"

  log "Starting block-node port-forwards"
  start_port_forward_supervisor PF_SRC_BN_PID "$SOLO_SRC_NAMESPACE" "service/${SRC_BN_SVC}" "$SRC_BN_LOCAL_PORT" "40840" \
    "$RUN_DIR/port-forward-bn-src.log" "$RUN_DIR/port-forward-bn-src.pid"
  start_port_forward_supervisor PF_DST_BN_PID "$SOLO_DST_NAMESPACE" "service/${DST_BN_SVC}" "$DST_BN_LOCAL_PORT" "40840" \
    "$RUN_DIR/port-forward-bn-dst.log" "$RUN_DIR/port-forward-bn-dst.pid"
fi

wait_for_port() {
  local port="$1"
  local deadline=$((SECONDS + 30))
  while [[ $SECONDS -lt $deadline ]]; do
    if bash -lc "echo >/dev/tcp/127.0.0.1/${port}" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

assert_block_stream_wiring() {
  local namespace="$1"
  local label="$2"
  local pod
  pod="$(find_node_pod "$namespace")"
  [[ -n "$pod" ]] || die "No network-node1 pod found in namespace '$namespace' while validating block-stream wiring"

  local probe_out
  if ! probe_out="$(
    kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc '
set -e
APP=""
for p in \
  /opt/hgcapp/services-hedera/HapiApp2.0/data/config/application.properties \
  /opt/hgcapp/services-hedera/HapiApp2.0/application.properties; do
  if [ -f "$p" ]; then
    APP="$p"
    break
  fi
done

if [ -z "$APP" ]; then
  echo "missing application.properties"
  exit 11
fi

grep -Eq "^blockStream\\.streamMode=" "$APP" || { echo "missing blockStream.streamMode in $APP"; exit 12; }
grep -Eq "^blockStream\\.writerMode=" "$APP" || { echo "missing blockStream.writerMode in $APP"; exit 13; }

BLOCK_NODES_FILE="$(find /opt/hgcapp/services-hedera/HapiApp2.0 -maxdepth 5 -name block-nodes.json 2>/dev/null | head -n 1)"
if [ -z "$BLOCK_NODES_FILE" ]; then
  echo "missing block-nodes.json"
  exit 14
fi

echo "applicationProperties=$APP"
echo "blockNodesJson=$BLOCK_NODES_FILE"
' 2>&1
  )"; then
    die "Block-stream wiring check failed for '$label' ledger: $probe_out"
  fi

  log "Verified block-stream wiring for '$label' ledger ($(echo "$probe_out" | tr '\n' ' '))"
}

declare -a BN_GRPC_IMPORT_ARGS=()

add_bn_import_path_if_exists() {
  local import_path="$1"
  [[ -d "$import_path" ]] || return 0
  BN_GRPC_IMPORT_ARGS+=("-import-path" "$import_path")
}

build_bn_grpc_import_args() {
  BN_GRPC_IMPORT_ARGS=()
  # Prefer consensus-node protobuf resources because block stream payloads originate in CN.
  add_bn_import_path_if_exists "$CN_REPO_DIR/hapi/hapi/build/resources/main"
  add_bn_import_path_if_exists "$CN_REPO_DIR/hapi/hapi/build/extracted-protos/main"
  add_bn_import_path_if_exists "$CN_REPO_DIR/hapi/hedera-protobuf-java-api/build/resources/main"
  add_bn_import_path_if_exists "$CN_REPO_DIR/hapi/hedera-protobuf-java-api/src/main/proto"
  # Fallback to block-node repo protobuf resources.
  add_bn_import_path_if_exists "$PROJECT_ROOT/../hiero-block-node/protobuf-sources/src/main/proto"
  add_bn_import_path_if_exists "$PROJECT_ROOT/../hiero-block-node/protobuf-sources/src/main/proto-overrides"
  add_bn_import_path_if_exists "$PROJECT_ROOT/../hiero-block-node/stream/build/hedera-protobufs"
  add_bn_import_path_if_exists "$PROJECT_ROOT/../hiero-block-node/stream/build/resources/main"
  if [[ "${#BN_GRPC_IMPORT_ARGS[@]}" -eq 0 ]]; then
    die "Unable to locate block-node proto import paths under ../hiero-block-node"
  fi
}

query_bn_server_status() {
  local endpoint="$1"
  grpcurl -plaintext \
    "${BN_GRPC_IMPORT_ARGS[@]}" \
    -proto block-node/api/node_service.proto \
    -d '{}' \
    "$endpoint" \
    org.hiero.block.api.BlockNodeService/serverStatus
}

validate_bn_stream_available() {
  local endpoint="$1"
  local label="$2"
  local deadline=$((SECONDS + 120))
  local status_json=""
  local first_available=""
  local last_available=""

  while [[ $SECONDS -lt $deadline ]]; do
    if status_json="$(query_bn_server_status "$endpoint" 2>&1)"; then
      first_available="$(printf '%s\n' "$status_json" | rg -m1 -o '"firstAvailableBlock":\s*"?[0-9]+' | rg -m1 -o '[0-9]+' || true)"
      last_available="$(printf '%s\n' "$status_json" | rg -m1 -o '"lastAvailableBlock":\s*"?[0-9]+' | rg -m1 -o '[0-9]+' || true)"
      if [[ -n "$last_available" ]]; then
        # Some block-node versions omit firstAvailableBlock in serverStatus responses.
        if [[ -z "$first_available" ]]; then
          first_available="$last_available"
        fi
        if [[ "$last_available" != "18446744073709551615" ]]; then
          log "Verified block-node stream availability for '$label' ledger at $endpoint: first=$first_available last=$last_available"
          return 0
        fi
      fi
    fi
    sleep 2
  done

  if [[ -z "$last_available" ]]; then
    die "Could not parse block-node serverStatus for '$label' ledger at $endpoint after retry window: $status_json"
  fi
  die "Block-node for '$label' ledger stayed NOT_AVAILABLE after retry window (first=$first_available last=$last_available)."
}

validate_block_stream_readiness() {
  [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]] || return 0

  assert_block_stream_wiring "$SOLO_SRC_NAMESPACE" "source"
  assert_block_stream_wiring "$SOLO_DST_NAMESPACE" "destination"

  if [[ "$CLPR_ENABLE_BLOCK_STREAM_TAILER" == "true" ]]; then
    build_bn_grpc_import_args
    validate_bn_stream_available "$SRC_BN_ENDPOINT" "source"
    validate_bn_stream_available "$DST_BN_ENDPOINT" "destination"
  fi
}

wait_for_port "$SRC_GRPC_LOCAL_PORT" || die "Source gRPC port-forward not ready on localhost:${SRC_GRPC_LOCAL_PORT}"
wait_for_port "$DST_GRPC_LOCAL_PORT" || die "Destination gRPC port-forward not ready on localhost:${DST_GRPC_LOCAL_PORT}"
if [[ "$CLPR_ENABLE_BLOCK_STREAM_TAILER" == "true" ]]; then
  wait_for_port "$SRC_BN_LOCAL_PORT" || die "Source block-node port-forward not ready on localhost:${SRC_BN_LOCAL_PORT}"
  wait_for_port "$DST_BN_LOCAL_PORT" || die "Destination block-node port-forward not ready on localhost:${DST_BN_LOCAL_PORT}"
fi

validate_block_stream_readiness

phase_compile_hardhat_artifacts
phase_compile_config_exchange_tool
phase_run_config_exchange_and_validate

if [[ "$CLPR_ENABLE_BLOCK_STREAM_TAILER" == "true" ]]; then
  log "Starting live block-stream tailers (CN->BN subscriber feeds)"
  build_tail_filter_args() {
    local csv="$1"
    local flag="$2"
    [[ -n "$csv" ]] || return 0
    local IFS=','
    local values
    read -r -a values <<< "$csv"
    for value in "${values[@]}"; do
      value="${value#"${value%%[![:space:]]*}"}"
      value="${value%"${value##*[![:space:]]}"}"
      [[ -n "$value" ]] || continue
      TAILER_FILTER_ARGS+=("$flag" "$value")
    done
  }

  TAILER_FILTER_ARGS=()
  build_tail_filter_args "$CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS" "--match-item-kind"
  build_tail_filter_args "$CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS" "--match-response-kind"
  build_tail_filter_args "$CLPR_BLOCK_STREAM_MATCH_KEYWORDS" "--match-keyword"
  if [[ "$CLPR_BLOCK_STREAM_LOG_ALL" == "true" ]]; then
    TAILER_FILTER_ARGS+=("--log-all")
  fi

  # macOS Bash (3.x) with `set -u` can treat empty array expansion as unbound.
  # Temporarily disable nounset for these invocations so empty filter arrays work.
  set +u
  (cd "$PROJECT_ROOT" && node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
    --endpoint "$SRC_BN_ENDPOINT" \
    --label "src" \
    --deployment-file "$RUN_DIR/deployment.json" \
    --output-file "$CLPR_BLOCK_STREAM_SRC_NDJSON" \
    "${TAILER_FILTER_ARGS[@]}") \
    >"$CLPR_BLOCK_STREAM_SRC_LOG" 2>&1 &
  TAILER_SRC_PID=$!

  (cd "$PROJECT_ROOT" && node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
    --endpoint "$DST_BN_ENDPOINT" \
    --label "dst" \
    --deployment-file "$RUN_DIR/deployment.json" \
    --output-file "$CLPR_BLOCK_STREAM_DST_NDJSON" \
    "${TAILER_FILTER_ARGS[@]}") \
    >"$CLPR_BLOCK_STREAM_DST_LOG" 2>&1 &
  TAILER_DST_PID=$!
  set -u
fi

phase_run_scenario_runner

collect_evidence

log "E2E run completed successfully. Evidence: $RUN_DIR"
