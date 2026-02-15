# Native Queue Integration Issues Index

## Ordered Execution

1. `ISSUE-0001-research-baseline-inventory.md`
2. `ISSUE-0002-custom-node-solo-rehearsal.md`
3. `ISSUE-0003-native-config-exchange-baseline.md`
4. `ISSUE-0004-system-contract-api-mapping-design.md`
5. `ISSUE-0005-native-enqueue-operation-in-clpr-service.md` (parallel track A after ISSUE-0004)
6. `ISSUE-0006-clpr-queue-system-contract-scaffolding.md` (parallel track B after ISSUE-0004)
7. `ISSUE-0007-enqueue-message-request-path.md`
8. `ISSUE-0008-enqueue-message-response-path.md`
9. `ISSUE-0009-native-bundle-processing-to-middleware-callbacks.md`
10. `ISSUE-0010-smart-contract-repo-minimal-integration.md`
11. `ISSUE-0011-consensus-unit-test-battery.md`
12. `ISSUE-0012-hapitest-e2e-battery.md`
13. `ISSUE-0013-solo-two-ledger-smoke-and-evidence.md`
14. `ISSUE-0014-cleanup-hardening-regression-gate.md`

## Milestone Policy

- Do not start an issue until the prior issue's `Milestone Exit Criteria (Dependency Gate)` is satisfied.
- For each completed issue, capture artifacts and link them in the issue document before moving forward.

## Phase Milestones

- Phase 1 (Research + Environment): ISSUE-0001 to ISSUE-0003
- Phase 2 (Design + Adapter Core): ISSUE-0004 to ISSUE-0008
- Phase 3 (Callback Integration): ISSUE-0009 to ISSUE-0012
- Phase 4 (Operationalization + Cleanup): ISSUE-0013 to ISSUE-0014

## Test Layer Progression

- Earliest: Unit-heavy (issues 0004-0011).
- Middle: HapiTest-heavy (issues 0012).
- Final: Solo-heavy (issues 0013-0014).
