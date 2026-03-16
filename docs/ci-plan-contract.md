# CI Plan Contract

This document defines the canonical execution-context contract produced by the top-level orchestrator job in `.github/workflows/orchestrator.yml`.

## Source Of Truth

Execution context is computed inline by the `compute-context` job in `.github/workflows/orchestrator.yml`.

There is no `plan_json` object and no separate planner workflow.

## Canonical Outputs

The `compute-context` job emits these outputs (all as strings):

- `run_infra_apply` (`true`/`false`)
- `run_ansible_bootstrap` (`true`/`false`)
- `run_portainer_apply` (`true`/`false`)
- `run_host_sync` (`true`/`false`)
- `run_config_sync` (`true`/`false`)
- `run_health_redeploy` (`true`/`false`)
- `has_work` (`true`/`false`)
- `stacks_sha` (40-char lowercase hex when present)
- `ansible_tags` (optional comma-separated Ansible tags)
- `reason` (non-empty reason string)

Downstream reusable workflows consume typed booleans/strings via explicit workflow inputs.

## Event Semantics

### `push`

- `stacks_sha` is resolved from `HEAD:stacks`
- Baseline path: `run_infra_apply=true`, `run_ansible_bootstrap=true`, `run_portainer_apply=true`
- If every changed file is under `ansible/**` or equals `.ansible-lint`, then `run_infra_apply=false`
- `reason=infra-repo-push`

### `workflow_dispatch`

- `stacks_sha` is resolved from `HEAD:stacks`
- Baseline path: `run_infra_apply=true`, `run_ansible_bootstrap=true`, `run_portainer_apply=true`
- If input `ansible_only=true`, then `run_infra_apply=false`
- `reason=manual-dispatch`

### `repository_dispatch` (`stacks-redeploy-intent-v5`)

- `run_portainer_apply=true`
- `run_host_sync=true`
- `run_config_sync=true`
- `run_health_redeploy=true`
- `run_infra_apply=false`
- `run_ansible_bootstrap=false`
- `stacks_sha` comes from dispatch payload
- `reason` comes from dispatch payload

## Dispatch Payload Validation

`repository_dispatch` payload validation happens inline in `compute-context` and enforces:

- Payload is a JSON object
- Keys are exactly: `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, `reason`
- `schema_version == v5`
- `stacks_sha` and `source_sha` are 40-char lowercase hex
- `source_repo` matches `owner/repo`
- `source_run_id` is numeric
- `reason == full-reconcile`

## Ansible Tag Computation

For ansible-only pushes, `ansible_tags` is computed only when all changed files are under `ansible/roles/**`.

Role path to phase tag mapping:

- `ansible/roles/system_user/` -> `phase1_base`
- `ansible/roles/storage/` -> `phase1_base`
- `ansible/roles/docker/` -> `phase2_docker`
- `ansible/roles/tailscale/` -> `phase3_tailscale`
- `ansible/roles/glusterfs/` -> `phase4_glusterfs`
- `ansible/roles/swarm/` -> `phase5_swarm`
- `ansible/roles/portainer_bootstrap/` -> `phase6_portainer`
- `ansible/roles/runtime_sync/` -> `phase7_runtime_sync`

If role mapping is not applicable, `ansible_tags` is empty and bootstrap runs full scope.

## Workflow Wiring

Current top-level orchestration chain:

- `compute-context`
- `preflight`
- `infra`
- `ansible`
- `portainer`

`preflight`, `infra`, `ansible`, and `portainer` are reusable workflows that consume explicit typed inputs, not a schema-threaded JSON plan object.
