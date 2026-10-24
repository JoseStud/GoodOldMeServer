# Design

## Context

See proposal.md (Why) for the four defects. Facts that shape the approach:

- **Where phase 6 runs.** Only on `groups['oci_nodes'][0]` (`ansible/playbooks/provision.yml:124-129`). The CI inventory names that host `oci-node-1` (`.github/scripts/tfc/render_inventory_from_tfc_outputs.sh:68`). `portainer-server` is pinned to `node.hostname == app-worker-1` (`stacks/management/docker-compose.yml:117-119`) and publishes 9000 in host mode (`:101-105`). The role's default API URL `http://localhost:9000/api` (`ansible/roles/portainer_bootstrap/defaults/main.yml:14`) only works because oci_nodes[0] is that node, so the local volume `management_portainer_db` (`docker-compose.yml:107,177-179`) lives there too.
- **Phase order.** Phase 6 runs before phase 7 (`provision.yml:124-135`). On first bootstrap, `/opt/stacks/management/.env` (rendered by the agent from `.env.tmpl`, `stacks/infisical-agent.yaml:53-65`) does not exist yet when phase 6 deploys.
- **Controller environment.** In CI, `.github/scripts/stages/ansible_run.sh:182-187` wraps `ansible-playbook` in nested `infisical run` for `/infrastructure` and `/stacks/management`. The playbook environment therefore holds `BASE_DOMAIN`, `TZ`, `HOMARR_SECRET_KEY`, `HOMARR_DB_PASS`, `PORTAINER_ADMIN_PASSWORD` and the currently stored `PORTAINER_ADMIN_PASSWORD_HASH`. These are the same keys `stacks/management/.env.tmpl:4-15` reads.
- **No extra-vars.** The orchestrator passes only `-i`, the playbook and an optional `--tags` (`ansible_run.sh:172-175`).
- **Controller tooling.** The runner installs `ansible-core==2.20.2` with `passlib[bcrypt]` (`.github/workflows/orchestrator.yml:193`). The role already depends on `password_hash('bcrypt')` (`tasks/main.yml:27-31`).
- **How Portainer uses `--admin-password`.** Portainer applies it only when it creates the first admin on an empty database. An existing instance logs that it skips the admin-password flags. The role comment claiming the hash "is applied on every container start" (`tasks/main.yml:174-177`) is wrong, and task 3.1 confirms this on the live node. So a new hash per run buys nothing but a restart.
- **Backup coverage.** The Portainer volume is a node-local Docker volume on the boot disk. It is outside `/mnt/app_data` (the block-volume mount, `ansible/roles/storage/defaults/main.yml:8`), which is the only thing the OCI Silver policy backs up (`docs/backup-strategy.md:33-41`). `docs/backup-strategy.md:67` wrongly lists `management/portainer/data` under the GlusterFS brick.
- **Paths affected.** Both paths change:
  - The orchestrator path (`ansible_run.sh` → `provision.yml`).
  - The local/break-glass path: `docs/ansible.md` "Running Ansible", and the manual management deploy in `docs/deployment-runbook.md` (Step 0, `:59-83`).
  - The explicit reset exists only on the local path.

## Goals / Non-Goals

**Goals:**
- Phase 6 is convergent and non-destructive. Re-running it with unchanged inputs changes nothing, and no health signal ever triggers deletion.
- Phase 6 and the runtime agent deploy `management` from one variable contract.
- Phase 6 output is safe for a public Actions log at default verbosity.

**Non-Goals:**
- **Admin password rotation.** Portainer ignores `--admin-password` on an existing database. Rotating `PORTAINER_ADMIN_PASSWORD` therefore still means changing it in Portainer first; this change only documents that.
- **Ansible tag scoping.** Covered by change `fix-ansible-tag-scoping`. SSH and network changes are also out of scope.
- **Portainer DB storage.** No scheduled backups of the Portainer DB, and no move of `portainer_db` onto `/mnt/app_data` (that would be a compose change in the stacks repo; see Open Questions).
- **API key logic.** No change to API key reuse or rotation beyond adding `no_log`.
- **Agent deploy command.** No change to the agent's `docker stack deploy` command; it stays without `--with-registry-auth`.

## Decisions

### D1. No pre-deploy health gate: always deploy, and treat post-deploy readiness as the gate

