# Native Queue Integration Baseline Matrix

Status: Completed research snapshot (2026-02-12)

## Snapshot Context

Smart contracts repo:

- Path: `.`
- Branch: `20111-clpr-middleware-with-connector`
- Commit: `2556204e4b774ad840ceb7b272f6c18c1f98c22c`

Consensus node repo:

- Path: `../hiero-consensus-node`
- Branch: `clpr-message-queue-integration-branch`
- Commit: `f84a46c99e827711c002f0de586a429535baae5b`

## Capability Matrix (Source-Linked)

| Capability | State | Evidence |
|---|---|---|
| CLPR ledger config query/set handlers | Implemented | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetLedgerConfigurationHandler.java:31`, `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprSetLedgerConfigurationHandler.java:34` |
| CLPR queue metadata query/update handlers | Implemented | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetMessageQueueMetadataHandler.java:25`, `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java:45` |
| CLPR bundle query/process handlers | Implemented | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetMessagesHandler.java:27`, `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java:42` |
| Cross-ledger queue/config sync loop | Implemented (dev-mode prototype) | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java:372` |
| CLPR transaction dispatch wiring | Implemented | `../hiero-consensus-node/hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/dispatcher/TransactionDispatcher.java:225` |
| CLPR API permissions wiring | Implemented | `../hiero-consensus-node/hedera-node/hedera-config/src/main/java/com/hedera/node/config/data/ApiPermissionConfig.java:355` |
| Solidity queue API used by middleware | Implemented and stable | `contracts/solidity/clpr/interfaces/IClprQueue.sol:8`, `contracts/solidity/clpr/interfaces/IClprQueue.sol:13`, `contracts/solidity/clpr/interfaces/IClprQueue.sol:18` |
| EVM CLPR queue system-contract package | Missing | No `clpr` package exists under `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/` |
| Native enqueue operation callable from EVM adapter | Missing/partial | Queue init path still seeds synthetic messages in update handler via `TODO: REMOVE THIS TESTING CODE`: `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java:153` |
| Middleware callback execution from processed bundles | Missing | Process bundle handler currently emits placeholder reply behavior and TODOs rather than calling middleware entrypoints: `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java:163`, `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java:177` |

## Prototype Shortcuts / Incomplete Paths

- Queue initialization currently inserts 10 synthetic outbound messages.
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java:153`
- Bundle processing has explicit TODOs for message handling/reply data semantics.
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java:163`
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java:177`
- `preHandle` requirements are not finalized in some CLPR handlers.
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java:83`
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java:101`

## Why This Integration Is Non-Trivial

- Native CLPR transport exists, but middleware callback execution from inbound bundles is not implemented.
- Solidity middleware relies on queue-facing APIs, but there is no CLPR queue system contract at EVM boundary yet.
- Exactly-once goals depend on preserving queue metadata and running-hash integrity while adding callback execution.

## Minimal New Components Required

- CLPR queue system-contract adapter package in consensus node smart-contract service.
- Native enqueue path callable from that adapter (request and response envelopes).
- Bundle-processing callback executor to invoke `handleMessage` / `handleMessageResponse` on middleware contracts.

## Blocked-By List for Issues 0002-0006

- ISSUE-0002 blocked by:
  - no command artifacts yet for deterministic dual-network local-build deployment.
- ISSUE-0003 blocked by:
  - no checked-in deterministic bootstrap checklist/evidence pack yet.
- ISSUE-0004 blocked by:
  - open decision: opaque bytes payload bridging vs field-by-field translation strategy.
- ISSUE-0005 blocked by:
  - no approved enqueue adapter contract (address/selector/error mapping) and no native enqueue API decision.
- ISSUE-0006 blocked by:
  - no approved system-contract address/selector design and no CLPR queue adapter package scaffold.

## Immediate Constraints (Carried Forward)

- Keep Solidity queue API unchanged.
- Use HAPI/gRPC as authoritative source invocation path.
- Keep CLPR config sharing bootstrap in orchestration path before middleware E2E scenarios.

