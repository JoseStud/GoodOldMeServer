# Design

## Context

See proposal.md (Why) for the defect. These facts shape the fix:

- Phase tags sit only on dynamic `include_role`/`include_tasks` statements (`ansible/playbooks/provision.yml:24-135`). No role task carries tags (`grep -n tags ansible/roles` finds only a comment in `sync-configs.yml:3`).
- Two consumers depend on tags:
  - The orchestrator. Host sync is forced to `phase7_runtime_sync` (`ci/src/ci_pipeline/__main__.py:148-150`), config sync uses `sync-configs` (`:172-178`), and ansible-only pushes take their tags from `ROLE_PHASE_MAP` (`ci/src/ci_pipeline/context.py:21-30,187-196`). The runner passes `--tags` through (`.github/scripts/stages/ansible_run.sh:173-175`).
  - The local/break-glass commands in `docs/ansible.md:123-132`, `docs/deployment-runbook.md:114-119,170-173`, `docs/stacks.md:192,202` and `docs/infisical-workflow.md:353`.

  **This change affects both paths.**
- `service_user`, `service_uid`, `service_group` and `service_gid` are defined four times, with the same values, in role defaults: `system_user`, `storage`, `docker` and `glusterfs`, each `defaults/main.yml:2-5` (glusterfs `:2-3`). `sync-configs.yml` sees them only through `public: true` on the glusterfs include (`provision.yml:109`).
- Roles live in `ansible/roles`, a sibling of the playbook directory. Only the CI runner sets `ANSIBLE_ROLES_PATH=ansible/roles` (`ansible_run.sh:183`). Neither `ansible/ansible.cfg` nor `validate-ansible.yml` sets a roles path. As a result the documented repo-root commands fail at runtime on the first include with `the role '<name>' was not found`. This was checked with ansible-core 2.20.2 on a playbook with the same layout and no roles path. The CI syntax check (`validate-ansible.yml:72-82`) passes only because dynamic includes are never resolved during parsing.
- Behaviour check with ansible-core 2.20.2 (the pinned version), on a synthetic playbook with the same shape:

  | Variant | `--tags phase7_runtime_sync` | `--tags sync-configs` | `--list-tasks` shows role tasks |
  |---|---|---|---|
  | include, no `apply` (today) | no role task runs | no task runs | no |
  | include + `apply: {tags}` | tasks and handler run | fails: `service_user` undefined | no, only the include stub |
  | `import_role` / `import_tasks` | tasks and handler run | tasks run | yes |

## Goals / Non-Goals

**Goals:**
- A phase tag runs exactly the role tasks and handlers of that phase, both in CI and in local runs. Tag names and the full-run task order stay unchanged.
- Every tag-filtered path, including `sync-configs` alone, can resolve the shared service-account variables.
- A regression check that needs no hosts and no secrets fails whenever a tag stops reaching its role, or whenever a role has no phase mapping.

**Non-Goals:**
- Stopping the agent restart that every phase-7 run causes (rsync puts back the un-injected `*.tmpl` files, `runtime_sync/tasks/main.yml:46-91`). That belongs to host-runtime-sync and is a separate change.
- Any change to which tags the pipeline chooses (`__main__.py`), to SSH transport, to Portainer bootstrap behaviour, or to stack pinning.
- Making Validate Ansible a required check that gates the orchestrator. That is branch-protection policy (see Open Questions).

## Decisions

### D1. Static `import_role` for every phase, instead of `include_role` + `apply`

Each `include_role` in `provision.yml` becomes `ansible.builtin.import_role` with the same `name` and `tags`.

- **Tag inheritance is structural.** Imported tasks and handlers inherit the statement's tags, so nothing has to be repeated. With `apply`, every tag list appears twice, on the statement and in `apply.tags`, and the two copies can drift silently.
- **Listings become truthful.** `--list-tasks` and `--list-tags` show the real role tasks. That is what makes the hostless regression check in D5 possible. For dynamic includes, even with `apply`, `--list-tasks` shows only the include stub, so a behavioural check would need real hosts.
- **The syntax check gets stronger.** The roles' task files are parsed, so a missing role or an unresolvable module fails in Validate Ansible instead of halfway through a live run.

