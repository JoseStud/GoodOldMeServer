# ci-change-classification Specification

## Purpose
Turn a GitHub event for the orchestrator workflow into stage run-toggles, a resolved stacks submodule SHA, optional Ansible phase tags and a reason string. This is the `compute-context` job (`python3 -m ci_pipeline.context` in `ci/src`, implemented in `ci/src/ci_pipeline/context.py`), and its outputs are the contract that all later orchestrator jobs read.

## Requirements

### Requirement: Supported Events
The classifier SHALL accept only the `push` and `workflow_dispatch` events, read from the `EVENT_NAME` environment variable. It MUST exit with status 1 and write an error to stderr, without emitting any outputs, when `EVENT_NAME` is empty or names any other event.

#### Scenario: Missing event name
- **WHEN** the classifier runs with `EVENT_NAME` unset or empty
- **THEN** it prints `EVENT_NAME is required` to stderr and exits with status 1

#### Scenario: Unsupported event
- **WHEN** the classifier runs with `EVENT_NAME=schedule` (or any value other than `push` and `workflow_dispatch`)
- **THEN** it prints `Unsupported event: schedule` to stderr and exits with status 1
- **AND** no `key=value` outputs are written

### Requirement: Stacks Gitlink SHA Resolution
For `push` and `workflow_dispatch`, the classifier SHALL resolve `stacks_sha` with `git rev-parse HEAD:stacks` before any change classification. It MUST exit with status 1 when the lookup fails or returns anything other than a 40-character lowercase hexadecimal SHA. The `compute-context` job checks out the repository with `fetch-depth: 0` before it runs.

#### Scenario: Gitlink resolved
- **WHEN** `git rev-parse HEAD:stacks` returns a 40-character lowercase hex commit SHA
- **THEN** that SHA is emitted as `stacks_sha` for every classification outcome, including the metadata-only no-op

#### Scenario: Gitlink lookup fails
- **WHEN** `git rev-parse HEAD:stacks` exits non-zero
- **THEN** the classifier prints `Failed to resolve stacks gitlink SHA from HEAD:stacks.` to stderr and exits with status 1

#### Scenario: Malformed gitlink value
- **WHEN** `git rev-parse HEAD:stacks` returns a value that does not match `^[0-9a-f]{40}$`
- **THEN** the classifier prints `Invalid stacks SHA: <value>` to stderr and exits with status 1

### Requirement: Push Changed-File Detection
On `push`, the classifier SHALL list changed files with `git diff --name-only $PUSH_BEFORE $PUSH_SHA`. It SHALL use an empty list when `PUSH_BEFORE` is empty or 40 zeros, when `PUSH_SHA` is empty, or when `git diff` exits non-zero. An empty list matches no narrower class and SHALL fall through to the full-run classification.

#### Scenario: New branch or initial push
- **WHEN** a push arrives with `PUSH_BEFORE` equal to `0000000000000000000000000000000000000000` or empty
- **THEN** no diff is computed
- **AND** the push is classified as a full run (`run_infra_apply`, `run_ansible_bootstrap` and `run_portainer_apply` are `true`, `reason=infra-repo-push`)

#### Scenario: Unreachable before SHA
- **WHEN** `git diff --name-only` fails, for example because the before SHA is not in the local history
- **THEN** the changed-file list is empty and the push is classified as a full run

### Requirement: Push Classification Precedence
Push classification SHALL be evaluated in a fixed order: metadata-only, then stacks-SHA bump, then ansible-only, then the full-run fallback. The first class that matches SHALL decide every toggle. The full-run fallback SHALL set `run_infra_apply`, `run_ansible_bootstrap` and `run_portainer_apply` to `true`, the other toggles to `false`, `ansible_tags` empty and `reason=infra-repo-push`.

#### Scenario: Lint config alone is metadata, not ansible-only
- **WHEN** the only changed file is `.ansible-lint`
- **THEN** the push is classified as metadata-only, even though `.ansible-lint` also qualifies as ansible-only

#### Scenario: Mixed classes fall back to a full run
- **WHEN** the changed files are `stacks` and `docs/x.md`, or `ansible/roles/docker/tasks/main.yml` and `terraform/infra/main.tf`
- **THEN** the push is classified as a full run with `reason=infra-repo-push`
- **AND** `run_host_sync`, `run_config_sync` and `run_health_redeploy` are `false`

### Requirement: Metadata-Only Push
A push whose changed files all start with `docs/`, `.github/` or `ci/`, or equal `.ansible-lint`, SHALL set all six run toggles to `false`, emit `has_work=false`, and set `reason=infra-repo-metadata-only`. A Markdown file outside those prefixes MUST NOT count as metadata.

#### Scenario: Docs and workflow edits
- **WHEN** the changed files are `docs/ci-plan-contract.md`, `.ansible-lint` and `.github/workflows/orchestrator.yml`
- **THEN** every run toggle is `false`, `has_work=false` and `reason=infra-repo-metadata-only`

#### Scenario: Markdown outside metadata prefixes
- **WHEN** the only changed file is `terraform/infra/NOTES.md`
- **THEN** the push is not metadata-only and is classified as a full run

### Requirement: Stacks SHA Bump Push
A push whose changed files include `stacks` and contain nothing besides `stacks` and `.gitmodules` SHALL set `run_portainer_apply`, `run_host_sync`, `run_config_sync` and `run_health_redeploy` to `true`, set `run_infra_apply` and `run_ansible_bootstrap` to `false`, leave `ansible_tags` empty, and set `reason=infra-repo-stacks-sha-bump`.

