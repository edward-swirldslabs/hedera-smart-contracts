# Native Messaging SOLO Integration (ClprEndpointClient) - Progress Report

Last updated: 2026-02-16

## TL;DR (Current Status)

- Active refactor issue set `ISSUE-0201..0209` is complete.
- End-to-end two-ledger SOLO scenario is stable and repeatable with the native CLPR messaging path:
  - outbound enqueue from EVM is transaction-correlated via `clprEnqueueMessage`,
  - cross-ledger transport is in-node `ClprEndpointClient` over CLPR gRPC,
  - inbound delivery is delegated through `0x16e` node-internal packed entry points,
  - on-wire payload bytes are canonical `abi.encode(ClprMessage)` / `abi.encode(ClprMessageResponse)` (no wrapper envelope).
- No external pump/relay/forwarder is used.

Latest 3 consecutive passing evidence runs:

- `artifacts/clpr-native-messaging-solo/20260216T155251Z/`
- `artifacts/clpr-native-messaging-solo/20260216T155821Z/`
- `artifacts/clpr-native-messaging-solo/20260216T160351Z/`

Each contains `scenario.log` with `Scenario passed`.

Latest clean-rerun validation (artifacts wiped first):

- `artifacts/clpr-native-messaging-solo/20260216T210811Z/`
- `scenario.log`: `Scenario passed`
- Block stream tailer decode checks:
  - source `block-stream-src.ndjson`: `decode_error=0`
  - destination `block-stream-dst.ndjson`: `decode_error=0`

## Validation Snapshot

Consensus node validations:

- `./gradlew :hiero-clpr-interledger-service-impl:test :app-service-contract-impl:test :app:assemble --no-daemon`
  - Result: pass
  - Notable counts: `138 passing` (`hiero-clpr-interledger-service-impl`), `1757 passing` (`app-service-contract-impl`)

Smart-contracts validation:

- `npx hardhat compile`
  - Result: pass (`Nothing to compile`)

SOLO stability gate:

- Three consecutive passes of:
  - `CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep`

## How To Run

Primary E2E command (recommended for integration lane):

```bash
CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true \
  bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep
```

Notes:

- Use `CLPR_SOLO_HOME` (or `SOLO_HOME`) isolation to avoid collisions with other SOLO workflows (e.g. GUI lane).
- `SOLO_SKIP_CLUSTER_SETUP=true` avoids concurrent cluster-scoped mutations when cluster reference is already configured.

Helpful options:

- `--no-build` to skip consensus-node artifact rebuild.
- Omit `--keep` if you want teardown at the end of each run.
- For deterministic artifact cleanup + rerun + validation checks, use:
  - `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md`

## Key Operational Fixes / Requirements

1. CLPR throttles:
- Use dev throttles in both ledgers:
- `bootstrap.throttleDefsJson.resource=genesis/throttles-dev.json`

2. Endpoint publishing + DNS:
- Endpoint advertisement enabled and in-cluster FQDNs allowed:
- `clpr.publicizeNetworkAddresses=true`
- `nodes.gossipFqdnRestricted=false`

3. Queue system contract enabled:
- `contracts.systemContract.clprQueue.enabled=true`

4. One-time config exchange kick:
- Exchange `ClprLedgerConfiguration` state proofs between ledgers before expecting autonomous message flow.

## Quarantine Notes

Pump-based historical attempt is quarantined and should not be revived:

- `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/README.md`
- `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
