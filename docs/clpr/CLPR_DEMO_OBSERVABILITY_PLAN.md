# CLPR Demo Observability Plan (Two-SOLO Native Messaging)

Last updated: 2026-02-17

## 1. Goal

This plan defines **where observability signals must exist** and the **expected temporal order** of those signals for the two-ledger SOLO CLPR scenario.

Demo objective:
- Show clear end-to-end call flow visibility across Solidity contracts and native Java pipeline.
- Show timing at major boundaries.
- Show external artifacts that can be queried (node logs, script artifacts, EVM events, block-stream feed, mirror REST).

Scope:
- Source and destination ledgers in SOLO.
- Native CLPR messaging path via `ClprEndpointClient`.
- Queue system contract (`0x16e`) as EVM/native bridge.

## 2. Temporary Instrumentation Rule (Required)

All new observability logs/events added for demo must be marked as temporary.

### 2.1 Solidity comment template

Use adjacent comments above each temporary event/emit:

```solidity
// TEMP-OBSERVABILITY (delete before production): emits boundary-crossing signal for demo traceability.
```

### 2.2 Java comment template

Use adjacent comments above each temporary logger call:

```java
// TEMP-OBSERVABILITY (delete before production): boundary trace for demo call-flow visibility.
```

### 2.3 Log message format

Use a stable key-value format so grep/splunk/jq can correlate quickly:

```
CLPR_OBS|component=<name>|stage=<stage>|ledger=<hex4>|messageId=<id>|appMsgId=<id>|status=<status>|tx=<txid>
```

Only include fields available in that component. Keep names stable.

## 3. Observability Surfaces by Component

## 3.1 EVM-side components (this repo)

| Component | File | Boundary crossed | Signal | Status |
|---|---|---|---|---|
| Source app | `contracts/solidity/clpr/apps/SourceApplication.sol` | App -> Middleware send attempt | `SendAttempted` event (connectorId + status) | Already present |
| Source app | `contracts/solidity/clpr/apps/SourceApplication.sol` | Middleware -> App response delivery | `ResponseReceived` event | Already present |
| Connector | `contracts/solidity/clpr/mocks/MockClprConnector.sol` | Middleware -> Connector authorize/reject path | `Authorized`, `SendRejected` events | Already present |
| Connector | `contracts/solidity/clpr/mocks/MockClprConnector.sol` | Destination reimbursement and response callback path | `Reimbursed`, `ConnectorResponseHandled`, `ApplicationResponseHandled` | Already present |
| Middleware | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Source send accepted -> queue enqueue boundary | `OutboundMessageEnqueued` | Already present |
| Middleware | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Destination inbound handling boundary | `InboundMessageHandled` | Already present |
| Middleware | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Source inbound response boundary | `InboundResponseHandled` + `RemoteStatusUpdated` | Already present |
| Echo app | `contracts/solidity/clpr/apps/EchoApplication.sol` | Destination app invocation boundary | `MessageHandled` | Already present |

Recommendation:
- Keep current events as primary EVM observability channel.
- If we add extra temporary events, only add them where a boundary is not already observable.

## 3.2 Native/system-side components (../hiero-consensus-node)

INFO-level boundary logs are now present across the listed CLPR boundary components using the standardized
`CLPR_OBS|component=...|stage=...` format.

