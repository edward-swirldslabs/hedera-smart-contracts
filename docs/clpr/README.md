# CLPR Docs

This folder contains CLPR middleware design notes, reports, operational troubleshooting, and SOLO-first native messaging integration planning.

## Documents

- `CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`
  - Proposed corrected architecture for CLPR native messaging integration in `../hiero-consensus-node`.
- `CLPR_MIDDLEWARE_OVERVIEW.md`
  - High-level overview of the current CLPR middleware implementation, contract layout, and test strategy.
- `CLPR_DEMO_REPORT_2026-02-11.md`
  - Comprehensive demo report covering middleware behavior, single-ledger and two-ledger test flows, and framework comparison.
- `SOLO_TWO_NETWORK_CLPR_BRIDGE_NOTES.md`
  - Detailed troubleshooting log for running two Solo networks with a bridged CLPR scenario.
- `ODIN_HARP_VS_JSONRPC_RELAY.md`
  - Comparison of ODIN/HARP (HAPI-first) versus JSON-RPC-relay-centric test paths.
- `native-messaging-solo-integration-plan/README.md`
  - Active plan for SOLO-first integration using the in-node native messaging layer and `ClprEndpointClient` (no external pump).
- `native-messaging-solo-integration-plan/issues/`
  - Active issue set for reaching the corrected SOLO integration target state.
- `NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
  - Pointer to the quarantined pump-based native-queue plan and associated scripts (anti-pattern archive).
- `NATIVE_MESSAGING_SOLO_AFTER_ACTION_REPORT.md`
  - After action report explaining what was built, why it differs from the pump-based attempt, and how to run the scenario.

## Source Code Map

- Contracts: `contracts/solidity/clpr/`
- Hardhat tests: `test/solidity/clpr/` and `test/network/clpr/`
- Foundry tests: `test/foundry/`
- Helper scripts: `scripts/`

## Regression Commands

Hedera-smart-contracts:

```bash
# Hardhat (single in-process chain)
npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat

# Hardhat (two-network bridged queue, JSON-RPC relay based)
npx hardhat test test/network/clpr/clprBridgeRelayedQueue.js --network hardhat

# Foundry
forge test --match-path test/foundry/ClprMiddleware.t.sol

# Solo (native queue, two ledgers, HAPI/gRPC only)
# Full build + deploy + kick + scenario + teardown:
bash scripts/clpr/native-messaging-solo/run-e2e.sh

# Useful options:
# bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build
# bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep
#
# The prior pump-based smoke runner was quarantined as an anti-pattern.
# See:
# - docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md
# - docs/clpr/native-messaging-solo-integration-plan/README.md
```

Consensus node sibling repo (`../hiero-consensus-node`) (examples; quote `--tests` patterns to avoid shell expansion):

```bash
cd ../hiero-consensus-node

# Unit-level handler/regression battery (targeted example)
./gradlew :hiero-clpr-interledger-service-impl:test --tests '*ClprProcessMessageBundleHandlerTest*' --no-daemon

# HapiTest (subprocess, targeted suite examples)
./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMessagesSuite' --rerun-tasks --no-daemon
```

## Middleware Callback Authorization Model

Middleware callback entrypoints must only accept calls from the queue system contract (native queue) and may optionally
allow an explicit trusted caller for local test harnesses:

- Queue address: system contract at `0x16E` (native queue adapter)
- Optional additional caller: `ClprMiddleware.trustedCallbackCaller`

## Known Limitations / Known Environment Noise

- Solo local-build dev mode can show control-plane/runtime drift; control-plane phase may read `configured` even when
  pods/JVM/gRPC are healthy.
- gRPC port-forwarding can transiently drop under load; polling helpers should treat transport hiccups as retryable.
- Gradle subprocess startup may intermittently fail with `NoSuchFileException: build/<network>-test/node0/output/hgcaa.log`;
  mitigation: re-run with `--rerun-tasks` and/or delete `hedera-node/build/*-test` directories before rerunning.

## Recommended Reading Order

1. `CLPR_MIDDLEWARE_OVERVIEW.md`
2. `native-messaging-solo-integration-plan/README.md`
3. `NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
4. `SOLO_TWO_NETWORK_CLPR_BRIDGE_NOTES.md`
5. `ODIN_HARP_VS_JSONRPC_RELAY.md`
