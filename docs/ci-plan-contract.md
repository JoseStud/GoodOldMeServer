# CI Plan Contract

This document defines the canonical CI planning contract emitted by:

- `.github/scripts/plan/resolve_ci_plan.sh`
- `.github/workflows/reusable-detect-impact-resolve-plan.yml`

## Canonical Output

The canonical output is `plan_json`. Caller workflows must treat this as source of truth.

Current schema version:

- `plan_schema_version: "ci-plan-v1"`

## Top-Level Shape

All plans share:

- `plan_schema_version` (string)
- `mode` (`meta`)
- `event_name` (string)
- `meta` object

## `meta` Mode Fields

- Execution toggles: `run_infra_apply`, `run_ansible_bootstrap`, `run_portainer_apply`, `run_host_sync`, `run_config_sync`, `run_health_redeploy`, `has_work`
- Context: `stacks_sha`, `reason`
- Stage gates under `meta.stages`:
  - `stage_cloud_runner_guard`
  - `stage_secret_validation`
  - `stage_network_policy_sync`
  - `stage_infra_apply`
  - `stage_inventory_handover`
  - `stage_network_preflight_ssh`
  - `stage_ansible_bootstrap`
  - `stage_host_sync`
  - `stage_post_bootstrap_secret_check`
  - `stage_portainer_api_preflight`
  - `stage_portainer_apply`
  - `stage_config_sync`
  - `stage_health_gated_redeploy`

## Event Semantics

- `push`: uses `meta_*` path filters to derive infra/apply/bootstrap/Portainer apply behavior for infra-repo changes.
- `repository_dispatch`: accepts only `stacks-redeploy-intent-v5` with the minimal `v5` payload and always resolves to the full stacks reconcile path.
- `workflow_dispatch` and `workflow_call`: support manual infra/bootstrap/Portainer operations only. `stacks_sha` is a trusted checkout override, not a stack-selection control.

## Projection Layer

Workflows that need scalar outputs must project them from `plan_json` using:

- `.github/scripts/plan/project_plan_outputs.sh meta`

The projection script validates:

- schema version (`ci-plan-v1`)
- requested mode matches `plan_json.mode`
- required fields exist with expected types

and emits scalar outputs as workflow commands.
