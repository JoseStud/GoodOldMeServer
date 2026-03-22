# Workflow Lifecycle

This document defines the current GitHub Actions workflow set.

## Active Workflows

| Workflow | Purpose |
|----------|---------|
| `.github/workflows/validate-planner-contracts.yml` | Public planner/workflow validation entry point for bootstrap-query-tools smoke and trusted stacks SHA verification. |
| `.github/workflows/validate-terraform.yml` | Public Terraform validation entry point for `terraform fmt`, multi-root `terraform validate`, and the TFC speculative plan for `terraform/infra`. The `portainer-live-plan` job (which ran on the cloud static runner) was removed — the orchestrator `portainer-apply` stage catches failures post-merge, and `PORTAINER_API_URL` now uses the Tailscale IP directly. |
| `.github/workflows/validate-ansible.yml` | Public Ansible validation entry point for `ansible-lint` and syntax checks. |
| `.github/workflows/orchestrator.yml` | Single orchestration entry point for all infra and ansible push paths. Push triggers: `terraform/**`, `stacks`, `.gitmodules`, `ansible/**`, `.ansible-lint`. Three GHA jobs: `compute-context` (inline Python module classifies push behavior, computes optional ansible phase tags) → `infra-apply` (TFC API-only apply when `run_infra_apply=true`) → `dagger-pipeline` (Tailscale-connected Dagger pipeline: preflight, inventory-handover, Ansible host subprocess, portainer phases). Also accepts `workflow_dispatch` (optional `ansible_only` boolean input to skip `infra-apply`). Stacks deployments are triggered by updating the submodule pointer in this repo. All paths share the `infra-orchestrator` concurrency group. |
| `.github/workflows/check-ansible-galaxy-updates.yml` | Scheduled (weekly, Monday 09:00 UTC) and manual check that compares pinned versions in `ansible/requirements.yml` against latest Galaxy releases. Fails with an annotation if any collection has a newer version available (Dependabot does not support Ansible Galaxy natively). |
| `.github/workflows/lint-github-actions.yml` | Lints workflow YAML, composite actions, and repository docs/config parseability. |