| Component | File | Required boundary log |
|---|---|---|
| Queue system contract (enqueue request) | `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/queue/enqueuemessage/ClprQueueEnqueueMessageCall.java` | Enter execute + decoded route header + dispatched `clprEnqueueMessage` status + assigned messageId |
| Queue system contract (enqueue response) | `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/queue/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java` | Enter execute + originalMessageId + route header + dispatch status + assigned response id |
| Queue system contract (deliver inbound request) | `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/queue/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java` | Enter execute + inboundMessageId + callback target middleware + callback status + response enqueue status |
| Queue system contract (deliver inbound reply) | `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/queue/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java` | Enter execute + target middleware + callback status |
| CLPR payload transaction handler | `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/handlers/ClprMessagePayloadHandler.java` | Handle start + payload type + dispatched contract call status |
| Outbound queue txn handler | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprEnqueueMessageHandler.java` | Handle start + ledgerId + messageId assigned + hash update complete |
| Inbound bundle handler | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java` | Bundle start + first/last ids + skipCount + per payload dispatch result |
| Endpoint exchange loop | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java` | Cycle start/end + remote endpoint selected + push config status + pull config status + push bundle status + pull bundle status |
| Query handlers (visibility that queries are actually received) | `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetMessageQueueMetadataHandler.java` and `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetMessagesHandler.java` | Query received + ledgerId + response-empty/response-with-proof/bundle range |

Log destination:
- These logs should appear in node runtime logs captured as:
  - `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-src.log`
  - `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-dst.log`
- Live in-pod path:
  - `/opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log`

## 3.3 Scenario driver observability (this repo)

Current implementation:
- `scripts/clpr/native-messaging-solo/run-e2e.sh` emits UTC-stamped phase boundaries and writes run artifacts.
- `scripts/clpr/native-messaging-solo/run-scenario.js` performs all deployment + assertions and writes `deployment.json`;
  it does not yet emit a full per-message timing JSON report.

Output sink:
- `artifacts/clpr-native-messaging-solo/<runId>/scenario.log`
- `artifacts/clpr-native-messaging-solo/<runId>/run-manifest.env`
- `artifacts/clpr-native-messaging-solo/<runId>/deployment.json`

## 3.4 Complete Trace Inventory (Authoritative)

This table is the full operational inventory of currently available traces for the two-ledger native-messaging scenario.

| Trace surface | Signal / pattern | Emitted by | Live retrieval | Post-run artifact / endpoint | Correlation keys |
|---|---|---|---|---|---|
| EVM event | `SendAttempted` | `contracts/solidity/clpr/apps/SourceApplication.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `appMsgId`, `connectorId`, `status`, `failureReason`, `failureSide` |
| EVM event | `ResponseReceived` | `contracts/solidity/clpr/apps/SourceApplication.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `appMsgId`, payload hash/content |
| EVM event | `MessageHandled` | `contracts/solidity/clpr/apps/EchoApplication.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `connectorId`, payload hash/content |
| EVM event | `Authorized` | `contracts/solidity/clpr/mocks/MockClprConnector.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `destinationConnectorId`, approval, `maxCharge` |
| EVM event | `SendRejected` | `contracts/solidity/clpr/mocks/MockClprConnector.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `appMsgId`, failure reason/side |
| EVM event | `Reimbursed` | `contracts/solidity/clpr/mocks/MockClprConnector.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | reimbursed amount, connector balance hash |
| EVM event | `OutboundMessageEnqueued` | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `appMsgId`, `messageId`, source/destination connector ids |
| EVM event | `InboundMessageHandled` | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `messageId`, destination app, middleware status |
| EVM event | `InboundResponseHandled` | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | `messageId`, `appMsgId`, middleware status |
| EVM event | `RemoteStatusUpdated` | `contracts/solidity/clpr/middleware/ClprMiddleware.sol` | Mirror REST query for tx hash logs | `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>` | destination connector id, available/safety/min/max |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_queue_enqueue_message_call|...` | `.../exec/systemcontracts/clpr/queue/enqueuemessage/ClprQueueEnqueueMessageCall.java` | `kubectl -n <ns> exec <node-pod> -c root-container -- tail -f /opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log` | `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-src.log` / `hgcaa-dst.log` | `remoteLedgerId`, route version, assigned `messageId` |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_queue_enqueue_message_response_call|...` | `.../exec/systemcontracts/clpr/queue/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java` | same as above | same as above | `originalMessageId`, assigned response `messageId` |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_queue_deliver_inbound_message_call|...` | `.../exec/systemcontracts/clpr/queue/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java` | same as above | same as above | `inboundMessageId`, callback status, response enqueue status |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_queue_deliver_inbound_message_reply_call|...` | `.../exec/systemcontracts/clpr/queue/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java` | same as above | same as above | route decode, callback status |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_message_payload_handler|...` | `.../handlers/ClprMessagePayloadHandler.java` | same as above | same as above | `sourceLedgerId`, `inboundMessageId`, payload type, dispatch status |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_enqueue_message_handler|...` | `.../impl/handlers/ClprEnqueueMessageHandler.java` | same as above | same as above | queue cursor, appended `messageId`, running hash |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_process_message_bundle_handler|...` | `.../impl/handlers/ClprProcessMessageBundleHandler.java` | same as above | same as above | bundle window, skip count, payload dispatch results |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_get_message_queue_metadata_handler|...` | `.../impl/handlers/ClprGetMessageQueueMetadataHandler.java` | same as above | same as above | queue `next/sent/received` ids |
| Consensus node log (`hgcaa.log`) | `CLPR_OBS|component=clpr_get_messages_handler|...` | `.../impl/handlers/ClprGetMessagesHandler.java` | same as above | same as above | bundle boundaries (`firstMessageInBundle`, `lastMessageInBundle`) |
| Consensus node log (`hgcaa.log`) | `CLPR Endpoint: ...` | `.../impl/ClprEndpointClient.java` | same as above (use `rg \"CLPR Endpoint:\"`) | `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-*.log` | remote ledger id, selected endpoint, publish/pull status |
| Consensus platform log (`swirlds.log`) | platform lifecycle / event processing context | consensus platform runtime | `kubectl -n <ns> exec <node-pod> -c root-container -- tail -f /opt/hgcapp/services-hedera/HapiApp2.0/output/swirlds.log` | `artifacts/clpr-native-messaging-solo/<runId>/swirlds-src.log` / `swirlds-dst.log` | node state transitions, platform-level warnings/errors |
| Test-only consensus log (`test-clients`) | `CLPR_TEST_OBS|component=clpr_messages_suite|...` | `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java` | `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMessagesSuite'` | subprocess logs in `hedera-node/test-clients/build/*-test/node*/output/` | connector snapshots, send tx records |
| Block-stream tailer NDJSON | `recordType=frame` | `scripts/clpr/native-messaging-solo/block-stream-tailer.js` | `tail -f artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.ndjson | jq` (or `.../block-stream-dst.ndjson`) | `artifacts/.../block-stream-src.ndjson`, `block-stream-dst.ndjson` | `responseKind`, `blockNumber`, `itemKinds`, CLPR match reasons |
| Block-stream tailer NDJSON | `recordType=block_item` | `scripts/clpr/native-messaging-solo/block-stream-tailer.js` | same as above | same as above | `itemKind`, `itemHash`, extracted entity IDs/EVM addresses |
| Block-stream tailer NDJSON | `recordType=decode_error` | `scripts/clpr/native-messaging-solo/block-stream-tailer.js` | same as above | same as above | failing block number, grpcurl exit code/error, skip action |
| Block-node process log | subscriber/server diagnostics | k8s `block-node-1` pod logs | `kubectl -n <ns> logs statefulset/block-node-1 --tail=400 -f` | `artifacts/clpr-native-messaging-solo/<runId>/block-node-src.log` / `block-node-dst.log` | block availability / ingestion health |
| Mirror REST | Contract execution metadata | mirror REST API | `curl -sS \"$MIRROR/api/v1/contracts/results/<txHash>\" | jq` | mirror endpoint response | tx hash, consensus timestamp, gas used, status |
| Mirror REST | EVM event logs | mirror REST API | `curl -sS \"$MIRROR/api/v1/contracts/results/logs?transaction.hash=<txHash>&order=asc&limit=200\" | jq` | mirror endpoint response | tx hash, log index, topic/data payload |
| Mirror REST | Network readiness | mirror REST API | `curl -sS \"$MIRROR/api/v1/network/nodes?limit=1\" | jq` | mirror endpoint response | node count / liveness |
| Mirror importer log | Ingest lag and errors | k8s `mirror-1-importer` pod logs | `kubectl -n <ns> logs deploy/mirror-1-importer --tail=400 -f` | `artifacts/clpr-native-messaging-solo/<runId>/mirror-importer-src.log` / `mirror-importer-dst.log` | ingest progress, parser/import errors |
| Runner/orchestration log | Phase transitions, env manifest, evidence capture | `scripts/clpr/native-messaging-solo/run-e2e.sh` | run script in terminal | `artifacts/clpr-native-messaging-solo/<runId>/run-manifest.env`, `scenario.log`, `config-exchange.log` | run id, local ports, deployment names, scenario pass/fail |

