// SPDX-License-Identifier: Apache-2.0
package com.hedera.node.app.service.contract.impl.exec.systemcontracts.clpr.enqueuemessage;

import static com.hedera.hapi.node.base.ResponseCodeEnum.CONTRACT_REVERT_EXECUTED;
import static com.hedera.hapi.node.base.ResponseCodeEnum.SUCCESS;
import static com.hedera.node.app.service.contract.impl.exec.systemcontracts.FullResult.revertResult;
import static com.hedera.node.app.service.contract.impl.exec.systemcontracts.FullResult.successResult;
import static com.hedera.node.app.service.contract.impl.exec.systemcontracts.common.Call.PricedResult.gasOnly;
import static java.nio.charset.StandardCharsets.UTF_8;
import static java.util.Objects.requireNonNull;

import com.esaulpaugh.headlong.abi.Address;
import com.esaulpaugh.headlong.abi.Tuple;
import com.esaulpaugh.headlong.abi.TupleType;
import com.hedera.node.app.service.contract.impl.exec.gas.SystemContractGasCalculator;
import com.hedera.node.app.service.contract.impl.exec.systemcontracts.common.AbstractCall;
import com.hedera.node.app.service.contract.impl.hevm.HederaWorldUpdater;
import com.hedera.node.app.spi.workflows.HandleException;
import edu.umd.cs.findbugs.annotations.NonNull;
import java.math.BigInteger;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessage;
import org.hiero.hapi.interledger.state.clpr.ClprMessagePayload;
import org.hiero.interledger.clpr.impl.ClprQueueOperations;
import org.apache.tuweni.bytes.Bytes;
import org.hyperledger.besu.evm.frame.MessageFrame;

/**
 * Executes {@code enqueueMessage(...)} by adapting calldata into native CLPR queue state updates.
 */
public class ClprQueueEnqueueMessageCall extends AbstractCall {
    private static final int SUPPORTED_ROUTE_VERSION = 1;
    private static final TupleType<Tuple> ROUTE_HEADER_TYPE = TupleType.parse("(uint8,bytes32,address,address)");
    private static final TupleType<Tuple> REQUEST_ENVELOPE_TYPE = TupleType.parse("(uint8,bytes32,address,address,bytes)");

    private final byte[] callData;
    private final Tuple clprMessage;

    public ClprQueueEnqueueMessageCall(
            @NonNull final SystemContractGasCalculator gasCalculator,
            @NonNull final HederaWorldUpdater.Enhancement enhancement,
            @NonNull final byte[] callData,
            @NonNull final Tuple clprMessage) {
        super(gasCalculator, enhancement, false);
        this.callData = requireNonNull(callData);
        this.clprMessage = requireNonNull(clprMessage);
    }

    @Override
    public @NonNull PricedResult execute(@NonNull final MessageFrame frame) {
        requireNonNull(frame);
        final RouteHeader routeHeader;
        try {
            routeHeader = decodeRouteHeader(clprMessage);
        } catch (final RuntimeException ignore) {
            return revertWithReason("CLPR_QUEUE_BAD_ROUTE_ENVELOPE");
        }

        if (routeHeader.version() != SUPPORTED_ROUTE_VERSION) {
            return revertWithReason("CLPR_QUEUE_UNSUPPORTED_ROUTE_VERSION");
        }
        if (routeHeader.remoteLedgerId().length == 0 || isAllZero(routeHeader.remoteLedgerId())) {
            return revertWithReason("CLPR_QUEUE_INVALID_REMOTE_LEDGER_ID");
        }

        final var remoteLedgerId =
                ClprLedgerId.newBuilder().ledgerId(com.hedera.pbj.runtime.io.buffer.Bytes.wrap(routeHeader.remoteLedgerId())).build();
        final var requestEnvelope = encodeRequestEnvelope(routeHeader, callData);
        final var payload = ClprMessagePayload.newBuilder()
                .message(ClprMessage.newBuilder()
                        .messageData(com.hedera.pbj.runtime.io.buffer.Bytes.wrap(requestEnvelope))
                        .build())
                .build();

        try {
            final var messageId = ClprQueueOperations.enqueue(
                    nativeOperations().writableClprMessageQueueMetadataStore(),
                    nativeOperations().writableClprMessageStore(),
                    remoteLedgerId,
                    payload);
            final var output = ClprQueueEnqueueMessageTranslator.ENQUEUE_MESSAGE
                    .getOutputs()
                    .encode(Tuple.singleton(BigInteger.valueOf(messageId)));
            return gasOnly(successResult(output, gasCalculator.viewGasRequirement()), SUCCESS, isViewCall);
        } catch (final HandleException e) {
            return revertWithReason(e.getStatus().protoName());
        }
    }

    private static RouteHeader decodeRouteHeader(@NonNull final Tuple clprMessage) {
        final var middlewareMessage = (Tuple) clprMessage.get(4);
        final var routeHeaderBytes = (byte[]) middlewareMessage.get(1);
        final var routeHeader = ROUTE_HEADER_TYPE.decode(routeHeaderBytes);
        final var version = ((Number) routeHeader.get(0)).intValue();
        final var remoteLedgerId = (byte[]) routeHeader.get(1);
        final var sourceMiddleware = (Address) routeHeader.get(2);
        final var destinationMiddleware = (Address) routeHeader.get(3);
        return new RouteHeader(version, remoteLedgerId, sourceMiddleware, destinationMiddleware);
    }

    private static byte[] encodeRequestEnvelope(@NonNull final RouteHeader routeHeader, @NonNull final byte[] callData) {
        final var encodedEnvelope = REQUEST_ENVELOPE_TYPE.encode(Tuple.of(
                routeHeader.version(),
                routeHeader.remoteLedgerId(),
                routeHeader.sourceMiddleware(),
                routeHeader.destinationMiddleware(),
                callData));
        final byte[] envelopeBytes = new byte[encodedEnvelope.remaining()];
        encodedEnvelope.get(envelopeBytes);
        return envelopeBytes;
    }

    private PricedResult revertWithReason(@NonNull final String reason) {
        return gasOnly(
                revertResult(Bytes.wrap(requireNonNull(reason).getBytes(UTF_8)), gasCalculator.viewGasRequirement()),
                CONTRACT_REVERT_EXECUTED,
                isViewCall);
    }

    private static boolean isAllZero(@NonNull final byte[] bytes) {
        for (final byte value : bytes) {
            if (value != 0) {
                return false;
            }
        }
        return true;
    }

    private record RouteHeader(int version, byte[] remoteLedgerId, Address sourceMiddleware, Address destinationMiddleware) {}
}
