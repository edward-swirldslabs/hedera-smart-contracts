# CLPR Consensus Node Refactor Proposal

This document proposes a corrected, production-intended shape for CLPR native messaging integration in the sibling repo `../hiero-consensus-node`, based on the constraints and target behavior you described.

Scope of this proposal:

- Remove ABI artifacts and ABI decoding/encoding from CLPR messaging-layer handlers (especially `ClprProcessMessageBundleHandler`).
- Ensure outbound CLPR queue state mutations are correlated to **explicit dispatched transactions** (block-stream traceability), instead of direct store writes.
- Ensure the on-wire message envelopes are the existing CLPR queue protos (`ClprMessagePayload` / `ClprMessage` / `ClprMessageReply`) and that the payload bytes are the canonical request/response envelopes (not queue ABI call-data wrappers).
- Do not introduce new third-party dependencies in new CLPR code. (Where `headlong` already exists in consensus-node, keep its usage localized to system-contract/EVM translation code, not CLPR messaging.)

Non-goals of this proposal:

- Not attempting to “complete middleware requirements” in `hiero-consensus-node` (beyond what is required to integrate the native messaging layer).
- Not changing connector logic; connectors remain paymasters only.
- Not designing ledger-routing inside the node messaging/queue layer (ledger selection remains an outcome of connector selection and the middleware’s message contents).

---

## 0) Current State (What We Are Refactoring Away From)

The current (problematic) shape in `../hiero-consensus-node` includes:

- A queue system contract at `0x16e` that writes directly into CLPR stores via `ClprQueueOperations.enqueue(...)`:
  - `hedera-node/hedera-smart-contract-service-impl/.../clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java`
  - `hedera-node/hedera-smart-contract-service-impl/.../clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java`
- A CLPR bundle handler (`ClprProcessMessageBundleHandler`) that:
  - embeds hard-coded ABI signatures and tuple layouts for middleware + queue,
  - decodes/encodes ABI in the messaging layer (via `com.esaulpaugh.headlong.abi.*`),
  - constructs non-canonical “request/response envelope wrappers” and stores them in `ClprMessage.message_data` / `ClprMessageReply.message_reply_data`,
  - and directly enqueues responses into native state from the bundle handler (not via a dedicated transaction handler).
  - File: `hedera-node/hiero-clpr-interledger-service-impl/.../handlers/ClprProcessMessageBundleHandler.java`
- The CLPR messaging module `org.hiero.interledger.clpr.impl` currently depends on `headlong` via:
  - `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/module-info.java`

This violates your intended separation of concerns:

- Messaging-layer handlers should be proto/state-proof-centric and should not contain ABI knowledge.
- Queue state mutations should be tied to explicit transactions (child dispatches) for block-stream correlation.
- On-wire payload bytes should be the canonical CLPR request/response envelopes, not queue ABI call-data or custom wrappers.

---

## 1) Target State Summary

### 1.1 Hard Requirements (Constraints)

1. **No ABI artifacts in CLPR messaging handlers**
   - No hard-coded Solidity function signatures.
   - No headlong tuple layouts.
   - No ABI decoding/encoding of CLPR payloads in `hiero-clpr-interledger-service-impl`.

2. **Outbound queue mutations are transaction-correlated**
   - Appending to outbound CLPR queues must happen inside a dedicated **transaction handler** invoked via **synthetic dispatch**.
   - No direct writes to CLPR queue/message state from system contracts or bundle processing.

3. **Canonical on-wire envelopes**
   - The on-wire envelope MUST be `ClprMessagePayload` with either:
     - `ClprMessage.message_data = <canonical request envelope bytes>`
     - `ClprMessageReply.message_reply_data = <canonical response envelope bytes>`
   - Only application payload, connector payload, and middleware-to-middleware payload fields remain “opaque bytes” *inside* these envelopes.
   - No additional wrapper “route envelope” around the canonical envelopes at the messaging layer.

