# CI Orchestrator Execution Rules

This document is the single source of truth for:

- validation entry points in `.github/workflows/validate-planner-contracts.yml`, `.github/workflows/validate-terraform.yml`, and `.github/workflows/validate-ansible.yml`
- infra-repo push execution in `.github/workflows/infra-orchestrator.yml`
- canonical planning in `.github/workflows/reusable-resolve-plan.yml`

## Validation Behavior

Validation is split by concern instead of being bundled into a single workflow:

- `validate-planner-contracts.yml` runs planner shell tests, workflow contract checks, bootstrap-tools smoke, and trusted stacks SHA verification for the current `HEAD:stacks` gitlink
- `validate-terraform.yml` runs `terraform fmt`, `terraform validate` for `terraform/infra`, `terraform/oci`, `terraform/gcp`, `terraform/portainer-root`, and `terraform/portainer`, plus the fixed Terraform Cloud speculative plan for `terraform/infra`
- `validate-ansible.yml` runs ansible lint + syntax checks

None of the active validation workflows do path-derived project selection inside the workflow body. Each workflow is triggered only by the path set relevant to its concern.

## Orchestrator Push Behavior

Impact detection has been removed from the active planner. Any eligible infra-repo `push` now resolves to the same infra-side reconcile path.

The trigger remains coarse in `.github/workflows/infra-orchestrator.yml`:

- `terraform/**`
- `ansible/**`
- `.ansible-lint`

Once triggered, the planner always emits the same push toggles:

- `run_infra_apply=true`
- `run_ansible_bootstrap=true`
- `run_portainer_apply=true`
- `run_host_sync=false`
- `run_config_sync=false`
- `run_health_redeploy=false`
- `reason=infra-repo-push`

The top-level orchestrator remains thin and stable:

- `resolve-context` emits canonical `plan_json`
- `preflight` runs cloud-runner-guard, optional stacks SHA trust, secret validation, and network policy sync
- `infra` runs infra apply, inventory handover, and SSH network preflight
- `ansible` runs bootstrap and/or host runtime sync
- `portainer` runs post-bootstrap checks, Portainer API preflight, optional config sync, Portainer apply, and optional health-gated redeploy

## Dispatch Notes

- `repository_dispatch` accepts only `stacks-redeploy-intent-v5` with `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, and `reason=full-reconcile`.
- Every valid stacks dispatch runs the same stacks path: trusted `stacks_sha` -> `phase7_runtime_sync` -> `sync-configs` -> SHA-pinned Portainer apply -> full Portainer-managed redeploy from that applied Git ref.
- `infra-orchestrator.yml` accepts only `push` and `repository_dispatch`. It no longer exposes manual `workflow_dispatch` or reusable `workflow_call` entry points.
- `has_work=true` when any execution toggle is true.
