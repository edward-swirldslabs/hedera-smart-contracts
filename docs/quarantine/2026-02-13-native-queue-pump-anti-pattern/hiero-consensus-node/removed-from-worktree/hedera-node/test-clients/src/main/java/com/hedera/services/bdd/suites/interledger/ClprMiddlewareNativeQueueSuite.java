// SPDX-License-Identifier: Apache-2.0
package com.hedera.services.bdd.suites.interledger;

import static com.hedera.node.app.hapi.utils.CommonPbjConverters.toPbj;
import static com.hedera.services.bdd.spec.HapiPropertySource.asAccount;
import static com.hedera.services.bdd.spec.HapiSpec.multiNetworkHapiTest;
import static com.hedera.services.bdd.spec.transactions.TxnVerbs.contractCallWithFunctionAbi;
import static com.hedera.services.bdd.spec.transactions.TxnVerbs.contractCreate;
import static com.hedera.services.bdd.spec.transactions.TxnVerbs.uploadInitCode;
import static com.hedera.services.bdd.spec.transactions.contract.HapiParserUtil.asHeadlongAddress;
import static com.hedera.services.bdd.spec.utilops.CustomSpecAssert.allRunFor;
import static com.hedera.services.bdd.spec.utilops.UtilVerbs.withOpContext;
import static com.hedera.services.bdd.suites.contract.Utils.FunctionType.FUNCTION;
import static com.hedera.services.bdd.suites.contract.Utils.getABIFor;
import static java.nio.charset.StandardCharsets.UTF_8;
import static org.assertj.core.api.Assertions.assertThat;

import com.hedera.hapi.node.base.ResponseCodeEnum;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import com.hedera.services.bdd.junit.ConfigOverride;
import com.hedera.services.bdd.junit.MultiNetworkHapiTest;
import com.hedera.services.bdd.junit.TestTags;
import com.hedera.services.bdd.junit.hedera.HederaNode;
import com.hedera.services.bdd.junit.hedera.subprocess.SubProcessNetwork;
import java.util.concurrent.atomic.AtomicReference;
import java.util.stream.Stream;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerConfiguration;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageBundle;
import org.hiero.hapi.interledger.state.clpr.ClprMessageQueueMetadata;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.DynamicTest;
import org.junit.jupiter.api.Tag;

@Tag(TestTags.CLPR)
public class ClprMiddlewareNativeQueueSuite {
    private static final String SINGLE_LEDGER = "single";
    private static final byte[] SINGLE_LEDGER_REMOTE_ID = new byte[] {
        0x41, 0x11, 0x23, 0x51, 0x41, 0x11, 0x23, 0x51,
        0x41, 0x11, 0x23, 0x51, 0x41, 0x11, 0x23, 0x51,
        0x41, 0x11, 0x23, 0x51, 0x41, 0x11, 0x23, 0x51,
        0x41, 0x11, 0x23, 0x51, 0x41, 0x11, 0x23, 0x51
    };

