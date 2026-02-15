# Critical Review: Native CLPR Queue Integration vs Spec + Messaging Layer Usage

Date: 2026-02-13

This document is a critical review of two questions:

1. Whether the CLPR middleware behavior implemented in `hedera-smart-contracts` (and exercised by the new two-ledger Solo native-queue smoke) satisfies the CLPR middleware requirements documented in PR `hiero-ledger/hiero-consensus-node#23333`.
2. Whether this development used the existing native messaging layer in `../hiero-consensus-node` as demonstrated by the `ClprMessagesSuite` and implemented in the commit range after `1e200bf1b9` ("20111 - CLPR Prototype", Edward Wertz, 2026-02-05).

The review is intentionally conservative: if a requirement cannot be shown to be met from code + tests in this workspace, it is treated as "not demonstrated" (and therefore effectively not met for the purposes of this review).

Relevant artifacts and code references in this workspace:

- Two-ledger Solo smoke runner: `scripts/clpr/native-queue/run-two-ledger-smoke.sh`
- External "bootstrap" + "pump" tools used by that smoke runner (consensus repo): `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueueBootstrapMain.java` and `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueuePumpMain.java`
- Native endpoint client inside the node that performs automatic push/pull cycles: `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java`
- "Demonstration" suite referenced by the user: `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
- Middleware prototype: `contracts/solidity/clpr/middleware/ClprMiddleware.sol`

Source-of-truth requirements documents (PR branch):

- Middleware APIs and semantics: `middleware-apis-and-semantics.md` (branch `23281-clpr-initial-requirements-documentation`)
- Messaging formats: `messaging-message-formats.md`
- Messaging queue + bundles: `messaging-queue-and-bundles.md`
- Applications interop contract: `applications-interop-contract.md`
- Connectors economics and behavior: `connectors-economics-and-behavior.md`
- Traceability: `traceability.md`

These can be fetched as raw files under the PR branch, for example:

```text
https://raw.githubusercontent.com/hiero-ledger/hiero-consensus-node/23281-clpr-initial-requirements-documentation/hedera-node/docs/clpr/requirements/middleware-apis-and-semantics.md
```

## 1) How This Development Does Not Meet The PR #23333 Requirements

This section focuses on non-compliance or "not demonstrated" compliance with the CLPR requirements in PR #23333.

Important framing: the work tracked by issues `ISSUE-0001 .. ISSUE-0014` in this repo was explicitly about integrating the EVM-side prototype with the native queue and proving a two-ledger round-trip. It was not an explicit full-spec conformance effort. Because the user is asking for spec conformance, this section will look "harsh": many requirements are simply outside the implemented scope.

### 1.0 The New Solo End-to-End Smoke Does Not Exercise The Middleware Prototype

The new two-ledger Solo native-queue smoke is not a middleware conformance test.

What it deploys and tests:

- It deploys `ClprMiddlewareHarness` from the consensus repo test resources, not `contracts/solidity/clpr/middleware/ClprMiddleware.sol`.
- The harness directly calls the queue system contract at `0x16E` via `enqueueMessage(...)` and exposes two callback entrypoints `handleMessage(...)` and `handleMessageResponse(...)` that only record bytes and IDs.

Evidence:

- Deployment script uses consensus repo harness artifacts by default (`scripts/clpr/native-queue/deploy-two-ledger-contracts.js:82` and `scripts/clpr/native-queue/deploy-two-ledger-contracts.js:85`).
- Harness queue integration is hard-coded (`../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/ClprMiddlewareHarness/ClprMiddlewareHarness.sol:78` and `:133`).
- Harness callback logic is intentionally minimal and does not implement connector/middleware semantics (`ClprMiddlewareHarness.sol:136` and `:156`).

Implication:

- Even if `contracts/solidity/clpr/middleware/ClprMiddleware.sol` were perfectly spec-compliant, this particular end-to-end smoke would not demonstrate it.
- Therefore the development as delivered cannot claim spec compliance based on the new end-to-end test. At best, it demonstrates a queue adapter + message bundle processing round-trip for a harness contract.

### 1.1 Requirement Scope Mismatch: Prototype Middleware vs Protocol Middleware

The PR requirements describe a middleware that is part of a protocol-level workflow with connector identity, authentication, and economics.

The Solidity code in this repo is described (by its own comments and repo guidance) as a prototype that evolves in place. For example, connector registration is modeled as connector self-registration, not as a protocol transaction that creates or updates a connector identity on-ledger.

Consequence:

- Requirements around on-ledger connector creation, governance, and identity proofs are not implemented or demonstrated by this development. This is a hard non-compliance gap, not a missing test.

Concrete example:

- The middleware `registerConnector(...)` API in `contracts/solidity/clpr/middleware/ClprMiddleware.sol:221` accepts opaque IDs and an admin address, and trusts that `msg.sender` is the connector. The requirements in `connectors-economics-and-behavior.md` describe a richer, protocol-driven connector lifecycle and mutual authentication story.

### 1.2 Connector Authentication and Identity Proof Requirements Are Not Met

The requirements in `middleware-apis-and-semantics.md` include explicit mutual authentication (for example REQ-MW-007, REQ-MW-008) based on connector identity material and signatures over configuration.

What the current prototype does instead:

- It uses simple pairing checks like `destinationReg.expectedRemoteConnectorId != message.applicationMessage.connectorId` to decide if a connector is paired (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:423`).
- It does not verify that the remote connector ID is derived from a signature over a configuration, nor does it check any cryptographic proof chain for connector identity.
- It does not include a protocol transaction flow for "create connector" and therefore cannot satisfy requirements that depend on that transaction existing and being validated by consensus.