4. **No new third-party dependencies**
   - The CLPR messaging module must not newly depend on third-party libraries for ABI (notably `com.esaulpaugh.headlong.abi`).
   - Any ABI translation that is unavoidable should stay in the already-EVM-centric system contract code paths (where `headlong` is already widely used).

### 1.2 The Key Architectural Move

Split responsibilities cleanly:

- **Messaging layer (`ClprProcessMessageBundleHandler`)**
  - validates bundle + state proof + running hash
  - updates received metadata
  - dispatches a per-message “delivery” step *to the CLPR Queue System Contract* (not to middleware)
  - does *not* decode ABI or build ABI artifacts

- **EVM boundary (Queue System Contract @ `0x16e`)**
  - translates between EVM calls and native queue operations
  - contains ABI translation (if needed at all)
  - does *not* directly mutate CLPR queue/message state
  - instead uses synthetic dispatch to a native enqueue transaction handler
  - additionally provides **node-internal delivery entrypoints** used by bundle processing:
    - request delivery: invokes middleware `handleMessage(...)` and enqueues the reply
    - response delivery: invokes middleware `handleMessageResponse(...)`

- **Native queue mutation handler (`ClprEnqueueMessageHandler`)**
  - the only component that appends to outbound queue state
  - updates `next_message_id` and stores message values with running hashes
  - is invoked only via synthetic dispatches

---

## 2) Canonical Wire Encoding (What Goes In `message_data` and `message_reply_data`)

The existing CLPR state proto intentionally treats the inner bytes as “opaque”; your constraint narrows that down to a canonical definition.

### 2.1 Canonical Request Envelope Bytes

For `ClprMessagePayload.message.message_data`, the bytes MUST be:

- `abi.encode(ClprTypes.ClprMessage)` where `ClprTypes.ClprMessage` is the Solidity request envelope struct used by the middleware + queue interface in this repo (`contracts/solidity/clpr/types/ClprTypes.sol`).

Implementation note (consensus-node side):

- If the EVM caller invokes `IClprQueue.enqueueMessage(ClprMessage)`, then the call data is:
  - `selector(4 bytes) || abi.encode(ClprMessage)`
- Therefore, the canonical `message_data` can be obtained *without re-encoding* by stripping the selector:
  - `message_data := input[4:]`

### 2.2 Canonical Response Envelope Bytes

For `ClprMessagePayload.message_reply.message_reply_data`, the bytes MUST be:

- `abi.encode(ClprTypes.ClprMessageResponse)` where `ClprTypes.ClprMessageResponse` is the Solidity response envelope struct.

Implementation notes:

- If an EVM caller invokes `IClprQueue.enqueueMessageResponse(ClprMessageResponse)`, the canonical bytes are similarly `input[4:]`.
- If a destination middleware returns a `ClprMessageResponse` from `handleMessage(...)`, the EVM return bytes are already the canonical ABI encoding of the response struct for a single return value:
  - `message_reply_data := evmReturnBytes`

### 2.3 “Opaque Bytes” Rule Is Preserved

Only these fields are treated as “opaque bytes” by the protocol:

- `ClprApplicationMessage.data`
- `ClprConnectorMessage.data`
- `ClprMiddlewareMessage.data`
- `ClprApplicationResponse.data`
- `ClprConnectorResponse.data`

Everything else is structured by the canonical envelope encoding above.

---

## 3) Call Flows (End-to-End)

The call flows below are written as *runtime* sequences across:

- Solidity contracts (middleware/apps/connectors)
- Queue system contract at `0x16e`
- Native queue state + messaging transport (`ClprEndpointClient`)
- Bundle processing handler(s)

### 3.1 Outbound Request (Source Ledger)

1. Source app calls `ClprMiddleware.send(applicationMessage)`.
2. Middleware constructs `ClprTypes.ClprMessage` and calls the queue interface:
   - `IClprQueue(0x16e).enqueueMessage(message)`.
3. Queue system contract (`0x16e`) executes `enqueueMessage(...)`:
   - Extracts destination ledger id by decoding the **route header** carried inside the canonical message envelope
     (typically stored in `ClprMiddlewareMessage.data`).
   - Builds a synthetic `clprEnqueueMessage` transaction containing:
     - `remote_ledger_id = <destination ledger id>`
     - `payload.message.message_data = input[4:]` (canonical)
   - Dispatches the synthetic tx.
