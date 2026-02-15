# Native CLPR Queue Integration: Final Result (ISSUE-0001 .. ISSUE-0014)

Date: 2026-02-13

This document explains the final result of the native CLPR queue integration work across:

- `hedera-smart-contracts` (Solidity middleware prototype + orchestration scripts + docs)
- `../hiero-consensus-node` (native CLPR messaging layer + EVM system-contract adapter)

The integration goal was to replace the mocked/off-chain CLPR relaying path with the **native CLPR message queue** inside the consensus node, while keeping the Solidity queue-facing API stable.

## 1) New End-to-End Test: Two-Ledger Solo Native-Queue Smoke

The primary end-to-end validation is a **one-command Solo smoke** that runs a full request/response round-trip across two ledgers using:

- native CLPR queue storage and bundle processing inside the consensus node,
- the new EVM system contract at `0x16E` as the queue adapter,
- HAPI/gRPC for contract deployment and invocation (no JSON-RPC relay dependency),
- an explicit “bundle pump” step to emulate off-ledger connector delivery.

Entry point:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh` (see `scripts/clpr/native-queue/run-two-ledger-smoke.sh:1`)

### Test Actor Overview

**Actors involved in the smoke run**

- Source ledger consensus node (Solo namespace `solo-clpr-native-src` by default)
- Destination ledger consensus node (Solo namespace `solo-clpr-native-dst` by default)
- Source-side deployed harness contract
- Destination-side deployed harness contract
- Bootstrap helper (Java main in consensus repo)
- Bundle pump helper (Java main in consensus repo)

**On-chain contracts used by the smoke run**

- `ClprMiddlewareHarness` (deployed to both ledgers)
  - Source contract call: `sendMessage(bytes32 remoteLedgerId, address destinationMiddleware, bytes payload)`
  - Destination callback: `handleMessage(ClprMessage message, uint64 inboundMessageId)`
  - Source callback: `handleMessageResponse(ClprMessageResponse response)`
  - Consensus repo file: `hedera-node/test-clients/src/main/resources/contract/contracts/ClprMiddlewareHarness/ClprMiddlewareHarness.sol:77`

- CLPR queue system contract (consensus node, not deployed)
  - Address: `0x16E`
  - Consensus repo file: `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/ClprQueueSystemContract.java:28`

### High-Level Sequence

The smoke run is intentionally structured as explicit stages, each with its own log output and evidence artifacts.

1. Preflight and environment health
2. CLPR control-plane bootstrap (config exchange + queue metadata init)
3. Deploy harness contracts on both ledgers
4. Send one outbound request on the source ledger (EVM -> system contract -> native queue)
5. Pump a request bundle to the destination ledger (emulate connector)
6. Destination ledger processes the request bundle (native bundle processing -> EVM callback)
7. Destination ledger enqueues a response (native enqueue)
8. Pump a response bundle back to the source ledger (emulate connector)
9. Source ledger processes the response bundle (native bundle processing -> EVM callback)
10. Assert destination and source contract state and capture evidence

### Detailed Sequence of Events (What Actually Happens)

This section maps the smoke run to the exact scripts/tools involved and what is happening at each stage.

#### Stage 0: Preflight and Guardrails

Runner script:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh:206`

Key checks:

- Single-controller ownership of Solo lifecycle.
  - Implemented by `assert_no_concurrent_solo_controller()`.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:98`

- Two-ledger health check.
  - Calls `scripts/clpr/native-queue/solo-two-network-status.sh`.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:226`

- Verifies the system contract feature gate is enabled on both ledgers:
  - `contracts.systemContract.clprQueue.enabled=true`
  - Implemented by exec’ing into the node pod and grepping `application.properties`.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:113`

- Starts resilient gRPC port-forwards to both ledgers.
  - `start_port_forward()` restarts `kubectl port-forward` if it exits.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:136`

Evidence always gets collected on exit via trap:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh:213` (trap)
- `scripts/clpr/native-queue/collect-evidence.sh:96`

#### Stage 1: CLPR Control-Plane Bootstrap (Config Exchange + Queue Metadata)

Bootstrap command (invoked by the smoke runner):

- `../hiero-consensus-node`:
  - `./gradlew :test-clients:runTestClient -PtestClient=com.hedera.services.bdd.tools.ClprNativeQueueBootstrapMain --rerun-tasks ...`
  - Invoked in `scripts/clpr/native-queue/run-two-ledger-smoke.sh:263`

Bootstrap tool implementation:

- `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueueBootstrapMain.java:31`

Bootstrap operations:

1. Connect to both ledgers over gRPC.
   - `ClprNativeQueueBootstrapMain.java:48`

2. Fetch each ledger’s *local* configuration state proof.
   - `ClprNativeQueueBootstrapMain.java:52`

3. Submit each configuration to the opposite ledger (cross-submission).
   - `ClprNativeQueueBootstrapMain.java:65`

4. Wait for remote configuration visibility on both ledgers.
   - `ClprNativeQueueBootstrapMain.java:81`

5. Ensure queue metadata exists in both directions (idempotent init).
   - `ClprNativeQueueBootstrapMain.java:85`
   - Queue init logic: `ClprNativeQueueBootstrapMain.java:283`

Smoke runner parses the ledger IDs from bootstrap logs:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh:280`

