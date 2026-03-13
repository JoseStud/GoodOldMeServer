# CI Orchestrator Execution Rules

This document is the single source of truth for:

- validation entry points in `.github/workflows/validate-planner-contracts.yml`, `.github/workflows/validate-terraform.yml`, and `.github/workflows/validate-ansible.yml`
- infra-repo push execution in `.github/workflows/orchestrator.yml`
- canonical planning in `.github/workflows/reusable-resolve-plan.yml`

## Validation Behavior

Validation is split by concern instead of being bundled into a single workflow:

- `validate-planner-contracts.yml` runs planner contract tests (pytest for the `ci_plan` Python package), workflow contract checks, stage exhaustiveness checks, bootstrap-query-tools smoke, and trusted stacks SHA verification for the current `HEAD:stacks` gitlink
- `validate-terraform.yml` runs `terraform fmt`, `terraform validate` for `terraform/infra`, `terraform/oci`, `terraform/gcp`, `terraform/portainer-root`, and `terraform/portainer`, plus the fixed Terraform Cloud speculative plan for `terraform/infra`
- `validate-ansible.yml` runs ansible lint + syntax checks

Each validation workflow runs on both `pull_request` and path-filtered `push`, including pushes to `main`.
None of the active validation workflows do path-derived project selection inside the workflow body. Each workflow is triggered only by the path set relevant to its concern.
Submodule pointer updates are treated as first-class infra changes: the active validation workflows and orchestrator trigger on `stacks` and `.gitmodules`.
Post-merge validation for deployment shell changes under `.github/scripts/**` is provided by these validation workflows, not by expanding the production orchestrator push paths.

## Orchestrator Push Behavior

A single `.github/workflows/orchestrator.yml` handles all push paths. The Python
resolver (`ci_plan` package) classifies each push automatically:

**Full reconcile** (infra apply + ansible + portainer) — triggered by changes to:

- `terraform/**`
- `stacks`
- `.gitmodules`

**Ansible-only reconcile** (skips infra apply) — triggered by changes to:

- `ansible/**`
- `.ansible-lint`

The resolver detects ansible-only mode when every changed file matches
`ansible/**` or `.ansible-lint` exactly. Mixed pushes (any terraform or stacks
file alongside ansible files) fall back to the full reconcile path.

Both trigger paths share the `infra-orchestrator` concurrency group so a full
infra run and an ansible-only run cannot execute simultaneously.

Once triggered, the infra-path planner always emits the same push toggles:

- `run_infra_apply=true`
- `run_ansible_bootstrap=true`
- `run_portainer_apply=true`
- `run_host_sync=false`
- `run_config_sync=false`
- `run_health_redeploy=false`
- `stacks_sha=$(git rev-parse HEAD:stacks)`
- `reason=infra-repo-push`

The top-level orchestrator remains thin and stable:

- `resolve-context` emits canonical `plan_json`
- `preflight` runs cloud-runner-guard, stacks SHA trust, secret validation, and network policy sync
- `infra` runs infra apply, inventory handover, and SSH network preflight
- `ansible` runs bootstrap and/or host runtime sync
- `portainer` runs post-bootstrap checks, Portainer API preflight, optional config sync, Portainer apply, and optional health-gated redeploy
- Any job running on `runner_label` assumes the `toolingDebian` runner contract and does not bootstrap deployment tooling inside the workflow

## Trusted `stacks_sha` Boundary

The stacks SHA trust gate is an architectural boundary between the public stacks repo CI surface and the private infra execution surface.

- `validate-planner-contracts.yml` verifies the current `HEAD:stacks` gitlink, and `reusable-orch-preflight.yml` verifies any dispatch or push `meta.stacks_sha` before later stages are allowed to consume it.
- Trust has two parts: the SHA must still be on the stacks repo `main` lineage, and every observed GitHub CI signal on that commit must be green.
- The observed CI signals are the GitHub Checks API (`check-runs`) and the legacy commit-status API (`combined status`). Either channel may be absent; if a channel exists it must be ready, and at least one channel must exist.
- `network-policy-sync` must wait for this trust gate before mutating Terraform Cloud or Infisical allowlists.
- `phase7_runtime_sync`, `sync-configs`, `terraform/portainer-root` SHA pinning, and the health-gated Portainer webhook redeploy all inherit this boundary because they consume the verified `meta.stacks_sha`.

## Dispatch Notes

- `repository_dispatch` accepts only `stacks-redeploy-intent-v5` with `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, and `reason=full-reconcile`. Payload validation is performed inline by the Python `ci_plan` resolver (controlled by `VALIDATE_DISPATCH_CONTRACT` env var).
- `repository_dispatch` payload `stacks_sha` remains authoritative for the stacks reconcile path; `push` resolves `stacks_sha` from `HEAD:stacks`.
- Every valid stacks dispatch runs the same stacks path: trusted `stacks_sha` -> `phase7_runtime_sync` -> `sync-configs` -> SHA-pinned Portainer apply -> full Portainer-managed redeploy from that applied Git ref.
- Network policy sync must wait for `stacks-sha-trust` before mutating Terraform Cloud or Infisical allowlists.
- `orchestrator.yml` accepts `push`, `repository_dispatch`, and `workflow_dispatch`. Manual dispatch (`workflow_dispatch`) resolves `stacks_sha` from `HEAD:stacks` and runs the full infra-side reconcile path (`reason=manual-dispatch`). An optional boolean input `ansible_only` skips TFC infra-apply; internally this maps to the `dispatch_ansible_only` event name, which the resolver treats identically to an ansible-only push. The orchestrator does not expose a reusable `workflow_call` entry point.
- `has_work=true` when any execution toggle is true.
