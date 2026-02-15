# Quarantine Archive: Native Queue “Pump” Anti-Pattern (2026-02-13)

## Why This Exists

This archive contains a prior integration attempt that validated “native queue” behavior by introducing an **external pump**
process to ship CLPR bundles between two ledgers.

That approach is explicitly **not** the intended architecture.

The intended architecture is:

- In-node native messaging layer
- `ClprEndpointClient` as the transport
- One-time config exchange “kick” only

Active work should follow:

- `docs/clpr/native-messaging-solo-integration-plan/README.md`

## What Is Archived Here

- `hedera-smart-contracts/`: prior issue plan (`ISSUE-0001..ISSUE-0014`), pump-based SOLO smoke scripts, and related docs
- `hiero-consensus-node/`: snapshots of pump/bootstrap tooling and suites, plus `git diff` snapshots for forensics

## How To Use This Archive

Use it only to understand what went wrong and what not to rebuild.

Do not revive or extend the pump scripts or “bundle forwarder” tooling as part of the corrected integration.