Impact:

- A connector can claim any `connectorId`/`expectedRemoteConnectorId` pairing as long as both middleware instances are configured consistently. That is not the same as mutual authentication against a proof derived from ledger configuration.

### 1.3 Native Value Forwarding Requirements Are Not Met

Middleware requirements include forwarding native value to the destination application (for example REQ-MW-010 in `middleware-apis-and-semantics.md`).

What exists today:

- The middleware `send(...)` function is not `payable` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:282`), so it cannot accept or forward EVM native value.
- The destination application call in `handleMessage(...)` is a plain interface call, not a value-forwarding call (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:478`).

Impact:

- Any requirement that depends on moving value as part of the cross-ledger flow is not satisfied in this implementation and not covered by the new smoke test.

### 1.4 Message Size Limits and Defenses Are Not Implemented

The requirements include enforcing maximum message size limits (for example REQ-MW-012).

What exists today:

- No max message size enforcement for `applicationMessage.data`.
- No max message size enforcement for `connectorMessage.data`.
- No max message size enforcement for `middlewareMessage.data`.
- No max message size enforcement for response payload equivalents.
- The new two-ledger smoke uses a small payload (`CLPR_SMOKE_PAYLOAD` default is `solo-native-queue-smoke` in `scripts/clpr/native-queue/run-two-ledger-smoke.sh:30`), so it does not demonstrate size enforcement either.

Impact:

- Size-related requirements are not met and the test does not protect against future regressions where large payloads could create non-deterministic failures or DoS surfaces.

### 1.5 "Queue-Only" Callback Authorization Is Weakened (Spec Risk)

Messaging semantics typically rely on a clear authority boundary: only the messaging layer (queue) can call middleware callback entrypoints.

What this prototype implements:

- It enforces `onlyQueueOrTrustedCallback()` on `handleMessage(...)` and `handleMessageResponse(...)` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:209`, applied at `contracts/solidity/clpr/middleware/ClprMiddleware.sol:407` and `contracts/solidity/clpr/middleware/ClprMiddleware.sol:518`).
- This allows an owner-configurable `trustedCallbackCaller` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:103`, setter at `contracts/solidity/clpr/middleware/ClprMiddleware.sol:276`).

Why this is a spec compliance risk:

- If the requirements assume "only the queue contract can deliver callbacks", this override is not compliant unless the spec explicitly allows alternate callback dispatch identities.
- Even if it is disabled by default, it is a foot-gun: a misconfiguration could allow unauthorized callback injection.

This might be acceptable as a prototype escape hatch, but it should be treated as non-compliant unless the requirements explicitly allow it.

### 1.6 Middleware Metadata "Complete Context" Requirements Are Only Partially Met

The requirements include passing "complete message context" to the source connector before enqueue (REQ-MW-003).

What exists today:

