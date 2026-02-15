// SPDX-License-Identifier: Apache-2.0
pragma solidity 0.8.24;

struct ClprAmount {
    uint256 amount;
    string tokenAddress;
}

struct ClprBalanceReport {
    bytes32 connectorId;
    ClprAmount sourceBalance;
    ClprAmount destinationBalance;
    ClprAmount networkFee;
}

struct ClprApplicationMessage {
    address destinationApplication;
    bytes32 destinationApplicationId;
    ClprAmount amount;
    bytes data;
}

struct ClprConnectorMessage {
    bool success;
    ClprAmount amount;
    bytes data;
}

struct ClprMiddlewareMessage {
    ClprBalanceReport balanceReport;
    bytes data;
}

struct ClprMessage {
    address sourceApplication;
    ClprApplicationMessage applicationMessage;
    bytes32 sourceConnectorId;
    ClprConnectorMessage connectorMessage;
    ClprMiddlewareMessage middlewareMessage;
}

struct ClprApplicationResponse {
    bytes data;
}

struct ClprConnectorResponse {
    bytes data;
}

enum ClprResponseCode {
    Success,
    UnsupportedOperation,
    InsufficientTransfer,
    SystemError
}

struct ClprMiddlewareResponse {
    ClprResponseCode code;
    ClprAmount sourceAmount;
    ClprAmount destinationAmount;
    ClprMiddlewareMessage middlewareMessage;
}

struct ClprMessageResponse {
    uint64 original_message_id;
    ClprApplicationResponse applicationResponse;
    ClprConnectorResponse connectorResponse;
    ClprMiddlewareResponse middlewareResponse;
}

interface IClprQueue {
    function enqueueMessage(ClprMessage memory message) external returns (uint64 messageId);

    function enqueueMessageResponse(ClprMessageResponse memory response) external returns (uint64 responseMessageId);
}

contract ClprMiddlewareHarness {
    IClprQueue private constant QUEUE = IClprQueue(address(0x16E));

    bool public failHandleMessage;
    bool public failHandleMessageResponse;

    uint64 public lastInboundMessageId;
    bytes public lastInboundRequestData;
    uint64 public lastResponseOriginalMessageId;
    bytes public lastResponseData;

    event HarnessHandleMessage(uint64 indexed inboundMessageId, bytes requestData);
    event HarnessHandleMessageResponse(uint64 indexed originalMessageId, bytes responseData);

    function setFailHandleMessage(bool shouldFail) external {
        failHandleMessage = shouldFail;
    }

    function setFailHandleMessageResponse(bool shouldFail) external {
        failHandleMessageResponse = shouldFail;
    }

    function sendMessage(bytes32 remoteLedgerId, address destinationMiddleware, bytes calldata payload)
        external
        returns (uint64 messageId)
    {
        ClprAmount memory amount = ClprAmount({amount: 1, tokenAddress: "tinybar"});
        ClprBalanceReport memory balanceReport = ClprBalanceReport({
            connectorId: bytes32(0),
            sourceBalance: amount,
            destinationBalance: amount,
            networkFee: amount
        });

        bytes memory routeHeader = abi.encode(uint8(1), remoteLedgerId, address(this), destinationMiddleware);

        ClprApplicationMessage memory applicationMessage = ClprApplicationMessage({
            destinationApplication: destinationMiddleware,
            destinationApplicationId: bytes32(0),
            amount: amount,
            data: payload
        });

        ClprConnectorMessage memory connectorMessage = ClprConnectorMessage({success: true, amount: amount, data: ""});

        ClprMiddlewareMessage memory middlewareMessage =
            ClprMiddlewareMessage({balanceReport: balanceReport, data: routeHeader});

        ClprMessage memory message = ClprMessage({
            sourceApplication: address(this),
            applicationMessage: applicationMessage,
            sourceConnectorId: bytes32(0),
            connectorMessage: connectorMessage,
            middlewareMessage: middlewareMessage
        });

        return QUEUE.enqueueMessage(message);
    }

    function handleMessage(ClprMessage calldata message, uint64 inboundMessageId)
        external
        returns (ClprMessageResponse memory response)
    {
        require(!failHandleMessage, "HARNESS_FAIL_MESSAGE");

        lastInboundMessageId = inboundMessageId;
        lastInboundRequestData = message.applicationMessage.data;
        emit HarnessHandleMessage(inboundMessageId, message.applicationMessage.data);

        response.original_message_id = inboundMessageId;
        response.applicationResponse.data = message.applicationMessage.data;
        response.connectorResponse.data = bytes("connector-ok");
        response.middlewareResponse.code = ClprResponseCode.Success;
        response.middlewareResponse.sourceAmount = message.applicationMessage.amount;
        response.middlewareResponse.destinationAmount = message.applicationMessage.amount;
        response.middlewareResponse.middlewareMessage.balanceReport = message.middlewareMessage.balanceReport;
        response.middlewareResponse.middlewareMessage.data = message.middlewareMessage.data;
    }

    function handleMessageResponse(ClprMessageResponse calldata response) external {
        require(!failHandleMessageResponse, "HARNESS_FAIL_RESPONSE");

        lastResponseOriginalMessageId = response.original_message_id;
        lastResponseData = response.applicationResponse.data;
        emit HarnessHandleMessageResponse(response.original_message_id, response.applicationResponse.data);
    }
}