The import semantics were checked one by one:
- **`when:` (phase 6).** On an import, the condition is copied onto every imported task. `inventory_hostname == groups['oci_nodes'][0]` is constant per host, and every `portainer_bootstrap` task already carries the same guard. Other hosts therefore still skip the whole role, now with one "skipping" line per task instead of a single skipped include.
- **`public`.** `import_role` exposes role defaults and vars to the whole play when the playbook is parsed (`DEFAULT_PRIVATE_ROLE_VARS=False`), so the glusterfs `public: true` is no longer needed and is dropped. A collision audit of every role's defaults found no shared keys other than the `service_*` set, which D3 moves into group_vars. The other defaults are `block_device`, `block_device_partition`, `mount_point`, `portainer_*`, `infisical_project_id` and `runtime_sync_*`, and none of them is used outside its own role.
- **Handlers.** `Restart infisical agent` is imported with the role and runs when notified under `--tags phase7_runtime_sync` (verified).
- **`strategy: free`, loops, dynamic role names.** Plays 1 and 2 use `strategy: free`, which imports do not affect. No include uses a loop or a templated role name, so nothing needs dynamic behaviour.

**Alternative: `include_role` with `apply: {tags: [...]}`.** It keeps the dynamic includes and their `when:`, and it works at runtime. It was rejected for three reasons. It duplicates every tag list. It leaves `--list-tasks` blind, so the only hostless guard left would be a structural lint ("every tagged include has matching `apply.tags`"), which checks a pattern rather than behaviour. And on its own it still fails `--tags sync-configs` on the undefined variable.

### D2. Config sync via `import_role: {name: glusterfs, tasks_from: sync-configs}`

This replaces `include_tasks: {file: ../roles/glusterfs/tasks/sync-configs.yml}` and keeps the tags `[phase4_glusterfs, sync-configs]`. The tasks keep their glusterfs role context, so listings show them as `glusterfs : Sync ...`. The scoping check uses that to tell sync tasks from main-role tasks. Copy sources are absolute (`{{ playbook_dir }}/../../stacks/...`), so loading the file from the role directory changes nothing. Importing the glusterfs role twice in one play, with different `tasks_from`, runs both task sets; that was verified, and neither import is de-duplicated.

**Alternative: `import_tasks` with the same file path.** It also inherits tags. It was rejected because it loses the role label that the check relies on, and it keeps the cross-directory path.

### D3. Shared service-account variables in `ansible/playbooks/group_vars/all.yml`

`service_user: media-srv`, `service_uid: 1500`, `service_group: media-srv` and `service_gid: 1500` move into the new file. The four duplicate copies are deleted from role defaults: the `system_user`, `docker` and `glusterfs` defaults files become empty and are removed, and `storage/defaults/main.yml` keeps only its block-device keys.

- **Why next to the playbook.** Group vars next to the inventory would not work for both paths, because CI's inventory is a rendered file at the repository root (`inventory-ci.yml`) and the local one is `ansible/inventory/terraform.yml`. Group vars next to the playbook load for any `-i` (checked with `ansible-inventory --playbook-dir`). They also take precedence over role defaults while `-e` can still override them.
- **Alternative: play-level `vars:`.** This would repeat the four variables in three plays. Rejected.
- **Alternative: keep the role defaults as a fallback.** This keeps the four duplicate copies that can drift, and imports make all of them play-visible anyway. Rejected: there is one playbook, and it is the only entry point.

### D4. Roles resolved from `ansible/roles` at every entry point

Imports need roles at parse time.

