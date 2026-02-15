# ISSUE-0208: Final Hardening (3 Clean SOLO Runs + Evidence)

Status: Planned

Primary design reference:

- `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

## Goal

Prove the corrected architecture is stable in the primary target environment (SOLO) and leave clear evidence:

- Run the full two-ledger SOLO E2E scenario three times successfully, with no manual intervention.
- Capture evidence for each run (logs, manifests, config exchange output, scenario results).
- Update the docs to reflect the final architecture and operational tutorial.

## Behavioral Change (What Users Notice)

- No behavior change intended.
- This is a stability validation and documentation hardening pass.

## Guardrails

- Remove any temporary diagnostic logs or Solidity `emit` events that were added for development.
- Keep the code diff minimal and production-intended.

## Files Impacted

This repo (`hedera-smart-contracts`):

- `docs/clpr/NATIVE_MESSAGING_SOLO_AFTER_ACTION_REPORT.md` (update)
- `docs/clpr/NATIVE_MESSAGING_SOLO_PROGRESS.md` (final update or close out)
- `docs/clpr/native-messaging-solo-integration-plan/README.md` (ensure it matches final behavior)
- Optional: `scripts/clpr/native-messaging-solo/*` (only if a proven reliability improvement is needed)

Consensus node (`../hiero-consensus-node`):

- No intended functional changes.
- Only remove temporary diagnostic logs or dead code if any remain.

## Implementation Tasks

1. Audit both repos for temporary diagnostics:
2. Remove log lines with comments indicating they were temporary.
3. Remove temporary Solidity `emit` events if any were added.
4. Run the scenario three times:
5. `bash scripts/clpr/native-messaging-solo/run-e2e.sh`
6. Repeat until three runs succeed consecutively without edits.
7. Save run directories and record their paths in the after action report.
8. Update documentation explaining:
9. The final call flow across bundle handler, `0x16e`, and `clprEnqueueMessage`.
10. How to run the E2E script and interpret evidence outputs.

## Test Plan

Baseline:

- `npx hardhat compile`

SOLO stability:

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`
- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`
- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

## Acceptance Criteria

Evidence:

- Three consecutive SOLO E2E runs succeed.
- Each run produced an evidence directory under `artifacts/clpr-native-messaging-solo/` (or the current configured artifact root).

Docs:

- The after action report and plan docs describe the final architecture accurately.
- The tutorial is accurate and copy-paste runnable.

## Implementation Log (Append As You Work)

- Notes:
- Commands run:
- Evidence directories:
- Completion summary:

