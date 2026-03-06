# CI Impact Rules

This document is the single source of truth for change-detection behavior used by:

- `.github/workflows/infra-validation.yml`
- `.github/workflows/infra-orchestrator.yml`
- `.github/workflows/reusable-detect-impact-resolve-plan.yml`

Rules are defined in `.github/ci/path-filters.yml` and consumed via `dorny/paths-filter@v3`.

## Canonical Planning Contract

- Canonical output: `plan_json` (schema version `ci-plan-v1`)
- Projection script for scalar workflow outputs:
  - `.github/scripts/plan/project_plan_outputs.sh iac`
  - `.github/scripts/plan/project_plan_outputs.sh meta`
- `.github/workflows/reusable-detect-impact-resolve-plan.yml` no longer exposes legacy scalar compatibility outputs directly.

## Filter Truth Table

| Filter key | Paths | Resolver output | Derived execution | Jobs triggered | Event caveats |
|------------|-------|-----------------|-------------------|----------------|---------------|
| `iac_workspace_infra` | `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**` | `infra_workspace_changed=true` (`.github/scripts/plan/resolve_ci_plan.sh`) | Adds `{"workspace_key":"infra","config_directory":"terraform/infra"}` to `tfc_workspace_matrix_json` | `tfc-speculative-plan` (infra workspace) when validate stage succeeds | On `workflow_dispatch`, forced `true`; on first push (`before=000...`), derived from `git show` fallback |
| `iac_workspace_portainer` | `terraform/portainer-root/**`, `terraform/portainer/**` | `portainer_workspace_changed=true` | Reporting signal for portainer workspace impact | No Terraform Cloud speculative plan row is emitted for portainer in current implementation | On `workflow_dispatch`, forced `true`; on first push, derived from `git show` fallback |
| `iac_ansible` | `ansible/**`, `.ansible-lint` | `ansible_changed=true` | Enables ansible validation path | `ansible-validate` | On `workflow_dispatch`, forced `true`; on first push, derived from `git show` fallback |
| `iac_stacks_gitlink` | `stacks` (gitlink) | `stacks_gitlink_changed=true` and `stacks_sha` populated | Enables trust verification for requested stacks SHA | `stacks-sha-trust` | On `workflow_dispatch`, forced `true`; on first push, derived from `git show` fallback |
| `iac_tf_infra` | `terraform/infra/**` | Adds `terraform/infra` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/infra`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_oci` | `terraform/oci/**` | Adds `terraform/oci` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/oci`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_gcp` | `terraform/gcp/**` | Adds `terraform/gcp` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/gcp`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_portainer_root` | `terraform/portainer-root/**` | Adds `terraform/portainer-root` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/portainer-root`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_portainer` | `terraform/portainer/**` | Adds `terraform/portainer` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/portainer`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `meta_infra` | `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**` | Initial signal `run_infra_apply=true` (`.github/scripts/plan/resolve_ci_plan.sh`) | Implies `run_ansible_bootstrap=true` and `run_portainer_apply=true` | `infra-apply`, then dependent chain (`inventory-handover`, `ansible-bootstrap`, `portainer-apply`) | Used for `push` path-filter resolution; `repository_dispatch` and manual events resolve from payload/inputs instead |
| `meta_ansible` | `ansible/**`, `.ansible-lint` | Initial signal `run_ansible_bootstrap=true` | Implies `run_portainer_apply=true` | `inventory-handover`, `network-preflight-ssh`, `ansible-bootstrap`, then `portainer-apply` chain | Used for `push` path-filter resolution; `repository_dispatch` and manual events resolve from payload/inputs instead |
| `meta_portainer` | `terraform/portainer/**`, `terraform/portainer-root/**` | Initial signal `run_portainer_apply=true` | Enables local portainer Terraform apply path and related API preflight | `post-bootstrap-secret-check` (if applicable), `portainer-api-preflight`, `portainer-apply` | Used for `push` path-filter resolution; `repository_dispatch` and manual events resolve from payload/inputs instead |

## Notes

- Dispatch-only stack planning still receives typed JSON arrays from `stacks-redeploy-intent-v4`, but `repository_dispatch` now treats every valid event as a full stacks reconcile.
- For `repository_dispatch`, the orchestrator always runs host sync, config sync, Portainer apply, and health-gated redeploy; payload arrays remain in `plan_json` for audit/debugging only.
- Manual `workflow_dispatch` and `workflow_call` keep the targeted behavior: `run_config_sync=true` when `config_stacks` is non-empty, `run_host_sync=true` when `host_sync_stacks` is non-empty, and `run_health_redeploy=true` when `changed_stacks` is non-empty.
- `has_work=true` when any execution toggle is true.
- `infra-orchestrator.yml` no longer infers stack redeploy intent from infra `push` events.