Why this stage exists:

- Native bundle exchange is blocked until the ledgers have shared configurations and a remote-ledger queue metadata object exists.
- The smoke runner makes this explicit and evidence-driven instead of relying on “background convergence.”

#### Stage 2: Deploy Harness Contracts to Both Ledgers (HAPI/gRPC)

Deployment script:

- `scripts/clpr/native-queue/deploy-two-ledger-contracts.js:4`

Deployment mechanism:

- Uses Hedera SDK `ContractCreateFlow` to deploy the same bytecode (`ClprMiddlewareHarness.bin`) to each ledger.
  - `scripts/clpr/native-queue/deploy-two-ledger-contracts.js:101`

Default harness artifact paths (from consensus repo test resources):

- `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/ClprMiddlewareHarness/ClprMiddlewareHarness.bin`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/ClprMiddlewareHarness/ClprMiddlewareHarness.json`

Path resolution:

- `scripts/clpr/native-queue/deploy-two-ledger-contracts.js:82`

Deployment output written to the smoke run directory:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh:296`

What this stage proves:

- You can deploy contracts to both ledgers via HAPI without needing the JSON-RPC relay.
- Each ledger provides a usable EVM address for the deployed harness contract.

#### Stage 3: Send One Source Message (EVM -> System Contract -> Native Queue)

Send-only invocation:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh:299` sets `CLPR_SMOKE_MODE=send-only` and calls:
  - `node scripts/clpr/native-queue/run-source-invocations.js`

Invocation behavior:

- Sends one contract execute transaction to the source harness:
  - Calls `sendMessage(remoteLedgerId, destinationMiddleware, payload)`.
  - Implemented at `scripts/clpr/native-queue/run-source-invocations.js:265`

Inside the harness contract, the send call does:

1. Constructs a route header tuple:
   - `(uint8 version, bytes32 remoteLedgerId, address sourceMiddleware, address destinationMiddleware)`
   - `ClprMiddlewareHarness.sol:111`

2. Builds a CLPR message struct (ABI shape matches the queue adapter expectations).
   - `ClprMiddlewareHarness.sol:113`

3. Calls `QUEUE.enqueueMessage(message)` where `QUEUE` is `address(0x16E)`.
   - `ClprMiddlewareHarness.sol:78`
   - `ClprMiddlewareHarness.sol:133`

On the consensus node, this triggers the new system contract:

- `ClprQueueSystemContract` routes the selector to the enqueue translator/call.
  - `ClprQueueSystemContract.java:50`

- `ClprQueueEnqueueMessageCall` decodes the route header and writes to native CLPR queue state.
  - `ClprQueueEnqueueMessageCall.java:53`

What this stage proves:

- The EVM call reaches the system contract at `0x16E`.
- The system contract can mutate native CLPR queue state (message store + metadata store) and return a `messageId`.

#### Stage 4: Pump Bundles Between Ledgers (Emulates Off-Ledger Connector)

Why pumping is required:

- In the real protocol, connectors deliver bundles between ledgers.
- In a local smoke run, nothing automatically “ships” messages between namespaces.
- So the smoke runner explicitly emulates connector behavior.

Pump command (invoked by the smoke runner):

- `../hiero-consensus-node`:
  - `./gradlew :test-clients:runTestClient -PtestClient=com.hedera.services.bdd.tools.ClprNativeQueuePumpMain --rerun-tasks ...`
  - Invoked in `scripts/clpr/native-queue/run-two-ledger-smoke.sh:311`

Pump tool implementation:

- `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueuePumpMain.java:34`

Pump operations:

1. Wait for an outbound request bundle on source:
   - `getMessages(dstLedgerId)`
   - `ClprNativeQueuePumpMain.java:73`

2. Submit that bundle to destination:
   - `clprProcessMessageBundle` transaction
   - `ClprNativeQueuePumpMain.java:78`

3. Wait for an outbound response bundle on destination:
   - `getMessages(srcLedgerId)`
   - `ClprNativeQueuePumpMain.java:87`

4. Submit that bundle back to source:
   - `clprProcessMessageBundle` transaction
   - `ClprNativeQueuePumpMain.java:92`

What this stage proves:

- Messages and replies are persisted and retrievable via the CLPR endpoint APIs.
- Bundle processing can be driven deterministically without relying on background timing.

#### Stage 5: Assert Destination and Source Callbacks

After pumping, the smoke runner re-runs the invocations script in assert-only mode:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh:330` sets `CLPR_SMOKE_MODE=assert-only` and calls:
  - `node scripts/clpr/native-queue/run-source-invocations.js`

