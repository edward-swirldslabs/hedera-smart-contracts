# ISSUE-0315: Expand SOLO Scenario with Top-Off and Re-Deplete via Connector 2

Status: Done (2026-02-18)

## Objective

Extend the scenario runner to demonstrate live recovery and re-depletion without resetting ledgers:

- top up destination connector2
- run two more source sends
- first succeeds via connector2
- next fails over because connector2 drops below threshold again

## Why

This validates the target demo behavior while keeping networks continuously running.

## Scope

### A. Scenario flow extension

Modify:

- `scripts/clpr/native-messaging-solo/run-scenario.js`

Add phase after initial connector2 depletion and failover demonstration:

1. Fund destination connector2 with only enough for 1-2 charges.
2. Trigger funding transition propagation (through base connector + middleware hook path).
3. Invoke source app twice:
   - invocation N: connector2 should be selected and succeed
   - invocation N+1: connector2 should be pre-rejected again, connector3 succeeds

### B. Assertions

Add explicit assertions for:

- connector authorize counts (connector2 increments once after top-off then stops again)
- connector2 destination balance at/under threshold after the second post-top-off attempt
- source middleware remote status reflects underfunded again

### C. Evidence output

Update deployment/scenario artifact output to include phase markers for:

- top-off action
- post-top-off send #1
- post-top-off send #2

## Impacted Files (Expected)

- `scripts/clpr/native-messaging-solo/run-scenario.js`
- possibly `scripts/clpr/native-messaging-solo/run-e2e.sh` artifact summaries
- `docs/clpr/*` scenario docs if command outputs changed

## Acceptance Criteria

1. No ledger reset is needed to observe recovery then re-depletion.
2. Post-top-off first send succeeds through connector2 path.
3. Post-top-off second send sees connector2 pre-rejected due to re-depletion.
4. Scenario prints/records clear phase evidence in artifact logs.

## Out of Scope

- Mirror/block-node infrastructure changes.
- External pump/poller components.

## Implementation Log

- Updated `scripts/clpr/native-messaging-solo/run-scenario.js`:
  - scenario now runs 6 source sends instead of 4
  - added destination connector2 top-off action (`50` WETH) using funding-aware `depositToken(...)`
  - added remote funding epoch wait helper (`waitForRemoteFundingEpoch(...)`)
  - added assertions for post-topoff reopen and subsequent re-deplete behavior
  - added scenario phase markers (`[SCENARIO] ...`) for artifact traceability
  - configured destination middleware remote middleware mapping for control update publication
- Updated script docs and runner text:
  - `scripts/clpr/README.md`
  - `scripts/clpr/native-messaging-solo/run-e2e.sh` usage text
- Static validation:
  - `node --check scripts/clpr/native-messaging-solo/run-scenario.js` (pass)
  - `bash -n scripts/clpr/native-messaging-solo/run-e2e.sh` (pass)

Completion summary:
- SOLO scenario script now demonstrates the requested top-off -> one connector2 success -> connector2 re-deplete failover cycle without resetting ledgers.