The pre-deploy probe (`tasks/main.yml:70-78`) existed only to decide on the wipe. Without the wipe, the only thing it could still decide is *whether to deploy*. Refusing to deploy an unhealthy Portainer would block the very fix that often cures it, such as a compose bump to a fixed image or a higher memory limit. `docker stack deploy` is convergent, so deploying over a sick service is safe. The existing post-deploy waits (`:144-169`) become the health gate. On timeout they print safe diagnostics and fail (spec: Portainer Readiness And Authentication).

*Alternatives considered:*
- **Retry the pre-deploy probe and fail if still unhealthy** (the suggested direction). Rejected: it duplicates the post-deploy wait and blocks remediation-by-redeploy.
- **Keep the automatic reset but add retries.** Rejected: it still destroys data on persistent faults that are recoverable, such as an OOM loop that a memory bump would fix.

### D2. Explicit reset: `-e portainer_force_reset=true`, service-scoped, archive first

- **Flag.** `portainer_force_reset` defaults to `false` in `defaults/main.yml` and is evaluated with `| bool`.
- **Sequence.**
  1. Look up the volume (`docker volume inspect`). If it is absent, report "nothing to reset" and skip the rest.
  2. `docker service rm management_portainer-server`.
  3. Wait (24 × 5 s) until `docker ps -a --filter volume=management_portainer_db -q` is empty.
  4. Create `/mnt/app_data/backups/portainer` (0700, root).
  5. Run `tar -czf` from the volume's `Mountpoint` into `management_portainer_db-<YYYYmmddTHHMMSSZ>.tar.gz` and set the file to 0600.
  6. Verify the archive with `tar -tzf`.
  7. `docker volume rm management_portainer_db`.
  8. Fall through to the normal deploy, which recreates the service.

  If any step up to verification fails, the role fails and the volume stays.
- **Remove the service, not the stack.** `homarr`, `homarr-db` and `portainer-agent` keep running. The old path tore down the whole stack (`:80-88`).
- **Wait on containers, not services.** `docker volume rm` refuses while any container references the volume, including a stopped task container. The old wait looked only at services (`:90-101`), and its `volume rm` ignored errors (`:103-109`), so it could silently do nothing or race.
- **Archive with host-side `tar`.** A helper container would need an image pull. The play already runs as root (`provision.yml:97`).
- **Archive location: `/mnt/app_data/backups/portainer`.** It is on the block volume, so the daily Silver backups cover it. The contents are sensitive: the database holds the stack environment values Terraform pushes from Infisical (`terraform/portainer/main.tf:291-298`), the admin hash and API token digests. Hence the root-only modes.
- **No orchestrator path.** An unattended run must never destroy state, and `ansible_run.sh` cannot pass extra-vars. Two other triggers were rejected:
  - A `PORTAINER_FORCE_RESET` environment variable. It could sit in Infisical `/infrastructure` or `/stacks/management` and be injected silently into every run by `ansible_run.sh`.
  - A `workflow_dispatch` input. Deferred (see Open Questions).
- **After a reset the existing flow repairs Portainer.** The endpoint task creates `primary`. The stored API key now gets 401, so the key rotates. The operator then re-applies `terraform/portainer-root` to recreate the stacks, webhooks and license. The runbook documents this.

### D3. Reuse the stored hash by recomputing bcrypt with its own salt

- **Parse.** Read the candidate from `lookup('env', 'PORTAINER_ADMIN_PASSWORD_HASH')` and parse it with `^\$(2[aby])\$(\d{2})\$([./A-Za-z0-9]{22})([./A-Za-z0-9]{31})$`. This is the same shape `assert_bcrypt_hash_value` enforces in `.github/scripts/lib/workflow_common.sh`.
- **Compare.** Compute `portainer_admin_password | password_hash('bcrypt', salt=<22 chars>, rounds=<cost|int>, ident=<2a|2b|2y>)`. If the result equals the candidate, reuse it. Otherwise generate a new hash, as today.
- **Errors count as a mismatch.** The computation runs inside a `block`/`rescue`. If passlib rejects a salt with non-zero padding bits or an unexpected variant, the role regenerates. The worst case is today's behavior (one restart and one write), never a failed run.
- **Reuse regardless of cost.** Portainer consumes the hash only on an empty database, so the cost of a stored hash does not matter. A change to `portainer_bcrypt_rounds` applies to the next newly generated hash.
- **Write a new hash before the deploy, not at the end** (it used to be written at `:464-478`). This keeps Infisical and the deployed service spec in agreement even if a later task fails. The agent's next render then deploys the same value, once the stacks quoting fix is in.