## 4. Temporal Sequence of Observable Phenomena

This is the expected order for one **successful** message round trip (connector2 or connector3 path).

1. Source app tx submitted (observable via source contract result in mirror and follow-on middleware/queue logs).
2. Source EVM emits connector-attempt events:
   - `Authorized` (connector invoked)
   - `SendAttempted` (attempt result)
3. Source middleware accepts one connector and emits `OutboundMessageEnqueued`.
4. Source queue system contract logs enqueue call execution (Java).
5. `ClprEnqueueMessageHandler` logs message appended to outbound queue.
6. Source `ClprEndpointClient` logs bundle publish attempt to destination.
7. Destination `ClprProcessMessageBundleHandler` logs bundle processing start.
8. Destination queue system contract logs inbound packed delivery call.
9. Destination middleware emits `InboundMessageHandled`.
10. Destination app emits `MessageHandled`.
11. Destination connector emits `Reimbursed` (if charge > 0).
12. Destination queue system contract logs enqueue response call.
13. Destination `ClprEnqueueMessageHandler` logs reply appended to outbound queue.
14. Destination `ClprEndpointClient` logs reply bundle publish.
15. Source `ClprProcessMessageBundleHandler` logs inbound response bundle processing.
16. Source queue system contract logs inbound reply delivery call.
17. Source middleware emits `InboundResponseHandled` and `RemoteStatusUpdated`.
18. Source app emits `ResponseReceived`.
19. Scenario runner reaches completion (`Scenario passed`) after all assertions succeed.

