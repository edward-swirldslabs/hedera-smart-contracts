// SPDX-License-Identifier: Apache-2.0

/*
  End-to-end SOLO scenario runner (two ledgers, no pump).

  This script assumes:
  - Two SOLO namespaces are running (source + destination).
  - CLPR config exchange has already been performed (the allowed "kick").
  - CLPR message queues are initialized on both ledgers.

  It then:
  - Deploys middleware on both ledgers with queue = 0x16e system contract.
  - Deploys connectors, funds destination connectors, deploys source/echo apps.
  - Sends 6 messages from source:
    - each send tries connector1 (deny), then connector2 (accept until funds run out), then connector3.
  - Tops up destination connector2 once it is underfunded, verifies source middleware learns this via control messaging,
    then verifies connector2 is usable for one send and becomes underfunded again.
*/

const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert');

const { ethers } = require('ethers');
const {
  AccountId,
  Client,
  ContractCallQuery,
  ContractCreateFlow,
  ContractExecuteTransaction,
  Hbar,
  PrivateKey,
} = require('@hashgraph/sdk');
const { deriveConnectorIds } = require('../shared/connector-ids');

const ZERO_ADDRESS = '0x0000000000000000000000000000000000000000';
const CLPR_QUEUE_SYSTEM_CONTRACT = '0x000000000000000000000000000000000000016e';

const ETH_UNIT = 'ETH';
const WETH_UNIT = 'WETH';

const DEST_MIN_CHARGE = 50n;
const DEST_SAFETY_THRESHOLD = 60n;
const CONNECTOR2_TOPOFF = 50n;
const UINT256_MAX = (1n << 256n) - 1n;

function env(name, fallback = undefined) {
  const v = process.env[name];
  return v == null || v === '' ? fallback : v;
}

function mustEnv(name) {
  const v = env(name);
  if (v == null) throw new Error(`Missing required env var: ${name}`);
  return v;
}