4. Native `ClprEnqueueMessageHandler` handles the synthetic tx:
   - assigns `messageId := queueMetadata.next_message_id`
   - computes running hash
   - stores `ClprMessageValue(payload,running_hash_after_processing)`
   - increments `next_message_id`
5. `enqueueMessage(...)` returns the assigned `messageId` to middleware.
6. Source middleware stores local pending state keyed by `messageId`.
7. Later, `ClprEndpointClient` bundles outbound messages and sends them to the destination ledger via CLPR gRPC as `ClprMessageBundle`.

### 3.2 Inbound Bundle Processing (Destination Ledger)

1. Destination ledger receives a `ClprMessageBundle` over CLPR gRPC (via `ClprEndpointClient`), submitted as a `clprProcessMessageBundle` transaction.
2. `ClprProcessMessageBundleHandler` handles it:
   - validates state proof and running hash
   - computes message ids and dedup/skip rules
   - for each inbound payload:
     - dispatches a per-message “delivery” step to the queue system contract at `0x16e`
   - updates `received_message_id` + `received_running_hash` for the sender ledger queue metadata

**Per-message “delivery” step for inbound request messages (performed by the queue system contract):**

3. `ClprProcessMessageBundleHandler` dispatches a synthetic `ContractCall` to `0x16e`, calling a node-internal delivery method
   (packed binary call data; see §4.5) with:
   - `sourceLedgerId = bundle.ledger_id` (the bundle sender, i.e. where replies must be queued)
   - `inboundMessageId`
   - `message_data` (canonical request envelope bytes)
4. Inside `0x16e`, the system contract:
   - ABI-decodes the canonical request envelope bytes into a `ClprMessage` tuple
   - extracts the destination middleware address (if required) from the canonical envelope’s structured fields
     (for the current Solidity prototype this is typically located inside the route header in middleware-to-middleware bytes)
   - dispatches a synthetic `ContractCall` to the destination middleware: `handleMessage(message, inboundMessageId)`
   - captures the EVM return bytes (`abi.encode(ClprMessageResponse)`), without wrapping them in any custom envelope
   - dispatches a synthetic `clprEnqueueMessage` tx to enqueue a `message_reply` payload to the outbound queue keyed by `sourceLedgerId`
5. The destination `ClprEndpointClient` later sends these queued reply payloads back to the source ledger in bundles.

Important note (ledger id for replies):

- Replies MUST be queued under the sender ledger id from the inbound bundle (the ledger that will later call `getMessageBundle(ledger_id=<sourceLedgerId>)`).
- This “reply target ledger id” is contextual and must not depend on extra wrapper envelopes.

### 3.3 Inbound Response Bundle Processing (Source Ledger)

1. Source ledger receives a bundle whose payloads are `message_reply` variants with canonical `message_reply_data`.
2. `ClprProcessMessageBundleHandler` validates and dispatches delivery per response.
3. For each response payload, `ClprProcessMessageBundleHandler` dispatches a synthetic `ContractCall` to `0x16e`
   to deliver the response (packed binary call data; see §4.5). Inside `0x16e`, the system contract dispatches the synthetic `ContractCall` to the source
   middleware `handleMessageResponse(response)`.
4. Source middleware updates remote status cache and calls back into the source application.

---

## 4) Proposed Code Changes in `../hiero-consensus-node`

This section lists the concrete new/modified components needed to reach the target state.

### 4.1 New Transaction Type: `clprEnqueueMessage`

Goal:

- Make queue appends transaction-correlated in block stream.

New protobuf:

- Add `hapi/hedera-protobuf-java-api/src/main/proto/interledger/clpr_enqueue_message.proto`
  - Proposed message:
    - `ClprLedgerId ledger_id`
    - `ClprMessagePayload payload`
    - (Optional but recommended) `uint64 expected_message_id`
      - lets the system contract pre-compute and assert the assignment deterministically

