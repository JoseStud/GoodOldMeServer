# CI Orchestrator Execution Rules

This document is the single source of truth for:

- validation entry points in `.github/workflows/validate-planner-contracts.yml`, `.github/workflows/validate-terraform.yml`, and `.github/workflows/validate-ansible.yml`
- infra-repo push execution in `.github/workflows/infra-orchestrator.yml`
- canonical planning in `.github/workflows/reusable-resolve-plan.yml`

## Validation Behavior

Validation is split by concern instead of being bundled into a single workflow:

- `validate-planner-contracts.yml` runs planner shell tests, workflow contract checks, bootstrap-query-tools smoke, and trusted stacks SHA verification for the current `HEAD:stacks` gitlink
- `validate-terraform.yml` runs `terraform fmt`, `terraform validate` for `terraform/infra`, `terraform/oci`, `terraform/gcp`, `terraform/portainer-root`, and `terraform/portainer`, plus the fixed Terraform Cloud speculative plan for `terraform/infra`
- `validate-ansible.yml` runs ansible lint + syntax checks

None of the active validation workflows do path-derived project selection inside the workflow body. Each workflow is triggered only by the path set relevant to its concern.
Submodule pointer updates are treated as first-class infra changes: the active validation workflows and orchestrator trigger on `stacks` and `.gitmodules`.

## Orchestrator Push Behavior

Impact detection has been removed from the active planner. Any eligible infra-repo `push` now resolves to the same infra-side reconcile path.

Push-triggered orchestration is split across two workflows by path:

**`.github/workflows/infra-orchestrator.yml`** — full reconcile (infra apply + ansible + portainer):

- `terraform/**`
- `stacks`
- `.gitmodules`

**`.github/workflows/ansible-orchestrator.yml`** — ansible-only reconcile (skips infra apply):

- `ansible/**`
- `.ansible-lint`

Both workflows share the `infra-orchestrator` concurrency group so a full infra run and an Ansible-only run cannot execute simultaneously.

Once triggered, the infra-orchestrator planner always emits the same push toggles:

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

- `repository_dispatch` accepts only `stacks-redeploy-intent-v5` with `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, and `reason=full-reconcile`.
- `repository_dispatch` payload `stacks_sha` remains authoritative for the stacks reconcile path; `push` resolves `stacks_sha` from `HEAD:stacks`.
- Every valid stacks dispatch runs the same stacks path: trusted `stacks_sha` -> `phase7_runtime_sync` -> `sync-configs` -> SHA-pinned Portainer apply -> full Portainer-managed redeploy from that applied Git ref.
- Network policy sync must wait for `stacks-sha-trust` before mutating Terraform Cloud or Infisical allowlists.
- `infra-orchestrator.yml` accepts `push`, `repository_dispatch`, and `workflow_dispatch`. Manual dispatch (`workflow_dispatch`) resolves `stacks_sha` from `HEAD:stacks` and runs the full infra-side reconcile path (`reason=manual-dispatch`). An optional boolean input `ansible_only` skips TFC infra-apply (equivalent to `ansible-orchestrator.yml` behavior). `ansible-orchestrator.yml` also accepts `workflow_dispatch` with no inputs (always runs in ansible-only mode). Neither orchestrator exposes a reusable `workflow_call` entry point.
- `has_work=true` when any execution toggle is true.