Assertions are intentionally invariant-based (message ids may not start at 1 across repeated runs).

Destination-side assertions (via HAPI local call):

- `lastInboundMessageId > 0` (destination callback executed)
- `lastInboundRequestData == payload` (payload integrity)

Implementation:

- `scripts/clpr/native-queue/run-source-invocations.js:284`

Source-side assertions (via HAPI local call):

- `lastResponseOriginalMessageId == destinationLastInboundMessageId` (correlation)
- `lastResponseData == payload` (round-trip integrity)

Implementation:

- `scripts/clpr/native-queue/run-source-invocations.js:313`

Why this is the correct invariant:

- Message IDs are allocated by native queue state and persist across runs for a stable ledger-id/queue.
- Hard-coding “message id must be 1” is brittle and false after the first run.

#### Stage 6: Evidence Capture

Evidence collection is performed regardless of pass/fail.

Evidence script:

- `scripts/clpr/native-queue/collect-evidence.sh:26`

What is captured:

- Kubernetes pod/service state.
  - `scripts/clpr/native-queue/collect-evidence.sh:32`

- Pod logs.
  - `scripts/clpr/native-queue/collect-evidence.sh:37`

- In-pod file logs (high signal):
  - `hgcaa.log` tail
  - `swirlds.log` tail
  - `scripts/clpr/native-queue/collect-evidence.sh:43`

- CLPR + system-contract config snapshots from `application.properties`.
  - `scripts/clpr/native-queue/collect-evidence.sh:70`

- Stage logs and JSON outputs:
  - `compile.log`, `bootstrap.log`, `deploy.log`, `pump.log`, `invoke.log`
  - `deployment.json`, `invoke-result.json`
  - `scripts/clpr/native-queue/collect-evidence.sh:112`

- A `smoke-summary.md` pointing at key files.
  - `scripts/clpr/native-queue/collect-evidence.sh:123`

PASS evidence bundle example:

- `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/`

## 2) Setup, Run, and Tear Down (Command-by-Command)

This section explains the commands needed to execute the end-to-end smoke in a clean, repeatable way.

### Preconditions

1. Confirm Solo CLI is available and the expected version.

```bash
solo --version
```

What it does:

- Verifies you are using Solo tooling compatible with the runbooks and known environment behaviors.

2. Confirm Kubernetes context.

```bash
kubectl config current-context
```

What it does:

- Ensures `kubectl` points at the cluster Solo will deploy into.

3. Ensure the consensus node local-build artifacts exist.

```bash
ls -la ../hiero-consensus-node/hedera-node/data
```

What it does:

- Confirms Solo can mount/apply a custom consensus-node build via `--local-build-path`.

If you need to (re)build the local artifacts:

```bash
cd ../hiero-consensus-node
./gradlew :hedera-node:assemble
```

What it does:

- Produces the local node artifacts under `hedera-node/data/` that Solo’s `consensus node setup --local-build-path` applies.

4. Ensure Node.js dependencies for this repo are installed.

```bash
npm install
```

What it does:

- Installs `@hashgraph/sdk`, `ethers`, and other JS dependencies used by the deploy/invoke scripts.

### Setup: Bring Up Two Solo Ledgers

1. Create both deployments and start the nodes.

```bash
scripts/clpr/native-queue/solo-two-network-up.sh
```

What it does:

- Creates/attaches Solo deployment configs for two networks.
- Deploys consensus network resources for each.
- Applies locally built node artifacts:
  - `solo consensus node setup --local-build-path ...`
  - Implemented in `scripts/clpr/native-queue/solo-two-network-up.sh:96`
- Starts nodes, treating the known `INVALID_NODE_ID` gRPC-web endpoint failure as non-fatal if runtime health is OK.
  - `scripts/clpr/native-queue/solo-two-network-up.sh:112`

Configuration applied during deploy:

- Source ledger: `scripts/clpr/native-queue/config/application-src.properties:2`
- Destination ledger: `scripts/clpr/native-queue/config/application-dst.properties:2`

Both configs enable:

- `clpr.clprEnabled=true`
- `clpr.devModeEnabled=true`
- `contracts.systemContract.clprQueue.enabled=true`

2. Confirm health.

```bash
scripts/clpr/native-queue/solo-two-network-status.sh
```

What it does:

- Validates both namespaces exist and have a running `network-node1` pod.
- Verifies the JVM is running inside the pod.
- Verifies gRPC `50211` is reachable inside the pod.
- Confirms `clpr.clprEnabled=true` is present in `application.properties`.
- Also prints the control-plane phase and warns on known phase/runtime drift.

Implementation:

- `scripts/clpr/native-queue/solo-two-network-status.sh:40`

### Setup: Provide Operator Keys for HAPI Transactions

The smoke uses HAPI transactions (contract create, contract execute, contract call query). You must provide funded operator credentials for each ledger.

Required environment variables:

- `CLPR_SRC_OPERATOR_KEY`
- `CLPR_DST_OPERATOR_KEY`

