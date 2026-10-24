# Proposal

## Why

Every tag-filtered run of `ansible/playbooks/provision.yml` silently skips the work it was started for. The phase tags sit only on the dynamic `ansible.builtin.include_role` / `include_tasks` statements, with no `apply: { tags: [...] }` (`provision.yml:24-135`), and no task under `ansible/roles/` has tags of its own. Ansible does not pass tags from a dynamic include down to the tasks it includes. So `--tags phase7_runtime_sync`, `--tags sync-configs` or any other phase tag runs only the `always`-tagged wait/setup/ping tasks and the include stubs, and no role task at all. This was reproduced with ansible-core 2.20.2, the version pinned in `.github/ci/tool-versions.lock` and installed by `orchestrator.yml:193`. Only untagged (full) runs converge hosts today. That breaks three paths:

- **Stacks-SHA bumps.** Host sync is forced to `--tags phase7_runtime_sync` (`ci/src/ci_pipeline/__main__.py:148-150`), and config sync runs `--tags sync-configs` (`:172-178`). So `/opt/stacks`, the Infisical agent config and the GlusterFS config files are never updated on a bump. Both runs still report success.
- **Ansible-only pushes.** These pushes get tags from `ROLE_PHASE_MAP` (`ci/src/ci_pipeline/context.py:21-30`), so the changed role never runs. `ansible/roles/infisical_cli/` has no map entry at all, so a change there falls back to a full bootstrap.
- **Operator commands.** The documented `--tags` commands do nothing (`docs/ansible.md:123-132`, `docs/deployment-runbook.md:114-119`).

A second bug is waiting behind the first. `sync-configs.yml:12-13` uses `service_user`/`service_group`, which exist only because the glusterfs include sets `public: true` (`provision.yml:109`) on top of `roles/glusterfs/defaults/main.yml:2-3`. Once tags reach the tasks, a `--tags sync-configs` run fails with `'service_user' is undefined`. This was reproduced.

## What Changes

- Every phase in `provision.yml` becomes a static `ansible.builtin.import_role` that carries its existing phase tag. Imported tasks inherit the tag, so a phase tag runs exactly that phase's role tasks and handlers. Tag names and the full-run order stay the same. Phase 6 keeps `when: inventory_hostname == groups['oci_nodes'][0]`, which Ansible now applies to each imported task.
- Config sync is imported as `import_role: { name: glusterfs, tasks_from: sync-configs }` with tags `phase4_glusterfs` and `sync-configs`. The glusterfs `public: true` is dropped.
- `service_user`, `service_uid`, `service_group` and `service_gid` are defined once, in `ansible/playbooks/group_vars/all.yml`, next to the playbook. They are therefore loaded for both `inventory-ci.yml` (CI) and `ansible/inventory/terraform.yml` (local). The duplicate copies in the `system_user`, `storage`, `docker` and `glusterfs` role defaults are removed.
- Imports resolve roles while the playbook is parsed. Validate Ansible therefore runs ansible-lint and the syntax check with `ANSIBLE_ROLES_PATH=ansible/roles`, as the CI runner already does (`.github/scripts/stages/ansible_run.sh:183`). `ansible/ansible.cfg` gains `roles_path = roles`. The docs' repo-root commands gain the same environment prefix, because without it the documented commands cannot find the roles today either.
- New regression check in Validate Ansible, with no real hosts. It runs `ansible-playbook --list-tasks --tags <tag>` against the existing localhost syntax inventory for each phase tag and for `sync-configs`. It fails unless every role mapped to that tag in `ROLE_PHASE_MAP` shows tasks. It also fails if the `sync-configs` listing has no sync tasks or includes glusterfs server tasks, or if any role directory has no map entry.
- `ROLE_PHASE_MAP` gains `ansible/roles/infisical_cli/` → `phase1_base`.
- No billable resources. No stacks-repo edits are needed.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `node-provisioning`: playbook structure moves from tagged dynamic includes to tag-inheriting static imports. The shared service-account variables get one source that every tag filter can see, and roles are resolved at parse time.
- `shared-storage`: config sync is imported from the glusterfs role, so a `sync-configs`-only run executes the copies and resolves the owner.
- `repository-validation`: lint and syntax check run with the roles path. New phase-tag scoping check.
- `ci-change-classification`: `infisical_cli/` maps to `phase1_base`.

## Impact

- **Code:** `ansible/playbooks/provision.yml`, new `ansible/playbooks/group_vars/all.yml`, role defaults of `system_user`, `storage`, `docker` and `glusterfs`, `ansible/ansible.cfg`, `.github/workflows/validate-ansible.yml`, a new check script under `.github/scripts/ansible/`, `ci/src/ci_pipeline/context.py` and `ci/tests/test_context.py`. Docs: `docs/ansible.md`, `docs/ci-plan-contract.md`, `docs/deployment-runbook.md`, `docs/stacks.md`, `docs/infisical-workflow.md`.
- **Rollout push:** an untagged bootstrap runs the same tasks in the same order as today. The design's recommended three-step rollout puts the `ansible/` part in its own ansible-only push. That push runs an untagged bootstrap and a Portainer apply but no infra apply. Merged as one PR instead, the change spans `ansible/`, `.github/`, `ci/` and `docs/` and classifies as a full run (`infra-repo-push`), which adds an infra apply. Either way, this first untagged run catches up on every stacks bump since the last untagged run, with the effects listed below.
- **Blast radius from then on:** every stacks-SHA bump really runs phase 7 on all three nodes (`oci-node-1`, `oci-node-2`, `gcp-witness`) and `sync-configs` on `groups['oci_nodes'][0]`:
  - `/opt/stacks` is rewritten to the pinned SHA with rsync `--delete`. This also deletes agent-rendered non-`.env` files such as `*.rendered.yml` until the agent renders them again.
  - The `*.tmpl` placeholders are injected again, and `infisical-agent` restarts on every node. This happens on every phase-7 run, because rsync restores the un-injected templates each time.
  - On the primary manager the restarted agent re-renders `management/.env` and runs `docker stack deploy management`. `portainer-server` or `homarr` restart only if their rendered spec differs from what is running. The agent also runs the auth-users and Alertmanager sync helpers, which rewrite their runtime files on GlusterFS.
  - `sync-configs` overwrites `configuration.yml`, `prometheus.yml`, `alert-rules.yml`, `loki-config.yaml` and `promtail.yml` on `/mnt/swarm-shared`. The seed-only files are left alone. Running containers pick up the new files only when they restart or reload. The same pipeline's health-gated redeploy then triggers every stack webhook, but a service whose spec has not changed may keep its old config in memory.
  - Ansible-only pushes now actually run the mapped role on every host in its plays.
- **Stateful data:** no Portainer DB volume, GlusterFS brick, block volume or node-local DB contents are touched. Phase 7 only re-asserts mode 0777 on the existing `/mnt/app_data/local/{auth/authelia-db,management/homarr-db}` directories. Only config files on the mounted GlusterFS volume are rewritten.
- **Interaction:** the cross-repo step of `harden-portainer-bootstrap`, which restarts the agent through phase 7 on a stacks bump, only works once this change has landed.
- **Rollback:** revert the commit(s). Tagged runs go back to being no-ops, and full runs are unaffected. Files that the fixed runs already wrote stay as the pinned stacks content. To put hosts back on an older stacks commit, revert the gitlink and then run an untagged bootstrap, because after the revert a bump alone no longer converges hosts. Use `workflow_dispatch` with `ansible_only=true`, or the local full run.
