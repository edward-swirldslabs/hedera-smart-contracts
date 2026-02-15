// SPDX-License-Identifier: Apache-2.0
package org.hiero.interledger.clpr.impl.handlers;

import static com.hedera.hapi.node.base.ResponseCodeEnum.SUCCESS;
import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_INVALID_BUNDLE;
import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_INVALID_RUNNING_HASH;
import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_INVALID_STATE_PROOF;
import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_MESSAGE_QUEUE_NOT_AVAILABLE;
import static com.hedera.hapi.node.base.ResponseCodeEnum.INVALID_TRANSACTION_BODY;
import static com.hedera.hapi.node.base.ResponseCodeEnum.NOT_SUPPORTED;
import static com.hedera.node.app.spi.workflows.HandleException.validateFalse;
import static com.hedera.node.app.spi.workflows.HandleException.validateTrue;
import static com.hedera.node.app.spi.workflows.DispatchOptions.stepDispatch;
import static com.hedera.node.app.spi.workflows.PreCheckException.validateFalsePreCheck;
import static com.hedera.node.app.spi.workflows.PreCheckException.validateTruePreCheck;
import static com.hedera.node.app.spi.workflows.record.StreamBuilder.SignedTxCustomizer.NOOP_SIGNED_TX_CUSTOMIZER;
import static java.util.Objects.requireNonNull;
import static org.hiero.interledger.clpr.ClprStateProofUtils.extractMessageKey;
import static org.hiero.interledger.clpr.ClprStateProofUtils.extractMessageValue;
import static org.hiero.interledger.clpr.ClprStateProofUtils.validateStateProof;
import static org.hiero.interledger.clpr.impl.ClprMessageUtils.nextRunningHash;

import com.esaulpaugh.headlong.abi.Address;
import com.esaulpaugh.headlong.abi.Function;
import com.esaulpaugh.headlong.abi.Tuple;
import com.esaulpaugh.headlong.abi.TupleType;
import com.hedera.hapi.node.base.ContractID;
import com.hedera.hapi.node.contract.ContractCallTransactionBody;
import com.hedera.hapi.node.transaction.TransactionBody;
import com.hedera.node.app.spi.info.NetworkInfo;
import com.hedera.node.app.spi.workflows.HandleContext;
import com.hedera.node.app.spi.workflows.HandleException;
import com.hedera.node.app.spi.workflows.PreCheckException;
import com.hedera.node.app.spi.workflows.PreHandleContext;
import com.hedera.node.app.spi.workflows.PureChecksContext;
import com.hedera.node.app.spi.workflows.TransactionHandler;
import com.hedera.node.app.spi.workflows.record.StreamBuilder;
import com.hedera.node.config.ConfigProvider;
import com.hedera.node.config.data.ContractsConfig;
import com.hedera.node.config.data.HederaConfig;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import edu.umd.cs.findbugs.annotations.NonNull;
import java.nio.ByteBuffer;
import java.util.HexFormat;
import java.util.ArrayList;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;
import javax.inject.Inject;
import java.math.BigInteger;
import org.apache.logging.log4j.LogManager;
import org.apache.logging.log4j.Logger;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageKey;
import org.hiero.hapi.interledger.state.clpr.ClprMessagePayload;
import org.hiero.hapi.interledger.state.clpr.ClprMessageReply;
import org.hiero.hapi.interledger.state.clpr.ClprMessageValue;
import org.hiero.interledger.clpr.WritableClprMessageQueueMetadataStore;
import org.hiero.interledger.clpr.WritableClprMessageStore;
import org.hiero.interledger.clpr.impl.ClprQueueOperations;
import org.hiero.interledger.clpr.impl.ClprStateProofManager;

public class ClprProcessMessageBundleHandler implements TransactionHandler {
    private static final Logger log = LogManager.getLogger(ClprProcessMessageBundleHandler.class);

    private static final int SUPPORTED_ROUTE_VERSION = 1;
    private static final TupleType<Tuple> REQUEST_ENVELOPE_TYPE = TupleType.parse("(uint8,bytes32,address,address,bytes)");
    private static final TupleType<Tuple> RESPONSE_ENVELOPE_TYPE = TupleType.parse("(uint8,address,bytes)");
    private static final TupleType<Tuple> RESPONSE_ROUTE_HEADER_TYPE = TupleType.parse("(uint8,bytes32,address)");

