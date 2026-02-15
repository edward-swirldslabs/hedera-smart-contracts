# ISSUE-0010: Minimal Smart-Contract Repo Integration Changes

Status: Completed (2026-02-12)

Owner: Unassigned

Depends on:

- ISSUE-0009

## Goal

Integrate with the native queue system-contract address while keeping Solidity CLPR APIs stable and limiting contract changes to only what is required for integration and traceability.

## Scope

In scope:

- Keep `IClprQueue` and middleware/public APIs unchanged.
- Parameterize queue address selection for deployment scripts/tests.
- Add minimal route-header population needed by native adapter envelopes (if not already present), without changing public interfaces.
- Align middleware callback authorization with native callback execution path (currently direct synthetic dispatch in ISSUE-0009), without introducing test-only bypass APIs.
- Add/adjust only essential tracing events or helper utilities needed for debugging.
- Ensure existing local unit tests still run against mock queue contracts.

Out of scope:

- Redesign of middleware/application contracts.
- Connector semantic changes unrelated to queue integration.

## Requirements / References

- `contracts/solidity/clpr/interfaces/IClprQueue.sol`
- `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
- Existing test/deploy scripts under `scripts/` and `test/`.

## Acceptance Criteria

- Contract deployment accepts and uses native queue system-contract address.
- Existing local (hardhat/foundry) tests remain green with mock queue path.
- Any added trace events are documented and intentionally minimal.
- No Solidity interface/API signature changes are introduced for CLPR middleware/queue contracts.
- Middleware callback authorization (`handleMessage`, `handleMessageResponse`) is compatible with native callback path and verified by tests, without weakening production authorization guarantees.
- Route-header bytes used by native adapter are deterministic and covered by unit tests.
- Production contracts do not include test-only wiring/functions (no peer-config helpers or test-only send entrypoints).
- `ClprMessage.middlewareMessage.data` is populated with ABI-encoded route header tuple exactly:
  - `(uint8 version, bytes32 remoteLedgerId, address sourceMiddleware, address destinationMiddleware)`
- Existing outbound path that currently emits empty `middlewareMessage.data` is replaced for native queue mode.
- `ClprMessageResponse.middlewareResponse.middlewareMessage.data` is populated with ABI-encoded route header tuple exactly:
  - `(uint8 version, bytes32 remoteLedgerId, address targetMiddleware)`
- Route-header payloads are produced by production middleware code paths (not test-only helper wiring).
- Native queue integration tests explicitly run with `contracts.systemContract.clprQueue.enabled=true`.

## Milestone Exit Criteria (Dependency Gate)

- A checked-in compatibility check documents ABI sameness for:
  - `IClprQueue`,
  - `IClprMiddleware`,
  - `IClprApplication`,
  - `IClprConnector`.
- Native queue address configuration is injectable via scripts without editing contract source.
- Callback-authorization decision is explicitly recorded (where checks happen and why) and linked from this issue.
- Any temporary diagnostic events are tagged per playbook and linked to cleanup issue.
- Any compatibility shim needed for tests lives in test harness contracts/scripts only, not production contracts.
- Route-header encoding unit tests assert field-by-field decode and hash stability for representative messages.

## Tests

- Unit:
- Foundry and Hardhat tests continue passing for local mock queue path.
- ABI compatibility check passes (pre/post integration comparison).
- Unit/integration tests assert callback authorization success path and fail path.
- HapiTest:
  - Contract deployment + invocation from HAPI helper scripts using native queue address.
- Solo:
  - Smoke deployment and one message flow in a custom Solo network.

## Expected File Changes

In `hedera-smart-contracts`:

- `contracts/solidity/clpr/middleware/ClprMiddleware.sol` (only if minor trace/event additions are needed)
- `scripts/clpr-smoke.js`
- `scripts/clpr-multi-source-smoke.js`
- New native-queue deploy/invoke script(s), e.g.:
  - `scripts/clpr-native-queue-smoke.js`
- `test/network/clpr/README.md` and/or new native-queue test README.

In `../hiero-consensus-node`:

- No mandatory changes in this issue.

## Risk Areas

- Accidentally coupling local tests to native queue behavior.
- Over-instrumentation in contracts that should stay production-clean.

## Completion Notes

- Implemented in `hedera-smart-contracts`:
  - `contracts/solidity/clpr/middleware/ClprMiddleware.sol`
  - `contracts/solidity/clpr/interfaces/IClprMiddleware.sol`
  - `contracts/solidity/clpr/mocks/MockClprConnector.sol`
  - `contracts/solidity/clpr/mocks/MockClprQueue.sol`
  - `test/solidity/clpr/clprMiddleware.js`
  - `test/foundry/ClprMiddleware.t.sol`
  - `test/network/clpr/clprBridgeRelayedQueue.js`
- Route-header behavior now comes from production middleware code paths:
  - request route header in `ClprMessage.middlewareMessage.data`
  - response route header in `ClprMessageResponse.middlewareResponse.middlewareMessage.data`
- Added explicit connector-to-remote-middleware configuration (`setConnectorRemoteMiddleware`) required for deterministic request route-header population.
- Added trusted callback caller support (`setTrustedCallbackCaller`) to align middleware callback authorization with native callback dispatch paths while retaining queue authorization as default.
- Evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0010-evidence.md`
