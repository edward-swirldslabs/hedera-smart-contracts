# ISSUE-0010 Evidence

Date (UTC): 2026-02-12T06:31:11Z

## Implemented Files

- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- `contracts/solidity/clpr/mocks/MockClprConnector.sol`
- `contracts/solidity/clpr/mocks/MockClprQueue.sol`
- `test/solidity/clpr/clprMiddleware.js`
- `test/foundry/ClprMiddleware.t.sol`
- `test/network/clpr/clprBridgeRelayedQueue.js`

## Validation Commands

1. Hardhat CLPR middleware suite

```bash
npx hardhat test --network hardhat test/solidity/clpr/clprMiddleware.js
```

Result:

- `5 passing`
- Includes new trusted-callback authorization test and route-header assertions.

2. Foundry CLPR middleware suite

```bash
forge test --match-contract ClprMiddlewareTest
```

Result:

- `5 tests passed, 0 failed`
- Includes trusted callback caller gating behavior and route-header assertions.

## Behavior Verified

- Source middleware now rejects sends when source connector lacks configured remote middleware.
- Source middleware emits request route-header bytes in `ClprMessage.middlewareMessage.data`.
- Destination middleware emits response route-header bytes in `ClprMessageResponse.middlewareResponse.middlewareMessage.data`.
- Middleware callback authorization now supports:
  - queue contract (default path),
  - optional trusted callback caller (for native callback dispatch compatibility).
