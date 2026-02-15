# ISSUE-0105: SOLO E2E Native Messaging (No Pump)

Status: Done (2026-02-14)

Primary runner:

- `bash scripts/clpr/native-messaging-solo/run-e2e.sh`

Example evidence bundle:

- `artifacts/clpr-native-messaging-solo/20260214T005029Z/` (contains `Scenario passed` in `scenario.log`)

## Goal

Demonstrate end-to-end cross-ledger message passing in **two SOLO deployments** using:

- Queue System Contract (EVM <-> native queue bridge)
- Existing native messaging layer
- `ClprEndpointClient` (transport)

No external message pump is allowed.

## Required Sequence (High Level)

1. Two SOLO deployments are running and mutually reachable on the advertised CLPR endpoints.
2. Perform the one-time config exchange “kick”.
3. On the source ledger, submit an EVM transaction that enqueues a CLPR message request through the queue system contract.
4. Verify the source ledger ships the request via `ClprEndpointClient` without external help.
5. Verify the destination ledger receives and processes the request and produces a response.
6. Verify the response is shipped back and becomes observable to the source ledger’s EVM/middleware.

## Constraints

- Do not change connectors.
- Avoid changes to the Solidity middleware and application APIs.
- If a harness contract is required for observability, keep it minimal and do not change the public CLPR APIs.

## Tasks

- Define the minimal “smoke” transaction:
  - what contract is called
  - what payload is sent
  - what on-chain state change is expected on the destination
- Add evidence collection:
  - node logs for endpoint client send/receive
  - any queue-size / metadata logs that confirm movement
  - contract state verification on destination and/or mirror observations
- Ensure the run is reproducible:
  - document exact CLI commands and required env vars
  - document expected outputs and timeouts

## Acceptance Criteria

- A single scripted run can:
  - perform the config exchange kick
  - submit the source enqueue transaction
  - observe the destination processing
  - observe the response arriving back at source
- The run uses no external pump and no “bundle forwarder” tool.
