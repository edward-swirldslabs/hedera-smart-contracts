# Active Issues (Native Messaging SOLO Integration, Refactor 0201+ and 0301+)

This directory is the active issue tracker for converging the current working SOLO demo into the production-intended
architecture described in:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`
- `docs/clpr/NATIVE_MESSAGING_SOLO_SCENARIO_REFERENCE.md`

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

- `ISSUE-0201-introduce-clpr-enqueue-message-transaction-and-handler.md` (Done)
- `ISSUE-0202-system-contract-dispatches-clpr-enqueue-message-no-direct-writes.md` (Done)
- `ISSUE-0203-add-0x16e-node-internal-delivery-entrypoints-packed-calls.md` (Done)
- `ISSUE-0204-refactor-bundle-handler-to-use-0x16e-delivery-remove-abi.md` (Done)
- `ISSUE-0205-switch-to-canonical-on-wire-envelope-bytes-remove-wrappers.md` (Done)
- `ISSUE-0206-remove-legacy-helpers-and-cross-store-plumbing.md` (Done)
- `ISSUE-0207-add-regression-tests-for-the-new-pipeline.md` (Done)
- `ISSUE-0208-final-hardening-3-clean-solo-runs-and-evidence.md` (Done)
- `ISSUE-0209-adversarial-code-review-and-final-polish.md` (Done)

## Issue List (Current Implementation Wave)

- `ISSUE-0301-extract-clpr-codecs-and-slim-delivery-calls.md` (Done)
- `ISSUE-0302-deduplicate-native-messaging-js-and-modularize-e2e-runner.md` (Done)
- `ISSUE-0303-standardize-clpr-observability-signals.md` (Done)
- `ISSUE-0304-enforce-mock-queue-middleware-only-boundary.md` (Done)
- `ISSUE-0305-add-internal-only-transaction-abuse-tests.md` (Done)
- `ISSUE-0306-add-clpr-system-contract-and-selector-coupling-tests.md` (Done)
- `ISSUE-0307-overhaul-clprmessagessuite-to-exercise-middleware-system-contract-flow.md` (Done)
- `ISSUE-0308-normalize-clpr-package-naming-symmetry.md` (Done)
- `ISSUE-0309-add-todo-for-metadata-cleanup-scaling.md` (Done)
- `ISSUE-0310-full-regression-and-solo-verification-gate.md` (Done)

## Issue List (Hybrid Funding-Recovery Wave)

- `ISSUE-0311-introduce-funding-control-types-and-hybrid-abi-surface.md` (Done)
- `ISSUE-0312-add-funding-aware-connector-base-and-migrate-mock.md` (Done)
- `ISSUE-0313-add-middleware-funding-transition-hook-and-control-message-sync.md` (Done)
- `ISSUE-0314-integrate-remote-cache-pre-reject-with-funding-epochs.md` (Done)
- `ISSUE-0315-expand-solo-scenario-with-topoff-and-redeplete-via-connector2.md` (Done)
- `ISSUE-0316-add-hardhat-and-foundry-tests-for-funding-transition-recovery.md` (Done)
- `ISSUE-0317-solo-verification-gate-for-topoff-recovery-redeplete.md` (In Progress)
- `ISSUE-0318-adversarial-review-security-and-after-action-analysis.md` (Planned)
