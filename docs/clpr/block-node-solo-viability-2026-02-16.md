<!-- SPDX-License-Identifier: Apache-2.0 -->

# Solo Block Node + Block Stream Viability (2026-02-16)

## Scope

Question investigated:

- Can we currently deploy a block node with Solo?
- Can we configure consensus nodes to produce block streams (instead of record-only)?
- Can mirror consume via block node (CN -> Block Node -> Mirror) in Solo today?

Environment used:

- Solo CLI: `0.55.0`
- Kubernetes context: `docker-desktop`
- Local repos used for source inspection:
  - `../solo`
  - `../hiero-block-node`
  - `../hiero-mirror-node`

## Executive Conclusion

Short answer: **Yes, with caveats**.

- Solo supports block node deployment and consensus block-stream wiring today.
- Consensus can be switched from `RECORDS` to `BOTH` with `FILE_AND_GRPC` writer mode when block node is configured.
- Mirror can consume from block node in Solo, but currently this requires **explicit mirror values/env configuration** (not automatic via `solo mirror node add` internals).

## Source Evidence (Code + Docs)

### 1. Solo has first-class block-node commands

- `solo --help` includes `block` command group.
- `solo block node add --help` exposes deployment options and defaults.

Related sources:

- `../solo/src/commands/command-definitions/block-command-definition.ts`
- `../solo/examples/network-with-block-node/README.md`

### 2. Solo network wiring updates consensus to block streaming

When block node mapping exists, Solo writes block config and updates app properties:

- writes `block-nodes.json` to consensus config path
- removes `blockStream.streamMode=RECORDS`
- sets:
  - `blockStream.streamMode=${BLOCK_STREAM_STREAM_MODE}` (default `BOTH`)
  - `blockStream.writerMode=${BLOCK_STREAM_WRITER_MODE}` (default `FILE_AND_GRPC`)

Source:

- `../solo/src/commands/network.ts:1388`
- `../solo/src/commands/network.ts:1395`
- `../solo/src/commands/network.ts:1399`
- `../solo/src/commands/network.ts:1411`

### 3. One-shot does not default to block-node

One-shot block-node add is gated by env var and default is disabled:

- `ONE_SHOT_WITH_BLOCK_NODE` defaults to `false`

Sources:

- `../solo/src/commands/one-shot/default-one-shot.ts:336`
- `../solo/src/core/constants.ts:252`
- `../solo/docs/site/content/en/docs/env.md:78`

### 4. Mirror importer supports blocknode profile

Mirror importer config includes a `blocknode` profile that:

- enables block importer
- sets source type `BLOCK_NODE`
- disables record downloader

Source:

- `../hiero-mirror-node/importer/src/main/resources/application.yml:132`
- `../hiero-mirror-node/importer/src/main/resources/application.yml:134`
- `../hiero-mirror-node/importer/src/main/resources/application.yml:137`
- `../hiero-mirror-node/importer/src/main/resources/application.yml:141`

### 5. Important Solo caveat: mirror auto block-node wiring is currently disabled in code

`MirrorNodeCommand.prepareBlockNodeIntegrationValues()` currently hard-codes `blockNodeSchemas = []`, so automatic bridge values are not applied from remote config.

Source:

- `../solo/src/commands/mirror-node.ts:273`
- `../solo/src/commands/mirror-node.ts:275`

## Runtime Spike Findings

A fresh temporary deployment (`solo-bn-viability`) was created to verify behavior end-to-end.

### Verified in-cluster state

Consensus node config showed block streaming enabled:

- `blockStream.streamMode=BOTH`
- `blockStream.writerMode=FILE_AND_GRPC`

Consensus `block-nodes.json` was present with block node FQDN:

```json
{
  "nodes": [
    {
      "address": "block-node-1.solo-bn-viability.svc.cluster.local",
      "port": 40840,
      "priority": 1
    }
  ],
  "blockItemBatchSize": 256
}
```

Mirror importer deployment had explicit block-node env applied:

- `SPRING_PROFILES_ACTIVE=blocknode`
- `HIERO_MIRROR_IMPORTER_BLOCK_NODES_0_HOST=block-node-1.solo-bn-viability.svc.cluster.local`

### Verified mirror/block-node runtime behavior

Importer log showed active block-node stream consumption:

- `BlockNodeSubscriber Start streaming block 0 from BlockNode(block-node-1.solo-bn-viability.svc.cluster.local:40840)`
- parser processed `.blk` files and inserted into mirror DB (`record_file`, `transaction`, etc.)

Block node logs showed repeated status requests from subscriber and non-empty available block range (`firstAvailableBlock=0, lastAvailableBlock=2`).

## Practical Guidance (Current-State)

For now, the reliable pattern is:

1. Add block node before or with consensus deploy.
2. Ensure consensus has `block-nodes.json` and block stream properties set (`BOTH` / `FILE_AND_GRPC`).
3. Add mirror with explicit values/env for blocknode profile, e.g.:

```yaml
importer:
  env:
    HIERO_MIRROR_IMPORTER_BLOCK_NODES_0_HOST: "block-node-1.<namespace>.svc.cluster.local"
    SPRING_PROFILES_ACTIVE: "blocknode"
```

4. Validate importer logs show `BlockNodeSubscriber Start streaming block ...`.
5. For CLPR scenario runs, use the native tailers in `scripts/clpr/native-messaging-solo/run-e2e.sh`:
   - `block-stream-src.ndjson`
   - `block-stream-dst.ndjson`
   These are direct BN subscriber feeds (server-streaming) with CLPR relevance tagging.

## Risks / Caveats

- Solo code currently disables automatic mirror block-node value generation (`blockNodeSchemas = []`), so relying on default `mirror node add` behavior may not wire block-node ingestion automatically.
- One-shot flows require explicit enablement (`ONE_SHOT_WITH_BLOCK_NODE=true`) and are not default-on.
- Operationally, mirror readiness can lag while DB migrations complete; readiness checks may take time on fresh DB.

## External References

- Hedera announcement: https://hedera.com/blog/hedera-block-nodes-in-private-preview/
- Solo FAQ (`v0.55.0`): https://solo.hiero.org/v0.55.0/docs/faq/
- Solo issue `#3367` (one-shot block-node DX): https://github.com/hiero-ledger/solo/issues/3367
- Solo block-node example docs: https://github.com/hiero-ledger/solo/tree/main/examples/network-with-block-node
- Mirror issue link referenced by Solo code: https://github.com/hiero-ledger/hiero-mirror-node/issues/12192
