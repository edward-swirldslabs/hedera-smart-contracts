# ISSUE-0308: Normalize CLPR Package Naming for Symmetry and Discoverability

Status: Done (2026-02-17)

## Objective

Align CLPR system-contract package layout with repository conventions and with CLPR request/response symmetry, without changing runtime behavior.

This implements approved proposal item:
- `2.9 / 3.2`

## Why

Current CLPR operation packages are functionally correct but visually flat (`clpr/<operation>/...`). Grouping queue-related operations under a stable intermediate package (`clpr/queue/...`) improves discoverability and makes request/reply operation pairs easier to review together.

## Scope

### Package organization changes (consensus-node)

Move/refactor CLPR queue operation packages under:
- `.../exec/systemcontracts/clpr/queue/enqueuemessage/...`
- `.../exec/systemcontracts/clpr/queue/enqueuemessageresponse/...`
- `.../exec/systemcontracts/clpr/queue/deliverinboundmessage/...`
- `.../exec/systemcontracts/clpr/queue/deliverinboundmessagereply/...`

Expected updates:
- package declarations
- imports in production classes
- Dagger/module wiring references
- unit test package paths and imports

### Behavioral guardrails

- No selector changes
- No ABI changes
- No dispatch/payload logic changes
- No semantic flow changes

## Impacted Files (Expected)

- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/**`
- `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/clpr/**`
- module/wiring files that import the moved classes

## Acceptance Criteria

1. Package structure reflects queue-domain grouping and request/reply symmetry.
2. Behavior is unchanged; all touched tests pass.
3. `ClprQueueCallAttemptTest` and translator/call tests still pass and reference new packages.
4. No external interface signatures or selectors are modified.

## Out of Scope

- Functional rewrites of translators/calls/codecs.
- Any new API surface.

## Implementation Log

- CLPR system-contract queue operations are organized under:
  - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/main/java/com/hedera/node/app/service/contract/impl/exec/systemcontracts/clpr/queue/`
  - with symmetric subpackages:
    - `deliverinboundmessage`
    - `deliverinboundmessagereply`
    - `enqueuemessage`
    - `enqueuemessageresponse`
- Matching test packages are organized under:
  - `../hiero-consensus-node/hedera-node/hedera-smart-contract-service-impl/src/test/java/com/hedera/node/app/service/contract/impl/test/exec/systemcontracts/clpr/queue/`
- Legacy flat package paths (`clpr/enqueuemessage`, etc.) are removed from current source tree.
- Validation:
  - `./gradlew :app-service-contract-impl:test --tests '*clpr*' --no-daemon --console=plain`
  - Result: PASS (`SUCCESS: Executed 38 tests`).

Completion summary:
- Package naming and placement now reflect queue-domain symmetry with no behavioral regressions in impacted CLPR system-contract tests.
