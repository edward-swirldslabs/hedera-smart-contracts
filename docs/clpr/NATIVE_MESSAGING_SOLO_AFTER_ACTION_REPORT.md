# Native Messaging SOLO (ClprEndpointClient) After Action Report

Date: 2026-02-14

Scope:

- This repo: `hedera-smart-contracts`
- Sibling repo: `../hiero-consensus-node`

Definition of done:

- Two independent SOLO deployments (source and destination) are running in Kubernetes.
- Both ledgers run the same consensus-node build that includes the CLPR queue system contract at `0x16e`.
- Solidity middleware enqueues outbound messages via `0x16e`, which writes into the native CLPR queue/state.
- Cross-ledger transport is performed exclusively by the in-node native messaging layer (`ClprEndpointClient`) exchanging `ClprMessageBundle` over CLPR gRPC.
- The only external bootstrap action is a one-time exchange of `ClprLedgerConfiguration` state proofs between ledgers (to seed endpoint configuration).
- The scripted scenario (connector authorization failover + destination-funds depletion) completes successfully and is evidenced by `Scenario passed` in `scenario.log`.

Evidence (a full passing run in this workspace):

- `artifacts/clpr-native-messaging-solo/20260214T005029Z/`

---

## 1) End Result Of Each Current Issue (0101-0108)

### ISSUE-0101: Define Target State and Guardrails

Summary: Defined the target architecture and enforced guardrails that prevent reintroducing an external bundle pump or parallel messaging infrastructure.

End result:

- The target architecture is explicitly locked:
  - Cross-ledger transport is the in-node `ClprEndpointClient`.
  - The only allowed external “kick” is a one-time config exchange (share endpoints via `ClprLedgerConfiguration` proof).
  - No external pump.
  - Connectors are paymasters only (no routing, no transport).
- The anti-pattern “pump-based” attempt is explicitly quarantined under `docs/quarantine/`.
- `AGENTS.md` was updated so future agents see the guardrails and the quarantine pointer immediately.

Verification:

- Confirm `docs/clpr/native-messaging-solo-integration-plan/README.md` explicitly forbids external pumping and requires `ClprEndpointClient` as the only cross-ledger transport.
- Run `bash scripts/clpr/native-messaging-solo/run-e2e.sh` and confirm the scenario completes without any off-chain bundle-forwarding step.

Primary references:

- `docs/clpr/native-messaging-solo-integration-plan/README.md`
- `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
- `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/README.md`

### ISSUE-0102: SOLO Two-Ledger Network Reachability

Summary: Ensured the two SOLO deployments advertise CLPR endpoints that are reachable by the peer ledger in-cluster.

End result:

- SOLO deployments are configured to publicize CLPR endpoints that are actually reachable from the other ledger.
- Required SOLO config is made explicit and repeatable:
  - `clpr.publicizeNetworkAddresses=true`
  - `nodes.gossipFqdnRestricted=false` (SOLO uses in-cluster DNS names)
- A fast health script verifies both ledgers are up and configured correctly:
  - `scripts/clpr/native-messaging-solo/two-network-status.sh`

Verification:

- Run `scripts/clpr/native-messaging-solo/two-network-status.sh`.
- Confirm both ledgers are healthy, CLPR is enabled, and the advertised endpoints are appropriate for the SOLO/Kubernetes environment.

### ISSUE-0103: Config Exchange “Kick” Tooling (No Pump)

Summary: Implemented the only allowed external “kick”: a one-time exchange of `ClprLedgerConfiguration` state proofs so each ledger can discover the other’s endpoints.

End result:

- Added a minimal tool that does only the allowed “kick”:
  - Fetch each ledger’s local `ClprLedgerConfiguration` state proof.
  - Install it onto the other ledger via `setConfiguration(...)`.
  - Optionally wait until queue metadata exists on both sides.
- The tool does not ship bundles and does not “pump” messages.

Verification:

- Run the config exchange step and confirm you see “setConfiguration” succeed for both ledgers.
- After config exchange, confirm message movement occurs without any additional off-chain process.

Implementation:

- `tools/clpr/ClprConfigExchange.java`

Used by:

- `scripts/clpr/native-messaging-solo/run-e2e.sh`

### ISSUE-0104: Queue System Contract (Minimal Adapter to Native Queue)

Summary: Added a queue system contract at `0x16e` that adapts EVM calls into native CLPR queue/state writes.

End result:

- The consensus node now exposes a system contract at `0x16e` that implements the queue methods the middleware expects.
- Calling `enqueueMessage(...)` and `enqueueMessageResponse(...)` from EVM results in native queue state being updated.
- This is a bridge only; it does not create any new cross-ledger transport.
- The system contract is feature-gated by config:
  - `contracts.systemContract.clprQueue.enabled=true`

Verification:

- Deploy middleware pointing at queue `0x16e`.
- Send one message from the source app.
- Confirm the destination receives the request and the source receives the response without any off-chain pumping (proving `0x16e` successfully enqueues into the native queue and the in-node transport delivers bundles).

### ISSUE-0105: SOLO E2E Native Messaging (No Pump)

Summary: Proved end-to-end two-ledger messaging in SOLO using native messaging (`ClprEndpointClient`) with no external pump.

End result:

- A single repeatable script:
  - Builds consensus-node artifacts (optional)
  - Deploys two SOLO networks
  - Port-forwards gRPC
  - Performs config exchange “kick”
  - Deploys contracts and runs the full connector failover + funds depletion scenario
  - Collects evidence
  - Tears down cleanly
- The proof of success is in `scenario.log`: it prints `Scenario passed`.

Primary runner:

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

### ISSUE-0106: Cleanup, Regression Guards, and Documentation

Summary: Consolidated documentation, added regression guardrails, and quarantined the pump-based anti-pattern for reference only.

End result:

- Documentation clearly points to:
  - The correct plan (native messaging, no pump)
  - The quarantine archive (pump anti-pattern)
- Guardrails and diagnostic allowances are written in `AGENTS.md`.
- Evidence and reproducibility instructions are consolidated:
  - `docs/clpr/NATIVE_MESSAGING_SOLO_PROGRESS.md`
- Generated evidence directories are ignored:
  - `.gitignore` ignores `artifacts/clpr-native-messaging-solo/` and `artifacts/clpr-native-queue/`

Verification:

- Run the scenario twice. You should get two different `artifacts/clpr-native-messaging-solo/<timestamp>/` folders.
- Confirm these artifacts don’t show up in `git status` as tracked (they should be ignored).

### ISSUE-0107: Pare Down `hedera-smart-contracts` Changes

Summary: Reduced Solidity/app/test changes to the smallest set required to integrate with the `0x16e` system contract and validate the SOLO scenario.

End result:

- Middleware changes were kept narrowly focused on:
  - Providing a route header needed by the system contract and the native bundle handler
  - Allowing the native callback dispatch path to reach middleware handlers safely
- App changes were kept narrowly focused on:
  - Making the SOLO scenario deterministic to drive and assert without mirror/relay dependence
- Connector changes were avoided for “real” logic:
  - Only mock/test connectors were adjusted to aid observability in tests

Verification:

- The connector contracts still only “approve/deny payment”.
- All “shipping the message” behavior comes from the node (`ClprEndpointClient`), not from Solidity connectors.

### ISSUE-0108: Pare Down `../hiero-consensus-node` Changes

Summary: Kept consensus-node changes focused on the queue system contract and the minimal wiring/bugfixes required for the existing native messaging layer to operate in SOLO.

End result:

- The only cross-ledger transport remains `ClprEndpointClient`.
- Active code contains no external pump.
- The consensus node gained:
  - The `0x16e` queue system contract
  - Native queue write helpers used by both the system contract and bundle processing
  - Bundle processing that calls into EVM middleware to produce responses
  - SOLO bootstrap fixes so endpoints and ledger IDs work in a two-ledger dev environment

Verification:

- There is no step in the runner that “moves bundles by hand”.
- If messages move, it is because the in-node `ClprEndpointClient` moved them.

---

## 2) Current Two-SOLO Interledger Behavior (And How It Differs From The Quarantined Version)

### 2.1 The Current Behavior (No Pump)

High-level flow:

1. Perform a one-time config exchange so each ledger has a verified `ClprLedgerConfiguration` for the peer (endpoint discovery/bootstrap).
2. The source application submits a send transaction to the source middleware contract, which applies connector failover semantics.
3. The source middleware enqueues the request via the queue system contract at `0x16e`, writing the request into native CLPR queue/state.
4. The in-node native messaging layer (`ClprEndpointClient`) packages queued outbound messages into `ClprMessageBundle` instances and delivers them to the destination over CLPR gRPC.
5. The destination processes the bundle, dispatches into the destination middleware via a synthetic contract call, and enqueues a response in native state.
6. The destination `ClprEndpointClient` delivers the response bundle back to the source ledger, which dispatches `handleMessageResponse(...)` and finally invokes the source application’s callback.

Detailed sequence (actual runtime steps):

1. Config exchange installs remote `ClprLedgerConfiguration` proofs on both ledgers.
2. Source app calls `SourceApplication.sendWithFailoverFromFirst(...)`.
3. Source middleware calls the queue system contract at `0x16e` using `enqueueMessage(...)`.
4. The system contract translates the EVM call into a native queue write (CLPR message store + queue metadata).
5. `ClprEndpointClient` notices outbound messages in native state, bundles them into `ClprMessageBundle`, and submits
   `clprProcessMessageBundle` transactions to the destination ledger over CLPR gRPC.
6. Destination `ClprProcessMessageBundleHandler`:
   - decodes the “request envelope”
   - dispatches a synthetic `ContractCall` to the destination middleware `handleMessage(...)`
   - captures the EVM return bytes
   - builds a `messageReply` payload and enqueues it back into native state for the origin ledger
7. `ClprEndpointClient` on destination ships that reply bundle back.
8. Source `ClprProcessMessageBundleHandler`:
   - decodes the “response envelope”
   - dispatches a synthetic `ContractCall` to the source middleware `handleMessageResponse(...)`
   - source middleware updates cached remote status and calls `SourceApplication.handleResponse(...)`.

Key “connector failover + funds depletion” scenario that is proven:

- Connector 1 always denies authorization.
- Connector 2 succeeds until the destination connector’s funds reach its safety threshold.
- After the source receives enough responses to learn destination connector 2’s balance report, the source middleware
  pre-rejects connector 2 before enqueue.
- Connector 3 is then used and succeeds (echo round-trip completes).

### 2.2 The Meaningful Difference From The Quarantined Version

Meaningful technical differences:

- The quarantined attempt relied on an off-chain “pump” step to manually forward `ClprMessageBundle` payloads between ledgers. That can validate some queue and envelope logic, but it does not validate the intended operational transport.
- The current implementation validates the intended operational transport end-to-end: endpoint configuration/bootstrap, bundle submission, inbound bundle handling, EVM dispatch, response creation, and response delivery are all performed by the node using `ClprEndpointClient` and native handlers.
- The quarantined attempt depended on test-only “seeding” behavior during queue metadata initialization (creating synthetic messages). The current implementation removes seeding and starts queues at the correct initial metadata values (for example `nextMessageId=1` and `lastAckedMessageId=0`).

Where the quarantine lives (for reference only):

- `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/README.md`

---

## 3) Minimal Necessary Changes In `hedera-smart-contracts`

This section enumerates the minimal contract, test, tooling, and documentation changes in this repository required to:

- integrate Solidity middleware with the `0x16e` queue system contract, and
- validate the two-ledger SOLO scenario using native messaging with no external pump.

### 3.0 Change Inventory (What Files Changed And Why)

This section lists the files changed in this repository and the rationale for each change.

Tracked (modified) files (these already existed on the branch, and we changed them):

- `.gitignore`
  - Purpose: Ignore generated evidence artifacts and run outputs.
  - Rationale: The two-ledger runner produces logs and evidence under `artifacts/`; these are not source-controlled inputs.
- `AGENTS.md`
  - Purpose: Capture guardrails and workflow constraints for long-running AI-assisted development.
  - Rationale: Prevents regression to the quarantined pump-based approach and keeps future changes aligned with “native messaging only”.
- `README.md` and `docs/clpr/README.md`
  - Purpose: Document the working integration and how to run it.
  - Rationale: Makes the current capability discoverable and repeatable without tribal knowledge.
- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
  - Purpose: Implements the CLPR middleware contract.
  - Rationale: Requires minimal additions for (a) route metadata used by the native queue/system contract and (b) safe authorization of callbacks invoked via native bundle processing.
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
  - Purpose: Defines middleware interface/ABI.
  - Rationale: Requires minimal interface additions for route configuration and callback allow-listing.
- `contracts/solidity/clpr/apps/SourceApplication.sol`
  - Purpose: Reference source application used in the acceptance scenario.
  - Rationale: Adds deterministic failover behavior (always try connectors 1→2→3) so the SOLO scenario is reproducible and assertable.
- `contracts/solidity/clpr/mocks/MockClprQueue.sol` and `contracts/solidity/clpr/mocks/MockClprConnector.sol`
  - Purpose: Test doubles used by unit/in-process tests.
  - Rationale: Adds minimal observability hooks needed to assert route header bytes and failover behavior in Hardhat/Foundry tests.
- `test/solidity/clpr/clprMiddleware.js`
  - Purpose: Hardhat tests for middleware behavior.
  - Rationale: Locks in route header and trusted callback caller behavior.
- `test/foundry/ClprMiddleware.t.sol`
  - Purpose: Foundry tests for middleware behavior.
  - Rationale: Locks in the same behaviors at the Solidity/unit level.
- `test/network/clpr/clprBridgeRelayedQueue.js`
  - Purpose: Two-network test harness (spec regression coverage).
  - Rationale: Updated to configure the middleware’s required route/callback settings.
- `contracts-abi/contracts/solidity/clpr/**.json`
  - Purpose: ABI artifacts consumed by tools and tests.
  - Rationale: Must remain consistent with Solidity source; otherwise tools/tests call incorrect selectors or decode incorrectly.

New (added) files and directories (these did not exist on the branch, and we created them):

- `scripts/clpr/native-messaging-solo/**`
  - Purpose: End-to-end runner and helper scripts for standing up two SOLO networks and executing the scenario.
  - Rationale: SOLO is the acceptance environment for this phase and must be repeatable.
- `tools/clpr/ClprConfigExchange.java`
  - Purpose: Implements the one-time CLPR configuration exchange (“kick”).
  - Rationale: Config exchange is the only allowed external bootstrap action; this tool performs it and nothing more.
- `docs/clpr/native-messaging-solo-integration-plan/**`
  - Purpose: Integration plan and issue descriptions.
  - Rationale: Keeps future work aligned with “native messaging, no pump”.
- `docs/clpr/NATIVE_MESSAGING_SOLO_PROGRESS.md`
  - Purpose: Short-form progress/status note.
  - Rationale: Quick orientation without requiring this full after-action report.
- `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md` and `docs/quarantine/**`
  - Purpose: Quarantine of the pump-based anti-pattern attempt.
  - Rationale: Preserves the history for reference while keeping active work free of the disallowed approach.

### 3.1 Solidity: Middleware

Files:

- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`

Why these changes are necessary:

- The `0x16e` system contract and native bundle handler require sufficient routing metadata to identify the remote ledger and destination middleware contract.
  - This routing metadata is encoded as a versioned route header in `ClprMessage.middlewareMessage.data`.
- Native bundle processing calls middleware callbacks using a synthetic contract call where `msg.sender` is the CLPR
  transaction payer (in SOLO, often the operator like `0.0.2`), not the queue system contract.
  - Without an explicit allow-list for this synthetic dispatch caller, middleware would reject legitimate inbound bundle callbacks.
  - We added `trustedCallbackCaller` as an allow-list mechanism to authorize these callbacks while preserving access control for other callers.

What changed (simple mapping):

- Added route header encoding in outbound messages:
  - Versioned header: `(version, remoteLedgerId, sourceMiddleware, destinationMiddleware)`
- Added `setConnectorRemoteMiddleware(...)`:
  - The middleware needs to know the destination middleware address so it can put it in the route header.
- Added `setTrustedCallbackCaller(...)` and `trustedCallbackCaller`:
  - Allows the identity used by synthetic dispatches to call `handleMessage(...)` and `handleMessageResponse(...)`.

### 3.2 Solidity: Source Application

File:

- `contracts/solidity/clpr/apps/SourceApplication.sol`

Why these changes are necessary:

- The SOLO scenario requires: “always try connector 1, then 2, then 3 for every message”.
  - The existing app kept a rolling preference index; that’s not the scenario.
  - We added `sendWithFailoverFromFirst(...)` to match the acceptance scenario exactly.
- In SOLO we do not rely on a mirror node to read events reliably.
  - We added minimal on-chain state (`lastReceivedAppMsgId`) so the scenario runner can poll deterministically for response completion.

### 3.3 Solidity: Mocks (Test-Only Observability)

Files:

- `contracts/solidity/clpr/mocks/MockClprQueue.sol`
- `contracts/solidity/clpr/mocks/MockClprConnector.sol`

Why these changes are necessary:

- These are mocks used only in in-process tests (Hardhat/Foundry).
- We added small getters to prove route headers exist and are shaped correctly.
- This does not change the production intended connector behavior; it just lets tests “peek” at bytes.

### 3.4 Tests and ABI Outputs

Files:

- `test/solidity/clpr/clprMiddleware.js`
- `test/foundry/ClprMiddleware.t.sol`
- `test/network/clpr/clprBridgeRelayedQueue.js`
- `contracts-abi/contracts/solidity/clpr/**.json` (updated compiled outputs)

Why these changes are necessary:

- Tests were updated to configure:
  - remote middleware address (for route header creation)
  - trusted callback caller (for native callback path)
- Tests now assert:
  - connector failover works
  - destination out-of-funds behavior is enforced
  - route headers are present in request and response flows

### 3.5 SOLO Runner and Tooling (The Repeatable “How To Prove It Works”)

Files:

- `scripts/clpr/native-messaging-solo/run-e2e.sh`
- `scripts/clpr/native-messaging-solo/run-scenario.js`
- `scripts/clpr/native-messaging-solo/two-network-up.sh`
- `scripts/clpr/native-messaging-solo/two-network-down.sh`
- `scripts/clpr/native-messaging-solo/two-network-status.sh`
- `scripts/clpr/native-messaging-solo/config/application-*.properties`
- `tools/clpr/ClprConfigExchange.java`

Why these are necessary:

- SOLO is the acceptance target for this phase.
- We need one repeatable driver to:
  - create two ledgers,
  - apply a custom consensus-node build,
  - do the one-time kick,
  - deploy contracts,
  - run the scenario,
  - capture logs,
  - tear down cleanly.

Where the “how to apply a local build to SOLO containers” knowledge came from:

- The quarantined archive recorded the working approach (`solo consensus node setup --local-build-path ...`).
- The corrected integration keeps that operational technique but removes the pump.

### 3.6 Docs / Guardrails / Quarantine Pointer

Files:

- `docs/clpr/native-messaging-solo-integration-plan/**`
- `docs/clpr/NATIVE_MESSAGING_SOLO_PROGRESS.md`
- `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
- `docs/quarantine/**`
- `AGENTS.md`
- `docs/clpr/README.md`
- `README.md`
- `.gitignore`

Why these changes are necessary:

- This was a long-running integration with a known failure mode (accidentally building a pump).
- The docs make the correct path discoverable and the forbidden path obvious.

---

## 4) Minimal Necessary Changes In `../hiero-consensus-node`

This section enumerates the minimal set of consensus-node changes required to:

- expose a CLPR queue system contract at `0x16e` that adapts EVM queue calls into native CLPR queue/state writes,
- process inbound `ClprMessageBundle` payloads by dispatching into EVM middleware and generating responses, and
- make the existing native messaging layer (`ClprEndpointClient`) usable in a two-ledger SOLO environment.

### 4.0 Change Inventory (What Files Changed And Why)

This subsection lists the files added/modified in consensus-node and the rationale for each change.

New (added) files and directories (these did not exist before, and they are the core of the solution):

- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/ClprQueueSystemContract.java`
  - Purpose: Implements the CLPR queue system contract at `0x16e`.
  - Rationale: Enables Solidity to enqueue messages into native CLPR stores via a controlled system-contract adapter.
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ClprQueueTranslatorsModule.java`
  - Purpose: Registers ABI translators for `0x16e`.
  - Rationale: Without translators, calls to `0x16e` are not recognized by the EVM system-contract dispatch layer.
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/**`
  - Purpose: Translator/call implementations for queue methods (enqueue request/response).
  - Rationale: Keeps system contract logic modular and unit-testable.
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java`
  - Purpose: Shared native queue mutation helper.
  - Rationale: Both the system contract and the bundle handler must enqueue messages consistently and safely.
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/ClprQueueSystemContractTest.java`
  - Purpose: Unit tests for the queue system contract.
  - Rationale: Prevents regressions in system contract behavior as plumbing evolves.
- `hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/clpr/**`
  - Purpose: Unit tests for translators/call factories.
  - Rationale: Locks in ABI mapping, decoding, and revert behavior.
- `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/ClprQueueOperationsTest.java`
  - Purpose: Unit tests for shared queue mutation helper.
  - Rationale: Queue mutation is foundational to end-to-end behavior; tests provide regression protection.

Modified (existing) files (these existed before; we changed them only to “plug in” the new helper and make SOLO work):

- `hedera-node/hedera-config/src/main/java/com/hedera/node/config/data/ContractsConfig.java`
  - Purpose: Adds config gating for the CLPR queue system contract.
  - Rationale: System contracts must be feature-gated for safe rollout.
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ProcessorModule.java`
  - Purpose: Registers `0x16e` into the EVM system-contract processor wiring.
  - Rationale: Without wiring, the system contract exists in source but is not reachable at runtime.
- `hedera-node/hedera-app/src/main/java/com/hedera/node/app/store/WritableStoreFactory.java`
  - Purpose: Allows the contract execution scope to obtain writable CLPR stores for enqueue operations.
  - Rationale: The system contract must be able to mutate CLPR queue/message state during EVM execution.
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HederaNativeOperations.java`
  - Purpose: Exposes enqueue operations on the native operations interface.
  - Rationale: System contracts mutate state through native operations, not by directly touching stores.
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HandleHederaNativeOperations.java`
  - Purpose: Implements the new native enqueue operations.
  - Rationale: Provides the concrete behavior used by system contract calls during handle workflows.
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`
  - Purpose: Implements inbound bundle processing and EVM dispatch for request/response flows.
  - Rationale: Without this, bundles can be received but requests are not executed and responses are not generated.
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java`
  - Purpose: Makes the existing native transport usable in SOLO (payer selection in dev-mode and additional diagnostics).
  - Rationale: SOLO often has different funding assumptions; diagnostics are required to debug endpoint and submission failures.
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/client/ClprClientImpl.java`
  - Purpose: Supports dialing CLPR endpoints by domain name.
  - Rationale: SOLO advertises endpoints as in-cluster DNS names, not always as IPv4 bytes.
- `hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/handle/record/SystemTransactions.java`
  - Purpose: Improves how the node derives service endpoints in SOLO.
  - Rationale: If the endpoint configuration is missing or non-routable, the peer ledger cannot submit CLPR transactions.
- `hedera-node/hedera-app-spi/src/main/java/com/hedera/node/app/spi/workflows/record/StreamBuilder.java`
  - Purpose: Adds a clean API to access EVM return bytes from synthetic contract calls.
  - Rationale: Inbound request processing must read middleware return bytes to build response envelopes deterministically.
- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`
  - Purpose: Removes test-seeding behavior during queue metadata initialization.
  - Rationale: Production correctness: queue metadata initialization should not create synthetic messages.
- `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
  - Purpose: Updates test expectations to match corrected queue metadata semantics.
  - Rationale: Tests should not rely on synthetic message seeding.
- Various CLPR unit tests under `hedera-node/hiero-clpr-interledger-service-impl/src/test/java/...`
  - Purpose: Updates/extends unit tests for bundle flow and metadata behavior.
  - Rationale: Locks in the fixes and prevents regressions.

### 4.1 Add The CLPR Queue System Contract At `0x16e`

Rationale:

- EVM contracts cannot directly mutate native CLPR queue/message state.
- A system contract provides an explicit, controlled adapter that is executed within the node’s contract service and can write to the allow-listed CLPR stores during EVM execution.

Key files:

- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/ClprQueueSystemContract.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ClprQueueTranslatorsModule.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/**`

Behavior:

- When enabled, `0x16e` accepts EVM calls for `enqueueMessage(...)` and `enqueueMessageResponse(...)`.
- It validates basic inputs, wraps calldata into the envelope the CLPR bundle handler expects, and writes to the native stores.
- When disabled by config, it reverts with a typed reason (`CLPR_QUEUE_DISABLED`).

Config flag added:

- `../hiero-consensus-node/hedera-node/hedera-config/src/main/java/com/hedera/node/config/data/ContractsConfig.java`
  - `systemContract.clprQueue.enabled`

Wiring added:

- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ProcessorModule.java`
  - registers the system contract and its translators into the EVM processor map.

### 4.2 Let The System Contract Write To CLPR Stores (Minimal, Allow-Listed Cross-Service Writable Access)

Rationale:

- CLPR queue/message state is owned by the CLPR service, while system contract execution occurs under the contract service.
- The `0x16e` system contract requires controlled writable access to a small set of CLPR stores during handle workflows to perform enqueue operations.
- The implementation provides an explicit allow-list of writable CLPR stores rather than broad cross-service write access.

Key files:

- `../hiero-consensus-node/hedera-node/hedera-app/src/main/java/com/hedera/node/app/store/WritableStoreFactory.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HederaNativeOperations.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/scope/HandleHederaNativeOperations.java`

What we avoided:

- We did not make “all stores writable from anywhere”.
- We only allow the specific CLPR queue stores required for enqueue operations.

### 4.3 Add A Shared Native Queue Mutation Helper (`ClprQueueOperations`)

Rationale:

- Multiple components (system contract and bundle handler) must enqueue messages and update queue metadata consistently.
- Centralizing queue mutation logic reduces duplication and prevents subtle divergence in metadata updates and message persistence.

Key file:

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java`

### 4.4 Make Bundle Processing Call EVM Middleware (And Enqueue Replies)

Rationale:

- On inbound request bundles, the destination ledger must execute the destination middleware `handleMessage(...)` to produce the response payload required by the protocol.
- The node must then persist and queue the response so it can be delivered back to the origin ledger by the native transport.

Key file:

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`

Key behavior changes vs baseline:

- It now understands a request “envelope” and a response “envelope”.
- On inbound requests:
  - decode envelope
  - dispatch a synthetic `ContractCall` to the destination middleware `handleMessage(...)`
  - read EVM return bytes
  - build a `messageReply` and enqueue it under the origin ledger id
- On inbound responses:
  - decode envelope
  - dispatch `handleMessageResponse(...)` on the target (source) middleware

### 4.5 Capture EVM Return Bytes Without Reflection (Production-Quality)

Rationale:

- The bundle handler must read EVM return bytes from synthetic middleware contract calls to build deterministic response envelopes.
- A stable API (`getEvmCallResult()`) is preferable to reflection-based access (which is brittle across refactors and build changes).

Key file:

- `../hiero-consensus-node/hedera-node/hedera-app-spi/src/main/java/com/hedera/node/app/spi/workflows/record/StreamBuilder.java`

### 4.6 SOLO Bootstrap Fixes (Endpoints + LedgerId Shape)

Rationale:

- In SOLO, node endpoint fields may be missing or shaped differently than in integration-test environments.
- A usable endpoint must be present in `ClprLedgerConfiguration`; otherwise the peer ledger cannot submit CLPR transactions.
- The route header uses `bytes32` ledger IDs, so dev-mode behavior must provide a stable 32-byte ledger identifier.

Key file:

- `../hiero-consensus-node/hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/handle/record/SystemTransactions.java`

Key behavior:

- If node service endpoints are missing, derive an endpoint from roster gossip info and the gRPC port.
- In dev mode, normalize ledger id bytes to 32 bytes (SHA-256) when needed.

### 4.7 Make The Endpoint Client Usable In SOLO (Payer + Domain Name Endpoints)

Rationale:

- `ClprEndpointClient` submits HAPI transactions and must select a payer that is funded in SOLO.
- SOLO advertises endpoints by DNS name; the client must support dialing `ServiceEndpoint.domainName` and not only IPv4 bytes.

Key files:

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/client/ClprClientImpl.java`

Key behavior changes:

- In dev-mode only, `ClprEndpointClient` uses treasury as payer.
- `ClprClientImpl` resolves `ServiceEndpoint.domainName` when present.

### 4.8 Remove Old “Test Seeding” Behavior (Production Correctness)

Rationale:

- Queue metadata initialization should not create synthetic messages.
- Tests and consumers should observe the correct initial queue state (`nextMessageId=1`, empty message stores).

Key file:

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`

Also requires:

- Updating `ClprMessagesSuite` expected queue metadata:
  - `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`

### 4.9 Tests Added/Updated To Lock In Behavior

Rationale:

- The system contract adapter and request/response bundle processing introduce new logic paths with non-trivial state semantics.
- Tests provide regression protection as CLPR code evolves.

Examples:

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/ClprProcessMessageBundleHandlerTest.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/.../ClprQueueSystemContractTest.java`

---

## 5) Fundamental Behavior Changes vs The Previously Committed Baseline

Summary: The previously committed baseline did not have an EVM-to-native queue adapter and did not execute middleware on inbound bundles to generate responses. This work completes those missing steps and wires them end-to-end for SOLO.

Fundamental changes in the node:

- EVM can now enqueue into the native CLPR queue via `0x16e`.
- Inbound bundle processing can now call the destination middleware and create real responses to ship back.
- The endpoint client can now operate in SOLO (domain names + dev-mode funded payer).
- Bootstrap now produces usable, routable CLPR endpoints in SOLO.
- Queue metadata init no longer manufactures fake messages.

Fundamental changes in the Solidity layer:

- Middleware now attaches a route header so native components can route callbacks correctly.
- Middleware now supports a safe “trusted callback caller” for the synthetic dispatch path.
- The source app now supports a deterministic “always start from connector 1” behavior and exposes minimal response state
  so a SOLO test driver can validate round-trips without a mirror node.

---

## 6) Tutorial: How To Run The Two-SOLO Test Scenario (Command Line, Explained)

### 6.1 One-Command Run (Recommended)

From `hedera-smart-contracts` repo root:

```bash
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

This is the end-to-end driver: it optionally builds consensus-node artifacts, deploys two SOLO networks, performs the one-time configuration exchange, deploys contracts, executes the scenario, collects evidence, and tears down (unless `--keep` is provided).

Useful options:

```bash
# Skip rebuilding the consensus-node artifacts (faster if you didn’t change ../hiero-consensus-node)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build

# Keep the clusters running after the run (useful for manual inspection/debugging)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --keep

# Don’t destroy/recreate the deployments (assume they already exist and are healthy)
bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-redeploy
```

### 6.2 What The Top-Level Script Does (Major Chunks)

File: `scripts/clpr/native-messaging-solo/run-e2e.sh`

Chunk A: Build the consensus node artifacts (optional)

- Command (inside `../hiero-consensus-node`):
  - `./gradlew :app:assemble`
- What it does:
  - Builds the node and populates `../hiero-consensus-node/hedera-node/data/`
  - SOLO later copies this into the running containers so they run “your code”, not the default release bits.

Chunk B: Stand up two SOLO deployments (source + destination)

- Script:
  - `scripts/clpr/native-messaging-solo/two-network-up.sh --force`
- What it does:
  - Creates two deployment configs
  - Deploys the charts into two namespaces
  - Applies the local build via `solo consensus node setup --local-build-path ...`
  - Starts both nodes
  - Validates health via `two-network-status.sh`

Chunk C: Port-forward gRPC so local tools can talk to both ledgers

- Commands:
  - `kubectl -n <ns> port-forward pod/network-node1-0 <localPort>:50211`
- What it does:
  - Makes `127.0.0.1:<localPort>` behave like the node’s CLPR gRPC endpoint.

Chunk D: Config exchange “kick”

- Compile tool:
  - `javac -cp "$CN_LOCAL_BUILD_PATH/lib/*:$CN_LOCAL_BUILD_PATH/apps/*" tools/clpr/ClprConfigExchange.java`
- Run tool:
  - `java ... tools.clpr.ClprConfigExchange --a <src> --b <dst> --out <env>`
- What it does:
  - Fetches each ledger’s local config proof
  - Installs it on the other ledger
  - Waits for queue metadata init
  - Writes an env file with both ledger IDs for the scenario runner

Chunk E: Run the scenario (deploy contracts + drive messages)

- Command:
  - `node scripts/clpr/native-messaging-solo/run-scenario.js`
- What it does:
  - Deploys middleware to both ledgers using queue `0x16e`
  - Deploys connectors and funds destination connectors
  - Deploys apps
  - Sends messages and waits for replies
  - Asserts the connector 1/2/3 story and prints `Scenario passed`

Chunk F: Evidence collection + teardown

- Evidence:
  - Captures k8s pod listings and key logs into `artifacts/clpr-native-messaging-solo/<runId>/`
- Teardown:
  - Stops nodes and destroys both deployments unless `--keep` was used

### 6.3 Manual Step-By-Step (If You Want To Run Pieces Yourself)

1) Build the consensus node artifacts (so SOLO can run your code):

```bash
# Go to the consensus node repo (this builds the node binaries SOLO will run)
cd ../hiero-consensus-node

# Build the app and populate hedera-node/data/* (SOLO copies these files into the node containers)
./gradlew :app:assemble

# Return to this repo (the scripts and contracts live here)
cd ../hedera-smart-contracts
```

2) Deploy both SOLO networks:

```bash
# Create two namespaces (source + destination) and deploy the charts.
# Also applies the local-build-path so the running containers include your consensus-node code.
bash scripts/clpr/native-messaging-solo/two-network-up.sh --force
```

3) Port-forward gRPC to localhost (so tools on your laptop can talk to each ledger):

```bash
# Namespaces created by two-network-up.sh
SRC_NS=solo-clpr-msg-src
DST_NS=solo-clpr-msg-dst

# Forward each ledger’s gRPC port 50211 to your laptop.
# This makes 127.0.0.1:51211 behave like "source ledger gRPC" and 127.0.0.1:52211 behave like "destination ledger gRPC".
kubectl -n "$SRC_NS" port-forward --address 127.0.0.1 pod/network-node1-0 51211:50211
kubectl -n "$DST_NS" port-forward --address 127.0.0.1 pod/network-node1-0 52211:50211
```

4) Compile and run the config exchange “kick”:

```bash
# Compile using consensus-node jars on the classpath
CN_LOCAL_BUILD_PATH="../hiero-consensus-node/hedera-node/data"
CLASSPATH_CN="$CN_LOCAL_BUILD_PATH/lib/*:$CN_LOCAL_BUILD_PATH/apps/*"

# Create a temporary directory for compiled Java .class files
mkdir -p /tmp/clpr-exchange-classes

# Compile the config exchange tool against the consensus-node jars
javac -cp "$CLASSPATH_CN" -d /tmp/clpr-exchange-classes tools/clpr/ClprConfigExchange.java

# Run (writes key=value env output)
# This does the only allowed external kick:
# - fetch each ledger's ClprLedgerConfiguration proof
# - install it on the other ledger
# After this, the built-in node messaging layer can ship bundles automatically.
java -cp "/tmp/clpr-exchange-classes:$CLASSPATH_CN" tools.clpr.ClprConfigExchange \
  --a "127.0.0.1:51211" \
  --b "127.0.0.1:52211" \
  --out /tmp/clpr-exchange.env
```

5) Run the scenario (deploy contracts + drive messages):

```bash
# Auto-export the variables defined in the env file (so node can read them)
set -a

# Load the output of the config exchange tool (ledger IDs, etc)
source /tmp/clpr-exchange.env

# Stop auto-exporting new shell variables
set +a

# Tell the scenario runner where each ledger is, and what their ledger IDs are.
export SRC_GRPC_ENDPOINT="127.0.0.1:51211"
export DST_GRPC_ENDPOINT="127.0.0.1:52211"
export SRC_LEDGER_ID_HEX="$CLPR_A_LEDGER_ID_HEX"
export DST_LEDGER_ID_HEX="$CLPR_B_LEDGER_ID_HEX"

# Deploy middleware/apps/connectors and run the connector failover + funds depletion story.
node scripts/clpr/native-messaging-solo/run-scenario.js
```

6) Tear down the SOLO deployments:

```bash
# Destroy both namespaces and clean up the deployments.
bash scripts/clpr/native-messaging-solo/two-network-down.sh
```