    private static final String ENQUEUE_MESSAGE_SIGNATURE =
            "enqueueMessage((address,(address,bytes32,(uint256,string),bytes),bytes32,(bool,(uint256,string),bytes),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes)))";
    private static final String ENQUEUE_MESSAGE_RESPONSE_SIGNATURE =
            "enqueueMessageResponse((uint64,(bytes),(bytes),(uint8,(uint256,string),(uint256,string),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes))))";
    private static final String HANDLE_MESSAGE_SIGNATURE =
            "handleMessage((address,(address,bytes32,(uint256,string),bytes),bytes32,(bool,(uint256,string),bytes),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes)),uint64)";
    private static final String HANDLE_MESSAGE_RESPONSE_SIGNATURE =
            "handleMessageResponse((uint64,(bytes),(bytes),(uint8,(uint256,string),(uint256,string),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes))))";

    private static final Function ENQUEUE_MESSAGE = new Function(ENQUEUE_MESSAGE_SIGNATURE, "(uint64)");
    private static final Function ENQUEUE_MESSAGE_RESPONSE = new Function(ENQUEUE_MESSAGE_RESPONSE_SIGNATURE, "(uint64)");
    private static final Function HANDLE_MESSAGE = new Function(HANDLE_MESSAGE_SIGNATURE, "("
            + "(uint64,(bytes),(bytes),(uint8,(uint256,string),(uint256,string),((bytes32,(uint256,string),(uint256,string),(uint256,string)),bytes)))"
            + ")");
    private static final Function HANDLE_MESSAGE_RESPONSE = new Function(HANDLE_MESSAGE_RESPONSE_SIGNATURE);
    private final ClprStateProofManager stateProofManager;
    private final NetworkInfo networkInfo;
    private final ConfigProvider configProvider;

    @Inject
    public ClprProcessMessageBundleHandler(
            @NonNull final ClprStateProofManager stateProofManager,
            @NonNull final NetworkInfo networkInfo,
            @NonNull final ConfigProvider configProvider) {
        this.stateProofManager = requireNonNull(stateProofManager);
        this.networkInfo = requireNonNull(networkInfo);
        this.configProvider = requireNonNull(configProvider);
    }

    @Override
    public void pureChecks(@NonNull PureChecksContext context) throws PreCheckException {
        validateTruePreCheck(stateProofManager.clprEnabled(), NOT_SUPPORTED);
        final var body = context.body();
        // validate mandatory fields
        validateTruePreCheck(body.clprProcessMessageBundleOrThrow().hasMessageBundle(), INVALID_TRANSACTION_BODY);
        final var bundle = body.clprProcessMessageBundleOrThrow().messageBundleOrThrow();
        // bundle must have at least state proof
        validateTruePreCheck(bundle.hasStateProof(), CLPR_INVALID_STATE_PROOF);
        // validate the state proof
        final var stateProof = bundle.stateProofOrThrow();
        validateTruePreCheck(validateStateProof(stateProof), CLPR_INVALID_STATE_PROOF);

        final var messageQueue = stateProofManager.getLocalMessageQueueMetadata(bundle.ledgerIdOrThrow());
        validateTruePreCheck(messageQueue != null, CLPR_MESSAGE_QUEUE_NOT_AVAILABLE);

        final var receivedMessageId = messageQueue.receivedMessageId();
        final var firstNonProcessedMsgId = receivedMessageId + 1;
        final var lastBundleMessageKey = extractMessageKey(stateProof);
        final var lastBundleMessageId = lastBundleMessageKey.messageId();
        final var firstBundleMessageId = lastBundleMessageId - bundle.messages().size();

        // validate if the bundle has misaligned message ids or all messages in the bundle are already processed
        validateFalsePreCheck(lastBundleMessageId <= receivedMessageId, CLPR_INVALID_BUNDLE);
        validateFalsePreCheck(firstBundleMessageId > firstNonProcessedMsgId, CLPR_INVALID_BUNDLE);

        // we may have already received a part of this bundle (or entire bundle).
        // In this case we should skip processing these messages
        final var skipCount = firstNonProcessedMsgId - firstBundleMessageId;

        final var lastBundleMessageValue = extractMessageValue(stateProof);
        final var lastBundleMessageRunningHash = lastBundleMessageValue.runningHashAfterProcessing();
        AtomicReference<Bytes> runningHash = new AtomicReference<>(messageQueue.receivedRunningHash());
        bundle.messages().stream()
                .skip(skipCount)
                .forEach(msg -> runningHash.set(nextRunningHash(msg, runningHash.get())));
        runningHash.set(nextRunningHash(lastBundleMessageValue.payload(), runningHash.get()));
        validateTruePreCheck(lastBundleMessageRunningHash.equals(runningHash.get()), CLPR_INVALID_RUNNING_HASH);
    }

