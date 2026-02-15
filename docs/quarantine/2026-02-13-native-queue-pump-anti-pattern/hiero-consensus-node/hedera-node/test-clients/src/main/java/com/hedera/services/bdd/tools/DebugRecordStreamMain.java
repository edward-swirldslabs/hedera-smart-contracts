// SPDX-License-Identifier: Apache-2.0
package com.hedera.services.bdd.tools;

import static com.hedera.node.app.hapi.utils.forensics.RecordParsers.parseV6RecordStreamEntriesIn;

import java.time.Instant;

/**
 * Debug tool: parse a record stream directory and print CLPR-oriented entries.
 */
public class DebugRecordStreamMain {
    public static void main(final String[] args) throws Exception {
        if (args.length < 1) {
            throw new IllegalArgumentException("Usage: DebugRecordStreamMain <record-stream-dir> [since-iso-instant]");
        }
        final var streamDir = args[0];
        final Instant since = (args.length >= 2) ? Instant.parse(args[1]) : Instant.EPOCH;

        final var entries = parseV6RecordStreamEntriesIn(streamDir);
        System.out.println("Parsed entries: " + entries.size());
        final var afterSince = entries.stream().filter(e -> !e.consensusTime().isBefore(since)).toList();
        System.out.println("Entries after cutoff: " + afterSince.size());
        afterSince.stream().limit(25).forEach(e -> System.out.printf(
                "TRACE %s | fn=%s | status=%s%n", e.consensusTime(), e.function(), e.finalStatus()));

        afterSince.stream()
                .filter(e -> e.function().name().contains("CLPR")
                        || e.finalStatus().name().contains("CLPR")
                        || e.function().name().contains("ContractCall")
                        || !"SUCCESS".equals(e.finalStatus().name()))
                .forEach(e -> {
                    final var record = e.transactionRecord();
                    final var txId = e.txnId();
                    final var parentTs = e.parentConsensusTimestamp();
                    final var callResult = record.hasContractCallResult() ? record.getContractCallResult() : null;
                    final var callResultLen = (callResult != null && callResult.getContractCallResult() != null)
                            ? callResult.getContractCallResult().size()
                            : 0;
                    final var err = (callResult != null) ? callResult.getErrorMessage() : "";
                    System.out.printf(
                            "%s | fn=%s | status=%s | txId=%s | parentTs=%s | callResultLen=%d | err='%s'%n",
                            e.consensusTime(),
                            e.function(),
                            e.finalStatus(),
                            txId,
                            parentTs,
                            callResultLen,
                            err);
                });

        System.out.println("Done");
    }
}
