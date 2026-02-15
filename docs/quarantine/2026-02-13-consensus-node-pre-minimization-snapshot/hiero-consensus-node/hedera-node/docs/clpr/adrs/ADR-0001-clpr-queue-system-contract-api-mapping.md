# ADR-0001: CLPR Queue System Contract API Mapping

Status: Accepted (for implementation)
Date: 2026-02-12
Owners: CLPR native queue integration track

## Context

The Solidity middleware calls queue operations via `IClprQueue`:

- `enqueueMessage(ClprTypes.ClprMessage) returns (uint64)`
- `enqueueMessageResponse(ClprTypes.ClprMessageResponse) returns (uint64)`

These signatures must remain stable. The native CLPR queue state stores opaque payload bytes (`message_data`, `message_reply_data`) keyed by remote ledger id + message id, so the EVM adapter must define:

- a system-contract address and selector mapping,
- deterministic payload mapping (ABI <-> native queue payload),
- deterministic callback routing to middleware contracts,
- consistent failure mapping to EVM behavior.

## Decision

### 1. System-contract address

Use `0x16E` for the CLPR queue system contract.

Rationale:

- Existing occupied addresses in this branch are `0x167`, `0x168`, `0x169`, `0x16A`, `0x16B`, `0x16C`.
- `0x16D` is reserved for hooks and must not be reused.
- `0x16E` is the next available adjacent system-contract slot and avoids collisions.

### 2. Selector table (canonical)

| Method | Canonical Signature | Selector |
|---|---|---|
| enqueueMessage | `enqueueMessage((address,(address,bytes32,(uint256,string),bytes),bytes32,(bool,(uint256,string),bytes),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes)))` | `0x8cfaaa60` |
| enqueueMessageResponse | `enqueueMessageResponse((uint64,(bytes),(bytes),(uint8,(uint256,string),(uint256,string),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes))))` | `0xb26aa82b` |

### 3. Payload strategy

Adopt **opaque ABI payload transport** with a thin route envelope.

- Preserve the Solidity queue API payload bytes without field-by-field translation to protobuf fields.
- Store `abi.encodeWithSelector(...)` payload inside CLPR queue opaque bytes.
- Add route header fields required for native queue routing and callback determinism.

Request envelope (`message_data`) shape:

- `version: uint8` (start with `1`)
- `remoteLedgerId: bytes32`
- `sourceMiddleware: address`
- `destinationMiddleware: address` (optional; zero means use configured default)
- `callData: bytes` (`enqueueMessage(...)` calldata)

Response envelope (`message_reply_data`) shape:

- `version: uint8` (start with `1`)
- `targetMiddleware: address` (source middleware on remote ledger)
- `callData: bytes` (`enqueueMessageResponse(...)` calldata)

### 4. Remote-ledger resolution

- Request enqueue uses `remoteLedgerId` from route header.
- Response enqueue resolves remote ledger via correlation map created during inbound request processing (`originalMessageId -> sourceLedgerId/sourceMiddleware`) and emits route envelope accordingly.

### 5. Callback target routing

- Inbound request callback target:
  - use `destinationMiddleware` from envelope if non-zero,
  - otherwise fallback to configured ledger-local default middleware address.
- Inbound response callback target:
  - use `targetMiddleware` from response envelope.

### 6. Failure mapping

| Condition | EVM behavior | Middleware impact |
|---|---|---|
| Unsupported selector / malformed ABI | halt (`INVALID_OPERATION`) | Solidity `try/catch` catches failure |
| CLPR queue service disabled | revert (`NOT_SUPPORTED`) | `try/catch` catches failure |
| Missing/invalid route metadata | revert (`INVALID_TRANSACTION_BODY` / CLPR-specific status) | `try/catch` catches failure |
| Queue state unavailable for remote ledger | revert (`CLPR_MESSAGE_QUEUE_NOT_AVAILABLE`) | `try/catch` catches failure |
| Successful enqueue | returns `uint64 messageId` | middleware records pending message |

This preserves middleware behavior that treats queue enqueue failure as rejection via `try/catch`.

### 7. Compatibility contract

- `IClprQueue` Solidity signatures remain unchanged.
- `IClprMiddleware`, app interfaces, and connector interfaces remain unchanged.
- Only opaque payload content and native adapter behavior evolve.

## Consequences

- ISSUE-0005 must add native enqueue operations and correlation state updates needed by response routing.
- ISSUE-0006 must add CLPR queue system-contract wiring at `0x16E` and method registry support.
- ISSUE-0010 may require minimal middleware-side route header population (without changing public Solidity APIs).

## Alternatives considered

1. Field-by-field protobuf mapping in adapter
- Rejected for now: high churn and lower compatibility with evolving Solidity envelope shape.

2. Reusing `0x16D`
- Rejected due to existing hook semantics and special-case storage handling.

3. Returning response-code sentinel instead of revert on enqueue failures
- Rejected because middleware currently relies on `try/catch` failure semantics.

## References

- `contracts/solidity/clpr/interfaces/IClprQueue.sol`
- `hapi/hedera-protobuf-java-api/src/main/proto/interledger/state/clpr/clpr_message_queue.proto`
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/processors/ProcessorModule.java`
- `hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/token/HookDispatchUtils.java`
