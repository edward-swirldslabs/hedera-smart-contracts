// SPDX-License-Identifier: Apache-2.0
package com.hedera.services.bdd.tools;

import com.hedera.hapi.node.base.AccountID;
import com.hedera.hapi.node.base.ResponseCodeEnum;
import com.hedera.hapi.node.base.ServiceEndpoint;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import edu.umd.cs.findbugs.annotations.NonNull;
import java.net.InetAddress;
import java.time.Duration;
import java.time.Instant;
import java.util.Objects;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageBundle;
import org.hiero.interledger.clpr.ClprStateProofUtils;
import org.hiero.interledger.clpr.client.ClprClient;
import org.hiero.interledger.clpr.impl.client.ClprClientImpl;

/**
 * Pumps a single request/response message bundle between two external CLPR-enabled ledgers.
 *
 * <p>This tool emulates the off-ledger connector behavior used in the {@code ClprMiddlewareTwoLedgerNativeQueueSuite}:
 * fetch outbound messages from one ledger via {@code getMessages()}, then submit them to the peer via
 * {@code clprProcessMessageBundle} transactions, repeating for the response direction.</p>
 *
 * <p>Required environment variables:
 * <ul>
 *   <li>{@code CLPR_SRC_GRPC_URL} and {@code CLPR_DST_GRPC_URL} (host:port)</li>
 *   <li>{@code CLPR_SRC_OPERATOR_ID} and {@code CLPR_DST_OPERATOR_ID} (payer accounts)</li>
 *   <li>{@code CLPR_SRC_NODE_ACCOUNT_ID} and {@code CLPR_DST_NODE_ACCOUNT_ID} (node accounts)</li>
 *   <li>{@code CLPR_SRC_LEDGER_ID_HEX} and {@code CLPR_DST_LEDGER_ID_HEX} (32-byte hex, without 0x)</li>
 * </ul>
 */
public final class ClprNativeQueuePumpMain {
    private static final Duration DEFAULT_TIMEOUT = Duration.ofMinutes(3);
    private static final long POLL_MS = 1_000L;
    private static final int DEFAULT_MAX_NUM_MESSAGES = 1000;
    private static final int DEFAULT_MAX_NUM_BYTES = 1024 * 1024;

    private ClprNativeQueuePumpMain() {
        throw new UnsupportedOperationException("Utility class");
    }