    @Override
    public void preHandle(@NonNull PreHandleContext context) throws PreCheckException {
        validateTruePreCheck(stateProofManager.clprEnabled(), NOT_SUPPORTED);
        // TODO: Implement preHandle once the payer and required signatures requirements are clear!
    }

    @Override
    public void handle(@NonNull HandleContext context) throws HandleException {
        requireNonNull(context);
        final var writableMessagesStore = context.storeFactory().writableStore(WritableClprMessageStore.class);
        final var writableMessageQueueStore =
                context.storeFactory().writableStore(WritableClprMessageQueueMetadataStore.class);

        final var txn = context.body();
        final var bundle = txn.clprProcessMessageBundleOrThrow().messageBundleOrThrow();
        final var ledgerId = bundle.ledgerIdOrThrow();

        final var messageQueue = writableMessageQueueStore.get(ledgerId);
        validateTrue(messageQueue != null, CLPR_MESSAGE_QUEUE_NOT_AVAILABLE);

        final var lastBundleMessageKey = extractMessageKey(bundle.stateProofOrThrow());
        final var lastBundleMessageValue = extractMessageValue(bundle.stateProofOrThrow());
        final var lastBundleMessageRunningHash = lastBundleMessageValue.runningHashAfterProcessing();

        final var receivedMessageId = messageQueue.receivedMessageId();
        final var firstNonProcessedMsgId = receivedMessageId + 1;
        final var lastBundleMessageId = lastBundleMessageKey.messageId();
        final var firstBundleMessageId = lastBundleMessageId - bundle.messages().size();
        if (firstBundleMessageId > firstNonProcessedMsgId) {
            throw new HandleException(CLPR_INVALID_BUNDLE);
        }

        // we may have already received a part of this bundle (or entire bundle).
        // In this case we should skip processing these messages
        final var skipCount = firstNonProcessedMsgId - firstBundleMessageId;

        // 1. Handle all messages (including the last message, extracted from the state proof)
        final var bundleMessages = new ArrayList<>(bundle.messages());
        bundleMessages.add(lastBundleMessageValue.payload());

        final var receivedMsgId = new AtomicLong(messageQueue.receivedMessageId());
        final int startIndex = Math.toIntExact(skipCount);
        for (int i = startIndex; i < bundleMessages.size(); i++) {
            final var payload = bundleMessages.get(i);
            final var inboundMessageId = receivedMsgId.incrementAndGet();
            if (payload.hasMessage()) {
                processInboundRequest(
                        context,
                        writableMessageQueueStore,
                        writableMessagesStore,
                        ledgerId,
                        inboundMessageId,
                        payload);
            } else if (payload.hasMessageReply()) {
                processInboundResponse(context, payload);
            } else {
                throw new HandleException(INVALID_TRANSACTION_BODY);
            }
        }

        // update message queue
        final var updatedQueueBuilder = writableMessageQueueStore.get(ledgerId).copyBuilder();
        updatedQueueBuilder.receivedMessageId(receivedMsgId.get());
        updatedQueueBuilder.receivedRunningHash(lastBundleMessageRunningHash);
        writableMessageQueueStore.put(ledgerId, updatedQueueBuilder.build());
    }

    private void processInboundRequest(
            @NonNull final HandleContext context,
            @NonNull final WritableClprMessageQueueMetadataStore writableMessageQueueStore,
            @NonNull final WritableClprMessageStore writableMessagesStore,
            @NonNull final ClprLedgerId localLedgerId,
            final long inboundMessageId,
            @NonNull final ClprMessagePayload payload)
            throws HandleException {
        final var maybeEnvelope = decodeRequestEnvelope(payload);
        if (maybeEnvelope == null) {
            enqueueLegacyReply(writableMessageQueueStore, writableMessagesStore, localLedgerId, inboundMessageId, payload);
            return;
        }
        validateRequestEnvelope(maybeEnvelope);

        final var responseCallData = invokeHandleMessageCallback(context, maybeEnvelope, inboundMessageId);
        final var responseCallDataWithRoute = injectResponseRouteHeader(responseCallData, maybeEnvelope);
        final var responseEnvelope = encodeResponseEnvelope(
                maybeEnvelope.version(), maybeEnvelope.sourceMiddleware(), responseCallDataWithRoute);
        final var replyPayload = ClprMessagePayload.newBuilder()
                .messageReply(ClprMessageReply.newBuilder()
                        .messageId(inboundMessageId)
                        .messageReplyData(Bytes.wrap(responseEnvelope))
                        .build())
                .build();
        // Endpoint-client semantics: responses must be enqueued under the bundle's ledgerId (the sender of this request
        // bundle) so the source ledger can later pull responses via getMessages(localLedgerId).
        ClprQueueOperations.enqueue(writableMessageQueueStore, writableMessagesStore, localLedgerId, replyPayload);
    }

