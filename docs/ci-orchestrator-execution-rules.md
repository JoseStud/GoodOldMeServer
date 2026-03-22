# CI Orchestrator Execution Rules

This document is the single source of truth for:

- validation entry points in `.github/workflows/validate-planner-contracts.yml`, `.github/workflows/validate-terraform.yml`, and `.github/workflows/validate-ansible.yml`
- infra-repo push and dispatch execution in `.github/workflows/orchestrator.yml`

## Validation Behavior

Validation is split by concern:

- `validate-planner-contracts.yml`: bootstrap-query-tools smoke and trusted stacks SHA verification for current `HEAD:stacks`
- `validate-terraform.yml`: `terraform fmt`, multi-root `terraform validate`, and Terraform Cloud speculative plan for `terraform/infra`
- `validate-ansible.yml`: ansible lint + syntax checks

All validation workflows run on `pull_request` and path-filtered `push`, including pushes to `main`.

## Orchestrator Event Behavior

`orchestrator.yml` computes execution toggles in a single inline job: `compute-context`.

### `push`

- `stacks_sha` is resolved from `HEAD:stacks`
- Default path: infra + ansible + portainer
- If every changed file is non-runtime metadata (`.ansible-lint`, Markdown files, `docs/**`, `.github/**`, `ci/**`), all execution toggles are false and `has_work=false` (`reason=infra-repo-metadata-only`)
- If every changed file is under `ansible/**` or equals `.ansible-lint`, skip infra apply
- Optional ansible phase tags are derived from changed role paths
- Classification order is metadata-only first, then ansible-only, then full-run fallback

### `workflow_dispatch`

- Runs infra + ansible + portainer
- If `ansible_only=true`, infra apply is skipped

## Runtime Job Chain

Top-level GHA jobs:

- `compute-context` — outputs execution toggles (runs on `ubuntu-latest`)
- `infra-apply` — TFC API apply via HashiCorp marketplace actions; gated on `run_infra_apply == 'true'` (runs on `ubuntu-latest`)
- `dagger-pipeline` — Tailscale-connected Dagger containerized pipeline; runs when `has_work == 'true'` and `infra-apply` succeeded or was skipped (runs on `ubuntu-latest`)

Within `dagger-pipeline`, phases execute in this order:

1. **Preflight** (parallel): stacks-sha-trust + secret-validation; inventory-handover (if needed)
2. **Network policy sync + Cloudflare DNS sync** (parallel): depends on preflight completing. DNS sync parses Traefik `Host(...)` rules from Portainer-managed compose files and reconciles round-robin A records once per unique hostname via `ci_pipeline/phases/dns.py`.
3. **Ansible** (host subprocess): bootstrap and/or host-sync, using Tailscale SSH; depends on inventory-handover + network-policy-sync
4. **Portainer**: post-bootstrap-secret-check, config-sync (host subprocess), portainer-api-preflight, portainer-apply, health-gated-redeploy; depends on network-policy-sync

Execution is gated by Python conditionals in `ci_pipeline/__main__.py` based on the toggle env vars from `compute-context`.

## Trusted `stacks_sha` Boundary

The `dagger-pipeline` preflight phase (`ci_pipeline/phases/preflight.py`) verifies trusted stacks SHA before any downstream stack-consuming stage mutates infrastructure.

This trust boundary applies to:

- runtime sync
- config sync
- Portainer apply manifest selection
- health-gated webhook redeploy

## Concurrency

All orchestrator event paths share one concurrency group (`infra-orchestrator-*`), so full infra runs and ansible-only runs do not execute concurrently on the same branch/default branch lane.

`cancel-in-progress: true` is enabled, so the latest event supersedes older in-flight orchestrator runs in the same lane.

Cancellation implication for Terraform Cloud applies:

- GitHub job cancellation stops further workflow steps immediately.
- A Terraform Cloud run already created before cancellation may continue server-side.
- Treat a canceled superseded run as non-authoritative and use the latest surviving run for decisioning and post-apply orchestration.

Operator procedure when a superseded orchestrator run may have started TFC apply:

1. Identify the canceled GitHub run and capture its TFC run id from the `Create Terraform Cloud Infra Run` step logs.
2. Open the TFC run and check status.
3. If TFC run is still planning/applying and a newer orchestrator run has not yet created a replacement TFC run, let the original TFC run finish, then continue with the latest orchestrator lane.
4. If a newer orchestrator run already created a replacement TFC run for the same workspace, cancel the older TFC run in TFC to avoid duplicate applies.
5. Record the final authoritative run id in the deployment notes and continue only from that surviving run's downstream stages.
