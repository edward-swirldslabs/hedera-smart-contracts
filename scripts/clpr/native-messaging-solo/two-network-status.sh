#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0")

Checks health for both native-messaging SOLO deployments.
Returns non-zero if any required check fails.
USAGE
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

require_cmd kubectl
require_cmd solo

get_remote_consensus_phase() {
  local namespace="$1"
  kubectl get configmap solo-remote-config -n "$namespace" -o jsonpath='{.data.remote-config-data}' 2>/dev/null \
    | awk '/consensusNodes:/{f=1} f && /phase:/{print $2; exit}'
}

check_properties() {
  local namespace="$1"
  local pod="$2"
  local prop_regex="$3"
  kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc "
set -e
for p in \
  /opt/hgcapp/services-hedera/HapiApp2.0/data/config/application.properties \
  /opt/hgcapp/services-hedera/HapiApp2.0/application.properties; do
  if [ -f \"\$p\" ] && grep -Eq \"$prop_regex\" \"\$p\"; then
    exit 0
  fi
done
exit 1
"
}

check_namespace_health() {
  local namespace="$1"
  local deployment="$2"
  local failures=0

  log "Checking namespace '$namespace' (deployment '$deployment')"

  if ! kubectl get namespace "$namespace" >/dev/null 2>&1; then
    warn "Namespace not found: $namespace"
    return 1
  fi

  local pod
  pod="$(find_node_pod "$namespace")"

  if [[ -z "$pod" ]]; then
    warn "No consensus node pod found in namespace '$namespace'"
    failures=$((failures + 1))
  else
    local phase
    phase="$(kubectl -n "$namespace" get pod "$pod" -o jsonpath='{.status.phase}')"
    if [[ "$phase" != "Running" ]]; then
      warn "Consensus pod not running in namespace '$namespace': $pod ($phase)"
      failures=$((failures + 1))
    else
      log "Consensus pod running: $pod"

      if ! kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc \
        "ps -ef | grep '[c]om.hedera.node.app.ServicesMain' >/dev/null"; then
        warn "Consensus JVM process not running in namespace '$namespace' pod '$pod'"
        failures=$((failures + 1))
      else
        log "Consensus JVM process is running in $pod"
      fi

      if ! kubectl -n "$namespace" exec "$pod" -c root-container -- bash -lc \
        "timeout 2 bash -lc 'echo >/dev/tcp/127.0.0.1/50211' >/dev/null 2>&1"; then
        warn "Consensus gRPC port 50211 not reachable inside namespace '$namespace' pod '$pod'"
        failures=$((failures + 1))
      else
        log "Consensus gRPC port 50211 reachable in $pod"
      fi

      if ! check_properties "$namespace" "$pod" '^clpr\\.clprEnabled\\s*=\\s*true\\s*$'; then
        warn "Could not confirm clpr.clprEnabled=true in '$namespace'"
        failures=$((failures + 1))
      else
        log "CLPR enabled configuration confirmed in '$namespace'"
      fi

      if ! check_properties "$namespace" "$pod" '^clpr\\.publicizeNetworkAddresses\\s*=\\s*true\\s*$'; then
        warn "Could not confirm clpr.publicizeNetworkAddresses=true in '$namespace'"
        failures=$((failures + 1))
      else
        log "CLPR endpoint publicizing confirmed in '$namespace'"
      fi

      if ! check_properties "$namespace" "$pod" '^contracts\\.systemContract\\.clprQueue\\.enabled\\s*=\\s*true\\s*$'; then
        warn "Could not confirm contracts.systemContract.clprQueue.enabled=true in '$namespace'"
        failures=$((failures + 1))
      else
        log "CLPR queue system contract enabled configuration confirmed in '$namespace'"
      fi
    fi
  fi

  if ! kubectl -n "$namespace" get svc haproxy-node1-svc >/dev/null 2>&1; then
    warn "Missing expected service haproxy-node1-svc in namespace '$namespace'"
    failures=$((failures + 1))
  else
    log "Service present: haproxy-node1-svc"
  fi

  if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
    local block_node_svc
    block_node_svc="$(find_block_node_service "$namespace")"
    if [[ -z "$block_node_svc" ]]; then
      warn "Block node service not found in namespace '$namespace'"
      failures=$((failures + 1))
    else
      log "Block node service present: $block_node_svc"
      if ! kubectl -n "$namespace" get endpoints "$block_node_svc" -o jsonpath='{.subsets[0].addresses[0].ip}' 2>/dev/null | grep -Eq '.'; then
        warn "Block node service '$block_node_svc' has no ready endpoints in namespace '$namespace'"
        failures=$((failures + 1))
      else
        log "Block node service '$block_node_svc' has ready endpoints"
      fi
    fi
  fi

  if [[ "$SOLO_ENABLE_MIRROR" == "true" ]]; then
    local importer_pod
    importer_pod="$(kubectl -n "$namespace" get pods -l app.kubernetes.io/component=importer -o name 2>/dev/null | head -n 1 | sed 's#^pod/##')"
    if [[ -z "$importer_pod" ]]; then
      warn "Mirror importer pod not found in namespace '$namespace'"
      failures=$((failures + 1))
    else
      log "Mirror importer pod present: $importer_pod"
      if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
        if ! kubectl -n "$namespace" exec "$importer_pod" -- sh -lc 'printenv | grep -Eq "^SPRING_PROFILES_ACTIVE=blocknode$"'; then
          warn "Mirror importer in '$namespace' is not running with SPRING_PROFILES_ACTIVE=blocknode"
          failures=$((failures + 1))
        else
          log "Mirror importer in '$namespace' confirmed with blocknode profile"
        fi
      fi
    fi
  fi

  local remote_phase
  remote_phase="$(get_remote_consensus_phase "$namespace" || true)"
  if [[ -z "$remote_phase" ]]; then
    warn "Could not read consensus node phase from solo-remote-config in namespace '$namespace'"
  else
    log "Control-plane consensus phase in '$namespace': $remote_phase"
    if [[ "$remote_phase" == "stopped" || "$remote_phase" == "configured" ]]; then
      warn "Runtime checks passed but control-plane phase is '$remote_phase' in '$namespace' (known Solo drift in local-build dev mode)"
    fi
  fi

  if [[ $failures -ne 0 ]]; then
    warn "Namespace '$namespace' failed $failures check(s)"
    return 1
  fi

  log "Namespace '$namespace' passed all checks"
  return 0
}

errors=0

if ! deployment_exists "$SOLO_SRC_DEPLOYMENT"; then
  warn "Source deployment config missing in cluster '$SOLO_CLUSTER_REF': $SOLO_SRC_DEPLOYMENT"
  errors=$((errors + 1))
fi
if ! deployment_exists "$SOLO_DST_DEPLOYMENT"; then
  warn "Destination deployment config missing in cluster '$SOLO_CLUSTER_REF': $SOLO_DST_DEPLOYMENT"
  errors=$((errors + 1))
fi

if ! check_namespace_health "$SOLO_SRC_NAMESPACE" "$SOLO_SRC_DEPLOYMENT"; then
  errors=$((errors + 1))
fi
if ! check_namespace_health "$SOLO_DST_NAMESPACE" "$SOLO_DST_DEPLOYMENT"; then
  errors=$((errors + 1))
fi

if [[ $errors -ne 0 ]]; then
  die "Status checks failed with $errors error(s)."
fi

log "All status checks passed"