Wire into transaction body:

- Add a new field to `hapi/.../services/transaction.proto` under `TransactionBody.data`:
  - `org.hiero.hapi.interledger.clpr.ClprEnqueueMessageTransactionBody clprEnqueueMessage = 103;`
- Add `HederaFunctionality` enum value in `hapi/.../services/basic_types.proto`:
  - `ClprEnqueueMessage = <next available id>` (exact number to be chosen to avoid collisions)

### 4.2 New Handler: `ClprEnqueueMessageHandler`

New Java handler:

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprEnqueueMessageHandler.java`

Responsibilities:

- Pure checks:
  - CLPR enabled
  - ledger id non-empty
  - payload has `message` or `message_reply`
  - queue metadata exists for ledger
  - if `expected_message_id` is present: it matches `queueMetadata.next_message_id`
- Handle:
  - `assignedId := queueMetadata.next_message_id`
  - compute running hash using `ClprMessageUtils.nextRunningHash(payload, previousHash)`
  - `messageStore.put(ClprMessageKey(ledgerId, assignedId), ClprMessageValue(payload,nextHash))`
  - increment `queueMetadata.next_message_id`

Notes:

- This replaces `org.hiero.interledger.clpr.impl.ClprQueueOperations.enqueue(...)` as the only way to append to the queue.

### 4.3 Refactor Queue System Contract (`0x16e`) to Dispatch Enqueue Transactions

Modify:

- `hedera-node/hedera-smart-contract-service-impl/.../clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java`
- `hedera-node/hedera-smart-contract-service-impl/.../clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java`

Changes:

- Remove direct state mutation through `ClprQueueOperations.enqueue(...)`.
- Build `ClprMessagePayload` using canonical bytes:
  - request: `message_data := input[4:]`
  - response: `message_reply_data := input[4:]`
- Dispatch `clprEnqueueMessage` synthetic tx:
  - payer: EVM sender id (or the synthetic payer used by the contract call handler)
  - verification: the attempt’s default verification strategy (standard system contract dispatch pattern)
- Return the assigned messageId to EVM caller:
  - Preferred: pre-read `next_message_id` and include `expected_message_id` in the synthetic body; return it after successful dispatch.

Expected result:

- `ClprQueueSystemContract` no longer needs writable CLPR stores via `HederaNativeOperations`.
- The contract service does not directly cross-write into CLPR service state.

#### 4.3.1 Remove Cross-Service CLPR Store Plumbing From Contract Scope (If Present On This Branch)

If the current branch introduced any of the following patterns to let the contract service directly mutate CLPR stores:

- a contract-service “escape hatch” such as `HederaNativeOperations.writableClprMessageStore()` or
  `HederaNativeOperations.writableClprMessageQueueMetadataStore()`
- contract-to-CLPR cross-service writable store allow-lists (for example a `WritableStoreFactory` special-case set)

…then the target state is to remove them once enqueue is implemented via `clprEnqueueMessage` dispatches.

Rationale:

- The system contract should only translate/dispatch; the enqueue handler should be the only writer of outbound queue state.
- This keeps the contract service from taking a direct dependency on CLPR service stores.

### 4.4 Refactor Bundle Handler: Remove ABI + Remove Custom Envelope Wrappers

Modify:

- `hedera-node/hiero-clpr-interledger-service-impl/.../handlers/ClprProcessMessageBundleHandler.java`

Remove entirely:

- `com.esaulpaugh.headlong.abi.*` usage
- all hard-coded ABI signatures and tuple layouts
- “request envelope” / “response envelope” wrapper encoding
- direct enqueue of replies via `ClprQueueOperations.enqueue(...)`

Replace with:

- For inbound request payload:
  - dispatch a synthetic `ContractCall` to the queue system contract `0x16e` to deliver the canonical message bytes
  - the system contract performs ABI translation + middleware dispatch + response enqueue internally
- For inbound response payload:
  - dispatch a synthetic `ContractCall` to the queue system contract `0x16e` to deliver the canonical response bytes
  - the system contract performs ABI translation + middleware dispatch internally

Critical note about ABI:

- `ClprProcessMessageBundleHandler` must not embed ABI artifacts or depend on headlong.
- Any ABI-aware call-data building and payload decoding/encoding belongs in the system contract translators/calls for `0x16e`.

### 4.5 New Node-Internal Delivery Entry Points on `0x16e` (No Ethereum ABI)

To keep *all* ABI logic out of the messaging module (and avoid introducing ABI encoders/decoders there),
bundle processing should invoke **node-internal entry points** on `0x16e` using a **simple packed binary format**.

These entry points are intentionally:

- **not** part of the Solidity `IClprQueue` interface (they are node-internal),
- **not** Ethereum-ABI encoded (so callers do not need ABI tooling),
- and are implemented entirely in the system-contract translator/call layer.

`0x16e` therefore needs node-internal entry points that:

1. Accept canonical envelope bytes from bundle processing.
2. Decode them using ABI tooling (headlong) *in the system contract layer*.
3. Dispatch middleware callbacks.
4. Enqueue responses via `clprEnqueueMessage` synthetic dispatches (transaction-correlated queue mutations).

Proposed packed call data formats:

1. **Deliver inbound request message**

- Selector (4 bytes): `DELIVER_INBOUND_MESSAGE_SELECTOR`
- Payload:
  - `sourceLedgerId` (32 bytes, big-endian, left-padded as Solidity `bytes32`)
  - `inboundMessageId` (8 bytes, unsigned big-endian)
  - `messageDataLen` (4 bytes, unsigned big-endian)
  - `messageData` (`messageDataLen` bytes)

Semantics:

- `messageData` is the canonical `abi.encode(ClprMessage)` bytes from `ClprMessage.message_data`.
- On success:
  - decode `messageData` to a `ClprMessage` tuple (ABI-aware in system contract layer)
  - dispatch middleware `handleMessage(message, inboundMessageId)`
  - dispatch `clprEnqueueMessage` to append a `message_reply` payload to the outbound queue keyed by `sourceLedgerId`
- On failure:
  - best-of-breed: enqueue a synthetic failure response and still advance `received_message_id` (avoids deadlock)
  - prototype fallback: return a non-success status code to the caller and let the bundle tx fail

Return bytes (system contract output):

- Standardized `int64` status code (or a Hedera-style encoded rc), consistent with other system contracts.

2. **Deliver inbound response message**

- Selector (4 bytes): `DELIVER_INBOUND_MESSAGE_REPLY_SELECTOR`
- Payload:
  - `responseDataLen` (4 bytes, unsigned big-endian)
  - `responseData` (`responseDataLen` bytes)

Semantics:

- `responseData` is the canonical `abi.encode(ClprMessageResponse)` bytes from `ClprMessageReply.message_reply_data`.
- Decode to extract the target middleware address (if required), then dispatch middleware `handleMessageResponse(response)`.

New translators/calls needed (in `hedera-smart-contract-service-impl`):

- `.../exec/systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageTranslator.java`
- `.../exec/systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java`
- `.../exec/systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyTranslator.java`
- `.../exec/systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java`

`ClprQueueTranslatorsModule` must register these translators alongside enqueue translators.

### 4.6 Remove `headlong` From CLPR Messaging Module

Modify:

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/module-info.java`

