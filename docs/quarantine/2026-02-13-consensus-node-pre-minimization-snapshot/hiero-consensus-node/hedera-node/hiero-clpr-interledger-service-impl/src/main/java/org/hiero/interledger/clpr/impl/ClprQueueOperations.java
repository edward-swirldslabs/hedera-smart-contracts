// SPDX-License-Identifier: Apache-2.0
package org.hiero.interledger.clpr.impl;

import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_INVALID_LEDGER_ID;
import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_MESSAGE_QUEUE_NOT_AVAILABLE;
import static com.hedera.hapi.node.base.ResponseCodeEnum.INVALID_TRANSACTION_BODY;
import static com.hedera.node.app.spi.workflows.HandleException.validateTrue;
import static java.util.Objects.requireNonNull;
import static org.hiero.interledger.clpr.impl.ClprMessageUtils.nextRunningHash;

import com.hedera.node.app.spi.workflows.HandleException;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import edu.umd.cs.findbugs.annotations.NonNull;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageKey;
import org.hiero.hapi.interledger.state.clpr.ClprMessagePayload;
import org.hiero.hapi.interledger.state.clpr.ClprMessageQueueMetadata;
import org.hiero.hapi.interledger.state.clpr.ClprMessageValue;
import org.hiero.interledger.clpr.WritableClprMessageQueueMetadataStore;
import org.hiero.interledger.clpr.WritableClprMessageStore;

/**
 * Native queue mutation operations used by CLPR enqueue integrations.
 */
public final class ClprQueueOperations {

    private ClprQueueOperations() {
        throw new UnsupportedOperationException("Utility class");
    }

    /**
     * Appends one outbound payload into the queue for the given remote ledger and returns the assigned message id.
     *
     * @param queueStore writable queue metadata store
     * @param messageStore writable message store
     * @param remoteLedgerId destination remote ledger id
     * @param payload message payload (request or response variant)
     * @return assigned queue message id
     * @throws HandleException if input is invalid or queue metadata is unavailable
     */
    public static long enqueue(
            @NonNull final WritableClprMessageQueueMetadataStore queueStore,
            @NonNull final WritableClprMessageStore messageStore,
            @NonNull final ClprLedgerId remoteLedgerId,
            @NonNull final ClprMessagePayload payload)
            throws HandleException {
        requireNonNull(queueStore);
        requireNonNull(messageStore);
        requireNonNull(remoteLedgerId);
        requireNonNull(payload);

        validateTrue(remoteLedgerId.ledgerId() != Bytes.EMPTY, CLPR_INVALID_LEDGER_ID);
        validateTrue(payload.hasMessage() || payload.hasMessageReply(), INVALID_TRANSACTION_BODY);

        final var queueMetadata = queueStore.get(remoteLedgerId);
        validateTrue(queueMetadata != null, CLPR_MESSAGE_QUEUE_NOT_AVAILABLE);

        final var messageId = queueMetadata.nextMessageId();
        validateTrue(messageId >= 1, INVALID_TRANSACTION_BODY);

        final var previousHash = previousRunningHash(messageStore, queueMetadata);
        final var nextHash = nextRunningHash(payload, previousHash);
        final var messageKey =
                ClprMessageKey.newBuilder().ledgerId(remoteLedgerId).messageId(messageId).build();
        final var messageValue = ClprMessageValue.newBuilder()
                .payload(payload)
                .runningHashAfterProcessing(nextHash)
                .build();
        messageStore.put(messageKey, messageValue);

        final var updatedQueue = queueMetadata.copyBuilder().nextMessageId(messageId + 1).build();
        queueStore.put(remoteLedgerId, updatedQueue);

        return messageId;
    }

    private static Bytes previousRunningHash(
            @NonNull final WritableClprMessageStore messageStore, @NonNull final ClprMessageQueueMetadata queueMetadata) {
        final var previousMessageId = queueMetadata.nextMessageId() - 1;
        if (previousMessageId < 1) {
            return queueMetadata.sentRunningHash();
        }
        final var previousMessageKey = ClprMessageKey.newBuilder()
                .ledgerId(queueMetadata.ledgerIdOrThrow())
                .messageId(previousMessageId)
                .build();
        final var previousMessage = messageStore.get(previousMessageKey);
        return previousMessage == null ? queueMetadata.sentRunningHash() : previousMessage.runningHashAfterProcessing();
    }
}
