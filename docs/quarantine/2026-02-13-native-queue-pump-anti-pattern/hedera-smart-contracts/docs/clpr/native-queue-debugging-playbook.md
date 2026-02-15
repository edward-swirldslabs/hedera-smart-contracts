# Native Queue Integration Debugging Playbook

Status: Draft  
Last updated: 2026-02-12

## Purpose

This playbook defines how to debug CLPR middleware integration when transport is native CLPR queue (no JSON-RPC relay). It covers:

- where to find evidence,
- how to isolate failures by stage,
- how to add temporary diagnostics safely,
- how to clean diagnostics before merge.

This document is the required reference during execution of:

- `docs/clpr/native-queue-integration-plan/issues/ISSUE-0001-...` through `ISSUE-0014-...`

## First Principles

- Treat the end-to-end path as a pipeline of stages.
- Capture evidence at each stage before changing code.
- Avoid multi-variable experiments; change one thing at a time.
- Prefer HAPI transaction paths as authoritative during this integration.

## Stage Map and Evidence

### Stage A: Custom Node Build Artifacts

Question: Did the expected consensus node code actually get built and deployed?

Evidence:

- Build output exists in `../hiero-consensus-node/hedera-node/data/`.
- Deployed node reports expected version/commit in pod logs.

Useful checks:

```bash
cd ../hiero-consensus-node
./gradlew :hedera-node:assemble
ls -la hedera-node/data
```

```bash
kubectl -n <ns> logs statefulset/network-node1 --tail=200 | rg "VERSION=|COMMIT="
```

### Stage B: Two-Network Solo Health

Question: Are both ledgers healthy enough to test CLPR?

Evidence:

- Consensus, mirror (if used), and CLPR-relevant pods Running.
- gRPC endpoints reachable.

Useful checks:

```bash
kubectl get pods -n <ns-a>
kubectl get pods -n <ns-b>
```

```bash
kubectl get svc -n <ns-a>
kubectl get svc -n <ns-b>
```

### Stage C: CLPR Config Exchange Bootstrapping

Question: Did ledger config publication and exchange succeed?

Evidence:

- `getConfiguration` and `setConfiguration` HAPI calls succeed.
- Queue metadata for remote ledger exists on both ledgers.
- `ClprMessagesSuite`/`ClprShipOfTheseusSuite` expectations hold.

Useful checks (HapiTest class-level):

- `com.hedera.services.bdd.suites.interledger.ClprMessagesSuite`
- `com.hedera.services.bdd.suites.interledger.ClprShipOfTheseusSuite`

### Stage D: EVM -> Queue System Contract

Question: Does middleware enqueue call reach native queue adapter?

Evidence:

- Transaction record indicates success.
- System-contract translator logs show selector dispatch.
- Returned `messageId` is non-zero and monotonic.

Useful checks:

- HAPI transaction record + status.
- Queue metadata/query after call.
- System-contract adapter logs in consensus node pod.

### Stage E: Native Queue Transport (Bundle Push/Pull)

Question: Are enqueued messages moving cross-ledger?

Evidence:

- `sent_message_id` and `received_message_id` advance.
- `getMessages` on source decreases pending outbound backlog.
- `processMessageBundle` tx status is success on destination.

Useful checks:

- `ClprGetMessageQueueMetadata`
- `ClprGetMessages`
- node logs containing `CLPR Endpoint` prefix

### Stage F: Destination Middleware Callback Execution

Question: Is inbound message reaching destination middleware/app logic?

Evidence:

- Destination middleware events/state updated.
- Destination app handles message (or explicit failure response path executes).
- Expected connector/balance status updates are visible.

Useful checks:

- Contract state queries (HAPI local call or relay-free query utilities).
- Event/state assertions in HapiTests.

### Stage G: Response Path Back to Source

Question: Does source receive response and correlate it?

Evidence:

- Response enqueue occurs.
- Source middleware `handleMessageResponse` path executes.
- Source app receives expected response payload and app message id mapping.

Useful checks:

- source contract state fields (latest response, status, counters)
- queue metadata on both ledgers after response cycle

## Failure Taxonomy

### F1: Build/Artifact mismatch

Symptoms:

- deployed node lacks expected code behavior.
- logs show unexpected commit/version.

Likely causes:

- stale `hedera-node/data` artifacts.
- Solo node setup not using `--local-build-path` expected output.

### F2: Config exchange stalls

Symptoms:

- queue metadata never appears for remote ledger.
- CLPR endpoint logs repeatedly show missing remote config/queue.

Likely causes:

- publicized endpoint config not enabled on at least one ledger.
- missing initial config submission from one ledger to the other.

### F3: Enqueue call succeeds but queue state unchanged

Symptoms:

- no increment in `next_message_id`.
- no message entry for returned id.

Likely causes:

- adapter decodes but dispatch never mutates state.
- enqueue transaction handler precheck/handle mismatch.

### F4: Bundle processing succeeds but no middleware callback

Symptoms:

- queue ids advance but app/middleware state unchanged.

Likely causes:

- payload not decoded back into middleware ABI struct.
- callback executor path not wired into bundle processing handler.

### F5: Callback reverts

Symptoms:

- process bundle fails or logs callback error.
- response never appears.

Likely causes:

- malformed payload fields.
- wrong middleware contract address or ABI mismatch.
- connector/app registration mismatch at destination ledger.

### F6: Response never arrives at source

Symptoms:

- destination state changed, source never updates.

Likely causes:

- response enqueue path broken.
- queue correlation id not preserved.
- source callback execution failure.

## Log Sources and What to Look For

### Consensus Node Pod Logs

Command:

```bash
kubectl -n <ns> logs statefulset/network-node1 --tail=800
```

Look for:

- system-contract selector dispatch traces
- CLPR handler precheck/handle status
- `CLPR Endpoint` push/pull loop status
- queue metadata update messages

### CLPR Service Handler Logs

Primary classes to inspect for logging:

- `ClprUpdateMessageQueueMetadataHandler`
- `ClprProcessMessageBundleHandler`
- `ClprGetMessagesHandler`
- `ClprEndpointClient`

### HapiTest Output

Capture:

- test class name
- per-step assertions
- transaction IDs and status codes

### Contract-Level Evidence

Capture:

- middleware/app event emission
- key state variables before/after invocation
- app message ids and correlation fields

## Temporary Logging Policy (Required)

If diagnostic logging is added, annotate it as temporary directly above the log statement.

### Java Template

```java
// DEBUG-MARKER(CLPR-NQ-<issue-id>): Remove in ISSUE-0014 after root cause is confirmed.
log.info("...");
```

### Solidity Template

```solidity
/// @dev DEBUG-MARKER(CLPR-NQ-<issue-id>): Remove in ISSUE-0014 cleanup.
emit DebugMarker(...);
```

### JavaScript/Script Template

```js
// DEBUG-MARKER(CLPR-NQ-<issue-id>): Remove in ISSUE-0014 cleanup.
console.error("...");
```

Rules:

- Include issue id in marker.
- Prefer `debug`/`trace` level where possible.
- Never leave temporary markers unresolved when closing ISSUE-0014.

## Minimum Incident Artifact Bundle

For every failed run, save:

- timestamp + timezone
- git commit SHA(s) of both repos
- Solo deployment names/namespaces
- command/test that failed
- transaction IDs
- queue metadata snapshots from both ledgers
- relevant pod logs (consensus node, any CLPR-related component)
- short hypothesis summary (1-3 bullets)

Suggested folder structure:

- `artifacts/clpr-native-queue/<timestamp>/`
  - `context.txt`
  - `tx-ids.txt`
  - `queue-metadata-src.json`
  - `queue-metadata-dst.json`
  - `network-node1-src.log`
  - `network-node1-dst.log`
  - `summary.md`

## Debug Workflow (Recommended)

1. Reproduce once with current code and capture artifact bundle.
2. Identify failing stage (A-G).
3. Add minimal temporary instrumentation for that stage only.
4. Re-run focused test (unit first, then HapiTest, then Solo).
5. Confirm root cause with a deterministic signal.
6. Implement fix.
7. Remove temporary instrumentation or tag it for ISSUE-0014 cleanup.
8. Re-run regression matrix.

## Regression Matrix Before Marking Fix Done

- Unit tests for changed modules pass.
- Relevant HapiTests pass.
- Solo two-ledger smoke passes with evidence capture.
- No unresolved temporary debug markers.
