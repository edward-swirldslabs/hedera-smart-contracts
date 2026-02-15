# ISSUE-0101: Define Target State and Guardrails (Sign-off Required)

Status: Done (2026-02-14)

## Goal

Lock in the exact “correct” end state for this integration so future work stays aligned:

- Cross-ledger message transport is performed by `ClprEndpointClient`.
- The only external action required to initiate cross-ledger behavior is the one-time config exchange.
- Connectors remain paymasters only (no routing logic and no transport logic).
- Solidity API and connector/application code changes are avoided.

## Context

The prior approach validated “native queue” behaviors in SOLO by introducing an external pump process that shipped bundles between ledgers. That approach is explicitly out of scope and quarantined:

- `docs/quarantine/2026-02-13-native-queue-pump-anti-pattern/`

## Requirements (Must Be True)

- In a two-ledger SOLO environment, after the one-time config exchange, message traffic flows without any external “pump”.
- The medium of message passing between ledgers is the same native messaging mechanism used by `ClprMessagesSuite` in `../hiero-consensus-node`.
- Queue access from EVM occurs via a Queue System Contract (in `../hiero-consensus-node`) that bridges to native queue operations.

## Non-Goals (Must Not Happen)

- No new “message forwarder” infrastructure outside the node.
- No new alternate messaging client beside `ClprEndpointClient`.
- No connector changes for routing, delivery, or transport.
- No broad middleware rewrite to accommodate testing conveniences.

## Deliverables

- A short written “definition of done” that can be referenced by all subsequent issues.
- A short list of acceptable changes (and unacceptable changes) for each repo:
  - `hedera-smart-contracts`
  - `../hiero-consensus-node`
- Update `AGENTS.md` to make the guardrails unmissable and to point to the quarantine archive.

## Acceptance Criteria

- A reviewer can read the deliverables and confidently decide whether a proposed change violates the target architecture.
- Every later issue references these guardrails and cannot be interpreted as authorizing a pump.
