# CI Impact Rules

This document defines the single source of truth for GitHub Actions change-detection rules used by:

- `.github/workflows/iac-validation.yml`
- `.github/workflows/meta-pipeline.yml`
- `.github/workflows/meta-pipeline-smoke.yml`

Rules are declared in `.github/ci/path-filters.yml` and consumed through `dorny/paths-filter@v3`.

## IaC Validation Filter Keys

- `iac_workspace_infra`
  - Paths: `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**`
  - Drives output: `infra_workspace_changed`
- `iac_workspace_portainer`
  - Paths: `terraform/portainer-root/**`, `terraform/portainer/**`
  - Drives output: `portainer_workspace_changed`
- `iac_ansible`
  - Paths: `ansible/**`, `.ansible-lint`
  - Drives output: `ansible_changed`
- `iac_stacks_gitlink`
  - Paths: `stacks`
  - Drives output: `stacks_gitlink_changed`
- `iac_tf_infra`
  - Paths: `terraform/infra/**`
  - Drives output: `changed_tf_roots_json` entry `terraform/infra`
- `iac_tf_oci`
  - Paths: `terraform/oci/**`
  - Drives output: `changed_tf_roots_json` entry `terraform/oci`
- `iac_tf_gcp`
  - Paths: `terraform/gcp/**`
  - Drives output: `changed_tf_roots_json` entry `terraform/gcp`
- `iac_tf_portainer_root`
  - Paths: `terraform/portainer-root/**`
  - Drives output: `changed_tf_roots_json` entry `terraform/portainer-root`
- `iac_tf_portainer`
  - Paths: `terraform/portainer/**`
  - Drives output: `changed_tf_roots_json` entry `terraform/portainer`

Derived outputs:

- `tfc_workspace_matrix_json` includes:
  - `{"workspace_key":"infra","config_directory":"terraform/infra"}` when `infra_workspace_changed=true`
  - `{"workspace_key":"portainer","config_directory":"terraform/portainer-root"}` when `portainer_workspace_changed=true`
- `stacks_sha` resolves from `HEAD:stacks` only when `stacks_gitlink_changed=true`
- `workflow_dispatch` forces full validation coverage (all toggles true)

## Meta Pipeline Filter Keys

- `meta_infra`
  - Paths: `terraform/infra/**`, `terraform/oci/**`, `terraform/gcp/**`
  - Initial signal: `run_infra_apply`
- `meta_ansible`
  - Paths: `ansible/**`, `.ansible-lint`
  - Initial signal: `run_ansible_bootstrap`
- `meta_portainer`
  - Paths: `terraform/portainer/**`, `terraform/portainer-root/**`, `.github/workflows/**`, `.github/scripts/**`, `.github/ci/**`
  - Initial signal: `run_portainer_apply`

Derived execution rules:

- `run_infra_apply=true` implies:
  - `run_ansible_bootstrap=true`
  - `run_portainer_apply=true`
- `run_ansible_bootstrap=true` implies:
  - `run_portainer_apply=true`
- `run_config_sync=true` when `config_stacks` is non-empty
- `run_health_redeploy=true` when `changed_stacks` is non-empty
- `has_work=true` when any execution toggle above is true

Event-specific behavior:

- `push`: use `paths-filter` outputs and compute `changed_paths` from git diff
- `repository_dispatch`: resolve from payload fields
- `workflow_dispatch`/`workflow_call`: resolve from inputs
- `meta-pipeline.yml` can resolve `stacks_sha` from `HEAD:stacks` when missing
- `meta-pipeline-smoke.yml` does not auto-resolve `stacks_sha`

## First Push Edge Case

When `github.event.before` is all zeros (`000...`), workflows skip `paths-filter` and fall back to `git show --name-only <sha>` for file-change detection.
