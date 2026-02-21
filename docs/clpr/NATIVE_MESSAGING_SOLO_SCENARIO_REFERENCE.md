# Native Messaging SOLO Scenario Reference

This is the canonical reference for the current two-ledger CLPR test scenario in this repository.

Audience:
- AI agents implementing or reviewing CLPR behavior
- developers running and debugging the scenario

## 1) Purpose

Validate end-to-end native CLPR messaging between two SOLO ledgers using the in-node messaging path only:
- no external pump
- no alternate transport
- `ClprEndpointClient` is the cross-ledger transport

The scenario specifically proves connector failover, remote-funds awareness, funding recovery, and re-depletion.

## 2) Hard Constraints

- Transport must remain native (`ClprEndpointClient` via queue/system contract path).
- Connectors are paymasters, not routers.
- Source application always tries connectors in order: connector1, then connector2, then connector3.
- Routing behavior is implied by connector pairing; no alternate ledger routing is introduced.

## 3) Scenario Actors and Initial State

Ledgers:
- source ledger
- destination ledger

Contracts:
- `ClprMiddleware` deployed to both ledgers
- `SourceApplication` on source ledger
- `EchoApplication` on destination ledger
- three connector pairs (1/2/3), each source connector paired 1:1 with its destination connector

Initial economics used by the scenario runner:
- destination connector2:
  - unit: `WETH`
  - `minimumCharge = 50`
  - `safetyThreshold = 60`
  - funded initially with `160`
- destination connector3:
  - funded initially with `500`
- source connector1 configured to deny authorization

## 4) End-to-End Sequence

Precondition bootstrap:
1. Two SOLO ledgers are up and healthy.
2. `ClprLedgerConfiguration` is exchanged once using `tools/clpr/ClprConfigExchange.java`.
3. Queue metadata is initialized and quiescent.

Execution phases:
1. Phase 1 (`msg-1`, `msg-2`)
   - connector1 denies
   - connector2 authorizes and succeeds twice
   - destination connector2 balance: `160 -> 110 -> 60`
   - source learns remote status and first funding epoch transition (`remoteFundingEpoch=1`)
2. Phase 2 (`msg-3`, `msg-4`)
   - connector1 denies
   - source middleware pre-rejects connector2 (remote underfunded boundary)
   - connector3 succeeds for both messages
3. Phase 3 (top-off action)
   - destination connector2 receives `+50` via `depositToken(50)`
   - connector2 funding state transitions underfunded -> available
   - destination middleware publishes control update to source
   - source applies update (`remoteFundingEpoch=2`)
4. Phase 4 (`msg-5`, `msg-6`)
   - `msg-5`: connector2 is usable again and succeeds once (`110 -> 60`)
   - depletion transition is propagated (`remoteFundingEpoch=3`)
   - `msg-6`: connector2 pre-rejected again, connector3 succeeds

## 5) Expected Final Checks

- `SourceApplication.ResponseReceived` count: `6`
- source connector authorize counts:
  - connector1: `6`
  - connector2: `3`
  - connector3: `3`
- source connector2 `sendRejectedCount`: `3`
- destination `EchoApplication.requestCount`: `6`
- destination connector2 final balance: `60`
- destination connector3 final balance: `350`

## 6) Canonical Commands

Full orchestrated run:

```bash
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

Minimal run profile (disable BN/MN/tailer while debugging scenario logic):

```bash
SOLO_ENABLE_BLOCK_NODE=false \
SOLO_ENABLE_MIRROR=false \
CLPR_ENABLE_BLOCK_STREAM_TAILER=false \
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build
```

Manual scenario runner call (after bootstrap/config exchange already completed):

```bash
SRC_GRPC_ENDPOINT=127.0.0.1:51211 \
DST_GRPC_ENDPOINT=127.0.0.1:52211 \
SRC_LEDGER_ID_HEX=<src-ledger-id-hex> \
DST_LEDGER_ID_HEX=<dst-ledger-id-hex> \
RUN_DIR=/tmp/clpr-manual-run \
node scripts/clpr/native-messaging-solo/run-scenario.js
```

## 7) Where to Inspect Results

Per-run artifact root:
- `artifacts/clpr-native-messaging-solo/<run-id>/`

Important files:
- `scenario.log`
- `deployment.json`
- `config-exchange.log`
- `run-manifest.env`
- `hgcaa-src.log`
- `hgcaa-dst.log`
- optional block-stream outputs:
  - `block-stream-src.ndjson`
  - `block-stream-dst.ndjson`

## 8) Primary Source Files for Behavior

- Scenario driver:
  - `scripts/clpr/native-messaging-solo/run-scenario.js`
- Orchestrator:
  - `scripts/clpr/native-messaging-solo/run-e2e.sh`
  - `scripts/clpr/native-messaging-solo/run-e2e-phases.sh`
- Solidity behavior:
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
  - `contracts/solidity/clpr/mocks/MockClprConnector.sol`
  - `contracts/solidity/clpr/connectors/base/ClprFundingAwareConnectorBase.sol`
- Regression tests:
  - `test/solidity/clpr/clprMiddleware.js`
  - `test/foundry/ClprMiddleware.t.sol`

## 9) Related Docs

- `scripts/clpr/README.md`
- `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md`
- `docs/clpr/native-messaging-solo-integration-plan/README.md`
- `docs/clpr/native-messaging-solo-integration-plan/issues/`
