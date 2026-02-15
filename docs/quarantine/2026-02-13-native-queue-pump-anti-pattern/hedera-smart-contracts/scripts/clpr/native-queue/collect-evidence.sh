#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

RUN_DIR="${RUN_DIR:?RUN_DIR is required}"
SOLO_SRC_NAMESPACE="${SOLO_SRC_NAMESPACE:-solo-clpr-native-src}"
SOLO_DST_NAMESPACE="${SOLO_DST_NAMESPACE:-solo-clpr-native-dst}"
CLPR_SMOKE_RESULT="${CLPR_SMOKE_RESULT:-UNKNOWN}"
CLPR_SMOKE_FAILURE_REASON="${CLPR_SMOKE_FAILURE_REASON:-}"

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

ensure_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "Missing required command: $1" >&2
    exit 1
  }
}

capture_namespace_state() {
  local ns="$1"
  local out_dir="$2"

  mkdir -p "$out_dir"

  kubectl get pods -n "$ns" -o wide >"$out_dir/pods.txt" 2>&1 || true
  kubectl get svc -n "$ns" -o wide >"$out_dir/services.txt" 2>&1 || true
  kubectl get configmap -n "$ns" >"$out_dir/configmaps.txt" 2>&1 || true
  kubectl get ingress -n "$ns" >"$out_dir/ingress.txt" 2>&1 || true
  kubectl describe pod -n "$ns" network-node1-0 >"$out_dir/network-node1-describe.txt" 2>&1 || true
  kubectl logs -n "$ns" network-node1-0 -c root-container --tail=3000 >"$out_dir/network-node1-root.log" 2>&1 || true
  kubectl logs -n "$ns" network-node1-0 -c record-stream-uploader --tail=2000 \
    >"$out_dir/network-node1-record-stream-uploader.log" 2>&1 || true
  kubectl logs -n "$ns" network-node1-0 -c blockstream-uploader --tail=2000 \
    >"$out_dir/network-node1-blockstream-uploader.log" 2>&1 || true

  # The node writes key diagnostics to files under /opt/hgcapp/.../output; `kubectl logs` can miss them.
  kubectl -n "$ns" exec network-node1-0 -c root-container -- sh -lc '
set -e
OUT=/opt/hgcapp/services-hedera/HapiApp2.0/output
ls -al "$OUT" || true
' >"$out_dir/network-node1-output-dir.txt" 2>&1 || true

  kubectl -n "$ns" exec network-node1-0 -c root-container -- sh -lc '
set -e
LOG=/opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log
if [ -f "$LOG" ]; then
  tail -n 4000 "$LOG"
else
  echo "Missing $LOG"
fi
' >"$out_dir/network-node1-hgcaa.tail.log" 2>&1 || true

  kubectl -n "$ns" exec network-node1-0 -c root-container -- sh -lc '
set -e
LOG=/opt/hgcapp/services-hedera/HapiApp2.0/output/swirlds.log
if [ -f "$LOG" ]; then
  tail -n 4000 "$LOG"
else
  echo "Missing $LOG"
fi
' >"$out_dir/network-node1-swirlds.tail.log" 2>&1 || true

  kubectl -n "$ns" exec network-node1-0 -c root-container -- sh -lc '
set -e
for p in \
  /opt/hgcapp/services-hedera/HapiApp2.0/data/config/application.properties \
  /opt/hgcapp/services-hedera/HapiApp2.0/application.properties \
  $(find /opt/hgcapp/services-hedera -name application.properties 2>/dev/null); do
  if [ -f "$p" ]; then
    echo "FILE=$p"
    grep -E "^(clpr\\.|contracts\\.systemContract\\.clprQueue\\.enabled)" "$p" || true
    echo
  fi
done
' >"$out_dir/application-properties-snapshot.txt" 2>&1 || true
}

copy_if_exists() {
  local src="$1"
  local dst="$2"
  if [[ -n "$src" && -f "$src" ]]; then
    if [[ "$src" == "$dst" ]]; then
      return 0
    fi
    cp "$src" "$dst" || true
  fi
}

main() {
  ensure_cmd kubectl

  mkdir -p "$RUN_DIR"
  local k8s_dir="$RUN_DIR/k8s"
  mkdir -p "$k8s_dir"

  log "Capturing namespace state for '$SOLO_SRC_NAMESPACE'"
  capture_namespace_state "$SOLO_SRC_NAMESPACE" "$k8s_dir/src"

  log "Capturing namespace state for '$SOLO_DST_NAMESPACE'"
  capture_namespace_state "$SOLO_DST_NAMESPACE" "$k8s_dir/dst"

  local logs_dir="$RUN_DIR/logs"
  mkdir -p "$logs_dir"

  copy_if_exists "${COMPILE_LOG:-}" "$logs_dir/compile.log"
  copy_if_exists "${BOOTSTRAP_LOG:-}" "$logs_dir/bootstrap.log"
  copy_if_exists "${DEPLOY_LOG:-}" "$logs_dir/deploy.log"
  copy_if_exists "${PUMP_LOG:-}" "$logs_dir/pump.log"
  copy_if_exists "${INVOKE_LOG:-}" "$logs_dir/invoke.log"
  copy_if_exists "${PORTFWD_SRC_LOG:-}" "$logs_dir/portforward-src.log"
  copy_if_exists "${PORTFWD_DST_LOG:-}" "$logs_dir/portforward-dst.log"

  copy_if_exists "${DEPLOYMENT_JSON:-}" "$RUN_DIR/deployment.json"
  copy_if_exists "${INVOKE_RESULT_JSON:-}" "$RUN_DIR/invoke-result.json"

  cat >"$RUN_DIR/smoke-summary.md" <<EOF
# Solo Two-Ledger Native Queue Smoke Summary

- Result: \`$CLPR_SMOKE_RESULT\`
- Failure reason: \`${CLPR_SMOKE_FAILURE_REASON:-none}\`
- Run directory: \`$RUN_DIR\`
- Source namespace: \`$SOLO_SRC_NAMESPACE\`
- Destination namespace: \`$SOLO_DST_NAMESPACE\`

## Key Evidence Files

- \`$RUN_DIR/logs/bootstrap.log\`
- \`$RUN_DIR/logs/deploy.log\`
- \`$RUN_DIR/logs/pump.log\`
- \`$RUN_DIR/logs/invoke.log\`
- \`$RUN_DIR/deployment.json\`
- \`$RUN_DIR/invoke-result.json\`
- \`$RUN_DIR/k8s/src/network-node1-root.log\`
- \`$RUN_DIR/k8s/dst/network-node1-root.log\`
- \`$RUN_DIR/k8s/src/network-node1-hgcaa.tail.log\`
- \`$RUN_DIR/k8s/dst/network-node1-hgcaa.tail.log\`
- \`$RUN_DIR/k8s/src/network-node1-swirlds.tail.log\`
- \`$RUN_DIR/k8s/dst/network-node1-swirlds.tail.log\`
EOF

  log "Evidence collection complete: $RUN_DIR"
}

main "$@"
