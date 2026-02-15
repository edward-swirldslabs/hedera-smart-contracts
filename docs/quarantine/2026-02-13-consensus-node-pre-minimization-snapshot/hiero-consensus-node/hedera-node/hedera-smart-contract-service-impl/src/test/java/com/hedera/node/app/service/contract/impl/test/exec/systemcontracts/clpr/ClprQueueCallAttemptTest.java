// SPDX-License-Identifier: Apache-2.0
package com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.clpr;

import static com.hedera.node.app.service.contract.impl.exec.systemcontracts.ClprQueueSystemContract.CLPR_QUEUE_CONTRACT_ID;
import static com.hedera.node.app.service.contract.impl.test.TestHelpers.DEFAULT_CONFIG;
import static com.hedera.node.app.service.contract.impl.test.TestHelpers.OWNER_BESU_ADDRESS;
import static java.nio.charset.StandardCharsets.UTF_8;
import static org.assertj.core.api.Assertions.assertThat;

import com.hedera.node.app.service.contract.impl.exec.metrics.ContractMetrics;
import com.hedera.node.app.service.contract.impl.exec.systemcontracts.clpr.ClprQueueCallAttempt;
import com.hedera.node.app.service.contract.impl.exec.systemcontracts.clpr.enqueuemessage.ClprQueueEnqueueMessageTranslator;
import com.hedera.node.app.service.contract.impl.exec.systemcontracts.common.CallAttemptOptions;
import com.hedera.node.app.service.contract.impl.test.exec.systemcontracts.common.CallAttemptTestBase;
import org.apache.tuweni.bytes.Bytes;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;
import org.mockito.Mock;

class ClprQueueCallAttemptTest extends CallAttemptTestBase {
    @Mock
    private ContractMetrics contractMetrics;

    private ClprQueueEnqueueMessageTranslator enqueueMessageTranslator;

    @BeforeEach
    void setUp() {
        enqueueMessageTranslator = new ClprQueueEnqueueMessageTranslator(systemContractMethodRegistry, contractMetrics);
    }

    @Test
    void unknownSelectorRevertsWithUnsupportedReason() {
        final var attempt = attemptWithInput(Bytes.fromHexString("deadbeef"), false);
        final var call = attempt.asExecutableCall();
        assertThat(call.getSystemContractMethod()).isEqualTo(ClprQueueCallAttempt.UNSUPPORTED_SELECTOR_METHOD);
        final var result = call.execute(frame);
        assertThat(new String(result.fullResult().output().toArrayUnsafe(), UTF_8))
                .isEqualTo("CLPR_QUEUE_UNSUPPORTED_SELECTOR");
    }

    @Test
    void knownSelectorRoutesToTranslatorAndFlagsBadCalldata() {
        final var attempt = attemptWithInput(Bytes.fromHexString("8cfaaa60"), true);
        final var call = attempt.asExecutableCall();
        final var result = call.execute(frame);
        assertThat(new String(result.fullResult().output().toArrayUnsafe(), UTF_8)).isEqualTo("CLPR_QUEUE_BAD_CALLDATA");
    }

    private ClprQueueCallAttempt attemptWithInput(final Bytes input, final boolean includeTranslator) {
        return new ClprQueueCallAttempt(
                input,
                new CallAttemptOptions<>(
                        CLPR_QUEUE_CONTRACT_ID,
                        OWNER_BESU_ADDRESS,
                        OWNER_BESU_ADDRESS,
                        false,
                        mockEnhancement(),
                        DEFAULT_CONFIG,
                        addressIdConverter,
                        verificationStrategies,
                        gasCalculator,
                        includeTranslator ? java.util.List.of(enqueueMessageTranslator) : java.util.List.of(),
                        systemContractMethodRegistry,
                        false));
    }
}

