# Workflow Lifecycle

This document defines which GitHub Actions workflows are active and which legacy workflows are retired.

## Active Workflows

| Workflow | Purpose |
|----------|---------|
| `.github/workflows/validate-planner-contracts.yml` | Public planner/workflow validation entry point for shell contract tests, workflow contract checks, bootstrap-tools smoke, and trusted stacks SHA verification. |
| `.github/workflows/validate-terraform.yml` | Public Terraform validation entry point for `terraform fmt`, multi-root `terraform validate`, and the fixed speculative Terraform Cloud run for `terraform/infra`. |
| `.github/workflows/validate-ansible.yml` | Public Ansible validation entry point for `ansible-lint` and syntax checks. |
| `.github/workflows/infra-orchestrator.yml` | Thin infrastructure orchestration entry point that fans into `preflight`, `infra`, `ansible`, and `portainer` reusable stage workflows. |
| `.github/workflows/reusable-resolve-plan.yml` | Reusable planner that emits canonical `plan_json` for the orchestrator workflow. |
| `.github/workflows/reusable-orch-preflight.yml` | Internal reusable stage for cloud runner guard, stacks SHA trust, secret validation, and network policy sync. |
| `.github/workflows/reusable-orch-infra.yml` | Internal reusable stage for infra apply, inventory handover, and SSH network preflight. |
| `.github/workflows/reusable-orch-ansible.yml` | Internal reusable stage for Ansible bootstrap and host runtime sync. |
| `.github/workflows/reusable-orch-portainer.yml` | Internal reusable stage for Portainer prechecks, config sync, Portainer apply, and health-gated redeploy. |
| `.github/workflows/lint-github-actions.yml` | Lints workflow YAML, composite actions, and docs references to retired workflow names. |

## Retired Workflows

| Workflow | Replacement |
|----------|-------------|
| `.github/workflows/infra-validation.yml` | Split into `validate-planner-contracts.yml`, `validate-terraform.yml`, and `validate-ansible.yml`. |
