# ISSUE-0102: SOLO Two-Ledger Network Reachability

Status: Done (2026-02-14)

Notes:

- In SOLO, the advertised CLPR endpoints are in-cluster DNS names (for example `network-node1-svc.<ns>.svc.cluster.local:50211`).
- Required config for this environment:
  - `clpr.publicizeNetworkAddresses=true`
  - `nodes.gossipFqdnRestricted=false` (allow in-cluster DNS names)
- Health validation helper:
  - `scripts/clpr/native-messaging-solo/two-network-status.sh`

## Goal

Ensure each SOLO network can reach the other network’s CLPR gRPC endpoint(s) that are advertised in `ClprLedgerConfiguration`.

## Why This Matters

Even with correct in-node messaging logic, cross-ledger delivery fails if the advertised endpoints are not routable between the two SOLO deployments. This issue is strictly about networking reachability, not application/middleware semantics.

## Requirements (Must Be True)

- The “publicized” ledger advertises endpoints that the other ledger can dial.
- The non-publicized ledger can successfully create a gRPC connection to those endpoints from inside its cluster context.
- No external pump or bundle forwarder is used as a workaround.

## Constraints

- Prefer port-forwarding and config changes over code changes.
- If any code change is necessary, it must be minimal and justified as “endpoint advertisement correctness” rather than “adding new transport”.

## Tasks

- Identify which config flags must be set for endpoint advertisement in SOLO.
- Verify what address/port values appear in the advertised `ClprLedgerConfiguration`.
- Make the advertised endpoints reachable cross-ledger. Options to evaluate:
  - K8s `LoadBalancer` or `NodePort` exposure (if allowed in local environment).
  - Port-forwarding the gRPC gateway endpoints and ensuring the advertised ports match.
  - Any required DNS adjustments between namespaces (if applicable).
- Add a reproducible reachability probe:
  - Run from the destination ledger’s cluster context.
  - Fails fast with actionable output (DNS failure, connection refused, TLS mismatch, etc).

## Acceptance Criteria

- For two simultaneously-running SOLO deployments, a reachability probe confirms the destination can dial the source’s advertised endpoints.
- The probe output is recorded in an evidence note under this repo (location TBD by the implementer).
