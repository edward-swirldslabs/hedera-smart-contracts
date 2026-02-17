#!/usr/bin/env node
// SPDX-License-Identifier: Apache-2.0

/*
  CLPR block-stream tailer (BN subscriber).

  Purpose:
  - Subscribe directly to a block node using the block stream protocol.
  - Emit lightweight structured metadata for each response frame.
  - Flag CLPR-relevant frames by scanning for CLPR keywords and known deployment identifiers.

  Notes:
  - This tool is intentionally "read-only observability"; it does not persist full blocks.
  - It reconnects automatically if the stream drops.
*/

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawn } = require('node:child_process');

const METHOD = 'org.hiero.block.api.BlockStreamSubscribeService/subscribeBlockStream';
const PROTO_FILE = 'block-node/api/block_stream_subscribe_service.proto';
const MAX_UINT64 = '18446744073709551615';

function nowIso() {
  return new Date().toISOString();
}

function log(msg) {
  process.stderr.write(`[${nowIso()}] block-stream-tailer ${msg}\n`);
}

function parseArgs(argv) {
  const out = {
    endpoint: '',
    label: 'ledger',
    startBlock: '0',
    reconnectDelayMs: 1500,
    deploymentFile: '',
    outputFile: '',
    logAll: false,
    matchItemKinds: [],
    matchResponseKinds: [],
    matchKeywords: [],
    importPaths: [],
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    switch (arg) {
      case '--endpoint':
        out.endpoint = argv[++i] || '';
        break;
      case '--label':
        out.label = argv[++i] || out.label;
        break;
      case '--start-block':
        out.startBlock = argv[++i] || out.startBlock;
        break;
      case '--reconnect-delay-ms':
        out.reconnectDelayMs = Number(argv[++i] || out.reconnectDelayMs);
        break;
      case '--deployment-file':
        out.deploymentFile = argv[++i] || '';
        break;
      case '--output-file':
        out.outputFile = argv[++i] || '';
        break;
      case '--import-path':
        out.importPaths.push(argv[++i] || '');
        break;
      case '--log-all':
        out.logAll = true;
        break;
      case '--match-item-kind':
        out.matchItemKinds.push(argv[++i] || '');
        break;
      case '--match-response-kind':
        out.matchResponseKinds.push(argv[++i] || '');
        break;
      case '--match-keyword':
        out.matchKeywords.push(argv[++i] || '');
        break;
      case '-h':
      case '--help':
        printUsage();
        process.exit(0);
        break;
      default:
        throw new Error(`Unknown argument: ${arg}`);
    }
  }

  out.matchItemKinds = normalizeStrings(out.matchItemKinds);
  out.matchResponseKinds = normalizeStrings(out.matchResponseKinds);
  out.matchKeywords = normalizeStrings(out.matchKeywords);

  if (!out.endpoint) throw new Error('Missing required --endpoint <host:port>');
  return out;
}

function normalizeStrings(values) {
  const normalized = new Set();
  for (const value of values) {
    const trimmed = String(value || '')
      .trim()
      .toLowerCase();
    if (trimmed) normalized.add(trimmed);
  }
  return [...normalized];
}

