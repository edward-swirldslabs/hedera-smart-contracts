// SPDX-License-Identifier: Apache-2.0

const { expect } = require('chai');
const { ethers } = require('hardhat');
const { deriveConnectorIds } = require('../../../scripts/clpr/shared/connector-ids');

describe('@solidityequiv1 CLPR Middleware MVP Connectors', function () {
  const SOURCE_LEDGER_ID = ethers.keccak256(ethers.toUtf8Bytes('clpr-ledger-source'));
  const DEST_LEDGER_ID = ethers.keccak256(ethers.toUtf8Bytes('clpr-ledger-destination'));
  const ETH_UNIT = 'ETH';
  const WETH_UNIT = 'WETH';

  const DEST_MIN_CHARGE = 50n;
  const DEST_SAFETY_THRESHOLD = 60n;

  let queue;
  let sourceMiddleware;
  let destinationMiddleware;
  let weth;

  let sourceConnector1;
  let sourceConnector2;
  let sourceConnector3;

  let destinationConnector1;
  let destinationConnector2;
  let destinationConnector3;

  let sourceConnectorId1;
  let sourceConnectorId2;
  let sourceConnectorId3;

  let destinationConnectorId1;
  let destinationConnectorId2;
  let destinationConnectorId3;

  let sourceApp;
  let echoApp;

  beforeEach(async function () {
    // Arrange mock messaging layer + two middleware endpoints (source and destination).
    const queueFactory = await ethers.getContractFactory('MockClprQueue');
    queue = await queueFactory.deploy();

    const middlewareFactory = await ethers.getContractFactory('ClprMiddleware');
    sourceMiddleware = await middlewareFactory.deploy(await queue.getAddress(), SOURCE_LEDGER_ID);
    destinationMiddleware = await middlewareFactory.deploy(await queue.getAddress(), DEST_LEDGER_ID);

    await (
      await queue.configureEndpoints(
        await sourceMiddleware.getAddress(),
        await destinationMiddleware.getAddress()
      )
    ).wait();

    // Destination ledger custom currency (wrapped ETH).
    const wethFactory = await ethers.getContractFactory('OZERC20Mock');
    weth = await wethFactory.deploy('Wrapped ETH', 'WETH');
    await weth.waitForDeployment();

    const connectorIds = deriveConnectorIds(ethers, SOURCE_LEDGER_ID, DEST_LEDGER_ID);
    [sourceConnectorId1, sourceConnectorId2, sourceConnectorId3] = connectorIds.source;
    [destinationConnectorId1, destinationConnectorId2, destinationConnectorId3] =
      connectorIds.destination;

    // Deploy three connector pairs (source uses ETH, destination uses WETH).
    const connectorFactory = await ethers.getContractFactory('MockClprConnector');

    // Source connectors (native ETH balance reporting); outbound max charge commitment is in WETH.
    const outboundMax = { value: DEST_MIN_CHARGE, unit: WETH_UNIT };
    sourceConnector1 = await connectorFactory.deploy(
      sourceConnectorId1,
      destinationConnectorId1,
      DEST_LEDGER_ID,
      ETH_UNIT,
      ethers.ZeroAddress,
      0,
      0,
      ethers.MaxUint256,
      outboundMax,
      { value: ethers.parseEther('1') }
    );
    sourceConnector2 = await connectorFactory.deploy(
      sourceConnectorId2,
      destinationConnectorId2,
      DEST_LEDGER_ID,
      ETH_UNIT,
      ethers.ZeroAddress,
      0,
      0,
      ethers.MaxUint256,
      outboundMax,
      { value: ethers.parseEther('1') }
    );
    sourceConnector3 = await connectorFactory.deploy(
      sourceConnectorId3,
      destinationConnectorId3,
      DEST_LEDGER_ID,
      ETH_UNIT,
      ethers.ZeroAddress,
      0,
      0,
      ethers.MaxUint256,
      outboundMax,
      { value: ethers.parseEther('1') }
    );

    // Destination connectors (ERC20=WETH balance reporting + reimbursement).
    const unbounded = ethers.MaxUint256;
    destinationConnector1 = await connectorFactory.deploy(
      destinationConnectorId1,
      sourceConnectorId1,
      SOURCE_LEDGER_ID,
      WETH_UNIT,
      await weth.getAddress(),
      DEST_SAFETY_THRESHOLD,
      DEST_MIN_CHARGE,
      unbounded,
      { value: unbounded, unit: WETH_UNIT }
    );
    destinationConnector2 = await connectorFactory.deploy(
      destinationConnectorId2,
      sourceConnectorId2,
      SOURCE_LEDGER_ID,
      WETH_UNIT,
      await weth.getAddress(),
      DEST_SAFETY_THRESHOLD,
      DEST_MIN_CHARGE,
      unbounded,
      { value: unbounded, unit: WETH_UNIT }
    );
    destinationConnector3 = await connectorFactory.deploy(
      destinationConnectorId3,
      sourceConnectorId3,
      SOURCE_LEDGER_ID,
      WETH_UNIT,
      await weth.getAddress(),
      DEST_SAFETY_THRESHOLD,
      DEST_MIN_CHARGE,
      unbounded,
      { value: unbounded, unit: WETH_UNIT }
    );

    // Seed destination connector funds (connector 1 intentionally underfunded).
    // Connector 2 has enough for two reimbursements and then hits the safety threshold boundary.
    await (await weth.mint(await destinationConnector2.getAddress(), 160n)).wait();
    await (await weth.mint(await destinationConnector3.getAddress(), 500n)).wait();

    // Register connectors with each middleware instance (self-registration via connector call).
    await (await sourceConnector1.registerWithMiddleware(await sourceMiddleware.getAddress())).wait();
    await (await sourceConnector2.registerWithMiddleware(await sourceMiddleware.getAddress())).wait();
    await (await sourceConnector3.registerWithMiddleware(await sourceMiddleware.getAddress())).wait();

    await (
      await destinationConnector1.registerWithMiddleware(await destinationMiddleware.getAddress())
    ).wait();
    await (
      await destinationConnector2.registerWithMiddleware(await destinationMiddleware.getAddress())
    ).wait();
    await (
      await destinationConnector3.registerWithMiddleware(await destinationMiddleware.getAddress())
    ).wait();

    // Destination connectors also need paired source middleware for funding-state control updates.
    await (
      await destinationMiddleware.setConnectorRemoteMiddleware(
        destinationConnectorId1,
        await sourceMiddleware.getAddress()
      )
    ).wait();
    await (
      await destinationMiddleware.setConnectorRemoteMiddleware(
        destinationConnectorId2,
        await sourceMiddleware.getAddress()
      )
    ).wait();
    await (
      await destinationMiddleware.setConnectorRemoteMiddleware(
        destinationConnectorId3,
        await sourceMiddleware.getAddress()
      )
    ).wait();

    // Source connectors must know the paired remote middleware for native queue route-header encoding.
    await (
      await sourceMiddleware.setConnectorRemoteMiddleware(
        sourceConnectorId1,
        await destinationMiddleware.getAddress()
      )
    ).wait();
    await (
      await sourceMiddleware.setConnectorRemoteMiddleware(
        sourceConnectorId2,
        await destinationMiddleware.getAddress()
      )
    ).wait();
    await (
      await sourceMiddleware.setConnectorRemoteMiddleware(
        sourceConnectorId3,
        await destinationMiddleware.getAddress()
      )
    ).wait();

    // Deploy the destination application first so source apps can be constructed with a known destination.
    const echoAppFactory = await ethers.getContractFactory('EchoApplication');
    echoApp = await echoAppFactory.deploy(await destinationMiddleware.getAddress());

    // Deploy a source app with three connectors in priority order.
    const sourceAppFactory = await ethers.getContractFactory('SourceApplication');
    sourceApp = await sourceAppFactory.deploy(
      await sourceMiddleware.getAddress(),
      await echoApp.getAddress(),
      [sourceConnectorId1, sourceConnectorId2, sourceConnectorId3],
      DEST_MIN_CHARGE,
      WETH_UNIT
    );

    // Register apps so middleware accepts them as local participants.
    await sourceMiddleware.registerLocalApplication(await sourceApp.getAddress());
    await destinationMiddleware.registerLocalApplication(await echoApp.getAddress());

    // Connector 1 "knows" it cannot be used (simulates a connector with known bad remote funding status).
    await (await sourceConnector1.setDenyAuthorize(true)).wait();
  });

  it('rejects middleware deployment with zero queue address', async function () {
    const middlewareFactory = await ethers.getContractFactory('ClprMiddleware');
    await expect(
      middlewareFactory.deploy(ethers.ZeroAddress, SOURCE_LEDGER_ID)
    ).to.be.revertedWithCustomError(
      middlewareFactory,
      'InvalidQueue'
    );
  });

  it('rejects source app deployment with zero middleware address', async function () {
    const sourceAppFactory = await ethers.getContractFactory('SourceApplication');
    await expect(
      sourceAppFactory.deploy(
        ethers.ZeroAddress,
        '0x0000000000000000000000000000000000000001',
        ['0x' + '11'.repeat(32)],
        1,
        'WETH'
      )
    ).to.be.revertedWithCustomError(sourceAppFactory, 'InvalidMiddleware');
  });

  it('rejects echo app deployment with zero middleware address', async function () {
    const echoAppFactory = await ethers.getContractFactory('EchoApplication');
    await expect(echoAppFactory.deploy(ethers.ZeroAddress)).to.be.revertedWithCustomError(
      echoAppFactory,
      'InvalidMiddleware'
    );
  });

  it('allows configured trusted callback caller in addition to queue', async function () {
    const zeroAmount = { value: 0n, unit: '' };
    const response = {
      originalMessageId: 999n,
      applicationResponse: { data: '0x' },
      connectorResponse: { data: '0x' },
      middlewareResponse: {
        status: 0,
        minimumCharge: zeroAmount,
        maximumCharge: zeroAmount,
        middlewareMessage: {
          balanceReport: {
            connectorId: ethers.ZeroHash,
            availableBalance: zeroAmount,
            safetyThreshold: zeroAmount,
            outstandingCommitments: zeroAmount,
          },
          data: '0x',
        },
      },
    };

    await expect(
      sourceMiddleware.handleMessageResponse(response)
    ).to.be.revertedWithCustomError(sourceMiddleware, 'QueueOnly');

    await (await sourceMiddleware.setTrustedCallbackCaller((await ethers.getSigners())[0].address)).wait();

    // With the trusted caller set, the QueueOnly gate is bypassed. Unknown originalMessageIds now
    // return silently (control message replies from the native ClprEndpointClient take this path).
    await expect(sourceMiddleware.handleMessageResponse(response)).to.not.be.reverted;
  });

  it('rejects direct queue enqueue calls from non-middleware callers', async function () {
    const [, outsider] = await ethers.getSigners();
    const zeroAmount = { value: 0n, unit: '' };

    const message = {
      senderApplicationId: await sourceApp.getAddress(),
      applicationMessage: {
        recipientId: await echoApp.getAddress(),
        connectorId: sourceConnectorId1,
        maxCharge: zeroAmount,
        data: '0x',
      },
      destinationConnectorId: destinationConnectorId1,
      connectorMessage: {
        approve: true,
        maxCharge: zeroAmount,
        data: '0x',
      },
      middlewareMessage: {
        balanceReport: {
          connectorId: ethers.ZeroHash,
          availableBalance: zeroAmount,
          safetyThreshold: zeroAmount,
          outstandingCommitments: zeroAmount,
        },
        data: '0x',
      },
    };

    const response = {
      originalMessageId: 1n,
      applicationResponse: { data: '0x' },
      connectorResponse: { data: '0x' },
      middlewareResponse: {
        status: 0,
        minimumCharge: zeroAmount,
        maximumCharge: zeroAmount,
        middlewareMessage: {
          balanceReport: {
            connectorId: ethers.ZeroHash,
            availableBalance: zeroAmount,
            safetyThreshold: zeroAmount,
            outstandingCommitments: zeroAmount,
          },
          data: '0x',
        },
      },
    };

    await expect(
      queue.connect(outsider).enqueueMessage(message)
    ).to.be.revertedWithCustomError(queue, 'MiddlewareOnly');

    await expect(
      queue.connect(outsider).enqueueMessageResponse(response)
    ).to.be.revertedWithCustomError(queue, 'MiddlewareOnly');
  });

  it('sends 6 messages with topoff recovery and re-deplete behavior on connector2', async function () {
    const payload1 = ethers.toUtf8Bytes('mvp-msg-1');
    const payload2 = ethers.toUtf8Bytes('mvp-msg-2');
    const payload3 = ethers.toUtf8Bytes('mvp-msg-3');
    const payload4 = ethers.toUtf8Bytes('mvp-msg-4');
    const payload5 = ethers.toUtf8Bytes('mvp-msg-5');
    const payload6 = ethers.toUtf8Bytes('mvp-msg-6');
    const topoffAmount = 50n;

    // Message 1: connector 1 rejects; connector 2 accepts.
    const tx1 = await sourceApp.sendWithFailoverFromFirst(payload1);
    const r1 = await tx1.wait();
    const b1 = r1.blockNumber;

    const abi = ethers.AbiCoder.defaultAbiCoder();
    const expectedRequestRoute = abi.encode(
      ['uint8', 'bytes32', 'address', 'address'],
      [1, DEST_LEDGER_ID, await sourceMiddleware.getAddress(), await destinationMiddleware.getAddress()]
    );
    const expectedResponseRoute = abi.encode(
      ['uint8', 'bytes32', 'address'],
      [1, DEST_LEDGER_ID, await sourceMiddleware.getAddress()]
    );

    const sendEvents1 = await sourceApp.queryFilter(sourceApp.filters.SendAttempted(), b1, b1);
    expect(sendEvents1.length).to.equal(2);
    expect(sendEvents1[0].args.connectorId).to.equal(sourceConnectorId1);
    expect(sendEvents1[0].args.status).to.equal(1n); // Rejected
    expect(sendEvents1[1].args.connectorId).to.equal(sourceConnectorId2);
    expect(sendEvents1[1].args.status).to.equal(0n); // Accepted

    // Only the accepted attempt should enqueue a message.
    expect(await queue.nextMessageId()).to.equal(1n);
    expect(await sourceConnector1.authorizeCount()).to.equal(1n);
    expect(await sourceConnector2.authorizeCount()).to.equal(1n);
    expect(await destinationConnector2.lastInboundRequestRouteData()).to.equal(expectedRequestRoute);
    expect(await queue.pendingResponseRouteData(1n)).to.equal(expectedResponseRoute);

    // Message 2: connector 2 accepts.
    const tx2 = await sourceApp.sendWithFailoverFromFirst(payload2);
    const r2 = await tx2.wait();
    const b2 = r2.blockNumber;
    const sendEvents2 = await sourceApp.queryFilter(sourceApp.filters.SendAttempted(), b2, b2);
    expect(sendEvents2.length).to.equal(2);
    expect(sendEvents2[0].args.connectorId).to.equal(sourceConnectorId1);
    expect(sendEvents2[0].args.status).to.equal(1n); // Rejected
    expect(sendEvents2[1].args.connectorId).to.equal(sourceConnectorId2);
    expect(sendEvents2[1].args.status).to.equal(0n); // Accepted

    expect(await queue.nextMessageId()).to.be.gte(2n);
    expect(await sourceConnector2.authorizeCount()).to.equal(2n);
    expect(await queue.pendingResponseRouteData(2n)).to.equal(expectedResponseRoute);

    // Deliver both responses so the source middleware learns the remote balance report for connector 2.
    const deliverAllReceipt = await (await queue.deliverAllMessageResponses()).wait();
    const deliverBlock = deliverAllReceipt.blockNumber;

    const responseEvents = await sourceApp.queryFilter(
      sourceApp.filters.ResponseReceived(),
      deliverBlock,
      deliverBlock
    );
    expect(responseEvents.length).to.equal(2);
    expect(responseEvents[0].args.payload).to.equal(ethers.hexlify(payload1));
    expect(responseEvents[1].args.payload).to.equal(ethers.hexlify(payload2));

    // Destination connector 2 should now be at the safety threshold (out of funds for further sends).
    expect(await weth.balanceOf(await destinationConnector2.getAddress())).to.equal(60n);

    const remote2 = await sourceMiddleware.remoteStatusByDestinationConnector(destinationConnectorId2);
    expect(remote2.known).to.equal(true);
    expect(remote2.availableBalance).to.equal(60n);
    expect(remote2.safetyThreshold).to.equal(60n);
    expect(await sourceMiddleware.remoteFundingEpoch(destinationConnectorId2)).to.equal(1n);

    // Message 3: connector 2 is rejected pre-enqueue due to remote out-of-funds; connector 3 accepts.
    const tx3 = await sourceApp.sendWithFailoverFromFirst(payload3);
    const r3 = await tx3.wait();
    const b3 = r3.blockNumber;

    const sendEvents3 = await sourceApp.queryFilter(sourceApp.filters.SendAttempted(), b3, b3);
    expect(sendEvents3.length).to.equal(3);
    expect(sendEvents3[0].args.connectorId).to.equal(sourceConnectorId1);
    expect(sendEvents3[0].args.status).to.equal(1n); // Rejected
    expect(sendEvents3[1].args.connectorId).to.equal(sourceConnectorId2);
    expect(sendEvents3[1].args.status).to.equal(1n); // Rejected
    expect(sendEvents3[1].args.failureReason).to.equal(2n); // ConnectorOutOfFunds
    expect(sendEvents3[1].args.failureSide).to.equal(2n); // Destination

    expect(sendEvents3[2].args.connectorId).to.equal(sourceConnectorId3);
    expect(sendEvents3[2].args.status).to.equal(0n); // Accepted

    // Pre-enqueue rejection should notify the connector without calling authorize again.
    expect(await sourceConnector2.sendRejectedCount()).to.equal(1n);
    expect(await sourceConnector2.authorizeCount()).to.equal(2n);

    expect(await queue.nextMessageId()).to.be.gte(4n);

    // Message 4: connector 2 remains rejected pre-enqueue; connector 3 accepts.
    const tx4 = await sourceApp.sendWithFailoverFromFirst(payload4);
    const r4 = await tx4.wait();
    const b4 = r4.blockNumber;

    const sendEvents4 = await sourceApp.queryFilter(sourceApp.filters.SendAttempted(), b4, b4);
    expect(sendEvents4.length).to.equal(3);
    expect(sendEvents4[0].args.connectorId).to.equal(sourceConnectorId1);
    expect(sendEvents4[0].args.status).to.equal(1n); // Rejected
    expect(sendEvents4[1].args.connectorId).to.equal(sourceConnectorId2);
    expect(sendEvents4[1].args.status).to.equal(1n); // Rejected
    expect(sendEvents4[1].args.failureReason).to.equal(2n); // ConnectorOutOfFunds
    expect(sendEvents4[1].args.failureSide).to.equal(2n); // Destination
    expect(sendEvents4[2].args.connectorId).to.equal(sourceConnectorId3);
    expect(sendEvents4[2].args.status).to.equal(0n); // Accepted

    expect(await queue.nextMessageId()).to.be.gte(5n);
    expect(await sourceConnector2.sendRejectedCount()).to.equal(2n);

    const deliver34Receipt = await (await queue.deliverAllMessageResponses()).wait();
    const deliver34Block = deliver34Receipt.blockNumber;
    const responseEvents34 = await sourceApp.queryFilter(
      sourceApp.filters.ResponseReceived(),
      deliver34Block,
      deliver34Block
    );
    expect(responseEvents34.length).to.equal(2);
    expect(responseEvents34[0].args.payload).to.equal(ethers.hexlify(payload3));
    expect(responseEvents34[1].args.payload).to.equal(ethers.hexlify(payload4));

    // Topoff connector2 on destination. Funding-aware deposit should publish an update to source middleware.
    const [owner] = await ethers.getSigners();
    await (await weth.mint(owner.address, topoffAmount)).wait();
    await (await weth.approve(await destinationConnector2.getAddress(), topoffAmount)).wait();
    await (await destinationConnector2.depositToken(topoffAmount)).wait();

    const remoteAfterTopoff = await sourceMiddleware.remoteStatusByDestinationConnector(destinationConnectorId2);
    expect(remoteAfterTopoff.availableBalance).to.equal(110n);
    expect(remoteAfterTopoff.safetyThreshold).to.equal(60n);
    expect(remoteAfterTopoff.minimumCharge).to.equal(50n);
    expect(remoteAfterTopoff.known).to.equal(true);
    expect(remoteAfterTopoff.unavailable).to.equal(false);
    expect(await sourceMiddleware.remoteFundingEpoch(destinationConnectorId2)).to.equal(2n);

    // Message 5: connector2 is usable again after topoff.
    const tx5 = await sourceApp.sendWithFailoverFromFirst(payload5);
    const r5 = await tx5.wait();
    const b5 = r5.blockNumber;
    const sendEvents5 = await sourceApp.queryFilter(sourceApp.filters.SendAttempted(), b5, b5);
    expect(sendEvents5.length).to.equal(2);
    expect(sendEvents5[0].args.connectorId).to.equal(sourceConnectorId1);
    expect(sendEvents5[0].args.status).to.equal(1n); // Rejected
    expect(sendEvents5[1].args.connectorId).to.equal(sourceConnectorId2);
    expect(sendEvents5[1].args.status).to.equal(0n); // Accepted

    expect(await queue.nextMessageId()).to.be.gte(7n);
    await (await queue.deliverAllMessageResponses()).wait();
    expect(await sourceMiddleware.remoteFundingEpoch(destinationConnectorId2)).to.equal(3n);
    expect(await weth.balanceOf(await destinationConnector2.getAddress())).to.equal(60n);

    // Message 6: connector2 should now be rejected again and fail over to connector3.
    const tx6 = await sourceApp.sendWithFailoverFromFirst(payload6);
    const r6 = await tx6.wait();
    const b6 = r6.blockNumber;
    const sendEvents6 = await sourceApp.queryFilter(sourceApp.filters.SendAttempted(), b6, b6);
    expect(sendEvents6.length).to.equal(3);
    expect(sendEvents6[0].args.connectorId).to.equal(sourceConnectorId1);
    expect(sendEvents6[0].args.status).to.equal(1n); // Rejected
    expect(sendEvents6[1].args.connectorId).to.equal(sourceConnectorId2);
    expect(sendEvents6[1].args.status).to.equal(1n); // Rejected
    expect(sendEvents6[1].args.failureReason).to.equal(2n); // ConnectorOutOfFunds
    expect(sendEvents6[1].args.failureSide).to.equal(2n); // Destination
    expect(sendEvents6[2].args.connectorId).to.equal(sourceConnectorId3);
    expect(sendEvents6[2].args.status).to.equal(0n); // Accepted

    expect(await queue.nextMessageId()).to.be.gte(8n);
    await (await queue.deliverAllMessageResponses()).wait();

    // Final source-side connector attempt counters.
    expect(await sourceConnector1.authorizeCount()).to.equal(6n);
    expect(await sourceConnector2.authorizeCount()).to.equal(3n);
    expect(await sourceConnector3.authorizeCount()).to.equal(3n);
    expect(await sourceConnector2.sendRejectedCount()).to.equal(3n);

    // Final destination connector balances.
    expect(await weth.balanceOf(await destinationConnector2.getAddress())).to.equal(60n);
    expect(await weth.balanceOf(await destinationConnector3.getAddress())).to.equal(350n);

    // Destination app handled all six successful messages.
    expect(await echoApp.requestCount()).to.equal(6n);
  });
});
