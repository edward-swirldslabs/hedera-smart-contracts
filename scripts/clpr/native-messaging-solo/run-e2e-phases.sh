#!/usr/bin/env bash
# SPDX-License-Identifier: Apache-2.0

set -euo pipefail

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "This file is meant to be sourced, not executed directly."
  exit 1
fi

phase_build_consensus_artifacts() {
  if [[ "$DO_BUILD" == "true" ]]; then
    log "Building consensus node artifacts into: $CN_LOCAL_BUILD_PATH"
    # In hiero-consensus-node, the Hedera app project is exposed as `:app`.
    # `:app:assemble` also runs the `copyLib` / `copyApp` / `copyNodeDataAndConfig` tasks that populate
    # `hedera-node/data/*`, which SOLO consumes via `--local-build-path`.
    (cd "$CN_REPO_DIR" && ./gradlew :app:assemble)
  else
    log "Skipping consensus node build (--no-build)"
  fi
}

phase_prepare_cluster_and_networks() {
  ensure_cluster_ref

  if [[ "$DO_REDEPLOY" == "true" ]]; then
    log "Deploying two SOLO networks (force recreate for repeatability)"
    "$SCRIPT_DIR/two-network-up.sh" --force
  else
    log "Skipping SOLO redeploy (--no-redeploy)"
    "$SCRIPT_DIR/two-network-status.sh"
  fi
}

phase_compile_hardhat_artifacts() {
  log "Compiling Solidity (Hardhat) to ensure artifacts are current"
  (cd "$PROJECT_ROOT" && npx hardhat compile)
}

phase_compile_config_exchange_tool() {
  log "Compiling CLPR config-exchange tool"
  JAVA_OUT_DIR="$RUN_DIR/java-classes"
  mkdir -p "$JAVA_OUT_DIR"
  CLASSPATH_CN="$CN_LOCAL_BUILD_PATH/lib/*:$CN_LOCAL_BUILD_PATH/apps/*"
  javac -cp "$CLASSPATH_CN" -d "$JAVA_OUT_DIR" "$PROJECT_ROOT/tools/clpr/ClprConfigExchange.java"

  export JAVA_OUT_DIR
  export CLASSPATH_CN
}

read_queue_meta() {
  local label="$1"
  local line
  line="$(rg -m1 "^${label}: next=[0-9]+ sent=[0-9]+ recv=[0-9]+$" "$RUN_DIR/config-exchange.log" || true)"
  [[ -n "$line" ]] || return 1
  if [[ "$line" =~ next=([0-9]+)[[:space:]]+sent=([0-9]+)[[:space:]]+recv=([0-9]+) ]]; then
    echo "${BASH_REMATCH[1]} ${BASH_REMATCH[2]} ${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

assert_queue_quiescent() {
  local label="$1"
  local next_id="$2"
  local sent_id="$3"
  local recv_id="$4"
  if (( sent_id != recv_id )); then
    die "${label} is not quiescent (sent=${sent_id}, recv=${recv_id}). Stale/in-flight queue state detected. Re-run without --no-redeploy (or recreate both ledgers) before running the scenario."
  fi
  if (( next_id != sent_id + 1 )); then
    die "${label} is not quiescent (next=${next_id}, sent=${sent_id}, recv=${recv_id}). Stale queue head detected. Re-run without --no-redeploy (or recreate both ledgers) before running the scenario."
  fi
}

phase_run_config_exchange_and_validate() {
  log "Running CLPR config exchange kick (and waiting for queue metadata init)"
  CONFIG_ENV="$RUN_DIR/config-exchange.env"
  # Run from the consensus-node repo root so dev signer key lookups that depend on relative paths work.
  (cd "$CN_REPO_DIR" && java -cp "$JAVA_OUT_DIR:$CLASSPATH_CN" tools.clpr.ClprConfigExchange \
    --a "$SRC_GRPC_ENDPOINT" \
    --b "$DST_GRPC_ENDPOINT" \
    --out "$CONFIG_ENV") \
    >"$RUN_DIR/config-exchange.log" 2>&1

  if read -r a_next a_sent a_recv < <(read_queue_meta "A queue for B"); then
    assert_queue_quiescent "A queue for B" "$a_next" "$a_sent" "$a_recv"
  else
    warn "Unable to parse queue metadata for 'A queue for B' from config-exchange log"
  fi

  if read -r b_next b_sent b_recv < <(read_queue_meta "B queue for A"); then
    assert_queue_quiescent "B queue for A" "$b_next" "$b_sent" "$b_recv"
  else
    warn "Unable to parse queue metadata for 'B queue for A' from config-exchange log"
  fi

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
}

phase_run_scenario_runner() {
  log "Running scenario runner"
  (cd "$PROJECT_ROOT" && node scripts/clpr/native-messaging-solo/run-scenario.js >"$RUN_DIR/scenario.log" 2>&1)
}
