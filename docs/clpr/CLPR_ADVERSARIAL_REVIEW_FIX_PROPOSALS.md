# CLPR Adversarial Review: Follow-On Fix Proposals

Date: 2026-02-17  
Status: Proposal document for issue creation and incremental implementation planning  
Depends on: `docs/clpr/CLPR_ADVERSARIAL_REVIEW_PASS_2.md`

## 1. Purpose and Scope

This document translates findings from `docs/clpr/CLPR_ADVERSARIAL_REVIEW_PASS_2.md` into concrete, file-level remediation proposals that are detailed enough to become implementation issues.

For each proposal below, the structure is:
- Current state and behavior
- Proposed code changes (by file)
- New behavior after change
- Why the change is better
- Recommended acceptance criteria

This document also records where we intentionally defer hardening work for the prototype.

## 2. Proposal Set by Review Item

### 2.1 Item 1.2.1: Reduce inline codec logic in delivery call classes

#### Current state

The following classes currently mix three concerns in one place:
- packed calldata decode/encode
- route-header parse/patch logic
- orchestration (dispatch middleware callback and enqueue synthetic tx)

Files:
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java`

How it works now:
- Each class parses packed bytes itself.
- Each class translates between canonical envelope bytes and tuples itself.
- Each class owns selector prepend/strip helpers.
- Each class then performs dispatch orchestration.

This makes the classes harder to review and increases duplication/drift risk.

#### Proposed change

Create dedicated codec utility classes under CLPR system contract package:
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/codec/ClprPackedInputCodec.java`
  - decode `deliverInboundMessagePacked` request
  - decode `deliverInboundMessageReplyPacked` request
  - shared bounds/length validation
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/codec/ClprCanonicalEnvelopeCodec.java`
  - canonical message tuple decode
  - canonical response tuple decode
  - response route-header patch helper
  - canonical response bytes encode
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/codec/ClprRouteHeaderCodec.java`
  - decode request route-header
  - decode response route-header
  - encode response route-header

Then slim down these orchestrator classes so they only:
- validate caller / high-level invariants
- call codec utilities
- dispatch middleware callback
- dispatch `clprEnqueueMessage`
- map status to revert/success output

Files to modify:
- `.../deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java`
- `.../deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java`

#### New behavior

Behavior remains functionally equivalent, but code responsibility is isolated:
- codec classes handle parse/encode semantics
- call classes handle workflow orchestration only

#### Why this is better

- Better maintainability and reviewability.
- Fewer copy/paste codec bugs.
- Easier to unit-test codecs independently from dispatch behavior.
- More consistent with existing consensus-node style (decoder/helper separation patterns).

#### Acceptance criteria

- No functional regression in existing CLPR tests.
- New codec unit tests cover malformed length, empty payload, and route-header parse errors.
- Delivery call classes no longer contain selector prepend/strip helper methods.

---

### 2.2 Item 1.2.2: Handler-level TODOs (defer by default, patch only if risk is immediate)

#### Current state

Outstanding TODOs are in:
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprProcessMessageBundleHandler.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`

You approved deferring most TODO hardening for prototype speed.

#### Proposed now-vs-later split

Do now (low cost, high safety):
- Add tests that lock current internal-only assumptions so accidental behavior drift is visible.

Defer (hardening phase):
- full payer/signature model finalization for these handlers.

Files for now:
- add/extend tests under:
  - `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/test/java/org/hiero/interledger/clpr/impl/test/handler/`

#### Why defer is acceptable here

- Prototype flow already has internal-only controls in other layers.
- immediate risk can be reduced with tests without prematurely freezing auth design.

#### Risk if left entirely for later

- subtle behavior changes could slip in unnoticed.

#### Acceptance criteria (now)

- At least one test fails if these handlers start accepting user-originated flows contrary to current intent.

---

### 2.3 Item 1.2.3 and Items 5.2.3/5.4: Cross-repo observability style alignment

#### Current state

Before this pass, logging style was uneven:
- `ClprEndpointClient` had rich logs.
- core queue/system-contract/handler boundaries had limited or no structured invocation logs.

#### Proposed standard

Use one structured pattern across CLPR Java components:
- Prefix: `CLPR_OBS|`
- Required fields: `component=...|stage=...`
- Add contextual keys per stage (`status`, `messageId`, `ledgerId`, `payloadType`, etc.)
- Every added diagnostic log must have adjacent comment:
  - `// TEMP-OBSERVABILITY (delete before production): ...`

#### Files already updated in working tree

System contract calls:
- `.../clpr/enqueuemessage/ClprQueueEnqueueMessageCall.java`
- `.../clpr/enqueuemessageresponse/ClprQueueEnqueueMessageResponseCall.java`
- `.../clpr/deliverinboundmessage/ClprQueueDeliverInboundMessageCall.java`
- `.../clpr/deliverinboundmessagereply/ClprQueueDeliverInboundMessageReplyCall.java`

