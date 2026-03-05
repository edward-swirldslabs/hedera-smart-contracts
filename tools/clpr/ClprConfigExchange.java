// SPDX-License-Identifier: Apache-2.0
/*
 * Minimal CLPR config exchange helper for SOLO two-ledger runs.
 *
 * Guardrails:
 * - This tool ONLY exchanges ledger configuration state proofs (the allowed "kick").
 * - It does not ship or "pump" message bundles.
 */
package tools.clpr;

import com.hedera.hapi.block.stream.StateProof;
import com.hedera.hapi.node.base.AccountID;
import com.hedera.hapi.node.base.QueryHeader;
import com.hedera.hapi.node.base.ResponseCodeEnum;
import com.hedera.hapi.node.base.ServiceEndpoint;
import com.hedera.hapi.node.base.Timestamp;
import com.hedera.hapi.node.transaction.Query;
import com.hedera.hapi.node.transaction.Response;
import com.hedera.pbj.runtime.io.buffer.Bytes;
import edu.umd.cs.findbugs.annotations.NonNull;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Objects;
import java.util.Optional;
import com.hedera.pbj.grpc.client.helidon.PbjGrpcClient;
import com.hedera.pbj.grpc.client.helidon.PbjGrpcClientConfig;
import com.hedera.pbj.runtime.grpc.ServiceInterface;
import io.helidon.common.tls.Tls;
import io.helidon.webclient.api.WebClient;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerConfiguration;
import org.hiero.hapi.interledger.state.clpr.ClprLedgerId;
import org.hiero.hapi.interledger.state.clpr.ClprMessageQueueMetadata;
import org.hiero.interledger.clpr.ClprStateProofUtils;
import org.hiero.interledger.clpr.client.ClprClient;
import org.hiero.interledger.clpr.impl.client.ClprClientImpl;
import org.hiero.hapi.interledger.clpr.ClprGetLedgerConfigurationQuery;
import org.hiero.hapi.interledger.clpr.ClprServiceInterface;

public final class ClprConfigExchange {
    private static final int DEFAULT_NODE_PORT = 50211;
    private static final String DEFAULT_PAYER = "0.0.2";
    private static final String DEFAULT_NODE = "0.0.3";
    private static final Duration DEFAULT_WAIT_FOR_QUEUES = Duration.ofSeconds(90);
    private static final Duration DEFAULT_POLL_INTERVAL = Duration.ofSeconds(1);

    private record Endpoint(String host, int port) {
        ServiceEndpoint asServiceEndpoint() {
            return ServiceEndpoint.newBuilder().domainName(host).port(port).build();
        }

        @Override
        public String toString() {
            return host + ":" + port;
        }
    }

    private record Ledger(String name, Endpoint endpoint, StateProof configProof, ClprLedgerConfiguration config) {
        ClprLedgerId ledgerId() {
            return config.ledgerIdOrThrow();
        }
    }

    private record QueryResult(ResponseCodeEnum precheck, StateProof proof) {}

    private static final Duration GRPC_TIMEOUT = Duration.ofSeconds(5);
    private static final PbjGrpcClientConfig QUERY_CLIENT_CONFIG = new PbjGrpcClientConfig(
            GRPC_TIMEOUT,
            Tls.builder().enabled(false).build(),
            Optional.empty(),
            ServiceInterface.RequestOptions.APPLICATION_GRPC_PROTO);

    private static final ServiceInterface.RequestOptions REQUEST_OPTIONS = new ServiceInterface.RequestOptions() {
        @Override
        public @NonNull Optional<String> authority() {
            return Optional.empty();
        }

        @Override
        public @NonNull String contentType() {
            return ServiceInterface.RequestOptions.APPLICATION_GRPC_PROTO;
        }
    };

    private static final class LedgerConfigQueryClient implements AutoCloseable {
        private final PbjGrpcClient pbjGrpcClient;
        private final ClprServiceInterface.ClprServiceClient clprServiceClient;

        LedgerConfigQueryClient(@NonNull final Endpoint endpoint) {
            final WebClient webClient = WebClient.builder()
                    .baseUri("http://" + endpoint.host() + ":" + endpoint.port())
                    .tls(Tls.builder().enabled(false).build())
                    .connectTimeout(GRPC_TIMEOUT)
                    .readTimeout(GRPC_TIMEOUT)
                    .build();
            pbjGrpcClient = new PbjGrpcClient(webClient, QUERY_CLIENT_CONFIG);
            clprServiceClient = new ClprServiceInterface.ClprServiceClient(pbjGrpcClient, REQUEST_OPTIONS);
        }

