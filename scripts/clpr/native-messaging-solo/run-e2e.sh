#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [options]

Runs the full two-ledger SOLO scenario using native CLPR messaging (ClprEndpointClient) with no off-chain pump:

1) Build consensus-node local artifacts (optional)
2) Deploy two SOLO networks (source + destination)
3) Port-forward gRPC endpoints to localhost
4) Perform the one-time CLPR config exchange "kick" (and wait for queue metadata initialization)
5) Deploy contracts to both ledgers and run the connector failover + funds depletion scenario
6) Collect evidence and teardown

Options:
  --no-build           Skip building ../hiero-consensus-node artifacts
  --no-redeploy        Do not destroy/recreate SOLO deployments (assume they already exist and are healthy)
  --keep               Keep SOLO deployments running after the scenario (no teardown)
  -h, --help           Show this help

Environment overrides:
  CN_LOCAL_BUILD_PATH          (default: ../hiero-consensus-node/hedera-node/data)
  SRC_GRPC_LOCAL_PORT          (default: 51211)
  DST_GRPC_LOCAL_PORT          (default: 52211)
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
write_run_manifest

# Ensure nested helper scripts (two-network-up/down/status) reuse this run's artifact directory.
export RUN_ID
export ARTIFACT_ROOT

SRC_GRPC_LOCAL_PORT="${SRC_GRPC_LOCAL_PORT:-51211}"
DST_GRPC_LOCAL_PORT="${DST_GRPC_LOCAL_PORT:-52211}"

SRC_GRPC_ENDPOINT="127.0.0.1:${SRC_GRPC_LOCAL_PORT}"
DST_GRPC_ENDPOINT="127.0.0.1:${DST_GRPC_LOCAL_PORT}"

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
  if [[ "$KEEP" != "true" && "$DO_REDEPLOY" == "true" ]]; then
    "$SCRIPT_DIR/two-network-down.sh" || true
  fi
}
trap cleanup EXIT

log "Run directory: $RUN_DIR"

if [[ "$DO_BUILD" == "true" ]]; then
  log "Building consensus node artifacts into: $CN_LOCAL_BUILD_PATH"
  # In hiero-consensus-node, the Hedera app project is exposed as `:app`.
  # `:app:assemble` also runs the `copyLib` / `copyApp` / `copyNodeDataAndConfig` tasks that populate `hedera-node/data/*`,
  # which SOLO consumes via `--local-build-path`.
  (cd "$CN_REPO_DIR" && ./gradlew :app:assemble)
else
  log "Skipping consensus node build (--no-build)"
fi

ensure_cluster_ref

if [[ "$DO_REDEPLOY" == "true" ]]; then
  log "Deploying two SOLO networks (force recreate for repeatability)"
  "$SCRIPT_DIR/two-network-up.sh" --force
else
  log "Skipping SOLO redeploy (--no-redeploy)"
  "$SCRIPT_DIR/two-network-status.sh"
fi

log "Starting gRPC port-forwards"
SRC_POD="$(find_node_pod "$SOLO_SRC_NAMESPACE")"
DST_POD="$(find_node_pod "$SOLO_DST_NAMESPACE")"
[[ -n "$SRC_POD" ]] || die "No network-node1 pod found in namespace '$SOLO_SRC_NAMESPACE'"
[[ -n "$DST_POD" ]] || die "No network-node1 pod found in namespace '$SOLO_DST_NAMESPACE'"

# Port-forward directly to the consensus pod's gRPC port to avoid intermittent proxy/service forwarding flakes.
kubectl -n "$SOLO_SRC_NAMESPACE" port-forward --address 127.0.0.1 "pod/${SRC_POD}" "${SRC_GRPC_LOCAL_PORT}:50211" \
  >"$RUN_DIR/port-forward-src.log" 2>&1 &
PF_SRC_PID=$!
kubectl -n "$SOLO_DST_NAMESPACE" port-forward --address 127.0.0.1 "pod/${DST_POD}" "${DST_GRPC_LOCAL_PORT}:50211" \
  >"$RUN_DIR/port-forward-dst.log" 2>&1 &
PF_DST_PID=$!

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

wait_for_port "$SRC_GRPC_LOCAL_PORT" || die "Source gRPC port-forward not ready on localhost:${SRC_GRPC_LOCAL_PORT}"
wait_for_port "$DST_GRPC_LOCAL_PORT" || die "Destination gRPC port-forward not ready on localhost:${DST_GRPC_LOCAL_PORT}"

log "Compiling Solidity (Hardhat) to ensure artifacts are current"
(cd "$PROJECT_ROOT" && npx hardhat compile)

log "Compiling CLPR config-exchange tool"
JAVA_OUT_DIR="$RUN_DIR/java-classes"
mkdir -p "$JAVA_OUT_DIR"
CLASSPATH_CN="$CN_LOCAL_BUILD_PATH/lib/*:$CN_LOCAL_BUILD_PATH/apps/*"
javac -cp "$CLASSPATH_CN" -d "$JAVA_OUT_DIR" "$PROJECT_ROOT/tools/clpr/ClprConfigExchange.java"

log "Running CLPR config exchange kick (and waiting for queue metadata init)"
CONFIG_ENV="$RUN_DIR/config-exchange.env"
# Run from the consensus-node repo root so dev signer key lookups that depend on relative paths work.
(cd "$CN_REPO_DIR" && java -cp "$JAVA_OUT_DIR:$CLASSPATH_CN" tools.clpr.ClprConfigExchange \
  --a "$SRC_GRPC_ENDPOINT" \
  --b "$DST_GRPC_ENDPOINT" \
  --out "$CONFIG_ENV") \
  >"$RUN_DIR/config-exchange.log" 2>&1

# Load ledger ids for the scenario runner.
set -a
# shellcheck source=/dev/null
source "$CONFIG_ENV"
set +a

export RUN_DIR
export SRC_GRPC_ENDPOINT
export DST_GRPC_ENDPOINT
export SRC_LEDGER_ID_HEX="$CLPR_A_LEDGER_ID_HEX"
export DST_LEDGER_ID_HEX="$CLPR_B_LEDGER_ID_HEX"

log "Running scenario runner"
(cd "$PROJECT_ROOT" && node scripts/clpr/native-messaging-solo/run-scenario.js >"$RUN_DIR/scenario.log" 2>&1)

collect_evidence

log "E2E run completed successfully. Evidence: $RUN_DIR"
