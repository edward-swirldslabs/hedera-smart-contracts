// SPDX-License-Identifier: Apache-2.0
package com.hedera.services.bdd.suites.interledger;

import static com.hedera.node.app.hapi.utils.CommonPbjConverters.toPbj;
import static com.hedera.services.bdd.spec.HapiPropertySource.asAccount;
import static com.hedera.services.bdd.spec.queries.QueryVerbs.contractCallLocalWithFunctionAbi;
import static com.hedera.services.bdd.spec.transactions.TxnUtils.solidityIdFrom;
import static com.hedera.services.bdd.spec.utilops.CustomSpecAssert.allRunFor;
import static com.hedera.services.bdd.suites.contract.Utils.FunctionType.FUNCTION;
import static com.hedera.services.bdd.suites.contract.Utils.getABIFor;
import static java.util.Objects.requireNonNull;

import com.esaulpaugh.headlong.abi.Function;
import com.hedera.hapi.node.base.ResponseCodeEnum;
import com.hedera.services.bdd.junit.hedera.HederaNode;
import com.hedera.services.bdd.spec.HapiSpec;
import com.hederahashgraph.api.proto.java.AccountID;
import java.time.Duration;
import java.time.Instant;
import java.util.Arrays;
import java.util.EnumSet;
import java.util.List;
import java.util.concurrent.atomic.AtomicLong;
import java.util.function.LongPredicate;
import java.util.function.Predicate;
import java.util.function.Supplier;
import org.apache.logging.log4j.Logger;
import org.assertj.core.api.Assertions;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerConfiguration;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageBundle;
import org.hiero.hapi.interledger.state.clpr.ClprMessageQueueMetadata;
import org.hiero.interledger.clpr.ClprStateProofUtils;
import org.hiero.interledger.clpr.client.ClprClient;

final class ClprMiddlewareNativeQueueTestSupport {
    static final String HARNESS_CONTRACT = "ClprMiddlewareHarness";

    private static final Duration AWAIT_TIMEOUT = Duration.ofMinutes(2);
    private static final Duration AWAIT_POLL_INTERVAL = Duration.ofSeconds(1);
    private static final Duration SUBMIT_RETRY_TIMEOUT = Duration.ofSeconds(30);
    private static final Duration SUBMIT_RETRY_INTERVAL = Duration.ofMillis(250);
    private static final AtomicLong RESULT_COUNTER = new AtomicLong(0);
    private static final EnumSet<ResponseCodeEnum> TRANSIENT_SUBMIT_STATUSES = EnumSet.of(
            ResponseCodeEnum.PLATFORM_TRANSACTION_NOT_CREATED,
            ResponseCodeEnum.BUSY,
            ResponseCodeEnum.UNKNOWN);

    private ClprMiddlewareNativeQueueTestSupport() {
        throw new UnsupportedOperationException("Utility class");
    }

    static HederaNode firstNode(final HapiSpec spec) {
        return spec.getNetworkNodes().getFirst();
    }

    static String contractAddressHex(final HapiSpec spec, final String contractName) {
        return "0x" + solidityIdFrom(spec.registry().getContractId(contractName));
    }

    static void submitConfiguration(
            final HapiSpec spec, final HederaNode targetNode, final ClprLedgerConfiguration remoteConfiguration) {
        final var payer = toPbj(asAccount(spec, 2));
        final var proof = ClprStateProofUtils.buildLocalClprStateProofWrapper(requireNonNull(remoteConfiguration));
        try (final var client = ClprSuite.createClient(targetNode)) {
            final var status = submitWithRetry(
                    () -> client.setConfiguration(payer, targetNode.getAccountId(), proof),
                    "submit CLPR remote configuration");
            Assertions.assertThat(status).isEqualTo(ResponseCodeEnum.OK);
        }
    }