        QueryResult getLocalConfiguration() {
            final var queryBody = ClprGetLedgerConfigurationQuery.newBuilder()
                    .header(QueryHeader.newBuilder().build())
                    .build();
            final var queryTxn = Query.newBuilder().getClprLedgerConfiguration(queryBody).build();
            final Response response = clprServiceClient.getLedgerConfiguration(queryTxn);
            if (response.hasClprLedgerConfiguration()) {
                final var clpr = response.clprLedgerConfigurationOrThrow();
                final var header = clpr.header();
                final var code = header == null ? null : header.nodeTransactionPrecheckCode();
                return new QueryResult(code, clpr.ledgerConfigurationProof());
            }
            return new QueryResult(null, null);
        }

        @Override
        public void close() {
            try {
                pbjGrpcClient.close();
            } catch (final Exception e) {
                // Best effort; this is a dev-only helper tool.
            }
        }
    }

    public static void main(String[] args) throws Exception {
        final var options = Options.parse(args);
        final var aEndpoint = options.endpointA();
        final var bEndpoint = options.endpointB();
        final var payer = parseAccountId(options.payerAccountId());
        final var node = parseAccountId(options.nodeAccountId());
        final var outPath = options.outPath();

        final var lines = new ArrayList<String>();
        lines.add("# Generated by tools/clpr/ClprConfigExchange.java");
        lines.add("CLPR_EXCHANGE_A_ENDPOINT=" + aEndpoint);
        lines.add("CLPR_EXCHANGE_B_ENDPOINT=" + bEndpoint);
        lines.add("CLPR_EXCHANGE_PAYER=" + options.payerAccountId());
        lines.add("CLPR_EXCHANGE_NODE=" + options.nodeAccountId());

        try (final ClprClientImpl clientA = new ClprClientImpl(aEndpoint.asServiceEndpoint());
                final ClprClientImpl clientB = new ClprClientImpl(bEndpoint.asServiceEndpoint());
                final LedgerConfigQueryClient queryA = new LedgerConfigQueryClient(aEndpoint);
                final LedgerConfigQueryClient queryB = new LedgerConfigQueryClient(bEndpoint)) {
            final var ledgerA = fetchLocalLedger("A", aEndpoint, clientA, queryA, options.waitTimeout());
            final var ledgerB = fetchLocalLedger("B", bEndpoint, clientB, queryB, options.waitTimeout());

            printLedgerSummary(ledgerA);
            printLedgerSummary(ledgerB);

            lines.add("CLPR_A_LEDGER_ID_HEX=" + toHex32(ledgerA.ledgerId().ledgerId()));
            lines.add("CLPR_B_LEDGER_ID_HEX=" + toHex32(ledgerB.ledgerId().ledgerId()));

            final var aOnB = ensureConfigInstalled("A->B", clientB, payer, node, ledgerA);
            final var bOnA = ensureConfigInstalled("B->A", clientA, payer, node, ledgerB);
            lines.add("CLPR_EXCHANGE_A_ON_B_STATUS=" + aOnB.name());
            lines.add("CLPR_EXCHANGE_B_ON_A_STATUS=" + bOnA.name());

            if (options.waitForQueues()) {
                waitForQueueMetadata(clientA, clientB, ledgerA, ledgerB, options.waitTimeout());
                lines.add("CLPR_QUEUE_METADATA_READY=true");
            }
        }

        if (outPath != null) {
            Files.createDirectories(outPath.getParent());
            Files.writeString(outPath, String.join("\n", lines) + "\n");
            System.out.println("Wrote: " + outPath);
        } else {
            for (final var line : lines) {
                System.out.println(line);
            }
        }
    }

    private static Ledger fetchLocalLedger(
            @NonNull final String name,
            @NonNull final Endpoint endpoint,
            @NonNull final ClprClientImpl client,
            @NonNull final LedgerConfigQueryClient queryClient,
            @NonNull final Duration timeout) {
        final var deadline = System.nanoTime() + timeout.toNanos();
        ResponseCodeEnum lastCode = null;
        long lastPrintNs = 0L;
        while (System.nanoTime() < deadline) {
            final QueryResult result;
            try {
                result = queryClient.getLocalConfiguration();
            } catch (final RuntimeException e) {
                // Surface transient gRPC/client errors, but keep retrying until timeout.
                if (System.nanoTime() - lastPrintNs > Duration.ofSeconds(5).toNanos()) {
                    System.out.println("Ledger " + name + " getConfiguration exception: " + e);
                    lastPrintNs = System.nanoTime();
                }
                sleepNanos(DEFAULT_POLL_INTERVAL.toNanos());
                continue;
            }

            final var proof = result.proof();
            if (proof != null) {
                final var config = ClprStateProofUtils.extractConfiguration(proof);
                return new Ledger(name, endpoint, proof, config);
            }

            final var code = result.precheck();
            final long now = System.nanoTime();
            if (code != lastCode || now - lastPrintNs > Duration.ofSeconds(10).toNanos()) {
                System.out.println("Ledger " + name + " getConfiguration: precheck=" + code + " proof=<none>");
                lastCode = code;
                lastPrintNs = now;
            }
            sleepNanos(DEFAULT_POLL_INTERVAL.toNanos());
        }
        throw new IllegalStateException(
                "Ledger " + name + " returned no configuration proof before timeout (" + timeout.toSeconds() + "s)");
    }

