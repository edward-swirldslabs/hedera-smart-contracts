# ISSUE-0108: Pare Down `../hiero-consensus-node` Changes to the Minimum

## Goal

Leave only the minimal consensus-node changes required to:

- Provide the Queue System Contract as the EVM bridge to native queue operations.
- Reuse the existing native messaging layer and `ClprEndpointClient` for cross-ledger transport.

Remove or quarantine anything that implemented an external pump, test-only shipping infrastructure, or alternate transport mechanisms.

## Requirements (Must Be True)

- Cross-ledger bundle shipping uses `ClprEndpointClient`.
- No external pump tools or suite-only bundle forwarders exist in active code paths.
- The node changes remain minimal beyond:
  - queue system contract implementation
  - wiring and configuration needed to enable it
  - any unavoidable compatibility fixes to connect the system contract to the existing queue and messaging layer

## Tasks

- Review `git diff` and identify which changes are strictly required for:
  - system contract registration and method translation
  - queue operations wiring used by existing messaging handlers
  - SOLO runtime correctness
- Remove or revert any modifications that exist only to support:
  - external pump scripts
  - test-client “mains” that ship bundles
  - alternate message passing infrastructure outside `ClprEndpointClient`
- Confirm `ClprMessagesSuite` remains the canonical example for the one-time config exchange step.
- Ensure the correct behavior can run in SOLO without requiring HAPI suite execution.

## Acceptance Criteria

- The consensus-node working tree contains no “pump” tooling outside `docs/quarantine/...`.
- A reviewer can point to the single cross-ledger transport mechanism (`ClprEndpointClient`) and verify it is the one being used at runtime.

## Resolution (Done)

Active consensus-node changes were pared down to the minimal set needed to:

- Implement the CLPR queue system contract at `0x16e` as an adapter from EVM `enqueueMessage(...)` calls into native CLPR
  queue state updates.
- Keep cross-ledger transport exclusively in the existing native messaging layer (`ClprEndpointClient`).
- Process inbound bundles by dispatching synthetic contract calls to middleware callback entrypoints and enqueueing
  responses back to the originating ledger, with no off-node “pump”.

Key change buckets (with representative files):

- Queue system contract + translators:
  - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../ClprQueueSystemContract.java`
  - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../ClprQueueTranslatorsModule.java`
  - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/.../systemcontracts/clpr/**`
  - Config gate: `../hiero-consensus-node/hedera-node/hedera-config/.../ContractsConfig.java` (`systemContract.clprQueue.enabled`)
- Native queue mutation helper (shared by system contract + handlers):
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/.../ClprQueueOperations.java`
- Inbound bundle processing now bridges to EVM middleware callbacks:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/.../handlers/ClprProcessMessageBundleHandler.java`
  - Decodes request/response envelopes, dispatches `handleMessage(...)` / `handleMessageResponse(...)`, and enqueues reply
    payloads for the originating ledger via `ClprQueueOperations`.
- SOLO bootstrap correctness (local configuration and publicized endpoints):
  - `../hiero-consensus-node/hedera-node/hedera-app/.../SystemTransactions.java`
  - Ensures endpoints are available (derives from roster gossip endpoints when node store lacks service endpoints) and
    normalizes dev-mode ledger id length for stability in SOLO.
- SOLO payer + endpoint resolution robustness:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/.../ClprEndpointClient.java`
  - Uses a funded payer in dev-mode (treasury) for CLPR HAPI transactions in SOLO; resolves domain-name endpoints.
- Minimal, production-quality wiring:
  - `../hiero-consensus-node/hedera-node/hedera-app/.../WritableStoreFactory.java` and native ops interfaces:
    allow-listed cross-service writable access so the system contract can update CLPR queue stores without broadening
    access patterns beyond what is required.

Explicitly removed / avoided:

- No new external “pump” binaries/tools in the active code path.
- No alternate cross-ledger transport layer beyond `ClprEndpointClient`.
