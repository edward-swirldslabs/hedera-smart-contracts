# ISSUE-0001: Research Spike and Baseline Inventory

Status: Done

Owner: Codex

Depends on:

- (none)

## Goal

Produce a reproducible baseline that documents what already works in `clpr-message-queue-integration-branch`, what is stubbed, and what is missing for Solidity middleware integration through the native CLPR queue.

## Scope

In scope:

- Confirm current CLPR queue/config behavior from code and existing tests.
- Record exact API/handler coverage for queue and config transactions/queries.
- Inventory current test-only shortcuts that must be removed or replaced.
- Publish a baseline matrix of "available now" vs "must build".

Out of scope:

- Any runtime environment mutation.
- Any functional code changes.

## Requirements / References

- `../hiero-consensus-node/hedera-node/docs/clpr/requirements/*.md`
- `../hiero-consensus-node/hedera-node/docs/clpr/implementation/iteration-plan.md`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprMessagesSuite.java`
- `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/suites/interledger/ClprShipOfTheseusSuite.java`

## Acceptance Criteria

- A checked-in baseline document maps each required behavior to current implementation status.
- The document explicitly identifies:
  - where queue messages are currently seeded/generated,
  - where middleware callbacks are absent,
  - which handlers/system-contract hooks exist vs missing.
- Risks and dependencies for downstream issues are captured.
- Baseline matrix includes commit SHA references for both repositories used during the analysis.

## Milestone Exit Criteria (Dependency Gate)

- `research-baseline-matrix.md` includes:
  - behavior-by-behavior status (`implemented`, `partial`, `missing`),
  - exact code locations for each status,
  - open decision list that ISSUE-0004 must resolve.
- A short "blocked-by" list is present for ISSUE-0002 through ISSUE-0006.

## Tests

- Unit:
  - N/A (research-only), but all assertions in the baseline matrix must be source-linked to code paths.
- HapiTest:
  - N/A in this issue.
- Solo:
  - N/A in this issue.

## Expected File Changes

In `hedera-smart-contracts`:

- `docs/clpr/native-queue-integration-plan/research-baseline-matrix.md` (new)

In `../hiero-consensus-node`:

- No code changes expected.

## Risk Areas

- False assumptions from stale docs instead of source code.
- Missing hidden test-only behavior that later blocks integration.

## Completion Notes

- Completed on 2026-02-12.
- Output artifact:
  - `docs/clpr/native-queue-integration-plan/research-baseline-matrix.md`