Change:

- Remove `requires transitive com.esaulpaugh.headlong;`

Expected outcome:

- CLPR messaging-layer code no longer depends on ABI libraries.

### 4.7 Delete / Deprecate `ClprQueueOperations`

Modify:

- `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprQueueOperations.java`

Change:

- Delete it, or reduce to a test-only helper not used by runtime code.

Rationale:

- Queue mutation must happen inside `ClprEnqueueMessageHandler` to be transaction-correlated.

---

## 5) Proposed Code Changes in `hedera-smart-contracts` (This Repo)

The target state above is designed to avoid Solidity changes.

However, one constraint remains practical:

- The consensus node delivers inbound messages via synthetic `ContractCall` transactions.
- In those synthetic calls, `msg.sender` will be the synthetic transaction payer (an account), not the queue system contract (`0x16e`).

Therefore, middleware callback authorization must allow a trusted synthetic caller, or the node must gain the ability to execute middleware callbacks with `msg.sender=0x16e` (not currently a standard pattern for system contracts).

Given the existing code already includes an allow-list:

- `ClprMiddleware.trustedCallbackCaller`

This proposal assumes that:

- The deployment/test harness configures `trustedCallbackCaller` to the payer used by CLPR bundle processing dispatches.
- No connector or application changes are needed.

