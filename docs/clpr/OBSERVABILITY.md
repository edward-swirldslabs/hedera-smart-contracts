<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLPR Observability

Defines where observability signals exist and their expected temporal order for the two-ledger SOLO CLPR scenario.

## Scope

- Source and destination ledgers in SOLO.
- Native CLPR messaging path via `ClprEndpointClient`.
- Queue system contract (`0x16e`) as EVM/native bridge.

## EVM-Side Observability

| Component | File | Signal | Status |
|---|---|---|---|
| Source app | `apps/SourceApplication.sol` | `SendAttempted` (connectorId + status) | Present |
| Source app | `apps/SourceApplication.sol` | `ResponseReceived` | Present |
| Connector | `mocks/MockClprConnector.sol` | `Authorized`, `SendRejected` | Present |
| Connector | `mocks/MockClprConnector.sol` | `Reimbursed`, `ConnectorResponseHandled`, `ApplicationResponseHandled` | Present |
| Middleware | `middleware/ClprMiddleware.sol` | `OutboundMessageEnqueued` | Present |
| Middleware | `middleware/ClprMiddleware.sol` | `InboundMessageHandled` | Present |
| Middleware | `middleware/ClprMiddleware.sol` | `InboundResponseHandled`, `RemoteStatusUpdated` | Present |
| Echo app | `apps/EchoApplication.sol` | `MessageHandled` | Present |

## Consensus Node Observability

INFO-level boundary logs using `CLPR_OBS|component=...|stage=...` format.

| Component | Required Boundary Log |
|---|---|
| Queue enqueue request (`ClprQueueEnqueueMessageCall`) | Enter execute, decoded route header, dispatch status, assigned messageId |
| Queue enqueue response (`ClprQueueEnqueueMessageResponseCall`) | Enter execute, originalMessageId, route header, dispatch status, assigned response id |
| Queue deliver inbound request (`ClprQueueDeliverInboundMessageCall`) | Enter execute, inboundMessageId, callback target, callback status, response enqueue status |
| Queue deliver inbound reply (`ClprQueueDeliverInboundMessageReplyCall`) | Enter execute, target middleware, callback status |
| Payload transaction handler (`ClprMessagePayloadHandler`) | Handle start, payload type, dispatch status |
| Outbound queue handler (`ClprEnqueueMessageHandler`) | Handle start, ledgerId, messageId assigned, hash update |
| Inbound bundle handler (`ClprProcessMessageBundleHandler`) | Bundle start, first/last ids, skip count, per-payload dispatch result |
| Endpoint exchange loop (`ClprEndpointClient`) | Cycle start/end, remote endpoint, push/pull config status, push/pull bundle status |
| Query handlers (`ClprGetMessageQueueMetadataHandler`, `ClprGetMessagesHandler`) | Query received, ledgerId, response details |

Log destination: `hgcaa.log` captured as `artifacts/clpr-native-messaging-solo/<runId>/hgcaa-src.log` and `hgcaa-dst.log`.

Live in-pod path: `/opt/hgcapp/services-hedera/HapiApp2.0/output/hgcaa.log`

Log format:

```
CLPR_OBS|component=<name>|stage=<stage>|ledger=<hex4>|messageId=<id>|appMsgId=<id>|status=<status>|tx=<txid>
```

## Complete Trace Inventory

| Trace Surface | Signal / Pattern | Emitted By | Post-Run Artifact | Correlation Keys |
|---|---|---|---|---|
| EVM event | `SendAttempted` | `SourceApplication.sol` | Mirror REST logs query | `appMsgId`, `connectorId`, `status` |
| EVM event | `ResponseReceived` | `SourceApplication.sol` | Mirror REST logs query | `appMsgId` |
| EVM event | `MessageHandled` | `EchoApplication.sol` | Mirror REST logs query | `connectorId` |
| EVM event | `Authorized` | `MockClprConnector.sol` | Mirror REST logs query | `destinationConnectorId`, approval |
| EVM event | `SendRejected` | `MockClprConnector.sol` | Mirror REST logs query | `appMsgId`, failure reason |
| EVM event | `Reimbursed` | `MockClprConnector.sol` | Mirror REST logs query | reimbursed amount |
| EVM event | `OutboundMessageEnqueued` | `ClprMiddleware.sol` | Mirror REST logs query | `appMsgId`, `messageId` |
| EVM event | `InboundMessageHandled` | `ClprMiddleware.sol` | Mirror REST logs query | `messageId` |
| EVM event | `InboundResponseHandled` | `ClprMiddleware.sol` | Mirror REST logs query | `messageId`, `appMsgId` |
| EVM event | `RemoteStatusUpdated` | `ClprMiddleware.sol` | Mirror REST logs query | destination connector id |
| Node log | `CLPR_OBS\|component=clpr_queue_enqueue_message_call` | `ClprQueueEnqueueMessageCall.java` | `hgcaa-*.log` | `remoteLedgerId`, `messageId` |
| Node log | `CLPR_OBS\|component=clpr_queue_enqueue_message_response_call` | `ClprQueueEnqueueMessageResponseCall.java` | `hgcaa-*.log` | `originalMessageId`, response `messageId` |
| Node log | `CLPR_OBS\|component=clpr_queue_deliver_inbound_message_call` | `ClprQueueDeliverInboundMessageCall.java` | `hgcaa-*.log` | `inboundMessageId`, callback status |
| Node log | `CLPR_OBS\|component=clpr_queue_deliver_inbound_message_reply_call` | `ClprQueueDeliverInboundMessageReplyCall.java` | `hgcaa-*.log` | route decode, callback status |
| Node log | `CLPR_OBS\|component=clpr_message_payload_handler` | `ClprMessagePayloadHandler.java` | `hgcaa-*.log` | `sourceLedgerId`, payload type |
| Node log | `CLPR_OBS\|component=clpr_enqueue_message_handler` | `ClprEnqueueMessageHandler.java` | `hgcaa-*.log` | queue cursor, `messageId` |
| Node log | `CLPR_OBS\|component=clpr_process_message_bundle_handler` | `ClprProcessMessageBundleHandler.java` | `hgcaa-*.log` | bundle window, skip count |
| Node log | `CLPR Endpoint: ...` | `ClprEndpointClient.java` | `hgcaa-*.log` | remote ledger, endpoint, status |
| Platform log | lifecycle / event processing | consensus platform | `swirlds-*.log` | state transitions |
| Block-stream NDJSON | `recordType=frame` | `block-stream-tailer.js` | `block-stream-*.ndjson` | `blockNumber`, CLPR match reasons |
| Block-stream NDJSON | `recordType=block_item` | `block-stream-tailer.js` | `block-stream-*.ndjson` | `itemKind`, `itemHash`, entities |
| Block-stream NDJSON | `recordType=decode_error` | `block-stream-tailer.js` | `block-stream-*.ndjson` | failing block, grpcurl error |
| Runner log | phase transitions | `run-e2e.sh` | `run-manifest.env`, `scenario.log` | run id, pass/fail |