- The source connector sees a `draft` in `IClprConnector.authorize(draft)` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:347`).
- The middleware message with route header and balance report is built separately in `_buildSourceMiddlewareMessage(...)` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:568`) and then included in the final outbound `ClprMessage` (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:364`).
- The connector does not receive the final `ClprMessage` in the authorize call, only the draft.

If the requirements interpret "complete context" as including the final middleware metadata, this implementation does not meet it. If the requirements interpret "complete context" as app payload plus enough connector/middleware context to authorize, this might be acceptable but is not explicitly demonstrated.

### 1.7 Consensus Node Messaging Requirements: Dev Mode and Proof Semantics Are Not Fully Demonstrated

The requirements set in PR #23333 includes state proofs and traceability requirements (`messaging-state-proofs.md`, `traceability.md`).

The end-to-end smoke in this repo runs both ledgers with `clpr.devModeEnabled=true` (`scripts/clpr/native-queue/config/application-src.properties:4` and `scripts/clpr/native-queue/config/application-dst.properties:4`).

From `../hiero-consensus-node/hedera-node/docs/design/clpr-service-design.md`, dev mode includes explicit shortcuts:

- signature bypasses
- fabricated state proofs
- relaxed throttles

Impact:

- Even if the messaging layer code paths are correct, this development does not demonstrate production-grade proof validation or signature semantics.
- Any requirement that assumes real cryptographic state proof verification is not met by the demonstrated test run.

### 1.8 Connector Economics Requirements Are Not Fully Implemented

The connectors requirements document (`connectors-economics-and-behavior.md`) includes requirements around:

- connector funding accounts and fee payment behavior
- charge bounds and unit normalization
- billing and reimbursement rules

The Solidity prototype implements a simplified version of connector economics, mostly for "out of funds" and min/max charge gating:

- It prefilters sends based on cached remote connector balance reports (`contracts/solidity/clpr/middleware/ClprMiddleware.sol:316` onward).
- It charges a hard-coded destination-side min charge via the connector callback and uses a simplistic token reimbursement model in mock connectors.

What is missing relative to the requirements:

- Any on-ledger accounting for who pays the HAPI fees for cross-ledger messaging transactions in production.
- Any end-to-end validation of "who pays for what" in the two-ledger smoke. The smoke uses operator keys that pay for all HAPI transactions directly (deploy, execute, and pump).

Net: connector economics requirements are only partially modeled for demo and are not demonstrated as conformant.

## 2) Was The Native Messaging Layer From `ClprMessagesSuite` Used?

This section answers the user's specific concern about "pumping" vs using the native messaging layer that already has a send/receive mechanism.

### 2.1 What `ClprMessagesSuite` Demonstrates

`ClprMessagesSuite` is a multi-network HAPI test that brings up two ledgers:

- a "private" ledger with `clpr.publicizeNetworkAddresses=false`
- a "public" ledger with `clpr.publicizeNetworkAddresses=true`

File: `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`

Observations:

- The suite triggers configuration exchange by submitting the public config to the private ledger (`ClprMessagesSuite.java:88`).
- It then waits until each ledger has queue metadata for the other (`ClprMessagesSuite.java:104` and `ClprMessagesSuite.java:110`).
- It does not manually "pump" bundles with `getMessages(...)` and `clprProcessMessageBundle(...)` in this suite.

So where does "send/receive" happen?

- In the consensus node implementation, the native in-node mechanism for exchanging queue metadata and message bundles is `ClprEndpointClient`.
- `ClprEndpointClient` schedules periodic cycles (`ClprEndpointClient.runOnce()` and `scheduleRoutineActivity()` in `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java:95` and `:156`).
- It has an explicit push/pull implementation for queue messages (`pushPullQueueMessages(...)` in `ClprEndpointClient.java:464`).
- Push path: `remoteClient.submitProcessMessageBundleTxn(...)` (`ClprEndpointClient.java:539`).
- Pull path: `remoteClient.getMessages(...)` and then `localClient.submitProcessMessageBundleTxn(...)` (`ClprEndpointClient.java:548` and `:572`).

Critical point:

- The "native messaging layer" in the node does include an automated mechanism to send and receive message bundles (the endpoint client) in dev/prototype builds.

Related note:

- A different suite, `ClprSuite`, *does* include explicit helper ops that fetch bundles with `getMessages(...)` and submit `clprProcessMessageBundle` transactions (`../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprSuite.java:545` and `:558`). So "manual pumping" is also an established pattern in the consensus repo tests, just not the one demonstrated by `ClprMessagesSuite`.

### 2.2 What This Development Actually Uses In The Two-Ledger Solo Smoke

The two-ledger Solo native-queue smoke runner in this repo is:

- `scripts/clpr/native-queue/run-two-ledger-smoke.sh`

The smoke runner does not rely on the in-node `ClprEndpointClient` to exchange bundles.

Instead it explicitly runs two external tools from `../hiero-consensus-node`:

- Bootstrap tool to exchange configurations and initialize queue metadata. Invoked by Gradle in `scripts/clpr/native-queue/run-two-ledger-smoke.sh:273`. Tool main is `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueueBootstrapMain.java`.
- Pump tool to exchange message bundles between ledgers. Invoked by Gradle in `scripts/clpr/native-queue/run-two-ledger-smoke.sh:323`. Tool main is `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueuePumpMain.java`.

The pump tool is the actual "medium" of cross-ledger message passing for the smoke run:

- It polls `getMessages(...)` on one ledger and submits the returned bundle to the other ledger via `clprProcessMessageBundle`.
- It then does the reverse for responses.

Conclusion:

- If "used the native messaging layer" means "used the on-ledger queue state + bundle processing handlers", then yes: the smoke relies on native `getMessages` and `clprProcessMessageBundle` semantics implemented by the node.
- If "used the native messaging layer demonstrated in `ClprMessagesSuite`" means "relied on the in-node `ClprEndpointClient` automatic send/receive mechanism", then no: the smoke does not use that mechanism and therefore does not validate it.

### 2.3 Why The Difference Matters

Relying on external pumping changes what you are validating:

- You validate message enqueue correctness (via the EVM system contract adapter).
- You validate the message bundle processing handler correctness (including EVM callback dispatch).
- You validate queue metadata update semantics.
- You do not validate that the in-node endpoint client can connect to remote endpoints in the specific environment (Solo, Kubernetes namespaces).
- You do not validate that the endpoint client correctly chooses endpoints, rotates cursors, retries, and drains queues without an external orchestrator.

So the user's concern is legitimate: the end-to-end test as implemented proves the queue and handler behavior, but it does not prove the native background "shipping" behavior that exists in the node prototype.

### 2.4 Is Pumping "Wrong" Per The Requirements?

The requirements in PR #23333 define:

- message formats (what a request/response is),
- queue and bundle semantics (how messages are stored, bundled, and acknowledged),
- API contracts between messaging, middleware, connectors, and applications.

They do not clearly mandate that the consensus node itself must run an automated cross-ledger transport loop inside the node process. In other words, the "native messaging layer" can be interpreted as:

- the on-ledger message stores and transaction/query handlers (`getMessages`, `processMessageBundle`, queue metadata updates), plus
- an external actor (a connector) that uses those APIs to ferry bundles across ledgers.

Under that interpretation, an explicit pump step is not "new messaging infrastructure"; it is simply an explicit connector emulator in a local test.

However, the checked-out consensus node branch also includes `ClprEndpointClient`, which *does* implement an automated push/pull loop in the node process (`ClprEndpointClient.java:464`). If the development goal was "use the same in-node mechanism that `ClprMessagesSuite` implicitly relies on", then pumping is the wrong validation mechanism, because it bypasses the in-node transport.

## 3) If The In-Node Messaging Mechanism Was Not Used: Did Issues 1-14 Drift?

This section assumes the stricter interpretation of the user's intent: "Do not build new messaging infrastructure; integrate and exercise the same native mechanism used by `ClprMessagesSuite` (the in-node endpoint client)."

Under that interpretation, the answer is:

- The work used the native queue and handlers, but it did not use the endpoint client's automatic transport mechanism.
- The issue plan included building external bootstrap/pump tooling and a smoke that depends on it, which can be viewed as a drift from the goal of validating the in-node mechanism end-to-end.

### 3.1 Where The Plan May Have Been Underspecified

The issues `ISSUE-0001 .. ISSUE-0014` were structured around producing a deterministic, stage-driven two-ledger smoke:

- Bootstrap stage
- Deploy stage
- Send stage
- Pump stage
- Assert stage

If the intended acceptance criterion was "no external pump; the node's own endpoint client must ship bundles", that criterion was not written as an explicit non-negotiable constraint early in the plan.

In long-running AI-led development, ambiguous requirements like "use the native messaging layer" tend to be interpreted as "use the native APIs and handlers" rather than "exercise the same background actor that the node uses in its own dev-mode plumbing."

### 3.2 Why An AI Agent Might Choose Pumping Anyway

Even if the endpoint client exists, an external pump is tempting because:

- It makes the end-to-end test deterministic and step-driven (no background polling windows).
- It avoids in-cluster reachability problems between namespaces (Kubernetes networking, service endpoint IPs, advertised addresses).
- It narrows the surface area: failures are easier to attribute to "queue state", "bundle handler", or "EVM callback dispatch" rather than to network-level connectivity.

This is a reasonable engineering tradeoff for "prove the queue adapter works" but it does not align with "prove the node ships messages itself."

### 3.3 What Would Have Been More Grounded If Endpoint Client Coverage Was The Goal

If the goal was to validate the native in-node transport, the first issues should have been:

- Run `ClprMessagesSuite` (or a new multi-network suite) against Solo environments that match production topology and confirm endpoint connectivity.
- Confirm what `ClprLedgerConfiguration.endpoints` advertise in Solo and whether those endpoints are routable from the other ledger's pods.
- Fix endpoint advertisement or endpoint selection so the endpoint client can actually connect across namespaces.
- Only then integrate the EVM system contract enqueue path and add the EVM harness.

In other words: start by proving the "medium" is correct, then integrate the new producer (EVM enqueue) and consumer (EVM callbacks).

As implemented, the plan inverted that: it made the medium external and explicit (pump) to get the E2E flow passing first.

### 3.4 Alternate Interpretation: The Issues Were Grounded If "Connector Transport" Is Out-Of-Process

If you interpret PR #23333 as defining a native messaging *API* (queue + bundles + handlers), with connectors as separate actors that call those APIs, then:

- Having an explicit pump step is aligned with the architecture: you must emulate the connector somehow in a local environment.
- The issues are reasonably grounded: they focus on making enqueue, bundling, processing, and EVM callbacks work end-to-end using the same query/transaction surfaces the connector would use.

Under that interpretation, the main weakness is not "straying from the messaging layer", but "not explicitly stating that we are testing the connector-emulation path rather than the in-node endpoint client's automatic transport."

## 4) How To Better Prompt AI Agents For Long-Running Alignment

This section proposes concrete prompting patterns that improve alignment with development goals, especially when a repository has multiple plausible "correct" approaches.

### 4.1 Make The Non-Goals Explicit, Not Implied

If the goal is "do not create any new transport tooling", say that explicitly:

Example constraint language:

- "Do not add any new tools that call `getMessages` or submit `clprProcessMessageBundle` transactions. You must rely on `ClprEndpointClient` for transport."
- "The final test must pass with the pump stage removed."

This prevents the agent from interpreting "use native messaging layer" as "call the native APIs from a new script."

### 4.2 Anchor On A Specific Existing Test As The Golden Path

If `ClprMessagesSuite` is the baseline, make that the anchor:

- "Extend `ClprMessagesSuite` to include an EVM enqueue and validate delivery, without introducing any new test harness classes."
- "Any new end-to-end test must be implemented as a new suite next to `ClprMessagesSuite` and must rely on the same internal transport mechanism."

This narrows interpretation.

### 4.3 Define "Used The Messaging Layer" Operationally

Replace vague goals with observable criteria:

- "Messages must move between ledgers without running any external client after the initial send."
- "The only processes allowed are the node processes and the test runner."

This makes it obvious that external pumping is disallowed.

### 4.4 Require Early Design Checkpoints Before Implementation

Long-running tasks should include explicit checkpoints where the agent must stop and confirm the plan before writing code.

Example:

1. "Show me where the node ships bundles today (file/line), and how the new test will trigger it."
2. "Show me the exact Solo endpoints advertised in `ClprLedgerConfiguration` and prove they are routable cross-namespace."
3. "Only then proceed to implement EVM enqueue/callback integration."

These checkpoints force early alignment and reduce the chance of building a lot of work on the wrong premise.

### 4.5 Demand A Definition Of Done That Includes Negative Assertions

Positive assertions (it works) are not enough when you care about mechanism.

Example negative assertions:

- "No new scripts in `scripts/clpr/native-queue/` that transport bundles."
- "No new Java mains under `test-clients` that emulate connectors."

This ensures the agent does not "accidentally" solve the problem by building a parallel path.

### 4.6 Provide a Minimal "Anti-Pattern" List Up Front

Provide a short list of things that are tempting but wrong for the goal.

Example anti-pattern list for this task:

- "Do not rely on manual pumping, even if it is easier to debug."
- "Do not bypass endpoint reachability issues by port-forwarding and running transport from the host."

This is especially important when the agent is under pressure to make tests pass quickly.
