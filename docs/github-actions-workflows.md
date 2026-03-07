# GitHub Actions Workflows

This page maps each active workflow to its responsibility, trigger or caller, and the main inputs/outputs that other workflows or operators depend on.

## Public Entry Points

| Workflow | Trigger | Responsibility | Inputs | Outputs / Artifacts |
|----------|---------|----------------|--------|---------------------|
| `.github/workflows/infra-orchestrator.yml` | `push` on `terraform/**`, `stacks` gitlink / `.gitmodules`; `repository_dispatch` `stacks-redeploy-intent-v5`; `workflow_dispatch` (manual rerun) | Thin top-level DAG: `resolve-context` -> `preflight` -> `infra` -> `ansible` -> `portainer`. `workflow_dispatch` input `ansible_only` (bool) skips TFC apply. | GitHub event payload | Consumes and forwards `plan_json`; exposes no additional public outputs |
| `.github/workflows/ansible-orchestrator.yml` | `push` on `ansible/**`, `.ansible-lint`; `workflow_dispatch` (manual rerun, no inputs) | Same DAG as `infra-orchestrator.yml` but resolves plan in `ansible_only_mode=true`, skipping `stage_infra_apply`. Shares the `infra-orchestrator` concurrency group. | GitHub event payload | Consumes and forwards `plan_json`; exposes no additional public outputs |
| `.github/workflows/validate-planner-contracts.yml` | `push`, `pull_request` | Planner shell tests, workflow contract tests, bootstrap-tools smoke, trusted stacks SHA verification | Repository contents on workflow/action/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/validate-terraform.yml` | `push`, `pull_request` | `terraform fmt`, multi-root `terraform validate`, fixed speculative Terraform Cloud run | Repository contents on Terraform/workflow/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/validate-ansible.yml` | `push`, `pull_request` | `ansible-lint` and syntax validation | Repository contents on Ansible/workflow/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/lint-github-actions.yml` | `push`, `pull_request` | actionlint, yamllint, YAML parse checks | Workflow/action/doc files plus `stacks` gitlink / `.gitmodules` updates | CI check results only |

## Internal Reusable Workflows

| Workflow | Caller | Responsibility | Required Inputs | Outputs / Artifacts |
|----------|--------|----------------|-----------------|---------------------|
| `.github/workflows/reusable-resolve-plan.yml` | `infra-orchestrator.yml` | Validate dispatch payload contract and emit canonical `plan_json` | Event metadata fields from the caller | `plan_json` |
| `.github/workflows/reusable-orch-preflight.yml` | `infra-orchestrator.yml` `preflight` job | Cloud runner guard, stacks SHA trust, secret validation, network policy sync | `plan_json` | `runner_label`, `network_access_policy_json`, `portainer_automation_allowed_cidrs` |
| `.github/workflows/reusable-orch-infra.yml` | `infra-orchestrator.yml` `infra` job | Infra apply, deterministic inventory render, SSH network preflight | `plan_json`, `runner_label`, `network_access_policy_json` | Uploads `inventory-ci` artifact containing `inventory-ci.yml` |
| `.github/workflows/reusable-orch-ansible.yml` | `infra-orchestrator.yml` `ansible` job | Ansible bootstrap and/or host runtime sync | `plan_json`, `runner_label` | Consumes `inventory-ci` artifact |
| `.github/workflows/reusable-orch-portainer.yml` | `infra-orchestrator.yml` `portainer` job | Post-bootstrap secret checks, Portainer API preflight, optional config sync, Portainer apply, health-gated redeploy | `plan_json`, `runner_label`, `network_access_policy_json` | Consumes `inventory-ci` artifact |

## Stable Contracts

- `plan_json` is the only planner contract shared across workflow boundaries.
- Active `push` and `repository_dispatch` paths both carry a non-empty `meta.stacks_sha`.
- Trusted stacks SHA verification uses observed GitHub CI signals from the stacks repo commit: GitHub Checks and legacy commit statuses. Either signal channel may be absent, but every channel that exists must be green and at least one must exist.
- `inventory-ci` remains the artifact name for the rendered CI inventory.
- `inventory-ci.yml` remains the rendered file path within the artifact and on runners.
- Reusable orchestrator workflows rely on `secrets: inherit`; caller workflow-level `env` is not propagated.
