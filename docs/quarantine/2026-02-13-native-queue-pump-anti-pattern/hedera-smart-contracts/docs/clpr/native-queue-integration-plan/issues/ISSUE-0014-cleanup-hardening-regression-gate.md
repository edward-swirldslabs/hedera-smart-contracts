# ISSUE-0014: Cleanup, Hardening, and Regression Gate

Status: Complete (2026-02-13)

Owner: Unassigned

Depends on:

- ISSUE-0013

## Completion Notes (2026-02-13)

- ISSUE-0013 smoke runner now passes end-to-end (see evidence bundle in `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/`).
- Temporary debug marker patterns removed across both repos.
- Evidence capture hardened to be best-effort and include consensus node file logs.
- Docs/runbooks updated to match implemented two-ledger Solo native-queue smoke workflow.
- Regression matrix updated and verified, including:
  - Solidity Hardhat + Foundry tests,
  - consensus unit tests (handler and system-contract translator tests),
  - HapiTest subprocess suite,
  - Solo smoke evidence bundle.
- Full run matrix and outputs are captured in:
  - `docs/clpr/native-queue-integration-plan/issue-0014-evidence.md`

## Goal

Remove temporary diagnostics, harden critical paths, and establish a stable regression gate for ongoing CLPR middleware/native-queue development.

## Scope

In scope:

- Remove temporary logging and temporary debug code.
- Keep only durable observability that is intentionally part of production-quality behavior.
- Add/update regression checklist and command matrix for Unit + HapiTest + Solo classes.
- Ensure docs reflect final bootstrap and failure-handling guidance.

Out of scope:

- New feature work.

## Requirements / References

- `docs/clpr/native-queue-debugging-playbook.md`
- `docs/clpr/native-queue-integration-plan/README.md`

## Acceptance Criteria

- No temporary debug marker remains unresolved.
- Regression command matrix is documented and reproducible.
- All agreed test layers pass before feature branch merge.
- Cleanup includes removal of prototype-only queue seeding and any stale diagnostic shortcuts added during integration.
- Final docs clearly distinguish known Solo operational limitations from product defects to prevent false regression alarms.
- Final docs are synchronized across `AGENTS.md` and `docs/clpr/README.md` for native-queue workflow and test entrypoints.
- Final issue docs and `execution-feedforward-log.md` reflect actual implemented behavior and deferred work boundaries (no stale acceptance criteria).
- Final docs explicitly capture the chosen middleware callback-authorization model and remove any temporary compatibility shims that are no longer needed.
- Final docs explicitly decide whether trusted callback caller remains part of the supported model or is removed after native callback stabilization.
- Temporary callback-debug markers are removed from native queue suites/handlers (for example `TEMP DEBUG` comments in callback path tests).
- Final docs include explicit mitigation/runbook guidance for intermittent subprocess startup race
  (`NoSuchFileException: build/<network>-test/node0/output/hgcaa.log`) and how to classify it as harness noise vs functional failure.
- Final regression gate permanently includes unit assertions for:
  - malformed route-header envelope decode mapping,
  - callback-failure status propagation,
  - queue metadata non-progression on callback failure.

## Milestone Exit Criteria (Dependency Gate)

- `rg \"TEMP-DEBUG\\(CLPR-NQ-\"` returns no matches in both repositories.
- `rg \"TEMP DEBUG|TEMP-DEBUG\"` returns no matches in native queue implementation/test files unless explicitly documented as accepted.
- Final regression report includes:
  - unit run summary,
  - HapiTest run summary,
  - Solo smoke evidence location.
- Regression command examples use quoted wildcard filters for `--tests` patterns to avoid shell-expansion false negatives.
- All native-queue docs in this repo are updated to reflect final workflow and known residual risks.
- `docs/clpr/README.md` includes an explicit "Known Limitations / Known Environment Noise" section.

## Tests

- Unit:
  - Full relevant unit suite for modified consensus modules and Solidity contracts.
- HapiTest:
  - Full interledger CLPR suite subset for native queue integration.
- Solo:
  - Final two-ledger smoke rerun with evidence archive.
  - One additional rerun from clean state to validate no hidden dependency on residual cluster state.

## Expected File Changes

In `../hiero-consensus-node`:

- Remove temporary log statements and debug-only helper paths.
- Update docs where temporary flags/notes were used.

In `hedera-smart-contracts`:

- Update docs and scripts to remove debug-only branches.
- Finalize `docs/clpr/README.md` entries for native queue flow.
- Synchronize guidance in `AGENTS.md` so future agents run the supported regression matrix and do not reintroduce deprecated paths.

## Risk Areas

- Forgetting to remove temporary instrumentation and leaving noise/debt.
- Regression drift if command matrix is not maintained.
