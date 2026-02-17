#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed directly."
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
DEFAULT_CN_LOCAL_BUILD_PATH="$PROJECT_ROOT/../hiero-consensus-node/hedera-node/data"

# Convenience for parallel workstreams:
# If set, CLPR_SOLO_HOME will be exported as SOLO_HOME for all Solo CLI commands invoked by these scripts.
# (Solo reads SOLO_HOME as its local state/config directory, defaulting to ~/.solo when unset.)
if [[ -n "${CLPR_SOLO_HOME:-}" ]]; then
  export SOLO_HOME="$CLPR_SOLO_HOME"
fi

SOLO_CLUSTER_CONTEXT="${SOLO_CLUSTER_CONTEXT:-docker-desktop}"
SOLO_CLUSTER_REF="${SOLO_CLUSTER_REF:-solo-shared}"
SOLO_CLUSTER_SETUP_NAMESPACE="${SOLO_CLUSTER_SETUP_NAMESPACE:-solo-setup}"

SOLO_SRC_DEPLOYMENT="${SOLO_SRC_DEPLOYMENT:-solo-int-src}"
SOLO_DST_DEPLOYMENT="${SOLO_DST_DEPLOYMENT:-solo-int-dst}"
SOLO_SRC_NAMESPACE="${SOLO_SRC_NAMESPACE:-solo-int-src}"
SOLO_DST_NAMESPACE="${SOLO_DST_NAMESPACE:-solo-int-dst}"

SOLO_NODE_ALIASES="${SOLO_NODE_ALIASES:-node1}"
SOLO_NUM_NODES="${SOLO_NUM_NODES:-1}"
SOLO_PROFILE="${SOLO_PROFILE:-local}"

SOLO_ENABLE_BLOCK_NODE="${SOLO_ENABLE_BLOCK_NODE:-false}"
SOLO_ENABLE_MIRROR="${SOLO_ENABLE_MIRROR:-false}"
SOLO_ENABLE_RELAY="${SOLO_ENABLE_RELAY:-false}"
SOLO_DEV_MODE="${SOLO_DEV_MODE:-true}"

CN_LOCAL_BUILD_PATH="${CN_LOCAL_BUILD_PATH:-$DEFAULT_CN_LOCAL_BUILD_PATH}"
SOLO_CONSENSUS_RELEASE_TAG="${SOLO_CONSENSUS_RELEASE_TAG:-}"
SOLO_BLOCK_NODE_RELEASE_TAG="${SOLO_BLOCK_NODE_RELEASE_TAG:-}"

SRC_APP_PROPERTIES="${SRC_APP_PROPERTIES:-$SCRIPT_DIR/config/application-src.properties}"
DST_APP_PROPERTIES="${DST_APP_PROPERTIES:-$SCRIPT_DIR/config/application-dst.properties}"

ARTIFACT_ROOT="${ARTIFACT_ROOT:-$PROJECT_ROOT/artifacts/clpr-native-messaging-solo}"
RUN_ID="${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)}"
RUN_DIR="$ARTIFACT_ROOT/$RUN_ID"
RUN_MANIFEST="$RUN_DIR/run-manifest.env"

DEV_ARGS=()
if [[ "$SOLO_DEV_MODE" == "true" ]]; then
  DEV_ARGS=(--dev)
fi

log() {
  printf '[%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

warn() {
  printf '[%s] WARN: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
}

die() {
  printf '[%s] ERROR: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

cluster_ref_exists() {
  solo cluster-ref config list -q 2>/dev/null | grep -Eq " - ${SOLO_CLUSTER_REF}:"
}

deployment_exists() {
  local deployment="$1"
  solo deployment config list -c "$SOLO_CLUSTER_REF" -q 2>/dev/null | grep -Eq " - ${deployment}$"
}

require_prereqs() {
  require_cmd solo
  require_cmd kubectl
  require_cmd grep
  require_cmd java
  require_cmd javac
  if [[ -z "${SOLO_HOME:-}" ]]; then
    warn "SOLO_HOME is not set; Solo will use the default (~/.solo). For parallel workstreams, set SOLO_HOME (or CLPR_SOLO_HOME) to a workstream-specific directory."
  fi
  [[ -d "$CN_LOCAL_BUILD_PATH" ]] || die "Consensus local build path not found: $CN_LOCAL_BUILD_PATH"
  [[ -f "$SRC_APP_PROPERTIES" ]] || die "Missing source app properties file: $SRC_APP_PROPERTIES"
  [[ -f "$DST_APP_PROPERTIES" ]] || die "Missing destination app properties file: $DST_APP_PROPERTIES"
}

write_run_manifest() {
  mkdir -p "$RUN_DIR"
  cat >"$RUN_MANIFEST" <<MANIFEST
RUN_ID=$RUN_ID
SOLO_HOME=${SOLO_HOME:-}
SOLO_CLUSTER_CONTEXT=$SOLO_CLUSTER_CONTEXT
SOLO_CLUSTER_REF=$SOLO_CLUSTER_REF
SOLO_CLUSTER_SETUP_NAMESPACE=$SOLO_CLUSTER_SETUP_NAMESPACE
SOLO_SRC_DEPLOYMENT=$SOLO_SRC_DEPLOYMENT
SOLO_DST_DEPLOYMENT=$SOLO_DST_DEPLOYMENT
SOLO_SRC_NAMESPACE=$SOLO_SRC_NAMESPACE
SOLO_DST_NAMESPACE=$SOLO_DST_NAMESPACE
SOLO_NODE_ALIASES=$SOLO_NODE_ALIASES
SOLO_NUM_NODES=$SOLO_NUM_NODES
SOLO_PROFILE=$SOLO_PROFILE
SOLO_ENABLE_BLOCK_NODE=$SOLO_ENABLE_BLOCK_NODE
SOLO_ENABLE_MIRROR=$SOLO_ENABLE_MIRROR
SOLO_ENABLE_RELAY=$SOLO_ENABLE_RELAY
SOLO_DEV_MODE=$SOLO_DEV_MODE
CN_LOCAL_BUILD_PATH=$CN_LOCAL_BUILD_PATH
SOLO_CONSENSUS_RELEASE_TAG=$SOLO_CONSENSUS_RELEASE_TAG
SOLO_BLOCK_NODE_RELEASE_TAG=$SOLO_BLOCK_NODE_RELEASE_TAG
SRC_APP_PROPERTIES=$SRC_APP_PROPERTIES
DST_APP_PROPERTIES=$DST_APP_PROPERTIES
MANIFEST
}

ensure_cluster_ref() {
  if cluster_ref_exists; then
    log "Cluster reference already exists: $SOLO_CLUSTER_REF"
  else
    log "Connecting cluster reference '$SOLO_CLUSTER_REF' -> context '$SOLO_CLUSTER_CONTEXT'"
    solo cluster-ref config connect -c "$SOLO_CLUSTER_REF" --context "$SOLO_CLUSTER_CONTEXT" -q
  fi

  if [[ "${SOLO_SKIP_CLUSTER_SETUP:-false}" == "true" ]]; then
    warn "Skipping 'solo cluster-ref config setup' because SOLO_SKIP_CLUSTER_SETUP=true (caller is responsible for cluster-scoped setup)."
    return 0
  fi

  log "Ensuring shared cluster setup in namespace '$SOLO_CLUSTER_SETUP_NAMESPACE'"
  solo cluster-ref config setup -c "$SOLO_CLUSTER_REF" -s "$SOLO_CLUSTER_SETUP_NAMESPACE" "${DEV_ARGS[@]}" -q
}

find_node_pod() {
  local namespace="$1"
  kubectl -n "$namespace" get pods -o name | grep '^pod/network-node1' | head -n 1 | sed 's#^pod/##'
}

find_block_node_service() {
  local namespace="$1"
  kubectl -n "$namespace" get svc -o name | grep '^service/block-node' | head -n 1 | sed 's#^service/##'
}

check_clpr_enabled() {
  local namespace="$1"
  local pod
  pod="$(find_node_pod "$namespace")"
  [[ -n "$pod" ]] || die "No network-node1 pod found in namespace '$namespace'"

  kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc '
set -e
for p in \
  /opt/hgcapp/services-hedera/HapiApp2.0/data/config/application.properties \
  /opt/hgcapp/services-hedera/HapiApp2.0/application.properties \
  $(find /opt/hgcapp/services-hedera -name application.properties 2>/dev/null); do
  if [ -f "$p" ] && grep -Eq "^clpr\\.clprEnabled\\s*=\\s*true\\s*$" "$p"; then
    echo "$p"
    exit 0
  fi
done
exit 1
' >/dev/null
}
