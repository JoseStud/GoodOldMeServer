# Tasks

## 1. Cross-repo prerequisite (JoseStud/stacks)

- [ ] 1.1 In JoseStud/stacks, change `management/.env.tmpl` so the hash line reads `PORTAINER_ADMIN_PASSWORD_HASH='{{ $pah.Value }}'`. Verify locally: write a file containing that line with a sample bcrypt hash, then run `sh -c 'set -a; . ./sample.env; set +a; printf %s "$PORTAINER_ADMIN_PASSWORD_HASH"'`. It must print the sample hash byte for byte.
- [ ] 1.2 Bump the `stacks` submodule here to the trusted SHA that contains 1.1. Verify that phase 7 has synced the new template to the primary manager. This happens through the stacks-SHA reconcile once `fix-ansible-tag-scoping` has landed, or otherwise through a full playbook run. Then check on the primary manager over SSH, without pasting the output anywhere public: the `--admin-password` argument in `docker service inspect management_portainer-server --format '{{json .Spec.TaskTemplate.ContainerSpec.Args}}'` starts with `$2`, and its `sha256sum` equals that of the Infisical `/stacks/management` value.

## 2. Deploy environment contract

- [ ] 2.1 Add the input checks as the first tasks of `ansible/roles/portainer_bootstrap/tasks/main.yml`, before "Ensure management runtime directory exists":
  - parse the `KEY=` names from the controller's trusted `stacks/management/.env.tmpl` (new default `portainer_env_template_source_path`, next to `portainer_compose_source_path`);
  - fail if no names are parsed;
  - assert that every name except `PORTAINER_ADMIN_PASSWORD_HASH`, plus `PORTAINER_ADMIN_PASSWORD`, is non-empty in the controller environment;
  - run with `no_log` and fail with a message that lists only the missing names.

  Verify by running the playbook locally with `HOMARR_DB_PASS` unset. It must fail before any host task, and the message must name `HOMARR_DB_PASS` and print no value.
- [ ] 2.2 Rewrite "Deploy management stack (Portainer + Homarr)" (`tasks/main.yml:119-132`):
  - set its `environment` to the parsed keys with their controller values, plus the resolved hash;
  - remove the `changeme` and `Etc/UTC` defaults;
  - add `no_log: true` and keep `changed_when`.

  Verify on the primary manager over SSH: `docker service inspect management_homarr-db --format '{{range .Spec.TaskTemplate.ContainerSpec.Env}}{{println .}}{{end}}' | grep -c '^POSTGRES_PASSWORD=.'` prints `1`.
- [ ] 2.3 Add `validate_value_secret /stacks/management HOMARR_DB_PASS` to the `RUN_ANSIBLE` block of `.github/scripts/stages/secret_validation.sh`. Verify with `shellcheck .github/scripts/stages/secret_validation.sh`, and verify that a `SHADOW_MODE=true` `workflow_dispatch` run (`ansible_only=true`) passes secret validation.
- [ ] 2.4 Update the docs:
  - `docs/ansible.md` Phase 6: the detailed flow, the required environment variables (add `HOMARR_DB_PASS` and `TZ`, note that there are no defaults and that variables come from `.env.tmpl`), and a note that local runs wrap `ansible-playbook` in the same nested `infisical run --path=/infrastructure … --path=/stacks/management` as `ansible_run.sh`.
  - `docs/infisical-workflow.md`: add `HOMARR_DB_PASS` to the "Required for First Deploy" row for `/stacks/management`.
  - `docs/deployment-runbook.md` Step 0: add `HOMARR_DB_PASS` to the manual deploy example.

  Verify that the documented manual command lists all five compose variables.

## 3. Admin hash reuse