## 4.1 Failover-specific expected sequence (messages 3, 4, and 6)

For messages where connector2 is no longer usable due known remote funds threshold:

1. Source connector1 emits `Authorized(... approve=false ...)`.
2. Source app emits `SendAttempted(... connector1 ... Rejected ...)`.
3. Source middleware pre-rejects connector2 using cached remote status.
4. Source connector2 emits `SendRejected(... ConnectorOutOfFunds, Destination ...)`.
5. Source app emits `SendAttempted(... connector2 ... Rejected/ConnectorOutOfFunds ...)`.
6. Source connector3 emits `Authorized(... approve=true ...)`.
7. Source app emits `SendAttempted(... connector3 ... Accepted ...)`.
8. Remaining successful round-trip sequence follows section 4.

## 4.2 Expected event count profile for 6-message top-off/re-deplete scenario

Expected totals (stable target):
- `SourceApplication.SendAttempted`: 15
- `SourceApplication.ResponseReceived`: 6
- `MockClprConnector.Authorized` (source side): 12 total (c1=6, c2=3, c3=3)
- `MockClprConnector.SendRejected` (source connector2): 3
- `ClprMiddleware.OutboundMessageEnqueued`: 6
- `EchoApplication.MessageHandled`: 6
- `ClprMiddleware.InboundResponseHandled`: 6
- `ClprMiddleware.FundingControlEnqueued`: 3
- `ClprMiddleware.RemoteFundingStateApplied`: 3

These counts are a quick integrity check that failover behavior is what we expect.

## 5. Timing Expectations (from recent local runs)

Use these as operational expectations for demo narration, not strict SLOs.

Per-message (steady-state) ballpark:
- Source submit -> source receipt: ~0.5s
- Source receipt -> destination request observed: ~0.6s to ~0.8s
- Destination request observed -> source response observed: ~0.9s to ~1.0s
- End-to-end source submit -> source response observed: ~2.0s to ~2.4s

Full scenario runtime:
- Hot path (`--no-build --no-redeploy`): around ~1 to ~2 minutes depending endpoint cycle cadence.
- Full clean redeploy/build run: several minutes (build + deploy dominates).

## 6. Mirror Node Observability Plan