If you want the “final form” to have zero Solidity changes:

- A separate design spike is needed to determine if consensus-node can legally and safely execute EVM calls that present `0x16e` as `msg.sender` (for example, via internal EVM frame execution or a special dispatch identity). This is not included in this proposal because it is significantly more invasive than the CLPR-native messaging integration itself.

---

## 6) Concrete Inventory of New/Modified Classes (By Component)

### 6.1 New Proto

- `../hiero-consensus-node/hapi/hedera-protobuf-java-api/src/main/proto/interledger/clpr_enqueue_message.proto`

### 6.2 New Transaction Handler

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprEnqueueMessageHandler.java`

### 6.3 Modified Dispatcher Wiring

- `../hiero-consensus-node/hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/dispatcher/TransactionHandlers.java`
  - add `ClprEnqueueMessageHandler`
- `../hiero-consensus-node/hedera-node/hedera-app/src/main/java/com/hedera/node/app/workflows/dispatcher/TransactionDispatcher.java`
  - dispatch new `CLPR_ENQUEUE_MESSAGE` kind to the handler

### 6.4 Modified System Contract Calls

- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java`

### 6.5 New System Contract Delivery Calls/Translators

- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageTranslator.java` (new)
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java` (new)
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyTranslator.java` (new)
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java` (new)

### 6.6 Modified Bundle Handler

- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/.../handlers/ClprProcessMessageBundleHandler.java`

---

## 7) Open Questions / Decisions Needed (Before Implementation)

1. **Where should ABI-aware call-data building live?**
   - Preferred: contract service module (ABI tooling already present), exposed via a tiny API that messaging layer can call.
   - Alternative: define a system-contract helper method and have bundle handler call it (adds nesting).

2. **Do we treat `enqueueMessageResponse(...)` as a supported external EVM API?**
   - If yes, we need an unambiguous rule for how the response envelope indicates the target ledger id for enqueue.
   - If no (for now), we keep it but do not rely on it for the SOLO scenario; responses are queued using the sender ledger id from the inbound bundle context.

3. **Middleware callback authorization**
   - If we accept the existing `trustedCallbackCaller` mechanism, no further Solidity changes required.
   - If we want to remove it, we need a much deeper EVM execution design to preserve `msg.sender=0x16e`.

4. **Failure semantics**
   - If middleware callback reverts, should the node enqueue a synthetic failure response or fail the whole bundle transaction?
   - Best-of-breed: enqueue a failure response and still advance `received_message_id` to avoid deadlock.

---

## 8) Why This Proposal Meets Your Constraints

- No ABI artifacts in messaging:
  - `ClprProcessMessageBundleHandler` becomes proto/state-proof + dispatch only.
  - headlong is removed from `hiero-clpr-interledger-service-impl`.

- Transaction-correlated outbound queue mutations:
  - every append is a synthetic `clprEnqueueMessage` transaction handled by a dedicated handler.

- Canonical on-wire envelopes:
  - payload bytes are `abi.encode(ClprMessage)` / `abi.encode(ClprMessageResponse)`, not wrapper envelopes.

- No new messaging infrastructure:
  - still uses the existing native messaging layer (`ClprEndpointClient`) moving `ClprMessageBundle` over CLPR gRPC.

---

## 9) Next Step (After You Review This Proposal)

After you confirm this is the intended target shape, we can translate this proposal into a new issue set with guardrails, and only then start the implementation/refactor work.
