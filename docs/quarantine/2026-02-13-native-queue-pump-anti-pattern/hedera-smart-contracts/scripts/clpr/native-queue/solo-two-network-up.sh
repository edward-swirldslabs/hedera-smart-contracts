#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--force]

Creates two Solo deployments using local consensus-node build artifacts.

Environment overrides:
  SOLO_CLUSTER_CONTEXT         (default: docker-desktop)
  SOLO_CLUSTER_REF             (default: solo-clpr-native)
  SOLO_SRC_DEPLOYMENT          (default: solo-clpr-native-src)
  SOLO_DST_DEPLOYMENT          (default: solo-clpr-native-dst)
  SOLO_SRC_NAMESPACE           (default: solo-clpr-native-src)
  SOLO_DST_NAMESPACE           (default: solo-clpr-native-dst)
  SOLO_NODE_ALIASES            (default: node1)
  SOLO_NUM_NODES               (default: 1)
  SOLO_PROFILE                 (default: local)
  CN_LOCAL_BUILD_PATH          (default: ../hiero-consensus-node/hedera-node/data)
  SOLO_CONSENSUS_RELEASE_TAG   (optional)
  SOLO_ENABLE_MIRROR           (default: false)
  SOLO_ENABLE_RELAY            (default: false)
  SOLO_DEV_MODE                (default: true)
USAGE
}

FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)
      FORCE=true
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
ensure_cluster_ref

if deployment_exists "$SOLO_SRC_DEPLOYMENT" || deployment_exists "$SOLO_DST_DEPLOYMENT"; then
  if [[ "$FORCE" == "true" ]]; then
    log "Existing deployment(s) found and --force enabled. Running teardown first."
    "$SCRIPT_DIR/solo-two-network-down.sh"
  else
    die "Deployment already exists for cluster ref '$SOLO_CLUSTER_REF'. Run solo-two-network-down.sh or use --force."
  fi
fi

setup_deployment() {
  local deployment="$1"
  local namespace="$2"
  local app_properties="$3"

  log "Creating deployment config: deployment='$deployment' namespace='$namespace'"
  solo deployment config create -d "$deployment" -n "$namespace" "${DEV_ARGS[@]}" -q

  log "Attaching deployment '$deployment' to cluster '$SOLO_CLUSTER_REF'"
  solo deployment cluster attach -d "$deployment" -c "$SOLO_CLUSTER_REF" --num-consensus-nodes "$SOLO_NUM_NODES" "${DEV_ARGS[@]}" -q

  log "Generating consensus keys for '$deployment'"
  solo keys consensus generate -d "$deployment" --gossip-keys --tls-keys -i "$SOLO_NODE_ALIASES" "${DEV_ARGS[@]}" -q

  local deploy_cmd=(
    solo consensus network deploy
    -d "$deployment"
    -i "$SOLO_NODE_ALIASES"
    --profile "$SOLO_PROFILE"
    --application-properties "$app_properties"
    "${DEV_ARGS[@]}"
    -q
  )

  if [[ -n "$SOLO_CONSENSUS_RELEASE_TAG" ]]; then
    deploy_cmd+=(--release-tag "$SOLO_CONSENSUS_RELEASE_TAG")
  fi

  log "Deploying consensus network for '$deployment'"
  "${deploy_cmd[@]}"

  local setup_cmd=(
    solo consensus node setup
    -d "$deployment"
    -i "$SOLO_NODE_ALIASES"
    --local-build-path "$CN_LOCAL_BUILD_PATH"
    "${DEV_ARGS[@]}"
    -q
  )

  if [[ -n "$SOLO_CONSENSUS_RELEASE_TAG" ]]; then
    setup_cmd+=(--release-tag "$SOLO_CONSENSUS_RELEASE_TAG")
  fi

  log "Applying local build artifacts to deployment '$deployment'"
  "${setup_cmd[@]}"

  log "Starting node(s) for deployment '$deployment'"
  local start_log
  start_log="$(mktemp)"
  if ! solo consensus node start -d "$deployment" -i "$SOLO_NODE_ALIASES" "${DEV_ARGS[@]}" -q >"$start_log" 2>&1; then
    cat "$start_log"
    if grep -q "set gRPC Web endpoint" "$start_log" && grep -q "INVALID_NODE_ID" "$start_log"; then
      warn "Ignoring SOLO gRPC Web endpoint update failure (INVALID_NODE_ID) for '$deployment'; continuing after health validation."
    else
      rm -f "$start_log"
      die "Failed to start deployment '$deployment'"
    fi
  else
    cat "$start_log"
  fi
  rm -f "$start_log"

  if [[ "$SOLO_ENABLE_MIRROR" == "true" ]]; then
    log "Adding mirror node for deployment '$deployment'"
    solo mirror node add -d "$deployment" --profile tiny "${DEV_ARGS[@]}" -q
  fi

  if [[ "$SOLO_ENABLE_RELAY" == "true" ]]; then
    log "Adding relay node for deployment '$deployment'"
    solo relay node add -d "$deployment" -i "$SOLO_NODE_ALIASES" --profile tiny "${DEV_ARGS[@]}" -q
  fi
}

setup_deployment "$SOLO_SRC_DEPLOYMENT" "$SOLO_SRC_NAMESPACE" "$SRC_APP_PROPERTIES"
setup_deployment "$SOLO_DST_DEPLOYMENT" "$SOLO_DST_NAMESPACE" "$DST_APP_PROPERTIES"

log "Running health checks"
"$SCRIPT_DIR/solo-two-network-status.sh"

log "Issue-0002 setup completed. Run manifest: $RUN_MANIFEST"
