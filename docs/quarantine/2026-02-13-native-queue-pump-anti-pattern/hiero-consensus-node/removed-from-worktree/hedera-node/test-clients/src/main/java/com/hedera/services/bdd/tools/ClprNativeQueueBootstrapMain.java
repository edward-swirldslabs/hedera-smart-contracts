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
import org.hiero.hapi.interledger.state.clpr.ClprLedgerConfiguration;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageQueueMetadata;
import org.hiero.interledger.clpr.ClprStateProofUtils;
import org.hiero.interledger.clpr.client.ClprClient;
import org.hiero.interledger.clpr.impl.client.ClprClientImpl;

/**
 * Bootstraps two external CLPR-enabled ledgers for native-queue contract smoke tests.
 *
 * <p>This tool performs only CLPR control-plane setup:
 * <ol>
 *     <li>Fetch each ledger's local CLPR configuration proof.</li>
 *     <li>Submit each configuration to the opposite ledger.</li>
 *     <li>Wait for remote configuration visibility on both ledgers.</li>
 *     <li>Ensure queue metadata exists in both directions.</li>
 * </ol>
 */
public final class ClprNativeQueueBootstrapMain {
    private static final Duration DEFAULT_TIMEOUT = Duration.ofMinutes(2);
    private static final long POLL_MS = 1_000L;

    private ClprNativeQueueBootstrapMain() {
        throw new UnsupportedOperationException("Utility class");
    }

    public static void main(final String[] args) throws Exception {
        final var srcGrpc = env("CLPR_SRC_GRPC_URL", "127.0.0.1:50221");
        final var dstGrpc = env("CLPR_DST_GRPC_URL", "127.0.0.1:30212");
        final var srcOperatorId = env("CLPR_SRC_OPERATOR_ID", "0.0.2");
        final var dstOperatorId = env("CLPR_DST_OPERATOR_ID", "0.0.2");
        final var srcNodeAccountId = env("CLPR_SRC_NODE_ACCOUNT_ID", "0.0.3");
        final var dstNodeAccountId = env("CLPR_DST_NODE_ACCOUNT_ID", "0.0.3");
        final var timeout = Duration.ofSeconds(Long.parseLong(env("CLPR_BOOTSTRAP_TIMEOUT_SECONDS", "180")));

        log("CLPR_BOOTSTRAP_STAGE=connect");
        try (final var ignoredSrc = createClprClient(srcGrpc);
                final var ignoredDst = createClprClient(dstGrpc)) {}

        log("CLPR_BOOTSTRAP_STAGE=fetch-local-configs");
        final var srcProof = awaitLocalConfigurationProof(srcGrpc, timeout, "source local configuration");
        final var dstProof = awaitLocalConfigurationProof(dstGrpc, timeout, "destination local configuration");
        final var srcConfig = ClprStateProofUtils.extractConfiguration(srcProof);
        final var dstConfig = ClprStateProofUtils.extractConfiguration(dstProof);

        log("CLPR_BOOTSTRAP_SRC_LEDGER_ID_HEX="
                + hex(srcConfig.ledgerIdOrThrow().ledgerId().toByteArray()));
        log("CLPR_BOOTSTRAP_DST_LEDGER_ID_HEX="
                + hex(dstConfig.ledgerIdOrThrow().ledgerId().toByteArray()));

        try (final var srcClient = createClprClient(srcGrpc);
                final var dstClient = createClprClient(dstGrpc)) {
            log("CLPR_BOOTSTRAP_STAGE=submit-cross-config");
            submitConfiguration(
                    srcClient,
                    parseAccount(srcOperatorId),
                    parseAccount(srcNodeAccountId),
                    dstProof,
                    dstConfig.ledgerIdOrThrow(),
                    "source receives destination configuration");
            submitConfiguration(
                    dstClient,
                    parseAccount(dstOperatorId),
                    parseAccount(dstNodeAccountId),
                    srcProof,
                    srcConfig.ledgerIdOrThrow(),
                    "destination receives source configuration");

            log("CLPR_BOOTSTRAP_STAGE=await-remote-config");
            awaitRemoteConfiguration(srcClient, dstConfig.ledgerIdOrThrow(), timeout, "source sees destination config");
            awaitRemoteConfiguration(dstClient, srcConfig.ledgerIdOrThrow(), timeout, "destination sees source config");

            log("CLPR_BOOTSTRAP_STAGE=ensure-queue-metadata");
            ensureQueueMetadata(
                    srcClient,
                    parseAccount(srcOperatorId),
                    parseAccount(srcNodeAccountId),
                    dstConfig.ledgerIdOrThrow());
            ensureQueueMetadata(
                    dstClient,
                    parseAccount(dstOperatorId),
                    parseAccount(dstNodeAccountId),
                    srcConfig.ledgerIdOrThrow());

            log("CLPR_BOOTSTRAP_STAGE=complete");
            log("CLPR_BOOTSTRAP_RESULT=PASS");
        }
    }