    private void processInboundResponse(@NonNull final HandleContext context, @NonNull final ClprMessagePayload payload)
            throws HandleException {
        final var maybeEnvelope = decodeResponseEnvelope(payload);
        if (maybeEnvelope == null) {
            // Legacy payload path: no middleware callback can be derived.
            return;
        }
        validateResponseEnvelope(maybeEnvelope);
        invokeHandleMessageResponseCallback(context, maybeEnvelope);
    }

    private void enqueueLegacyReply(
            @NonNull final WritableClprMessageQueueMetadataStore writableMessageQueueStore,
            @NonNull final WritableClprMessageStore writableMessagesStore,
            @NonNull final ClprLedgerId ledgerId,
            final long inboundMessageId,
            @NonNull final ClprMessagePayload payload)
            throws HandleException {
        final var replyPayload = ClprMessagePayload.newBuilder()
                .messageReply(ClprMessageReply.newBuilder()
                        .messageId(inboundMessageId)
                        .messageReplyData(payload.messageOrThrow().messageData())
                        .build())
                .build();
        ClprQueueOperations.enqueue(writableMessageQueueStore, writableMessagesStore, ledgerId, replyPayload);
    }

    private byte[] invokeHandleMessageCallback(
            @NonNull final HandleContext context, @NonNull final RequestEnvelope envelope, final long inboundMessageId)
            throws HandleException {
        final Tuple enqueueArgs;
        try {
            enqueueArgs = ENQUEUE_MESSAGE.decodeCall(envelope.callData());
        } catch (final RuntimeException e) {
            throw new HandleException(INVALID_TRANSACTION_BODY);
        }
        final var messageTuple = (Tuple) enqueueArgs.get(0);
        final var handleMessageCallData = toArray(HANDLE_MESSAGE.encodeCall(Tuple.of(messageTuple, BigInteger.valueOf(inboundMessageId))));
        final var streamBuilder = dispatchContractCall(context, envelope.destinationMiddleware(), handleMessageCallData);
        validateTrue(streamBuilder.status() == SUCCESS, streamBuilder.status());

        final byte[] callbackResult;
        try {
            callbackResult = extractEvmCallResult(streamBuilder);
        } catch (final HandleException e) {
            throw e;
        }
        if (callbackResult.length == 0) {
            throw new HandleException(CLPR_INVALID_BUNDLE);
        }
        final Tuple handleMessageReturn;
        try {
            handleMessageReturn = HANDLE_MESSAGE.decodeReturn(callbackResult);
        } catch (final RuntimeException e) {
            throw new HandleException(CLPR_INVALID_BUNDLE);
        }
        final var responseTuple = (Tuple) handleMessageReturn.get(0);
        return toArray(ENQUEUE_MESSAGE_RESPONSE.encodeCall(Tuple.singleton(responseTuple)));
    }

    private void invokeHandleMessageResponseCallback(
            @NonNull final HandleContext context, @NonNull final ResponseEnvelope envelope) throws HandleException {
        final Tuple enqueueResponseArgs;
        try {
            enqueueResponseArgs = ENQUEUE_MESSAGE_RESPONSE.decodeCall(envelope.callData());
        } catch (final RuntimeException e) {
            throw new HandleException(INVALID_TRANSACTION_BODY);
        }
        final var responseTuple = (Tuple) enqueueResponseArgs.get(0);
        final var handleResponseCallData = toArray(HANDLE_MESSAGE_RESPONSE.encodeCall(Tuple.singleton(responseTuple)));
        final var streamBuilder = dispatchContractCall(context, envelope.targetMiddleware(), handleResponseCallData);
        validateTrue(streamBuilder.status() == SUCCESS, streamBuilder.status());
    }