Optional overrides:

- `CLPR_SRC_OPERATOR_ID` (default `0.0.2`)
- `CLPR_DST_OPERATOR_ID` (default `0.0.2`)

The scripts accept DER-formatted keys or other SDK-parsable formats.

A common Solo pattern is to pull a private key from an `account-key-*` secret:

```bash
kubectl -n solo-clpr-native-src get secrets | rg '^account-key-'

# Example: decode the privateKey field (base64) from a chosen secret
kubectl -n solo-clpr-native-src get secret <secret-name> -o jsonpath='{.data.privateKey}' | base64 -d
```

What it does:

- Lists available account secrets.
- Decodes the `privateKey` data field into the DER string the scripts can use for `CLPR_SRC_OPERATOR_KEY`.

If you use a non-default operator account, set `CLPR_SRC_OPERATOR_ID`/`CLPR_DST_OPERATOR_ID` to match.

### Run: Execute the One-Command Smoke

From this repo root:

```bash
export CLPR_SRC_OPERATOR_KEY='<src-operator-key>'
export CLPR_DST_OPERATOR_KEY='<dst-operator-key>'

scripts/clpr/native-queue/run-two-ledger-smoke.sh
```

What it does:

- Preflight checks + resilient port-forwards.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:223`

- Compiles consensus-node test-client tooling.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:257`

- Bootstraps CLPR control-plane between ledgers.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:263`

- Deploys `ClprMiddlewareHarness` to both ledgers via HAPI.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:287`

- Sends one request.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:299`

- Pumps request + response bundles.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:311`

- Asserts destination and source callbacks.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:330`

- Collects a full evidence bundle even on failure.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:175`
  - `scripts/clpr/native-queue/collect-evidence.sh:26`

Evidence output:

- `artifacts/clpr-native-queue/issue-0013/<RUN_ID>/`

### Tear Down: Destroy Both Solo Deployments

```bash
scripts/clpr/native-queue/solo-two-network-down.sh
```

What it does:

- Stops nodes (best-effort).
- Destroys relay/mirror resources if present.
- Destroys the consensus networks.
- Removes local Solo deployment config entries.

Implementation:

- `scripts/clpr/native-queue/solo-two-network-down.sh:39`

If you want to keep local Solo configs (but still destroy cluster resources):

```bash
scripts/clpr/native-queue/solo-two-network-down.sh --keep-config
```

## 3) Solidity Changes Required (Barriers and Fixes)

The end-to-end integration forced a small set of critical Solidity changes. The goal was to keep public interfaces stable while providing the metadata and authorization behavior needed for native queue semantics.

### Barrier A: Native Queue Requires Deterministic Routing Metadata

Problem:

- `IClprQueue.enqueueMessage(ClprMessage)` does not have an explicit “remote ledger id” parameter.
- The native adapter must know:
  - which remote-ledger queue to append to, and
  - which middleware contracts to call on the destination.

Fix:

1. Embed a route header in `ClprMessage.middlewareMessage.data`.

- Route header encoding is done in:
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:568`

Key implementation detail:

- `_buildSourceMiddlewareMessage(...)` sets:
  - `data = abi.encode(ROUTE_VERSION, reg.remoteLedgerId, address(this), destinationMiddleware)`
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:587`

2. Require source connectors to be configured with the paired remote middleware address.

- New API:
  - `IClprMiddleware.setConnectorRemoteMiddleware(...)`
  - `contracts/solidity/clpr/interfaces/IClprMiddleware.sol:37`

- Implementation:
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:265`

- Enforcement:
  - sends are rejected if `remoteMiddleware` is unset
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:308`

Test coverage:

- Hardhat ensures remote middleware mapping is configured before sends.
  - `test/solidity/clpr/clprMiddleware.js:180`
- Foundry mirrors the same.
  - `test/foundry/ClprMiddleware.t.sol:154`

### Barrier B: Response Routing Needs a Different Route Header Shape

Problem:

- The response enqueue path expects the route header for `enqueueMessageResponse` to include:
  - `(version, remoteLedgerId, targetMiddleware)`
- But the request route header is `(version, remoteLedgerId, sourceMiddleware, destinationMiddleware)`.

Fix:

- Decode the request route header on destination and build a response route header.

Implementation:

- `_buildResponseRouteHeader(bytes requestRouteData)`:
  - decodes `(uint8,bytes32,address,address)`
  - validates version, remoteLedgerId, sourceMiddleware
  - validates the destination middleware matches `address(this)`
  - returns `(uint8,bytes32,address)`

File:

- `contracts/solidity/clpr/middleware/ClprMiddleware.sol:708`

This is used in:

- `handleMessage(...)` to populate response route bytes.
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:403`

### Barrier C: Native Callback Sender Identity Is Not Always the Queue Contract

Problem:

- Production intent is: middleware callback entrypoints are “queue-only.”
- In native queue flows, callback dispatch can originate from native handler contexts that are not literally the mock queue contract used in local tests.

Fix:

- Keep queue-only semantics as the default.
- Add a controlled override: `trustedCallbackCaller`.

Interface and implementation:

- `IClprMiddleware.setTrustedCallbackCaller(address caller)`
  - `contracts/solidity/clpr/interfaces/IClprMiddleware.sol:43`

- `trustedCallbackCaller` storage:
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:103`

- New modifier used by callback entrypoints:
  - `onlyQueueOrTrustedCallback`
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:208`

- Applied to:
  - `handleMessage(...)` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:403`)
  - `handleMessageResponse(...)` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:517`)

Test coverage:

- Hardhat: trusted callback caller allows bypassing the queue-only gate, but still enforces message existence.
  - `test/solidity/clpr/clprMiddleware.js:253`

- Foundry: same behavior.
  - `test/foundry/ClprMiddleware.t.sol:190`

### Barrier D: Local Tests Needed to Model Asynchrony (Queue Stores Responses)

Problem:

- A “synchronous” mock queue that immediately calls both destination and source in one stack frame hides real ordering and correlation issues.

Fix:

- `MockClprQueue` stores responses and requires an explicit delivery step.

Implementation:

- Response stored under `originalMessageId`:
  - `contracts/solidity/clpr/mocks/MockClprQueue.sol:41`

- `deliverAllMessageResponses()` drives asynchronous delivery.
  - `contracts/solidity/clpr/mocks/MockClprQueue.sol:127`

Tests updated accordingly:

- Hardhat uses `deliverAllMessageResponses()` before asserting source-side response effects.
  - `test/solidity/clpr/clprMiddleware.js:326`

### Barrier E: Tests Needed to Assert Route Header Bytes End-to-End

Problem:

- Native adapter correctness hinges on byte-level envelope fidelity.

Fix:

- `MockClprConnector` records route-header bytes it observes on the destination side.

Implementation:

- Captures request and response route bytes:
  - `contracts/solidity/clpr/mocks/MockClprConnector.sol:262`

Hardhat asserts exact ABI-encoded route header bytes:

- `test/solidity/clpr/clprMiddleware.js:296`

Foundry mirrors the same route checks:

- `test/foundry/ClprMiddleware.t.sol:232`

## 4) Consensus Node: New EVM System Contract (EVM <-> Native Queue)

The core bridge is a new **CLPR Queue System Contract** at `0x16E` inside the consensus node smart-contract service.

Conceptually:

- Solidity calls `IClprQueue.enqueueMessage(...)` or `enqueueMessageResponse(...)`.
- The consensus node intercepts the call because the target address is a reserved system-contract address.
- The call is decoded and translated into **native CLPR queue state mutations**.

### 4.1 Address Mapping and Feature Gate

Address mapping:

- Wired into the system contract map in:
  - `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ProcessorModule.java:35`

The CLPR system contract is registered at:

- `0x16e`
- `CLPR_QUEUE_EVM_ADDRESS` in:
  - `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/ClprQueueSystemContract.java:30`

Feature gate:

- Config property:
  - `contracts.systemContract.clprQueue.enabled`
  - `hedera-node/hedera-config/src/main/java/com/hedera/node/config/data/ContractsConfig.java:90`

- Gate enforcement:
  - `ClprQueueSystemContract.computeFully()` reverts with `CLPR_QUEUE_DISABLED` when off.
  - `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/ClprQueueSystemContract.java:50`

Unit test for gate behavior:

- `hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/ClprQueueSystemContractTest.java:61`

### 4.2 Call Dispatch Architecture

The system contract uses the standard contract-service call pipeline:

1. `ClprQueueCallFactory` creates a `ClprQueueCallAttempt` from the EVM frame.
   - `.../ClprQueueCallFactory.java:51`

2. `ClprQueueCallAttempt.asExecutableCall()` iterates translators.
   - `.../ClprQueueCallAttempt.java:41`

3. If no translator matches, it returns a typed revert call:
   - `CLPR_QUEUE_UNSUPPORTED_SELECTOR`
   - `.../ClprQueueCallAttempt.java:49`

4. Translators are provided via Dagger module:
   - `.../ClprQueueTranslatorsModule.java:20`

Typed revert call implementation:

- `.../ClprQueueRevertCall.java:20`

Call attempt tests:

- Unsupported selector returns typed reason.
  - `.../ClprQueueCallAttemptTest.java:31`

### 4.3 Request Enqueue: `enqueueMessage(ClprMessage)`

Translator:

- Signature locked to the ABI shape used by `IClprQueue.enqueueMessage(ClprMessage)`.
  - `.../ClprQueueEnqueueMessageTranslator.java:24`

- On decode failure, returns typed revert:
  - `CLPR_QUEUE_BAD_CALLDATA`
  - `.../ClprQueueEnqueueMessageTranslator.java:47`

Call implementation (`execute()`):

- Decodes route header from the nested `middlewareMessage.data` bytes.
  - `.../ClprQueueEnqueueMessageCall.java:90`

- Validates:
  - route version == 1
  - remote ledger id is non-zero
  - `.../ClprQueueEnqueueMessageCall.java:59`

- Encodes the request envelope bytes:
  - `(uint8,bytes32,address,address,bytes callData)`
  - `.../ClprQueueEnqueueMessageCall.java:101`

- Writes to native CLPR queue state using `ClprQueueOperations.enqueue(...)`.
  - `.../ClprQueueEnqueueMessageCall.java:75`

- Returns ABI-encoded `(uint64 messageId)`.
  - `.../ClprQueueEnqueueMessageCall.java:81`

Key typed revert reasons emitted by this call:

- `CLPR_QUEUE_BAD_ROUTE_ENVELOPE`
- `CLPR_QUEUE_UNSUPPORTED_ROUTE_VERSION`
- `CLPR_QUEUE_INVALID_REMOTE_LEDGER_ID`

Translator unit tests cover:

- selector match, bad calldata, unsupported route version, zero remote ledger id, malformed route header bytes.
- `.../ClprQueueEnqueueMessageTranslatorTest.java:63`

### 4.4 Response Enqueue: `enqueueMessageResponse(ClprMessageResponse)`

Translator:

- `.../ClprQueueEnqueueMessageResponseTranslator.java:24`

Call behavior:

- Validates `originalMessageId > 0`.
  - `.../ClprQueueEnqueueMessageResponseCall.java:53`

- Decodes response route header from nested `middlewareResponse.middlewareMessage.data`.
  - `.../ClprQueueEnqueueMessageResponseCall.java:101`

- Encodes response envelope:
  - `(uint8 version, address targetMiddleware, bytes callData)`
  - `.../ClprQueueEnqueueMessageResponseCall.java:112`

- Enqueues the native reply payload:
  - `ClprMessageReply.messageReplyData = responseEnvelopeBytes`
  - `.../ClprQueueEnqueueMessageResponseCall.java:79`

Unit tests cover:

- invalid original message id, malformed route header, unsupported route version, zero ledger id.
- `.../ClprQueueEnqueueMessageResponseTranslatorTest.java:105`

### 4.5 Bridging the Store Boundary (Contract Service -> CLPR Service State)

The system contract must mutate CLPR state, but it executes inside the smart-contract service handle context.

Two key changes make this possible.

1. Expose CLPR writable stores through `HederaNativeOperations`.

- Default methods added:
  - `writableClprMessageQueueMetadataStore()`
  - `writableClprMessageStore()`

File:

- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HederaNativeOperations.java:93`

