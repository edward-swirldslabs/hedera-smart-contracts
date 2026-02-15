# Archived Issues (Native Messaging SOLO Integration, 0101-0108)

Archived on: 2026-02-15

Why this was archived:

- The `ISSUE-0101..0108` set successfully drove an end-to-end SOLO demo, but it also produced consensus-node code that
  is not aligned with the desired final architecture:
  - ABI artifacts and ABI decoding/encoding in `ClprProcessMessageBundleHandler`
  - outbound queue mutations that are not cleanly correlated to explicit enqueue transactions
  - non-canonical wrapper envelopes stored in `ClprMessage.message_data` / `ClprMessageReply.message_reply_data`
- The refactor target state is now captured in:
  - `docs/clpr/CLPR_CONSENSUS_NODE_REFACTOR_PROPOSAL.md`

What to do instead:

- Use the active issue set in:
  - `docs/clpr/native-messaging-solo-integration-plan/issues/`
  - Refactor series: `ISSUE-0201..0208`

This archived issue set defined work required to reach the native-messaging SOLO architecture described in:

- `docs/clpr/native-messaging-solo-integration-plan/README.md`

## Active Issues

Status:

- `ISSUE-0101-define-target-state-and-guardrails.md` (Done)
- `ISSUE-0102-solo-two-ledger-network-reachability.md` (Done)
- `ISSUE-0103-config-exchange-kick-tooling-no-pump.md` (Done)
- `ISSUE-0104-queue-system-contract-minimal-adapter.md` (Done)
- `ISSUE-0105-solo-e2e-native-messaging-no-pump.md` (Done)
- `ISSUE-0106-cleanup-regression-guards-and-documentation.md` (Done)
- `ISSUE-0107-pare-down-hedera-smart-contracts-changes.md` (Done)
- `ISSUE-0108-pare-down-hiero-consensus-node-changes.md` (Done)
