# CLPR Running Hash Fix — Change Summary

## Date: 2026-02-21

## Problem

The 2-Solo E2E native messaging test consistently failed with:

```
Error: Timed out waiting for response delivery (appMsgId=4, last=2)
```

The source ledger could send messages to the destination and receive the first response, but all subsequent response bundles from the destination were rejected with `CLPR_INVALID_RUNNING_HASH`, preventing `receivedMessageId` from advancing beyond 1.

---

## Root Cause

**File:** `ClprMessageUtils.java:57` — off-by-one in `createBundle()` loop bound.

`createBundle()` assembles a message bundle for cross-ledger transport. The bundle protocol has two parts:
- `bundle.messages()` — a list of `ClprMessagePayload` objects for all messages **except** the last
- `bundle.stateProof()` — contains the last message's payload, running hash, and cryptographic proof

Both `pureChecks()` and `handle()` in `ClprProcessMessageBundleHandler` rely on this contract:
- `firstBundleMessageId = lastBundleMessageId - bundle.messages().size()` (assumes last msg not in list)
- `handle()` appends `lastBundleMessageValue.payload()` to the list before processing

**The bug:** `createBundle()` used `i <= lastMsgInBundle`, putting ALL messages (including the last) into `bundle.messages()`. This duplicated the last message and shifted every downstream calculation:

| Calculation | With Bug | Correct |
|---|---|---|
| `bundle.messages().size()` for bundle [1,2,3] | 3 | 2 |
| `firstBundleMessageId` (lastId=3) | 3 - 3 = 0 | 3 - 2 = 1 |
| `skipCount` (receivedId=1) | 2 - 0 = 2 | 2 - 1 = 1 |
| Hash chain | Skips too many, computes msg3 twice | Correct chain |

Single-message bundles worked by coincidence (skipCount compensated for the extra element), which is why the first message exchange always succeeded.

---

## Changes

### 1. Primary Fix — `ClprMessageUtils.java` (hiero-consensus-node)

**Path:** `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprMessageUtils.java`

```diff
-        for (long i = firstPendingMsgId; i <= lastMsgInBundle; i++) {
+        for (long i = firstPendingMsgId; i < lastMsgInBundle; i++) {
```

One-character fix. The last message is already carried in the state proof; it must not also appear in `bundle.messages()`.

### 2. Diagnostic Logging — `ClprEndpointClient.java` (hiero-consensus-node)

**Path:** `hedera-node/hiero-clpr-interledger-service-impl/src/main/java/org/hiero/interledger/clpr/impl/ClprEndpointClient.java`

Added a `diagLog` logger under the `com.hedera.clpr.diagnostic` namespace. All `org.hiero.*` loggers fall through to the root logger (`FATAL` level) in Solo-deployed nodes, making them invisible in `hgcaa.log`. By placing the diagnostic logger under `com.hedera.*`, it inherits the `INFO` + `RollingFile` configuration and writes to `hgcaa.log`.

This was essential for root-cause analysis — without it, the `CLPR_INVALID_RUNNING_HASH` rejection was invisible in logs.

### 3. Infrastructure Fixes (hedera-smart-contracts scripts)

#### `lib.sh` — Auto-detect kubectl context

```diff
-SOLO_CLUSTER_CONTEXT="${SOLO_CLUSTER_CONTEXT:-docker-desktop}"
+SOLO_CLUSTER_CONTEXT="${SOLO_CLUSTER_CONTEXT:-$(kubectl config current-context 2>/dev/null || echo docker-desktop)}"
```

The hardcoded `docker-desktop` default failed on `kind-solo` clusters.

#### `two-network-up.sh` — ClusterRole cleanup and context restore

- **Pre-deployment cleanup:** Deletes stale `mirror-ingress-controller` ClusterRole/ClusterRoleBinding before the first deployment. Solo's haproxy-ingress chart creates cluster-scoped resources annotated with a namespace. Stale resources from a previous run cause Helm ownership conflicts.
- **Context restore:** Added `kubectl config use-context` before health checks. Solo CLI operations can unset or change the kubectl context.

#### `two-network-status.sh` — Non-fatal block node check

Made the block node endpoint readiness check a warning instead of a fatal error. The block node is optional for CLPR messaging — it's used for block-stream observability only.

#### `run-e2e.sh` — Context restore

Added `kubectl config use-context` after network deployment and before evidence collection, since Solo CLI operations can unset the context.

---

## Verification

- 133 unit tests pass (`:hiero-clpr-interledger-service-impl:test`)
- E2E scenario passes all 5 phases: initial messages, connector failover, topoff, post-topoff messages, validations
- Zero `CLPR_INVALID_RUNNING_HASH` errors in diagnostic logs
- Evidence: `artifacts/clpr-native-messaging-solo/20260221T203757Z/`
