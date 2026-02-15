// SPDX-License-Identifier: Apache-2.0

/**
 * Executes one end-to-end native queue round-trip using ClprMiddlewareHarness.
 *
 * Required environment variables:
 *   CLPR_SRC_OPERATOR_KEY
 *   CLPR_DST_OPERATOR_KEY
 *   CLPR_REMOTE_LEDGER_ID_HEX   (32-byte hex ledger id for destination ledger)
 *
 * Optional environment variables:
 *   CLPR_DEPLOYMENT_JSON        (default: ./artifacts/clpr-native-queue/issue-0013/latest/deployment.json)
 *   CLPR_SMOKE_PAYLOAD          (default: solo-native-queue-smoke)
 *   CLPR_SMOKE_MODE             (default: send-and-assert; one of: send-and-assert, send-only, assert-only)
 *   CLPR_QUERY_GAS              (default: 500000)
 *   CLPR_EXEC_GAS               (default: 4000000)
 *   CLPR_POLL_MS                (default: 1000)
 *   CLPR_TIMEOUT_MS             (default: 180000)
 *   CLPR_SMOKE_RESULT_OUTPUT    (default: ./artifacts/clpr-native-queue/issue-0013/latest/invoke-result.json)
 */

const fs = require('fs');
const path = require('path');
const { ethers } = require('ethers');
const {
  AccountId,
  Client,
  ContractCallQuery,
  ContractExecuteTransaction,
  ContractId,
  Hbar,
  PrivateKey,
} = require('@hashgraph/sdk');

const env = (key, defaultValue = '') =>
  process.env[key] && process.env[key].trim() !== ''
    ? process.env[key].trim()
    : defaultValue;

const splitHostPort = (hostPort) => {
  const [host, portRaw] = hostPort.split(':');
  if (!host || !portRaw) {
    throw new Error(`Invalid host:port value: ${hostPort}`);
  }
  const port = Number(portRaw);
  if (!Number.isFinite(port) || port <= 0) {
    throw new Error(`Invalid port in host:port value: ${hostPort}`);
  }
  return { host, port };
};

const parsePrivateKey = (raw) => {
  const normalized = raw.trim().replace(/^0x/i, '');
  try {
    return PrivateKey.fromStringDer(normalized);
  } catch (derErr) {
    try {
      return PrivateKey.fromString(normalized);
    } catch (genericErr) {
      throw new Error(
        `Unable to parse private key. DER parse error=${derErr.message}; generic parse error=${genericErr.message}`
      );
    }
  }
};

const createClient = ({
  grpcUrl,
  nodeAccountId,
  operatorId,
  operatorKey,
}) => {
  const { host, port } = splitHostPort(grpcUrl);
  const nodeAddress = `${host}:${port}`;
  const client = Client.forNetwork({ [nodeAddress]: AccountId.fromString(nodeAccountId) });
  client.setOperator(AccountId.fromString(operatorId), parsePrivateKey(operatorKey));
  client.setDefaultMaxTransactionFee(new Hbar(20));
  return client;
};

const decodeSingleResult = (iface, fnName, encodedBytes) => {
  const decoded = iface.decodeFunctionResult(fnName, encodedBytes);
  return decoded.length === 1 ? decoded[0] : decoded;
};

const callView = async ({
  client,
  contractId,
  iface,
  fnName,
  args = [],
  gas,
}) => {
  const callData = iface.encodeFunctionData(fnName, args);
  const result = await new ContractCallQuery()
    .setContractId(ContractId.fromString(contractId))
    .setGas(gas)
    .setQueryPayment(new Hbar(2))
    .setFunctionParameters(ethers.getBytes(callData))
    .execute(client);
  const raw = ethers.hexlify(result.asBytes());
  return decodeSingleResult(iface, fnName, raw);
};

const executeTx = async ({
  client,
  contractId,
  iface,
  fnName,
  args = [],
  gas,
}) => {
  const callData = iface.encodeFunctionData(fnName, args);
  const tx = await new ContractExecuteTransaction()
    .setContractId(ContractId.fromString(contractId))
    .setGas(gas)
    .setFunctionParameters(ethers.getBytes(callData))
    .execute(client);
  const receipt = await tx.getReceipt(client);
  const status = receipt.status.toString();
  if (status !== 'SUCCESS') {
    throw new Error(
      `Execute failed: ${contractId}.${fnName} status=${status} txId=${tx.transactionId?.toString() || '<unknown>'}`
    );
  }
  return tx.transactionId?.toString() || '<unknown>';
};

