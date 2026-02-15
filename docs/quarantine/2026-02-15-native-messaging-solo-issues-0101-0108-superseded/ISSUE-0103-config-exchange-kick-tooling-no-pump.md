# ISSUE-0103: Config Exchange “Kick” Tooling (No Pump)

Status: Done (2026-02-14)

Implementation:

- `tools/clpr/ClprConfigExchange.java`
- Used by: `scripts/clpr/native-messaging-solo/run-e2e.sh`

## Goal

Create a minimal, reproducible way to perform the one-time config exchange between two SOLO deployments:

- Query `ClprLedgerConfiguration` (or its state proof) from the ledger that publicizes endpoints.
- Submit it to the other ledger.

This is the only allowed external step to initiate cross-ledger behavior.

## Requirements (Must Be True)

- The tool performs config exchange only.
- The tool does not ship message bundles or “pump” queue contents.
- The tool can run against SOLO deployments (not a HAPI test harness dependency).
- The tool is safe to re-run (idempotent or “no-op if already configured”).

## Constraints

- Prefer a small script/tool in `hedera-smart-contracts` over adding new consensus-node test-client mains.
- If reuse of `../hiero-consensus-node` test-client libraries is helpful, it must not require introducing a new pump framework.

## Tasks

- Decide the interface:
  - CLI script (Node or shell) in this repo.
  - Minimal Java CLI in a dedicated “tools” area in this repo (only if unavoidable).
- Implement query of the public ledger configuration state proof.
- Implement submission of the state proof to the other ledger.
- Add logging that clearly indicates:
  - Which ledger is “publicized”
  - Which ledger received the config
  - The endpoint list being installed
- Add a verification step:
  - Read back local CLPR config state from the receiver ledger to confirm it was installed.

## Acceptance Criteria

- Running the tool once results in the receiver ledger having the other ledger’s configuration installed.
- Running the tool again produces a clear “already configured” output (or performs a safe overwrite with identical results).
- No other external processes are required to start message passing after the exchange.