- **CI runner.** It already sets `ANSIBLE_ROLES_PATH=ansible/roles`.
- **`validate-ansible.yml`.** Job-level `env: ANSIBLE_ROLES_PATH: ansible/roles`. Without it, ansible-lint reports `syntax-check[specific]: the role 'system_user' was not found` and the syntax check fails; both verified. With it, ansible-lint 26.1.1 passes the import-based tree under profile `basic`.
- **`ansible/ansible.cfg`.** Gains `roles_path = roles`, resolved relative to the config file, for runs from `ansible/`. This adds a setting and leaves the existing ones as `Local Operator Configuration` describes them.
- **Docs.** Repo-root commands gain an `ANSIBLE_ROLES_PATH=ansible/roles` prefix, mirroring the runner.

**Alternative: a symlink `ansible/playbooks/roles -> ../roles`.** It needs no configuration, but it is an unusual layout in a public repo and could make linters walk the roles twice. Rejected.

**Alternative: path-style role names (`name: ../roles/x`).** These tie every import to a relative path. Rejected.

### D5. Hostless tag-scoping check: `.github/scripts/ansible/check_tag_scoping.py`

A stdlib-only Python script, run in Validate Ansible after the syntax check. Its steps:
1. Read `ROLE_PHASE_MAP` from `ci/src/ci_pipeline/context.py` with `ast`. This avoids importing the `ci` package and its dependencies, and the map stays the single source of truth for which role a tag must reach.
2. Fail if any directory under `ansible/roles/` lacks a key.
3. For each distinct tag, run `ansible-playbook -i /tmp/ansible-syntax.ini --list-tasks --tags <tag> ansible/playbooks/provision.yml` and parse lines of the form `<role> : <task>`. Fail when a mapped role has no listed task.
4. For `sync-configs`, require `glusterfs : Sync Authelia configuration to GlusterFS` and forbid `glusterfs : Install GlusterFS server`.

`ci/src/ci_pipeline/context.py` is added to Validate Ansible's push and pull_request path filters, so a map-only edit is still checked. The orchestrator classifies such an edit as metadata-only (`ci/` prefix), so it never deploys anything.

The localhost syntax inventory puts `localhost` in both groups. Listing therefore covers both bootstrap plays: `storage` is listed only in play 1, and the witness roles in play 2. Collections are already installed by the job before this step (`validate-ansible.yml:67`).

**Alternative: pytest in `ci/tests`.** No workflow runs `ci/` pytest today, so it would gate nothing. A unit test for the `infisical_cli` mapping is still added there.

**Alternative: a real run against a container.** Too heavy for the value it adds; the list-based check already tests the property that broke.

### D6. `ansible/roles/infisical_cli/` → `phase1_base` in `ROLE_PHASE_MAP`

`infisical_cli` is imported under `phase1_base` in both bootstrap plays (`provision.yml:34-37,78-81`). With the map entry, a change to it runs phase 1 instead of a full-scope bootstrap. The check in D5 makes any future unmapped role fail validation.

## Risks / Trade-offs

- **[Tagged CI runs now mutate hosts]** Every stacks-SHA bump restarts `infisical-agent` on all three nodes, may redeploy `management` from the primary manager, and overwrites the GlusterFS config files. An ansible-only push now runs its role everywhere. → This is the intended behaviour, and it is what the docs already promise (`docs/deployment-runbook.md:345`). The recommended rollout in the Migration Plan absorbs the accumulated drift in one supervised untagged run before the first tagged bump.
- **[Agent restarts on every phase-7 run]** These come from the existing rsync and injection loop, and they now happen on every bump instead of only on full runs. → Out of scope here. It is listed as a follow-up for host-runtime-sync (see Open Questions). The restart is cheap, and the agent re-renders idempotently, apart from the `management` deploy.
- **[rsync `--delete` removes agent-rendered `*.rendered.yml` under `/opt/stacks`]** This is existing behaviour, now more frequent. → The files are re-rendered after the agent restart that the same run triggers, and the GlusterFS copies made by the helpers stay in place.
- **[Parse-time dependency on roles and collections]** A run without them fails before contacting any host. → The runner installs collections before the playbook (`ansible_run.sh:160-166`) and sets the roles path (`:183`). Validate Ansible installs both (D4). The docs show the local prefix. Failing early is safer than failing halfway through a run.
- **[Play-wide role defaults with imports]** A future unprefixed default could collide across roles, and `var-naming[no-role-prefix]` is skipped in `.ansible-lint`. → Today's keys were audited (D1). Reviewers should keep new defaults role-prefixed.
- **[Phase-6-only runs]** Under `--tags phase6_portainer` the swarm role does not run, so `ts_ip` is undefined and the `PORTAINER_API_URL` write is skipped by its guard (`portainer_bootstrap/tasks/main.yml:505-521`). The same would happen with `apply`. → Accepted. Full runs and phase 5+6 runs still write it. This is noted for `harden-portainer-bootstrap`.
- **[Validate Ansible does not gate the orchestrator]** A broken push to `main` still deploys. → The check catches regressions on pull requests and branch pushes. Gating is an owner decision.

