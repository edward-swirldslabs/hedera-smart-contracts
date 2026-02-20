# Native Messaging SOLO Integration Plan (ClprEndpointClient)

## Goal

Get CLPR message passing working between **two SOLO deployments** using the **existing native messaging layer** in `../hiero-consensus-node`, with **`ClprEndpointClient`** as the only cross-ledger transport.

Refactor reference architecture:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`
- `docs/clpr/NATIVE_MESSAGING_SOLO_SCENARIO_REFERENCE.md`

## Target Architecture (The Intended End State)

- An EVM transaction enqueues a CLPR message via a **Queue System Contract** (in `../hiero-consensus-node`).
- The consensus node converts that into a native queue operation.
- The existing native messaging layer bundles and ships messages using **`ClprEndpointClient`**.
- The destination ledger processes the bundle, produces responses, and the responses are shipped back the same way.
- There is **no external pump** that moves bundles between ledgers.

## Allowed External “Kick” (The Only One)

To start cross-ledger activity when CLPR is enabled:

- At least one ledger runs with endpoint advertisement enabled (for example `clpr.publicizeNetworkAddresses=true`).
- The other ledger is given that ledger’s `ClprLedgerConfiguration` state proof (the same conceptual step used by `ClprMessagesSuite`).
- After this one-time config exchange, message passing should be hands-off if the networking paths are viable.

## Hard Guardrails (Do Not Violate)

- Do not implement any external “pump”, “relay”, or “bundle forwarder” process as part of the integration.
- Do not add any new message transport layer. The transport must be `ClprEndpointClient`.
- Connectors are paymasters only. Do not change connector logic to add routing, transport, or delivery behavior.
- Avoid Solidity API changes (middleware/app/connector). If any change is unavoidable, it must be minimal and justified in writing.
- Keep `../hiero-consensus-node` changes minimal beyond the Queue System Contract and any unavoidable wiring to plug it into the existing messaging layer.
- SOLO is the primary target environment for validation. HAPI tests can be added later, after SOLO works.

## Quarantine / Anti-Pattern Archive

The previous “native queue integration” effort that used an external pump has been quarantined as an anti-pattern:

- Pointer: `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
- Archive root: `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/`

Use the archive only for historical reference. Do not resurrect its approach.

The prior SOLO integration issue set `ISSUE-0101..0108` is also archived as a superseded implementation guide:

- Archive: `docs/quarantine/2026-02-15-native-messaging-solo-issues-0101-0108-superseded/`
- Replacement: `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Issue Track (Active)

See `docs/clpr/native-messaging-solo-integration-plan/issues/README.md`.

Current implementation wave for adversarial-review remediations:

- `ISSUE-0301..ISSUE-0310`

## Operational Baseline

For repeatable agent execution and validation in this repository, use:

- `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md`

That playbook documents:

- artifact cleanup,
- deterministic rerun command-line,
- pass/fail and decode-health checks,
- common Solo failure signatures and fixes.
