# Queue Adapter Design Notes (Issue-0004)

Status: Completed design baseline
Date: 2026-02-12

This note mirrors ADR-0001 in `../hiero-consensus-node` and provides concrete payload examples for adapter tests.

## Locked decisions

- System-contract address: `0x16E`
- Queue API signatures remain unchanged (`IClprQueue`)
- Payload strategy: opaque ABI payload bytes with a thin route envelope
- Unsupported/malformed calls fail (halt or revert) so middleware `try/catch` handles enqueue failures naturally

## Selector table

- `enqueueMessage(...)` => `0x8cfaaa60`
- `enqueueMessageResponse(...)` => `0xb26aa82b`

Canonical signatures used for selector calculation:

- `enqueueMessage((address,(address,bytes32,(uint256,string),bytes),bytes32,(bool,(uint256,string),bytes),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes)))`
- `enqueueMessageResponse((uint64,(bytes),(bytes),(uint8,(uint256,string),(uint256,string),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes))))`

## Envelope format (v1)

Request (`ClprMessagePayload.message.message_data`):

- `uint8 version`
- `bytes32 remoteLedgerId`
- `address sourceMiddleware`
- `address destinationMiddleware`
- `bytes callData` (full `enqueueMessage(...)` calldata)

Response (`ClprMessagePayload.message_reply.message_reply_data`):

- `uint8 version`
- `address targetMiddleware`
- `bytes callData` (full `enqueueMessageResponse(...)` calldata)

## Routing rules

- Request enqueue routes by `remoteLedgerId` in route header.
- Response enqueue routes via correlation state keyed from previously processed inbound request.
- Request callback target: envelope `destinationMiddleware` (fallback to configured default if zero).
- Response callback target: envelope `targetMiddleware`.

## Concrete encode examples

Generated with `ethers.Interface` from `artifacts/contracts/solidity/clpr/interfaces/IClprQueue.sol/IClprQueue.json`.

- request calldata size: `1412` bytes
- response calldata size: `1380` bytes
- request envelope size: `1632` bytes
- response envelope size: `1536` bytes

Example prefixes:

- request calldata prefix:
  - `0x8cfaaa6000000000000000000000000000000000000000000000000000000000000000200000000000000000000000001000000000000000000000000000000000000001`
- response calldata prefix:
  - `0xb26aa82b00000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000000000007`
- request envelope prefix:
  - `0x0000000000000000000000000000000000000000000000000000000000000001aabbccddeeff00112233445566778899aabbccddeeff0011223344556677889900000000`
- response envelope prefix:
  - `0x0000000000000000000000000000000000000000000000000000000000000001000000000000000000000000900000000000000000000000000000000000000900000000`

Reference hashes:

- route header hash: `0xd67df4605fdc4e5605647eef59caa9b4d8169f20957e14692f90b6bb26b53318`
- request calldata hash: `0xb27d2a810ccfaeb8d500a9138141c65a1beaf8a13ae55e2562d41c96d7325743`
- response calldata hash: `0x8fb63b1fba03e7161b32e90cfc70adfbce0a459fcfc0f4169e061c6cdc17ef39`

## Feed-forward to implementation issues

- ISSUE-0005:
  - add enqueue primitives in native CLPR service with route + correlation support
  - remove queue test-seeding shortcut from `ClprUpdateMessageQueueMetadataHandler`
- ISSUE-0006:
  - scaffold CLPR queue system-contract package at `0x16E`
- ISSUE-0007/0008:
  - use these exact signatures/selectors as fixtures
- ISSUE-0009:
  - implement callback routing via envelopes and correlation state
