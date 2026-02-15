# CLPR Native Queue Integration Plan (No JSON-RPC Relay)

Status: Complete  
Last updated: 2026-02-13

## Purpose

This plan defines the implementation sequence for replacing the mocked/off-chain CLPR relaying path with the **native CLPR message queue** running inside `hiero-consensus-node`, while keeping Solidity middleware APIs stable and minimizing contract changes in this repository.

## Scope Decisions (Confirmed)

- Queue integration only at the system-contract boundary.
- Existing Solidity queue-facing API remains unchanged (`IClprQueue` methods).
- CLPR config exchange/state-proof mechanics remain native messaging-layer details and are not surfaced to Solidity.
- Source transaction path uses **HAPI gRPC gateway** (not JSON-RPC relay) for integration testing.
- Development mode/prototype behavior is acceptable for this phase.

## High-Level Target Flow

1. Source app sends through `ClprMiddleware.send(...)` on Ledger A.
2. Middleware calls queue contract API (`enqueueMessage` / `enqueueMessageResponse`) at a system-contract address.
3. Queue system contract translates ABI call into native CLPR queue mutation.
4. Native CLPR endpoint client exchanges bundles/config between ledgers.
5. Destination ledger invokes middleware + destination app.
6. Response returns through native queue path back to source middleware + source app.

## Repositories and Boundaries

- `hedera-smart-contracts` (this repo)
  - Solidity contracts, deployment/test harnesses, Solo orchestration scripts for middleware tests.
- `../hiero-consensus-node`
  - Native CLPR service, handlers, endpoint client, and the new queue system-contract bridge.
- No ODIN work in this phase.
- No JavaScript relay queue in this phase.

## References

- CLPR requirements/doc set in PR #23333:  
  `https://github.com/hiero-ledger/hiero-consensus-node/pull/23333`
- Local references in `../hiero-consensus-node`:
  - `hedera-node/docs/clpr/requirements/middleware-apis-and-semantics.md`
  - `hedera-node/docs/clpr/requirements/messaging-message-formats.md`
  - `hedera-node/docs/clpr/requirements/messaging-queue-and-bundles.md`
  - `hedera-node/docs/clpr/requirements/connectors-economics-and-behavior.md`
  - `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
  - `hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprShipOfTheseusSuite.java`
- Solo custom local build docs:
  - `https://solo.hiero.org/v0.55.0/examples/local-build-with-custom-config/`

## Baseline Snapshot

- `docs/clpr/native-queue-integration-plan/research-baseline-matrix.md`
- `docs/clpr/native-queue-integration-plan/prioritization-matrix.md`

## Issue Sequence

1. `issues/ISSUE-0001-research-baseline-inventory.md`
2. `issues/ISSUE-0002-custom-node-solo-rehearsal.md`
3. `issues/ISSUE-0003-native-config-exchange-baseline.md`
4. `issues/ISSUE-0004-system-contract-api-mapping-design.md`
5. `issues/ISSUE-0005-native-enqueue-operation-in-clpr-service.md`
6. `issues/ISSUE-0006-clpr-queue-system-contract-scaffolding.md` (recommended parallel track with ISSUE-0005)
7. `issues/ISSUE-0007-enqueue-message-request-path.md`
8. `issues/ISSUE-0008-enqueue-message-response-path.md`
9. `issues/ISSUE-0009-native-bundle-processing-to-middleware-callbacks.md`
10. `issues/ISSUE-0010-smart-contract-repo-minimal-integration.md`
11. `issues/ISSUE-0011-consensus-unit-test-battery.md`
12. `issues/ISSUE-0012-hapitest-e2e-battery.md`
13. `issues/ISSUE-0013-solo-two-ledger-smoke-and-evidence.md`
14. `issues/ISSUE-0014-cleanup-hardening-regression-gate.md`

Execution rule:

- A dependent issue starts only after the predecessor's `Milestone Exit Criteria (Dependency Gate)` is satisfied.

## Testing Strategy by Layer

- Unit
  - Java system-contract translators/calls/dispatch and CLPR handler logic.
  - Solidity unit tests only where contract behavior changes are unavoidable.
- HapiTest
  - Native CLPR config exchange and queue lifecycle validation.
  - Contract invocation path via HAPI Ethereum transactions.
- Solo
  - Two deployed ledgers, custom local consensus-node build, end-to-end middleware message flow.

## Definition of Done for This Plan

- Native queue system-contract path is functional for both queue API methods.
- Existing Solidity queue API is unchanged.
- Two-ledger CLPR middleware scenario executes through native queue transport.
- Reproducible runbook captures deployment, config exchange, invocation, and evidence.
- Temporary debug instrumentation is removed or explicitly tracked to ISSUE-0014.

## Current Plan Status

- Issues completed through Solo smoke + final regression gate:
  - `ISSUE-0013` complete (see `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/`).
  - `ISSUE-0014` complete (see `docs/clpr/native-queue-integration-plan/issue-0014-evidence.md`).