Handlers:
- `.../handlers/ClprMessagePayloadHandler.java`
- `.../handlers/ClprEnqueueMessageHandler.java`
- `.../handlers/ClprProcessMessageBundleHandler.java`
- `.../handlers/ClprGetMessagesHandler.java`
- `.../handlers/ClprGetMessageQueueMetadataHandler.java`

#### New behavior

Each boundary crossing now emits stage-based log markers that can be stitched into a timeline using `scenario.log`, `hgcaa-*.log`, and EVM event timestamps.

#### Why this is better

- Demo readiness (observable stage transitions).
- Faster root-cause triage.
- Traceability without introducing protocol changes.

#### Acceptance criteria

- In one successful run, logs show all major stages from enqueue through bundle processing through callback/response.
- All added logs include temporary-removal comments.

---

### 2.4 Item 1.3.3: Enforce middleware-only sender equality in `MockClprQueue`

#### Current state

`MockClprQueue` accepts enqueue calls from any caller, unlike `MockClprRelayedQueue` which enforces middleware sender boundaries.

File:
- `contracts/solidity/clpr/mocks/MockClprQueue.sol`

How it works now:
- test harnesses can call queue methods directly.
- this can mask integration bugs where middleware-only queue boundaries are violated.

#### Proposed change

Add sender equality constraints to `MockClprQueue` enqueue methods:
- `require(msg.sender == sourceMiddleware, UnauthorizedCaller(msg.sender));`

Potentially affected tests:
- `test/solidity/clpr/clprMiddleware.js`
- `test/foundry/ClprMiddleware.t.sol`
- any test currently calling queue directly must go through middleware or explicit authorized setup.

#### Why adding this constraint is better than removing it

What it prevents:
- false-positive tests that bypass middleware boundary checks.
- accidental direct queue usage patterns that are invalid in intended architecture.

Opportunity cost:
- tests that currently shortcut queue calls need slight setup changes.
- some convenience in direct queue poking is reduced.

Why that cost is acceptable:
- the tests become more representative of real flow.
- catches boundary mistakes earlier.

#### Acceptance criteria

- Direct unauthorized queue enqueue attempts revert in tests.
- Middleware-driven enqueue path still passes.

---

### 2.5 Item 2.1: Deduplication proposals

#### Current state

Duplication exists across CLPR call classes and JS scenario/test helpers.

#### Proposed changes

Consensus-node dedup:
- Implement codec utility split in Section 2.1.
- Consolidate shared selector/byte helpers in `ClprPackedInputCodec`.

Smart-contract repo dedup:
- Extract connector-id derivation/helper logic into shared JS utility:
  - `scripts/clpr/native-messaging-solo/lib-connectors.js`
- Reuse it from:
  - `scripts/clpr/native-messaging-solo/run-scenario.js`
  - `test/solidity/clpr/clprMiddleware.js` (if compatible with test runtime)

If test runtime import constraints make cross-folder sharing noisy, create a mirrored helper under:
- `test/solidity/clpr/support/connectorIds.js`

#### Why this is better

- single source of truth for connector id derivation.
- lower drift risk between test and scenario runner.

#### Acceptance criteria

- helper logic exists once per runtime boundary (production script vs test harness).
- no duplicated connector-id formula strings in target files.

---

### 2.6 Item 2.2.1: Noise cleanup (completed)

#### Completed changes

Removed unused logger noise from handlers where no meaningful logs existed:
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetMessagesHandler.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprGetMessageQueueMetadataHandler.java`
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`

Follow-up:
- query handlers now include meaningful trace logs (Section 2.3), so they are no longer “dead logger” noise.

---

### 2.7 Item 2.2.2: Script modularization/refactor (completed baseline + next cleanup slice)

#### Current/updated state

The `scripts/clpr/native-messaging-solo` suite is now split into reusable operational scripts:
- `lib.sh` (shared config, env wiring, utility functions)
- `two-network-up.sh`
- `two-network-down.sh`
- `two-network-status.sh`
- `run-e2e.sh` (orchestrator)
- `block-stream-tailer.js`

Docs updated with usage and runbooks:
- `docs/clpr/README.md`
- `docs/clpr/BLOCK_STREAM_TAILER_RUNBOOK.md`
- `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md`
- `AGENTS.md`

#### Recommended next cleanup slice (optional)

If further modularization is desired, split `run-e2e.sh` into phase functions in a sourced `run-e2e-phases.sh`:
- `phase_build_cn`
- `phase_deploy_ledgers`
- `phase_port_forward`
- `phase_config_exchange`
- `phase_run_scenario`
- `phase_collect_evidence`

This is quality-of-life only; not required for correctness.

---

### 2.8 Item 2.3: Add unit tests and HapiTests for new CLPR system-contract path

#### Current gap

