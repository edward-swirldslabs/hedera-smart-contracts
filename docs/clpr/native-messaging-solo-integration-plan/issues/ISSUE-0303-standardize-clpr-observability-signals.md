# ISSUE-0303: Standardize CLPR Observability Signals Across Java/EVM Boundaries

Status: Done (2026-02-17)

## Objective

Standardize temporary prototype observability across CLPR components with consistent structured log/event semantics.

This implements approved proposal items:
- `2.3 / 1.2.3 / 5.2.3 / 5.4`

## Why

The demo requires traceability across boundary crossings. Logs/events need consistent component/stage naming and discoverability.

## Scope

### Consensus-node logging standardization

Ensure boundary components use:
- prefix `CLPR_OBS|`
- keys `component=...|stage=...` plus context keys
- adjacent temporary marker comment:
  - `// TEMP-OBSERVABILITY (delete before production): ...`

Target classes include:
- `ClprQueueEnqueueMessageCall`
- `ClprQueueEnqueueMessageResponseCall`
- `ClprQueueDeliverInboundMessageCall`
- `ClprQueueDeliverInboundMessageReplyCall`
- `ClprMessagePayloadHandler`
- `ClprEnqueueMessageHandler`
- `ClprProcessMessageBundleHandler`
- `ClprGetMessagesHandler`
- `ClprGetMessageQueueMetadataHandler`

### Smart-contract events

- Confirm source app / middleware / connector / queue mock events cover all boundary transitions required by demo observability.
- Add minimal temporary events only if a boundary remains opaque.

### Documentation

- Update `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md` with final component/stage list and where to find each signal.

## Acceptance Criteria

1. One successful run produces end-to-end stage traceability across:
   - EVM events
   - CLPR Java boundary logs
   - scenario/evidence logs
2. Every new diagnostic log/event has explicit temporary marker comment.
3. Observability docs map each stage to source file and log/event channel.

## Out of Scope

- Permanent production telemetry system design.
- Metrics backend integration.

## Implementation Log

- Added standardized `CLPR_OBS|component=...|stage=...` temporary trace logs across CLPR Java boundary components in
  `../hiero-consensus-node`, including queue system-contract calls, payload/bundle handlers, enqueue handler, and query handlers.
- All added diagnostic logs include adjacent temporary marker comments:
  - `// TEMP-OBSERVABILITY (delete before production): ...`
- Updated observability documentation:
  - `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md`
- Build/tests validation completed after logging changes:
  - `./gradlew :app:compileJava --no-daemon` (pass)
  - targeted CLPR test slices remained green (pass)

Completion summary:
- Observability style is now consistent across CLPR Java boundary components and documented for demo operations.