*Alternatives considered:*
- **An `infisical secrets get` fallback for the candidate, like the API key fallback** (`:337-366`). Rejected: a run without the injected environment also lacks `HOMARR_DB_PASS` and the other values, so it fails D4's check anyway. Local runs use the same nested `infisical run` instead, and the docs say so.
- **Python `bcrypt.checkpw`.** Rejected: it adds a controller dependency on the local path.
- **A deterministic salt derived from the password.** Rejected: it weakens bcrypt.
- **Dropping `--admin-password` from the compose `command` once initialized.** Rejected: the compose file is static in the stacks repo, and the flag is needed for a reset.

### D4. The deploy environment comes from the trusted `.env.tmpl`

- **Key list.** The role reads the controller's trusted `stacks/management/.env.tmpl`, using the same path pattern as `portainer_compose_source_path` (`defaults/main.yml:7`). It takes every line matching `^([A-Z][A-Z0-9_]*)=` as the key list. Today that list is `BASE_DOMAIN`, `TZ`, `HOMARR_SECRET_KEY`, `PORTAINER_ADMIN_PASSWORD_HASH` and `HOMARR_DB_PASS`. That is exactly the set of variables the compose file interpolates (`docker-compose.yml:5,7,8,14,20,41,65,100,127`).
- **Values.** `PORTAINER_ADMIN_PASSWORD_HASH` comes from D3. Every other key must be non-empty in the controller environment, together with `PORTAINER_ADMIN_PASSWORD`.
- **Check first.** These checks are the first tasks of the role, before the directory and staging tasks (`:39-55`), and they run with `no_log`. A failure message names only the missing keys. A template that yields zero keys also fails.
- **Deploy.** The deploy task (`:119-132`) gets this dictionary as `environment`, has no defaults, and runs with `no_log`.
- **Effect.** The phase-6 deploy and the agent deploy see identical values by construction. A stacks-repo template change that adds a variable makes phase 6 fail fast instead of deploying a blank value.

*Alternatives considered:*
- **A hard-coded key list.** Rejected: it drifts silently from the template.
- **Sourcing the agent-rendered `/opt/stacks/management/.env`.** Rejected: the file is absent on first bootstrap and may be stale.
- **Phase 6 rendering `.env` itself.** Rejected: that makes two writers for one file and repeats the quoting hazard.
- **Reordering phases so the agent deploys `management`.** Rejected: the agent path has no readiness, auth, endpoint or API key steps.

### D5. Credential-safe output

- **Remove the diagnostic.** Delete the diagnostic task and its debug print (`:211-268`).
- **Endpoint task** (`:270-317`, already `no_log`):
  - curl runs as `curl -s -o <tmpfile> -w '%{http_code}'` with stderr discarded.
  - The task prints only `STEP=<auth|list|create> HTTP=<code>`, `CHANGED` or `UNCHANGED`.
  - It runs with `failed_when: false` under `until`, followed by a `fail` task that echoes only that marker.
- **Add `no_log`** to:
  - the token listing (`:319-328`);
  - the repair-mode `set_fact` (`:382-386`);
  - the deploy (`:119-132`);
  - the final verification (`:544-555`), which gets `failed_when: false` and a follow-up `fail` that shows only the status code.
- **Readiness diagnostics.** The two waits (`:144-169`) sit in a `block`/`rescue`. The `rescue` prints `docker service ps management_portainer-server management_portainer-agent --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}'` and then fails with the D1 message.
  - It does not use `docker service inspect`, which would print the `--admin-password` hash from `command`.
  - It does not use `docker service logs`, which may contain request paths that include webhook IDs. Webhook URLs are secrets in `/deployments`.
- **Static check.** A grep over the role, as in tasks.md, verifies the rule.

### D6. CI secret preflight validates `HOMARR_DB_PASS`

Add `validate_value_secret /stacks/management HOMARR_DB_PASS` to the `RUN_ANSIBLE` block of `.github/scripts/stages/secret_validation.sh:100-104`. Preflight runs before any Ansible mutation (`ci/src/ci_pipeline/__main__.py:71-105`), so a missing value fails before phases 1-5. `BASE_DOMAIN` and `TZ` are already validated for `RUN_ANSIBLE` through `validate_portainer_managed_stack_secrets` (`secret_validation.sh:39-41,110-112`).

### D7. Cross-repo ordering: the stacks quoting fix lands first

In JoseStud/stacks, change `management/.env.tmpl:12` to `PORTAINER_ADMIN_PASSWORD_HASH='{{ $pah.Value }}'`. The bcrypt alphabet has no `'`, so single quotes are safe. Then bump the submodule here, before or in the same PR as this change.

