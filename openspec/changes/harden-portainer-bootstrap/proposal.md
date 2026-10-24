# Proposal

## Why

Phase 6 (`ansible/roles/portainer_bootstrap`) can destroy Portainer's database, can leak an admin JWT into public Actions logs, restarts Portainer on every run, and deploys the `management` stack with an incomplete environment. Every push that runs phase 6 goes to live nodes unattended, so all four defects (described as-built in `openspec/specs/portainer-bootstrap/spec.md`) are live risks. They are also coupled: the churn feeds the data-loss path, and the churn currently hides the missing variable.

1. **Data loss.** A single GET to `/system/status` that is never retried and never fails the task (`tasks/main.yml:70-78`) decides everything. If it returns anything but 200, the role runs `docker stack rm management` (`:80-88`) and, separately, `docker volume rm management_portainer_db` with failures ignored (`:103-109`). That volume holds the whole Portainer database (`stacks/management/docker-compose.yml:107,177-179`): the Git-backed stacks and webhooks created by `terraform/portainer/main.tf:269,317-326`, the license (`:305`), the agent endpoint and the API tokens. One unhealthy moment wipes it, and Terraform state plus `/deployments` `WEBHOOK_URL_*` are left pointing at objects that no longer exist. Examples of such a moment: a restart (the role itself causes one every run, see 3), an OOM kill at the 256M limit (`docker-compose.yml:122`), or an image upgrade. The volume is a node-local Docker volume on the boot disk, not on the block volume, so OCI's Silver backup policy does not cover it either.
2. **Credential leak.** The diagnostic task runs `curl -sv … 2>&1` with `Authorization: Bearer $JWT` (`:246-253`). The next debug task prints that output and has no `no_log` (`:265-268`). This fires whenever Portainer has zero endpoints, which happens on first bootstrap and after every wipe from defect 1. Two more tasks pass the JWT or the API key as request headers without `no_log`: the token listing (`:319-328`) and the final verification (`:544-555`).
3. **Churn.** A freshly salted bcrypt hash is generated on every run (`:27-31`) and placed in the `portainer-server` `command` (`docker-compose.yml:100`). The service spec therefore changes and Portainer restarts every run (`order: stop-first`, `:115`), and the hash is rewritten to Infisical every run (`:464-478`). Portainer only reads `--admin-password` when it creates the admin user on an empty database, so the restart achieves nothing. Cross-repo, `stacks/management/.env.tmpl:12` writes the hash unquoted, and the agent sources that file with `sh` (`stacks/infisical-agent.yaml:61`). As a result `$2b$12$…` is shell-expanded, and the agent redeploys a mangled value. That changes the spec again.
4. **Incomplete deploy environment.** The phase-6 deploy passes only `BASE_DOMAIN`, `HOMARR_SECRET_KEY` (fallback `changeme`), `TZ` and the hash (`:125-129`). It omits `HOMARR_DB_PASS`, which the compose file needs (`docker-compose.yml:14,20,65`), so Homarr receives a blank DB password. Today the agent usually repairs this within minutes, because the hash rewrite makes it re-render `.env` and redeploy. Fixing defect 3 alone would remove that accidental repair.

## What Changes

