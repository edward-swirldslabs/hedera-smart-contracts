# Issue-0002 Evidence: Custom Solo Dual-Network Rehearsal

Date: 2026-02-12

## Environment

- Solo CLI: `0.55.0`
- Kubernetes context: `docker-desktop`
- Consensus artifacts path:
  - `../hiero-consensus-node/hedera-node/data`
- Deployments:
  - Source: `solo-clpr-native-src`
  - Destination: `solo-clpr-native-dst`

## Commands Executed

- Bring up from clean state:
  - `scripts/clpr/native-queue/solo-two-network-up.sh --force`
- Health validation:
  - `scripts/clpr/native-queue/solo-two-network-status.sh`

## Results

- Both namespaces reached runtime healthy state.
- For each namespace, checks passed for:
  - consensus pod running,
  - consensus JVM process active,
  - `haproxy-node1-svc` present,
  - `clpr.clprEnabled=true` found in `application.properties`.

## Artifacts

Run manifests captured:

- `artifacts/clpr-native-queue/issue-0002/20260212T043235Z/run-manifest.env`
- `artifacts/clpr-native-queue/issue-0002/20260212T043323Z/run-manifest.env`
- `artifacts/clpr-native-queue/issue-0002/20260212T044010Z/run-manifest.env`
- `artifacts/clpr-native-queue/issue-0002/20260212T044229Z/run-manifest.env`

## Known Solo Operational Quirks Observed

1. Node start may report:
   - stage: `set gRPC Web endpoint`
   - error: `INVALID_NODE_ID`

Observed behavior in this setup:

- Runtime node health can still be valid despite this error.
- `solo-two-network-up.sh` now treats this signature as non-blocking and proceeds to health checks.

2. `solo consensus node stop` control-plane/runtime drift in dev mode:

- Remote config phase can change (for example to `stopped`) while pod/JVM remains active.
- Restart validation should use both control-plane and runtime evidence, not runtime shutdown assumptions alone.

## Conclusion

Issue-0002 execution gate is satisfied for practical integration work:

- dual-network custom-build rehearsal is scripted and repeatable,
- health gates and artifacts are present,
- known Solo quirks are documented and handled explicitly.
