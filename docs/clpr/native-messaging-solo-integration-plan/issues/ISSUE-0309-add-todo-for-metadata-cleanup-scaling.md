# ISSUE-0309: Add Explicit TODO for Metadata Cleanup Scaling in Queue Metadata Handler

Status: Done (2026-02-17)

## Objective

Capture the denied-for-now algorithmic improvement as explicit technical debt in code comments without implementing behavior changes.

This implements approved direction:
- `2.10 / 4.2.1` (denied for implementation now; add TODO comments only)

## Scope

Add clear TODO comments in:
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`

Comment must explain:
- current linear cleanup behavior
- potential scaling risk at high backlog
- deferred follow-up expected in production hardening phase

## Acceptance Criteria

1. TODO comment is precise and visible near cleanup loop logic.
2. No runtime behavior changes.
3. No test updates required unless formatting/lint requires.

## Out of Scope

- Implementing batching/chunking logic now.

## Implementation Log

- Added explicit deferred-scaling TODO comment at the cleanup loop in:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`
- Comment documents:
  - current O(n) per-message cleanup behavior
  - risk for large backlogs
  - deferred production-hardening expectation

Completion summary:
- Required TODO was added with no runtime behavior changes, matching approved scope.
