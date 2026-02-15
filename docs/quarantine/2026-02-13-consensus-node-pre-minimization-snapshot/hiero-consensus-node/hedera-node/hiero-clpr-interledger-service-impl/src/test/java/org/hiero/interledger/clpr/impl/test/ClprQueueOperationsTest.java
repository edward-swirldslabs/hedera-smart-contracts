// SPDX-License-Identifier: Apache-2.0
package org.hiero.interledger.clpr.impl.test;

import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_INVALID_LEDGER_ID;
import static com.hedera.hapi.node.base.ResponseCodeEnum.CLPR_MESSAGE_QUEUE_NOT_AVAILABLE;
import static com.hedera.hapi.node.base.ResponseCodeEnum.INVALID_TRANSACTION_BODY;
import static org.assertj.core.api.Assertions.assertThat;
import static org.assertj.core.api.Assertions.assertThatThrownBy;
import static org.hiero.interledger.clpr.impl.ClprMessageUtils.nextRunningHash;

import com.hedera.node.app.spi.workflows.HandleException;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessage;
import org.hiero.hapi.interledger.state.clpr.ClprMessageKey;
import org.hiero.hapi.interledger.state.clpr.ClprMessagePayload;
import org.hiero.hapi.interledger.state.clpr.ClprMessageQueueMetadata;
import org.hiero.hapi.interledger.state.clpr.ClprMessageReply;
import org.hiero.interledger.clpr.impl.ClprQueueOperations;
import org.hiero.interledger.clpr.impl.ClprServiceImpl;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

class ClprQueueOperationsTest extends ClprTestBase {
    private static final ClprLedgerId REMOTE_LEDGER_ID =
            ClprLedgerId.newBuilder().ledgerId(Bytes.wrap("remote-ledger".getBytes())).build();
    private static final Bytes ZERO_HASH = Bytes.wrap(new byte[ClprServiceImpl.RUNNING_HASH_SIZE]);

    @BeforeEach
    void setUp() {
        setupStates();
    }

    @Test
    void enqueueAssignsSequentialIdsAndStoresRunningHashes() {
        writableClprMessageQueueMetadataStore.put(REMOTE_LEDGER_ID, initialQueueMetadata(REMOTE_LEDGER_ID));

        final var requestPayload = ClprMessagePayload.newBuilder()
                .message(ClprMessage.newBuilder()
                        .messageData(Bytes.wrap("request".getBytes()))
                        .build())
                .build();
        final var responsePayload = ClprMessagePayload.newBuilder()
                .messageReply(ClprMessageReply.newBuilder()
                        .messageId(1L)
                        .messageReplyData(Bytes.wrap("reply".getBytes()))
                        .build())
                .build();

        final var requestId = ClprQueueOperations.enqueue(
                writableClprMessageQueueMetadataStore, writableClprMessageStore, REMOTE_LEDGER_ID, requestPayload);
        final var responseId = ClprQueueOperations.enqueue(
                writableClprMessageQueueMetadataStore, writableClprMessageStore, REMOTE_LEDGER_ID, responsePayload);

        assertThat(requestId).isEqualTo(1L);
        assertThat(responseId).isEqualTo(2L);

        final var requestKey = ClprMessageKey.newBuilder()
                .ledgerId(REMOTE_LEDGER_ID)
                .messageId(requestId)
                .build();
        final var responseKey = ClprMessageKey.newBuilder()
                .ledgerId(REMOTE_LEDGER_ID)
                .messageId(responseId)
                .build();
        final var storedRequest = writableClprMessageStore.get(requestKey);
        final var storedResponse = writableClprMessageStore.get(responseKey);

        final var requestHash = nextRunningHash(requestPayload, ZERO_HASH);
        final var responseHash = nextRunningHash(responsePayload, requestHash);
        assertThat(storedRequest.runningHashAfterProcessing()).isEqualTo(requestHash);
        assertThat(storedResponse.runningHashAfterProcessing()).isEqualTo(responseHash);

        final var updatedQueue = writableClprMessageQueueMetadataStore.get(REMOTE_LEDGER_ID);
        assertThat(updatedQueue.nextMessageId()).isEqualTo(3L);
        assertThat(updatedQueue.sentMessageId()).isZero();
        assertThat(updatedQueue.sentRunningHash()).isEqualTo(ZERO_HASH);
    }

    @Test
    void enqueueRejectsMissingQueueMetadata() {
        final var payload = ClprMessagePayload.newBuilder()
                .message(ClprMessage.newBuilder()
                        .messageData(Bytes.wrap("request".getBytes()))
                        .build())
                .build();

        assertThatThrownBy(() -> ClprQueueOperations.enqueue(
                        writableClprMessageQueueMetadataStore, writableClprMessageStore, REMOTE_LEDGER_ID, payload))
                .isInstanceOf(HandleException.class)
                .extracting("status")
                .isEqualTo(CLPR_MESSAGE_QUEUE_NOT_AVAILABLE);
    }

    @Test
    void enqueueRejectsEmptyLedgerId() {
        final var payload = ClprMessagePayload.newBuilder()
                .message(ClprMessage.newBuilder()
                        .messageData(Bytes.wrap("request".getBytes()))
                        .build())
                .build();
        final var invalidLedgerId = ClprLedgerId.DEFAULT;

        assertThatThrownBy(() -> ClprQueueOperations.enqueue(
                        writableClprMessageQueueMetadataStore, writableClprMessageStore, invalidLedgerId, payload))
                .isInstanceOf(HandleException.class)
                .extracting("status")
                .isEqualTo(CLPR_INVALID_LEDGER_ID);
    }

    @Test
    void enqueueRejectsPayloadWithoutVariant() {
        writableClprMessageQueueMetadataStore.put(REMOTE_LEDGER_ID, initialQueueMetadata(REMOTE_LEDGER_ID));

        assertThatThrownBy(() -> ClprQueueOperations.enqueue(
                        writableClprMessageQueueMetadataStore,
                        writableClprMessageStore,
                        REMOTE_LEDGER_ID,
                        ClprMessagePayload.DEFAULT))
                .isInstanceOf(HandleException.class)
                .extracting("status")
                .isEqualTo(INVALID_TRANSACTION_BODY);
    }

    private ClprMessageQueueMetadata initialQueueMetadata(final ClprLedgerId remoteLedgerId) {
        return ClprMessageQueueMetadata.newBuilder()
                .ledgerId(remoteLedgerId)
                .nextMessageId(1L)
                .sentMessageId(0L)
                .sentRunningHash(ZERO_HASH)
                .receivedMessageId(0L)
                .receivedRunningHash(ZERO_HASH)
                .build();
    }
}
