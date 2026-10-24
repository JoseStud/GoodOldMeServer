# Tasks

## 1. Owner and cross-repo prerequisites (JoseStud/stacks, GitHub, Infisical)

- [ ] 1.1 (Owner) Create a GitHub App with repository permissions `Contents: Read and write` and `Metadata: Read`, and no webhook. Install it on `JoseStud/stacks` only. Verify that the installation's repository list shows only `stacks`. The App is free.
- [ ] 1.2 (Owner) Store the App ID and PEM private key in Infisical `prod` `/management` as `STACKS_DEPLOY_APP_ID` and `STACKS_DEPLOY_APP_PRIVATE_KEY`. Verify that both keys exist without printing their values, for example with `infisical secrets --path=/management --plain | cut -d= -f1`.
- [ ] 1.3 (Owner, cross-repo) Create `refs/heads/deploy` in JoseStud/stacks at the current infra `HEAD:stacks`, `6b0008699ba5a4151fbeb0a81cfac2398d5d3c35`. Verify that `git ls-remote https://github.com/JoseStud/stacks refs/heads/deploy` prints that SHA.
- [ ] 1.4 (Owner, cross-repo) Add a JoseStud/stacks ruleset targeting `refs/heads/deploy`: restrict updates, restrict deletions, block force pushes, with the App from 1.1 as the only bypass actor (always). Verify that `git push --force origin <other-sha>:refs/heads/deploy` from the owner's own account is rejected.
- [ ] 1.5 (Owner, cross-repo) Confirm that the JoseStud/stacks `main` branch protection or ruleset does not list the App as a bypass actor. Verify that an installation token minted for the App gets HTTP 403 or 422 on a `PATCH /git/refs/heads/main` attempt that targets the current SHA, which is harmless.
- [ ] 1.6 (Cross-repo PR in JoseStud/stacks) Rewrite the README section "Verified deployment tags" added in `7bf6d43`. It should say that Portainer tracks `refs/heads/deploy`, which the infra orchestrator advances to the trusted gitlink SHA, and that `deploy-<sha>` tags are informational. Verify that the PR is merged and that its CI is green.

## 2. Terraform: local manifest, hard guards, deploy reference default

- [ ] 2.1 In `terraform/portainer/main.tf`, remove the following:
  - `data "http" "stacks_manifest"`
  - the `hashicorp/http` entry in `required_providers`
  - the `has_stacks_sha` and `github_repo_*` locals
  - the variables `stacks_sha`, `stacks_manifest_url` and `stacks_manifest_token`

  Then add `variable "stacks_manifest_path"` (string, default `null`) and the local `yamldecode(file(coalesce(var.stacks_manifest_path, "${path.module}/../../stacks/stacks.yaml")))`. Verify with `terraform -chdir=terraform/portainer init -backend=false && terraform -chdir=terraform/portainer validate`.
- [ ] 2.2 Replace the four `check` blocks with a `terraform_data "stacks_manifest_guard"` resource (no `input`) carrying four `lifecycle.precondition` blocks, using the exact messages from the Manifest Plan Guards requirement. Add `terraform/portainer/tests/manifest_guards.tftest.hcl` using `mock_provider` for `portainer` and `infisical`, with `override_data` supplying the required Infisical keys, and fixtures for:
  - the current manifest
  - `404: Not Found`
  - `version: 2`
  - a blank `compose_path`
  - a managed stack with no env map
  - one stack removed

  Verify that `terraform -chdir=terraform/portainer test` passes, that each bad fixture hits `expect_failures = [terraform_data.stacks_manifest_guard]`, and that the one-stack-removed fixture plans exactly one `portainer_stack` destroy.
