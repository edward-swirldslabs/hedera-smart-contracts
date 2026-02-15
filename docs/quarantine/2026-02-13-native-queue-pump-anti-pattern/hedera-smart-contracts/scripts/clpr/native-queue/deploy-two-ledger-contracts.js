// SPDX-License-Identifier: Apache-2.0

/**
 * Deploy ClprMiddlewareHarness contracts to two CLPR-enabled ledgers via HAPI/gRPC.
 *
 * Required environment variables:
 *   CLPR_SRC_OPERATOR_KEY
 *   CLPR_DST_OPERATOR_KEY
 *
 * Optional environment variables:
 *   CLPR_SRC_GRPC_URL          (default: 127.0.0.1:50221)
 *   CLPR_DST_GRPC_URL          (default: 127.0.0.1:30212)
 *   CLPR_SRC_NODE_ACCOUNT_ID   (default: 0.0.3)
 *   CLPR_DST_NODE_ACCOUNT_ID   (default: 0.0.3)
 *   CLPR_SRC_OPERATOR_ID       (default: 0.0.2)
 *   CLPR_DST_OPERATOR_ID       (default: 0.0.2)
 *   CLPR_DEPLOY_GAS            (default: 4000000)
 *   CLPR_DEPLOY_OUTPUT         (default: ./artifacts/clpr-native-queue/issue-0013/latest/deployment.json)
 *   CLPR_HARNESS_BIN_PATH      (default: ../hiero-consensus-node/.../ClprMiddlewareHarness.bin)
 *   CLPR_HARNESS_ABI_PATH      (default: ../hiero-consensus-node/.../ClprMiddlewareHarness.json)
 */