- [ ] 3.1 Confirm Portainer's `--admin-password` behavior on the live node. Over SSH, `docker service logs management_portainer-server 2>&1 | grep -i 'skipping admin password'` after a restart must show the skip line. Keep this output private. Then correct the role comment at `tasks/main.yml:174-177` to match the observed behavior.
- [ ] 3.2 Replace "Generate bcrypt hash of admin password" (`tasks/main.yml:27-31`):
  - read the candidate from `lookup('env', 'PORTAINER_ADMIN_PASSWORD_HASH')`;
  - parse it with the `^\$(2[aby])\$(\d{2})\$([./A-Za-z0-9]{22})([./A-Za-z0-9]{31})$` shape;
  - recompute with `password_hash('bcrypt', salt=…, rounds=…, ident=…)` inside `block`/`rescue`;
  - set `portainer_admin_password_hash` and `portainer_admin_hash_mode` (`reused` / `generated`), all with `no_log`.

  Verify with a throwaway localhost playbook in the scratchpad (not committed) that covers three cases: a matching password/hash pair gives `reused`, a wrong password gives `generated`, and a malformed or `$2y$` hash with bad padding gives `generated` without failing.
- [ ] 3.3 Move "Write PORTAINER_ADMIN_PASSWORD_HASH to Infisical" (`tasks/main.yml:464-478`) so it runs before the deploy, gated on `portainer_admin_hash_mode == 'generated'` and a non-empty `INFISICAL_PROJECT_ID`. Verify that across two consecutive phase-6 runs, `infisical secrets get PORTAINER_ADMIN_PASSWORD_HASH --env=prod --path=/stacks/management --plain | sha256sum` is identical. Never print the value itself.
- [ ] 3.4 Change the summary's `Admin Hash` line (`tasks/main.yml:557-568`) to show one of three values: `reused (verified against PORTAINER_ADMIN_PASSWORD)`, `written to Infisical /stacks/management`, or the existing `MANUAL — …` text. Verify in the summary of a live run.
- [ ] 3.5 Update the hash ownership wording to "generated once and rewritten only when missing or mismatched with `PORTAINER_ADMIN_PASSWORD`". The places are `docs/infisical-workflow.md:53,157`, `docs/meta-pipeline-cutover-checklist.md:12` and `docs/ansible.md`. In `docs/ansible.md`, also say that changing `PORTAINER_ADMIN_PASSWORD` requires changing the admin password in Portainer first. Verify that no doc still says the hash is rewritten on every run (`grep -rn "every bootstrap run\|on every run" docs/`).

## 4. Non-destructive health handling and explicit reset

- [ ] 4.1 Delete the pre-deploy probe, `docker stack rm`, service wait and `docker volume rm` tasks, together with their comment block (`tasks/main.yml:63-109`). Verify that `grep -nE 'stack rm|volume rm|service rm' ansible/roles/portainer_bootstrap/tasks/main.yml` matches only tasks inside the reset block from 4.3.
- [ ] 4.2 Wrap "Wait for portainer-agent to have a Running task" and "Wait for Portainer API to be reachable" (`tasks/main.yml:144-169`) in `block`/`rescue`:
  - the `rescue` prints only `docker service ps management_portainer-server management_portainer-agent --no-trunc --format '{{.Name}} {{.CurrentState}} {{.Error}}'`;
  - it then fails with a message saying that no data was removed, and naming `-e portainer_force_reset=true`.

  Verify with a local run using `-e portainer_api_url=http://localhost:1/api`. The run must fail with only task states shown, and `docker volume inspect management_portainer_db` must still succeed afterwards.
- [ ] 4.3 Add the reset block.
  - Defaults: `portainer_force_reset: false`, `portainer_reset_backup_dir: /mnt/app_data/backups/portainer`, `portainer_db_volume: management_portainer_db`, `portainer_server_service: management_portainer-server`.
  - Gate it on `portainer_force_reset | bool`.
  - Steps, in order:
    1. check that the volume exists;
    2. `docker service rm`;
    3. wait until `docker ps -a --filter volume=<vol> -q` is empty;
    4. create the backup directory with mode 0700;
    5. `tar -czf` the volume `Mountpoint` into `<vol>-<UTC timestamp>.tar.gz` and set the file to mode 0600;
    6. check it with `tar -tzf`;
    7. `docker volume rm`.
  - Then continue to the normal deploy.

  Verify on the primary manager against a throwaway volume and a one-replica test service that mounts it, by overriding `portainer_db_volume` and `portainer_server_service`: the archive exists with mode 0600, `tar -tzf` lists the test file, and the throwaway volume is gone. Delete the test archive afterwards.
- [ ] 4.4 Check the failure and no-op paths with the same throwaway setup:
  - Point `portainer_reset_backup_dir` at an unwritable path. The role must fail and leave the volume in place.
  - Run with the flag but no volume. The role must report "nothing to reset" and deploy normally.