Mirror is an **external observability channel** (not the control channel for this scenario).

## 6.1 What should be observable in mirror

For each contract transaction hash, mirror should expose:
- contract result metadata (status, gas, consensus timestamp)
- emitted EVM logs/events for that transaction

Primary endpoints:
- `GET /api/v1/contracts/results/<txHash>`
- `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>&order=asc&limit=200`

## 6.2 Expected mirror timing after test start

Assuming healthy ingest pipeline:
- First source tx result visible: typically T+3s to T+20s
- Destination tx results (inbound handling): typically T+5s to T+30s
- Source response-delivery tx results: typically T+6s to T+40s

Under load or importer lag, visibility can stretch to ~30s-90s.

## 6.3 Mirror readiness checks (before trusting timing)

For each namespace mirror deployment:
- Mirror API responds to `/api/v1/network/nodes?limit=1`.
- Importer logs show active ingestion, not stuck/no-signature loop.

If not healthy, use node logs/events as source of truth and mark mirror timing as delayed/inconclusive.

## 6.4 Mirror artifacts expected per major stage

After each source app send transaction hash is known:
1. Source-side tx hash appears in source mirror `contracts/results`.
2. Destination-side inbound processing tx hash appears in destination mirror.
3. Source-side response handling tx hash appears in source mirror.

Correlate by:
- event topics + decoded ABI event names,
- message ids (`appMsgId`, queue `messageId`) in event data where available,
- consensus timestamps.

## 6.5 Mirror event list and expected appearance window

Per message send attempt (relative to that message submit time):

| Ledger | Contract/component | Event(s) expected in mirror logs | Typical appearance window |
|---|---|---|---|
| Source | `SourceApplication` | `SendAttempted` (one per connector tried) | T+3s to T+25s |
| Source | `MockClprConnector` | `Authorized` and (for connector2 depletion path) `SendRejected` | T+3s to T+25s |
| Source | `ClprMiddleware` | `OutboundMessageEnqueued` | T+3s to T+25s |
| Destination | `ClprMiddleware` | `InboundMessageHandled` | T+5s to T+35s |
| Destination | `EchoApplication` | `MessageHandled` | T+5s to T+35s |
| Destination | `MockClprConnector` | `Reimbursed` (on successful destination processing) | T+5s to T+35s |
| Source | `ClprMiddleware` | `InboundResponseHandled`, `RemoteStatusUpdated` | T+6s to T+40s |
| Source | `SourceApplication` | `ResponseReceived` | T+6s to T+40s |

Notes:
- Window assumes healthy mirror ingest and ingress routing.
- If mirror ingest is behind, these events can shift into the T+30s to T+90s range.
- Native Java logs remain the immediate source of truth when mirror lags.

## 6.6 Mirror query commands (operator playbook)

Assume:
- `SRC_MIRROR=http://127.0.0.1:<src-mirror-port>`
- `DST_MIRROR=http://127.0.0.1:<dst-mirror-port>`
- `TX_HASH=<0x...>`

Fetch contract result metadata:

```bash
curl -sS \"$SRC_MIRROR/api/v1/contracts/results/$TX_HASH\" | jq
```

Fetch emitted logs for a transaction hash:

```bash
curl -sS \"$SRC_MIRROR/api/v1/contracts/results/logs?transaction.hash=$TX_HASH&order=asc&limit=200\" | jq
```

Quick mirror health:

```bash
curl -sS \"$SRC_MIRROR/api/v1/network/nodes?limit=1\" | jq '.nodes | length'
curl -sS \"$DST_MIRROR/api/v1/network/nodes?limit=1\" | jq '.nodes | length'
```

Mirror importer lag check (inside namespace):

```bash
kubectl -n <namespace> logs deploy/mirror-1-importer --tail=200
```

## 6.7 Block Stream Live Feed (BN Subscriber)

The two-ledger runner now starts a direct BN subscriber per ledger and writes structured metadata for CLPR-relevant
frames and block items.