const fs = require('fs');
const path = require('path');
const {
  AccountId,
  Client,
  ContractCreateFlow,
  ContractInfoQuery,
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

const readText = (filePath) => fs.readFileSync(filePath, 'utf8');

const resolveDefaultHarnessPaths = () => {
  const base = path.resolve(
    process.cwd(),
    '../hiero-consensus-node/hedera-node/test-clients/src/main/resources/contract/contracts/ClprMiddlewareHarness'
  );
  return {
    bin: path.join(base, 'ClprMiddlewareHarness.bin'),
    abi: path.join(base, 'ClprMiddlewareHarness.json'),
  };
};

const normalizeHexBytecode = (raw) => {
  const trimmed = raw.trim();
  if (!trimmed) {
    throw new Error('Harness bytecode file is empty');
  }
  return trimmed.startsWith('0x') ? trimmed : `0x${trimmed}`;
};

const deployHarness = async ({ client, bytecodeHex, gas }) => {
  const tx = await new ContractCreateFlow()
    .setGas(gas)
    .setBytecode(bytecodeHex)
    .execute(client);
  const receipt = await tx.getReceipt(client);
  const status = receipt.status.toString();
  if (status !== 'SUCCESS' || !receipt.contractId) {
    throw new Error(`Harness deploy failed: status=${status}`);
  }
  const contractId = receipt.contractId.toString();
  const info = await new ContractInfoQuery()
    .setContractId(receipt.contractId)
    .execute(client);
  const evmAddress = info.contractAccountId.startsWith('0x')
    ? info.contractAccountId
    : `0x${info.contractAccountId}`;
  return {
    contractId,
    evmAddress,
    txId: tx.transactionId ? tx.transactionId.toString() : '<unknown>',
  };
};

async function main() {
  const srcGrpc = env('CLPR_SRC_GRPC_URL', '127.0.0.1:50221');
  const dstGrpc = env('CLPR_DST_GRPC_URL', '127.0.0.1:30212');
  const srcNodeAccountId = env('CLPR_SRC_NODE_ACCOUNT_ID', '0.0.3');
  const dstNodeAccountId = env('CLPR_DST_NODE_ACCOUNT_ID', '0.0.3');
  const srcOperatorId = env('CLPR_SRC_OPERATOR_ID', '0.0.2');
  const dstOperatorId = env('CLPR_DST_OPERATOR_ID', '0.0.2');
  const srcOperatorKey = env('CLPR_SRC_OPERATOR_KEY', '');
  const dstOperatorKey = env('CLPR_DST_OPERATOR_KEY', '');
  const deployGas = Number(env('CLPR_DEPLOY_GAS', '4000000'));

  if (!srcOperatorKey || !dstOperatorKey) {
    throw new Error('Missing CLPR_SRC_OPERATOR_KEY and/or CLPR_DST_OPERATOR_KEY');
  }
  if (!Number.isFinite(deployGas) || deployGas <= 0) {
    throw new Error(`Invalid CLPR_DEPLOY_GAS value: ${deployGas}`);
  }

  const defaults = resolveDefaultHarnessPaths();
  const harnessBinPath = path.resolve(env('CLPR_HARNESS_BIN_PATH', defaults.bin));
  const harnessAbiPath = path.resolve(env('CLPR_HARNESS_ABI_PATH', defaults.abi));
  const outputPath = path.resolve(
    env(
      'CLPR_DEPLOY_OUTPUT',
      path.join(process.cwd(), 'artifacts/clpr-native-queue/issue-0013/latest/deployment.json')
    )
  );

  if (!fs.existsSync(harnessBinPath)) {
    throw new Error(`Harness bytecode file not found: ${harnessBinPath}`);
  }
  if (!fs.existsSync(harnessAbiPath)) {
    throw new Error(`Harness ABI file not found: ${harnessAbiPath}`);
  }

  const harnessBytecode = normalizeHexBytecode(readText(harnessBinPath));
  const harnessAbi = JSON.parse(readText(harnessAbiPath));
  if (!Array.isArray(harnessAbi) || harnessAbi.length === 0) {
    throw new Error(`Unexpected harness ABI contents in: ${harnessAbiPath}`);
  }

  console.log('CLPR_DEPLOY_STAGE=connect');
  const srcClient = createClient({
    grpcUrl: srcGrpc,
    nodeAccountId: srcNodeAccountId,
    operatorId: srcOperatorId,
    operatorKey: srcOperatorKey,
  });
  const dstClient = createClient({
    grpcUrl: dstGrpc,
    nodeAccountId: dstNodeAccountId,
    operatorId: dstOperatorId,
    operatorKey: dstOperatorKey,
  });

  try {
    console.log('CLPR_DEPLOY_STAGE=deploy-src');
    const src = await deployHarness({
      client: srcClient,
      bytecodeHex: harnessBytecode,
      gas: deployGas,
    });
    console.log(`CLPR_DEPLOY_SRC_HARNESS_ID=${src.contractId}`);
    console.log(`CLPR_DEPLOY_SRC_HARNESS_EVM=${src.evmAddress}`);
    console.log(`CLPR_DEPLOY_SRC_TX_ID=${src.txId}`);

    console.log('CLPR_DEPLOY_STAGE=deploy-dst');
    const dst = await deployHarness({
      client: dstClient,
      bytecodeHex: harnessBytecode,
      gas: deployGas,
    });
    console.log(`CLPR_DEPLOY_DST_HARNESS_ID=${dst.contractId}`);
    console.log(`CLPR_DEPLOY_DST_HARNESS_EVM=${dst.evmAddress}`);
    console.log(`CLPR_DEPLOY_DST_TX_ID=${dst.txId}`);

    const payload = {
      generatedAt: new Date().toISOString(),
      src: {
        grpcUrl: srcGrpc,
        nodeAccountId: srcNodeAccountId,
        operatorId: srcOperatorId,
        harnessContractId: src.contractId,
        harnessEvmAddress: src.evmAddress,
        deployTxId: src.txId,
      },
      dst: {
        grpcUrl: dstGrpc,
        nodeAccountId: dstNodeAccountId,
        operatorId: dstOperatorId,
        harnessContractId: dst.contractId,
        harnessEvmAddress: dst.evmAddress,
        deployTxId: dst.txId,
      },
      artifacts: {
        harnessBinPath,
        harnessAbiPath,
      },
    };

    fs.mkdirSync(path.dirname(outputPath), { recursive: true });
    fs.writeFileSync(outputPath, JSON.stringify(payload, null, 2), 'utf8');

    console.log('CLPR_DEPLOY_STAGE=complete');
    console.log(`CLPR_DEPLOY_OUTPUT=${outputPath}`);
    console.log('CLPR_DEPLOY_RESULT=PASS');
  } finally {
    srcClient.close();
    dstClient.close();
  }
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
