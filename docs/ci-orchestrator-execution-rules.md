# CI Orchestrator Execution Rules

This document is the single source of truth for:

- fixed-suite validation in `.github/workflows/infra-validation.yml`
- infra-repo push execution in `.github/workflows/infra-orchestrator.yml`
- canonical planning in `.github/workflows/reusable-resolve-plan.yml`

## Validation Behavior

`infra-validation.yml` does not do path-derived project selection. On every relevant trigger it always runs:

- planner contract tests
- bootstrap-tools smoke
- `terraform fmt`
- `terraform validate` for `terraform/infra`, `terraform/oci`, `terraform/gcp`, `terraform/portainer-root`, and `terraform/portainer`
- the fixed Terraform Cloud speculative plan for the infra workspace (`terraform/infra`)
- ansible lint + syntax
- trusted stacks SHA verification for the current `HEAD:stacks` gitlink

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

## Dispatch Notes

- `repository_dispatch` accepts only `stacks-redeploy-intent-v5` with `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, and `reason=full-reconcile`.
- Every valid stacks dispatch runs the same stacks path: trusted `stacks_sha` -> `phase7_runtime_sync` -> `sync-configs` -> SHA-pinned Portainer apply -> full Portainer-managed redeploy from that applied Git ref.
- `infra-orchestrator.yml` accepts only `push` and `repository_dispatch`. It no longer exposes manual `workflow_dispatch` or reusable `workflow_call` entry points.
- `has_work=true` when any execution toggle is true.