    @MultiNetworkHapiTest(
            networks = {
                @MultiNetworkHapiTest.Network(
                        name = SINGLE_LEDGER,
                        size = 1,
                        firstGrpcPort = 36400,
                        setupOverrides = {
                            @ConfigOverride(key = "clpr.clprEnabled", value = "true"),
                            @ConfigOverride(key = "clpr.devModeEnabled", value = "true"),
                            @ConfigOverride(key = "clpr.publicizeNetworkAddresses", value = "false"),
                            @ConfigOverride(key = "clpr.connectionFrequency", value = "200"),
                            @ConfigOverride(key = "contracts.systemContract.clprQueue.enabled", value = "true"),
                        })
            })
    @DisplayName("Native queue callback failure preserves metadata in single-network flow")
    final Stream<DynamicTest> callbackFailurePreservesQueueMetadata(final SubProcessNetwork singleNet) {
        final var targetNode = new AtomicReference<HederaNode>();
        final var remoteLedgerId = new AtomicReference<ClprLedgerId>();
        final var remoteConfiguration = new AtomicReference<ClprLedgerConfiguration>();
        final var queuedBundle = new AtomicReference<ClprMessageBundle>();
        final var queueBeforeFailure = new AtomicReference<ClprMessageQueueMetadata>();
        final var payload = "native-queue-failure-path".getBytes(UTF_8);

        final var builder = multiNetworkHapiTest(singleNet).onNetwork(SINGLE_LEDGER, withOpContext((spec, opLog) -> {
                    targetNode.set(ClprMiddlewareNativeQueueTestSupport.firstNode(spec));
                    remoteLedgerId.set(ClprLedgerId.newBuilder().ledgerId(Bytes.wrap(SINGLE_LEDGER_REMOTE_ID)).build());
                    final var bootstrapConfig =
                            ClprMiddlewareNativeQueueTestSupport.awaitLocalConfiguration(targetNode.get());
                    remoteConfiguration.set(ClprLedgerConfiguration.newBuilder()
                            .ledgerId(remoteLedgerId.get())
                            .timestamp(bootstrapConfig.timestampOrThrow())
                            .endpoints(bootstrapConfig.endpoints())
                            .build());
                    ClprMiddlewareNativeQueueTestSupport.submitConfiguration(
                            spec, targetNode.get(), remoteConfiguration.get());
                    ClprMiddlewareNativeQueueTestSupport.awaitRemoteConfiguration(
                            spec.getNetworkNodes(), remoteLedgerId.get());

                    allRunFor(
                            spec,
                            uploadInitCode(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT),
                            contractCreate(ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT).gas(4_000_000L));

                    ClprMiddlewareNativeQueueTestSupport.initializeQueueMetadata(
                            spec, targetNode.get(), remoteLedgerId.get());

                    final var selfAddress = ClprMiddlewareNativeQueueTestSupport.contractAddressHex(
                            spec, ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT);
                    allRunFor(
                            spec,
                            contractCallWithFunctionAbi(
                                            ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT,
                                            getABIFor(
                                                    FUNCTION,
                                                    "sendMessage",
                                                    ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT),
                                            remoteLedgerId.get().ledgerId().toByteArray(),
                                            asHeadlongAddress(selfAddress),
                                            payload)
                                    .gas(4_000_000L)
                                    .hasKnownStatusFrom(
                                            com.hederahashgraph.api.proto.java.ResponseCodeEnum.SUCCESS,
                                            com.hederahashgraph.api.proto.java.ResponseCodeEnum.UNKNOWN)
                                    .via("singleLedgerNativeQueueSend"));

                    try (final var client = ClprSuite.createClient(targetNode.get())) {
                        queueBeforeFailure.set(ClprMiddlewareNativeQueueTestSupport.awaitMessageQueueMetadata(
                                client,
                                remoteLedgerId.get(),
                                metadata -> metadata.nextMessageId() == 2L,
                                "increment nextMessageId after send"));
                        queuedBundle.set(ClprMiddlewareNativeQueueTestSupport.awaitMessageBundle(
                                client, remoteLedgerId.get(), 10));
                    }
                    assertThat(queueBeforeFailure.get().nextMessageId())
                            .as("sending via native queue should increment nextMessageId")
                            .isEqualTo(2L);

                    allRunFor(
                            spec,
                            contractCallWithFunctionAbi(
                                            ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT,
                                            getABIFor(
                                                    FUNCTION,
                                                    "setFailHandleMessage",
                                                    ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT),
                                            true)
                                    .gas(1_000_000L)
                                    .via("forceCallbackFailure"));

                    try (final var client = ClprSuite.createClient(targetNode.get())) {
                        final var localConfig = ClprMiddlewareNativeQueueTestSupport.awaitLocalConfiguration(targetNode.get());
                        // Single-ledger harness mode: normalize the bundle ledger ID to the synthetic remote id
                        // whose queue metadata we initialized for this scenario.
                        final var normalizedBundle =
                                queuedBundle.get().copyBuilder().ledgerId(remoteLedgerId.get()).build();
                        final var status = client.submitProcessMessageBundleTxn(
                                toPbj(asAccount(spec, 2)),
                                targetNode.get().getAccountId(),
                                localConfig.ledgerId(),
                                normalizedBundle);
                        assertThat(status)
                                .as("processMessageBundle precheck should still be accepted")
                                .isEqualTo(ResponseCodeEnum.OK);

                        final var queueAfterFailure =
                                ClprMiddlewareNativeQueueTestSupport.awaitMessageQueueMetadata(client, remoteLedgerId.get());
                        assertThat(queueAfterFailure)
                                .as("failed callback must not mutate queue metadata")
                                .isEqualTo(queueBeforeFailure.get());
                    }

                    assertThat(ClprMiddlewareNativeQueueTestSupport.readUint64Getter(
                                    spec,
                                    ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT,
                                    "lastInboundMessageId"))
                            .as("failed callback must not update inbound message id in harness")
                            .isZero();
                    assertThat(ClprMiddlewareNativeQueueTestSupport.readBytesGetter(
                                    spec,
                                    ClprMiddlewareNativeQueueTestSupport.HARNESS_CONTRACT,
                                    "lastInboundRequestData"))
                            .as("failed callback must not update inbound request payload in harness")
                            .isEmpty();
                }));
        return builder.asDynamicTests();
    }
}
