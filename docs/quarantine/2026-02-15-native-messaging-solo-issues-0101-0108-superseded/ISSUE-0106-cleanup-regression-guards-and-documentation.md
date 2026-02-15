# ISSUE-0106: Cleanup, Regression Guards, and Documentation

## Goal

After the corrected integration works in SOLO, ensure the repository state prevents regressions into the quarantined pump-based anti-pattern and that future contributors have clear, enforceable guidance.

## Requirements (Must Be True)

- The pump-based archive remains quarantined and clearly labeled as an anti-pattern.
- Active docs and scripts do not reference pump tooling.
- The “correct” integration path is documented end-to-end.

## Tasks

- Update `AGENTS.md`:
  - Point to the new issue set and the quarantine archive.
  - Add explicit “do not build a pump” guardrails.
  - Clarify that connectors are paymasters only and must not be modified for routing/transport.
- Add a small regression tripwire (choose one):
  - A documented `rg` check that must stay empty (for example: `rg -n \"PumpMain|pump bundle|external pump\"`).
  - A lightweight script that fails if pump keywords reappear outside `docs/quarantine/`.
- Consolidate evidence notes:
  - Keep only the minimal evidence required to prove SOLO correctness.
  - Keep the anti-pattern archive separate and clearly labeled.

## Acceptance Criteria

- A new developer can:
  - find the correct plan
  - follow it to reproduce SOLO success
  - understand what is forbidden and why
- The repository contains an explicit guard that makes it hard to accidentally reintroduce pump-based message movement.

## Resolution (Done)

Completed:

- Quarantined the pump-based approach under `docs/quarantine/` and added an explicit pointer doc:
  - `docs/clpr/NATIVE_QUEUE_INTEGRATION_QUARANTINED.md`
- Documented the correct SOLO-first native messaging path:
  - `docs/clpr/native-messaging-solo-integration-plan/README.md`
  - `docs/clpr/NATIVE_MESSAGING_SOLO_PROGRESS.md`
- Added explicit guardrails and diagnostic allowances in `AGENTS.md`.

Regression tripwire (run from `hedera-smart-contracts` repo root; should return no matches):

```bash
rg -n "ClprNativeQueuePumpMain|ClprNativeQueueBootstrapMain|native-queue" contracts scripts tools test --glob '!docs/quarantine/**'
```
