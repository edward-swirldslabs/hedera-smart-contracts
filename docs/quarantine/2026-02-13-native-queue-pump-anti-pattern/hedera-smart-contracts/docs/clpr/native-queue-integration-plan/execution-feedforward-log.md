# Native Queue Plan Execution Feed-Forward Log

Purpose: capture implementation-time observations that should improve remaining issue descriptions and completion criteria.

## ISSUE-0001

Status: Completed (2026-02-12)

What was learned:

- CLPR queue and bundle handlers exist, but core paths still include prototype shortcuts (`TODO` markers) in message seeding and reply handling.
- There is no CLPR-specific system-contract package in consensus node EVM service yet.
- Queue and config functionality dispatch/permission wiring already exists for current CLPR transaction/query surface.

Pay attention in downstream issues:

- ISSUE-0002/0003:
  - Ensure runbooks explicitly handle bootstrap ordering and evidence collection; this is a known timing risk area.
- ISSUE-0004:
  - Adapter design must explicitly choose payload strategy (opaque bytes vs field mapping) and lock it before coding.
- ISSUE-0005:
  - Remove/replace test-seeding path as part of native enqueue implementation to avoid false-positive queue behavior.
- ISSUE-0006:
  - Address/selector mapping needs collision checks against existing system contracts.
- ISSUE-0009:
  - Callback semantics are the highest risk and must include deterministic failure handling to preserve queue integrity.

Refinement actions applied after ISSUE-0001:

- Added stronger milestone gate criteria and negative-path test requirements across remaining issues.
- Added explicit prioritization and critical-path guidance in:
  - `docs/clpr/native-queue-integration-plan/prioritization-matrix.md`


Post-ISSUE-0001 refine pass applied:

- Added CLPR-enabled config checks and feed-forward logging requirements to ISSUE-0002.
- Added directional queue metadata assertions to ISSUE-0003.
- Strengthened ISSUE-0004 to include middleware target-address encoding decision.
- Strengthened ISSUE-0005 to explicitly remove test seeding path in `ClprUpdateMessageQueueMetadataHandler`.
- Added stale-bundle pre-callback assertions to ISSUE-0009.
- Clarified HAPI-only requirement in ISSUE-0012 and ISSUE-0013.
- Added prioritization and critical-path guidance in `prioritization-matrix.md` and updated sequence docs.

## ISSUE-0002

Status: Completed (2026-02-12)

What was learned:

- Dual local-build Solo deployments can be created repeatably with deterministic naming and scripted preflight/health checks.
- Solo v0.55.0 shows a recurring start-path failure signature in this environment:
  - `set gRPC Web endpoint` fails with `INVALID_NODE_ID`.
  - Consensus runtime can still be healthy (pod running, JVM active, HAPI service present).
- In local-build dev mode, `solo consensus node stop` may update control-plane phase without immediately terminating pod/JVM runtime.

Pay attention in downstream issues:

- ISSUE-0003:
  - Do not gate config-exchange baseline on relay/gRPC-web side effects.
  - Use direct HAPI evidence and queue metadata assertions as truth source.
- ISSUE-0012/0013:
  - For Solo smoke gates, treat runtime health + functional assertions as primary pass criteria.
  - Record control-plane phase separately as diagnostic evidence, not as sole health criterion.
- ISSUE-0014:
  - Include explicit cleanup guidance for known Solo control-plane/runtime drift.

Refinement actions applied after ISSUE-0002:

- Updated `solo-custom-build-runbook.md` with known failure signatures and phase-based restart validation guidance.
- Updated `solo-two-network-status.sh` to surface control-plane phase and warn on phase/runtime drift.

## ISSUE-0003

Status: Completed (2026-02-12)

What was learned:

- The correct focused baseline execution path is:
  - `:test-clients:testSubprocess --tests com.hedera.services.bdd.suites.interledger.ClprMessagesSuite --rerun-tasks`
- `:test-clients:hapiTestMultiNetwork` does not accept `--tests` filtering from CLI.
- `ClprShipOfTheseusSuite` is not suitable for this fast baseline gate due runtime/complexity.
- Baseline logs repeatedly show:
  - publish/pull attempts and completions,
  - queue metadata sent-id progression (`5 -> 10 -> 15 -> 20`),
  - stale bundle detection on already-processed ranges.