function sleep(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function phase(message) {
  console.log(`[SCENARIO] ${message}`);
}

function loadArtifact(relPath) {
  const fullPath = path.join(process.cwd(), relPath);
  return JSON.parse(fs.readFileSync(fullPath, 'utf8'));
}

function toUint8Array(hex) {
  return ethers.getBytes(hex);
}

function solidityAddrFromContractId(contractId) {
  // JS SDK returns 40 hex chars (no 0x).
  return '0x' + contractId.toSolidityAddress();
}

function solidityAddrFromAccountId(accountIdStr) {
  return '0x' + AccountId.fromString(accountIdStr).toSolidityAddress();
}

function hederaClientFor(endpoint, nodeAccountIdStr, operatorIdStr, operatorKeyStr) {
  const network = {};
  network[endpoint] = AccountId.fromString(nodeAccountIdStr);
  const client = Client.forNetwork(network);
  client.setOperator(AccountId.fromString(operatorIdStr), PrivateKey.fromString(operatorKeyStr));
  // SOLO gRPC port-forwarding can be bursty; raise retry/timeout defaults to reduce transient TIMEOUT flakes.
  const maxAttempts = Number(env('HEDERA_MAX_ATTEMPTS', '30'));
  const requestTimeoutMs = Number(env('HEDERA_REQUEST_TIMEOUT_MS', '60000'));
  if (Number.isFinite(maxAttempts) && maxAttempts > 0) {
    client.setMaxAttempts(maxAttempts);
  }
  if (Number.isFinite(requestTimeoutMs) && requestTimeoutMs > 0) {
    client.setRequestTimeout(requestTimeoutMs);
  }
  // Keep fees/gas conservative to avoid flaky under-estimation.
  client.setDefaultMaxTransactionFee(new Hbar(50));
  client.setDefaultMaxQueryPayment(new Hbar(5));
  return client;
}

async function deployContract(client, artifact, constructorArgs, opts = {}) {
  const gas = opts.gas ?? 4_000_000;
  const initialBalanceTinybar = opts.initialBalanceTinybar ?? 0;

  const factory = new ethers.ContractFactory(artifact.abi, artifact.bytecode);
  const ctorParams = factory.interface.encodeDeploy(constructorArgs);

  const flow = new ContractCreateFlow()
    .setBytecode(artifact.bytecode)
    .setConstructorParameters(toUint8Array(ctorParams))
    .setGas(gas);

  if (initialBalanceTinybar > 0) {
    flow.setInitialBalance(Hbar.fromTinybars(initialBalanceTinybar));
  }

  const txResp = await flow.execute(client);
  const receipt = await txResp.getReceipt(client);
  const contractId = receipt.contractId;
  if (!contractId) throw new Error('Missing contractId in receipt');

  return {
    contractId,
    evmAddress: solidityAddrFromContractId(contractId),
  };
}

async function executeContract(client, contractId, callDataHex, opts = {}) {
  const gas = opts.gas ?? 1_000_000;
  const payableTinybar = opts.payableTinybar ?? 0;
  const tx = new ContractExecuteTransaction()
    .setContractId(contractId)
    .setGas(gas)
    .setFunctionParameters(toUint8Array(callDataHex));
  if (payableTinybar > 0) {
    tx.setPayableAmount(Hbar.fromTinybars(payableTinybar));
  }
  const txResp = await tx.execute(client);
  return await txResp.getReceipt(client);
}

async function callContract(client, contractId, callDataHex, opts = {}) {
  const gas = opts.gas ?? 250_000;
  const query = new ContractCallQuery()
    .setContractId(contractId)
    .setGas(gas)
    .setFunctionParameters(toUint8Array(callDataHex));
  return await query.execute(client);
}

async function main() {
  const runDir = env('RUN_DIR');
  if (runDir) fs.mkdirSync(runDir, { recursive: true });
  phase('starting deployment and execution');

  const srcGrpc = mustEnv('SRC_GRPC_ENDPOINT');
  const dstGrpc = mustEnv('DST_GRPC_ENDPOINT');
  const srcLedgerId = mustEnv('SRC_LEDGER_ID_HEX');
  const dstLedgerId = mustEnv('DST_LEDGER_ID_HEX');

  const operatorId = env('OPERATOR_ID', '0.0.2');
  const nodeAccountId = env('NODE_ACCOUNT_ID', '0.0.3');
  const operatorSolidityAddress = solidityAddrFromAccountId(operatorId);
  // CLPR inbound bundle processing dispatches synthetic ContractCall transactions using the CLPR txn payer.
  // In SOLO we submit CLPR transactions as the operator (default 0.0.2), so middleware callbacks will appear
  // as coming from the operator's EVM address (unless overridden).
  const trustedCallbackCaller = env('TRUSTED_CALLBACK_CALLER', solidityAddrFromAccountId(operatorId));

  let operatorKey = env('OPERATOR_KEY');
  if (!operatorKey) {
    const keyPath = env(
      'GENESIS_PRIVKEY_PATH',
      path.join(process.cwd(), '../hiero-consensus-node/hedera-node/data/onboard/GenesisPrivKey.txt')
    );
    operatorKey = fs.readFileSync(keyPath, 'utf8').trim();
  }

  const clientSrc = hederaClientFor(srcGrpc, nodeAccountId, operatorId, operatorKey);
  const clientDst = hederaClientFor(dstGrpc, nodeAccountId, operatorId, operatorKey);
  try {

  const artifacts = {
    ClprMiddleware: loadArtifact(
      'artifacts/contracts/solidity/clpr/middleware/ClprMiddleware.sol/ClprMiddleware.json'
    ),
    MockClprConnector: loadArtifact(
      'artifacts/contracts/solidity/clpr/mocks/MockClprConnector.sol/MockClprConnector.json'
    ),
    SourceApplication: loadArtifact(
      'artifacts/contracts/solidity/clpr/apps/SourceApplication.sol/SourceApplication.json'
    ),
    EchoApplication: loadArtifact(
      'artifacts/contracts/solidity/clpr/apps/EchoApplication.sol/EchoApplication.json'
    ),
    OZERC20Mock: loadArtifact(
      'artifacts/contracts/openzeppelin/ERC-20/ERC20Mock.sol/OZERC20Mock.json'
    ),
  };

  // Derive connector ids (models spec intent: ids differ across ledgers but are deterministically paired).
  const connectorIds = deriveConnectorIds(ethers, srcLedgerId, dstLedgerId);
  const [srcConnectorId1, srcConnectorId2, srcConnectorId3] = connectorIds.source;
  const [dstConnectorId1, dstConnectorId2, dstConnectorId3] = connectorIds.destination;

  const deployment = {
    src: {},
    dst: {},
    connectorIds: {
      src: [srcConnectorId1, srcConnectorId2, srcConnectorId3],
      dst: [dstConnectorId1, dstConnectorId2, dstConnectorId3],
    },
  };

  // Destination: deploy WETH + middleware + connectors + echo app.
  const weth = await deployContract(clientDst, artifacts.OZERC20Mock, ['Wrapped ETH', 'WETH'], { gas: 1_200_000 });
  deployment.dst.weth = weth;

  const dstMw = await deployContract(
    clientDst,
    artifacts.ClprMiddleware,
    [CLPR_QUEUE_SYSTEM_CONTRACT, dstLedgerId],
    { gas: 8_000_000 }
  );
  deployment.dst.middleware = dstMw;

  // Allow synthetic callback calls (CLPR bundle processing) to reach middleware handlers.
  {
    const iface = new ethers.Interface(artifacts.ClprMiddleware.abi);
    await executeContract(
      clientDst,
      dstMw.contractId,
      iface.encodeFunctionData('setTrustedCallbackCaller', [trustedCallbackCaller]),
      { gas: 300_000 }
    );
  }

  const connectorFactory = new ethers.ContractFactory(
    artifacts.MockClprConnector.abi,
    artifacts.MockClprConnector.bytecode
  );

  const dstConnectors = [];
  for (const [idx, connectorId] of deployment.connectorIds.dst.entries()) {
    const expectedRemote =
      idx === 0 ? srcConnectorId1 : idx === 1 ? srcConnectorId2 : srcConnectorId3;
    const connector = await deployContract(
      clientDst,
      artifacts.MockClprConnector,
      [
        connectorId,
        expectedRemote,
        srcLedgerId,
        WETH_UNIT,
        weth.evmAddress,
        DEST_SAFETY_THRESHOLD,
        DEST_MIN_CHARGE,
        UINT256_MAX,
        { value: UINT256_MAX, unit: WETH_UNIT },
      ],
      { gas: 5_000_000 }
    );
    dstConnectors.push(connector);
  }
  deployment.dst.connectors = dstConnectors;

  // Fund destination connectors:
  // - connector 2: enough for two reimbursements of 50, then hits safety threshold boundary (160 -> 60)
  // - connector 3: enough for multiple reimbursements.
  {
    const iface = new ethers.Interface(artifacts.OZERC20Mock.abi);
    await executeContract(
      clientDst,
      weth.contractId,
      iface.encodeFunctionData('mint', [dstConnectors[1].evmAddress, 160n]),
      { gas: 250_000 }
    );
    await executeContract(
      clientDst,
      weth.contractId,
      iface.encodeFunctionData('mint', [dstConnectors[2].evmAddress, 500n]),
      { gas: 250_000 }
    );
  }

  // Register destination connectors with destination middleware.
  {
    const ifaceConnector = new ethers.Interface(artifacts.MockClprConnector.abi);
    for (const c of dstConnectors) {
      await executeContract(
        clientDst,
        c.contractId,
        ifaceConnector.encodeFunctionData('registerWithMiddleware', [dstMw.evmAddress]),
        { gas: 500_000 }
      );
    }
  }

  const echoApp = await deployContract(clientDst, artifacts.EchoApplication, [dstMw.evmAddress], { gas: 2_500_000 });
  deployment.dst.echoApp = echoApp;

  // Register destination app with middleware.
  {
    const iface = new ethers.Interface(artifacts.ClprMiddleware.abi);
    await executeContract(
      clientDst,
      dstMw.contractId,
      iface.encodeFunctionData('registerLocalApplication', [echoApp.evmAddress]),
      { gas: 250_000 }
    );
  }

  // Source: deploy middleware + connectors + source app.
  const srcMw = await deployContract(
    clientSrc,
    artifacts.ClprMiddleware,
    [CLPR_QUEUE_SYSTEM_CONTRACT, srcLedgerId],
    { gas: 8_000_000 }
  );
  deployment.src.middleware = srcMw;

  {
    const iface = new ethers.Interface(artifacts.ClprMiddleware.abi);
    await executeContract(
      clientSrc,
      srcMw.contractId,
      iface.encodeFunctionData('setTrustedCallbackCaller', [trustedCallbackCaller]),
      { gas: 300_000 }
    );
  }

  const srcConnectors = [];
  for (const [idx, connectorId] of deployment.connectorIds.src.entries()) {
    const expectedRemote =
      idx === 0 ? dstConnectorId1 : idx === 1 ? dstConnectorId2 : dstConnectorId3;
    const connector = await deployContract(
      clientSrc,
      artifacts.MockClprConnector,
      [
        connectorId,
        expectedRemote,
        dstLedgerId,
        ETH_UNIT,
        ZERO_ADDRESS,
        0,
        0,
        UINT256_MAX,
        { value: DEST_MIN_CHARGE, unit: WETH_UNIT },
      ],
      { gas: 5_000_000 }
    );
    srcConnectors.push(connector);
  }
  deployment.src.connectors = srcConnectors;

  // Register source connectors with source middleware.
  {
    const ifaceConnector = new ethers.Interface(artifacts.MockClprConnector.abi);
    for (const c of srcConnectors) {
      await executeContract(
        clientSrc,
        c.contractId,
        ifaceConnector.encodeFunctionData('registerWithMiddleware', [srcMw.evmAddress]),
        { gas: 500_000 }
      );
    }
  }

  // Configure source middleware with remote middleware for each source connector id.
  {
    const iface = new ethers.Interface(artifacts.ClprMiddleware.abi);
    for (const connectorId of deployment.connectorIds.src) {
      await executeContract(
        clientSrc,
        srcMw.contractId,
        iface.encodeFunctionData('setConnectorRemoteMiddleware', [connectorId, dstMw.evmAddress]),
        { gas: 300_000 }
      );
    }
  }

  // Configure destination middleware with remote middleware for each destination connector id.
  // This enables destination-side funding-state transitions to publish control updates back to source.
  {
    const iface = new ethers.Interface(artifacts.ClprMiddleware.abi);
    for (const connectorId of deployment.connectorIds.dst) {
      await executeContract(
        clientDst,
        dstMw.contractId,
        iface.encodeFunctionData('setConnectorRemoteMiddleware', [connectorId, srcMw.evmAddress]),
        { gas: 300_000 }
      );
    }
  }

  // Deploy source application referencing the destination echo app's address.
  const srcApp = await deployContract(
    clientSrc,
    artifacts.SourceApplication,
    [srcMw.evmAddress, echoApp.evmAddress, deployment.connectorIds.src, DEST_MIN_CHARGE, WETH_UNIT],
    { gas: 3_000_000 }
  );
  deployment.src.sourceApp = srcApp;

  // Register source app with middleware.
  {
    const iface = new ethers.Interface(artifacts.ClprMiddleware.abi);
    await executeContract(
      clientSrc,
      srcMw.contractId,
      iface.encodeFunctionData('registerLocalApplication', [srcApp.evmAddress]),
      { gas: 250_000 }
    );
  }

  // Connector 1 always denies authorization.
  {
    const iface = new ethers.Interface(artifacts.MockClprConnector.abi);
    await executeContract(
      clientSrc,
      srcConnectors[0].contractId,
      iface.encodeFunctionData('setDenyAuthorize', [true]),
      { gas: 150_000 }
    );
  }

  if (runDir) {
    fs.writeFileSync(path.join(runDir, 'deployment.json'), JSON.stringify(deployment, null, 2) + '\n');
  }

  const ifaceSrcApp = new ethers.Interface(artifacts.SourceApplication.abi);
  const ifaceSrcMw = new ethers.Interface(artifacts.ClprMiddleware.abi);
  const ifaceConnector = new ethers.Interface(artifacts.MockClprConnector.abi);
  const ifaceWeth = new ethers.Interface(artifacts.OZERC20Mock.abi);

  async function getUint64(client, contractId, iface, fn, args = []) {
    const res = await callContract(client, contractId, iface.encodeFunctionData(fn, args));
    const decoded = iface.decodeFunctionResult(fn, res.bytes);
    return BigInt(decoded[0].toString());
  }

  async function getUint256(client, contractId, iface, fn, args = []) {
    const res = await callContract(client, contractId, iface.encodeFunctionData(fn, args));
    const decoded = iface.decodeFunctionResult(fn, res.bytes);
    return BigInt(decoded[0].toString());
  }

  async function getRemoteStatus(destinationConnectorId) {
    const res = await callContract(
      clientSrc,
      srcMw.contractId,
      ifaceSrcMw.encodeFunctionData('remoteStatusByDestinationConnector', [destinationConnectorId])
    );
    const decoded = ifaceSrcMw.decodeFunctionResult('remoteStatusByDestinationConnector', res.bytes);
    return {
      available: BigInt(decoded[0].toString()),
      safety: BigInt(decoded[1].toString()),
      minimumCharge: BigInt(decoded[2].toString()),
      maximumCharge: BigInt(decoded[3].toString()),
      unit: decoded[4],
      known: Boolean(decoded[5]),
      unavailable: Boolean(decoded[6]),
    };
  }

  async function waitForRemoteFundingEpoch(destinationConnectorId, minEpoch, timeoutMs) {
    const start = Date.now();
    for (;;) {
      const epoch = await getUint64(
        clientSrc,
        srcMw.contractId,
        ifaceSrcMw,
        'remoteFundingEpoch',
        [destinationConnectorId]
      );
      if (epoch >= minEpoch) return epoch;
      if (Date.now() - start > timeoutMs) {
        throw new Error(
          `Timed out waiting for remote funding epoch (connector=${destinationConnectorId}, expected>=${minEpoch}, got=${epoch})`
        );
      }
      await sleep(1000);
    }
  }

  async function waitForResponse(appMsgId, timeoutMs) {
    const start = Date.now();
    for (;;) {
      const last = await getUint64(clientSrc, srcApp.contractId, ifaceSrcApp, 'lastReceivedAppMsgId');
      if (last >= appMsgId) return;
      if (Date.now() - start > timeoutMs) {
        throw new Error(`Timed out waiting for response delivery (appMsgId=${appMsgId}, last=${last})`);
      }
      await sleep(1000);
    }
  }

  async function sendAndWait(label, payloadUtf8) {
    const payloadHex = ethers.hexlify(ethers.toUtf8Bytes(payloadUtf8));
    // Submit the send transaction and decode the return struct so failures include connector-side details.
    {
      const callDataHex = ifaceSrcApp.encodeFunctionData('sendWithFailoverFromFirst', [payloadHex]);
      const tx = new ContractExecuteTransaction()
        .setContractId(srcApp.contractId)
        .setGas(1_800_000)
        .setFunctionParameters(toUint8Array(callDataHex));
      const txResp = await tx.execute(clientSrc);
      await txResp.getReceipt(clientSrc);
      const record = await txResp.getRecord(clientSrc);
      const decoded = ifaceSrcApp.decodeFunctionResult('sendWithFailoverFromFirst', record.contractFunctionResult.bytes);
      const statusStruct = decoded[0];
      const field = (s, name, idx) => (s && s[name] != null ? s[name] : s[idx]);
      const appMsgId = BigInt(field(statusStruct, 'appMsgId', 0).toString());
      const status = BigInt(field(statusStruct, 'status', 1).toString());
      const failureReason = BigInt(field(statusStruct, 'failureReason', 2).toString());
      const failureSide = BigInt(field(statusStruct, 'failureSide', 3).toString());
      // 0 = Accepted, 1 = Rejected (ClprTypes.ClprSendStatus)
      if (status !== 0n) {
        throw new Error(
          `sendWithFailoverFromFirst rejected (label=${label}, appMsgId=${appMsgId}, failureReason=${failureReason}, failureSide=${failureSide})`
        );
      }
    }
    const lastAppMsgId = await getUint64(clientSrc, srcMw.contractId, ifaceSrcMw, 'nextAppMsgId', [srcApp.evmAddress]);
    await waitForResponse(lastAppMsgId, 120_000);
    return { label, lastAppMsgId };
  }

  phase('phase1-send-initial-two-messages');
  // Phase 1: send 2 messages until destination connector2 reaches safety threshold.
  await sendAndWait('msg-1', 'solo-msg-1');
  await sendAndWait('msg-2', 'solo-msg-2');

  // Validate connector2 balance boundary and remote status cache.
  {
    const bal = await getUint256(clientDst, weth.contractId, ifaceWeth, 'balanceOf', [dstConnectors[1].evmAddress]);
    assert.equal(bal, DEST_SAFETY_THRESHOLD, 'destination connector2 should be at safety threshold after 2 charges');

    const remote = await getRemoteStatus(dstConnectorId2);
    const remoteEpoch = await getUint64(
      clientSrc,
      srcMw.contractId,
      ifaceSrcMw,
      'remoteFundingEpoch',
      [dstConnectorId2]
    );
    assert.equal(remote.known, true, 'remote status for destination connector2 should be known');
    assert.equal(remote.unavailable, false, 'remote status for destination connector2 should not be unavailable');
    assert.equal(remote.available, DEST_SAFETY_THRESHOLD, 'remote available balance should match on-ledger balance');
    assert.equal(remote.safety, DEST_SAFETY_THRESHOLD, 'remote safety threshold should match on-ledger policy');
    assert.equal(remote.minimumCharge, DEST_MIN_CHARGE, 'remote minimum charge should match on-ledger policy');
    assert.equal(remote.unit, WETH_UNIT, 'remote unit should match destination connector local unit');
    assert.equal(remoteEpoch, 1n, 'remote funding epoch should advance on initial depletion transition');
  }

  phase('phase2-send-two-more-with-connector2-pre-reject');
  // Phase 2: send two more messages; connector2 should be pre-rejected and connector3 should succeed.
  await sendAndWait('msg-3', 'solo-msg-3');
  await sendAndWait('msg-4', 'solo-msg-4');

  phase(`phase3-topoff-connector2 amount=${CONNECTOR2_TOPOFF.toString()}`);
  // Top off destination connector2 by 50 WETH using funding-aware deposit.
  // This should transition connector2 from Underfunded -> Available and publish a control update.
  await executeContract(
    clientDst,
    weth.contractId,
    ifaceWeth.encodeFunctionData('mint', [operatorSolidityAddress, CONNECTOR2_TOPOFF]),
    { gas: 250_000 }
  );
  await executeContract(
    clientDst,
    weth.contractId,
    ifaceWeth.encodeFunctionData('approve', [dstConnectors[1].evmAddress, CONNECTOR2_TOPOFF]),
    { gas: 250_000 }
  );
  await executeContract(
    clientDst,
    dstConnectors[1].contractId,
    ifaceConnector.encodeFunctionData('depositToken', [CONNECTOR2_TOPOFF]),
    { gas: 250_000 }
  );

  await waitForRemoteFundingEpoch(dstConnectorId2, 2n, 60_000);
  {
    const bal2 = await getUint256(clientDst, weth.contractId, ifaceWeth, 'balanceOf', [dstConnectors[1].evmAddress]);
    assert.equal(
      bal2,
      DEST_SAFETY_THRESHOLD + CONNECTOR2_TOPOFF,
      'destination connector2 balance should increase after topoff'
    );

    const remote = await getRemoteStatus(dstConnectorId2);
    assert.equal(remote.known, true, 'remote status should remain known after topoff');
    assert.equal(remote.unavailable, false, 'remote status should remain available after topoff');
    assert.equal(
      remote.available,
      DEST_SAFETY_THRESHOLD + CONNECTOR2_TOPOFF,
      'source cache should reflect topped-off destination balance'
    );
  }

  phase('phase4-send-post-topoff-two-messages');
  // Phase 3: send one message that should use connector2 again, then one that falls back to connector3.
  await sendAndWait('msg-5', 'solo-msg-5');
  await sendAndWait('msg-6', 'solo-msg-6');

  // Validate connector attempt counts:
  // - connector1 authorize called once per send attempt (6 total)
  // - connector2 authorize called for msg-1,msg-2,msg-5 only (3 total)
  // - connector3 authorize called for msg-3,msg-4,msg-6 (3 total)
  {
    const a1 = await getUint64(clientSrc, srcConnectors[0].contractId, ifaceConnector, 'authorizeCount');
    const a2 = await getUint64(clientSrc, srcConnectors[1].contractId, ifaceConnector, 'authorizeCount');
    const a3 = await getUint64(clientSrc, srcConnectors[2].contractId, ifaceConnector, 'authorizeCount');
    assert.equal(a1, 6n, 'source connector1 authorizeCount');
    assert.equal(a2, 3n, 'source connector2 authorizeCount');
    assert.equal(a3, 3n, 'source connector3 authorizeCount');

    const rej2 = await getUint64(clientSrc, srcConnectors[1].contractId, ifaceConnector, 'sendRejectedCount');
    assert.equal(rej2, 3n, 'source connector2 should be notified of 3 pre-enqueue rejections');
  }

  // Validate destination connector funds after topoff and re-deplete cycle.
  {
    const bal2 = await getUint256(clientDst, weth.contractId, ifaceWeth, 'balanceOf', [dstConnectors[1].evmAddress]);
    const bal3 = await getUint256(clientDst, weth.contractId, ifaceWeth, 'balanceOf', [dstConnectors[2].evmAddress]);
    assert.equal(bal2, DEST_SAFETY_THRESHOLD, 'destination connector2 balance should remain at threshold');
    assert.equal(bal3, 350n, 'destination connector3 balance should reflect three reimbursements');

    const remote = await getRemoteStatus(dstConnectorId2);
    const remoteEpoch = await getUint64(
      clientSrc,
      srcMw.contractId,
      ifaceSrcMw,
      'remoteFundingEpoch',
      [dstConnectorId2]
    );
    assert.equal(remote.available, DEST_SAFETY_THRESHOLD, 'remote available balance should return to threshold');
    assert.equal(remote.safety, DEST_SAFETY_THRESHOLD, 'remote safety threshold should be stable');
    assert.equal(remote.minimumCharge, DEST_MIN_CHARGE, 'remote minimum charge should be stable');
    assert.equal(remote.known, true, 'remote status should remain known after re-deplete');
    assert.equal(remote.unavailable, false, 'remote status should remain available after re-deplete');
    assert.equal(remoteEpoch, 3n, 'remote funding epoch should include topoff and re-deplete transitions');
  }

  phase('scenario-validations-complete');
  console.log('Scenario passed');
  } finally {
    // Explicitly close gRPC channels so the process exits deterministically.
    try {
      clientSrc.close();
    } catch (_) {}
    try {
      clientDst.close();
    } catch (_) {}
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
