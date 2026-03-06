# CI Impact Rules

This document is the single source of truth for:

- fixed-suite validation in `.github/workflows/infra-validation.yml`
- infra-repo push detection in `.github/workflows/infra-orchestrator.yml`
- path-filter use inside `.github/workflows/reusable-detect-impact-resolve-plan.yml`

Rules are defined in `.github/ci/path-filters.yml` and consumed via `dorny/paths-filter@v3`.

## Validation Behavior

`infra-validation.yml` no longer uses impact-derived project selection. On every relevant trigger it always runs:

- planner contract tests
- bootstrap-tools smoke
- `terraform fmt`
- `terraform validate` for `terraform/infra`, `terraform/oci`, `terraform/gcp`, `terraform/portainer-root`, and `terraform/portainer`
- the fixed Terraform Cloud speculative plan for the infra workspace (`terraform/infra`)
- ansible lint + syntax
- trusted stacks SHA verification for the current `HEAD:stacks` gitlink

## Orchestrator Push Filters

Only the `meta_*` filters remain, and they apply only to infra-repo `push` planning.

| Filter key | Paths | Resolver output | Derived execution |
|------------|-------|-----------------|-------------------|
| `meta_infra` | `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**` | Initial signal `run_infra_apply=true` | Implies `run_ansible_bootstrap=true` and `run_portainer_apply=true` |
| `meta_ansible` | `ansible/**`, `.ansible-lint` | Initial signal `run_ansible_bootstrap=true` | Implies `run_portainer_apply=true` |
| `meta_portainer` | `terraform/portainer/**`, `terraform/portainer-root/**` | Initial signal `run_portainer_apply=true` | Enables local Portainer Terraform apply path and related preflights |

## Dispatch and Manual Notes

- `repository_dispatch` accepts only `stacks-redeploy-intent-v5` with `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, and `reason=full-reconcile`.
- Every valid stacks dispatch runs the same stacks path: trusted `stacks_sha` -> `phase7_runtime_sync` -> `sync-configs` -> Portainer apply -> full Portainer-managed redeploy.
- Manual `workflow_dispatch` and `workflow_call` do not support stack-targeted execution. They keep only `run_infra_apply`, `run_ansible_bootstrap`, `run_portainer_apply`, `dry_run`, `reason`, `stacks_sha`, and the break-glass override.
- `has_work=true` when any execution toggle is true.
