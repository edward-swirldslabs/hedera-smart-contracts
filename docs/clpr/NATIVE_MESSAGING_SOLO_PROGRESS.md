# Native Messaging SOLO Integration (ClprEndpointClient) - Progress Report

Last updated: 2026-02-14

## TL;DR (Current Status)

- Two SOLO networks (source + destination) can be stood up repeatably with a custom locally-built consensus-node applied to both deployments.
- The one-time CLPR config exchange kick works (no pump):
  - fetch each ledger's `ClprLedgerConfiguration` state proof, install it on the other ledger,
  - wait for queue metadata initialization on both ledgers.
- End-to-end application flow now works in SOLO:
  - source app sends requests across ledgers,
  - destination echo app responds,
  - responses arrive back at the source app,
  - connector failover + destination funds depletion behavior matches the intended scenario.
- Cross-ledger transport is performed by the in-node native messaging layer (`ClprEndpointClient`) exchanging `ClprMessageBundle` over CLPR gRPC.
  No external bundle pump/relay exists in this integration.

Latest passing evidence bundle:

- `artifacts/clpr-native-messaging-solo/20260214T005029Z/`
  - `config-exchange.log`
  - `scenario.log` (contains `Scenario passed`)
  - `deployment.json`
  - `hgcaa-*.log` / `swirlds-*.log` snapshots

Earlier passing run (example):

- `artifacts/clpr-native-messaging-solo/20260214T000828Z/`

## How To Run

End-to-end runner (build + deploy two networks + kick + scenario + teardown):

```bash
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

Helpful options:

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build` (skip rebuilding consensus-node artifacts)
- `bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep` (keep the two SOLO deployments running after the run)

## What Was Fixed (Key SOLO Gotchas)

### 1) CLPR Ops Throttled Under SOLO Defaults

SOLO uses `genesis/throttles.json` by default; it does not include the prototype CLPR operations. Result: CLPR queries and
transactions return `BUSY` indefinitely.

Fix: use dev throttles in both ledgers' application properties:

- `bootstrap.throttleDefsJson.resource=genesis/throttles-dev.json`

Files:

- `scripts/clpr/native-messaging-solo/config/application-src.properties`
- `scripts/clpr/native-messaging-solo/config/application-dst.properties`

### 2) In-Cluster DNS (Gossip FQDN) Restrictions

SOLO advertises in-cluster DNS names for endpoints; to keep advertised CLPR endpoints usable, allow FQDNs for gossip:

- `nodes.gossipFqdnRestricted=false`

### 3) Native Queue System Contract Enabled

Enable the CLPR queue system contract (`0x16e`) in SOLO deployments:

- `contracts.systemContract.clprQueue.enabled=true`

### 4) Callback Authorization For Native Bundle Processing

Inbound CLPR bundle processing dispatches synthetic contract calls to middleware callbacks; the EVM `msg.sender` is the
CLPR transaction payer, not the queue contract.

Fix: allow an explicit trusted callback caller in middleware (`trustedCallbackCaller`) and configure it in the SOLO runner
to the operator's EVM address.

### 5) Message Envelope Compatibility

The queue system contract adapts `enqueueMessage(...)` into a native queue write by wrapping:

- route header bytes from `ClprMessage.middlewareMessage.data`
- the original calldata

into the on-wire request envelope that the native bundle handler expects.

### 6) SOLO gRPC TIMEOUT Flakes During Deploy/Execute

SOLO gRPC port-forwarding can be bursty, which can manifest as `GrpcServiceError: Status: TIMEOUT` during
`ContractCreateFlow` / receipt queries.

Mitigation: the scenario runner increases Hedera JS SDK retry/timeout defaults:

- `HEDERA_MAX_ATTEMPTS` (default: `30`)
- `HEDERA_REQUEST_TIMEOUT_MS` (default: `60000`)

## Quarantine Notes

The previous pump-based attempt is quarantined here and should not be revived:

- `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/README.md`

It still contains useful operational notes (e.g., how to apply a local consensus-node build to SOLO) that informed the
current scripted workflow.