Handle-time implementation:

- `HandleHederaNativeOperations` returns these stores via `context.storeFactory().writableStore(...)`.
  - `.../HandleHederaNativeOperations.java:116`

2. Allow cross-service writable access from the contract service into the CLPR service.

Problem:

- Store factory calls are generally scoped to the current service.

Fix:

- `WritableStoreFactory` explicitly permits a small allow-list of CLPR writable stores when the caller is `ContractService`.

File:

- `hedera-node/hedera-app/src/main/java/com/hedera/node/app/store/WritableStoreFactory.java:69`
- Cross-service routing:
  - `hedera-node/hedera-app/src/main/java/com/hedera/node/app/store/WritableStoreFactory.java:197`

Without this, the system contract would be unable to persist queue messages.

### 4.6 Module and Method Registry Integration

- `SystemContractMethod.SystemContract` gained a `CLPR` kind.
  - `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/utils/SystemContractMethod.java:101`

- The smart-contract service module was updated to require CLPR modules.
  - `hedera-node/hedera-smart-contract-service-impl/src/main/java/module-info.java:29`

## 5) Consensus Node: Messaging Layer Changes Required (Native Queue + Bundle Processing)

The messaging layer changes live primarily in `hiero-clpr-interledger-service-impl`. They enable:

- native enqueue mutations from the EVM system contract,
- correct queue metadata semantics (especially `sentMessageId` vs `nextMessageId`),
- inbound bundle processing that calls Solidity middleware callbacks,
- correct response routing and correlation.

### 5.1 Hurdle: Implement Native Enqueue Mutation (Queue State Must Actually Change)

Problem:

- The EVM adapter must append outbound messages into the CLPR queue state.
- This cannot be a test-only shortcut; it must update:
  - message store,
  - running hash,
  - `nextMessageId`.

Fix:

- Added a native utility operation:
  - `ClprQueueOperations.enqueue(...)`