const isTransientNetworkError = (error) => {
  if (!error) return false;
  const msg = typeof error.message === 'string' ? error.message : String(error);
  return (
    msg.includes('Network connectivity issue') ||
    msg.includes('All nodes are unhealthy') ||
    msg.includes('ECONNREFUSED') ||
    msg.includes('socket hang up') ||
    msg.includes('connection reset') ||
    msg.includes('RST_STREAM') ||
    msg.includes('UNAVAILABLE')
  );
};

const waitFor = async ({
  label,
  timeoutMs,
  pollMs,
  readFn,
  predicateFn,
}) => {
  const start = Date.now();
  while (Date.now() - start <= timeoutMs) {
    let value;
    try {
      // eslint-disable-next-line no-await-in-loop
      value = await readFn();
    } catch (error) {
      if (isTransientNetworkError(error)) {
        // Port-forwards can transiently drop; treat connectivity hiccups as retryable until timeout.
        // eslint-disable-next-line no-await-in-loop
        await new Promise((resolve) => setTimeout(resolve, pollMs));
        continue;
      }
      throw error;
    }
    if (predicateFn(value)) {
      return value;
    }
    // eslint-disable-next-line no-await-in-loop
    await new Promise((resolve) => setTimeout(resolve, pollMs));
  }
  throw new Error(`Timed out waiting for ${label}`);
};

const asBigInt = (value) => (typeof value === 'bigint' ? value : BigInt(value.toString()));

const normalizeHex = (value) => {
  const hex = typeof value === 'string' ? value : ethers.hexlify(value);
  return hex.startsWith('0x') ? hex.toLowerCase() : `0x${hex.toLowerCase()}`;
};