    private static void printLedgerSummary(@NonNull final Ledger ledger) {
        final var ledgerIdHex = toHex32(ledger.ledgerId().ledgerId());
        System.out.println("Ledger " + ledger.name() + " ledgerId=" + ledgerIdHex);
        final var endpoints = ledger.config().endpoints();
        if (endpoints == null || endpoints.isEmpty()) {
            System.out.println("Ledger " + ledger.name() + " endpoints=<none>");
            return;
        }
        for (int i = 0; i < endpoints.size(); i++) {
            final var ep = endpoints.get(i);
            if (ep == null) {
                continue;
            }
            if (!ep.hasEndpoint()) {
                System.out.println("Ledger " + ledger.name() + " endpoint[" + i + "]=<hidden>");
                continue;
            }
            final var svc = ep.endpointOrThrow();
            final var host = svc.domainName() != null && !svc.domainName().isBlank()
                    ? svc.domainName()
                    : ipv4OrUnknown(svc.ipAddressV4());
            System.out.println("Ledger " + ledger.name() + " endpoint[" + i + "]=" + host + ":" + svc.port());
        }
    }

    private static ResponseCodeEnum ensureConfigInstalled(
            @NonNull final String label,
            @NonNull final ClprClient client,
            @NonNull final AccountID payer,
            @NonNull final AccountID node,
            @NonNull final Ledger remoteLedger) {
        final var ledgerId = remoteLedger.ledgerId();
        final var existingProof = client.getConfiguration(ledgerId);
        if (existingProof != null) {
            final var existingConfig = ClprStateProofUtils.extractConfiguration(existingProof);
            if (!isNewer(existingConfig, remoteLedger.config())) {
                System.out.println(label + ": receiver already has config (timestamp >= candidate); skipping set");
                return ResponseCodeEnum.SUCCESS;
            }
        }
        final var status = client.setConfiguration(payer, node, remoteLedger.configProof());
        System.out.println(label + ": setConfiguration status=" + status);
        return status;
    }

    private static void waitForQueueMetadata(
            @NonNull final ClprClient clientA,
            @NonNull final ClprClient clientB,
            @NonNull final Ledger ledgerA,
            @NonNull final Ledger ledgerB,
            @NonNull final Duration timeout) {
        final var deadline = System.nanoTime() + timeout.toNanos();
        final var pollNs = DEFAULT_POLL_INTERVAL.toNanos();

        final var aId = ledgerA.ledgerId();
        final var bId = ledgerB.ledgerId();

        while (System.nanoTime() < deadline) {
            final var qAForB = clientA.getMessageQueueMetadata(bId);
            final var qBForA = clientB.getMessageQueueMetadata(aId);
            if (qAForB != null && qBForA != null) {
                final var metaA = ClprStateProofUtils.extractMessageQueueMetadata(qAForB);
                final var metaB = ClprStateProofUtils.extractMessageQueueMetadata(qBForA);
                printQueueMeta("A queue for B", metaA);
                printQueueMeta("B queue for A", metaB);
                return;
            }
            sleepNanos(pollNs);
        }
        throw new IllegalStateException("Timed out waiting for message queue metadata to initialize on both ledgers ("
                + timeout.toSeconds() + "s)");
    }

    private static void printQueueMeta(@NonNull final String label, @NonNull final ClprMessageQueueMetadata meta) {
        System.out.println(label + ": next=" + meta.nextMessageId() + " sent=" + meta.sentMessageId() + " recv=" + meta.receivedMessageId());
    }

