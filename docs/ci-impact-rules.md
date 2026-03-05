# CI Impact Rules

This document is the single source of truth for change-detection behavior used by:

- `.github/workflows/iac-validation.yml`
- `.github/workflows/meta-pipeline.yml`
- `.github/workflows/meta-pipeline-smoke.yml`

Rules are defined in `.github/ci/path-filters.yml` and consumed via `dorny/paths-filter@v3`.

## Filter Truth Table

| Filter key | Paths | Resolver output | Derived execution | Jobs triggered | Event caveats |
|------------|-------|-----------------|-------------------|----------------|---------------|
| `iac_workspace_infra` | `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**` | `infra_workspace_changed=true` (`detect_iac_impact.sh`) | Adds `{"workspace_key":"infra","config_directory":"terraform/infra"}` to `tfc_workspace_matrix_json` | `tfc-speculative-plan` (infra workspace) when validate stage succeeds | On `workflow_dispatch`, forced `true`; on first push (`before=000...`), derived from `git show` fallback |
| `iac_workspace_portainer` | `terraform/portainer-root/**`, `terraform/portainer/**` | `portainer_workspace_changed=true` | Reporting signal for portainer workspace impact | No Terraform Cloud speculative plan row is emitted for portainer in current implementation | On `workflow_dispatch`, forced `true`; on first push, derived from `git show` fallback |
| `iac_ansible` | `ansible/**`, `.ansible-lint` | `ansible_changed=true` | Enables ansible validation path | `ansible-validate` | On `workflow_dispatch`, forced `true`; on first push, derived from `git show` fallback |
| `iac_stacks_gitlink` | `stacks` (gitlink) | `stacks_gitlink_changed=true` and `stacks_sha` populated | Enables trust verification for requested stacks SHA | `stacks-sha-trust` | On `workflow_dispatch`, forced `true`; on first push, derived from `git show` fallback |
| `iac_tf_infra` | `terraform/infra/**` | Adds `terraform/infra` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/infra`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_oci` | `terraform/oci/**` | Adds `terraform/oci` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/oci`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_gcp` | `terraform/gcp/**` | Adds `terraform/gcp` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/gcp`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_portainer_root` | `terraform/portainer-root/**` | Adds `terraform/portainer-root` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/portainer-root`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `iac_tf_portainer` | `terraform/portainer/**` | Adds `terraform/portainer` to `changed_tf_roots_json` | Enables matrix validation for this root | `terraform-validate` (`matrix.root=terraform/portainer`) | On `workflow_dispatch`, included by default; on first push, derived from `git show` fallback |
| `meta_infra` | `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**` | Initial signal `run_infra_apply=true` (`resolve_meta_context.sh`) | Implies `run_ansible_bootstrap=true` and `run_portainer_apply=true` | `infra-apply`, then dependent chain (`inventory-handover`, `ansible-bootstrap`, `portainer-apply`, optional downstream jobs) | Used for `push` path-filter resolution; `repository_dispatch` and manual events resolve from payload/inputs instead |
| `meta_ansible` | `ansible/**`, `.ansible-lint` | Initial signal `run_ansible_bootstrap=true` | Implies `run_portainer_apply=true` | `inventory-handover`, `network-preflight-ssh`, `ansible-bootstrap`, then `portainer-apply` chain | Used for `push` path-filter resolution; `repository_dispatch` and manual events resolve from payload/inputs instead |
| `meta_portainer` | `terraform/portainer/**`, `terraform/portainer-root/**`, `.github/workflows/**`, `.github/scripts/**`, `.github/ci/**` | Initial signal `run_portainer_apply=true` | Enables local portainer Terraform apply path and related API preflight | `post-bootstrap-secret-check` (if applicable), `portainer-api-preflight`, `portainer-apply` | Used for `push` path-filter resolution; `repository_dispatch` and manual events resolve from payload/inputs instead |

## Notes

- `run_config_sync=true` when `config_stacks` is non-empty.
- `run_health_redeploy=true` when `changed_stacks` is non-empty.
- `has_work=true` when any execution toggle is true.
- `meta-pipeline.yml` can auto-resolve `stacks_sha` from `HEAD:stacks` when missing; `meta-pipeline-smoke.yml` does not.