#### Scenario: Gitlink-only push
- **WHEN** the changed files are `stacks`, or `stacks` and `.gitmodules`
- **THEN** the context enables Portainer apply, host sync, config sync and health redeploy, skips infra apply and Ansible bootstrap, and sets `has_work=true`

#### Scenario: Submodule config without a gitlink change
- **WHEN** the only changed file is `.gitmodules`
- **THEN** the push is not a stacks SHA bump and is classified as a full run

### Requirement: Ansible-Only Push
A push whose changed files all start with `ansible/` or equal `.ansible-lint`, and that is neither metadata-only nor a stacks SHA bump, SHALL set `run_ansible_bootstrap` and `run_portainer_apply` to `true`, all other run toggles to `false`, and `reason=infra-repo-push`, with `ansible_tags` derived from the changed role paths.

#### Scenario: Role change skips infra apply
- **WHEN** the only changed file is `ansible/roles/docker/tasks/main.yml`
- **THEN** `run_infra_apply=false`, `run_ansible_bootstrap=true`, `run_portainer_apply=true` and `ansible_tags=phase2_docker`

#### Scenario: Playbook change runs a full-scope bootstrap
- **WHEN** the only changed file is `ansible/playbooks/provision.yml`
- **THEN** the push is ansible-only with `run_infra_apply=false` and an empty `ansible_tags`

### Requirement: Ansible Phase Tag Mapping
For an ansible-only push, `ansible_tags` SHALL be the comma-joined unique phase tags of the changed roles, in first-seen order, per this map under `ansible/roles/`: `system_user/`, `storage/` → `phase1_base`; `docker/` → `phase2_docker`; `tailscale/` → `phase3_tailscale`; `glusterfs/` → `phase4_glusterfs`; `swarm/` → `phase5_swarm`; `portainer_bootstrap/` → `phase6_portainer`; `runtime_sync/` → `phase7_runtime_sync`. Any changed file outside these paths SHALL make it empty.

#### Scenario: Several roles map to tags
- **WHEN** the changed files are under `ansible/roles/glusterfs/` and `ansible/roles/runtime_sync/`
- **THEN** `ansible_tags=phase4_glusterfs,phase7_runtime_sync`

#### Scenario: Roles sharing a phase are de-duplicated
- **WHEN** the changed files are under `ansible/roles/system_user/` and `ansible/roles/storage/`
- **THEN** `ansible_tags=phase1_base`

#### Scenario: Unmapped path empties the tags
- **WHEN** any changed file is outside `ansible/roles/` (including `.ansible-lint` or a playbook) or under a role not in the map
- **THEN** `ansible_tags` is empty, which downstream means a full-scope bootstrap

### Requirement: Manual Dispatch Toggles
On `workflow_dispatch` the classifier SHALL NOT inspect changed files. It SHALL set `run_portainer_apply=true`, `run_infra_apply` to NOT `ansible_only`, `run_ansible_bootstrap` to NOT `skip_ansible_bootstrap`, `run_health_redeploy` to `force_health_redeploy`, `run_host_sync` and `run_config_sync` to `false`, `ansible_tags` empty and `reason=manual-dispatch`. Each input is true only when its `WORKFLOW_*` variable is exactly `true`.

#### Scenario: Default dispatch
- **WHEN** the workflow is dispatched with all inputs left at their default `false`
- **THEN** `run_infra_apply`, `run_ansible_bootstrap` and `run_portainer_apply` are `true` and `run_health_redeploy` is `false`

#### Scenario: Narrow Portainer retry
- **WHEN** the workflow is dispatched with `ansible_only=true`, `skip_ansible_bootstrap=true` and `force_health_redeploy=true`
- **THEN** `run_infra_apply=false`, `run_ansible_bootstrap=false`, `run_portainer_apply=true` and `run_health_redeploy=true`

#### Scenario: Input wiring from the workflow
- **WHEN** `compute-context` runs
- **THEN** `WORKFLOW_ANSIBLE_ONLY`, `WORKFLOW_FORCE_HEALTH_REDEPLOY` and `WORKFLOW_SKIP_ANSIBLE_BOOTSTRAP` are set to `github.event_name == 'workflow_dispatch' && inputs.<name>`
- **AND** a value such as `True` or `1` counts as false

### Requirement: Context Output Emission
The classifier SHALL emit ten `key=value` lines: `run_infra_apply`, `run_ansible_bootstrap`, `run_portainer_apply`, `run_host_sync`, `run_config_sync`, `run_health_redeploy`, `has_work`, `stacks_sha`, `ansible_tags`, `reason`. Booleans are lowercase `true`/`false`, and `has_work` is `true` exactly when at least one of the six run toggles is `true`. Lines go to the file named by `GITHUB_OUTPUT` when set, otherwise to stdout.

#### Scenario: GitHub Actions mode
- **WHEN** `GITHUB_OUTPUT` is set
- **THEN** the ten lines are appended to that file and become outputs of the `compute-context` job
- **AND** a single summary line `Context emitted: reason=<reason> has_work=<True|False>` is printed to stdout

#### Scenario: Local mode
- **WHEN** `GITHUB_OUTPUT` is unset
- **THEN** the ten `key=value` lines are printed to stdout and the process exits with status 0
