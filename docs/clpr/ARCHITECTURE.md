<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLPR Architecture

This document describes the architecture of the Cross-Ledger PRotocol (CLPR) system as implemented across `hedera-smart-contracts` (Solidity middleware) and `../hiero-consensus-node` (native messaging).

## System Overview

CLPR enables cross-ledger request/response messaging between independent Hedera/Hiero ledgers. Two ledgers communicate via a fully in-node transport path with no external relay or bridge.

The key components:

- **Solidity middleware** (`contracts/solidity/clpr/`) handles application routing, connector authorization, failover, and funds policy.
- **Queue system contract** at EVM address `0x16e` bridges EVM calls into the native CLPR queue/state.
- **Native messaging layer** (`ClprEndpointClient`) bundles queued messages and ships them between ledgers over CLPR gRPC.
- **Bundle processing handler** (`ClprProcessMessageBundleHandler`) receives inbound bundles, dispatches into EVM middleware, and enqueues responses.

The only external bootstrap action is a one-time exchange of `ClprLedgerConfiguration` state proofs between ledgers so each can discover the other's endpoints.

## Hard Guardrails

These constraints are non-negotiable:

1. **No external pump.** Do not implement any external "pump", "relay", or "bundle forwarder" process. Cross-ledger transport is `ClprEndpointClient` only.
2. **No new transport layer.** The transport must be `ClprEndpointClient` exchanging `ClprMessageBundle` over CLPR gRPC.
3. **Connectors are paymasters only.** Do not add routing, transport, or delivery behavior to connectors.
4. **Minimal Solidity API changes.** If any change to middleware/app/connector interfaces is unavoidable, it must be minimal and justified.
5. **No ABI artifacts in CLPR messaging handlers.** No Solidity function signatures, headlong tuple layouts, or ABI encoding in `hiero-clpr-interledger-service-impl`.
6. **Transaction-correlated queue mutations.** Outbound queue appends happen inside a dedicated transaction handler via synthetic dispatch, not direct state writes.
7. **Canonical on-wire envelopes.** Payload bytes are `abi.encode(ClprMessage)` / `abi.encode(ClprMessageResponse)`, not custom wrapper envelopes.
8. **No new third-party dependencies in CLPR messaging module.** `headlong` (ABI library) usage stays in the system-contract/EVM translation layer.

## Solidity Components

Source root: `contracts/solidity/clpr/`

| Component | File | Role |
|---|---|---|
| Middleware | `middleware/ClprMiddleware.sol` | Registers apps/connectors, handles send/receive flows, tracks remote connector status, enforces funds policy |
| Source App | `apps/SourceApplication.sol` | Sends messages through middleware with connector preference ordering and failover (`sendWithFailoverFromFirst`) |
| Echo App | `apps/EchoApplication.sol` | Reference destination app for request/response validation |
| Funding-Aware Base | `connectors/base/ClprFundingAwareConnectorBase.sol` | Abstract base for connectors with threshold-driven funding state machine, deposit APIs, epoch tracking, and middleware notification |
| Mock Connector | `mocks/MockClprConnector.sol` | Connector mock inheriting `ClprFundingAwareConnectorBase` for authorization, balance reporting, reimbursement |
| Mock Queue | `mocks/MockClprQueue.sol` | Single-ledger queue mock for deterministic async-style testing |
| Mock Relayed Queue | `mocks/MockClprRelayedQueue.sol` | Two-ledger queue mock used with an off-chain relayer (legacy path) |
| Types | `types/ClprTypes.sol` | Canonical message/response envelope structs, control envelope types, funding state types |
| Interfaces | `interfaces/IClprMiddleware.sol`, `interfaces/IClprQueue.sol`, `interfaces/IClprConnector.sol` | ABI interfaces including funding hooks |

### Core Solidity Flow

1. Source app calls middleware `send(...)`.
2. Middleware validates app/connector, calls source connector `authorize(...)`.
3. Middleware enqueues `ClprMessage` via the queue interface (`IClprQueue(0x16e).enqueueMessage(...)`).
4. Queue stores and native transport forwards the message to the destination.
5. Destination middleware validates destination connector and funds policy.
6. Destination app handles the message (or middleware returns connector failure status).
7. Response returns to source middleware, which updates remote status cache and delivers to source app.

### Current Behavioral Focus (IT1-CONN-AUTH + Funding Recovery)