- [ ] 2.3 Change the `repository_reference` default to `refs/heads/deploy` in `terraform/portainer/main.tf` and `terraform/portainer-root/main.tf`. In the root, remove `stacks_sha`, `stacks_manifest_url` and `stacks_manifest_token`, and declare and forward `stacks_manifest_path` (default `null`). Verify that `terraform fmt -check -recursive terraform` passes.
- [ ] 2.4 Remove the `registry.terraform.io/hashicorp/http` block from `terraform/portainer/.terraform.lock.hcl` and `terraform/portainer-root/.terraform.lock.hcl` by re-running `terraform init -backend=false` in each directory. Verify that `terraform -chdir=<dir> init -backend=false -lockfile=readonly -input=false` and `validate` succeed for both, as `validate-terraform.yml` runs them.
- [ ] 2.5 In a scratch worktree where the `stacks` submodule is not initialized, run the `validate-terraform.yml` init and validate commands for `terraform/portainer-root` and `terraform/portainer`. If `file()` fails there, add `submodules: true` to that workflow's `terraform-validate` checkout (`JoseStud/stacks` is public). Verify that the Validate Terraform workflow is green on the PR.
- [ ] 2.6 Update `docs/infisical-workflow.md` ("Terraform → Portainer Integration", around line 297) and `docs/meta-pipeline-cutover-checklist.md` (the `goodoldme-portainer` table: drop the `stacks_manifest_url`/`stacks_manifest_token` row, add `stacks_manifest_path`, and note the `refs/heads/deploy` default). Verify with `grep -rn "stacks_manifest_url\|stacks_manifest_token" docs terraform` returning nothing.

## 3. Portainer apply stage pins the manifest checkout

- [ ] 3.1 In `.github/scripts/stages/portainer_apply.sh`, call `checkout_stacks_sha "${STACKS_SHA:-}"` before `terraform init` and stop adding `TF_VAR_stacks_sha` to `terraform_args`. Verify that `shellcheck .github/scripts/stages/portainer_apply.sh` is clean, and that a container dry run with `stacks/` overwritten by a different commit ends with `git -C stacks rev-parse HEAD` equal to STACKS_SHA.
- [ ] 3.2 In `ci/src/ci_pipeline/phases/portainer.py` (`_portainer_terraform_container`), stop setting `TF_VAR_stacks_sha` but keep `STACKS_SHA`. Verify that `cd ci && pytest` passes.
- [ ] 3.3 Update `docs/ci-orchestrator-execution-rules.md` ("Trusted `stacks_sha` Boundary") to list Portainer stack source via `refs/heads/deploy` and the Portainer apply manifest read from the pinned checkout. Verify that the section no longer says "manifest selection".

## 4. stacks-deploy-ref stage

- [ ] 4.1 Add `.github/scripts/stacks/advance_stacks_deploy_ref.sh <STACKS_SHA>`. It does the following:
  - validates the SHA with `is_valid_sha`
  - fetches `STACKS_DEPLOY_APP_ID` and `STACKS_DEPLOY_APP_PRIVATE_KEY` from `/management` via `fetch_infisical_secret`
  - signs an RS256 JWT with `openssl`, resolves `GET /repos/JoseStud/stacks/installation`, and mints an installation token narrowed to `stacks` and `contents: write`
  - runs GET, then POST/PATCH (`force: true`), then reads the ref back
  - in SHADOW_MODE, mints and reads but does not write
  - prints only SHAs, HTTP status and GitHub's `message`, never bodies, headers, the JWT or the token

  Verify that `shellcheck` is clean.
- [ ] 4.2 Add `portainer.stacks_deploy_ref(...)` in `ci/src/ci_pipeline/phases/portainer.py`. It uses the `infisical` profile plus `apk add openssl`, `_wire_infisical`, `STACKS_SHA`, `SHADOW_MODE` and the proxy binding, and prints `stacks-deploy-ref: skipped (no stacks_sha)` when STACKS_SHA is empty. Call it in `ci/src/ci_pipeline/__main__.py` after `portainer_api_preflight` and before `portainer_apply_debug` when `run_portainer_apply or run_health_redeploy`. Verify that `cd ci && pytest` passes.
- [ ] 4.3 Add pytest coverage in `ci/tests/` for the script, against a stub GitHub API (local HTTP server via `GITHUB_API_URL`) and stubbed Infisical/`openssl` calls. Cover:
  - create when absent
  - no-op when current
  - forward move
  - backward move (rollback)
  - SHADOW_MODE with no write
  - HTTP 401, 403 and 422 rejections
  - missing credential
  - read-back mismatch

  Each case asserts the exit code and that no token or JWT string appears in stdout or stderr. Add a test that the stage order in `__main__` places stacks-deploy-ref between portainer-api-preflight and portainer-apply-debug. Verify that `cd ci && pytest` passes.