Runtime behavior:
- Feed type: **server-streaming gRPC** (`subscribeBlockStream`), not polling.
- Start block: `0` on first connect.
- End block: `uint64_max` (live tail).
- Reconnect behavior: auto-reconnect with cursor resume from last observed completed block.

Run artifacts:
- Source tailer process log: `artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.log`
- Destination tailer process log: `artifacts/clpr-native-messaging-solo/<runId>/block-stream-dst.log`
- Source structured feed metadata: `artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.ndjson`
- Destination structured feed metadata: `artifacts/clpr-native-messaging-solo/<runId>/block-stream-dst.ndjson`

Structured record shape (NDJSON):
- `recordType`: `frame`, `block_item`, or `decode_error`

Frame (`recordType=frame`):
- `observedAt`: UTC timestamp when frame metadata was emitted
- `label`: `src` or `dst`
- `endpoint`: local block-node endpoint consumed by tailer
- `responseKind`: one of `block_items`, `end_of_block`, `status`, `unknown`
- `blockNumber`: best-effort associated block number
- `itemCount`: batch item count for `block_items` frames
- `itemKinds`: first-level block-item oneof keys present in the frame
- `clprRelated`: boolean relevance flag
- `matchReasons`: why it was flagged (`contains-clpr-keyword`, deployed-address/connector-id matches, queue system contract `0x16e` match)
- `clprItemCount`: count of CLPR-relevant block items in the frame
- `clprItemKinds`: distinct relevant block item kinds in the frame

Block item (`recordType=block_item`):
- `itemIndex`: index within the `block_items` frame
- `itemKind`: oneof key (`event_transaction`, `transaction_result`, `transaction_output`, etc.)
- `clprRelated`: item-level relevance flag
- `matchReasons`: CLPR relevance reasons for that item
- `itemHash`: sha256 hash of serialized item JSON
- `entities`: best-effort extracted Hedera IDs and EVM addresses from that item
- `itemSummary`: best-effort summary (status/timestamps/output-kind)

Decode error (`recordType=decode_error`):
- `attemptedStartBlock`: stream cursor used when opening grpcurl stream
- `failingBlock`: cursor at decode failure
- `grpcExitCode` and `grpcError`: grpcurl failure details
- `action`: current behavior is `skip_block` to continue tailing

Notes:
- In the current Solo stack, grpcurl may fail decoding specific block payloads (`integer overflow` / `bad wiretype`).
- The tailer treats these as non-fatal observability artifacts and continues from the next block.
- CLPR relevance can be inferred from deployed EVM addresses, connector IDs, and deployed contract IDs seen in parsed item entities.

Live monitoring examples:

```bash
run_id=<run-id>
tail -f artifacts/clpr-native-messaging-solo/$run_id/block-stream-src.ndjson | jq
tail -f artifacts/clpr-native-messaging-solo/$run_id/block-stream-dst.ndjson | jq
```

## 7. Where to Look During Demo

Primary artifact bundle per run:
- `artifacts/clpr-native-messaging-solo/<runId>/scenario.log`
- `artifacts/clpr-native-messaging-solo/<runId>/config-exchange.log`
- `artifacts/clpr-native-messaging-solo/<runId>/block-stream-src.ndjson`
- `artifacts/clpr-native-messaging-solo/<runId>/block-stream-dst.ndjson`
- `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-src.log`
- `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-dst.log`
- `artifacts/clpr-native-messaging-solo/<runId>/swirlds-src.log`
- `artifacts/clpr-native-messaging-solo/<runId>/swirlds-dst.log`
- `artifacts/clpr-native-messaging-solo/<runId>/deployment.json`

Live tail in pods:
- `kubectl -n <src-ns> exec <src-pod> -c root-container -- tail -f /opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log`
- `kubectl -n <dst-ns> exec <dst-pod> -c root-container -- tail -f /opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log`

## 8. Demo Readiness Checklist

- Every component boundary in section 3 has at least one observable signal.
- Temporary observability comments exist adjacent to every added log/event.
- Driver emits stage/timing markers for each major transition.
- Mirror visibility validated on both ledgers (or explicitly marked delayed with node-log fallback evidence).
- One dry-run executed and artifacts reviewed before executive demo.