- Connector registration and remote pairing semantics
- Source-side authorization before enqueue
- Destination-side safety threshold and minimum charge checks
- Remote balance/policy propagation in response handling
- Source-side pre-enqueue rejection when remote connector is known out-of-funds (epoch-aware)
- Connector preference and failover in the source app
- Funding-aware connector base with deposit APIs and threshold-driven state machine
- Cross-ledger funding state synchronization via control envelopes (no polling or external pump)
- Top-off recovery: destination connector topped up → state transition published → source cache updated → connector usable again
- Re-depletion: connector exhausts funds again → new transition → source pre-rejects again

### Funding Control Plane

Connectors inherit `ClprFundingAwareConnectorBase` which implements a two-state funding model (`Available` / `Underfunded`) with a monotonic `fundingEpoch` counter. When a connector's available balance crosses the safety threshold:

1. **Connector detects transition**: `ClprFundingAwareConnectorBase` re-evaluates state after deposits or reimbursements.
2. **Connector notifies local middleware**: Calls `IClprMiddleware.onConnectorFundingStateTransition(connectorId, epoch, state, balanceReport)`.
3. **Middleware enqueues control message**: Builds a `ClprControlEnvelope` wrapping a `ClprFundingStateUpdate` and enqueues it to the remote middleware via the normal queue path.
4. **Remote middleware applies update**: On the source side, `_applyRemoteFundingStateUpdate` updates the remote connector cache with epoch ordering (stale/duplicate epochs are ignored).
5. **Pre-reject uses updated cache**: Source middleware `_isRemoteOutOfFunds` checks the cached remote funding state before allowing enqueue.

Control types (`ClprTypes.sol`):
- `ClprControlType`: `ConnectorFundingStateUpdate`, `ConnectorFundingStateQuery`, `ConnectorFundingStateAck`
- `ClprFundingState`: `Underfunded`, `Available`
- `ClprFundingStateUpdate`: full payload with `connectorId`, `fundingEpoch`, `state`, `balanceReport`, charge bounds
- `ClprControlEnvelope`: generic wrapper for typed control messages in `middlewareMessage.data`

## Consensus Node Components

Source root: `../hiero-consensus-node/`

### Queue System Contract (`0x16e`)

The EVM-to-native bridge. When Solidity calls `enqueueMessage(...)` or `enqueueMessageResponse(...)`, the system contract:

- Extracts canonical payload bytes (`input[4:]`, stripping the selector)
- Dispatches a synthetic `clprEnqueueMessage` transaction
- Returns the assigned `messageId` to the EVM caller

Config flag: `contracts.systemContract.clprQueue.enabled=true`

Additionally provides node-internal delivery entry points (not part of the Solidity `IClprQueue` interface) used by bundle processing:

- **Deliver inbound request**: Decodes canonical message bytes, dispatches middleware `handleMessage(...)`, enqueues the reply
- **Deliver inbound response**: Decodes canonical response bytes, dispatches middleware `handleMessageResponse(...)`

These use a packed binary format (not Ethereum ABI) so the messaging module does not need ABI tooling.

### Native Queue Mutation Handler (`ClprEnqueueMessageHandler`)

The only component that appends to outbound queue state:

- Assigns `messageId` from `queueMetadata.next_message_id`
- Computes running hash
- Stores `ClprMessageValue(payload, running_hash)`
- Increments `next_message_id`

Invoked only via synthetic dispatches, ensuring all queue mutations are transaction-correlated in the block stream.

### Bundle Processing Handler (`ClprProcessMessageBundleHandler`)

Handles inbound `ClprMessageBundle` received over CLPR gRPC:

- Validates state proof and running hash
- Computes message IDs and dedup/skip rules
- For each inbound payload, dispatches delivery to `0x16e` (which handles ABI translation + middleware dispatch)
- Updates `received_message_id` and `received_running_hash` for the sender ledger

### Endpoint Client (`ClprEndpointClient`)

The native messaging transport:

- Bundles outbound messages from native state into `ClprMessageBundle`
- Ships bundles to destination ledger via CLPR gRPC
- In SOLO/dev mode, uses treasury as payer and resolves domain-name endpoints

### Key New/Modified Files (Consensus Node)

