# ISSUE-0107: Pare Down `hedera-smart-contracts` Changes to the Minimum

## Goal

Ensure the smart-contract-side code remains as close as possible to the original intended design:

- Middleware, connector, and application Solidity code should not be changed unless strictly required to use the Queue System Contract.
- Any changes made solely to support the quarantined pump-based approach must be removed.

## Requirements (Must Be True)

- Connectors remain paymasters only.
- Existing middleware/app/connector Solidity APIs remain stable whenever possible.
- Any Solidity changes that remain are justified as “required for native Queue System Contract compatibility”.

## Tasks

- Review current `git diff` in this repo and classify each change:
  - required for queue system contract integration
  - convenience for pump-based testing (must be removed)
  - unrelated (must be removed)
- Remove or revert any connector changes that introduce:
  - routing/ledger selection logic beyond connector id semantics
  - transport/delivery semantics
  - queue “pumping” helpers
- Remove or revert Solidity API changes unless there is a consensus-node limitation that forces them.
- Ensure ABI artifacts remain consistent with source contracts:
  - `contracts-abi/.../*.json` should match compiled output.

## Acceptance Criteria

- A reviewer can explain, file by file, why every remaining Solidity change is necessary.
- There are no contract-level behaviors that imply an external pump is required.

## Resolution (Done)

Kept changes in `hedera-smart-contracts` were limited to what is required to exercise the native queue system contract
(`0x16e`) and to drive/verify the SOLO end-to-end scenario without introducing any external bundle pumping.

Required Solidity/API compatibility changes:

- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
  - Added a small route header in `ClprMessage.middlewareMessage.data` so the native queue system contract can build the
    on-wire request envelope consumed by the native bundle handler.
  - Added `trustedCallbackCaller` so middleware callbacks can be accepted when native bundle processing dispatches
    synthetic contract calls where `msg.sender` is the CLPR payer (not the queue system contract).
- `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
  - Added `setConnectorRemoteMiddleware(...)` and `setTrustedCallbackCaller(...)` for the above configuration.
- `contracts/solidity/clpr/apps/SourceApplication.sol`
  - Added `sendWithFailoverFromFirst(...)` and minimal response state (`lastReceivedAppMsgId`) so the SOLO runner can
    reproduce and assert the required connector failover behavior deterministically without relying on a mirror node.

Test-only observability additions (mocks only):

- `contracts/solidity/clpr/mocks/MockClprQueue.sol` and `contracts/solidity/clpr/mocks/MockClprConnector.sol`
  - Added minimal accessors to assert that request/response route headers are present and correctly shaped.

Tests updated to cover the required behavior and compatibility:

- `test/solidity/clpr/clprMiddleware.js`
- `test/foundry/ClprMiddleware.t.sol`
- `test/network/clpr/clprBridgeRelayedQueue.js`

SOLO driver/scripts and docs (new files, not part of Solidity protocol surface):

- `scripts/clpr/native-messaging-solo/` (repeatable SOLO orchestration + scenario runner)
- `tools/clpr/ClprConfigExchange.java` (the one-time allowed config exchange "kick")
- `docs/clpr/native-messaging-solo-integration-plan/` and `docs/clpr/NATIVE_MESSAGING_SOLO_PROGRESS.md`

Explicitly removed / avoided:

- No connector routing/transport logic changes (connectors remain paymasters only).
- No external bundle pump/relay tooling in active code paths.