async function main() {
  const deploymentPath = path.resolve(
    env(
      'CLPR_DEPLOYMENT_JSON',
      path.join(process.cwd(), 'artifacts/clpr-native-queue/issue-0013/latest/deployment.json')
    )
  );
  if (!fs.existsSync(deploymentPath)) {
    throw new Error(`Deployment file not found: ${deploymentPath}`);
  }
  const deployment = JSON.parse(fs.readFileSync(deploymentPath, 'utf8'));
  const src = deployment?.src || {};
  const dst = deployment?.dst || {};
  if (!src.harnessContractId || !dst.harnessContractId || !dst.harnessEvmAddress) {
    throw new Error(`Deployment file missing required harness fields: ${deploymentPath}`);
  }

  const smokeMode = env('CLPR_SMOKE_MODE', 'send-and-assert').toLowerCase();
  const shouldSend = smokeMode === 'send-and-assert' || smokeMode === 'send-only';
  const shouldAssert = smokeMode === 'send-and-assert' || smokeMode === 'assert-only';
  if (!shouldSend && !shouldAssert) {
    throw new Error(`Invalid CLPR_SMOKE_MODE: ${smokeMode}`);
  }

  let remoteLedgerIdHex = '';
  if (shouldSend) {
    const remoteLedgerIdHexRaw = env('CLPR_REMOTE_LEDGER_ID_HEX', '');
    if (!remoteLedgerIdHexRaw) {
      throw new Error('Missing CLPR_REMOTE_LEDGER_ID_HEX');
    }
    remoteLedgerIdHex = remoteLedgerIdHexRaw.startsWith('0x')
      ? remoteLedgerIdHexRaw
      : `0x${remoteLedgerIdHexRaw}`;
    const remoteLedgerBytes = ethers.getBytes(remoteLedgerIdHex);
    if (remoteLedgerBytes.length !== 32) {
      throw new Error(`CLPR_REMOTE_LEDGER_ID_HEX must be 32 bytes, got ${remoteLedgerBytes.length}`);
    }
  } else {
    const remoteLedgerIdHexRaw = env('CLPR_REMOTE_LEDGER_ID_HEX', '');
    remoteLedgerIdHex = remoteLedgerIdHexRaw
      ? (remoteLedgerIdHexRaw.startsWith('0x') ? remoteLedgerIdHexRaw : `0x${remoteLedgerIdHexRaw}`)
      : '';
  }

  const srcOperatorKey = env('CLPR_SRC_OPERATOR_KEY', '');
  const dstOperatorKey = env('CLPR_DST_OPERATOR_KEY', '');
  if (!srcOperatorKey || !dstOperatorKey) {
    throw new Error('Missing CLPR_SRC_OPERATOR_KEY and/or CLPR_DST_OPERATOR_KEY');
  }

  const payloadText = env('CLPR_SMOKE_PAYLOAD', 'solo-native-queue-smoke');
  const payload = ethers.toUtf8Bytes(payloadText);
  const queryGas = Number(env('CLPR_QUERY_GAS', '500000'));
  const execGas = Number(env('CLPR_EXEC_GAS', '4000000'));
  const pollMs = Number(env('CLPR_POLL_MS', '1000'));
  const timeoutMs = Number(env('CLPR_TIMEOUT_MS', '180000'));
  const outputPath = path.resolve(
    env(
      'CLPR_SMOKE_RESULT_OUTPUT',
      path.join(process.cwd(), 'artifacts/clpr-native-queue/issue-0013/latest/invoke-result.json')
    )
  );

  const harnessAbiPath = deployment?.artifacts?.harnessAbiPath;
  if (!harnessAbiPath || !fs.existsSync(harnessAbiPath)) {
    throw new Error(`Harness ABI path missing or not found in deployment file: ${harnessAbiPath || '<empty>'}`);
  }
  const harnessAbi = JSON.parse(fs.readFileSync(harnessAbiPath, 'utf8'));
  const harnessIface = new ethers.Interface(harnessAbi);

  const srcClient = createClient({
    grpcUrl: src.grpcUrl,
    nodeAccountId: src.nodeAccountId,
    operatorId: src.operatorId,
    operatorKey: srcOperatorKey,
  });
  const dstClient = createClient({
    grpcUrl: dst.grpcUrl,
    nodeAccountId: dst.nodeAccountId,
    operatorId: dst.operatorId,
    operatorKey: dstOperatorKey,
  });

  try {
    let sendTxId = '';
    if (shouldSend) {
      console.log('CLPR_SMOKE_STAGE=send');
      sendTxId = await executeTx({
        client: srcClient,
        contractId: src.harnessContractId,
        iface: harnessIface,
        fnName: 'sendMessage',
        args: [remoteLedgerIdHex, dst.harnessEvmAddress, payload],
        gas: execGas,
      });
      console.log(`CLPR_SMOKE_TX_SOURCE_SEND=${sendTxId}`);
      if (!shouldAssert) {
        console.log('CLPR_SMOKE_STAGE=send-complete');
        console.log('CLPR_SMOKE_RESULT=PASS');
        return;
      }
    }

    console.log('CLPR_SMOKE_STAGE=await-destination-callback');
    const inboundMessageId = await waitFor({
      label: 'destination lastInboundMessageId > 0',
      timeoutMs,
      pollMs,
      readFn: async () =>
        asBigInt(
          await callView({
            client: dstClient,
            contractId: dst.harnessContractId,
            iface: harnessIface,
            fnName: 'lastInboundMessageId',
            gas: queryGas,
          })
        ),
      predicateFn: (value) => value > 0n,
    });
    console.log(`CLPR_SMOKE_DST_LAST_INBOUND_MESSAGE_ID=${inboundMessageId.toString()}`);
    const destinationPayload = await callView({
      client: dstClient,
      contractId: dst.harnessContractId,
      iface: harnessIface,
      fnName: 'lastInboundRequestData',
      gas: queryGas,
    });
    if (normalizeHex(destinationPayload) !== normalizeHex(payload)) {
      throw new Error('Destination callback payload mismatch');
    }

    console.log('CLPR_SMOKE_STAGE=await-source-response');
    const responseOriginalMessageId = await waitFor({
      label: `source lastResponseOriginalMessageId == ${inboundMessageId.toString()}`,
      timeoutMs,
      pollMs,
      readFn: async () =>
        asBigInt(
          await callView({
            client: srcClient,
            contractId: src.harnessContractId,
            iface: harnessIface,
            fnName: 'lastResponseOriginalMessageId',
            gas: queryGas,
          })
        ),
      predicateFn: (value) => value === inboundMessageId,
    });
    console.log(`CLPR_SMOKE_SRC_LAST_RESPONSE_ORIGINAL_MESSAGE_ID=${responseOriginalMessageId.toString()}`);
    const responsePayload = await callView({
      client: srcClient,
      contractId: src.harnessContractId,
      iface: harnessIface,
      fnName: 'lastResponseData',
      gas: queryGas,
    });
    if (normalizeHex(responsePayload) !== normalizeHex(payload)) {
      throw new Error('Source response payload mismatch');
    }

    const result = {
      generatedAt: new Date().toISOString(),
      payloadText,
      remoteLedgerIdHex: remoteLedgerIdHex ? normalizeHex(remoteLedgerIdHex) : '',
      sendTxId: sendTxId || '<not-sent>',
      assertions: {
        destinationLastInboundMessageId: inboundMessageId.toString(),
        sourceLastResponseOriginalMessageId: responseOriginalMessageId.toString(),
        destinationPayloadHex: normalizeHex(destinationPayload),
        sourceResponsePayloadHex: normalizeHex(responsePayload),
      },
    };
    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, JSON.stringify(result, null, 2), 'utf8');

    console.log('CLPR_SMOKE_STAGE=complete');
    console.log(`CLPR_SMOKE_RESULT_OUTPUT=${outputPath}`);
    console.log('CLPR_SMOKE_RESULT=PASS');
  } finally {
    srcClient.close();
    dstClient.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