Coverage of new payload-delivery bridge and selector coupling is not yet sufficient.

#### Proposed test additions

Unit tests:
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/.../handlers/ClprMessagePayloadHandlerTest.java`
  - message payload path dispatches `deliverInboundMessagePacked`
  - reply payload path dispatches `deliverInboundMessageReplyPacked`
  - invalid payload fails with expected status

Translator/coupling tests:
- extend existing CLPR translator tests so selector constants used by handlers/calls are asserted explicitly.

Hapi test (subprocess):
- add scenario test under test-clients CLPR suite to verify:
  - inbound request processing dispatches payload handler
  - outbound response enqueue occurs via `clprEnqueueMessage`
  - query-visible queue cursor updates are correct

#### Acceptance criteria

- new tests pass locally and fail if selector coupling drifts.
- existing CLPR suite remains green.

---

### 2.9 Item 3.2: Naming symmetry and clarity proposals

#### Current state

CLPR naming is mostly clear, but package names under system-contract operations are visually inconsistent.

#### Proposed naming cleanup

Normalize operation package names to a common pattern (defer until after behavior stabilization):
- from `enqueuemessage` -> `enqueue_message` style is not idiomatic Java.
- preferred Java idiom is keep lower-case package names, but group by operation domain:
  - `.../clpr/queue/enqueuemessage/...`
  - `.../clpr/queue/enqueuemessageresponse/...`
  - `.../clpr/queue/deliverinboundmessage/...`
  - `.../clpr/queue/deliverinboundmessagereply/...`

This preserves Java package conventions while improving scanability by introducing a stable `queue` grouping layer.

#### Why better

- improves discoverability for reviewers and maintainers.
- emphasizes operation symmetry.

#### Acceptance criteria

- no behavior changes.
- imports and test references updated cleanly.

---

### 2.10 Items 4.1.2, 4.2.1, 4.2.2: Security/algorithmic fixes proposed for next development slice

#### 4.1.2 Proposal: hardening guardrail without freezing full auth design

Now:
- keep prototype preHandle TODOs where policy is genuinely undecided.

But add now:
- tests that enforce current internal-only assumptions.
- explicit TODO owner marker and ticket ID in comments so deferred hardening is trackable.

Files:
- `ClprProcessMessageBundleHandler.java`
- `ClprUpdateMessageQueueMetadataHandler.java`
- corresponding test files

#### 4.2.1 Proposal: metadata cleanup algorithm improvement

Current behavior:
- metadata-update removes stale messages one-by-one in a linear loop.

Proposed path:
- introduce bounded batch cleanup in handler execution:
  - process up to `N` deletions per transaction (configurable)
  - persist progress through queue cursor semantics

File:
- `../hiero-consensus-node/hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/handlers/ClprUpdateMessageQueueMetadataHandler.java`

Why better:
- avoids heavy single-transaction loops for large backlog.

#### 4.2.2 Proposal: reduce packed encode/decode churn

Current behavior:
- delivery call classes repeatedly decode and re-encode tuple/call data.

Proposed path:
- codec split from Section 2.1.
- keep canonical bytes as bytes where possible; decode to tuple only when needed for route-header extraction/callback patching.

Why better:
- fewer intermediate allocations.
- clearer fast-path for prototype and future optimization.

---

## 3. Proposed Issue Breakdown

Recommended issue ordering for implementation:

1. Codec extraction and call-class slimming (`2.1`, `4.2.2`).
2. Mock queue sender-equality constraint + negative tests (`2.4`).
3. CLPR payload handler + selector coupling tests (`2.8`).
4. Deferred-hardening guardrail tests for TODO handlers (`2.2`, `2.10`).
5. Metadata cleanup batching (`2.10/4.2.1`).
6. Naming/package cleanup (optional, behavior-neutral) (`2.9`).

Each issue should require:
- implementation log notes
- passing relevant unit/Hapi tests
- at least one successful two-ledger SOLO run for integration-touching changes

## 4. Prototype Deferrals (Explicitly Accepted)

The following are intentionally deferred unless they block prototype correctness:
- full signature/payer policy finalization for TODO-marked handlers
- production-grade throttling and rate controls
- full production hardening of all diagnostics

These deferrals are acceptable only if test guardrails are added so behavior drift is visible.

## 5. Cross-References

- Source review: `docs/clpr/CLPR_ADVERSARIAL_REVIEW_PASS_2.md`
- Observability map: `docs/clpr/CLPR_DEMO_OBSERVABILITY_PLAN.md`
- SOLO runbooks:
  - `docs/clpr/NATIVE_MESSAGING_SOLO_CLEAN_RERUN_PLAYBOOK.md`
  - `docs/clpr/BLOCK_STREAM_TAILER_RUNBOOK.md`
- Integration issues root:
  - `docs/clpr/native-messaging-solo-integration-plan/issues/README.md`