File:

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java:41`

Key behaviors:

- Validates remote ledger id is non-empty.
  - `ClprQueueOperations.java:52`

- Validates payload has request or reply.
  - `ClprQueueOperations.java:53`

- Reads queue metadata and assigns `messageId = nextMessageId`.
  - `ClprQueueOperations.java:55`

- Computes `runningHashAfterProcessing` and stores the message.
  - `ClprQueueOperations.java:61`

- Updates only `nextMessageId` (does not change `sentMessageId`).
  - `ClprQueueOperations.java:71`

This operation is called from:

- system contract enqueue calls (`ClprQueueEnqueueMessageCall`, `ClprQueueEnqueueMessageResponseCall`)
- bundle processing handler when enqueuing response payloads (`ClprProcessMessageBundleHandler`)

### 5.2 Hurdle: Remove Synthetic Queue Seeding (Prevent False Positives)

Problem:

- Earlier dev/test behavior seeded queues with synthetic messages.
- This breaks invariant assumptions and causes brittle tests (e.g., expecting message id to start at 21).

Fix:

- Ensure queue initialization produces a clean empty-queue baseline:
  - `nextMessageId = 1`
  - `sentMessageId = 0`
  - `receivedMessageId = 0`

Implementation:

- `initQueue(...)` in `ClprUpdateMessageQueueMetadataHandler`.
  - `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java:139`

Impact:

- Baseline CLPR suites had to stop expecting synthetic “20 messages exist” behavior.

### 5.3 Hurdle: Bundle Processing Must Invoke EVM Callbacks (Native -> Solidity)

Problem:

- Enqueueing messages is not enough; when a ledger processes inbound bundles it must:
  - decode the queued payload into middleware call(s),
  - call destination middleware `handleMessage(...)`,
  - enqueue the response,
  - call source middleware `handleMessageResponse(...)` on response bundles.

Fix:

- `ClprProcessMessageBundleHandler` now implements an envelope-aware callback state machine.

File:

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`

Key additions:

- Envelope types:
  - `REQUEST_ENVELOPE_TYPE` and `RESPONSE_ENVELOPE_TYPE`
  - `ClprProcessMessageBundleHandler.java:65`

- Processing loop distinguishes request vs reply payloads.
  - `ClprProcessMessageBundleHandler.java:181`

- Request payload path:
  - decode request envelope
  - dispatch `handleMessage` contract call
  - encode and enqueue response
  - `ClprProcessMessageBundleHandler.java:206`

- Response payload path:
  - decode response envelope
  - dispatch `handleMessageResponse` contract call
  - `ClprProcessMessageBundleHandler.java:236`

### 5.4 Hurdle: Callback Dispatch Must Use Synthetic Contract Calls

Problem:

- Bundle processing happens inside a native transaction handler.
- It must invoke EVM code via a synthetic HAPI contract call.

Fix:

- Build and dispatch a synthetic `ContractCallTransactionBody` for the target middleware.

Implementation:

- `dispatchContractCall(...)`
  - constructs `ContractCallTransactionBody`
  - dispatches via `stepDispatch(...)`
  - `ClprProcessMessageBundleHandler.java:310`

Address-to-ContractID conversion logic:

- `asContractId(...)` resolves numbered or EVM-address-based contract IDs.
  - `ClprProcessMessageBundleHandler.java:330`

Gas limit:

- Pulls `contracts.maxGasPerTransaction` from config.
  - `ClprProcessMessageBundleHandler.java:323`

### 5.5 Hurdle: Extract EVM Call Return Bytes Reliably

Problem:

- The handler needs the raw EVM output bytes from the synthetic contract call to decode `handleMessage` return values.
- Stream builder types are not always directly accessible.

Fix:

- Use reflection to call `getEvmCallResult` on the `StreamBuilder`.

Implementation:

- `extractEvmCallResult(...)`
  - `ClprProcessMessageBundleHandler.java:466`

Failure handling:

- If extraction fails, treat as not supported / invalid for this environment.
  - `ClprProcessMessageBundleHandler.java:477`

### 5.6 Hurdle: Response Route Header Must Be Patched for Adapter Expectations

Problem:

- The response enqueue system-contract path expects `middlewareResponse.middlewareMessage.data` to contain the response route header.
- But `handleMessage(...)` returns a response struct that may contain request route bytes.

Fix:

- Patch the route bytes before wrapping/queueing the response envelope.

Implementation:

- `injectResponseRouteHeader(...)`
  - Decodes the `enqueueMessageResponse` call data
  - Replaces nested route header with `(version, remoteLedgerId, sourceMiddleware)`
  - Re-encodes the call

File:

- `ClprProcessMessageBundleHandler.java:420`

### 5.7 Hurdle: Make Bootstrap/Connector-Emulation Explicit for Local Runs

Problem:

- Local smoke runs stalled when relying on implicit background behavior.
- Two missing explicit actions were required:
  - control-plane bootstrap (config exchange + queue metadata init)
  - message “shipping” between ledgers (bundle pump)

Fix:

- Added two Java tools used by the smoke runner.

Bootstrap tool:

- `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueueBootstrapMain.java:31`

Pump tool:

- `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueuePumpMain.java:34`

### 5.8 Hurdle: Dev-Mode Signing Key Discovery Broke Under Gradle `user.dir`

Problem:

- When running `:test-clients:runTestClient`, Gradle sets `user.dir` to the module directory.
- Dev-mode key lookups that assume repo root fail, causing bootstrap/pump tools to warn:
  - “No dev-mode signing key found”.

