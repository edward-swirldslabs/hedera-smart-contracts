#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
CONSENSUS_NODE_REPO="${CONSENSUS_NODE_REPO:-$PROJECT_ROOT/../hiero-consensus-node}"

ARTIFACT_ROOT="${CLPR_SMOKE_ARTIFACT_ROOT:-$PROJECT_ROOT/artifacts/clpr-native-queue/issue-0013}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$ARTIFACT_ROOT/$RUN_ID"

CLPR_SRC_OPERATOR_ID="${CLPR_SRC_OPERATOR_ID:-0.0.2}"
CLPR_DST_OPERATOR_ID="${CLPR_DST_OPERATOR_ID:-0.0.2}"
CLPR_SRC_NODE_ACCOUNT_ID="${CLPR_SRC_NODE_ACCOUNT_ID:-0.0.3}"
CLPR_DST_NODE_ACCOUNT_ID="${CLPR_DST_NODE_ACCOUNT_ID:-0.0.3}"

CLPR_SRC_GRPC_LOCAL_PORT="${CLPR_SRC_GRPC_LOCAL_PORT:-50221}"
CLPR_DST_GRPC_LOCAL_PORT="${CLPR_DST_GRPC_LOCAL_PORT:-30212}"
CLPR_SRC_GRPC_SERVICE="${CLPR_SRC_GRPC_SERVICE:-network-node1-svc}"
CLPR_DST_GRPC_SERVICE="${CLPR_DST_GRPC_SERVICE:-network-node1-svc}"
CLPR_SRC_GRPC_URL="127.0.0.1:${CLPR_SRC_GRPC_LOCAL_PORT}"
CLPR_DST_GRPC_URL="127.0.0.1:${CLPR_DST_GRPC_LOCAL_PORT}"

CLPR_BOOTSTRAP_TIMEOUT_SECONDS="${CLPR_BOOTSTRAP_TIMEOUT_SECONDS:-180}"
CLPR_PUMP_TIMEOUT_SECONDS="${CLPR_PUMP_TIMEOUT_SECONDS:-180}"
CLPR_SMOKE_TIMEOUT_MS="${CLPR_SMOKE_TIMEOUT_MS:-180000}"
CLPR_SMOKE_POLL_MS="${CLPR_SMOKE_POLL_MS:-1000}"
CLPR_SMOKE_PAYLOAD="${CLPR_SMOKE_PAYLOAD:-solo-native-queue-smoke}"

COMPILE_LOG="$RUN_DIR/compile.log"
BOOTSTRAP_LOG="$RUN_DIR/bootstrap.log"
DEPLOY_LOG="$RUN_DIR/deploy.log"
PUMP_LOG="$RUN_DIR/pump.log"
INVOKE_LOG="$RUN_DIR/invoke.log"
PORTFWD_SRC_LOG="$RUN_DIR/portforward-src.log"
PORTFWD_DST_LOG="$RUN_DIR/portforward-dst.log"
DEPLOYMENT_JSON="$RUN_DIR/deployment.json"
INVOKE_RESULT_JSON="$RUN_DIR/invoke-result.json"
PREFLIGHT_REPORT="$RUN_DIR/preflight-report.txt"

CLPR_SMOKE_RESULT="FAIL"
CLPR_SMOKE_FAILURE_REASON=""
PF_PIDS=()

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Runs a two-ledger native queue smoke against active Solo deployments.

Required env:
  CLPR_SRC_OPERATOR_KEY
  CLPR_DST_OPERATOR_KEY

Optional env:
  CONSENSUS_NODE_REPO         (default: ../hiero-consensus-node)
  ARTIFACT_ROOT               (default: artifacts/clpr-native-queue/issue-0013)
  RUN_ID                      (default: UTC timestamp)
  CLPR_SRC_GRPC_LOCAL_PORT    (default: 50221)
  CLPR_DST_GRPC_LOCAL_PORT    (default: 30212)
  CLPR_SRC_GRPC_SERVICE       (default: network-node1-svc)
  CLPR_DST_GRPC_SERVICE       (default: network-node1-svc)