- [ ] 4.5 Add a "Reset or restore Portainer" section to `docs/deployment-runbook.md`. It covers when to use the reset, the exact local command, the archive location and permissions, the restore steps, and the follow-up `terraform -chdir=terraform/portainer-root apply` to recreate stacks, webhooks and the license. Also fix `docs/backup-strategy.md:67`: Portainer data is a node-local Docker volume, not on the brick, and reset archives live under `/mnt/app_data/backups/portainer`. Fix the `portainer-server` placement in `docs/stacks.md:23` too (pinned to `app-worker-1`). Verify that the documented restore commands match the role's paths and names.

## 5. Credential-safe output

- [ ] 5.1 Delete "Debug - diagnose endpoint creation" and "Debug - print endpoint creation diagnostics" (`tasks/main.yml:211-268`). Rewrite "Ensure agent endpoint exists in Portainer" (`:270-317`):
  - run curl as `curl -s -o <tmp> -w '%{http_code}'` with stderr discarded;
  - print only `STEP=<auth|list|create> HTTP=<code>`, `CHANGED` or `UNCHANGED`;
  - use `failed_when: false` with `until` and 12 retries, followed by a `fail` task that echoes only the marker.

  Verify that `grep -nE 'curl[^|]*-s?v' ansible/roles/portainer_bootstrap/tasks/main.yml` returns nothing.
- [ ] 5.2 Add `no_log: true` to:
  - "Check for existing Terraform API key" (`:319-328`);
  - "Determine API key repair mode" (`:382-386`);
  - "Verify Portainer is healthy and API key works" (`:544-555`). Give this one `failed_when: false` and a follow-up `fail` that shows only the status code.

  Verify with a short script (scratchpad, or a CI guard if the owner wants one) that lists every task whose module arguments or `environment` reference a credential variable named in the Credential-Safe Task Output spec but which lacks `no_log: true`. The list must be empty.
- [ ] 5.3 After the first live run that executes phase 6, verify that `gh run view <run-id> --log | grep -cE 'Authorization|Bearer|\$2[aby]\$'` prints `0`. Run this on the operator machine.
- [ ] 5.4 Document in `docs/ansible.md` Phase 6 that diagnostics are limited to step names, status codes and Swarm task states, and that detailed logs are read over SSH. Verify that the page no longer mentions the diagnostic endpoint task.

## 6. Repository checks and rollout verification

No Terraform or Python files change, so `terraform fmt -check`/`validate` are not needed. `pytest` in `ci/` still runs as a regression guard.

- [ ] 6.1 Run `ansible-lint -c .ansible-lint ansible` and `ansible-playbook --syntax-check -i ansible/inventory/terraform.yml ansible/playbooks/provision.yml`. Both must pass.
- [ ] 6.2 Run `shellcheck .github/scripts/stages/*.sh` and `cd ci && pytest`. Both must pass.
- [ ] 6.3 With the repository variable `SHADOW_MODE=true`, trigger `orchestrator.yml` via `workflow_dispatch` (`ansible_only=true`). Verify that secret validation passes and that the Ansible stage logs `SHADOW_MODE=true: skipping Ansible mutation run.` Then reset `SHADOW_MODE`.
- [ ] 6.4 First live run that executes phase 6 (a full run, or a tag-scoped run once `fix-ansible-tag-scoping` lands). Verify:
  - the summary shows `Health: OK` and `Admin Hash: reused (verified against PORTAINER_ADMIN_PASSWORD)`;
  - `docker volume inspect management_portainer_db` shows the volume unchanged;
  - at most one new `management_portainer-server` task appears in `docker service ps`.
- [ ] 6.5 Second consecutive phase-6 run. Verify that `docker service ps` shows no new task for `management_portainer-server`, `management_homarr` or `management_homarr-db`, and that the Infisical hash checksum from 3.3 is unchanged.

## Workflow follow-up

- Owner decides whether to delete historical orchestrator run logs that may contain the old diagnostic output (design.md, Open Questions).
- Archive this change after the live verification in 6.4 and 6.5, then confirm the archived `portainer-bootstrap` and `secrets-management` specs pass `openspec validate --specs --strict`.