## Temporal Sequence

Expected order for one **successful** message round trip:

1. Source app tx submitted
2. Source EVM emits connector-attempt events (`Authorized`, `SendAttempted`)
3. Source middleware emits `OutboundMessageEnqueued`
4. Source queue system contract logs enqueue call (Java)
5. `ClprEnqueueMessageHandler` logs message appended
6. Source `ClprEndpointClient` logs bundle publish to destination
7. Destination `ClprProcessMessageBundleHandler` logs bundle processing start
8. Destination queue system contract logs inbound delivery call
9. Destination middleware emits `InboundMessageHandled`
10. Destination app emits `MessageHandled`
11. Destination connector emits `Reimbursed`
12. Destination queue system contract logs enqueue response
13. Destination `ClprEnqueueMessageHandler` logs reply appended
14. Destination `ClprEndpointClient` logs reply bundle publish
15. Source `ClprProcessMessageBundleHandler` logs inbound response processing
16. Source queue system contract logs inbound reply delivery
17. Source middleware emits `InboundResponseHandled` and `RemoteStatusUpdated`
18. Source app emits `ResponseReceived`
19. Scenario runner prints `Scenario passed`

### Failover Sequence (Messages 3-4)

When connector 2 is known out-of-funds:

1. Connector 1: `Authorized(approve=false)` → `SendAttempted(Rejected)`
2. Connector 2: pre-rejected by middleware cached status → `SendRejected(ConnectorOutOfFunds, Destination)` → `SendAttempted(Rejected/ConnectorOutOfFunds)`
3. Connector 3: `Authorized(approve=true)` → `SendAttempted(Accepted)`
4. Normal round-trip follows

### Expected Event Counts (4-Message Scenario)

| Event | Expected Count |
|---|---|
| `SourceApplication.SendAttempted` | 10 |
| `SourceApplication.ResponseReceived` | 4 |
| `MockClprConnector.Authorized` (source) | 8 (c1=4, c2=2, c3=2) |
| `MockClprConnector.SendRejected` (source c2) | 2 |
| `ClprMiddleware.OutboundMessageEnqueued` | 4 |
| `EchoApplication.MessageHandled` | 4 |
| `ClprMiddleware.InboundResponseHandled` | 4 |

## Timing Expectations

Per-message steady-state ballpark:
- Source submit → source receipt: ~0.5s
- Source receipt → destination request observed: ~0.6-0.8s
- Destination request → source response observed: ~0.9-1.0s
- End-to-end source submit → source response: ~2.0-2.4s

Full scenario runtime:
- Hot path (`--no-build --no-redeploy`): ~1-2 minutes
- Full clean redeploy + build: several minutes (build + deploy dominates)

## Mirror Observability

Mirror is an external observability channel, not the control channel.

Primary endpoints:
- `GET /api/v1/contracts/results/<txHash>` — contract result metadata
- `GET /api/v1/contracts/results/logs?transaction.hash=<txHash>&order=asc&limit=200` — emitted EVM logs

Mirror timing: events appear T+3s to T+40s after source tx submission under healthy ingest. Under importer lag, visibility can stretch to T+30s-90s. When mirror lags, use node logs as source of truth.

Mirror health check:

```bash
curl -sS "$MIRROR/api/v1/network/nodes?limit=1" | jq '.nodes | length'
```

## Temporary Instrumentation

All observability logs/events added for demo are marked with adjacent comments:

- Solidity: `// TEMP-OBSERVABILITY (delete before production)`
- Java: `// TEMP-OBSERVABILITY (delete before production)`

Search for these markers when preparing for production cleanup.