- **Without the fix,** every agent render deploys a shell-mangled hash. With a stable Infisical hash this happens less often, but the `portainer-server` spec would still flip between phase 6 and agent deploys.
- **Lockout risk.** An agent deploy that happened to be the first start on an empty database would create the admin with an unusable hash.

## Risks / Trade-offs

- **[A genuinely corrupt Portainer DB now blocks phase 6 until the operator acts]** → The failure message names the reset, and the runbook documents the reset and restore. As with any phase-6 failure today, the failed host skips phase 7 in that run.
- **[Hash verification depends on passlib salt handling]** → Errors are treated as a mismatch, which degrades to today's regenerate-and-restart behavior.
- **[Deriving keys from `.env.tmpl` couples phase 6 to the template's `KEY=` line format]** → Zero parsed keys fails the role, and the format is documented in `docs/ansible.md`. Template changes already arrive only through the trusted-SHA path.
- **[Archives accumulate and contain secrets]** → Files are root-only and a few MB each, and pruning is manual. OCI backups keep deleted archives for up to 5 days.
- **[`no_log` hides failure detail]** → Sanitized step and status messages remain, and the operator inspects details over SSH.
- **[Local runs that relied on the `Etc/UTC`, `changeme` or `localhost` defaults now fail]** → This is the intended BREAKING change. `BASE_DOMAIN` and `TZ` are already listed as Required (`docs/infisical-workflow.md:65`), and the docs are updated.
- **[The first rollout restarts `portainer-server` once]** → The rollout swaps the agent's mangled hash for the real one. Because the service updates `stop-first` (`docker-compose.yml:115`), the API is down briefly, and the readiness wait covers it.
- **[The reset runs on a node without the volume]** → It reports "nothing to reset" and does not touch other nodes. phase 6 already assumes oci_nodes[0] hosts `portainer-server` (see Context).
- **[Old public run logs may still hold a JWT]** → Portainer JWTs expire with the session lifetime (8 h by default), and Portainer is reachable only over Tailscale or behind Authelia. Purging old logs is an operator decision (Open Questions).

## Migration Plan

1. **Stacks fix.** In JoseStud/stacks, quote the hash in `management/.env.tmpl` and bump the `stacks` submodule here. The new template reaches `/opt/stacks` through phase 7. That happens in the orchestrator's stacks-SHA reconcile once `fix-ansible-tag-scoping` has landed, because its tag-scoped phase 7 only then runs the role's tasks; until then it takes a full playbook run. The agent then restarts and redeploys `management` once, and `portainer-server` restarts once.
2. **Secret check.** Confirm `/stacks/management` `HOMARR_DB_PASS` exists. The agent template already requires it.
3. **Merge this change.**
   1. Verify the `secret_validation.sh` change with a `SHADOW_MODE=true` run.
   2. The next run that executes phase 6 converges: the hash is reused (no Infisical write) and the deploy gets the full environment. At most one `portainer-server` restart happens, if the running spec still differs. Phase 6 runs in a full playbook run, or in a tag-scoped run once `fix-ansible-tag-scoping` lands.
4. **Verify idempotence.** Run phase 6 a second time. The `docker service ps management_portainer-server` task history gains no new task, and the Infisical version of `PORTAINER_ADMIN_PASSWORD_HASH` is unchanged.

**Rollback:** revert the commit(s). This brings back the automatic wipe, so prefer a forward fix. Archives stay in place. To restore one:
1. `docker service rm management_portainer-server` and wait for its containers to go.
2. `docker volume create management_portainer_db`.
3. `tar -xzf <archive> -C <Mountpoint>`.
4. Re-run phase 6 without the flag.
5. Re-apply `terraform/portainer-root`, because webhook IDs recreated after a reset differ from the restored ones.

## Open Questions

- **Archive retention.** Should old reset archives be pruned automatically, or stay manual? This can be decided later without changing the specs.
- **`workflow_dispatch` trigger.** Should the reset be exposed later as a guarded `workflow_dispatch` input? This change keeps it local-only.
- **Old run logs.** Should past orchestrator run logs that contain the diagnostic output be deleted? This is operational only.
- **Stacks-repo follow-ups.**
  - Move `portainer_db` onto a bind mount under `/mnt/app_data/local/management/` for continuous backup coverage.
  - Single-quote the other `.env.tmpl` values.
- **Seed script.** Should `scripts/import_infisical_secrets.sh` seed a `HOMARR_DB_PASS` placeholder? That would change the secrets-management "Infisical Seed Script" behavior in a separate change.
