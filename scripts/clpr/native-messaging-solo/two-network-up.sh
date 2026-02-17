#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./lib.sh
source "$SCRIPT_DIR/lib.sh"

usage() {
  cat <<USAGE
Usage: $(basename "$0") [--force]

Creates two SOLO deployments using local consensus-node build artifacts and CLPR native messaging.

Environment overrides:
  CLPR_SOLO_HOME               (optional; if set, exported as SOLO_HOME for all Solo CLI commands)
  SOLO_HOME                    (optional; Solo local state dir; set for parallel workstreams to avoid ~/.solo collisions)
  SOLO_SKIP_CLUSTER_SETUP      (optional; when true, skip 'solo cluster-ref config setup' to avoid concurrent cluster-scoped operations)
  SOLO_CLUSTER_CONTEXT         (default: docker-desktop)
  SOLO_CLUSTER_REF             (default: solo-shared)
  SOLO_SRC_DEPLOYMENT          (default: solo-int-src)
  SOLO_DST_DEPLOYMENT          (default: solo-int-dst)
  SOLO_SRC_NAMESPACE           (default: solo-int-src)
  SOLO_DST_NAMESPACE           (default: solo-int-dst)
  SOLO_NODE_ALIASES            (default: node1)
  SOLO_NUM_NODES               (default: 1)
  SOLO_PROFILE                 (default: local)
  CN_LOCAL_BUILD_PATH          (default: ../hiero-consensus-node/hedera-node/data)
  SOLO_CONSENSUS_RELEASE_TAG   (optional)
  SOLO_ENABLE_BLOCK_NODE       (default: false)
  SOLO_BLOCK_NODE_RELEASE_TAG  (optional; defaults to Solo CLI release defaults)
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
    "$SCRIPT_DIR/two-network-down.sh"
  else
    die "Deployment already exists for cluster ref '$SOLO_CLUSTER_REF'. Run two-network-down.sh or use --force."
  fi
fi

write_mirror_block_node_values() {
  local namespace="$1"
  local deployment="$2"
  local values_file="$RUN_DIR/mirror-${deployment}-block-node-values.yaml"

  cat >"$values_file" <<EOF
importer:
  env:
    # TEMP-OBSERVABILITY/BOOTSTRAP: explicit block-node profile wiring for Solo while mirror auto-wiring is disabled.
    SPRING_PROFILES_ACTIVE: "blocknode"
    HIERO_MIRROR_IMPORTER_BLOCK_NODES_0_HOST: "block-node-1.${namespace}.svc.cluster.local"
    HIERO_MIRROR_IMPORTER_BLOCK_NODES_0_PORT: "40840"
EOF

  echo "$values_file"
}

normalize_block_nodes_configmaps() {
  local namespace="$1"

  IFS=',' read -r -a node_aliases <<< "$SOLO_NODE_ALIASES"
  for raw_alias in "${node_aliases[@]}"; do
    local alias="$raw_alias"
    alias="${alias#"${alias%%[![:space:]]*}"}"
    alias="${alias%"${alias##*[![:space:]]}"}"
    [[ -n "$alias" ]] || continue

    local cm_name="network-${alias}-data-config-cm"
    if ! kubectl -n "$namespace" get configmap "$cm_name" >/dev/null 2>&1; then
      warn "ConfigMap '$cm_name' not found in namespace '$namespace' while normalizing block-nodes.json"
      continue
    fi

    local block_nodes_json
    block_nodes_json="$(kubectl -n "$namespace" get configmap "$cm_name" -o jsonpath='{.data.block-nodes\.json}' || true)"
    if [[ -z "$block_nodes_json" ]]; then
      warn "ConfigMap '$cm_name' has no block-nodes.json entry"
      continue
    fi

    local normalized_json
    normalized_json="$(node -e '
const fs = require("node:fs");
const input = fs.readFileSync(0, "utf8").trim();
const obj = JSON.parse(input);
if (Array.isArray(obj.nodes)) {
  for (const node of obj.nodes) {
    if (node && typeof node === "object") {
      if (node.port != null && node.streamingPort == null) {
        const port = Number(node.port);
        node.streamingPort = port;
        if (node.servicePort == null) node.servicePort = port;
        delete node.port;
      } else if (node.streamingPort != null && node.servicePort == null) {
        node.servicePort = Number(node.streamingPort);
      }
    }
  }
}
process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
' <<< "$block_nodes_json")"

    local patch_file
    patch_file="$(mktemp)"
    {
      echo "data:"
      echo "  block-nodes.json: |"
      echo "$normalized_json" | sed 's/^/    /'
    } >"$patch_file"
    kubectl -n "$namespace" patch configmap "$cm_name" --type merge --patch-file "$patch_file" >/dev/null
    rm -f "$patch_file"

    log "Normalized block-nodes schema in '$namespace/$cm_name' to streamingPort/servicePort"
  done
}

normalize_block_nodes_runtime_files() {
  local namespace="$1"
  local remote_path="/opt/hgcapp/services-hedera/HapiApp2.0/data/config/block-nodes.json"

  IFS=',' read -r -a node_aliases <<< "$SOLO_NODE_ALIASES"
  for raw_alias in "${node_aliases[@]}"; do
    local alias="$raw_alias"
    alias="${alias#"${alias%%[![:space:]]*}"}"
    alias="${alias%"${alias##*[![:space:]]}"}"
    [[ -n "$alias" ]] || continue

    local pod
    pod="$(kubectl -n "$namespace" get pods -o name | grep "^pod/network-${alias}" | head -n 1 | sed 's#^pod/##')"
    if [[ -z "$pod" ]]; then
      warn "Could not find pod for node alias '$alias' in namespace '$namespace' while normalizing runtime block-nodes.json"
      continue
    fi

    local block_nodes_json
    if ! block_nodes_json="$(kubectl -n "$namespace" exec "$pod" -c root-container -- cat "$remote_path" 2>/dev/null)"; then
      warn "Could not read runtime block-nodes.json from '$namespace/$pod:$remote_path'"
      continue
    fi

    local normalized_json
    normalized_json="$(node -e '
const fs = require("node:fs");
const input = fs.readFileSync(0, "utf8").trim();
const obj = JSON.parse(input);
if (Array.isArray(obj.nodes)) {
  for (const node of obj.nodes) {
    if (node && typeof node === "object") {
      if (node.port != null && node.streamingPort == null) {
        const port = Number(node.port);
        node.streamingPort = port;
        if (node.servicePort == null) node.servicePort = port;
        delete node.port;
      } else if (node.streamingPort != null && node.servicePort == null) {
        node.servicePort = Number(node.streamingPort);
      }
    }
  }
}
process.stdout.write(`${JSON.stringify(obj, null, 2)}\n`);
' <<< "$block_nodes_json")"

    local tmp_file
    tmp_file="$(mktemp)"
    printf '%s' "$normalized_json" >"$tmp_file"
    kubectl -n "$namespace" cp "$tmp_file" "$pod:$remote_path" -c root-container >/dev/null
    rm -f "$tmp_file"

    # Keep ownership/permissions compatible with the consensus node process user.
    kubectl -n "$namespace" exec "$pod" -c root-container -- sh -lc "chown hedera:hedera '$remote_path' && chmod 755 '$remote_path'"

    log "Normalized runtime block-nodes file in '$namespace/$pod' for node alias '$alias'"
  done
}

setup_deployment() {
  local deployment="$1"
  local namespace="$2"
  local app_properties="$3"

  log "Creating deployment config: deployment='$deployment' namespace='$namespace'"
  solo deployment config create -d "$deployment" -n "$namespace" "${DEV_ARGS[@]}" -q

  log "Attaching deployment '$deployment' to cluster '$SOLO_CLUSTER_REF'"
  solo deployment cluster attach -d "$deployment" -c "$SOLO_CLUSTER_REF" --num-consensus-nodes "$SOLO_NUM_NODES" "${DEV_ARGS[@]}" -q

  if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
    local block_cmd=(
      solo block node add
      -d "$deployment"
      --force-port-forward=false
      "${DEV_ARGS[@]}"
      -q
    )
    if [[ -n "$SOLO_BLOCK_NODE_RELEASE_TAG" ]]; then
      block_cmd+=(--release-tag "$SOLO_BLOCK_NODE_RELEASE_TAG")
    fi

    # Block-node wiring must be present before consensus deploy/setup/start so CN boots with
    # blockStream.* settings and block-nodes.json from the beginning.
    log "Adding block node for deployment '$deployment' before consensus deploy"
    "${block_cmd[@]}"
  fi

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

  if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
    # Solo can emit legacy block-nodes.json with `port`. Normalize to the schema consumed by
    # this consensus-node line (`streamingPort` / `servicePort`) before node startup.
    normalize_block_nodes_configmaps "$namespace"
  fi

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

  if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
    normalize_block_nodes_runtime_files "$namespace"
  fi

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
    local mirror_cmd=(
      solo mirror node add
      -d "$deployment"
      --profile tiny
      --enable-ingress
      --force-port-forward=false
      "${DEV_ARGS[@]}"
      -q
    )

    if [[ "$SOLO_ENABLE_BLOCK_NODE" == "true" ]]; then
      local mirror_values
      mirror_values="$(write_mirror_block_node_values "$namespace" "$deployment")"
      mirror_cmd+=(-f "$mirror_values")
      log "Adding mirror node for deployment '$deployment' with block-node importer profile"
    else
      log "Adding mirror node for deployment '$deployment'"
    fi

    # Mirror+relay in Solo can require ingress for stable relay->mirror routing; disable Solo auto port-forwarding
    # so parallel workstreams can manage their own local port allocations.
    "${mirror_cmd[@]}"
  fi

  if [[ "$SOLO_ENABLE_RELAY" == "true" ]]; then
    log "Adding relay node for deployment '$deployment'"
    solo relay node add -d "$deployment" -i "$SOLO_NODE_ALIASES" --profile tiny --force-port-forward=false "${DEV_ARGS[@]}" -q
  fi
}

setup_deployment "$SOLO_SRC_DEPLOYMENT" "$SOLO_SRC_NAMESPACE" "$SRC_APP_PROPERTIES"
setup_deployment "$SOLO_DST_DEPLOYMENT" "$SOLO_DST_NAMESPACE" "$DST_APP_PROPERTIES"

log "Running health checks"
"$SCRIPT_DIR/two-network-status.sh"

log "Two-network setup completed. Run manifest: $RUN_MANIFEST"