    static ClprLedgerConfiguration awaitLocalConfiguration(final HederaNode node) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            try (final var client = ClprSuite.createClient(node)) {
                final var proof = client.getConfiguration();
                if (proof != null) {
                    return ClprStateProofUtils.extractConfiguration(proof);
                }
            }
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException("Timed out waiting for local CLPR configuration");
    }

    static ClprLedgerConfiguration awaitRemoteConfiguration(final List<HederaNode> nodes, final ClprLedgerId remoteLedgerId) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            for (final var node : nodes) {
                try (final var client = ClprSuite.createClient(node)) {
                    final var proof = client.getConfiguration(remoteLedgerId);
                    if (proof != null) {
                        return ClprStateProofUtils.extractConfiguration(proof);
                    }
                }
            }
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException("Timed out waiting for remote CLPR configuration " + remoteLedgerId.ledgerId());
    }

    static ClprMessageQueueMetadata initializeQueueMetadata(
            final HapiSpec spec, final HederaNode node, final ClprLedgerId remoteLedgerId) {
        final var payer = toPbj(asAccount(spec, 2));
        final var initialQueue = ClprMessageQueueMetadata.newBuilder()
                .ledgerId(remoteLedgerId)
                .nextMessageId(1L)
                .sentMessageId(0L)
                .receivedMessageId(0L)
                .build();
        final var proof = ClprStateProofUtils.buildLocalClprStateProofWrapper(initialQueue);
        try (final var client = ClprSuite.createClient(node)) {
            final var status = submitWithRetry(
                    () -> client.updateMessageQueueMetadata(payer, node.getAccountId(), remoteLedgerId, proof),
                    "initialize CLPR queue metadata");
            Assertions.assertThat(status).isEqualTo(ResponseCodeEnum.OK);
            return awaitMessageQueueMetadata(
                    client,
                    remoteLedgerId,
                    metadata -> metadata.nextMessageId() == 1L
                            && metadata.sentMessageId() == 0L
                            && metadata.receivedMessageId() == 0L,
                    "initialize queue metadata");
        }
    }

    static ClprMessageQueueMetadata awaitMessageQueueMetadata(final ClprClient client, final ClprLedgerId remoteLedgerId) {
        return awaitMessageQueueMetadata(client, remoteLedgerId, metadata -> true, "be available");
    }

    static ClprMessageQueueMetadata awaitMessageQueueMetadata(
            final ClprClient client,
            final ClprLedgerId remoteLedgerId,
            final Predicate<ClprMessageQueueMetadata> predicate,
            final String reason) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            final var proof = client.getMessageQueueMetadata(remoteLedgerId);
            if (proof != null) {
                final var metadata = ClprStateProofUtils.extractMessageQueueMetadata(proof);
                if (predicate.test(metadata)) {
                    return metadata;
                }
            }
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException(
                "Timed out waiting for queue metadata for ledger " + remoteLedgerId.ledgerId() + " to " + reason);
    }

    static ClprMessageBundle awaitMessageBundle(final ClprClient client, final ClprLedgerId remoteLedgerId, final int maxNumMessages) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            final var bundle = client.getMessages(remoteLedgerId, maxNumMessages, 1024 * 1024);
            if (bundle != null) {
                return bundle;
            }
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException("Timed out waiting for message bundle for ledger " + remoteLedgerId.ledgerId());
    }

    static void awaitEmptyOutgoingQueue(
            final Logger log, final List<HederaNode> nodes, final ClprLedgerId remoteLedgerId) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            for (final var node : nodes) {
                try (final var client = ClprSuite.createClient(node)) {
                    final var bundle = client.getMessages(remoteLedgerId, 1000, 1024 * 1024);
                    if (bundle == null) {
                        return;
                    }
                    log.info("Queue for ledger {} not empty yet", remoteLedgerId.ledgerId());
                }
            }
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException("Timed out waiting for outgoing queue to be empty for ledger " + remoteLedgerId.ledgerId());
    }

    static void awaitUint64Getter(
            final Logger log,
            final HapiSpec spec,
            final String deployedContractName,
            final String getterName,
            final LongPredicate predicate,
            final String reason) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            final var value = readUint64Getter(spec, deployedContractName, getterName);
            if (predicate.test(value)) {
                return;
            }
            log.info("Waiting for {}.{}; current value={}", deployedContractName, getterName, value);
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException("Timed out waiting for " + deployedContractName + "." + getterName + " to " + reason);
    }

    static void awaitBytesGetter(
            final Logger log,
            final HapiSpec spec,
            final String deployedContractName,
            final String getterName,
            final Predicate<byte[]> predicate,
            final String reason) {
        final var deadline = Instant.now().plus(AWAIT_TIMEOUT);
        do {
            final var value = readBytesGetter(spec, deployedContractName, getterName);
            if (predicate.test(value)) {
                return;
            }
            log.info("Waiting for {}.{}; current length={}", deployedContractName, getterName, value.length);
            sleepQuietly(AWAIT_POLL_INTERVAL);
        } while (Instant.now().isBefore(deadline));
        throw new IllegalStateException("Timed out waiting for " + deployedContractName + "." + getterName + " to " + reason);
    }

    static long readUint64Getter(final HapiSpec spec, final String deployedContractName, final String getterName) {
        final var resultKey = deployedContractName + "_" + getterName + "_" + RESULT_COUNTER.incrementAndGet();
        allRunFor(
                spec,
                contractCallLocalWithFunctionAbi(
                                deployedContractName, getABIFor(FUNCTION, getterName, HARNESS_CONTRACT))
                        .saveResultTo(resultKey));
        final var raw = spec.registry().getBytes(resultKey);
        final var getter = Function.fromJson(getABIFor(FUNCTION, getterName, HARNESS_CONTRACT));
        final var decoded = getter.decodeReturn(raw);
        return ((Number) decoded.get(0)).longValue();
    }

    static byte[] readBytesGetter(final HapiSpec spec, final String deployedContractName, final String getterName) {
        final var resultKey = deployedContractName + "_" + getterName + "_" + RESULT_COUNTER.incrementAndGet();
        allRunFor(
                spec,
                contractCallLocalWithFunctionAbi(
                                deployedContractName, getABIFor(FUNCTION, getterName, HARNESS_CONTRACT))
                        .saveResultTo(resultKey));
        final var raw = spec.registry().getBytes(resultKey);
        final var getter = Function.fromJson(getABIFor(FUNCTION, getterName, HARNESS_CONTRACT));
        final var decoded = getter.decodeReturn(raw);
        return (byte[]) decoded.get(0);
    }

    static void assertBytesEquals(final byte[] actual, final byte[] expected, final String message) {
        Assertions.assertThat(Arrays.equals(actual, expected))
                .withFailMessage(message)
                .isTrue();
    }

    private static ResponseCodeEnum submitWithRetry(
            final Supplier<ResponseCodeEnum> submitAction, final String operationDescription) {
        final var deadline = Instant.now().plus(SUBMIT_RETRY_TIMEOUT);
        ResponseCodeEnum lastStatus = ResponseCodeEnum.UNKNOWN;
        do {
            lastStatus = submitAction.get();
            if (lastStatus == ResponseCodeEnum.OK || lastStatus == ResponseCodeEnum.SUCCESS) {
                return lastStatus;
            }
            if (!TRANSIENT_SUBMIT_STATUSES.contains(lastStatus)) {
                return lastStatus;
            }
            sleepQuietly(SUBMIT_RETRY_INTERVAL);
        } while (Instant.now().isBefore(deadline));

        throw new IllegalStateException(
                "Timed out waiting for transient status recovery while trying to " + operationDescription + "; last status="
                        + lastStatus);
    }

    private static void sleepQuietly(final Duration duration) {
        try {
            Thread.sleep(duration.toMillis());
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IllegalStateException("Interrupted while waiting for CLPR state", e);
        }
    }
}
