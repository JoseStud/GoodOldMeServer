# Workflow Lifecycle

This document defines the current GitHub Actions workflow set.

## Active Workflows

| Workflow | Purpose |
|----------|---------|
| `.github/workflows/validate-planner-contracts.yml` | Public planner/workflow validation entry point for `ci_plan` pytest contract tests, workflow contract checks, stage exhaustiveness checks, bootstrap-query-tools smoke, and trusted stacks SHA verification. |
| `.github/workflows/validate-terraform.yml` | Public Terraform validation entry point for `terraform fmt`, multi-root `terraform validate`, the fixed speculative Terraform Cloud run for `terraform/infra`, and a live shadow Portainer plan for `terraform/portainer-root` (runs on the cloud static runner in `SHADOW_MODE=true`). |
| `.github/workflows/validate-ansible.yml` | Public Ansible validation entry point for `ansible-lint` and syntax checks. |
| `.github/workflows/orchestrator.yml` | Single orchestration entry point for all infra and ansible push paths. Push triggers: `terraform/**`, `stacks`, `.gitmodules` (full reconcile with infra apply); `ansible/**`, `.ansible-lint` (ansible-only, resolver detects from changed files and computes fine-grained tags). Also accepts `stacks-redeploy-intent-v5` repository dispatch and `workflow_dispatch` (optional `ansible_only` boolean input to skip TFC apply). Fans into `preflight`, `infra`, `ansible`, and `portainer` reusable stage workflows under the `infra-orchestrator` concurrency group. |
| `.github/workflows/check-ansible-galaxy-updates.yml` | Scheduled (weekly, Monday 09:00 UTC) and manual check that compares pinned versions in `ansible/requirements.yml` against latest Galaxy releases. Fails with an annotation if any collection has a newer version available (Dependabot does not support Ansible Galaxy natively). |
| `.github/workflows/reusable-resolve-plan.yml` | Reusable planner that installs the `ci_plan` Python package, validates dispatch payloads inline, and emits canonical `plan_json` for the orchestrator workflow. |
| `.github/workflows/reusable-orch-preflight.yml` | Internal reusable stage for cloud runner guard, stacks SHA trust, secret validation, and network policy sync. |
| `.github/workflows/reusable-orch-infra.yml` | Internal reusable stage for infra apply, inventory handover, and SSH network preflight. |
| `.github/workflows/reusable-orch-ansible.yml` | Internal reusable stage for Ansible bootstrap and host runtime sync. |
| `.github/workflows/reusable-orch-portainer.yml` | Internal reusable stage for Portainer prechecks, config sync, Portainer apply, and health-gated redeploy. |
| `.github/workflows/lint-github-actions.yml` | Lints workflow YAML, composite actions, and repository docs/config parseability. |
