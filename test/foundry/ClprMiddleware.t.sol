// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import "forge-std/Test.sol";

import { ClprTypes } from "../../contracts/solidity/clpr/types/ClprTypes.sol";
import { ClprMiddleware } from "../../contracts/solidity/clpr/middleware/ClprMiddleware.sol";
import { MockClprQueue } from "../../contracts/solidity/clpr/mocks/MockClprQueue.sol";
import { MockClprConnector } from "../../contracts/solidity/clpr/mocks/MockClprConnector.sol";
import { SourceApplication } from "../../contracts/solidity/clpr/apps/SourceApplication.sol";
import { EchoApplication } from "../../contracts/solidity/clpr/apps/EchoApplication.sol";
import { OZERC20Mock } from "../../contracts/openzeppelin/ERC-20/ERC20Mock.sol";

contract ClprMiddlewareTest is Test {
    bytes32 private constant SOURCE_LEDGER_ID = keccak256(bytes("clpr-ledger-source"));
    bytes32 private constant DEST_LEDGER_ID = keccak256(bytes("clpr-ledger-destination"));

    string private constant ETH_UNIT = "ETH";
    string private constant WETH_UNIT = "WETH";

    uint256 private constant DEST_MIN_CHARGE = 50;
    uint256 private constant DEST_SAFETY_THRESHOLD = 60;

    MockClprQueue private queue;
    ClprMiddleware private sourceMiddleware;
    ClprMiddleware private destinationMiddleware;
    OZERC20Mock private weth;

    MockClprConnector private sourceConnector1;
    MockClprConnector private sourceConnector2;
    MockClprConnector private sourceConnector3;

    MockClprConnector private destinationConnector1;
    MockClprConnector private destinationConnector2;
    MockClprConnector private destinationConnector3;

    bytes32 private sourceConnectorId1;
    bytes32 private sourceConnectorId2;
    bytes32 private sourceConnectorId3;

    bytes32 private destinationConnectorId1;
    bytes32 private destinationConnectorId2;
    bytes32 private destinationConnectorId3;

    SourceApplication private sourceApp;
    EchoApplication private echoApp;

    function setUp() public {
        queue = new MockClprQueue();
        sourceMiddleware = new ClprMiddleware(address(queue), SOURCE_LEDGER_ID);
        destinationMiddleware = new ClprMiddleware(address(queue), DEST_LEDGER_ID);

        queue.configureEndpoints(address(sourceMiddleware), address(destinationMiddleware));

        weth = new OZERC20Mock("Wrapped ETH", "WETH");

        // Derive connector ids (models spec intent: ids differ across ledgers).
        bytes32 ownerKey1 = keccak256(bytes("connector-owner-1"));
        bytes32 ownerKey2 = keccak256(bytes("connector-owner-2"));
        bytes32 ownerKey3 = keccak256(bytes("connector-owner-3"));

        sourceConnectorId1 = keccak256(abi.encodePacked("src", ownerKey1, SOURCE_LEDGER_ID, DEST_LEDGER_ID));
        destinationConnectorId1 = keccak256(abi.encodePacked("dst", ownerKey1, DEST_LEDGER_ID, SOURCE_LEDGER_ID));

        sourceConnectorId2 = keccak256(abi.encodePacked("src", ownerKey2, SOURCE_LEDGER_ID, DEST_LEDGER_ID));
        destinationConnectorId2 = keccak256(abi.encodePacked("dst", ownerKey2, DEST_LEDGER_ID, SOURCE_LEDGER_ID));

        sourceConnectorId3 = keccak256(abi.encodePacked("src", ownerKey3, SOURCE_LEDGER_ID, DEST_LEDGER_ID));
        destinationConnectorId3 = keccak256(abi.encodePacked("dst", ownerKey3, DEST_LEDGER_ID, SOURCE_LEDGER_ID));

        ClprTypes.ClprAmount memory outboundMaxCharge = ClprTypes.ClprAmount({value: DEST_MIN_CHARGE, unit: WETH_UNIT});

        sourceConnector1 = new MockClprConnector{value: 1 ether}(
            sourceConnectorId1,
            destinationConnectorId1,
            DEST_LEDGER_ID,
            ETH_UNIT,
            address(0),
            0,
            0,
            type(uint256).max,
            outboundMaxCharge
        );
        sourceConnector2 = new MockClprConnector{value: 1 ether}(
            sourceConnectorId2,
            destinationConnectorId2,
            DEST_LEDGER_ID,
            ETH_UNIT,
            address(0),
            0,
            0,
            type(uint256).max,
            outboundMaxCharge
        );
        sourceConnector3 = new MockClprConnector{value: 1 ether}(
            sourceConnectorId3,
            destinationConnectorId3,
            DEST_LEDGER_ID,
            ETH_UNIT,
            address(0),
            0,
            0,
            type(uint256).max,
            outboundMaxCharge
        );

        destinationConnector1 = new MockClprConnector(
            destinationConnectorId1,
            sourceConnectorId1,
            SOURCE_LEDGER_ID,
            WETH_UNIT,
            address(weth),
            DEST_SAFETY_THRESHOLD,
            DEST_MIN_CHARGE,
            type(uint256).max,
            ClprTypes.ClprAmount({value: type(uint256).max, unit: WETH_UNIT})
        );
        destinationConnector2 = new MockClprConnector(
            destinationConnectorId2,
            sourceConnectorId2,
            SOURCE_LEDGER_ID,
            WETH_UNIT,
            address(weth),
            DEST_SAFETY_THRESHOLD,
            DEST_MIN_CHARGE,
            type(uint256).max,
            ClprTypes.ClprAmount({value: type(uint256).max, unit: WETH_UNIT})
        );
        destinationConnector3 = new MockClprConnector(
            destinationConnectorId3,
            sourceConnectorId3,
            SOURCE_LEDGER_ID,
            WETH_UNIT,
            address(weth),
            DEST_SAFETY_THRESHOLD,
            DEST_MIN_CHARGE,
            type(uint256).max,
            ClprTypes.ClprAmount({value: type(uint256).max, unit: WETH_UNIT})
        );

        // Seed destination connector funds (connector 1 intentionally underfunded).
        weth.mint(address(destinationConnector2), 160);
        weth.mint(address(destinationConnector3), 500);

        // Register connectors with each middleware instance (self-registration via connector call).
        sourceConnector1.registerWithMiddleware(address(sourceMiddleware));
        sourceConnector2.registerWithMiddleware(address(sourceMiddleware));
        sourceConnector3.registerWithMiddleware(address(sourceMiddleware));

        destinationConnector1.registerWithMiddleware(address(destinationMiddleware));
        destinationConnector2.registerWithMiddleware(address(destinationMiddleware));
        destinationConnector3.registerWithMiddleware(address(destinationMiddleware));

        // Destination connectors also need paired source middleware for funding-state control updates.
        destinationMiddleware.setConnectorRemoteMiddleware(destinationConnectorId1, address(sourceMiddleware));
        destinationMiddleware.setConnectorRemoteMiddleware(destinationConnectorId2, address(sourceMiddleware));
        destinationMiddleware.setConnectorRemoteMiddleware(destinationConnectorId3, address(sourceMiddleware));

        sourceMiddleware.setConnectorRemoteMiddleware(sourceConnectorId1, address(destinationMiddleware));
        sourceMiddleware.setConnectorRemoteMiddleware(sourceConnectorId2, address(destinationMiddleware));
        sourceMiddleware.setConnectorRemoteMiddleware(sourceConnectorId3, address(destinationMiddleware));

        echoApp = new EchoApplication(address(destinationMiddleware));

        bytes32[] memory connectorIds = new bytes32[](3);
        connectorIds[0] = sourceConnectorId1;
        connectorIds[1] = sourceConnectorId2;
        connectorIds[2] = sourceConnectorId3;
        sourceApp = new SourceApplication(address(sourceMiddleware), address(echoApp), connectorIds, DEST_MIN_CHARGE, WETH_UNIT);

        sourceMiddleware.registerLocalApplication(address(sourceApp));
        destinationMiddleware.registerLocalApplication(address(echoApp));

        // Connector 1 always denies authorization (simulates a known-bad connector).
        sourceConnector1.setDenyAuthorize(true);
    }

    function test_RevertWhenDeployingMiddlewareWithZeroQueueAddress() public {
        vm.expectRevert(ClprMiddleware.InvalidQueue.selector);
        new ClprMiddleware(address(0), SOURCE_LEDGER_ID);
    }

    function test_RevertWhenDeployingSourceApplicationWithZeroMiddlewareAddress() public {
        vm.expectRevert(SourceApplication.InvalidMiddleware.selector);
        bytes32[] memory connectorIds = new bytes32[](1);
        connectorIds[0] = bytes32(uint256(1));
        new SourceApplication(address(0), address(1), connectorIds, 1, "WETH");
    }

    function test_RevertWhenDeployingEchoApplicationWithZeroMiddlewareAddress() public {
        vm.expectRevert(EchoApplication.InvalidMiddleware.selector);
        new EchoApplication(address(0));
    }

    function test_TrustedCallbackCallerBypassesQueueOnlyGate() public {
        ClprTypes.ClprAmount memory zeroAmount = ClprTypes.ClprAmount({value: 0, unit: ""});
        ClprTypes.ClprMessageResponse memory response = ClprTypes.ClprMessageResponse({
            originalMessageId: 999,
            applicationResponse: ClprTypes.ClprApplicationResponse({data: bytes("")}),
            connectorResponse: ClprTypes.ClprConnectorResponse({data: bytes("")}),
            middlewareResponse: ClprTypes.ClprMiddlewareResponse({
                status: ClprTypes.ClprMiddlewareStatus.Success,
                minimumCharge: zeroAmount,
                maximumCharge: zeroAmount,
                middlewareMessage: ClprTypes.ClprMiddlewareMessage({
                    balanceReport: ClprTypes.ClprBalanceReport({
                        connectorId: bytes32(0),
                        availableBalance: zeroAmount,
                        safetyThreshold: zeroAmount,
                        outstandingCommitments: zeroAmount
                    }),
                    data: bytes("")
                })
            })
        });

        vm.expectRevert(ClprMiddleware.QueueOnly.selector);
        sourceMiddleware.handleMessageResponse(response);

        sourceMiddleware.setTrustedCallbackCaller(address(this));

        // With the trusted caller set, the QueueOnly gate is bypassed. Unknown originalMessageIds now
        // return silently (control message replies from the native ClprEndpointClient take this path).
        sourceMiddleware.handleMessageResponse(response);
    }

    function test_RevertWhenNonMiddlewareCallsQueueEnqueueApis() public {
        address outsider = makeAddr("outsider");
        ClprTypes.ClprAmount memory zeroAmount = ClprTypes.ClprAmount({value: 0, unit: ""});

        ClprTypes.ClprMessage memory message = ClprTypes.ClprMessage({
            senderApplicationId: address(sourceApp),
            applicationMessage: ClprTypes.ClprApplicationMessage({
                recipientId: address(echoApp),
                connectorId: sourceConnectorId1,
                maxCharge: zeroAmount,
                data: bytes("")
            }),
            destinationConnectorId: destinationConnectorId1,
            connectorMessage: ClprTypes.ClprConnectorMessage({approve: true, maxCharge: zeroAmount, data: bytes("")}),
            middlewareMessage: ClprTypes.ClprMiddlewareMessage({
                balanceReport: ClprTypes.ClprBalanceReport({
                    connectorId: bytes32(0),
                    availableBalance: zeroAmount,
                    safetyThreshold: zeroAmount,
                    outstandingCommitments: zeroAmount
                }),
                data: bytes("")
            })
        });

        ClprTypes.ClprMessageResponse memory response = ClprTypes.ClprMessageResponse({
            originalMessageId: 1,
            applicationResponse: ClprTypes.ClprApplicationResponse({data: bytes("")}),
            connectorResponse: ClprTypes.ClprConnectorResponse({data: bytes("")}),
            middlewareResponse: ClprTypes.ClprMiddlewareResponse({
                status: ClprTypes.ClprMiddlewareStatus.Success,
                minimumCharge: zeroAmount,
                maximumCharge: zeroAmount,
                middlewareMessage: ClprTypes.ClprMiddlewareMessage({
                    balanceReport: ClprTypes.ClprBalanceReport({
                        connectorId: bytes32(0),
                        availableBalance: zeroAmount,
                        safetyThreshold: zeroAmount,
                        outstandingCommitments: zeroAmount
                    }),
                    data: bytes("")
                })
            })
        });

        vm.prank(outsider);
        vm.expectRevert(MockClprQueue.MiddlewareOnly.selector);
        queue.enqueueMessage(message);

        vm.prank(outsider);
        vm.expectRevert(MockClprQueue.MiddlewareOnly.selector);
        queue.enqueueMessageResponse(response);
    }

    function test_SendsSixMessagesWithTopoffRecoveryAndRedeplete() public {
        // Message 1: connector 1 rejects; connector 2 accepts.
        _sendAccepted(bytes("mvp-msg-1"));
        assertEq(queue.nextMessageId(), 1);
        assertEq(sourceConnector1.authorizeCount(), 1);
        assertEq(sourceConnector2.authorizeCount(), 1);
        bytes memory expectedRequestRoute = abi.encode(uint8(1), DEST_LEDGER_ID, address(sourceMiddleware), address(destinationMiddleware));
        bytes memory expectedResponseRoute = abi.encode(uint8(1), DEST_LEDGER_ID, address(sourceMiddleware));
        assertEq(destinationConnector2.lastInboundRequestRouteData(), expectedRequestRoute);
        assertEq(queue.pendingResponseRouteData(1), expectedResponseRoute);

        // Message 2: connector 2 accepts.
        _sendAccepted(bytes("mvp-msg-2"));
        assertGe(queue.nextMessageId(), 2);
        assertEq(sourceConnector2.authorizeCount(), 2);
        assertEq(queue.pendingResponseRouteData(2), expectedResponseRoute);

        // Deliver responses so the source middleware learns the destination connector's balance report.
        queue.deliverAllMessageResponses();

        // Destination connector 2 should now be at the safety threshold boundary.
        assertEq(weth.balanceOf(address(destinationConnector2)), DEST_SAFETY_THRESHOLD);
        _assertRemoteStatus(destinationConnectorId2, DEST_SAFETY_THRESHOLD, DEST_SAFETY_THRESHOLD, DEST_MIN_CHARGE, 1);

        // Message 3: connector 2 is rejected pre-enqueue; connector 3 accepts.
        _sendAccepted(bytes("mvp-msg-3"));
        assertGe(queue.nextMessageId(), 4);
        assertEq(sourceConnector2.sendRejectedCount(), 1);
        assertEq(sourceConnector2.authorizeCount(), 2); // no authorize on pre-enqueue rejection
        assertEq(sourceConnector3.authorizeCount(), 1);

        // Message 4: connector 2 rejected again; connector 3 accepts.
        _sendAccepted(bytes("mvp-msg-4"));
        assertGe(queue.nextMessageId(), 5);
        assertEq(sourceConnector2.sendRejectedCount(), 2);
        assertEq(sourceConnector2.authorizeCount(), 2);
        assertEq(sourceConnector3.authorizeCount(), 2);
        queue.deliverAllMessageResponses();

        // Topoff connector2 by 50 WETH and deposit via funding-aware connector API.
        weth.mint(address(this), 50);
        weth.approve(address(destinationConnector2), 50);
        destinationConnector2.depositToken(50);
        _assertRemoteStatus(destinationConnectorId2, 110, DEST_SAFETY_THRESHOLD, DEST_MIN_CHARGE, 2);

        // Message 5: connector2 is usable again.
        _sendAccepted(bytes("mvp-msg-5"));
        assertGe(queue.nextMessageId(), 7);
        assertEq(sourceConnector2.authorizeCount(), 3);
        queue.deliverAllMessageResponses();

        // Depletion transition should publish epoch 3 update and return connector2 to threshold boundary.
        assertEq(sourceMiddleware.remoteFundingEpoch(destinationConnectorId2), 3);
        assertEq(weth.balanceOf(address(destinationConnector2)), DEST_SAFETY_THRESHOLD);

        // Message 6: connector2 rejected again; connector3 accepts.
        _sendAccepted(bytes("mvp-msg-6"));
        assertGe(queue.nextMessageId(), 8);
        assertEq(sourceConnector2.sendRejectedCount(), 3);
        assertEq(sourceConnector3.authorizeCount(), 3);
        queue.deliverAllMessageResponses();

        // Final connector counters and destination balances.
        assertEq(sourceConnector1.authorizeCount(), 6);
        assertEq(sourceConnector2.authorizeCount(), 3);
        assertEq(sourceConnector2.sendRejectedCount(), 3);
        assertEq(sourceConnector3.authorizeCount(), 3);
        assertEq(weth.balanceOf(address(destinationConnector2)), DEST_SAFETY_THRESHOLD);
        assertEq(weth.balanceOf(address(destinationConnector3)), 350);

        // Destination app handled all six successful messages.
        assertEq(echoApp.requestCount(), 6);
    }

    function _sendAccepted(bytes memory payload) private {
        ClprTypes.ClprSendMessageStatus memory status = sourceApp.sendWithFailoverFromFirst(payload);
        assertEq(uint8(status.status), uint8(ClprTypes.ClprSendStatus.Accepted));
    }

    function _assertRemoteStatus(
        bytes32 destinationConnectorId,
        uint256 expectedAvailableBalance,
        uint256 expectedSafetyThreshold,
        uint256 expectedMinimumCharge,
        uint64 expectedEpoch
    ) private {
        (
            uint256 availableBalance,
            uint256 safetyThreshold,
            uint256 minimumCharge,
            ,
            string memory unit,
            bool known,
            bool unavailable
        ) = sourceMiddleware.remoteStatusByDestinationConnector(destinationConnectorId);
        assertEq(known, true);
        assertEq(unavailable, false);
        assertEq(availableBalance, expectedAvailableBalance);
        assertEq(safetyThreshold, expectedSafetyThreshold);
        assertEq(minimumCharge, expectedMinimumCharge);
        assertEq(keccak256(bytes(unit)), keccak256(bytes(WETH_UNIT)));
        assertEq(sourceMiddleware.remoteFundingEpoch(destinationConnectorId), expectedEpoch);
    }
}