function printUsage() {
  process.stdout.write(`Usage: block-stream-tailer.js --endpoint <host:port> [options]

Options:
  --label <name>                 Ledger label for output metadata (default: ledger)
  --start-block <n>              Start block number (default: 0)
  --deployment-file <path>       Optional run deployment.json for CLPR identifier matching
  --output-file <path>           Optional NDJSON output file (default: stdout only)
  --reconnect-delay-ms <ms>      Delay before reconnect after stream closes (default: 1500)
  --import-path <dir>            Extra grpcurl proto import path (repeatable)
  --match-item-kind <name>       Emit only frames containing this block-item kind (repeatable)
  --match-response-kind <kind>   Emit only these response kinds: block_items,end_of_block,status (repeatable)
  --match-keyword <text>         Emit only frames containing this case-insensitive substring (repeatable)
  --log-all                      Emit metadata for all frames (default: only CLPR-relevant)
  --help                         Show help
`);
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function collectRecursiveStrings(value, predicate, out) {
  if (value == null) return;
  if (Array.isArray(value)) {
    for (const item of value) collectRecursiveStrings(item, predicate, out);
    return;
  }
  if (typeof value === 'object') {
    for (const [k, v] of Object.entries(value)) {
      if (typeof v === 'string' && predicate(k, v)) out.add(v.toLowerCase());
      collectRecursiveStrings(v, predicate, out);
    }
  }
}

function loadDeploymentIdentifiers(filePath) {
  const empty = {
    addresses: new Set(),
    connectorIds: new Set(),
    contractIds: new Set(),
  };
  if (!filePath || !fs.existsSync(filePath)) return empty;

  try {
    const parsed = JSON.parse(fs.readFileSync(filePath, 'utf8'));
    const addresses = new Set();
    const connectorIds = new Set();
    const contractIds = new Set();

    collectRecursiveStrings(
      parsed,
      (k, v) => k === 'evmAddress' && v.startsWith('0x') && v.length === 42,
      addresses
    );
    collectRecursiveStrings(
      parsed,
      (k, v) => k.toLowerCase().includes('connector') && v.startsWith('0x'),
      connectorIds
    );

    const toNum = (value) => {
      if (typeof value === 'number') return value;
      if (typeof value === 'string' && value.trim() !== '') return Number(value);
      if (value && typeof value === 'object') {
        if (typeof value.low === 'number') return value.low;
        if (typeof value.low === 'string' && value.low.trim() !== '') return Number(value.low);
      }
      return null;
    };

    const walkForContractIds = (value, keyPath = []) => {
      if (value == null) return;
      if (Array.isArray(value)) {
        for (const entry of value) walkForContractIds(entry, keyPath);
        return;
      }
      if (typeof value !== 'object') return;

      const keyLower = keyPath.length > 0 ? String(keyPath[keyPath.length - 1]).toLowerCase() : '';
      if (Object.prototype.hasOwnProperty.call(value, 'shard') &&
          Object.prototype.hasOwnProperty.call(value, 'realm') &&
          Object.prototype.hasOwnProperty.call(value, 'num')) {
        const shard = toNum(value.shard);
        const realm = toNum(value.realm);
        const num = toNum(value.num);
        if (
          Number.isFinite(shard) &&
          Number.isFinite(realm) &&
          Number.isFinite(num) &&
          (keyLower.includes('contract') || keyLower === 'contractid')
        ) {
          contractIds.add(`${shard}.${realm}.${num}`);
        }
      }

      for (const [k, v] of Object.entries(value)) {
        walkForContractIds(v, keyPath.concat(k));
      }
    };
    walkForContractIds(parsed);

    // Support matching without `0x` prefix too.
    for (const addr of [...addresses]) addresses.add(addr.replace(/^0x/, ''));
    for (const id of [...connectorIds]) connectorIds.add(id.replace(/^0x/, ''));

    return { addresses, connectorIds, contractIds };
  } catch (err) {
    log(`WARN failed to parse deployment identifiers from ${filePath}: ${err.message}`);
    return empty;
  }
}

function resolveImportPaths(extraPaths) {
  const repoRoot = path.resolve(__dirname, '../../..');
  const cnRepoRoot = path.resolve(repoRoot, '../hiero-consensus-node');
  const candidates = [
    // Explicitly supplied paths take precedence over defaults.
    ...extraPaths,
    // Prefer consensus-node protobuf resources, since block-node stream payloads are CN-produced.
    path.resolve(cnRepoRoot, 'hapi/hapi/build/resources/main'),
    path.resolve(cnRepoRoot, 'hapi/hapi/build/extracted-protos/main'),
    path.resolve(cnRepoRoot, 'hapi/hedera-protobuf-java-api/build/resources/main'),
    path.resolve(cnRepoRoot, 'hapi/hedera-protobuf-java-api/src/main/proto'),
    // Fallbacks from local block-node checkout/build outputs.
    path.resolve(repoRoot, '../hiero-block-node/protobuf-sources/src/main/proto'),
    path.resolve(repoRoot, '../hiero-block-node/protobuf-sources/src/main/proto-overrides'),
    path.resolve(repoRoot, '../hiero-block-node/stream/build/hedera-protobufs'),
    path.resolve(repoRoot, '../hiero-block-node/stream/build/resources/main'),
  ];

  const resolved = [];
  const seen = new Set();
  for (const dir of candidates) {
    if (!dir) continue;
    const abs = path.resolve(dir);
    if (seen.has(abs)) continue;
    if (fs.existsSync(abs)) {
      seen.add(abs);
      resolved.push(abs);
    }
  }
  return resolved;
}

function parseJsonObjects(state, chunk) {
  state.buffer += chunk;
  const objects = [];

  let start = -1;
  let depth = 0;
  let inString = false;
  let escape = false;
  let lastConsumed = 0;

  for (let i = 0; i < state.buffer.length; i += 1) {
    const ch = state.buffer[i];

    if (start === -1) {
      if (ch === '{') {
        start = i;
        depth = 1;
        inString = false;
        escape = false;
      }
      continue;
    }

    if (inString) {
      if (escape) {
        escape = false;
      } else if (ch === '\\') {
        escape = true;
      } else if (ch === '"') {
        inString = false;
      }
      continue;
    }

    if (ch === '"') {
      inString = true;
      continue;
    }
    if (ch === '{') {
      depth += 1;
      continue;
    }
    if (ch === '}') {
      depth -= 1;
      if (depth === 0) {
        objects.push(state.buffer.slice(start, i + 1));
        lastConsumed = i + 1;
        start = -1;
      }
    }
  }

  if (lastConsumed > 0) {
    state.buffer = state.buffer.slice(lastConsumed);
  } else if (state.buffer.length > 1_000_000) {
    // Protect against runaway non-JSON logs on stdout.
    state.buffer = state.buffer.slice(-200_000);
  }

  return objects;
}

function get(obj, candidates) {
  for (const pathSpec of candidates) {
    let cur = obj;
    let ok = true;
    for (const part of pathSpec) {
      if (cur == null || !(part in cur)) {
        ok = false;
        break;
      }
      cur = cur[part];
    }
    if (ok) return cur;
  }
  return undefined;
}

function normalizeKind(frame) {
  if (frame.status != null) return 'status';
  if (frame.endOfBlock != null || frame.end_of_block != null) return 'end_of_block';
  if (frame.blockItems != null || frame.block_items != null) return 'block_items';
  return 'unknown';
}

function extractBlockNumber(frame, state) {
  const endBlock = get(frame, [['endOfBlock', 'blockNumber'], ['end_of_block', 'block_number']]);
  if (endBlock != null) {
    state.lastCompletedBlock = String(endBlock);
    return String(endBlock);
  }

  const headerNum = get(frame, [
    ['blockItems', 'blockItems', 0, 'blockHeader', 'number'],
    ['block_items', 'block_items', 0, 'block_header', 'number'],
    ['blockItems', 'blockItems', 0, 'recordFile', 'recordFile', 'consensusEnd'],
  ]);
  if (headerNum != null) return String(headerNum);

  return state.lastCompletedBlock || null;
}

function extractItemMeta(frame) {
  const items =
    get(frame, [['blockItems', 'blockItems'], ['block_items', 'block_items']]) || [];
  if (!Array.isArray(items)) return { itemCount: 0, itemKinds: [] };

  const kinds = new Set();
  for (const item of items) {
    if (item && typeof item === 'object') {
      const keys = Object.keys(item);
      if (keys.length > 0) kinds.add(keys[0]);
    }
  }
  return { itemCount: items.length, itemKinds: [...kinds].slice(0, 8) };
}

function detectClpr(serializedLower, filters) {
  const reasons = [];

  if (serializedLower.includes('clpr')) reasons.push('contains-clpr-keyword');

  for (const addr of filters.addresses) {
    if (addr && serializedLower.includes(addr)) {
      reasons.push(`matches-deployed-address:${addr.slice(0, 14)}`);
      break;
    }
  }

  for (const connectorId of filters.connectorIds) {
    if (connectorId && serializedLower.includes(connectorId)) {
      reasons.push(`matches-connector-id:${connectorId.slice(0, 14)}`);
      break;
    }
  }

  for (const contractId of filters.contractIds) {
    if (contractId && serializedLower.includes(contractId)) {
      reasons.push(`matches-contract-id:${contractId}`);
      break;
    }
  }

  return { clprRelated: reasons.length > 0, reasons };
}

function detectCustomMatch(serializedLower, responseKind, itemKinds, args) {
  const requirements = [];
  const reasons = [];

  if (args.matchResponseKinds.length > 0) {
    const matched = args.matchResponseKinds.includes(String(responseKind || '').toLowerCase());
    requirements.push(matched);
    if (matched) reasons.push(`matches-response-kind:${responseKind}`);
  }

  if (args.matchItemKinds.length > 0) {
    const normalizedItemKinds = itemKinds.map((kind) => String(kind || '').toLowerCase());
    const matchedKind = normalizedItemKinds.find((kind) => args.matchItemKinds.includes(kind));
    const matched = Boolean(matchedKind);
    requirements.push(matched);
    if (matched) reasons.push(`matches-item-kind:${matchedKind}`);
  }

  if (args.matchKeywords.length > 0) {
    const matchedKeyword = args.matchKeywords.find((keyword) => serializedLower.includes(keyword));
    const matched = Boolean(matchedKeyword);
    requirements.push(matched);
    if (matched) reasons.push(`matches-keyword:${matchedKeyword}`);
  }

  const matched = requirements.length > 0 && requirements.every(Boolean);
  return { matched, reasons };
}

function extractBlockItems(frame) {
  const items =
    get(frame, [['blockItems', 'blockItems'], ['block_items', 'block_items']]) || [];
  return Array.isArray(items) ? items : [];
}

function toHexOrOriginal(bytesString) {
  if (typeof bytesString !== 'string' || bytesString.length === 0) return null;
  if (bytesString.startsWith('0x')) return bytesString.toLowerCase();
  try {
    const raw = Buffer.from(bytesString, 'base64');
    if (raw.length === 0) return null;
    return `0x${raw.toString('hex')}`;
  } catch (_) {
    return bytesString.toLowerCase();
  }
}

function normalizeNumberLike(value) {
  if (value == null) return null;
  if (typeof value === 'number' || typeof value === 'bigint') return String(value);
  if (typeof value === 'string' && value.trim() !== '') return value.trim();
  return null;
}

function getField(obj, names) {
  for (const name of names) {
    if (obj != null && Object.prototype.hasOwnProperty.call(obj, name)) {
      return obj[name];
    }
  }
  return undefined;
}

function formatEntityId(entityObj, keyLower) {
  if (entityObj == null || typeof entityObj !== 'object' || Array.isArray(entityObj)) return null;

  const shard = normalizeNumberLike(getField(entityObj, ['shardNum', 'shard_num'])) || '0';
  const realm = normalizeNumberLike(getField(entityObj, ['realmNum', 'realm_num'])) || '0';

  const entityTypeCandidates = [
    ['contract', ['contractNum', 'contract_num']],
    ['account', ['accountNum', 'account_num']],
    ['token', ['tokenNum', 'token_num']],
    ['topic', ['topicNum', 'topic_num']],
    ['schedule', ['scheduleNum', 'schedule_num']],
    ['file', ['fileNum', 'file_num']],
    ['node', ['nodeId', 'node_id']],
  ];

  for (const [entityType, fieldCandidates] of entityTypeCandidates) {
    const num = normalizeNumberLike(getField(entityObj, fieldCandidates));
    if (num != null) return { entityType, value: `${shard}.${realm}.${num}` };
  }

  const evmAddress = getField(entityObj, ['evmAddress', 'evm_address']);
  if (evmAddress != null && keyLower.includes('contract')) {
    const parsed = toHexOrOriginal(evmAddress);
    if (parsed) return { entityType: 'contract_evm_address', value: parsed };
  }

  return null;
}

function scanItemForEntities(item) {
  const found = {
    contractIds: new Set(),
    accountIds: new Set(),
    tokenIds: new Set(),
    topicIds: new Set(),
    scheduleIds: new Set(),
    fileIds: new Set(),
    nodeIds: new Set(),
    evmAddresses: new Set(),
  };

  const walk = (value, keyPath) => {
    if (value == null) return;
    if (Array.isArray(value)) {
      for (const entry of value) walk(entry, keyPath);
      return;
    }
    if (typeof value !== 'object') return;

    for (const [k, v] of Object.entries(value)) {
      const keyLower = String(k).toLowerCase();
      const nextPath = keyPath.concat(k);

      if (v != null && typeof v === 'object' && !Array.isArray(v)) {
        const formatted = formatEntityId(v, keyLower);
        if (formatted != null) {
          switch (formatted.entityType) {
            case 'contract':
              found.contractIds.add(formatted.value);
              break;
            case 'account':
              found.accountIds.add(formatted.value);
              break;
            case 'token':
              found.tokenIds.add(formatted.value);
              break;
            case 'topic':
              found.topicIds.add(formatted.value);
              break;
            case 'schedule':
              found.scheduleIds.add(formatted.value);
              break;
            case 'file':
              found.fileIds.add(formatted.value);
              break;
            case 'node':
              found.nodeIds.add(formatted.value);
              break;
            case 'contract_evm_address':
              found.evmAddresses.add(formatted.value);
              break;
            default:
              break;
          }
        }
      }

      if (typeof v === 'string') {
        if (keyLower.includes('evmaddress') || keyLower.includes('evm_address')) {
          const parsed = toHexOrOriginal(v);
          if (parsed) found.evmAddresses.add(parsed);
        } else if (keyLower.includes('address') && v.length > 0) {
          const parsed = toHexOrOriginal(v);
          if (parsed && parsed.startsWith('0x')) found.evmAddresses.add(parsed);
        }
      }

      walk(v, nextPath);
    }
  };

  walk(item, []);
  return {
    contractIds: [...found.contractIds],
    accountIds: [...found.accountIds],
    tokenIds: [...found.tokenIds],
    topicIds: [...found.topicIds],
    scheduleIds: [...found.scheduleIds],
    fileIds: [...found.fileIds],
    nodeIds: [...found.nodeIds],
    evmAddresses: [...found.evmAddresses].slice(0, 16),
  };
}

function scanForSystemContractQueue(serializedLower) {
  const reasons = [];
  if (serializedLower.includes('0x16e')) {
    reasons.push('mentions-system-contract-0x16e');
  }
  if (serializedLower.includes('000000000000000000000000000000000000016e')) {
    reasons.push('mentions-system-contract-0x000...016e');
  }
  return reasons;
}

function summarizeItem(item, itemKind) {
  const txResult = get(item, [
    ['transactionResult'],
    ['transaction_result'],
  ]);
  const txOutput = get(item, [['transactionOutput'], ['transaction_output']]);
  const eventTxn = get(item, [['eventTransaction'], ['event_transaction']]);

  const summary = {
    itemKind,
    status: get(txResult, [['status']]) ?? null,
    consensusTimestamp:
      get(txResult, [['consensusTimestamp'], ['consensus_timestamp']]) ?? null,
    parentConsensusTimestamp:
      get(txResult, [['parentConsensusTimestamp'], ['parent_consensus_timestamp']]) ?? null,
    transactionFeeCharged:
      get(txResult, [['transactionFeeCharged'], ['transaction_fee_charged']]) ?? null,
    outputKind:
      txOutput && typeof txOutput === 'object'
        ? Object.keys(txOutput)[0] || null
        : null,
    hasApplicationTransaction:
      eventTxn && typeof eventTxn === 'object'
        ? get(eventTxn, [['applicationTransaction'], ['application_transaction']]) != null
        : false,
  };

  return summary;
}

function inspectBlockItems(items, filters, args) {
  const records = [];
  items.forEach((item, index) => {
    if (item == null || typeof item !== 'object') return;

    const itemKind = Object.keys(item)[0] || 'unknown';
    const serialized = JSON.stringify(item);
    const serializedLower = serialized.toLowerCase();
    const clpr = detectClpr(serializedLower, filters);
    const custom = detectCustomMatch(
      serializedLower,
      'block_items',
      [itemKind],
      args
    );
    const queueReasons = scanForSystemContractQueue(serializedLower);
    const entities = scanItemForEntities(item);
    const entityReasons = [];

    if (filters.contractIds && filters.contractIds.size > 0) {
      for (const contractId of entities.contractIds || []) {
        if (filters.contractIds.has(contractId.toLowerCase())) {
          entityReasons.push(`matches-entity-contract-id:${contractId}`);
          break;
        }
      }
    }

    if (filters.addresses && filters.addresses.size > 0) {
      for (const evmAddress of entities.evmAddresses || []) {
        const normalized = String(evmAddress || '').toLowerCase().replace(/^0x/, '');
        if (filters.addresses.has(normalized) || filters.addresses.has(`0x${normalized}`)) {
          entityReasons.push(`matches-entity-evm-address:${normalized.slice(0, 14)}`);
          break;
        }
      }
    }

    const matchReasons = [...clpr.reasons, ...queueReasons, ...entityReasons];
    const clprRelated = matchReasons.length > 0;

    const shouldEmit = args.logAll || clprRelated || custom.matched;
    if (!shouldEmit) return;

    const itemSummary = summarizeItem(item, itemKind);
    const itemHash = crypto.createHash('sha256').update(serialized).digest('hex');

    records.push({
      itemIndex: index,
      itemKind,
      clprRelated,
      matchReasons,
      customMatched: custom.matched,
      customMatchReasons: custom.reasons,
      itemHash,
      entities,
      itemSummary,
    });
  });
  return records;
}

async function main() {
  const args = parseArgs(process.argv.slice(2));
  const importPaths = resolveImportPaths(args.importPaths);
  if (importPaths.length === 0) {
    throw new Error(
      'No grpcurl proto import paths found. Build sibling block-node protos first (e.g. ../hiero-block-node/stream/build/hedera-protobufs).'
    );
  }

  if (args.outputFile) {
    fs.mkdirSync(path.dirname(path.resolve(args.outputFile)), { recursive: true });
  }
  const output = args.outputFile
    ? fs.createWriteStream(path.resolve(args.outputFile), { flags: 'a' })
    : process.stdout;

  const streamState = { buffer: '', lastCompletedBlock: null };
  const filterState = {
    ids: loadDeploymentIdentifiers(args.deploymentFile),
    lastRefreshMs: 0,
  };

  let nextStart = BigInt(args.startBlock);
  let child = null;
  let stopping = false;
  let lastDecodeErrorBlock = null;
  let decodeErrorCountForBlock = 0;

  const refreshIdentifiers = () => {
    if (!args.deploymentFile) return;
    const now = Date.now();
    if (now - filterState.lastRefreshMs < 2000) return;
    filterState.lastRefreshMs = now;
    filterState.ids = loadDeploymentIdentifiers(args.deploymentFile);
  };

  const writeMeta = (meta) => {
    output.write(JSON.stringify(meta) + '\n');
  };

  const stop = () => {
    if (stopping) return;
    stopping = true;
    if (child) {
      child.kill('SIGTERM');
    }
  };
  process.on('SIGINT', stop);
  process.on('SIGTERM', stop);

  while (!stopping) {
    refreshIdentifiers();
    const attemptStart = nextStart;
    const requestJson = JSON.stringify({
      start_block_number: nextStart.toString(),
      end_block_number: MAX_UINT64,
    });

    const grpcArgs = ['-plaintext'];
    for (const importPath of importPaths) {
      grpcArgs.push('-import-path', importPath);
    }
    grpcArgs.push('-proto', PROTO_FILE, '-d', requestJson, args.endpoint, METHOD);

    log(
      `connect label=${args.label} endpoint=${args.endpoint} startBlock=${nextStart} importPaths=${importPaths.length}`
    );

    child = spawn('grpcurl', grpcArgs, { stdio: ['ignore', 'pipe', 'pipe'] });
    let grpcErrorText = '';

    child.stderr.on('data', (chunk) => {
      const text = String(chunk).trim();
      if (text) {
        grpcErrorText += `${text}\n`;
        if (grpcErrorText.length > 8000) {
          grpcErrorText = grpcErrorText.slice(-8000);
        }
        log(`grpcurl stderr (${args.label}): ${text}`);
      }
    });

    child.stdout.on('data', (chunk) => {
      const objects = parseJsonObjects(streamState, String(chunk));
      for (const objectText of objects) {
        let frame;
        try {
          frame = JSON.parse(objectText);
        } catch (err) {
          log(`WARN failed to parse streamed frame: ${err.message}`);
          continue;
        }

        refreshIdentifiers();

        const responseKind = normalizeKind(frame);
        const blockNumber = extractBlockNumber(frame, streamState);
        const items = extractBlockItems(frame);
        const { itemCount, itemKinds } = extractItemMeta(frame);
        const serializedLower = objectText.toLowerCase();
        const clpr = detectClpr(serializedLower, filterState.ids);
        const custom = detectCustomMatch(serializedLower, responseKind, itemKinds, args);
        const clprItems =
          responseKind === 'block_items'
            ? inspectBlockItems(items, filterState.ids, args)
            : [];
        const clprRelatedItems = clprItems.filter((item) => item.clprRelated);
        const clprItemKinds = [
          ...new Set(clprRelatedItems.map((item) => item.itemKind)),
        ].slice(0, 12);

        if (responseKind === 'end_of_block' && blockNumber != null) {
          try {
            nextStart = BigInt(blockNumber) + 1n;
          } catch (_) {
            // Keep prior cursor if conversion fails.
          }
        }

        if (args.logAll || clpr.clprRelated || custom.matched || clprItems.length > 0) {
          writeMeta({
            observedAt: nowIso(),
            recordType: 'frame',
            label: args.label,
            endpoint: args.endpoint,
            responseKind,
            blockNumber,
            itemCount,
            itemKinds,
            clprRelated: clpr.clprRelated,
            matchReasons: clpr.reasons,
            customMatched: custom.matched,
            customMatchReasons: custom.reasons,
            clprItemCount: clprRelatedItems.length,
            clprItemKinds,
          });
        }

        for (const itemRecord of clprItems) {
          writeMeta({
            observedAt: nowIso(),
            recordType: 'block_item',
            label: args.label,
            endpoint: args.endpoint,
            responseKind,
            blockNumber,
            ...itemRecord,
          });
          if (itemRecord.clprRelated) {
            log(
              `clpr-item label=${args.label} block=${blockNumber ?? 'unknown'} index=${itemRecord.itemIndex} kind=${itemRecord.itemKind} reasons=${itemRecord.matchReasons.join(',') || 'none'}`
            );
          }
        }
      }
    });

    const exit = await new Promise((resolve) => {
      child.on('exit', (code, signal) => resolve({ code, signal }));
    });
    child = null;

    if (stopping) break;

    const grpcErrorLower = grpcErrorText.toLowerCase();
    const isProtoDecodeError =
      exit.code === 77 &&
      (grpcErrorLower.includes('failed to unmarshal the received message') ||
        grpcErrorLower.includes('proto: integer overflow') ||
        grpcErrorLower.includes('proto: bad wiretype'));

    if (isProtoDecodeError) {
      const failingBlock = nextStart;
      if (lastDecodeErrorBlock != null && failingBlock === lastDecodeErrorBlock) {
        decodeErrorCountForBlock += 1;
      } else {
        lastDecodeErrorBlock = failingBlock;
        decodeErrorCountForBlock = 1;
      }

      // grpcurl can fail to decode specific block payloads in some mixed-version stacks.
      // TEMPORARY observability behavior: skip known-bad blocks so live tailing can continue.
      writeMeta({
        observedAt: nowIso(),
        recordType: 'decode_error',
        label: args.label,
        endpoint: args.endpoint,
        responseKind: 'decode_error',
        attemptedStartBlock: attemptStart.toString(),
        failingBlock: failingBlock.toString(),
        decodeErrorCountForBlock,
        grpcExitCode: exit.code,
        grpcError: grpcErrorText.trim() || null,
        action: 'skip_block',
      });

      log(
        `decode error at block=${failingBlock} label=${args.label}; skipping block and continuing live tail`
      );
      nextStart = failingBlock + 1n;
      streamState.lastCompletedBlock = failingBlock.toString();
      await sleep(args.reconnectDelayMs);
      continue;
    }

    // Reset decode-error tracking after a normal stream cycle.
    lastDecodeErrorBlock = null;
    decodeErrorCountForBlock = 0;

    log(
      `stream closed label=${args.label} endpoint=${args.endpoint} code=${exit.code} signal=${exit.signal}; reconnect in ${args.reconnectDelayMs}ms`
    );
    await sleep(args.reconnectDelayMs);
  }

  if (args.outputFile) {
    output.end();
  }
  log(`stopped label=${args.label} endpoint=${args.endpoint}`);
}

main().catch((err) => {
  log(`fatal: ${err.message}`);
  process.exit(1);
});