    private StreamBuilder dispatchContractCall(
            @NonNull final HandleContext context, @NonNull final Address targetMiddleware, @NonNull final byte[] callData) {
        final var contractCallBody = ContractCallTransactionBody.newBuilder()
                .contractID(asContractId(targetMiddleware))
                .gas(maxGasPerContractCall())
                .functionParameters(Bytes.wrap(callData))
                .build();
        final var syntheticTxn =
                TransactionBody.newBuilder().contractCall(contractCallBody).build();
        return context.dispatch(stepDispatch(
                context.payer(), syntheticTxn, StreamBuilder.class, NOOP_SIGNED_TX_CUSTOMIZER));
    }

    private long maxGasPerContractCall() {
        return configProvider
                .getConfiguration()
                .getConfigData(ContractsConfig.class)
                .maxGasPerTransaction();
    }

    private ContractID asContractId(@NonNull final Address targetMiddleware) {
        final var hederaConfig = configProvider.getConfiguration().getConfigData(HederaConfig.class);
        final var explicitAddress = explicitFromHeadlong(targetMiddleware);
        final var contractIdBuilder = ContractID.newBuilder()
                .shardNum(hederaConfig.shard())
                .realmNum(hederaConfig.realm());
        final var contractNum =
                contractNumIfNumberedAddress(explicitAddress, hederaConfig.shard(), hederaConfig.realm());
        if (contractNum != null) {
            return contractIdBuilder.contractNum(contractNum).build();
        }
        return contractIdBuilder.evmAddress(Bytes.wrap(explicitAddress)).build();
    }

    private static Long contractNumIfNumberedAddress(
            @NonNull final byte[] explicitAddress, final long shard, final long realm) {
        if (explicitAddress.length != 20) {
            return null;
        }
        if (isLongZeroAddress(explicitAddress)) {
            return numberOfLongZero(explicitAddress);
        }
        if (isSolidityAddressFor(explicitAddress, shard, realm)) {
            return ByteBuffer.wrap(explicitAddress, 12, Long.BYTES).getLong();
        }
        return null;
    }

    private static boolean isLongZeroAddress(@NonNull final byte[] explicitAddress) {
        for (int i = 0; i < 12; i++) {
            if (explicitAddress[i] != 0) {
                return false;
            }
        }
        return true;
    }

    private static long numberOfLongZero(@NonNull final byte[] explicitAddress) {
        return ByteBuffer.wrap(explicitAddress, 12, Long.BYTES).getLong();
    }

    private static boolean isSolidityAddressFor(
            @NonNull final byte[] explicitAddress, final long expectedShard, final long expectedRealm) {
        final var encodedShard = Integer.toUnsignedLong(ByteBuffer.wrap(explicitAddress, 0, Integer.BYTES).getInt());
        final var encodedRealm = ByteBuffer.wrap(explicitAddress, Integer.BYTES, Long.BYTES).getLong();
        return encodedShard == expectedShard && encodedRealm == expectedRealm;
    }

    private RequestEnvelope decodeRequestEnvelope(@NonNull final ClprMessagePayload payload) {
        try {
            final var tuple = REQUEST_ENVELOPE_TYPE.decode(payload.messageOrThrow().messageData().toByteArray());
            final var version = ((Number) tuple.get(0)).intValue();
            final var remoteLedgerId = (byte[]) tuple.get(1);
            final var sourceMiddleware = (Address) tuple.get(2);
            final var destinationMiddleware = (Address) tuple.get(3);
            final var callData = (byte[]) tuple.get(4);
            return new RequestEnvelope(version, remoteLedgerId, sourceMiddleware, destinationMiddleware, callData);
        } catch (final RuntimeException e) {
            final var bytes = payload.hasMessage() ? payload.messageOrThrow().messageData() : Bytes.EMPTY;
            log.debug("Failed to decode request envelope payload (size={})", bytes.length(), e);
            return null;
        }
    }

    private ResponseEnvelope decodeResponseEnvelope(@NonNull final ClprMessagePayload payload) {
        try {
            final var tuple =
                    RESPONSE_ENVELOPE_TYPE.decode(payload.messageReplyOrThrow().messageReplyData().toByteArray());
            final var version = ((Number) tuple.get(0)).intValue();
            final var targetMiddleware = (Address) tuple.get(1);
            final var callData = (byte[]) tuple.get(2);
            return new ResponseEnvelope(version, targetMiddleware, callData);
        } catch (final RuntimeException e) {
            final var bytes = payload.hasMessageReply() ? payload.messageReplyOrThrow().messageReplyData() : Bytes.EMPTY;
            log.debug("Failed to decode response envelope payload (size={})", bytes.length(), e);
            return null;
        }
    }