    private static ClprClientImpl createClprClient(@NonNull final String grpcHostPort) throws Exception {
        final var endpoint = toServiceEndpoint(grpcHostPort);
        return new ClprClientImpl(endpoint);
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

    private static com.hedera.hapi.block.stream.StateProof awaitLocalConfigurationProof(
            @NonNull final String grpcHostPort, @NonNull final Duration timeout, @NonNull final String reason) {
        final var deadline = Instant.now().plus(timeout);
        Exception lastFailure = null;
        int attempts = 0;
        do {
            attempts++;
            try (final var client = createClprClient(grpcHostPort)) {
                final var result = client.getConfigurationResult();
                final var proof = result.proof();
                if (proof != null) {
                    return proof;
                }
                if (attempts == 1 || attempts % 10 == 0) {
                    log("CLPR_BOOTSTRAP_INFO=getConfiguration scope="
                            + reason
                            + " attempt="
                            + attempts
                            + " result=null status="
                            + result.status());
                }
            } catch (final Exception e) {
                // Helidon gRPC channels may transiently close streams during local port-forward churn.
                // Keep polling until timeout instead of failing on the first transport hiccup.
                lastFailure = e;
                log("CLPR_BOOTSTRAP_WARN=getConfiguration scope="
                        + reason
                        + " attempt="
                        + attempts
                        + " error="
                        + describeFailure(e));
            }
            sleepQuietly(POLL_MS);
        } while (Instant.now().isBefore(deadline));
        final var details = (lastFailure == null) ? "none" : describeFailure(lastFailure);
        final var message = "Timed out waiting for "
                + reason
                + " after "
                + timeout.toSeconds()
                + "s, attempts="
                + attempts
                + ", lastError="
                + details;
        if (lastFailure == null) {
            throw new IllegalStateException(message);
        }
        throw new IllegalStateException(message, lastFailure);
    }

    private static void awaitRemoteConfiguration(
            @NonNull final ClprClient client,
            @NonNull final ClprLedgerId remoteLedgerId,
            @NonNull final Duration timeout,
            @NonNull final String reason) {
        final var deadline = Instant.now().plus(timeout);
        RuntimeException lastFailure = null;
        int attempts = 0;
        do {
            attempts++;
            try {
                final var proof = client.getConfiguration(remoteLedgerId);
                if (proof != null) {
                    return;
                }
                if (attempts == 1 || attempts % 10 == 0) {
                    final var status = (client instanceof ClprClientImpl clprClient)
                            ? clprClient.getConfigurationResult(remoteLedgerId).status()
                            : ResponseCodeEnum.FAIL_INVALID;
                    log("CLPR_BOOTSTRAP_INFO=getConfiguration(remote) scope="
                            + reason
                            + " remoteLedgerId="
                            + hex(remoteLedgerId.ledgerId().toByteArray())
                            + " attempt="
                            + attempts
                            + " result=null status="
                            + status);
                }
            } catch (final RuntimeException e) {
                lastFailure = e;
                log("CLPR_BOOTSTRAP_WARN=getConfiguration(remote) scope="
                        + reason
                        + " remoteLedgerId="
                        + hex(remoteLedgerId.ledgerId().toByteArray())
                        + " attempt="
                        + attempts
                        + " error="
                        + describeFailure(e));
            }
            sleepQuietly(POLL_MS);
        } while (Instant.now().isBefore(deadline));
        final var details = (lastFailure == null) ? "none" : describeFailure(lastFailure);
        throw new IllegalStateException(
                "Timed out waiting for "
                        + reason
                        + " after "
                        + timeout.toSeconds()
                        + "s, attempts="
                        + attempts
                        + ", lastError="
                        + details,
                lastFailure);
    }

    private static void submitConfiguration(
            @NonNull final ClprClient client,
            @NonNull final AccountID payer,
            @NonNull final AccountID node,
            @NonNull final com.hedera.hapi.block.stream.StateProof proof,
            @NonNull final ClprLedgerId expectedLedgerId,
            @NonNull final String reason) {
        RuntimeException lastFailure = null;
        for (int attempt = 1; attempt <= 5; attempt++) {
            try {
                final var status = client.setConfiguration(payer, node, proof);
                if (status == ResponseCodeEnum.OK || status == ResponseCodeEnum.SUCCESS) {
                    return;
                }
                // Allow idempotent bootstrap: if the remote already has a configuration for this ledger id,
                // treat the submission as "already applied" instead of failing the run.
                try {
                    if (client.getConfiguration(expectedLedgerId) != null) {
                        log("CLPR_BOOTSTRAP_INFO=setConfiguration idempotent-accept ledgerId="
                                + hex(expectedLedgerId.ledgerId().toByteArray())
                                + " status="
                                + status);
                        return;
                    }
                } catch (final RuntimeException ignore) {
                    // Fall through and retry submission.
                }
                throw new IllegalStateException("Failed to " + reason + ", status=" + status);
            } catch (final RuntimeException e) {
                lastFailure = e;
                log("CLPR_BOOTSTRAP_WARN=transient setConfiguration failure attempt="
                        + attempt
                        + " error="
                        + describeFailure(e));
                sleepQuietly(POLL_MS);
            }
        }
        throw new IllegalStateException("Failed to " + reason, lastFailure);
    }

    private static com.hedera.hapi.block.stream.StateProof safeGetQueueMetadata(
            @NonNull final ClprClient client, @NonNull final ClprLedgerId remoteLedgerId) {
        try {
            return client.getMessageQueueMetadata(remoteLedgerId);
        } catch (final RuntimeException e) {
            log("CLPR_BOOTSTRAP_WARN=transient getMessageQueueMetadata failure: " + describeFailure(e));
            return null;
        }
    }

    private static void ensureQueueMetadata(
            @NonNull final ClprClient client,
            @NonNull final AccountID payer,
            @NonNull final AccountID node,
            @NonNull final ClprLedgerId remoteLedgerId) {
        final var existing = safeGetQueueMetadata(client, remoteLedgerId);
        if (existing != null) {
            return;
        }
        final var metadata = ClprMessageQueueMetadata.newBuilder()
                .ledgerId(remoteLedgerId)
                .nextMessageId(1L)
                .sentMessageId(0L)
                .receivedMessageId(0L)
                .build();
        final var proof = ClprStateProofUtils.buildLocalClprStateProofWrapper(metadata);
        RuntimeException lastFailure = null;
        for (int attempt = 1; attempt <= 5; attempt++) {
            try {
                final var status = client.updateMessageQueueMetadata(payer, node, remoteLedgerId, proof);
                if (status == ResponseCodeEnum.OK || status == ResponseCodeEnum.SUCCESS) {
                    return;
                }
                throw new IllegalStateException(
                        "Failed to initialize queue metadata for " + remoteLedgerId + ", status=" + status);
            } catch (final RuntimeException e) {
                lastFailure = e;
                log("CLPR_BOOTSTRAP_WARN=transient updateMessageQueueMetadata failure attempt="
                        + attempt
                        + " error="
                        + describeFailure(e));
                sleepQuietly(POLL_MS);
            }
        }
        throw new IllegalStateException("Failed to initialize queue metadata for " + remoteLedgerId, lastFailure);
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

    private static String hex(@NonNull final byte[] bytes) {
        final var out = new StringBuilder(bytes.length * 2);
        for (final var b : bytes) {
            out.append(Character.forDigit((b >> 4) & 0xF, 16));
            out.append(Character.forDigit(b & 0xF, 16));
        }
        return out.toString();
    }
}
