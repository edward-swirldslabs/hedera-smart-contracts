// SPDX-License-Identifier: Apache-2.0
package com.hedera.services.bdd.suites.interledger;

import static com.hedera.node.app.hapi.utils.CommonPbjConverters.toPbj;
import static com.hedera.services.bdd.spec.HapiPropertySource.asAccount;
import static com.hedera.services.bdd.spec.HapiSpec.multiNetworkHapiTest;
import static com.hedera.services.bdd.spec.assertions.TransactionRecordAsserts.recordWith;
import static com.hedera.services.bdd.spec.queries.QueryVerbs.getTxnRecord;
import static com.hedera.services.bdd.spec.transactions.TxnVerbs.contractCallWithFunctionAbi;
import static com.hedera.services.bdd.spec.transactions.TxnVerbs.contractCreate;
import static com.hedera.services.bdd.spec.transactions.TxnVerbs.uploadInitCode;
import static com.hedera.services.bdd.spec.transactions.contract.HapiParserUtil.asHeadlongAddress;
import static com.hedera.services.bdd.spec.utilops.CustomSpecAssert.allRunFor;
import static com.hedera.services.bdd.spec.utilops.UtilVerbs.withOpContext;
import static com.hedera.services.bdd.suites.contract.Utils.FunctionType.FUNCTION;
import static com.hedera.services.bdd.suites.contract.Utils.getABIFor;
import static com.hederahashgraph.api.proto.java.ResponseCodeEnum.SUCCESS;
import static java.nio.charset.StandardCharsets.UTF_8;
import static org.assertj.core.api.Assertions.assertThat;

import com.esaulpaugh.headlong.abi.Address;
import com.esaulpaugh.headlong.abi.Tuple;
import com.esaulpaugh.headlong.abi.TupleType;
import com.hedera.hapi.node.base.ResponseCodeEnum;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import com.hedera.services.bdd.junit.ConfigOverride;
import com.hedera.services.bdd.junit.MultiNetworkHapiTest;
import com.hedera.services.bdd.junit.TestTags;
import com.hedera.services.bdd.junit.hedera.subprocess.SubProcessNetwork;
import java.util.concurrent.atomic.AtomicReference;
import java.util.concurrent.ThreadLocalRandom;
import java.util.stream.Stream;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerConfiguration;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageBundle;
import org.hiero.interledger.clpr.ClprStateProofUtils;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Tag;

@Tag(TestTags.MULTINETWORK)
public class ClprMiddlewareTwoLedgerNativeQueueSuite {
    private static final TupleType<Tuple> REQUEST_ENVELOPE_TYPE = TupleType.parse("(uint8,bytes32,address,address,bytes)");
    private static final String PRIVATE_LEDGER = "private";
    private static final String PUBLIC_LEDGER = "public";