- Intermittent `INVALID_TRANSACTION` pre-check events from `ClprSetLedgerConfigurationHandler` occur during endpoint publish attempts in dev mode, yet runs still converge and pass.

Pay attention in downstream issues:

- ISSUE-0012:
  - Keep fast feedback loops anchored on `testSubprocess` and focused suite targets.
  - Avoid assuming `hapiTestMultiNetwork` supports per-suite CLI filtering.
- ISSUE-0013:
  - Evidence capture should include both pass markers and intermediate queue progression checkpoints.
  - Separate expected/non-gating dev-mode warnings from true functional failures.
- ISSUE-0014:
  - Document and harden criteria for classifying `INVALID_TRANSACTION` events as expected vs regression.

Refinement actions applied after ISSUE-0003:

- Updated ISSUE-0003 acceptance/gate language to allow deterministic checkpoint logs when tx ids are not surfaced.
- Added completed evidence document:
  - `docs/clpr/native-queue-integration-plan/config-exchange-baseline-evidence.md`

## ISSUE-0004

Status: Completed (2026-02-12)

What was learned:

- Queue adapter design must explicitly carry routing metadata in opaque payload envelopes because queue state is keyed by remote ledger id while Solidity queue APIs do not expose a dedicated routing parameter.
- `0x16D` is reserved for hooks and cannot be used for CLPR queue system-contract mapping.
- The stable selector values for current Solidity tuple signatures are:
  - `enqueueMessage` -> `0x8cfaaa60`
  - `enqueueMessageResponse` -> `0xb26aa82b`
- Middleware compatibility depends on preserving failure-as-exception semantics; returning sentinel values instead of reverting would bypass current Solidity `try/catch` control flow.

Pay attention in downstream issues:

- ISSUE-0005:
  - Implement native enqueue with envelope + correlation support (request and response).
  - Remove test-seeding path from `ClprUpdateMessageQueueMetadataHandler`.
- ISSUE-0006:
  - Wire queue system contract at `0x16E` with explicit collision tests and feature-gate hook.
- ISSUE-0007/0008:
  - Reuse locked selectors and golden calldata fixtures from `queue-adapter-design-notes.md`.
- ISSUE-0009:
  - Callback routing must consume envelope/correlation metadata and reject stale bundles before callback.
- ISSUE-0010:
  - Minimal Solidity integration may need route-header population while keeping public APIs unchanged.

Refinement actions applied after ISSUE-0004:

- Added accepted design artifacts:
  - `../hiero-consensus-node/hedera-node/docs/clpr/adrs/ADR-0001-clpr-queue-system-contract-api-mapping.md`
  - `../hiero-consensus-node/hedera-node/docs/clpr/implementation/queue-adapter-integration-notes.md`
  - `docs/clpr/native-queue-integration-plan/queue-adapter-design-notes.md`

## ISSUE-0005

Status: Completed (2026-02-12)

What was learned:

- Queue metadata semantics in current CLPR handlers are:
  - `sentMessageId` tracks the highest remotely acknowledged id (not \"last enqueued\" id),
  - `nextMessageId` tracks next local outbound id assignment.
- Native enqueue must **not** advance `sentMessageId`; it advances only `nextMessageId` and stores message value/running hash.
- After removing test-only queue seeding, baseline queue counters in `ClprMessagesSuite` converge to an empty-queue steady state (`sent=0, received=0, next=1`) instead of synthetic `20/20/21`.
- `HandleException` status mapping is practical for queue operation validation (`CLPR_INVALID_LEDGER_ID`, `CLPR_MESSAGE_QUEUE_NOT_AVAILABLE`, `INVALID_TRANSACTION_BODY`).

Pay attention in downstream issues:

- ISSUE-0006:
  - CLPR queue system-contract call path should delegate state mutation to `ClprQueueOperations.enqueue(...)`.
  - Preserve `sentMessageId` semantics; adapter must not reinterpret it as \"last enqueued\".
- ISSUE-0007:
  - Validate request-path enqueue updates `nextMessageId` only and chains running hash from last queued value or `sentRunningHash`.
- ISSUE-0008:
  - Response-path enqueue should reuse the same enqueue primitive with correlation-derived routing.
- ISSUE-0012/0013:
  - Queue progression assertions must be invariant-based and avoid hardcoded synthetic id milestones from removed seed behavior.

Refinement actions applied after ISSUE-0005:

- Recorded completion evidence and test commands:
  - `docs/clpr/native-queue-integration-plan/issue-0005-evidence.md`

## ISSUE-0006

Status: Completed (2026-02-12)

What was learned:

- CLPR queue adapter scaffolding at `0x16E` is stable and compatible with existing processor/module wiring.
- Typed revert reasons for adapter boundary failures work well for middleware `try/catch` semantics.
- Config gate defaults to disabled (`contracts.systemContract.clprQueue.enabled=false`), so Hapi/Solo tests must explicitly enable it.

Pay attention in downstream issues:

- ISSUE-0007:
  - Replace request selector stub with real enqueue path and keep typed route validation.
- ISSUE-0008:
  - Replace response selector stub with real enqueue behavior and explicit route-header validation.
- ISSUE-0012/0013:
  - Ensure test configs explicitly enable `contracts.systemContract.clprQueue.enabled`.

Refinement actions applied after ISSUE-0006:

- Updated ISSUE-0007 and ISSUE-0008 to explicitly require replacement of scaffolding stub behavior.
- Added ISSUE-0006 completion evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0006-evidence.md`

## ISSUE-0007

Status: Completed (2026-02-12)

What was learned:

- Request-path adapter can enqueue natively by decoding route metadata from `ClprMessage.middlewareMessage.data`.
- Route header validation is required at adapter boundary:
  - unsupported version -> typed revert,
  - zero/invalid remote ledger id -> typed revert.
- Adapter/tests must respect strict ABI numeric typing:
  - `uint8` uses `Integer`,
  - `uint64` output encoding uses `BigInteger`.
- End-to-end middleware flows are not yet natively compatible until route-header bytes are populated in Solidity middleware (currently empty for outbound requests).

Pay attention in downstream issues:

- ISSUE-0008:
  - Mirror request-path rigor for response path (typed validation + stable envelope encoding).
- ISSUE-0009:
  - Bundle callback path must read the same envelope format and preserve exactly-once commit semantics.
- ISSUE-0010:
  - Solidity middleware must populate deterministic route-header bytes into `middlewareMessage.data` for native queue path.
- ISSUE-0012/0013:
  - Keep fast validation anchored on `testSubprocess` and HAPI evidence; treat noisy environment warnings as non-gating unless assertions fail.

Refinement actions applied after ISSUE-0007:

- Added ISSUE-0007 completion evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0007-evidence.md`
- Refined remaining issues to include:
  - explicit route-header source/shape expectations,
  - explicit `contracts.systemContract.clprQueue.enabled` gating requirement in Hapi/Solo scenarios.

## ISSUE-0008

Status: Completed (2026-02-12)

What was learned:

- Response-path adapter implementation is stable with route-header based routing and strict field validation at adapter boundary.
- `original_message_id` validation is currently structural (`>0`) in adapter path; persisted correlation lookup cannot be completed until callback/correlation state is added during bundle processing.
- Baseline `ClprMessagesSuite` runs can remain green even when `contracts.systemContract.clprQueue.enabled=false`; this is expected for non-adapter paths and must not be misread as native queue coverage.

Pay attention in downstream issues:

- ISSUE-0009:
  - Add persisted correlation state write/read during callback processing and bind response routing to that state.
  - Keep exactly-once commit sequencing explicit: validate -> callback -> commit.
- ISSUE-0010:
  - Populate deterministic route headers in production Solidity middleware for both request and response flows.
- ISSUE-0012/0013:
  - Ensure native queue paths are exercised under `contracts.systemContract.clprQueue.enabled=true` with explicit assertions that queue selector calls occurred.

Refinement actions applied after ISSUE-0008:

- Added ISSUE-0008 completion evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0008-evidence.md`
- Refined remaining issues to tighten:
  - correlation-state ownership in callback processing (ISSUE-0009),
  - production route-header population expectations (ISSUE-0010),
  - native-queue path proof requirements in Hapi/Solo gates (ISSUE-0012/0013).

## ISSUE-0009

Status: Completed (2026-02-12, consensus-side callback wiring)

What was learned:

- Callback dispatch from `ClprProcessMessageBundleHandler` requires non-null `HandleContext.payer()` because `stepDispatch(...)` enforces non-null payer.
- Callback-path tests require an EVM-call-result-capable stream builder fixture; using plain `StreamBuilder` for request callbacks is insufficient because return data decode is required.
- Envelope callback flow is now in place for both inbound request and inbound response payloads, with legacy fallback retained for non-envelope payloads.
- Queue metadata progression remains stable in handler tests after callback processing.
- Baseline `ClprMessagesSuite` continues to pass, but it does not prove middleware callback authorization semantics because queue system contract path is disabled by default (`contracts.systemContract.clprQueue.enabled=false`) in that baseline config.

Pay attention in downstream issues:

- ISSUE-0010:
  - Resolve middleware callback authorization model (`onlyQueue`) for synthetic callback dispatch path.
  - Ensure production Solidity emits deterministic route headers for both request and response middleware fields.
- ISSUE-0011:
  - Add unit tests that explicitly assert callback auth fail/pass behavior and route-header decode invariants.
- ISSUE-0012/0013:
  - Run native callback scenarios only with `contracts.systemContract.clprQueue.enabled=true`.
  - Keep evidence anchored to HAPI receipts + queue state transitions, not just node logs.

Refinement actions applied after ISSUE-0009:

- Added ISSUE-0009 evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0009-evidence.md`
- Updated ISSUE-0010 to explicitly include callback authorization alignment and native-callback path proof expectations.
- Updated ISSUE-0011 to include callback authorization unit-matrix expectations.
- Updated ISSUE-0012 and ISSUE-0013 to require explicit callback authorization and adapter-path evidence under enabled queue system contract.
- Updated ISSUE-0014 cleanup gate to include resolution/decision documentation for callback authorization model and any temporary compatibility shims.

## ISSUE-0010

Status: Completed (2026-02-12)

What was learned:

- Native queue route-header support in Solidity middleware requires explicit remote-middleware configuration on source connectors; connector-id pairing alone is not enough to produce destination middleware address.
- Request and response route-header bytes can be asserted cleanly through existing mock contracts with minimal test-only surface additions:
  - destination connector stores last inbound route header,
  - mock queue exposes pending response route header bytes.
- Callback authorization mismatch from ISSUE-0009 can be handled in Solidity with an explicit trusted-callback caller override while keeping queue authorization as default.
- Hardhat default network config in this repo targets `local`; deterministic local validation requires `--network hardhat` unless an external local node is running.

Pay attention in downstream issues:

- ISSUE-0011:
  - Add consensus-side unit matrix cases that mirror trusted callback authorization assumptions and failure mapping.
  - Include route-header decode failures as first-class negative tests.
- ISSUE-0012/0013:
  - Explicitly set both:
    - connector remote middleware mapping,
    - trusted callback caller (if callback path requires non-queue sender),
    in scenario setup scripts before asserting callback success.
- ISSUE-0014:
  - Revisit whether trusted callback caller remains required after full native callback path stabilization.
  - If not required, remove and document final authorization model.

Refinement actions applied after ISSUE-0010:

- Added ISSUE-0010 evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0010-evidence.md`
- Refined ISSUE-0011 to include callback-authorization and route-header decode negative matrices.
- Refined ISSUE-0012/0013 to require explicit setup/evidence for remote middleware mapping and trusted callback caller configuration where applicable.
- Refined ISSUE-0014 to require final decision/cleanup on trusted callback caller path.

## ISSUE-0011

Status: Completed (2026-02-12)

What was learned:

- Route-header validation coverage needed explicit malformed-byte and wrong-tuple-shape tests in both request and response translators.
- Callback failure semantics are now explicitly characterized in handler tests:
  - callback revert status is propagated,
  - queue metadata is preserved on callback failure,
  - malformed callback return payload maps to `CLPR_INVALID_BUNDLE`.
- ABI unsigned return decoding assertions should be explicit in adapter tests to prevent accidental type regressions.
- Gradle wildcard test selectors must be quoted in shell invocations (`--tests '*pattern*'`) to avoid shell expansion false negatives.

Pay attention in downstream issues:

- ISSUE-0012:
  - Mirror unit-level callback-failure assertions in Hapi suites (failed callback should not advance queue metadata/correlation state).
  - Include one malformed payload/route failure case at Hapi level to prove status mapping consistency beyond unit tests.
  - Use quoted wildcard filters in reproducible command examples.
- ISSUE-0013:
  - Smoke evidence should capture both success-path queue progression and fail-path non-progression invariants.
  - Stage-level report should clearly include callback-failure checkpoint behavior (expected status + unchanged queue state).
- ISSUE-0014:
  - Keep these unit cases as permanent regression gates for route-header decode and callback-failure mapping.
  - Ensure cleanup does not remove assertions that enforce metadata-preservation on failed callbacks.

Refinement actions applied after ISSUE-0011:

- Added ISSUE-0011 evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0011-evidence.md`
- Refined ISSUE-0012 to include explicit fail-path metadata non-progression assertions and quoted command examples.
- Refined ISSUE-0013 to include fail-path checkpoint/evidence requirements for unchanged queue state.
- Refined ISSUE-0014 to lock route-envelope decode and callback-failure mapping checks into final regression gate expectations.

## ISSUE-0012

Status: Completed (2026-02-12)

What was learned:

- Focused native-queue Hapi gates are now in place and passing:
  - `ClprMiddlewareNativeQueueSuite` (single-ledger callback failure non-progression),
  - `ClprMiddlewareTwoLedgerNativeQueueSuite` (two-ledger request/response callback round-trip).
- Running the gate without `--rerun-tasks` can intermittently fail in subprocess startup with:
  - `NoSuchFileException: build/<network>-test/node0/output/hgcaa.log`
  even when the same suites pass with `--rerun-tasks`.
- For this environment, deterministic local gating is currently best-effort stable with:
  - explicit suite filters,
  - `:test-clients:testSubprocess`,
  - `--rerun-tasks`.

Pay attention in downstream issues:

- ISSUE-0013:
  - Smoke runbook should explicitly include mitigation for `hgcaa.log` startup race:
    - clean `*-test` build dirs and/or execute with `--rerun-tasks` for deterministic startup.
  - Evidence bundle should classify this as operational harness flakiness unless functional assertions fail.
- ISSUE-0014:
  - Final regression guidance should document the known startup race and chosen mitigation.
  - Cleanup scope should remove temporary debug markers currently left in native queue suites/handlers after callback debugging.

Refinement actions applied after ISSUE-0012:

- Added ISSUE-0012 evidence:
  - `docs/clpr/native-queue-integration-plan/issue-0012-evidence.md`
- Refined ISSUE-0013 to include explicit mitigation and evidence requirements for `hgcaa.log` subprocess-log startup race.
- Refined ISSUE-0014 to include explicit cleanup/verification of temporary callback-debug markers and final regression docs for subprocess startup mitigation.

## ISSUE-0013

Status: Completed (2026-02-13)

What was learned:

- A Solo two-ledger smoke must explicitly emulate off-ledger connector behavior:
  - fetch outbound bundles via `getMessages(...)`,
  - submit `clprProcessMessageBundle` on the peer ledger,
  - repeat for the response direction.
- Smoke assertions must be invariant-based and not assume message id starts at 1 (message ids persist across runs for a stable ledger id).
- `:test-clients:runTestClient` uses `user.dir` of the `hedera-node/test-clients` module; dev-mode signing key discovery must walk parent dirs to find `hedera-node/data/onboard/*`.
- `kubectl logs` alone can miss node diagnostics; file logs under `/opt/hgcapp/services-hedera/HapiApp2.0/output/` are high-value evidence.
- Evidence capture scripts must be best-effort and must not fail the smoke run on benign copy errors (for example copying a file onto itself).

Evidence:

- PASS run: `artifacts/clpr-native-queue/issue-0013/20260213T023353Z/`

Refinement actions applied after ISSUE-0013:

- Added bundle-pump tooling and stage markers:
  - `../hiero-consensus-node/hedera-node/test-clients/src/main/java/com/hedera/services/bdd/tools/ClprNativeQueuePumpMain.java`
- Hardened smoke evidence collection:
  - include `pump.log`,
  - include `hgcaa.log` and `swirlds.log` tails,
  - include application properties snapshots for config proof,
  - avoid failing on benign copy behavior.

## ISSUE-0014

Status: Completed (2026-02-13)

What was learned:

- Gradle subproject names in `../hiero-consensus-node` are artifact-based; CLPR queue translator tests live under:
  - `:app-service-contract-impl:test` (not `:hedera-smart-contract-service-impl:test`)
- The final regression gate should always include targeted translator tests to catch route-envelope decode/validation drift.
- Native-queue smoke evidence capture should be best-effort and include in-pod file logs (not just `kubectl logs`) for high-signal failure diagnosis.

Evidence:

- `docs/clpr/native-queue-integration-plan/issue-0014-evidence.md`