USAGE
}

die() {
  CLPR_SMOKE_FAILURE_REASON="$*"
  printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

require_env() {
  local key="$1"
  if [[ -z "${!key:-}" ]]; then
    die "Missing required environment variable: $key"
  fi
}

wait_for_tcp() {
  local host="$1"
  local port="$2"
  local timeout_seconds="$3"
  local start="$SECONDS"
  while ((SECONDS - start < timeout_seconds)); do
    if (echo >/dev/tcp/"$host"/"$port") >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.2
  done
  return 1
}

assert_no_concurrent_solo_controller() {
  local matches
  matches="$(pgrep -fl "solo " || true)"
  if [[ -z "$matches" ]]; then
    return 0
  fi

  local foreign
  foreign="$(echo "$matches" | grep -v "$$" | grep -v "run-two-ledger-smoke.sh" || true)"
  if [[ -n "$foreign" ]]; then
    die "Concurrent solo-related processes detected; enforce single-controller ownership before running smoke:
$foreign"
  fi
}

check_clpr_queue_system_contract_enabled() {
  local namespace="$1"
  local pod
  pod="$(find_node_pod "$namespace")"
  [[ -n "$pod" ]] || die "No network-node1 pod found in namespace '$namespace'"

  if ! kubectl -n "$namespace" exec "$pod" -- sh -lc '
set -e
for p in \
  /opt/hgcapp/services-hedera/HapiApp2.0/data/config/application.properties \
  /opt/hgcapp/services-hedera/HapiApp2.0/application.properties \
  $(find /opt/hgcapp/services-hedera -name application.properties 2>/dev/null); do
  if [ -f "$p" ] && grep -Eq "^contracts\.systemContract\.clprQueue\.enabled\s*=\s*true\s*$" "$p"; then
    echo "$p"
    exit 0
  fi
done
exit 1
' >/dev/null; then
    die "Queue system contract flag not enabled in namespace '$namespace'"
  fi
}

start_port_forward() {
  local namespace="$1"
  local service="$2"
  local local_port="$3"
  local log_file="$4"

  # Port-forwards are occasionally unstable under sustained gRPC polling (or during transient kube-apiserver churn).
  # Keep the forward alive by restarting it if the underlying `kubectl port-forward` process exits.
  : >"$log_file"
  (
    set +e
    while true; do
      kubectl -n "$namespace" port-forward --address 127.0.0.1 "svc/$service" "${local_port}:50211" >>"$log_file" 2>&1
      printf '[%s] WARN: port-forward exited (namespace=%s service=%s local_port=%s exit_code=%s)\n' \
        "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$namespace" "$service" "$local_port" "$?" >>"$log_file"
      sleep 0.5
    done
  ) &
  local pf_pid=$!
  PF_PIDS+=("$pf_pid")

  if ! wait_for_tcp 127.0.0.1 "$local_port" 20; then
    die "Timed out waiting for port-forward in namespace '$namespace' via service '$service' on local port $local_port"
  fi
}

assert_grpc_service_ready() {
  local namespace="$1"
  local service="$2"
  local endpoints
  endpoints="$(kubectl -n "$namespace" get endpoints "$service" -o jsonpath='{.subsets[*].ports[*].port}' 2>/dev/null || true)"
  if [[ -z "$endpoints" ]]; then
    die "No ready endpoints for service '$service' in namespace '$namespace'"
  fi
  if ! grep -q '50211' <<<"$endpoints"; then
    die "Service '$service' in namespace '$namespace' does not expose gRPC port 50211 in ready endpoints (ports='$endpoints')"
  fi
}

collect_evidence_and_cleanup() {
  local exit_code=$?

  if [[ "$CLPR_SMOKE_RESULT" != "PASS" && -z "$CLPR_SMOKE_FAILURE_REASON" ]]; then
    CLPR_SMOKE_FAILURE_REASON="run-two-ledger-smoke.sh failed with exit code $exit_code"
  fi

  for pid in "${PF_PIDS[@]:-}"; do
    kill "$pid" >/dev/null 2>&1 || true
  done
  wait >/dev/null 2>&1 || true

  RUN_DIR="$RUN_DIR" \
  SOLO_SRC_NAMESPACE="$SOLO_SRC_NAMESPACE" \
  SOLO_DST_NAMESPACE="$SOLO_DST_NAMESPACE" \
  CLPR_SMOKE_RESULT="$CLPR_SMOKE_RESULT" \
  CLPR_SMOKE_FAILURE_REASON="$CLPR_SMOKE_FAILURE_REASON" \
  COMPILE_LOG="$COMPILE_LOG" \
  BOOTSTRAP_LOG="$BOOTSTRAP_LOG" \
  DEPLOY_LOG="$DEPLOY_LOG" \
  PUMP_LOG="$PUMP_LOG" \
  INVOKE_LOG="$INVOKE_LOG" \
  PORTFWD_SRC_LOG="$PORTFWD_SRC_LOG" \
  PORTFWD_DST_LOG="$PORTFWD_DST_LOG" \
  DEPLOYMENT_JSON="$DEPLOYMENT_JSON" \
  INVOKE_RESULT_JSON="$INVOKE_RESULT_JSON" \
  "$SCRIPT_DIR/collect-evidence.sh" || true

  exit "$exit_code"
}

main() {
  if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
    usage
    exit 0
  fi

  mkdir -p "$RUN_DIR"
  trap collect_evidence_and_cleanup EXIT

  require_cmd solo
  require_cmd kubectl
  require_cmd node
  require_cmd jq
  require_env CLPR_SRC_OPERATOR_KEY
  require_env CLPR_DST_OPERATOR_KEY
  [[ -d "$CONSENSUS_NODE_REPO" ]] || die "Consensus repo not found: $CONSENSUS_NODE_REPO"

  log "Preflight: assert single-controller ownership"
  assert_no_concurrent_solo_controller

  log "Preflight: validating active Solo deployments"
  "$SCRIPT_DIR/solo-two-network-status.sh" | tee "$RUN_DIR/status.log"

  log "Preflight: verifying queue system contract enablement on both ledgers"
  check_clpr_queue_system_contract_enabled "$SOLO_SRC_NAMESPACE"
  check_clpr_queue_system_contract_enabled "$SOLO_DST_NAMESPACE"

  log "Preflight: verifying gRPC service endpoints for bootstrap clients"
  assert_grpc_service_ready "$SOLO_SRC_NAMESPACE" "$CLPR_SRC_GRPC_SERVICE"
  assert_grpc_service_ready "$SOLO_DST_NAMESPACE" "$CLPR_DST_GRPC_SERVICE"

  {
    echo "RUN_ID=$RUN_ID"
    echo "RUN_DIR=$RUN_DIR"
    echo "CONSENSUS_NODE_REPO=$CONSENSUS_NODE_REPO"
    echo "SOLO_SRC_NAMESPACE=$SOLO_SRC_NAMESPACE"
    echo "SOLO_DST_NAMESPACE=$SOLO_DST_NAMESPACE"
    echo "CLPR_SRC_GRPC_URL=$CLPR_SRC_GRPC_URL"
    echo "CLPR_DST_GRPC_URL=$CLPR_DST_GRPC_URL"
    echo "Mitigation: using Gradle --rerun-tasks for bootstrap client run."
    if compgen -G "$CONSENSUS_NODE_REPO/hedera-node/build/*-test" >/dev/null; then
      echo "Detected existing $CONSENSUS_NODE_REPO/hedera-node/build/*-test directories."
    else
      echo "No existing $CONSENSUS_NODE_REPO/hedera-node/build/*-test directories detected."
    fi
  } >"$PREFLIGHT_REPORT"

  log "Starting gRPC port-forwards"
  start_port_forward "$SOLO_SRC_NAMESPACE" "$CLPR_SRC_GRPC_SERVICE" "$CLPR_SRC_GRPC_LOCAL_PORT" "$PORTFWD_SRC_LOG"
  start_port_forward "$SOLO_DST_NAMESPACE" "$CLPR_DST_GRPC_SERVICE" "$CLPR_DST_GRPC_LOCAL_PORT" "$PORTFWD_DST_LOG"

  log "Compiling consensus test-clients helper tools"
  (
    cd "$CONSENSUS_NODE_REPO"
    ./gradlew :test-clients:compileJava --no-daemon --console=plain
  ) 2>&1 | tee "$COMPILE_LOG"

  log "Bootstrapping CLPR control-plane between ledgers"
  (
    cd "$CONSENSUS_NODE_REPO"
    CLPR_SRC_GRPC_URL="$CLPR_SRC_GRPC_URL" \
    CLPR_DST_GRPC_URL="$CLPR_DST_GRPC_URL" \
    CLPR_SRC_OPERATOR_ID="$CLPR_SRC_OPERATOR_ID" \
    CLPR_DST_OPERATOR_ID="$CLPR_DST_OPERATOR_ID" \
    CLPR_SRC_NODE_ACCOUNT_ID="$CLPR_SRC_NODE_ACCOUNT_ID" \
    CLPR_DST_NODE_ACCOUNT_ID="$CLPR_DST_NODE_ACCOUNT_ID" \
    CLPR_BOOTSTRAP_TIMEOUT_SECONDS="$CLPR_BOOTSTRAP_TIMEOUT_SECONDS" \
    ./gradlew :test-clients:runTestClient \
      -PtestClient=com.hedera.services.bdd.tools.ClprNativeQueueBootstrapMain \
      --rerun-tasks \
      --no-daemon \
      --console=plain
  ) 2>&1 | tee "$BOOTSTRAP_LOG"

  local src_ledger_hex
  local dst_ledger_hex
  src_ledger_hex="$(grep -m1 '^CLPR_BOOTSTRAP_SRC_LEDGER_ID_HEX=' "$BOOTSTRAP_LOG" | cut -d= -f2- | tr -d '\r\n')"
  dst_ledger_hex="$(grep -m1 '^CLPR_BOOTSTRAP_DST_LEDGER_ID_HEX=' "$BOOTSTRAP_LOG" | cut -d= -f2- | tr -d '\r\n')"
  [[ -n "$src_ledger_hex" ]] || die "Unable to parse source ledger id from bootstrap log"
  [[ -n "$dst_ledger_hex" ]] || die "Unable to parse destination ledger id from bootstrap log"

  log "Deploying harness contracts through HAPI/gRPC"
  CLPR_SRC_GRPC_URL="$CLPR_SRC_GRPC_URL" \
  CLPR_DST_GRPC_URL="$CLPR_DST_GRPC_URL" \
  CLPR_SRC_NODE_ACCOUNT_ID="$CLPR_SRC_NODE_ACCOUNT_ID" \
  CLPR_DST_NODE_ACCOUNT_ID="$CLPR_DST_NODE_ACCOUNT_ID" \
  CLPR_SRC_OPERATOR_ID="$CLPR_SRC_OPERATOR_ID" \
  CLPR_DST_OPERATOR_ID="$CLPR_DST_OPERATOR_ID" \
  CLPR_SRC_OPERATOR_KEY="$CLPR_SRC_OPERATOR_KEY" \
  CLPR_DST_OPERATOR_KEY="$CLPR_DST_OPERATOR_KEY" \
  CLPR_DEPLOY_OUTPUT="$DEPLOYMENT_JSON" \
  node "$SCRIPT_DIR/deploy-two-ledger-contracts.js" 2>&1 | tee "$DEPLOY_LOG"

  log "Invoking source harness and verifying destination callback + response callback"
  CLPR_SMOKE_MODE="send-only" \
  CLPR_SRC_OPERATOR_KEY="$CLPR_SRC_OPERATOR_KEY" \
  CLPR_DST_OPERATOR_KEY="$CLPR_DST_OPERATOR_KEY" \
  CLPR_DEPLOYMENT_JSON="$DEPLOYMENT_JSON" \
  CLPR_REMOTE_LEDGER_ID_HEX="$dst_ledger_hex" \
  CLPR_SMOKE_PAYLOAD="$CLPR_SMOKE_PAYLOAD" \
  CLPR_TIMEOUT_MS="$CLPR_SMOKE_TIMEOUT_MS" \
  CLPR_POLL_MS="$CLPR_SMOKE_POLL_MS" \
  CLPR_SMOKE_RESULT_OUTPUT="$INVOKE_RESULT_JSON" \
  node "$SCRIPT_DIR/run-source-invocations.js" 2>&1 | tee "$INVOKE_LOG"

  log "Pumping native queue message bundles (emulating connector delivery)"
  (
    cd "$CONSENSUS_NODE_REPO"
    CLPR_SRC_GRPC_URL="$CLPR_SRC_GRPC_URL" \
    CLPR_DST_GRPC_URL="$CLPR_DST_GRPC_URL" \
    CLPR_SRC_OPERATOR_ID="$CLPR_SRC_OPERATOR_ID" \
    CLPR_DST_OPERATOR_ID="$CLPR_DST_OPERATOR_ID" \
    CLPR_SRC_NODE_ACCOUNT_ID="$CLPR_SRC_NODE_ACCOUNT_ID" \
    CLPR_DST_NODE_ACCOUNT_ID="$CLPR_DST_NODE_ACCOUNT_ID" \
    CLPR_SRC_LEDGER_ID_HEX="$src_ledger_hex" \
    CLPR_DST_LEDGER_ID_HEX="$dst_ledger_hex" \
    CLPR_PUMP_TIMEOUT_SECONDS="$CLPR_PUMP_TIMEOUT_SECONDS" \
    ./gradlew :test-clients:runTestClient \
      -PtestClient=com.hedera.services.bdd.tools.ClprNativeQueuePumpMain \
      --rerun-tasks \
      --no-daemon \
      --console=plain
  ) 2>&1 | tee "$PUMP_LOG"

  log "Asserting destination callback + source response callback"
  CLPR_SMOKE_MODE="assert-only" \
  CLPR_SRC_OPERATOR_KEY="$CLPR_SRC_OPERATOR_KEY" \
  CLPR_DST_OPERATOR_KEY="$CLPR_DST_OPERATOR_KEY" \
  CLPR_DEPLOYMENT_JSON="$DEPLOYMENT_JSON" \
  CLPR_REMOTE_LEDGER_ID_HEX="$dst_ledger_hex" \
  CLPR_SMOKE_PAYLOAD="$CLPR_SMOKE_PAYLOAD" \
  CLPR_TIMEOUT_MS="$CLPR_SMOKE_TIMEOUT_MS" \
  CLPR_POLL_MS="$CLPR_SMOKE_POLL_MS" \
  CLPR_SMOKE_RESULT_OUTPUT="$INVOKE_RESULT_JSON" \
  node "$SCRIPT_DIR/run-source-invocations.js" 2>&1 | tee -a "$INVOKE_LOG"

  CLPR_SMOKE_RESULT="PASS"
  CLPR_SMOKE_FAILURE_REASON=""

  log "Smoke run completed successfully"
  log "Run directory: $RUN_DIR"
  echo "CLPR_SMOKE_SRC_LEDGER_ID_HEX=$src_ledger_hex"
  echo "CLPR_SMOKE_DST_LEDGER_ID_HEX=$dst_ledger_hex"
  echo "CLPR_SMOKE_DEPLOYMENT_JSON=$DEPLOYMENT_JSON"
  echo "CLPR_SMOKE_INVOKE_RESULT_JSON=$INVOKE_RESULT_JSON"
}
main "$@"
