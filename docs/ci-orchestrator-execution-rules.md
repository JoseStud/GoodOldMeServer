# CI Orchestrator Execution Rules

This document is the single source of truth for:

- validation entry points in `.github/workflows/validate-planner-contracts.yml`, `.github/workflows/validate-terraform.yml`, and `.github/workflows/validate-ansible.yml`
- infra-repo push and dispatch execution in `.github/workflows/orchestrator.yml`

## Validation Behavior

Validation is split by concern:

- `validate-planner-contracts.yml`: bootstrap-query-tools smoke and trusted stacks SHA verification for current `HEAD:stacks`
- `validate-terraform.yml`: `terraform fmt`, multi-root `terraform validate`, fixed Terraform Cloud speculative run for `terraform/infra`, and shadow Portainer plan checks
- `validate-ansible.yml`: ansible lint + syntax checks

All validation workflows run on `pull_request` and path-filtered `push`, including pushes to `main`.

## Orchestrator Event Behavior

`orchestrator.yml` computes execution toggles in a single inline job: `compute-context`.

### `push`

- `stacks_sha` is resolved from `HEAD:stacks`
- Default path: infra + ansible + portainer
- If every changed file is under `ansible/**` or equals `.ansible-lint`, skip infra apply
- Optional ansible phase tags are derived from changed role paths

### `workflow_dispatch`

- Runs infra + ansible + portainer
- If `ansible_only=true`, infra apply is skipped

### `repository_dispatch` (`stacks-redeploy-intent-v5`)

- Runs portainer + host sync + config sync + health-gated redeploy
- Dispatch payload is validated inline (`schema_version=v5`, strict key set, SHA/reason/source field checks)

## Runtime Job Chain

Top-level chain:

- `compute-context`
- `preflight`
- `infra`
- `ansible`
- `portainer`

Execution is serialized through this chain, with gating handled by per-job `if` conditions and `needs` checks.

## Trusted `stacks_sha` Boundary

`reusable-orch-preflight.yml` verifies trusted stacks SHA before any downstream stack-consuming stage mutates infrastructure.

This trust boundary applies to:

- runtime sync
- config sync
- Portainer apply SHA pinning
- health-gated webhook redeploy

## Concurrency

All orchestrator event paths share one concurrency group (`infra-orchestrator-*`), so full infra runs and ansible-only runs do not execute concurrently on the same branch/default branch lane.
