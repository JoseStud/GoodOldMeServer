# CI Plan Contract

This document defines the canonical CI planning contract emitted by:

- `.github/scripts/plan/resolve_ci_plan.sh`
- `.github/workflows/reusable-resolve-plan.yml`

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
  - Optional: `meta.ansible_tags` — an array of Ansible tag strings that callers may set to scope `reusable-orch-ansible.yml` runs (for example to run a subset of bootstrap tasks).

## Event Semantics

- `push`: any eligible infra-repo push resolves to the same infra-side reconcile path: `run_infra_apply=true`, `run_ansible_bootstrap=true`, `run_portainer_apply=true`, with `meta.stacks_sha` resolved from `HEAD:stacks` so the current infra-repo gitlink becomes the Portainer deployment pin.
- `repository_dispatch`: accepts only `stacks-redeploy-intent-v5` with the minimal `v5` payload and always resolves to the full stacks reconcile path.
- `resolve_ci_plan.sh` meta mode accepts only `push` and `repository_dispatch`. Any other event name is invalid.

## Workflow Consumption

Active workflows consume `plan_json` directly with `fromJSON(...)`.

- `.github/workflows/infra-orchestrator.yml` passes `plan_json` unchanged into its reusable stage workflows
- `.github/workflows/reusable-orch-*.yml` read toggles and stage gates directly from `fromJSON(inputs.plan_json)`
- no scalar projection script remains in the active workflow graph

Note: reusable workflows perform defensive validation of `inputs.plan_json` at the start of each stage. The validation checks that the input is valid JSON and that, if present, `plan_schema_version` matches the expected value (`ci-plan-v1`). Callers should ensure `plan_json` is well-formed (for example by invoking the reusable `reusable-resolve-plan.yml` which emits a canonical `plan_json`); workflows also gracefully handle empty outputs by falling back to an empty JSON object for parsing.
