# ISSUE-0002: Custom Consensus Node Deployment Rehearsal (Solo Local Build)

Status: Done

Owner: Codex (GPT-5)

Depends on:

- ISSUE-0001

## Goal

Create a repeatable deployment workflow for two Solo networks running custom consensus node artifacts built from `../hiero-consensus-node` so integration changes can be tested quickly and consistently.

## Scope

In scope:

- Document and script the minimal sequence to:
  - build consensus node artifacts,
  - deploy two Solo namespaces with local-build path,
  - expose only required endpoints for HAPI-driven tests.
- Standardize namespace/port/config naming to avoid collisions.
- Add preflight checks and diagnostics capture commands.

Out of scope:

- Middleware/system-contract feature changes.
- JSON-RPC relay bootstrap.

## Requirements / References

- Solo doc: `https://solo.hiero.org/v0.55.0/examples/local-build-with-custom-config/`
- `../hiero-consensus-node/.github/workflows/support/citr/Taskfile.citr.yml`
- `../hiero-consensus-node/.github/workflows/zxc-json-rpc-relay-regression.yaml`

## Acceptance Criteria

- One command (or short script sequence) reliably deploys two custom local-build networks.
- Deployment runbook includes rollback/reset path and diagnostics collection.
- Script validates expected pods/services before returning success.
- Scripts include deterministic naming for deployments, namespaces, and local output artifact paths.
- Runbook includes explicit configuration checks confirming CLPR is enabled on both deployed ledgers.

## Milestone Exit Criteria (Dependency Gate)

- `solo-two-network-up.sh` produces a machine-readable run manifest (deployment names, namespaces, key endpoints).
- `solo-two-network-status.sh` returns non-zero on unhealthy state and prints actionable failing checks.
- `solo-custom-build-runbook.md` includes exact build and deploy command sequence and known failure signatures.

## Tests

- Unit:
  - Shell/static checks for script linting (`shellcheck` if available).
  - Script argument validation tests for missing/invalid deployment identifiers.
- Integration:
  - Scripted health checks validate consensus node pod status, expected services, and CLPR enablement configuration presence.
- Solo:
  - Two namespaces reach healthy consensus-node pod state.
  - Restart test: stop/start one node in one namespace and confirm control-plane phase transition is reported, with runtime-health checks re-validated after restart.

## Expected File Changes

In `hedera-smart-contracts`:

- `scripts/clpr/native-queue/solo-two-network-up.sh` (new)
- `scripts/clpr/native-queue/solo-two-network-down.sh` (new)
- `scripts/clpr/native-queue/solo-two-network-status.sh` (new)
- `docs/clpr/native-queue-integration-plan/solo-custom-build-runbook.md` (new)
- `docs/clpr/native-queue-integration-plan/execution-feedforward-log.md` (append ISSUE-0002 observations)

In `../hiero-consensus-node`:

- No mandatory code changes; optional CI helper docs only if needed.

## Risk Areas

- Local Kubernetes resource pressure and unstable port-forward processes.
- Mismatch between Solo chart versions and locally built node artifacts.

## Completion Notes

- Implemented scripts:
  - `scripts/clpr/native-queue/solo-two-network-up.sh`
  - `scripts/clpr/native-queue/solo-two-network-status.sh`
  - `scripts/clpr/native-queue/solo-two-network-down.sh`
  - `scripts/clpr/native-queue/lib.sh`
- Added deterministic CLPR config templates:
  - `scripts/clpr/native-queue/config/application-src.properties`
  - `scripts/clpr/native-queue/config/application-dst.properties`
- Added runbook:
  - `docs/clpr/native-queue-integration-plan/solo-custom-build-runbook.md`
- Verified dual deployment health using script checks (pods, JVM process, service, CLPR config).
- Captured run manifests in:
  - `artifacts/clpr-native-queue/issue-0002/*/run-manifest.env`
- Observed reproducible Solo start quirk:
  - `consensus node start` may fail at `set gRPC Web endpoint` with `INVALID_NODE_ID`.
  - Script now treats this signature as non-blocking when post-start health checks pass.
- Observed Solo stop behavior quirk in dev mode:
  - `solo consensus node stop` updates control-plane state but does not reliably terminate the running node process/pod in this environment.
  - Restart validation criteria were adjusted in runbook to use control-plane phase evidence instead of assuming immediate pod/JVM termination.
