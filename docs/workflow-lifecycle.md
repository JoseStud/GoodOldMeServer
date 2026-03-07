# Workflow Lifecycle

This document defines which GitHub Actions workflows are active and which legacy workflows are retired.

## Active Workflows

| Workflow | Purpose |
|----------|---------|
| `.github/workflows/infra-validation.yml` | Pull request and push validation that always runs the fixed Terraform, Ansible, planner-contract, and trusted stacks SHA suite. |
| `.github/workflows/infra-orchestrator.yml` | Main infrastructure orchestration entry point for infra apply, bootstrap, Portainer apply, host runtime sync, config sync, and health-gated redeploy. |
| `.github/workflows/reusable-resolve-plan.yml` | Reusable planner that emits canonical `plan_json` for the orchestrator workflow. |
| `.github/workflows/lint-github-actions.yml` | Lints workflow YAML and local composite actions. |