    public static void main(final String[] args) throws Exception {
        final var srcGrpc = env("CLPR_SRC_GRPC_URL", "127.0.0.1:50221");
        final var dstGrpc = env("CLPR_DST_GRPC_URL", "127.0.0.1:30212");
        final var srcOperatorId = env("CLPR_SRC_OPERATOR_ID", "0.0.2");
        final var dstOperatorId = env("CLPR_DST_OPERATOR_ID", "0.0.2");
        final var srcNodeAccountId = env("CLPR_SRC_NODE_ACCOUNT_ID", "0.0.3");
        final var dstNodeAccountId = env("CLPR_DST_NODE_ACCOUNT_ID", "0.0.3");
        final var srcLedgerIdHex = requireEnv("CLPR_SRC_LEDGER_ID_HEX");
        final var dstLedgerIdHex = requireEnv("CLPR_DST_LEDGER_ID_HEX");
        final var timeoutSeconds = Long.parseLong(env("CLPR_PUMP_TIMEOUT_SECONDS", Long.toString(DEFAULT_TIMEOUT.toSeconds())));
        final var timeout = Duration.ofSeconds(timeoutSeconds);
        final var maxNumMessages = Integer.parseInt(env("CLPR_PUMP_MAX_NUM_MESSAGES", Integer.toString(DEFAULT_MAX_NUM_MESSAGES)));
        final var maxNumBytes = Integer.parseInt(env("CLPR_PUMP_MAX_NUM_BYTES", Integer.toString(DEFAULT_MAX_NUM_BYTES)));

        final var srcLedgerId = parseLedgerIdHex(srcLedgerIdHex);
        final var dstLedgerId = parseLedgerIdHex(dstLedgerIdHex);

        log("CLPR_PUMP_STAGE=connect");
        try (final var ignoredSrc = createClprClient(srcGrpc); final var ignoredDst = createClprClient(dstGrpc)) {}

        try (final var srcClient = createClprClient(srcGrpc); final var dstClient = createClprClient(dstGrpc)) {
            final var srcPayer = parseAccount(srcOperatorId);
            final var dstPayer = parseAccount(dstOperatorId);
            final var srcNode = parseAccount(srcNodeAccountId);
            final var dstNode = parseAccount(dstNodeAccountId);

            logQueueMetadata("src-before", srcClient, dstLedgerId);
            logQueueMetadata("dst-before", dstClient, srcLedgerId);

            log("CLPR_PUMP_STAGE=await-request-bundle");
            final var requestBundle = awaitMessageBundle(
                    srcClient, dstLedgerId, timeout, maxNumMessages, maxNumBytes, "source outbound request bundle");
            final var normalizedRequestBundle = requestBundle.copyBuilder().ledgerId(srcLedgerId).build();

            log("CLPR_PUMP_STAGE=submit-request-bundle");
            final var requestSubmission = dstClient.submitProcessMessageBundleTxnDetailed(
                    dstPayer, dstNode, dstLedgerId, normalizedRequestBundle);
            log("CLPR_PUMP_DST_PROCESS_REQUEST_TX_ID=" + requestSubmission.transactionId());
            log("CLPR_PUMP_DST_PROCESS_REQUEST_PRECHECK=" + requestSubmission.precheckCode());
            assertOk(requestSubmission.precheckCode(), "destination process request bundle precheck");

            logQueueMetadata("dst-after-request", dstClient, srcLedgerId);

            log("CLPR_PUMP_STAGE=await-response-bundle");
            final var responseBundle = awaitMessageBundle(
                    dstClient, srcLedgerId, timeout, maxNumMessages, maxNumBytes, "destination outbound response bundle");
            final var normalizedResponseBundle = responseBundle.copyBuilder().ledgerId(dstLedgerId).build();

            log("CLPR_PUMP_STAGE=submit-response-bundle");
            final var responseSubmission = srcClient.submitProcessMessageBundleTxnDetailed(
                    srcPayer, srcNode, srcLedgerId, normalizedResponseBundle);
            log("CLPR_PUMP_SRC_PROCESS_RESPONSE_TX_ID=" + responseSubmission.transactionId());
            log("CLPR_PUMP_SRC_PROCESS_RESPONSE_PRECHECK=" + responseSubmission.precheckCode());
            assertOk(responseSubmission.precheckCode(), "source process response bundle precheck");

            logQueueMetadata("src-after-response", srcClient, dstLedgerId);

            log("CLPR_PUMP_STAGE=complete");
            log("CLPR_PUMP_RESULT=PASS");
        }
    }

    private static void assertOk(@NonNull final ResponseCodeEnum status, @NonNull final String reason) {
        if (status != ResponseCodeEnum.OK && status != ResponseCodeEnum.SUCCESS) {
            throw new IllegalStateException("Expected OK/SUCCESS for " + reason + ", got " + status);
        }
    }

    private static void logQueueMetadata(
            @NonNull final String label, @NonNull final ClprClient client, @NonNull final ClprLedgerId remoteLedgerId) {
        try {
            final var proof = client.getMessageQueueMetadata(remoteLedgerId);
            if (proof == null) {
                log("CLPR_PUMP_INFO=queueMetadata label=" + label + " remoteLedgerIdHex=" + hex(remoteLedgerId) + " result=null");
                return;
            }
            final var metadata = ClprStateProofUtils.extractMessageQueueMetadata(proof);
            log("CLPR_PUMP_INFO=queueMetadata label=" + label
                    + " remoteLedgerIdHex=" + hex(remoteLedgerId)
                    + " nextMessageId=" + metadata.nextMessageId()
                    + " sentMessageId=" + metadata.sentMessageId()
                    + " receivedMessageId=" + metadata.receivedMessageId());
        } catch (final RuntimeException e) {
            log("CLPR_PUMP_WARN=getMessageQueueMetadata label=" + label + " error=" + describeFailure(e));
        }
    }

