# CLPR Running Hash Fix — Retrospective

## Date: 2026-02-21

## Time Spent: ~4 hours

## Why It Took 4 Hours

The one-character fix (`<=` to `<`) took under a minute to write. The remaining ~3 hours 59 minutes were consumed by three categories of work:

### 1. Making Logs Visible (~1.5 hours)

The single largest time sink. The `CLPR_INVALID_RUNNING_HASH` rejection happened inside `ClprProcessMessageBundleHandler.pureChecks()`, which runs in the consensus node JVM. But ALL `org.hiero.*` loggers were invisible in the deployed Solo nodes because:

- The `log4j2.xml` deployed by Solo has root logger at `FATAL`
- Only `com.hedera.*` loggers are configured at `INFO` with `RollingFile` (writes to `hgcaa.log`)
- `org.hiero.interledger.clpr.*` classes fall through to root → FATAL → invisible

Three approaches were tried:
1. **Modifying `log4j2.xml` directly** — Failed because Solo's `--local-build-path` only copies `data/` (JARs), not the parent `log4j2.xml`
2. **kubectl cp of `log4j2.xml` into pods** — Failed because Solo's `consensus node start` overwrites `log4j2.xml` during JVM startup
3. **Creating a `diagLog` under `com.hedera.clpr.diagnostic`** — Succeeded. This inherits the `com.hedera` logger config and writes to `hgcaa.log`

Each attempt required a full rebuild (~45s) + full E2E run (~8 minutes) to validate.

### 2. Infrastructure Flakiness (~1.5 hours)

After the code fix was applied, 6 consecutive E2E runs failed before the scenario could execute, due to four independent infrastructure issues:

| Issue | Runs Lost | Time |
|---|---|---|
| `SOLO_CLUSTER_CONTEXT` defaulting to `docker-desktop` instead of `kind-solo` | 2 | ~20 min |
| Stale `mirror-ingress-controller` ClusterRole causing Helm ownership conflict | 2 | ~20 min |
| Block node endpoint not ready treated as fatal health check failure | 2 | ~20 min |
| Solo CLI unsetting kubectl context during operations | 2 | ~20 min |

Each issue required: identify failure from logs → find root cause → apply fix → re-run (~8 min per run). The issues were layered — fixing one revealed the next.

### 3. Root Cause Analysis (~1 hour)

Once logs were visible, identifying the `CLPR_INVALID_RUNNING_HASH` error in the diagnostic traces, then reading and understanding the interaction between `createBundle()`, `pureChecks()`, and `handle()` across three files to pinpoint the off-by-one.

---

## Instructions to Make This Faster Next Time

### For the AI Agent

#### Before Starting: Understand the Logging Architecture (saves ~1.5 hours)

1. **Solo-deployed nodes use Docker image log4j2.xml, not the repo's.** Do not attempt to modify `hedera-node/log4j2.xml` or kubectl-cp it into pods. Solo overwrites it during `consensus node start`.

2. **`org.hiero.*` loggers are invisible in deployed nodes.** The deployed `log4j2.xml` only routes `com.hedera.*` to `RollingFile` (hgcaa.log). All `org.hiero.*` classes fall through to root logger at `FATAL`.

3. **To get diagnostic logging from `org.hiero.*` code, use a logger under `com.hedera.*` namespace:**
   ```java
   private static final Logger diagLog = LogManager.getLogger("com.hedera.clpr.diagnostic");
   ```
   This inherits the `com.hedera` logger's `INFO` + `RollingFile` configuration.

4. **Do not waste cycles on log4j config deployment.** Go straight to the `com.hedera.*` diagnostic logger approach.

#### Before Starting: Pre-flight the Infrastructure (saves ~1.5 hours)

1. **Always verify kubectl context before running E2E:**
   ```bash
   kubectl config current-context  # Must be kind-solo
   kubectl config use-context kind-solo  # Set if needed
   ```

2. **Always clean up stale cluster-scoped resources:**
   ```bash
   kubectl delete clusterrole mirror-ingress-controller 2>/dev/null || true
   kubectl delete clusterrolebinding mirror-ingress-controller 2>/dev/null || true
   ```

3. **Run with minimal services when debugging consensus-node code:**
   ```bash
   SOLO_ENABLE_BLOCK_NODE=false SOLO_ENABLE_MIRROR=false CLPR_ENABLE_BLOCK_STREAM_TAILER=false \
     bash scripts/clpr/native-messaging-solo/run-e2e.sh
   ```
   Block node and mirror are not needed for CLPR messaging tests. Disabling them avoids block-node readiness flakes and ClusterRole conflicts entirely.

4. **Solo CLI can unset the kubectl context.** If any kubectl command fails with "current-context is not set" or returns HTML instead of JSON, run `kubectl config use-context kind-solo`.

#### Analysis Strategy (saves ~30 min)

1. **Read the handler code FIRST.** When the error is `CLPR_INVALID_RUNNING_HASH`, go straight to `ClprProcessMessageBundleHandler.pureChecks()` and trace the hash chain computation. Then read `createBundle()` to check whether the bundle structure matches the handler's expectations.

2. **Check the unit test conventions.** The unit tests in `ClprProcessMessageBundleHandlerTest` construct bundles manually. Compare how they build `bundle.messages()` vs what `createBundle()` produces — mismatches between test conventions and real bundle assembly are a strong signal.

3. **The running hash chain is a sequential hash.** If validation fails, the mismatch is either:
   - Wrong starting hash (receivedRunningHash is stale)
   - Wrong skip count (off-by-one in bundle size calculation)
   - Wrong payload type (ClprMessagePayload vs raw Bytes)
   - Duplicate/missing message in the chain

#### E2E Run Optimization

- Each full E2E run takes ~8 minutes (deploy two Solo networks + scenario)
- Use `--no-build` if the consensus node JARs haven't changed
- Use `--no-redeploy` if the Solo networks are already running and healthy
- Combined: `--no-build --no-redeploy` reduces a re-run to ~2 minutes (just scenario)

### Estimated Time with These Instructions

| Phase | Original | Optimized |
|---|---|---|
| Diagnostic logging | 1.5 hours | 15 min (go straight to diagLog) |
| Infrastructure issues | 1.5 hours | 10 min (pre-flight + minimal services) |
| Root cause analysis | 1 hour | 30 min (read handler first, check test conventions) |
| Verification | 15 min | 10 min (--no-build --no-redeploy) |
| **Total** | **~4 hours** | **~1 hour** |