    private static void sleepNanos(final long nanos) {
        try {
            Thread.sleep(Math.max(0L, nanos / 1_000_000L));
        } catch (final InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static boolean isNewer(
            @NonNull final ClprLedgerConfiguration existingConfig, @NonNull final ClprLedgerConfiguration candidate) {
        final var existingTs = existingConfig.timestampOrElse(Timestamp.DEFAULT);
        final var candidateTs = candidate.timestampOrElse(Timestamp.DEFAULT);
        return candidateTs.seconds() > existingTs.seconds()
                || (candidateTs.seconds() == existingTs.seconds() && candidateTs.nanos() > existingTs.nanos());
    }

    private static AccountID parseAccountId(@NonNull final String accountId) {
        final var parts = accountId.trim().split("\\.");
        if (parts.length != 3) {
            throw new IllegalArgumentException("Invalid account id: " + accountId);
        }
        return AccountID.newBuilder()
                .shardNum(Long.parseLong(parts[0]))
                .realmNum(Long.parseLong(parts[1]))
                .accountNum(Long.parseLong(parts[2]))
                .build();
    }

    private static String ipv4OrUnknown(final Bytes ipv4) {
        if (ipv4 == null || ipv4.length() != 4) {
            return "<unknown-ipv4>";
        }
        final var b = ipv4.toByteArray();
        return (b[0] & 0xff) + "." + (b[1] & 0xff) + "." + (b[2] & 0xff) + "." + (b[3] & 0xff);
    }

    private static String toHex32(@NonNull final Bytes bytes) {
        Objects.requireNonNull(bytes);
        final byte[] raw = bytes.toByteArray();
        final StringBuilder sb = new StringBuilder(2 + raw.length * 2);
        sb.append("0x");
        for (final byte b : raw) {
            sb.append(String.format(Locale.ROOT, "%02x", b));
        }
        return sb.toString();
    }

    private record Options(
            Endpoint endpointA,
            Endpoint endpointB,
            String payerAccountId,
            String nodeAccountId,
            boolean waitForQueues,
            Duration waitTimeout,
            Path outPath) {
        static Options parse(final String[] args) {
            Endpoint a = null;
            Endpoint b = null;
            String payer = DEFAULT_PAYER;
            String node = DEFAULT_NODE;
            boolean wait = true;
            Duration waitTimeout = DEFAULT_WAIT_FOR_QUEUES;
            Path out = null;

            for (int i = 0; i < args.length; i++) {
                final var arg = args[i];
                switch (arg) {
                    case "--a":
                        a = parseEndpoint(requireArg(args, ++i, "--a"));
                        break;
                    case "--b":
                        b = parseEndpoint(requireArg(args, ++i, "--b"));
                        break;
                    case "--payer":
                        payer = requireArg(args, ++i, "--payer");
                        break;
                    case "--node":
                        node = requireArg(args, ++i, "--node");
                        break;
                    case "--no-wait-for-queues":
                        wait = false;
                        break;
                    case "--wait-timeout-seconds":
                        waitTimeout = Duration.ofSeconds(Long.parseLong(requireArg(args, ++i, "--wait-timeout-seconds")));
                        break;
                    case "--out":
                        out = Path.of(requireArg(args, ++i, "--out"));
                        break;
                    case "-h":
                    case "--help":
                        usageAndExit(0);
                        break;
                    default:
                        throw new IllegalArgumentException("Unknown arg: " + arg);
                }
            }

            if (a == null || b == null) {
                usageAndExit(2);
            }
            return new Options(a, b, payer, node, wait, waitTimeout, out);
        }

        private static String requireArg(final String[] args, final int idx, final String flag) {
            if (idx >= args.length) {
                throw new IllegalArgumentException("Missing value for " + flag);
            }
            return args[idx];
        }

        private static Endpoint parseEndpoint(@NonNull final String value) {
            final var trimmed = value.trim();
            final int colon = trimmed.lastIndexOf(':');
            if (colon <= 0) {
                return new Endpoint(trimmed, DEFAULT_NODE_PORT);
            }
            final var host = trimmed.substring(0, colon);
            final var port = Integer.parseInt(trimmed.substring(colon + 1));
            return new Endpoint(host, port);
        }

        private static void usageAndExit(final int code) {
            System.err.println("Usage: java tools.clpr.ClprConfigExchange --a host:port --b host:port [options]");
            System.err.println("Options:");
            System.err.println("  --payer 0.0.2              Payer account id (default: " + DEFAULT_PAYER + ")");
            System.err.println("  --node 0.0.3               Node account id (default: " + DEFAULT_NODE + ")");
            System.err.println("  --no-wait-for-queues       Do not wait for message queue metadata initialization");
            System.err.println("  --wait-timeout-seconds N   Queue init wait timeout (default: " + DEFAULT_WAIT_FOR_QUEUES.toSeconds() + ")");
            System.err.println("  --out /path/to/file.env    Write key=value output to file instead of stdout");
            System.exit(code);
        }
    }
}
