<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLPR (Cross-Ledger Protocol Relay)

CLPR enables cross-ledger request/response messaging between independent Hedera/Hiero ledgers. The Solidity middleware handles application routing, connector authorization, and failover policy. A queue system contract at `0x16e` bridges EVM calls into the native CLPR queue, and the in-node `ClprEndpointClient` transports message bundles between ledgers over gRPC with no external pump or relay process.

**Current implementation status**: IT1-CONN-AUTH iteration with funding-aware connector recovery — connector registration, authorization, failover, funds exhaustion, top-off recovery, and re-depletion behavior validated end-to-end across two Solo ledgers using native messaging (6-message scenario).

## Documentation

| Document | Description |
|---|---|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System architecture: Solidity components, consensus node components, message flow, wire encoding, hard guardrails |
| [TESTING.md](TESTING.md) | All test instructions: Hardhat, Foundry, and two-Solo E2E native messaging test with step-by-step setup |
| [OPERATIONS.md](OPERATIONS.md) | Operational playbook: clean rerun procedures, known failure signatures, block-stream tailer, block node config, JSON-RPC relay notes |
| [OBSERVABILITY.md](OBSERVABILITY.md) | Trace inventory: EVM events, consensus node logs, block-stream feed, temporal sequence, timing expectations |
| [NATIVE_MESSAGING_SOLO_SCENARIO_REFERENCE.md](NATIVE_MESSAGING_SOLO_SCENARIO_REFERENCE.md) | Canonical test scenario: 6-message sequence, expected counters/balances, operator commands |
| [CLPR_REQUIREMENTS_DEEP_COMPARISON_2026-02-18.md](CLPR_REQUIREMENTS_DEEP_COMPARISON_2026-02-18.md) | Requirements gap analysis against PR #23333 specification |
| [native-messaging-solo-integration-plan/](native-messaging-solo-integration-plan/README.md) | Active integration plan and issue tracker |

## Source Code Map

| Location | Content |
|---|---|
| `contracts/solidity/clpr/` | Solidity middleware, apps, connectors, mocks, types, interfaces ([contract README](../../contracts/solidity/clpr/README.md)) |
| `test/solidity/clpr/` | Hardhat integration tests |
| `test/foundry/ClprMiddleware.t.sol` | Foundry unit tests |
| `test/network/clpr/` | Two-network bridged test (JSON-RPC relay path) |
| `scripts/clpr/` | E2E runner, bring-up/teardown, config exchange, block-stream tailer ([script README](../../scripts/clpr/README.md)) |
| `tools/clpr/` | Config exchange Java tool |
| `../hiero-consensus-node/` | Queue system contract, native messaging, bundle processing (branch `23652-clpr-middleware-integration`) |

## Quick Start: Run Tests

### Single-ledger (fast)

```bash
# Hardhat
npx hardhat test test/solidity/clpr/clprMiddleware.js --network hardhat

# Foundry
forge test --match-path test/foundry/ClprMiddleware.t.sol
```

### Two-Solo E2E (native messaging)

```bash
# Full run (build + deploy + scenario + teardown)
bash scripts/clpr/native-messaging-solo/run-e2e.sh

# Fast rerun (skip consensus node rebuild)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build
```

See [TESTING.md](TESTING.md) for prerequisites, environment variables, and troubleshooting.

## Key Operational Notes

- The gRPC/native messaging path is the reliable baseline for multi-ledger testing. JSON-RPC relay depends on Mirror Node ingestion, which can stall independently of consensus node health.
- Solo cluster context defaults to `docker-desktop`. If using a Kind cluster, set `SOLO_CLUSTER_CONTEXT=kind-<name>`.
- Block-stream tailers require `SOLO_ENABLE_BLOCK_NODE=true`. If block node is not needed, disable both: `SOLO_ENABLE_BLOCK_NODE=false CLPR_ENABLE_BLOCK_STREAM_TAILER=false`.
- See [OPERATIONS.md](OPERATIONS.md) for known failure signatures and fixes.

## Consensus Node Regression Commands

```bash
cd ../hiero-consensus-node

# Unit tests (targeted)
./gradlew :hiero-clpr-interledger-service-impl:test --tests '*ClprProcessMessageBundleHandlerTest*' --no-daemon

# HapiTest suite
./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMessagesSuite' --rerun-tasks --no-daemon
```