- **BREAKING (operator workflow):** phase 6 never removes the `management` stack, the `portainer-server` service or the `management_portainer_db` volume on its own. Unhealthy Portainer now fails the run with safe diagnostics instead of being wiped.
- New explicit, operator-only reset: `-e portainer_force_reset=true`. It removes only the `portainer-server` service and archives the volume to a root-only, timestamped tarball under `/mnt/app_data/backups/portainer/` (block volume, covered by the Silver backup policy). It checks the archive and only then removes the volume and redeploys. The orchestrator cannot pass this flag.
- The diagnostic endpoint task and its debug print are removed. Endpoint creation stays as the single idempotent task. Every task that carries the admin password, the hash, a JWT, an API key or a Homarr secret runs with `no_log`. Failure output is limited to step names, HTTP or exit codes, counts and Swarm task states.
- `PORTAINER_ADMIN_PASSWORD_HASH` is reused from the controller environment (injected from Infisical `/stacks/management`) when it verifies against `PORTAINER_ADMIN_PASSWORD`. A new hash is generated and written to Infisical only when the stored one is missing or does not match. Re-runs with unchanged inputs no longer restart Portainer.
- **BREAKING (inputs):** the management deploy gets exactly the variable set the runtime agent renders: `BASE_DOMAIN`, `TZ`, `HOMARR_SECRET_KEY`, `HOMARR_DB_PASS` and `PORTAINER_ADMIN_PASSWORD_HASH`. The role fails before touching the host when any of these, or `PORTAINER_ADMIN_PASSWORD`, is empty. The `changeme` and `Etc/UTC` fallbacks are dropped.
- CI secret preflight (`secret_validation.sh`) also validates `/stacks/management` `HOMARR_DB_PASS` when Ansible runs.
- **Cross-repo (JoseStud/stacks):** quote `PORTAINER_ADMIN_PASSWORD_HASH` in `management/.env.tmpl` (for example `PORTAINER_ADMIN_PASSWORD_HASH='{{ $pah.Value }}'`), then bump the `stacks` submodule here. Out of scope: Ansible tag scoping (change `fix-ansible-tag-scoping`) and SSH/network changes.

## Capabilities

### New Capabilities
None.

### Modified Capabilities
- `portainer-bootstrap`:
  - Admin hash reuse instead of per-run regeneration.
  - The automatic unhealthy reset is removed and replaced by an explicit, archived reset.
  - Complete, fail-fast deploy environment.
  - Readiness failures produce safe diagnostics.
  - Endpoint provisioning without the verbose diagnostic.
  - A credential-safe output rule.
  - Summary reports the hash mode.
- `secrets-management`:
  - Automation-managed write-back of `PORTAINER_ADMIN_PASSWORD_HASH` happens only on mismatch.
  - Bootstrap secret validation includes `HOMARR_DB_PASS`.

## Impact

- **Code:** `ansible/roles/portainer_bootstrap/tasks/main.yml` and `defaults/main.yml`, plus `.github/scripts/stages/secret_validation.sh`. Docs: `docs/ansible.md`, `docs/deployment-runbook.md`, `docs/infisical-workflow.md`, `docs/meta-pipeline-cutover-checklist.md`, `docs/backup-strategy.md`, `docs/stacks.md`. Cross-repo: `stacks/management/.env.tmpl`.
- **Blast radius:**
  - **Node:** only the primary manager, `groups['oci_nodes'][0]` (`oci-node-1` = `app-worker-1`, where `portainer-server` is pinned).
  - **First phase-6 run after rollout:** `portainer-server` restarts once, because its running spec carries the agent's mangled hash and phase 6 now deploys the real one. That means a short Portainer API/UI outage. `homarr` and `homarr-db` restart once only if their running spec still has the blank `HOMARR_DB_PASS` from a phase-6 deploy. `portainer-agent` is unchanged. After that, re-runs with unchanged inputs restart nothing.
  - **Cross-repo bump:** once phase 7 syncs the bumped stacks submodule, the agent restarts and redeploys `management` once with the correctly quoted hash. On the tag-scoped reconcile path this needs `fix-ansible-tag-scoping`; otherwise it waits for a full run.
- **Stateful data:**
  - The Portainer DB volume is no longer touched automatically. Only an explicit reset touches it, and the archive is written first.
  - Archives add a few MB per reset to `/mnt/app_data` on the primary manager's block volume.
  - Homarr's node-local DB directory, GlusterFS bricks and other block-volume data are not touched.
  - No new billable resources.
- **Rollback:** revert the commit(s) and let the next phase-6 run apply the old role. Be aware that this brings back the automatic volume wipe and the per-run hash churn. Archives under `/mnt/app_data/backups/portainer/` stay in place. A performed reset is undone by restoring the archive into the volume (runbook procedure added by this change). The stacks quoting fix is reverted in JoseStud/stacks plus a submodule bump. It needs no data migration either way.
