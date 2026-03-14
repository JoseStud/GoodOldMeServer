# GitHub Actions Workflows

This page maps each active workflow to its responsibility, trigger or caller, and the main inputs/outputs that other workflows or operators depend on.

## Public Entry Points

| Workflow | Trigger | Responsibility | Inputs | Outputs / Artifacts |
|----------|---------|----------------|--------|---------------------|
| `.github/workflows/orchestrator.yml` | `push` on `terraform/**`, `stacks` gitlink / `.gitmodules`, `ansible/**`, `.ansible-lint`; `repository_dispatch` `stacks-redeploy-intent-v5`; `workflow_dispatch` (manual rerun) | Thin top-level DAG: `compute-context` -> `preflight` -> `infra` -> `ansible` -> `portainer`. `compute-context` validates dispatch payloads, classifies ansible-only pushes, computes optional `ansible_tags`, and emits typed run toggles for reusable workflows. `workflow_dispatch` input `ansible_only` (bool) skips TFC apply. All paths share the `infra-orchestrator` concurrency group. | GitHub event payload | Exposes execution toggles and context via `compute-context` outputs |
| `.github/workflows/validate-planner-contracts.yml` | `push` including `main`, `pull_request` | Bootstrap-query-tools smoke and trusted stacks SHA verification | Repository contents on workflow/action/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/validate-terraform.yml` | `push` including `main`, `pull_request` | `terraform fmt`, multi-root `terraform validate`, fixed speculative Terraform Cloud run | Repository contents on Terraform/workflow/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/validate-ansible.yml` | `push` including `main`, `pull_request` | `ansible-lint` and syntax validation | Repository contents on Ansible/workflow/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/lint-github-actions.yml` | `push`, `pull_request` | actionlint, yamllint, YAML parse checks | Workflow/action/doc files plus `stacks` gitlink / `.gitmodules` updates | CI check results only |

## Internal Reusable Workflows

| Workflow | Caller | Responsibility | Required Inputs | Outputs / Artifacts |
|----------|--------|----------------|-----------------|---------------------|
| `.github/workflows/reusable-orch-preflight.yml` | `orchestrator.yml` | Cloud runner guard, stacks SHA trust, secret validation, network policy sync. | `has_work`, `stacks_sha`, `run_infra_apply`, `run_ansible_bootstrap`, `run_portainer_apply`, `run_host_sync`, `run_health_redeploy` | `runner_label`, `network_access_policy_json`, `portainer_automation_allowed_cidrs` |
| `.github/workflows/reusable-orch-infra.yml` | `orchestrator.yml` | Infra apply (skipped in ansible-only mode), deterministic inventory render, SSH network preflight. | `run_infra_apply`, `run_ansible_bootstrap`, `run_host_sync`, `run_config_sync`, `reason`, `runner_label`, `network_access_policy_json` | Uploads `inventory-ci` artifact containing `inventory-ci.yml` |
| `.github/workflows/reusable-orch-ansible.yml` | `orchestrator.yml` | Ansible bootstrap and/or host runtime sync. | `run_ansible_bootstrap`, `run_host_sync`, `stacks_sha`, `ansible_tags`, `runner_label` | Consumes `inventory-ci` artifact |
| `.github/workflows/reusable-orch-portainer.yml` | `orchestrator.yml` | Post-bootstrap secret checks, Portainer API preflight, optional config sync, Portainer apply, health-gated redeploy. | `run_portainer_apply`, `run_health_redeploy`, `run_config_sync`, `stacks_sha`, `runner_label`, `network_access_policy_json` | Consumes `inventory-ci` artifact |

## Stable Contracts

- Typed workflow inputs are the planner contract shared across workflow boundaries.
- Active `push` and `repository_dispatch` paths both carry a non-empty `meta.stacks_sha`.
- Trusted stacks SHA verification uses observed GitHub CI signals from the stacks repo commit: GitHub Checks and legacy commit statuses. Either signal channel may be absent, but every channel that exists must be green and at least one must exist.
- `inventory-ci` remains the artifact name for the rendered CI inventory.
- `inventory-ci.yml` remains the rendered file path within the artifact and on runners.
- Reusable orchestrator workflows rely on `secrets: inherit`; caller workflow-level `env` is not propagated.
- Cloud-runner jobs assume the `toolingDebian` contract behind `CLOUD_STATIC_RUNNER_LABEL` and do not install deployment tools at runtime.
- Post-merge protection for `.github/scripts/**` changes comes from the `validate-*` workflows running on `push`, including `main`; the orchestrators stay path-scoped to deployable infra and ansible content.
- The `validate-terraform.yml` workflow includes a `portainer-live-plan` job: a shadow Portainer plan run (uses `SHADOW_MODE=true`) that runs on the cloud static runner and performs a live Portainer plan validation for the `terraform/portainer-root` workspace.
- The `validate-planner-contracts.yml` workflow's `stacks-sha-trust` job intentionally does NOT wait for external CI signals by default (contract: `WAIT_FOR_SUCCESS=false`). The orchestrator preflight sets `WAIT_FOR_SUCCESS=true` and polls.
