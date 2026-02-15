# Active Issues (Native Messaging SOLO Integration, Refactor 0201+)

This directory is the active issue tracker for converging the current working SOLO demo into the production-intended
architecture described in:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Guardrails (Non-Negotiable)

- Do not add any external pump/relay/forwarder for bundles.
- Do not add any new messaging transport. Cross-ledger transport must remain `ClprEndpointClient`.
- Do not add new third-party dependencies to any CLPR module (especially `hiero-clpr-interledger-service-impl`).
- Keep ABI artifacts and ABI encoding/decoding out of CLPR messaging handlers.
- Any outbound queue append must be transaction-correlated via a dedicated handler (`clprEnqueueMessage`), not direct store writes.
- Preserve the existing Solidity middleware/app/connector APIs if at all possible.

Exit criteria per issue:

- All new tests pass.
- All modified tests pass.
- If any runtime code changed in either repo, `bash scripts/clpr/native-messaging-solo/run-e2e.sh` passes.

## Workflow Expectations For Implementers

- Each issue file contains an **Implementation Log** section at the end.
- The implementing agent must append notes and a completion summary there before moving to the next issue.
- If temporary diagnostic logs or Solidity `emit` events are added, they must have adjacent comments clearly marking them as temporary.
- Temporary diagnostics must be removed before the final hardening issue.

## Archived Issue Sets (Historical Only)

- Prior issue set `ISSUE-0101..0108` (superseded by the refactor proposal): `docs/quarantine/2026-02-15-native-messaging-solo-issues-0101-0108-superseded/`
- Prior pump-based plan and scripts (anti-pattern archive): `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md` and `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/`

## Issue List (Active)

- `ISSUE-0201-introduce-clpr-enqueue-message-transaction-and-handler.md` (Planned)
- `ISSUE-0202-system-contract-dispatches-clpr-enqueue-message-no-direct-writes.md` (Planned)
- `ISSUE-0203-add-0x16e-node-internal-delivery-entrypoints-packed-calls.md` (Planned)
- `ISSUE-0204-refactor-bundle-handler-to-use-0x16e-delivery-remove-abi.md` (Planned)
- `ISSUE-0205-switch-to-canonical-on-wire-envelope-bytes-remove-wrappers.md` (Planned)
- `ISSUE-0206-remove-legacy-helpers-and-cross-store-plumbing.md` (Planned)
- `ISSUE-0207-add-regression-tests-for-the-new-pipeline.md` (Planned)
- `ISSUE-0208-final-hardening-3-clean-solo-runs-and-evidence.md` (Planned)