    private void validateRequestEnvelope(@NonNull final RequestEnvelope envelope) throws HandleException {
        validateTrue(envelope.version() == SUPPORTED_ROUTE_VERSION, CLPR_INVALID_STATE_PROOF);
        validateTrue(
                envelope.remoteLedgerId().length > 0 && !isAllZero(envelope.remoteLedgerId()),
                CLPR_INVALID_STATE_PROOF);
    }

    private void validateResponseEnvelope(@NonNull final ResponseEnvelope envelope) throws HandleException {
        validateTrue(envelope.version() == SUPPORTED_ROUTE_VERSION, CLPR_INVALID_STATE_PROOF);
    }

    private byte[] injectResponseRouteHeader(@NonNull final byte[] enqueueResponseCallData, @NonNull final RequestEnvelope requestEnvelope)
            throws HandleException {
        try {
            final var responseCall = ENQUEUE_MESSAGE_RESPONSE.decodeCall(enqueueResponseCallData);
            final var responseTuple = (Tuple) responseCall.get(0);
            final var middlewareResponse = (Tuple) responseTuple.get(3);
            final var middlewareMessage = (Tuple) middlewareResponse.get(3);
            final var routeHeader = toArray(RESPONSE_ROUTE_HEADER_TYPE.encode(Tuple.of(
                    requestEnvelope.version(), requestEnvelope.remoteLedgerId(), requestEnvelope.sourceMiddleware())));
            final var patchedMiddlewareMessage = Tuple.of(middlewareMessage.get(0), routeHeader);
            final var patchedMiddlewareResponse = Tuple.of(
                    middlewareResponse.get(0), middlewareResponse.get(1), middlewareResponse.get(2), patchedMiddlewareMessage);
            final var patchedResponseTuple =
                    Tuple.of(responseTuple.get(0), responseTuple.get(1), responseTuple.get(2), patchedMiddlewareResponse);
            return toArray(ENQUEUE_MESSAGE_RESPONSE.encodeCall(Tuple.singleton(patchedResponseTuple)));
        } catch (final RuntimeException e) {
            log.warn("Failed to inject response route header", e);
            throw new HandleException(CLPR_INVALID_BUNDLE);
        }
    }

    private static byte[] encodeResponseEnvelope(
            final int version, @NonNull final Address targetMiddleware, @NonNull final byte[] callData) {
        return toArray(RESPONSE_ENVELOPE_TYPE.encode(Tuple.of(version, targetMiddleware, callData)));
    }

    private static byte[] explicitFromHeadlong(@NonNull final Address address) {
        final var hexAddress = address.toString();
        return HexFormat.of().parseHex(hexAddress.startsWith("0x") ? hexAddress.substring(2) : hexAddress);
    }

    private static boolean isAllZero(@NonNull final byte[] bytes) {
        for (final byte value : bytes) {
            if (value != 0) {
                return false;
            }
        }
        return true;
    }

    private static byte[] toArray(@NonNull final ByteBuffer byteBuffer) {
        final var out = new byte[byteBuffer.remaining()];
        byteBuffer.get(out);
        return out;
    }

    private byte[] extractEvmCallResult(@NonNull final StreamBuilder streamBuilder) throws HandleException {
        try {
            final var accessor = streamBuilder.getClass().getMethod("getEvmCallResult");
            final var value = accessor.invoke(streamBuilder);
            if (value instanceof Bytes bytes) {
                return bytes.toByteArray();
            }
            log.warn(
                    "getEvmCallResult returned unsupported type {} from {}",
                    value == null ? "null" : value.getClass().getName(),
                    streamBuilder.getClass().getName());
        } catch (final ReflectiveOperationException e) {
            log.warn(
                    "Failed to extract EVM call result via reflection from {}",
                    streamBuilder.getClass().getName(),
                    e);
            throw new HandleException(NOT_SUPPORTED);
        }
        log.warn(
                "Missing usable EVM call result from streamBuilder {}",
                streamBuilder.getClass().getName());
        throw new HandleException(NOT_SUPPORTED);
    }

    private record RequestEnvelope(
            int version, byte[] remoteLedgerId, Address sourceMiddleware, Address destinationMiddleware, byte[] callData) {}

    private record ResponseEnvelope(int version, Address targetMiddleware, byte[] callData) {}
}
