<!-- SPDX-License-Identifier: Apache-2.0 -->

# CLPR Block Stream Tailer Runbook

## Purpose

This runbook explains how to use the CLPR block-stream tailer for **live** block-node observability.

- Protocol: `org.hiero.block.api.BlockStreamSubscribeService/subscribeBlockStream`
- Transport mode: server-streaming gRPC (push feed, not polling)
- Cursor behavior: resumes from the last completed block after reconnect
- Decode resilience: on known grpcurl decode failures (`integer overflow` / `bad wiretype`), the tailer logs a `decode_error` record and skips the failing block to continue live follow.

## Prerequisites

- A reachable block-node endpoint (for example `127.0.0.1:54080`).
- `grpcurl` installed and on `PATH`.
- Protobuf import paths available from sibling `../hiero-block-node` build outputs.

## Start Methods

## 1) Auto-start via scenario runner

```bash
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

`run-e2e.sh` automatically starts two tailers:
- source (`--label src`)
- destination (`--label dst`)

Default block-node endpoints used by the runner:
- source BN: `127.0.0.1:54080`
- destination BN: `127.0.0.1:54081`

## 2) Manual standalone start

Example:

```bash
node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
  --endpoint 127.0.0.1:54080 \
  --label src \
  --start-block 0 \
  --deployment-file artifacts/clpr-native-messaging-solo/<runId>/deployment.json \
  --output-file artifacts/clpr-native-messaging-solo/<runId>/src-custom.ndjson
```

## Customization

## Output filenames

For `run-e2e.sh`, output/log filenames are configurable:

```bash
CLPR_BLOCK_STREAM_SRC_NDJSON=src-feed.ndjson \
CLPR_BLOCK_STREAM_DST_NDJSON=dst-feed.ndjson \
CLPR_BLOCK_STREAM_SRC_LOG=src-tailer.log \
CLPR_BLOCK_STREAM_DST_LOG=dst-tailer.log \
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

Rules:
- If a filename is relative, `run-e2e.sh` places it under the run directory.
- Absolute paths are used as-is.

For manual use, set any file path directly with `--output-file`.

## Filter to specific block items

`block-stream-tailer.js` can filter by response and item kinds:

```bash
node scripts/clpr/native-messaging-solo/block-stream-tailer.js \
  --endpoint 127.0.0.1:54080 \
  --label src \
  --output-file /tmp/src-events.ndjson \
  --match-response-kind block_items \
  --match-item-kind event_transaction
```

Supported filter flags (repeatable):
- `--match-response-kind <kind>` where kind is typically `block_items`, `end_of_block`, or `status`
- `--match-item-kind <name>` for top-level block item oneof keys (as reported in `itemKinds`)
- `--match-keyword <text>` case-insensitive payload substring

Filter semantics:
- Within one filter type (for example multiple `--match-item-kind`), matching is OR.
- Across filter types, matching is AND.
- Emission occurs when either:
  - built-in CLPR relevance matches, or
  - custom filters match, or
  - `--log-all` is set.

Runner equivalents (CSV):