- [ ] 4.4 Update the docs:
  - `docs/deployment-runbook.md` "Via Portainer GitOps Webhooks": step 3 and the paragraph at line 392 now describe the `deploy` ref, and a break-glass note covers moving `deploy` (App token or temporary ruleset edit) and running a local apply with the submodule at the `deploy` commit.
  - `docs/scripts.md`: a row for the new script.
  - `docs/infisical-workflow.md`: the `/management` `STACKS_DEPLOY_APP_*` keys.
  - `docs/ci-orchestrator-execution-rules.md`: the Portainer layer list.

  Verify that the runbook no longer says webhooks follow `refs/heads/main`.

## 5. Health redeploy verifies the deploy reference

- [ ] 5.1 In `.github/scripts/stages/health_gated_redeploy.sh`, after `exit_if_shadow_mode`, fail when STACKS_SHA is empty, and fail with "refs/heads/deploy is at <commit>, expected <STACKS_SHA>." unless `git ls-remote "${STACKS_REPO_URL:-https://github.com/JoseStud/stacks}" refs/heads/deploy` equals STACKS_SHA. Both checks run before any webhook. Verify that `shellcheck` is clean.
- [ ] 5.2 Add pytest coverage in `ci/tests/` that runs the stage against a local bare repo (`STACKS_REPO_URL`) with `curl`, `infisical` and the gate script stubbed on `PATH`. Assert that a mismatched or missing `deploy` ref and an empty STACKS_SHA both exit 1 without invoking the webhook stub, and that a matching ref proceeds. Verify that `cd ci && pytest` passes.
- [ ] 5.3 Note in `docs/deployment-runbook.md` (manual webhook section) and `docs/ansible.md` (runtime_sync helper description) that every webhook, including the agent's `portainer-stack-webhook`, redeploys the commit at `refs/heads/deploy`. Verify by reading the rendered Markdown.

## 6. Rollout verification (integration)

- [ ] 6.1 Set repo variable `SHADOW_MODE=true` and merge. In the orchestrator run, verify the following:
  - stacks-deploy-ref mints a token and reports that `deploy` is already at `HEAD:stacks`.
  - The portainer-apply plan shows 8 in-place updates of `repository_reference_name`, 1 `terraform_data` create and 0 destroys.
  - No token, JWT or Authorization header appears anywhere in the public log.
- [ ] 6.2 Record SHA-256 hashes (not values) of the eight `/deployments` `WEBHOOK_URL_*` secrets. Unset `SHADOW_MODE` and run `workflow_dispatch` with `skip_ansible_bootstrap: true` and `force_health_redeploy: true`. Verify the following:
  - The apply reports 8 changed and 0 destroyed.
  - Portainer shows `refs/heads/deploy` for all 8 stacks.
  - The webhook hashes are unchanged.
  - health-gated-redeploy passes.
  - `docker service ls` shows every service at its desired replicas.
- [ ] 6.3 On the next stacks gitlink bump, verify that stacks-deploy-ref prints `refs/heads/deploy: <old> -> <new>`, that `git ls-remote` shows `deploy` at the new gitlink SHA, and that the gate completes.

## 7. Cross-repo follow-through

- [ ] 7.1 (Owner decision, cross-repo) After 6.3, decide whether to keep or remove the stacks `publish-deploy-tag` job and `deploy-*` tags from `7bf6d43`. They are unused by this design but harmless, and they are the basis of the rejected alternative (3b) in design.md D1. Verify that the decision is recorded in the stacks README section from 1.6.