Fix:

- Walk up parent directories and try both:
  - `data/onboard/...`
  - `hedera-node/data/onboard/...`

Implementation:

- `candidatePaths(...)` in `ClprClientImpl`.
  - `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/client/ClprClientImpl.java:536`

### 5.9 Regression Coverage Added for Messaging Layer and Adapter

Targeted unit tests include:

- system-contract adapter translator tests:
  - `.../ClprQueueEnqueueMessageTranslatorTest.java`
  - `.../ClprQueueEnqueueMessageResponseTranslatorTest.java`

- handler tests:
  - `.../ClprProcessMessageBundleHandlerTest.java`

Regression run matrix is captured in:

- `docs/clpr/native-queue-integration-plan/issue-0014-evidence.md`

## 6) Lessons Learned (For Junior Developers)

Each lesson below is presented as:

- Lesson statement
- Why it matters (with an example from this integration)

### Lesson 1: Always Turn “End-to-End” Into a Staged Pipeline

Why it matters:

- Complex integrations fail in many places. If you only have a single “it failed” signal, debugging becomes guesswork.
- This project explicitly staged the smoke run into:
  - preflight, bootstrap, deploy, send, pump, assert, evidence.

Example:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh` writes independent logs per stage:
  - `compile.log`, `bootstrap.log`, `deploy.log`, `pump.log`, `invoke.log`
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:35`

### Lesson 2: Make Evidence Collection Automatic and Non-Blocking

Why it matters:

- The most valuable debugging artifacts often exist only at the moment of failure.
- If evidence capture is manual, you will forget it or capture after state has changed.

Example:

- The smoke runner traps exit and collects evidence even on failure.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:213`

- Evidence collection is best-effort and intentionally does not fail the smoke run.
  - `scripts/clpr/native-queue/run-two-ledger-smoke.sh:201`

### Lesson 3: Avoid Hard-Coding IDs; Assert Invariants Instead

Why it matters:

- IDs like message numbers often persist across runs and environments.
- Hard-coded assumptions turn real success into false failures.

Example:

- The smoke assertion uses:
  - `destination lastInboundMessageId > 0`
  - `source lastResponseOriginalMessageId == destination lastInboundMessageId`
  - `scripts/clpr/native-queue/run-source-invocations.js:284`

### Lesson 4: When an Interface Lacks Needed Context, Add an Explicit Envelope

Why it matters:

- Changing public APIs is expensive and cascades into many call sites.
- Adding a minimal, explicit envelope preserves stable interfaces while enabling new behavior.

Example:

- The queue adapter needed routing info but `enqueueMessage` didn’t expose it, so the route header moved into bytes:
  - `ClprMiddleware.sol` encodes it in `middlewareMessage.data`.
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol:587`

- The consensus system contract then decodes and re-encodes envelope bytes.
  - `ClprQueueEnqueueMessageCall.java:90`

### Lesson 5: Feature-Gate New System Contracts

Why it matters:

- New system contracts can change consensus behavior.
- A feature gate allows safe rollout and prevents accidental activation.

Example:

- Gate is off by default:
  - `ContractsConfig.systemContractClprQueueEnabled` default is `false`.
  - `hedera-node/hedera-config/src/main/java/com/hedera/node/config/data/ContractsConfig.java:90`

- When off, the system contract reverts with a typed reason.
  - `ClprQueueSystemContract.java:54`

### Lesson 6: Preserve Exactly-Once Semantics by Failing Fast on Callback Errors

Why it matters:

- If you “partially succeed” (update metadata but lose callback), you corrupt protocol state.
- It’s usually better to fail the whole bundle processing transaction and retry later.

Example:

- Bundle processing validates callback status is `SUCCESS` and throws otherwise.
  - `ClprProcessMessageBundleHandler.java:275`

This means:

- Queue metadata update at the end of the handler never commits on callback failure.

### Lesson 7: Cross-Service State Mutation Must Be Explicit and Tested

Why it matters:

- Most systems assume a service can only write its own state.
- “Hidden” cross-service writes create security and correctness risks.

Example:

- This integration explicitly allow-listed CLPR writable stores for contract service access.
  - `WritableStoreFactory.java:69`
  - `WritableStoreFactory.java:197`

### Lesson 8: Dev Tools Must Be Robust to Build/Run Working Directories

Why it matters:

- Tools that depend on relative paths often break when run under Gradle, CI, or other orchestrators.

Example:

- Dev-mode signing key discovery was fixed to walk parent dirs.
  - `ClprClientImpl.java:536`

### Lesson 9: Emulate Missing Real-World Actors Explicitly

Why it matters:

- If a system depends on an actor that is not present in local tests (connectors, relayers, etc.), the test must provide a deterministic substitute.

Example:

- The smoke run includes a “bundle pump” step to emulate connector delivery.
  - `ClprNativeQueuePumpMain.java:20`