    private static ClprMessageBundle awaitMessageBundle(
            @NonNull final ClprClient client,
            @NonNull final ClprLedgerId remoteLedgerId,
            @NonNull final Duration timeout,
            final int maxNumMessages,
            final int maxNumBytes,
            @NonNull final String reason) {
        final var deadline = Instant.now().plus(timeout);
        RuntimeException lastFailure = null;
        int attempts = 0;
        do {
            attempts++;
            try {
                final var bundle = client.getMessages(remoteLedgerId, maxNumMessages, maxNumBytes);
                if (bundle != null) {
                    return bundle;
                }
                if (attempts == 1 || attempts % 10 == 0) {
                    log("CLPR_PUMP_INFO=getMessages scope="
                            + reason
                            + " remoteLedgerIdHex="
                            + hex(remoteLedgerId)
                            + " attempt="
                            + attempts
                            + " result=null");
                }
            } catch (final RuntimeException e) {
                lastFailure = e;
                log("CLPR_PUMP_WARN=getMessages scope="
                        + reason
                        + " remoteLedgerIdHex="
                        + hex(remoteLedgerId)
                        + " attempt="
                        + attempts
                        + " error="
                        + describeFailure(e));
            }
            sleepQuietly(POLL_MS);
        } while (Instant.now().isBefore(deadline));
        final var details = (lastFailure == null) ? "none" : describeFailure(lastFailure);
        throw new IllegalStateException(
                "Timed out waiting for " + reason + " after " + timeout.toSeconds() + "s, attempts=" + attempts
                        + ", lastError=" + details,
                lastFailure);
    }

    private static ClprClientImpl createClprClient(@NonNull final String grpcHostPort) throws Exception {
        return new ClprClientImpl(toServiceEndpoint(grpcHostPort));
    }

    private static ServiceEndpoint toServiceEndpoint(@NonNull final String grpcHostPort) throws Exception {
        final var split = grpcHostPort.split(":");
        if (split.length != 2) {
            throw new IllegalArgumentException("Invalid host:port '" + grpcHostPort + "'");
        }
        final var host = split[0].trim();
        final var port = Integer.parseInt(split[1].trim());
        final byte[] ipv4 = InetAddress.getByName(host).getAddress();
        return ServiceEndpoint.newBuilder().ipAddressV4(Bytes.wrap(ipv4)).port(port).build();
    }

    private static ClprLedgerId parseLedgerIdHex(@NonNull final String raw) {
        final var normalized = raw.trim().toLowerCase().replaceFirst("^0x", "");
        final var bytes = Bytes.fromHex(normalized).toByteArray();
        if (bytes.length != 32) {
            throw new IllegalArgumentException("Ledger id must be 32 bytes, got " + bytes.length + " for '" + raw + "'");
        }
        return ClprLedgerId.newBuilder().ledgerId(Bytes.wrap(bytes)).build();
    }

    private static AccountID parseAccount(@NonNull final String literal) {
        final var split = literal.trim().split("\\.");
        if (split.length != 3) {
            throw new IllegalArgumentException("Account literal must be shard.realm.num, got: " + literal);
        }
        return AccountID.newBuilder()
                .shardNum(Long.parseLong(split[0]))
                .realmNum(Long.parseLong(split[1]))
                .accountNum(Long.parseLong(split[2]))
                .build();
    }

    private static String requireEnv(@NonNull final String key) {
        final var raw = System.getenv(key);
        if (raw == null || raw.isBlank()) {
            throw new IllegalArgumentException("Missing required environment variable: " + key);
        }
        return raw.trim();
    }

    private static String env(@NonNull final String key, @NonNull final String defaultValue) {
        final var raw = System.getenv(key);
        return (raw == null || raw.isBlank()) ? defaultValue : raw.trim();
    }

    private static void sleepQuietly(final long millis) {
        try {
            Thread.sleep(millis);
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting", e);
        }
    }

    private static void log(@NonNull final String message) {
        System.out.println(Objects.requireNonNull(message));
    }

    private static String describeFailure(@NonNull final Throwable failure) {
        final var root = rootCause(failure);
        final var rootMessage = sanitize(root.getMessage());
        final var rootSummary = root.getClass().getSimpleName() + (rootMessage.isBlank() ? "" : ": " + rootMessage);
        if (root == failure) {
            return rootSummary;
        }
        return failure.getClass().getSimpleName() + " -> " + rootSummary;
    }

    private static Throwable rootCause(@NonNull final Throwable failure) {
        var current = failure;
        while (current.getCause() != null && current.getCause() != current) {
            current = current.getCause();
        }
        return current;
    }

    private static String sanitize(final String message) {
        return message == null ? "" : message.replace('\n', ' ').replace('\r', ' ').trim();
    }

    private static String hex(@NonNull final ClprLedgerId ledgerId) {
        return hex(ledgerId.ledgerId().toByteArray());
    }

    private static String hex(@NonNull final byte[] bytes) {
        final var out = new StringBuilder(bytes.length * 2);
        for (final var b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xF, 16));
            out.append(Character.forDigit(b & 0xF, 16));
        }
        return out.toString();
    }
}

