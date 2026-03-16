# GitHub Actions Workflows

This page maps each active workflow to its responsibility, trigger or caller, and the main inputs/outputs that other workflows or operators depend on.

## Public Entry Points

| Workflow | Trigger | Responsibility | Inputs | Outputs / Artifacts |
|----------|---------|----------------|--------|---------------------|
| `.github/workflows/orchestrator.yml` | `push` on `terraform/**`, `stacks` gitlink / `.gitmodules`, `ansible/**`, `.ansible-lint`; `repository_dispatch` `stacks-redeploy-intent-v5`; `workflow_dispatch` (manual rerun) | Three-job pipeline: `compute-context` → `infra-apply` → `dagger-pipeline`. `compute-context` validates dispatch payloads, classifies ansible-only pushes, computes optional `ansible_tags`, and emits typed run toggles (via `ci_pipeline.context` Python module). `infra-apply` runs TFC API-only marketplace actions when `run_infra_apply=true`. `dagger-pipeline` connects to the Tailscale mesh and runs the Dagger containerized pipeline: preflight phase (stacks-sha-trust, secret-validation, network-policy-sync), inventory-handover, Ansible bootstrap/host-sync (host subprocess with Tailscale SSH), and portainer phase (post-bootstrap-secret-check, portainer-api-preflight, portainer-apply, health-gated-redeploy). `workflow_dispatch` input `ansible_only` (bool) skips `infra-apply`. All paths share the `infra-orchestrator` concurrency group. | GitHub event payload | Exposes execution toggles and context via `compute-context` outputs |
| `.github/workflows/validate-planner-contracts.yml` | `push` including `main`, `pull_request` | Bootstrap-query-tools smoke and trusted stacks SHA verification | Repository contents on workflow/action/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/validate-terraform.yml` | `push` including `main`, `pull_request` | `terraform fmt`, multi-root `terraform validate`, fixed speculative Terraform Cloud run | Repository contents on Terraform/workflow/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/validate-ansible.yml` | `push` including `main`, `pull_request` | `ansible-lint` and syntax validation | Repository contents on Ansible/workflow/script changes plus `stacks` gitlink / `.gitmodules` updates | CI check results only |
| `.github/workflows/lint-github-actions.yml` | `push`, `pull_request` | actionlint, yamllint, YAML parse checks | Workflow/action/doc files plus `stacks` gitlink / `.gitmodules` updates | CI check results only |

## Stable Contracts

- The `compute-context` outputs are the planner contract shared across GHA job boundaries within `orchestrator.yml`.
- Active `push` and `repository_dispatch` paths both carry a non-empty `meta.stacks_sha`.
- Trusted stacks SHA verification uses observed GitHub CI signals from the stacks repo commit: GitHub Checks and legacy commit statuses. Either signal channel may be absent, but every channel that exists must be green and at least one must exist.
- The rendered CI inventory (`inventory-ci.yml`) is produced inside the Dagger pipeline by `ci_pipeline/phases/infra.py` and exported to the runner filesystem for Ansible host-subprocess stages.
- The `dagger-pipeline` job runs on `ubuntu-latest` with Tailscale connected; Ansible and Dagger are installed at runtime via pip and the `dagger/dagger-for-github` action.
- The cloud static runner (`CLOUD_STATIC_RUNNER_LABEL`) is used only by `validate-terraform.yml` for the `portainer-live-plan` job; the orchestrator no longer routes through it.
- Post-merge protection for `.github/scripts/**` changes comes from the `validate-*` workflows running on `push`, including `main`; the orchestrators stay path-scoped to deployable infra and ansible content.
- The `validate-terraform.yml` workflow includes a `portainer-live-plan` job: a shadow Portainer plan run (uses `SHADOW_MODE=true`) that runs on the cloud static runner and performs a live Portainer plan validation for the `terraform/portainer-root` workspace.
- The `validate-planner-contracts.yml` workflow's `stacks-sha-trust` job intentionally does NOT wait for external CI signals by default (contract: `WAIT_FOR_SUCCESS=false`). The orchestrator `dagger-pipeline` preflight phase sets `WAIT_FOR_SUCCESS=true` and polls.
