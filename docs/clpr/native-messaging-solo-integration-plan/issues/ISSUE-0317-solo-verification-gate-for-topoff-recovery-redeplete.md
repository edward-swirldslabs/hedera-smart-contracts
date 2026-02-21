# ISSUE-0317: SOLO Verification Gate for Top-Off Recovery and Re-Deplete Flow

Status: In Progress

## Objective

Run a final SOLO verification gate for the hybrid funding recovery feature and collect reproducible evidence.

## Why

The target behavior is an end-to-end interledger behavior. The gate confirms full pipeline correctness in the real two-ledger setup.

## Scope

### A. Repeatable run profile

Validate with current supported profile used for CLPR native messaging:

- two SOLO ledgers
- native messaging transport (no external pump)
- scenario includes top-off and second depletion cycle

### B. Evidence capture

For each run capture:

- command line
- timestamps
- run artifact directory
- pass/fail markers
- key state snapshots (connector balances, remote status cache, attempt/reject counters)

### C. Multi-run stability

Perform at least 3 clean runs of the updated scenario and record results.

## Impacted Files (Expected)

- `docs/clpr/native-messaging-solo-integration-plan/issues/ISSUE-0317-*.md` (implementation log)
- `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md` (if commands change)
- `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md` (if new observability checkpoints are added)

## Acceptance Criteria

1. 3/3 SOLO runs pass with top-off then re-depletion behavior.
2. Artifacts clearly show:
   - top-off action
   - one connector2-success post top-off
   - one connector2-pre-reject after re-depletion
3. No manual reset/redeploy needed between those post-top-off attempts.

## Out of Scope

- New feature work.
- Production hardening beyond the agreed prototype guardrails.

## Implementation Log

- Run attempt #1:
  - Command:
    - `CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build`
  - Artifact dir:
    - `artifacts/clpr-native-messaging-solo/20260218T125615Z`
  - Result:
    - failed before config-exchange/scenario execution
  - Root cause identified:
    - `run-e2e.sh` intended to default `SOLO_ENABLE_BLOCK_NODE=true`, but `lib.sh` pre-initialized it to `false`.
    - This caused early runner failure when tailer/BN assumptions were checked.
- Fix applied:
  - `scripts/clpr/native-messaging-solo/run-e2e.sh` now detects caller-provided env overrides with `printenv`
    and applies runner defaults for `SOLO_ENABLE_BLOCK_NODE` / `SOLO_ENABLE_MIRROR` correctly.
- Run attempt #2:
  - Command:
    - `CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true SOLO_ENABLE_BLOCK_NODE=false SOLO_ENABLE_MIRROR=false CLPR_ENABLE_BLOCK_STREAM_TAILER=false bash scripts/clpr/native-messaging-solo/run-e2e.sh --no-build --keep`
  - Result:
    - manually interrupted during redeploy to avoid long setup cycle while this issue wave was being closed.
  - Cleanup:
    - `CLPR_SOLO_HOME=$HOME/.solo-integration SOLO_SKIP_CLUSTER_SETUP=true bash scripts/clpr/native-messaging-solo/two-network-down.sh`
    - pass (environment cleaned)
- Next verification step:
  - execute full 3-run gate after this change set is staged and reviewed, using the updated runner defaults and capture
    all three run directories.

Completion summary:
- Verification gate is partially complete: runner default bug fixed and documented, final 3/3 passing run evidence pending.
