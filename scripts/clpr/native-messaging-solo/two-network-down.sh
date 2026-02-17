#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--keep-config]

Stops and destroys both SOLO deployments used for CLPR native messaging runs.
USAGE
}

KEEP_CONFIG=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --keep-config)
      KEEP_CONFIG=true
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

require_cmd solo
require_cmd kubectl

destroy_deployment() {
  local deployment="$1"

  if ! deployment_exists "$deployment"; then
    warn "Deployment not found in local config for cluster '$SOLO_CLUSTER_REF': $deployment"
    return 0
  fi

  log "Stopping node(s) for '$deployment'"
  solo consensus node stop -d "$deployment" -i "$SOLO_NODE_ALIASES" "${DEV_ARGS[@]}" -q || warn "Node stop failed for $deployment"

  if [[ "$SOLO_ENABLE_RELAY" == "true" ]]; then
    log "Destroying relay for '$deployment' (if present)"
    solo relay node destroy -d "$deployment" -i "$SOLO_NODE_ALIASES" "${DEV_ARGS[@]}" -q || true
  fi

  if [[ "$SOLO_ENABLE_MIRROR" == "true" ]]; then
    log "Destroying mirror for '$deployment' (if present)"
    solo mirror node destroy -d "$deployment" --force "${DEV_ARGS[@]}" -q || true
  fi

  if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
    log "Destroying block node for '$deployment' (if present)"
    solo block node destroy -d "$deployment" --force "${DEV_ARGS[@]}" -q || true
  fi

  log "Destroying consensus network for '$deployment'"
  solo consensus network destroy -d "$deployment" --delete-pvcs --delete-secrets --force "${DEV_ARGS[@]}" -q || \
    solo consensus network destroy -d "$deployment" --force "${DEV_ARGS[@]}" -q

  if [[ "$KEEP_CONFIG" == "false" ]]; then
    log "Deleting local deployment config for '$deployment'"
    solo deployment config delete -d "$deployment" "${DEV_ARGS[@]}" -q || warn "Could not delete local config for $deployment"
  fi
}

destroy_deployment "$SOLO_SRC_DEPLOYMENT"
destroy_deployment "$SOLO_DST_DEPLOYMENT"

log "Two-network teardown completed"