## Migration Plan

The recommended rollout uses three pushes to `main`, so no step triggers an infra apply:

1. **Metadata-only push** (`.github/`, `ci/`). Add job-level `ANSIBLE_ROLES_PATH` to `validate-ansible.yml`, add the `infisical_cli` map entry and its unit test, and run `pytest` in `ci/`. The orchestrator classifies this as `infra-repo-metadata-only` and runs nothing. The new map entry is harmless before step 2: until then, tags still reach no role task.
2. **Ansible-only push** (`ansible/`). Changes the playbook imports, adds `group_vars/all.yml`, removes the duplicate role defaults and adds `roles_path` to `ansible.cfg`. Because `provision.yml` changed, the classifier emits empty `ansible_tags`. The result is an untagged bootstrap plus a Portainer apply on all nodes, with no infra apply. This run catches up the drift from earlier bumps (proposal, Impact). Watch the run, and confirm that `runtime_sync :` and `glusterfs : Sync ...` tasks report `ok` or `changed`.
3. **Metadata-only push** (`.github/`, `docs/`). Adds the scoping-check script, its workflow step and the `context.py` path filter, plus the docs updates. Validate Ansible must pass on the branch before merge.

Merging everything as one PR also works. It classifies as a full run, which adds an infra apply that should plan no changes.

Verification:
- Before step 2, on the branch, run `ansible-playbook --list-tasks --tags <tag>` locally (with `ANSIBLE_ROLES_PATH=ansible/roles`) and the scoping-check script.
- After step 2, observe the first real stacks-SHA bump: the host-sync log must list `runtime_sync :` tasks for every host, and the config-sync log must list `glusterfs : Sync ...` on `oci-node-1`.
- `SHADOW_MODE` stops `ansible_run.sh` before `ansible-playbook` runs. A `workflow_dispatch` (`ansible_only=true`) with `vars.SHADOW_MODE=true` can therefore only confirm the runner wiring, collection install and the shadow exit. It cannot confirm tag behaviour.

Rollback: revert the step-2 commit, which restores the include-based playbook and the role defaults; tagged runs go back to doing nothing. Steps 1 and 3 can stay, but the scoping check will then fail Validate Ansible until it is reverted too. Revert steps 3 and 2 together. Host content written in the meantime is the pinned stacks content. To return the hosts to an older stacks commit, revert the gitlink and run an untagged bootstrap (`workflow_dispatch`, `ansible_only=true`).

## Open Questions

- Should Validate Ansible become a required status check for `main`? This is branch protection and does not change this design.
- Follow-up change for host-runtime-sync: make placeholder injection idempotent, for example by injecting on the controller or excluding injected `*.tmpl` files from rsync `--delete` and rewrite. That would stop the per-run agent restart.
- Should `Local Operator Configuration` (node-provisioning) list `roles_path = roles` explicitly? Coordinate with `tailscale-only-ssh`, which may edit the same `ansible.cfg` requirement.
- Should `ci/` pytest run in a workflow? No workflow runs it today.
