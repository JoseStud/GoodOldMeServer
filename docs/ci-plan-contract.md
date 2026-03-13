# CI Plan Contract

This document defines the canonical CI planning contract emitted by:

- `.github/scripts/plan/ci_plan/` (Python package — `resolver.py` computes the plan, `dispatch_validator.py` validates dispatch payloads)
- `.github/scripts/plan/resolve_ci_plan.sh` (thin bash wrapper that delegates to `python3 -m ci_plan`)
- `.github/workflows/reusable-resolve-plan.yml`

## Implementation

Plan resolution is implemented as a Python package (`ci_plan`) located at `.github/scripts/plan/ci_plan/`. The package has zero runtime dependencies (stdlib-only, Python >= 3.12) and is installed via `pip install .github/scripts/plan/` in CI workflows.

Key modules:

| Module | Responsibility |
|--------|----------------|
| `models.py` | Frozen dataclasses for `CIPlan`, `MetaPlan`, `Stages`, `ResolveContext`; JSON serialization via `CIPlan.to_json()` |
| `rules.py` | Declarative `ROLE_PHASE_MAP` dict mapping Ansible role paths to phase tags, and `ANSIBLE_ONLY_PATTERNS` for push classification |
| `resolver.py` | Core logic: `resolve_meta_plan()`, `is_ansible_only()`, `compute_ansible_tags()`, `derive_stages()` |
| `dispatch_validator.py` | Dispatch payload validation (schema version, SHA format, reason, source fields, removed field rejection) |
| `git.py` | `GitInterface` protocol with `RealGit` subprocess implementation; enables `FakeGit` injection in tests |
| `github_actions.py` | `emit_output()` writes to `$GITHUB_OUTPUT`; `read_env_context()` builds `ResolveContext` from env vars |
| `__main__.py` | CLI entry point: `python3 -m ci_plan` (CI mode) or `python3 -m ci_plan --local` (stdout mode) |

Tests are in `.github/scripts/plan/tests/` and run via `pytest`. Install with: `pip install '.github/scripts/plan/[dev]'`

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
  - Optional: `meta.ansible_tags` — a comma-separated string of Ansible tag names that callers may set to scope `reusable-orch-ansible.yml` runs (for example to run a subset of bootstrap tasks).

## Event Semantics

- `push`: any eligible infra-repo push resolves to the same infra-side reconcile path: `run_infra_apply=true`, `run_ansible_bootstrap=true`, `run_portainer_apply=true`, with `meta.stacks_sha` resolved from `HEAD:stacks` so the current infra-repo gitlink becomes the Portainer deployment pin. Ansible-only pushes (all changes under `ansible/**` or `.ansible-lint`) skip `run_infra_apply` and compute fine-grained `ansible_tags` from changed role paths.
- `workflow_dispatch`: resolves `stacks_sha` from `HEAD:stacks` and runs the full infra-side reconcile path (`reason=manual-dispatch`). The optional `ansible_only` input skips TFC infra-apply.
- `dispatch_ansible_only`: same as `workflow_dispatch` with `ansible_only=true` — skips infra apply, runs ansible bootstrap + portainer.
- `repository_dispatch`: accepts only `stacks-redeploy-intent-v5` with the minimal `v5` payload and always resolves to the full stacks reconcile path.

## Dispatch Payload Validation

Dispatch payload validation is performed inline by the Python resolver when `VALIDATE_DISPATCH_CONTRACT=true` (the default). The validation enforces:

- `schema_version` must be `"v5"`
- `stacks_sha` and `source_sha` must be 40-character lowercase hex
- `reason` must be `"full-reconcile"`
- `source_repo` must match `owner/repo` format
- `source_run_id` must be numeric
- Payload JSON must contain exactly these keys: `schema_version`, `stacks_sha`, `source_sha`, `source_repo`, `source_run_id`, `reason`
- Removed fields (`changed_stacks`, `host_sync_stacks`, `config_stacks`, `structural_change`, `changed_paths`) are rejected

## Phase Tag Computation

For ansible-only pushes, the resolver maps changed role paths to phase tags using a declarative dictionary (`rules.py:ROLE_PHASE_MAP`):

| Role path prefix | Phase tag |
|-----------------|-----------|
| `ansible/roles/system_user/` | `phase1_base` |
| `ansible/roles/storage/` | `phase1_base` |
| `ansible/roles/docker/` | `phase2_docker` |
| `ansible/roles/tailscale/` | `phase3_tailscale` |
| `ansible/roles/glusterfs/` | `phase4_glusterfs` |
| `ansible/roles/swarm/` | `phase5_swarm` |
| `ansible/roles/portainer_bootstrap/` | `phase6_portainer` |
| `ansible/roles/runtime_sync/` | `phase7_runtime_sync` |

Changes outside `ansible/roles/` (playbooks, group_vars, host_vars, requirements) or to unrecognised roles fall back to a full bootstrap (empty `ansible_tags`).

## Stage Derivation

Stage flags are derived from execution toggles by pure boolean formulas in `resolver.py:derive_stages()`:

- `stage_cloud_runner_guard` = `has_work`
- `stage_secret_validation` = `has_work`
- `stage_network_policy_sync` = `has_work`
- `stage_infra_apply` = `run_infra_apply`
- `stage_inventory_handover` = `run_ansible_bootstrap` OR `run_host_sync` OR `run_config_sync`
- `stage_network_preflight_ssh` = `stage_inventory_handover`
- `stage_ansible_bootstrap` = `run_ansible_bootstrap`
- `stage_host_sync` = `run_host_sync` AND NOT `run_ansible_bootstrap` (mutually exclusive)
- `stage_post_bootstrap_secret_check` = `run_portainer_apply`
- `stage_portainer_api_preflight` = `run_portainer_apply` OR `run_health_redeploy`
- `stage_portainer_apply` = `run_portainer_apply`
- `stage_config_sync` = `run_config_sync`
- `stage_health_gated_redeploy` = `run_health_redeploy`

## Workflow Consumption

Active workflows consume `plan_json` directly with `fromJSON(...)`.

- `.github/workflows/orchestrator.yml` passes `plan_json` unchanged into its reusable stage workflows
- `.github/workflows/reusable-orch-*.yml` read toggles and stage gates directly from `fromJSON(inputs.plan_json)`
- no scalar projection script remains in the active workflow graph

Note: reusable workflows perform defensive validation of `inputs.plan_json` at the start of each stage. The validation checks that the input is valid JSON and that, if present, `plan_schema_version` matches the expected value (`ci-plan-v1`). Callers should ensure `plan_json` is well-formed (for example by invoking the reusable `reusable-resolve-plan.yml` which emits a canonical `plan_json`); workflows also gracefully handle empty outputs by falling back to an empty JSON object for parsing.

## Testing

The plan resolver has a comprehensive pytest suite at `.github/scripts/plan/tests/`:

- `test_resolver.py` — event routing, flag computation, edge cases (null SHA, empty diff, git failure)
- `test_dispatch_validator.py` — payload validation positive/negative cases
- `test_phase_detection.py` — role-to-phase mapping and ansible-only classification
- `test_stage_derivation.py` — exhaustive stage flag derivation across all event types
- `test_output_format.py` — JSON serialization format, key ordering, boolean types

Run locally: `cd .github/scripts/plan && pip install -e '.[dev]' && pytest tests/ -v`

Stage exhaustiveness is also verified by `test_stage_exhaustiveness.sh`, which reads all stage field names from the Python `Stages` dataclass and checks that each appears in a reusable workflow `if:` condition.
