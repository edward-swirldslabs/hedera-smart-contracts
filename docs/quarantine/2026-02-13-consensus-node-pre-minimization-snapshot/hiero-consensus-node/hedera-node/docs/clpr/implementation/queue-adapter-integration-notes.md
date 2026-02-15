# CLPR Queue Adapter Integration Notes (Issue-0004)

This note captures concrete implementation guidance from ADR-0001.

## Implementation checklist

1. Add CLPR queue system contract at `0x16E` in processor wiring.
2. Add CLPR queue translator methods with selectors:
   - `0x8cfaaa60` (`enqueueMessage`)
   - `0xb26aa82b` (`enqueueMessageResponse`)
3. Decode calldata using headlong canonical signatures exactly as recorded in ADR-0001.
4. Request enqueue path:
   - parse route header,
   - validate `remoteLedgerId` non-empty,
   - append message payload as `ClprMessagePayload.message.message_data` envelope bytes,
   - update queue metadata (`next_message_id`, running hash, sent metadata).
5. Response enqueue path:
   - validate `originalMessageId` and correlation map entry,
   - append payload as `ClprMessagePayload.message_reply.message_reply_data` envelope bytes,
   - set `message_reply.message_id = originalMessageId`.
6. Bundle processing callback path (planned in ISSUE-0009):
   - decode envelope,
   - call middleware callback target,
   - on request callback, capture correlation for later response enqueue.

## Required config knobs (planned)

- `contracts.systemContract.clprQueueService.enabled` (gate queue system contract execution).
- Optional fallback middleware target for inbound request callback when envelope target is zero.

## Determinism requirements

- For a fixed input stream and initial queue state, message-id assignment and running-hash results must be deterministic.
- Selector decode and failure behavior must be deterministic across nodes.
- Callback routing must not depend on off-chain relay state.

## Negative-path requirements

- malformed route header -> reject with typed revert status,
- missing correlation on response enqueue -> reject,
- stale/duplicate bundle -> reject before callback execution.