| File | Purpose |
|---|---|
| `hedera-smart-contract-service-impl/.../ClprQueueSystemContract.java` | System contract at `0x16e` |
| `hedera-smart-contract-service-impl/.../ClprQueueTranslatorsModule.java` | ABI translator registration |
| `hedera-smart-contract-service-impl/.../clpr/queue/**` | Enqueue + delivery translator/call implementations |
| `hiero-clpr-interledger-service-impl/.../ClprEnqueueMessageHandler.java` | Outbound queue transaction handler |
| `hiero-clpr-interledger-service-impl/.../ClprProcessMessageBundleHandler.java` | Inbound bundle processing |
| `hiero-clpr-interledger-service-impl/.../ClprEndpointClient.java` | Native messaging transport |
| `hedera-config/.../ContractsConfig.java` | Feature gate `systemContract.clprQueue.enabled` |
| `hedera-app/.../WritableStoreFactory.java` | Cross-service writable CLPR store access (allow-listed) |
| `hedera-app-spi/.../StreamBuilder.java` | API to access EVM return bytes from synthetic calls |

## Message Flow (End-to-End)

### Outbound Request (Source Ledger)

1. Source app calls `ClprMiddleware.send(applicationMessage)`.
2. Middleware constructs `ClprTypes.ClprMessage` with a versioned route header in `middlewareMessage.data` containing `(version, remoteLedgerId, sourceMiddleware, destinationMiddleware)`.
3. Middleware calls `IClprQueue(0x16e).enqueueMessage(message)`.
4. System contract extracts destination ledger ID from route header, builds synthetic `clprEnqueueMessage` transaction with `message_data = input[4:]` (canonical bytes).
5. `ClprEnqueueMessageHandler` assigns `messageId`, computes running hash, stores message, increments `next_message_id`.
6. `enqueueMessage(...)` returns assigned `messageId` to middleware.
7. `ClprEndpointClient` later bundles outbound messages and sends them to the destination via CLPR gRPC.

### Inbound Bundle Processing (Destination Ledger)

1. Destination receives `ClprMessageBundle` over gRPC, submitted as `clprProcessMessageBundle` transaction.
2. `ClprProcessMessageBundleHandler` validates, then for each inbound request payload dispatches to `0x16e`.
3. Inside `0x16e`: ABI-decodes canonical request bytes → dispatches `handleMessage(message, inboundMessageId)` to destination middleware → captures EVM return bytes → dispatches `clprEnqueueMessage` to queue a `message_reply` payload for the source ledger.
4. Destination `ClprEndpointClient` later ships these reply payloads back.

### Inbound Response (Source Ledger)

1. Source receives a reply bundle.
2. `ClprProcessMessageBundleHandler` dispatches each response payload to `0x16e`.
3. Inside `0x16e`: ABI-decodes canonical response bytes → dispatches `handleMessageResponse(response)` to source middleware.
4. Source middleware updates remote status cache, calls source app callback.

## Wire Encoding

### Canonical Request Envelope

`ClprMessagePayload.message.message_data` contains `abi.encode(ClprTypes.ClprMessage)`.

Implementation: When EVM calls `enqueueMessage(ClprMessage)`, the canonical bytes are `input[4:]` (selector stripped).

### Canonical Response Envelope

`ClprMessagePayload.message_reply.message_reply_data` contains `abi.encode(ClprTypes.ClprMessageResponse)`.

Implementation: Similarly `input[4:]` for `enqueueMessageResponse(...)`, or the raw EVM return bytes from `handleMessage(...)`.

### Opaque Bytes

Only these inner fields are treated as opaque by the protocol:

- `ClprApplicationMessage.data`
- `ClprConnectorMessage.data`
- `ClprMiddlewareMessage.data`
- `ClprApplicationResponse.data`
- `ClprConnectorResponse.data`

Everything else is structured by the canonical envelope encoding.

## One-Time Config Exchange ("Kick")

The only allowed external bootstrap action:

1. Each ledger runs with `clpr.publicizeNetworkAddresses=true`.
2. A one-time tool (`tools/clpr/ClprConfigExchange.java`) fetches each ledger's `ClprLedgerConfiguration` state proof and installs it on the peer ledger via `setConfiguration(...)`.
3. After this exchange, the native messaging layer operates autonomously.

## Middleware Callback Authorization

Native bundle processing invokes middleware callbacks via synthetic `ContractCall` where `msg.sender` is the transaction payer (e.g., `0.0.2` in SOLO), not the queue system contract. The middleware uses `trustedCallbackCaller` as an allow-list to authorize these synthetic dispatches.
