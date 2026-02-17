# ISSUE-0307: Overhaul ClprMessagesSuite to Exercise Middleware/System-Contract End-to-End Flow

Status: Done (2026-02-17)

## Objective

Repurpose `ClprMessagesSuite` so its primary assertion is the real CLPR path:

`Source App -> Middleware -> Queue System Contract (0x16e) -> Native queue dispatch -> ClprEndpointClient transport -> Bundle processing -> Payload handler -> Middleware callback -> Destination App -> Response path back to source`

This implements approved proposal item:
- `2.8 / 2.3` (HapiTest portion)

## Why

The prior suite shape proved ledger configuration exchange and bundle movement, but did not reliably prove the system-contract translator path that now defines the intended architecture. The suite must become the canonical subprocess proof for middleware+system-contract integration across two ledgers.

## Scope

### A. Test flow redesign in consensus-node

Primary file:
- `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`

Required behavior:
- Keep two-network setup and endpoint publication/query flow.
- Deploy on both ledgers:
  - `ClprMiddleware`
  - `EchoApplication` (destination)
  - `SourceApplication` (source)
  - `MockClprConnector` pairs (always-authorize behavior for this suite)
- Register connector configuration and app bindings through middleware APIs.
- Trigger source sends from Hapi operations.
- Assert destination app receives requests (request counter increments).
- Assert source app receives responses (response counter / last-response assertions).

### B. Ensure the suite hits system-contract/native translation boundaries

The suite must exercise:
- queue API calls from middleware into system contract
- translation to native CLPR payload transactions
- native handler processing and bundle delivery callbacks
- translation back into middleware callback API on destination

This must use existing native messaging (`ClprEndpointClient`) with no external pump/relay.

### C. Supporting assets and diagnostics

Allowed additions/updates (test-clients only):
- contract resources under `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/`
- helper methods in suite for deployment/config steps
- temporary observability logs with clear cleanup comments

## Impacted Files (Expected)

- `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/ClprMiddleware/*`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/SourceApplication/*`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/EchoApplication/*`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/MockClprConnector/*`

## Acceptance Criteria

1. `ClprMessagesSuite` passes in subprocess mode and proves request+response round-trip between two ledgers.
2. Assertions prove destination app execution and source response receipt, not just transaction success receipts.
3. Suite uses native messaging path via `ClprEndpointClient`; no external pump/forwarder introduced.
4. Temporary diagnostics (if added) are clearly marked as temporary and removable.
5. Existing non-CLPR subprocess suites remain unaffected.

## Out of Scope

- Production-grade connector economics (always-authorize connector behavior is sufficient here).
- Ledger routing expansion beyond connector-defined point-to-point behavior.
- New transport protocols or alternate queue mechanisms.

## Implementation Log

- Addressing/call-target fixes applied in:
  - `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
- Key corrections made:
  - Connector admin calls now target connector `ContractID` directly (not `evm_address` target form), avoiding no-op success calls to non-contract addresses.
  - Solidity address parameters passed to middleware/app registration now use `asAddress(ContractID)` (long-zero EVM address format expected by contract calls in this test stack).
  - `getResponse(uint64)` query parameters now pass `BigInteger` values (`BigInteger.valueOf(appMsgId)`), matching ABI uint64 encoding expectations.
- Observability snapshots now confirm connector state transitions:
  - `pre_set_remote_middleware_connector_snapshot` shows connector `exists=true`.
  - `post_source_deploy_connector_snapshot` shows `remoteMiddleware` populated and connector enabled.
- Validation run:
  - `./gradlew :test-clients:testSubprocess --tests 'com.hedera.services.bdd.suites.interledger.ClprMessagesSuite' --no-daemon --console=plain`
  - Result: PASS (`1 passing`) with `BUILD SUCCESSFUL`.

Completion summary:
- `ClprMessagesSuite` now exercises the intended middleware/system-contract/native-queue round-trip path and passes with request/response assertions.