```bash
CLPR_BLOCK_STREAM_MATCH_RESPONSE_KINDS=block_items \
CLPR_BLOCK_STREAM_MATCH_ITEM_KINDS=event_transaction,transaction_result \
CLPR_BLOCK_STREAM_MATCH_KEYWORDS=clpr,enqueue \
bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

To emit every streamed frame:

```bash
CLPR_BLOCK_STREAM_LOG_ALL=true bash scripts/clpr/native-messaging-solo/run-e2e.sh
```

## Stop Methods

## Manual tailer

- Foreground process: `Ctrl+C`
- Background process: `kill <pid>`

## Runner-managed tailers

- `run-e2e.sh` stops tailers automatically in cleanup on success/failure/interrupt.
- To stop immediately, terminate the runner process; its trap handler cleans up tailers and port-forwards.

## Data Locations

For each run directory `artifacts/clpr-native-messaging-solo/<runId>/`:
- source feed NDJSON (default): `block-stream-src.ndjson`
- destination feed NDJSON (default): `block-stream-dst.ndjson`
- source tailer logs (default): `block-stream-src.log`
- destination tailer logs (default): `block-stream-dst.log`
- deployment metadata used for relevance matching: `deployment.json`

Monitoring examples:

```bash
run_id=<run-id>
tail -f artifacts/clpr-native-messaging-solo/$run_id/block-stream-src.ndjson | jq
tail -f artifacts/clpr-native-messaging-solo/$run_id/block-stream-src.log
```

## NDJSON Record Schema

The tailer now emits three record types in NDJSON:

1. Frame records (`recordType=frame`)
2. Block-item records (`recordType=block_item`)
3. Decode-error records (`recordType=decode_error`)

### Frame record fields

- `recordType` = `frame`
- `observedAt`
- `label`
- `endpoint`
- `responseKind`
- `blockNumber`
- `itemCount`
- `itemKinds`
- `clprRelated`
- `matchReasons`
- `customMatched`
- `customMatchReasons`
- `clprItemCount` (count of CLPR-relevant item records found in this frame)
- `clprItemKinds` (distinct relevant item kinds)

### Block-item record fields

- `recordType` = `block_item`
- `observedAt`
- `label`
- `endpoint`
- `responseKind` (normally `block_items`)
- `blockNumber`
- `itemIndex` (position within the frame item list)
- `itemKind` (oneof key, for example `event_transaction`, `transaction_result`, `transaction_output`)
- `clprRelated`
- `matchReasons`
- `customMatched`
- `customMatchReasons`
- `itemHash` (sha256 of serialized item JSON)
- `entities` (best-effort extracted Hedera IDs and EVM addresses)
- `itemSummary` (best-effort operational summary: status, consensus timestamps, output kind, etc.)

CLPR-relevant block-item records are also echoed to the tailer process log (`block-stream-*.log`) as concise line summaries.

### Decode-error record fields

- `recordType` = `decode_error`
- `observedAt`
- `label`
- `endpoint`
- `responseKind` = `decode_error`
- `attemptedStartBlock` (cursor at stream open)
- `failingBlock` (cursor at decode failure)
- `decodeErrorCountForBlock`
- `grpcExitCode`
- `grpcError`
- `action` (currently `skip_block`)

These records can occur in mixed-version or protobuf-path drift scenarios and are useful for proving that the tailer stayed live and progressed through the stream despite decode failures. In the current baseline clean rerun (`20260216T210811Z`), both source and destination feeds had `decode_error=0`.

### CLPR item relevance rules

A block item is marked `clprRelated=true` when any of these are true:
- item payload contains `clpr` (case-insensitive),
- item payload matches deployed CLPR addresses from `deployment.json`,
- item payload matches deployed connector IDs from `deployment.json`,
- extracted item entities include deployed CLPR contract IDs from `deployment.json`,
- item payload references the queue system contract address (`0x16e` / `0x000...016e`).

## Examples

Show only CLPR-relevant block items:

```bash
run_id=<run-id>
jq -c 'select(.recordType=="block_item" and .clprRelated==true)' \
  artifacts/clpr-native-messaging-solo/$run_id/block-stream-src.ndjson
```

Show frame-level CLPR item counts by block:

```bash
run_id=<run-id>
jq -c 'select(.recordType=="frame") | {blockNumber, clprItemCount, clprItemKinds}' \
  artifacts/clpr-native-messaging-solo/$run_id/block-stream-src.ndjson
```

Check decode-error count quickly:

```bash
run_id=<run-id>
for side in src dst; do
  f="artifacts/clpr-native-messaging-solo/$run_id/block-stream-$side.ndjson"
  n=$(rg -c '"type":"decode_error"' "$f" || true)
  n=${n:-0}
  echo "$side decode_error=$n"
done
```

## Suggested Future Enhancements

Potential additions that would improve demo operations:

1. Add `--match-contract-id` and `--match-account-id` flags for first-class Hedera entity filtering.
2. Add optional raw-frame sidecar output (`--raw-output-file`) for deeper forensic replay.
3. Add a summary mode that periodically writes per-item-kind counts and per-block latency stats.
4. Add Prometheus export mode for live dashboards without parsing NDJSON in custom scripts.