    @MultiNetworkHapiTest(
            networks = {
                @MultiNetworkHapiTest.Network(
                        name = PRIVATE_LEDGER,
                        size = 1,
                        firstGrpcPort = 35400,
                        setupOverrides = {
                            @ConfigOverride(key = "clpr.clprEnabled", value = "true"),
                            @ConfigOverride(key = "clpr.devModeEnabled", value = "true"),
                            @ConfigOverride(key = "clpr.publicizeNetworkAddresses", value = "false"),
                            @ConfigOverride(key = "clpr.connectionFrequency", value = "200"),
                            @ConfigOverride(key = "contracts.systemContract.clprQueue.enabled", value = "true"),
                        }),
                @MultiNetworkHapiTest.Network(
                        name = PUBLIC_LEDGER,
                        size = 1,
                        firstGrpcPort = 36400,
                        setupOverrides = {
                            @ConfigOverride(key = "clpr.clprEnabled", value = "true"),
                            @ConfigOverride(key = "clpr.devModeEnabled", value = "true"),
                            @ConfigOverride(key = "clpr.publicizeNetworkAddresses", value = "true"),
                            @ConfigOverride(key = "clpr.connectionFrequency", value = "200"),
                            @ConfigOverride(key = "contracts.systemContract.clprQueue.enabled", value = "true"),
                        })
            })
    @DisplayName("Two-ledger native queue flow invokes destination and source middleware callbacks")
    Stream<DynamicTest> twoLedgerNativeQueueRoundTrip(final SubProcessNetwork privateNet, final SubProcessNetwork publicNet) {
        // Generate fresh synthetic IDs each run to avoid queue-state collisions across repeated executions.
        final var privateSyntheticLedgerId = syntheticLedgerId((byte) 0x31);
        final var publicSyntheticLedgerId = syntheticLedgerId((byte) 0x42);
        final var publicConfig = new AtomicReference<ClprLedgerConfiguration>();
        final var privateConfig = new AtomicReference<ClprLedgerConfiguration>();
        final var privateHarnessId = new AtomicReference<String>();
        final var publicHarnessId = new AtomicReference<String>();
        final var publicHarnessAddress = new AtomicReference<String>();
        final var requestBundle = new AtomicReference<ClprMessageBundle>();
        final var responseBundle = new AtomicReference<ClprMessageBundle>();
        final var payload = "native-queue-two-ledger".getBytes(UTF_8);

        final var builder = multiNetworkHapiTest(privateNet, publicNet)
                .onNetwork(PUBLIC_LEDGER, withOpContext((spec, opLog) -> {
                    allRunFor(
                            spec,
                            uploadInitCode(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT),
                            contractCreate(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT).gas(4_000_000L));
                    final var publicContractId =
                            spec.registry().getContractId(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT);
                    publicHarnessId.set(publicContractId.getShardNum()
                            + "."
                            + publicContractId.getRealmNum()
                            + "."
                            + publicContractId.getContractNum());
                    final var contractAccountId = spec.registry()
                            .getContractInfo(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT)
                            .getContractAccountID();
                    publicHarnessAddress.set(
                            contractAccountId.startsWith("0x") ? contractAccountId : "0x" + contractAccountId);
                    publicConfig.set(ClprMiddlewareNativeQueueTestSupport.awaitLocalConfiguration(
                            ClprMiddlewareNativeQueueTestSupport.firstNode(spec)));
                }))
                .onNetwork(PRIVATE_LEDGER, withOpContext((spec, opLog) -> {
                    allRunFor(
                            spec,
                            uploadInitCode(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT),
                            contractCreate(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT).gas(4_000_000L));
                    final var contractId = spec.registry().getContractId(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT);
                    privateHarnessId.set(
                            contractId.getShardNum() + "." + contractId.getRealmNum() + "." + contractId.getContractNum());
                    privateConfig.set(ClprMiddlewareNativeQueueTestSupport.awaitLocalConfiguration(
                            ClprMiddlewareNativeQueueTestSupport.firstNode(spec)));
                }))
                .onNetwork(PRIVATE_LEDGER, withOpContext((spec, opLog) -> {
                    final var node = ClprMiddlewareNativeQueueTestSupport.firstNode(spec);
                    ClprMiddlewareNativeQueueTestSupport.initializeQueueMetadata(
                            spec, node, privateSyntheticLedgerId);
                    ClprMiddlewareNativeQueueTestSupport.initializeQueueMetadata(
                            spec, node, publicSyntheticLedgerId);
                }))
                .onNetwork(PUBLIC_LEDGER, withOpContext((spec, opLog) -> {
                    final var node = ClprMiddlewareNativeQueueTestSupport.firstNode(spec);
                    ClprMiddlewareNativeQueueTestSupport.initializeQueueMetadata(
                            spec, node, privateSyntheticLedgerId);
                }))
                .onNetwork(PRIVATE_LEDGER, withOpContext((spec, opLog) -> {
                    allRunFor(
                            spec,
                            contractCallWithFunctionAbi(
                                            privateHarnessId.get(),
                                            getABIFor(
                                                    FUNCTION,
                                                    "sendMessage",
                                                    ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT),
                                            privateSyntheticLedgerId.ledgerId().toByteArray(),
                                            asHeadlongAddress(publicHarnessAddress.get()),
                                            payload)
                                    .gas(4_000_000L)
                                    .via("twoLedgerNativeQueueSend"));
                }))
                .onNetwork(PRIVATE_LEDGER, withOpContext((spec, opLog) -> {
                    try (final var client = ClprSuite.createClient(ClprMiddlewareNativeQueueTestSupport.firstNode(spec))) {
                        requestBundle.set(ClprMiddlewareNativeQueueTestSupport.awaitMessageBundle(
                                client, privateSyntheticLedgerId, 10));
                    }
                }))
                .onNetwork(PUBLIC_LEDGER, withOpContext((spec, opLog) -> {
                    final var normalizedRequestBundle =
                            requestBundle.get().copyBuilder().ledgerId(privateSyntheticLedgerId).build();
                    final var lastMessageValue = ClprStateProofUtils.extractMessageValue(
                            normalizedRequestBundle.stateProofOrThrow());
                    final var routeEnvelope = REQUEST_ENVELOPE_TYPE.decode(
                            lastMessageValue.payloadOrThrow().messageOrThrow().messageData().toByteArray());
                    final var routedDestinationMiddleware = ((Address) routeEnvelope.get(3)).toString().toLowerCase();
                    assertThat(routedDestinationMiddleware)
                            .as("request envelope destination middleware in outbound bundle")
                            .isEqualTo(publicHarnessAddress.get().toLowerCase());
                    try (final var client = ClprSuite.createClient(ClprMiddlewareNativeQueueTestSupport.firstNode(spec))) {
                        final var submission = client.submitProcessMessageBundleTxnDetailed(
                                toPbj(asAccount(spec, 2)),
                                ClprMiddlewareNativeQueueTestSupport.firstNode(spec).getAccountId(),
                                publicConfig.get().ledgerId(),
                                normalizedRequestBundle);
                        assertThat(submission.precheckCode())
                                .as("public request bundle processing precheck")
                                .isEqualTo(ResponseCodeEnum.OK);
                        allRunFor(
                                spec,
                                getTxnRecord(submission.transactionId())
                                        .assertingNothingAboutHashes()
                                        .hasPriority(recordWith().status(SUCCESS)));
                    }
                }))
                .onNetwork(PUBLIC_LEDGER, withOpContext((spec, opLog) -> {
                    try (final var client = ClprSuite.createClient(ClprMiddlewareNativeQueueTestSupport.firstNode(spec))) {
                        final var publicQueueAfterRequest = ClprMiddlewareNativeQueueTestSupport.awaitMessageQueueMetadata(
                                client,
                                privateSyntheticLedgerId,
                                metadata -> metadata.receivedMessageId() == 1L && metadata.nextMessageId() == 2L,
                                "process one request and enqueue one response");
                        assertThat(publicQueueAfterRequest.sentMessageId())
                                .as("public queue sent id should still be zero before peer acknowledgement")
                                .isZero();
                    }

                    ClprMiddlewareNativeQueueTestSupport.awaitUint64Getter(
                            opLog,
                            spec,
                            publicHarnessId.get(),
                            "lastInboundMessageId",
                            value -> value == 1L,
                            "record first inbound request callback");
                    final var publicInboundPayload = ClprMiddlewareNativeQueueTestSupport.readBytesGetter(
                            spec,
                            publicHarnessId.get(),
                            "lastInboundRequestData");
                    ClprMiddlewareNativeQueueTestSupport.assertBytesEquals(
                            publicInboundPayload,
                            payload,
                            "public harness must receive source payload via handleMessage callback");
                }))
                .onNetwork(PUBLIC_LEDGER, withOpContext((spec, opLog) -> {
                    try (final var client = ClprSuite.createClient(ClprMiddlewareNativeQueueTestSupport.firstNode(spec))) {
                        responseBundle.set(ClprMiddlewareNativeQueueTestSupport.awaitMessageBundle(
                                client, privateSyntheticLedgerId, 10));
                    }
                }))
                .onNetwork(PRIVATE_LEDGER, withOpContext((spec, opLog) -> {
                    final var normalizedResponseBundle =
                            responseBundle.get().copyBuilder().ledgerId(publicSyntheticLedgerId).build();
                    try (final var client = ClprSuite.createClient(ClprMiddlewareNativeQueueTestSupport.firstNode(spec))) {
                        final var submission = client.submitProcessMessageBundleTxnDetailed(
                                toPbj(asAccount(spec, 2)),
                                ClprMiddlewareNativeQueueTestSupport.firstNode(spec).getAccountId(),
                                privateConfig.get().ledgerId(),
                                normalizedResponseBundle);
                        assertThat(submission.precheckCode())
                                .as("private response bundle processing precheck")
                                .isEqualTo(ResponseCodeEnum.OK);
                        allRunFor(
                                spec,
                                getTxnRecord(submission.transactionId())
                                        .assertingNothingAboutHashes()
                                        .hasPriority(recordWith().status(SUCCESS)));
                    }
                }))
                .onNetwork(PRIVATE_LEDGER, withOpContext((spec, opLog) -> {
                    try (final var client = ClprSuite.createClient(ClprMiddlewareNativeQueueTestSupport.firstNode(spec))) {
                        final var privateQueueAfterResponse = ClprMiddlewareNativeQueueTestSupport.awaitMessageQueueMetadata(
                                client,
                                publicSyntheticLedgerId,
                                metadata -> metadata.receivedMessageId() == 1L && metadata.nextMessageId() == 1L,
                                "process one inbound response from public ledger");
                        assertThat(privateQueueAfterResponse.sentMessageId())
                                .as("private queue sent id should remain zero on public-ledger queue")
                                .isZero();
                    }

                    ClprMiddlewareNativeQueueTestSupport.awaitUint64Getter(
                            opLog,
                            spec,
                            privateHarnessId.get(),
                            "lastResponseOriginalMessageId",
                            value -> value == 1L,
                            "record first inbound response callback");
                    final var privateResponsePayload = ClprMiddlewareNativeQueueTestSupport.readBytesGetter(
                            spec,
                            privateHarnessId.get(),
                            "lastResponseData");
                    ClprMiddlewareNativeQueueTestSupport.assertBytesEquals(
                            privateResponsePayload,
                            payload,
                            "private harness must receive response payload via handleMessageResponse callback");
                }));

        return builder.asDynamicTests();
    }

    private static ClprLedgerId syntheticLedgerId(final byte prefix) {
        final var bytes = new byte[32];
        ThreadLocalRandom.current().nextBytes(bytes);
        bytes[0] = prefix;
        return ClprLedgerId.newBuilder().ledgerId(Bytes.wrap(bytes)).build();
    }
}
