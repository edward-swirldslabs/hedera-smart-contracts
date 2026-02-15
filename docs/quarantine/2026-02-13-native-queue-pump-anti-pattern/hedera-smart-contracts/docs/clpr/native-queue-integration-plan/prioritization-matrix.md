# Native Queue Integration Prioritization Matrix

Status: Complete  
Last updated: 2026-02-13

## Scoring Model

- Risk: `Low`, `Medium`, `High`, `Very High`
- Effort: `S` (small), `M` (medium), `L` (large), `XL` (very large)
- Confidence: estimated confidence that requirements and implementation approach are already clear.

## Issue Ranking

| Issue | Risk | Effort | Confidence | Why it is risky | Gate evidence required |
|---|---|---:|---:|---|---|
| ISSUE-0001 | Low | S | 0.95 | Mostly analysis quality risk | Baseline matrix with source-linked findings |
| ISSUE-0002 | Medium | M | 0.80 | Solo environment/tooling drift risk | Repeatable deploy script + status checks |
| ISSUE-0003 | High | M | 0.70 | Bootstrap ordering and cross-ledger timing risk | Proven config exchange checkpoints |
| ISSUE-0004 | Medium | M | 0.75 | Wrong adapter design can cause rework | ADR with selector/error/encoding tables |
| ISSUE-0005 | High | L | 0.65 | Queue state mutation correctness and compatibility risk | Deterministic enqueue state transitions |
| ISSUE-0006 | Medium | M | 0.75 | EVM wiring/addressing and revert semantics risk | Selector dispatch tests + collision checks |
| ISSUE-0007 | High | M | 0.65 | Payload fidelity and routing correctness risk | Golden request fixtures + monotonic id checks |
| ISSUE-0008 | High | M | 0.65 | Response correlation and mixed-flow ordering risk | Golden response fixtures + correlation tests |
| ISSUE-0009 | Very High | XL | 0.45 | Core callback integration semantics risk | Two-ledger callback cycle validated end-to-end |
| ISSUE-0010 | Medium | M | 0.80 | Accidental Solidity API drift risk | ABI compatibility and configurable queue address |
| ISSUE-0011 | Medium | M | 0.85 | Coverage gaps hide regressions | Behavior-to-test matrix with fast deterministic suite |
| ISSUE-0012 | High | L | 0.60 | Asynchronous two-ledger flakiness risk | Stable HapiTest checkpoints + failure-path assertions |
| ISSUE-0013 | High | L | 0.55 | Operational flakiness and weak evidence risk | One-command smoke + mandatory artifact bundle |
| ISSUE-0014 | Medium | M | 0.90 | Debug debt/regression drift risk | No temporary debug markers + full regression report |

## Critical Path

Strict path:

1. ISSUE-0001 -> ISSUE-0002 -> ISSUE-0003 -> ISSUE-0004
2. ISSUE-0005 and ISSUE-0006
3. ISSUE-0007 -> ISSUE-0008 -> ISSUE-0009
4. ISSUE-0010 -> ISSUE-0011 -> ISSUE-0012 -> ISSUE-0013 -> ISSUE-0014

## Recommended Parallel Workstreams

After ISSUE-0004 is complete:

- Workstream A: ISSUE-0005 (native enqueue operation)
- Workstream B: ISSUE-0006 (system-contract scaffolding)

After ISSUE-0009 is complete:

- Workstream A: ISSUE-0010 (smart-contract repo integration)
- Workstream B: ISSUE-0011 (unit battery hardening)

## Recommended Milestone Reviews

- Review 1 (post-ISSUE-0004): approve adapter design before code-heavy implementation.
- Review 2 (post-ISSUE-0009): confirm callback semantics before broad test expansion.
- Review 3 (post-ISSUE-0013): assess operational reliability and evidence quality before cleanup gate.

## Highest-Risk Focus Areas

- Callback execution semantics in `ClprProcessMessageBundleHandler` path.
- Queue state/running-hash integrity when mixing request and response payloads.
- Two-ledger timing and bootstrap ordering in Solo-based runs.
