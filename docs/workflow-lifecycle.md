# Workflow Lifecycle

This document defines the current GitHub Actions workflow set.

## Active Workflows

| Workflow | Purpose |
|----------|---------|
| `.github/workflows/validate-planner-contracts.yml` | Public planner/workflow validation entry point for shell contract tests, workflow contract checks, bootstrap-query-tools smoke, and trusted stacks SHA verification. |
| `.github/workflows/validate-terraform.yml` | Public Terraform validation entry point for `terraform fmt`, multi-root `terraform validate`, and the fixed speculative Terraform Cloud run for `terraform/infra`. |
| `.github/workflows/validate-ansible.yml` | Public Ansible validation entry point for `ansible-lint` and syntax checks. |
| `.github/workflows/infra-orchestrator.yml` | Thin infrastructure orchestration entry point triggered by `terraform/**`, `stacks`, `.gitmodules` pushes, `stacks-redeploy-intent-v5` dispatch, and `workflow_dispatch` (manual rerun; `ansible_only` boolean input to skip TFC apply). Fans into `preflight`, `infra`, `ansible`, and `portainer` reusable stage workflows. |
| `.github/workflows/ansible-orchestrator.yml` | Ansible-only orchestration entry point triggered by `ansible/**` and `.ansible-lint` pushes, and `workflow_dispatch` (manual rerun, no inputs). Shares the same reusable stage workflows as `infra-orchestrator.yml` but skips the Terraform infra-apply stage (`stage_infra_apply=false`). Shares the `infra-orchestrator` concurrency group to prevent simultaneous runs. |
| `.github/workflows/check-ansible-galaxy-updates.yml` | Scheduled (weekly, Monday 09:00 UTC) and manual check that compares pinned versions in `ansible/requirements.yml` against latest Galaxy releases. Fails with an annotation if any collection has a newer version available (Dependabot does not support Ansible Galaxy natively). |
| `.github/workflows/reusable-resolve-plan.yml` | Reusable planner that emits canonical `plan_json` for the orchestrator workflow. |
| `.github/workflows/reusable-orch-preflight.yml` | Internal reusable stage for cloud runner guard, stacks SHA trust, secret validation, and network policy sync. |
| `.github/workflows/reusable-orch-infra.yml` | Internal reusable stage for infra apply, inventory handover, and SSH network preflight. |
| `.github/workflows/reusable-orch-ansible.yml` | Internal reusable stage for Ansible bootstrap and host runtime sync. |
| `.github/workflows/reusable-orch-portainer.yml` | Internal reusable stage for Portainer prechecks, config sync, Portainer apply, and health-gated redeploy. |
| `.github/workflows/lint-github-actions.yml` | Lints workflow YAML, composite actions, and repository docs/config parseability. |
