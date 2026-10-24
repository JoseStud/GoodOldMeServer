# Design

## Context

See proposal.md (Why) for the two defects. This section covers only the facts that shape the approach.

- **Where STACKS_SHA comes from.** It is always set on `push` and `workflow_dispatch`, resolved from `HEAD:stacks` (`ci/src/ci_pipeline/context.py:221-230`). The `dagger-pipeline` job checks out with `submodules: recursive` (`.github/workflows/orchestrator.yml:146-149`), and Dagger mounts the runner checkout at `/work` without `.git` (`ci/src/ci_pipeline/__main__.py:58-61`). So `stacks/` in every stage container holds the gitlink's files. Their git metadata is missing, which is why `checkout_stacks_sha` falls back to a fresh shallow fetch (`.github/scripts/lib/workflow_common.sh:433-463`). Ansible and the health redeploy already use that helper (`.github/scripts/stages/ansible_run.sh:152`, `health_gated_redeploy.sh:9`). portainer-apply does not.
- **Portainer stacks are Git stacks.** They use `method = "repository"`, `stack_webhook = true` and `force_update = true` (`terraform/portainer/main.tf:269-289`). Webhooks are triggered in two places:
  - the health gate, in manifest dependency order, stopping at the first failure (`.github/scripts/stacks/trigger_webhooks_with_gates.sh:163-176`);
  - the runtime agent. `auth-users-database-sync` and `observability-alertmanager-sync` call `/usr/local/bin/portainer-stack-webhook` (`stacks/infisical-agent.yaml:47,91`; `ansible/roles/runtime_sync/templates/auth-users-database-sync.sh.j2:32`).
- **Provider facts** (portainer/portainer provider 1.26.0, locked in both `.terraform.lock.hcl`; source `internal/resource_stack.go@v1.26.0`):
  - `method`, `deployment_type`, `name`, `endpoint_id` and `repository_url` are `ForceNew`. `repository_reference_name` is not.
  - An in-place update of a repository stack calls `POST /stacks/{id}/git` and then `PUT /stacks/{id}/git/redeploy`.
- **Portainer server facts** (`portainer/portainer-ee:2.39.6`, `stacks/management/docker-compose.yml:99`; checked against CE tag `2.39.0`):
  - `api/git/git.go` resolves a Git reference by listing remote refs and matching `ref.Name()` with `strings.EqualFold`. It fails with `could not find ref` otherwise, so a raw commit SHA is not a usable reference. Branch and tag refs are.
  - `api/stacks/deployments/deploy.go` (`redeployWhenChanged`) returns `nil` for a stack with no `GitConfig`, commented "do nothing if it isn't a git-based stack". The webhook handler then answers 200.
- **hashicorp/http 3.5.0** is locked. Its 3.0.0 changelog says "Response status code is not checked anymore".
- **JoseStud/stacks is public.** Unauthenticated `git ls-remote` and clone both work. Its CI runs on pushes to `main` only, so updating another branch does not start CI.
- **The stacks repo `main` already carries a deployment-tag mechanism that the gitlink does not include.** Commit `7bf6d43` ("Publish immutable deployment tags after stacks validation", one commit ahead of the gitlink `6b00086`) adds a `publish-deploy-tag` job. That job pushes a lightweight `refs/tags/deploy-<sha>` after validation, using the job-scoped `GITHUB_TOKEN`. The commit also adds a README section stating "Portainer uses `refs/tags/deploy-<SHA>`". Nothing in this repo implements that statement. `refs/tags/deploy-7bf6d43…` exists on the remote. No tag exists for `6b00086`.

## Goals / Non-Goals

**Goals:**
- Every Portainer redeploy, whether from the orchestrator, the agent helper or `scripts/portainer-webhook.sh`, deploys a commit that passed `stacks-sha-trust`.
- Keep the health gate as the only step that rolls new compose content out to existing stacks, so it keeps its dependency order and stop-at-first-failure containment.
- A missing, unreadable or empty manifest fails `terraform plan` and cannot produce a destroy plan.
- Rollout and rollback are both in-place updates. No stack is destroyed.

**Non-Goals:**
- Changing the trust algorithm (`stacks-trust-verification` is untouched) or how the trusted SHA is chosen.
- Changing the agent webhook helper, the webhook URL publication, or the Ansible-owned `management` stack.
- Defending against a compromise of stacks `main` itself. That is the trust gate's job.
- Changing `scripts/portainer-webhook.sh`. It inherits the pinned behavior through the reference.

## Decisions

### D1. Pin content with a moving `refs/heads/deploy` that only automation moves (option 1)

| Option | Pins webhooks? | Keeps ordered, contained rollout? | Credential in infra | Rollout blast radius | Verdict |
|---|---|---|---|---|---|
| (1) Moving `deploy` branch, advanced after trust | Yes | Yes. The reference never changes, so the apply does not redeploy stacks. | GitHub App or PAT with `contents: write` on stacks | 8 in-place git updates, once | **Chosen** |
| (2) `method = "string"` with compose from the pinned checkout | Content is pinned. Webhooks silently do nothing: Portainer answers 200 and skips non-Git stacks. | No. Every compose change becomes an apply-time update. | None | `method` is ForceNew, so all 8 stacks are destroyed and recreated (`docker stack rm` of everything, new webhook IDs) | Rejected |
| (3) Commit SHA as `repository_reference` | No. Portainer `could not find ref`. | n/a | None | n/a | Rejected |
| (3b) Immutable `refs/tags/deploy-<STACKS_SHA>` as the reference (stacks side already exists at `7bf6d43`) | Yes, immutable | No. The reference changes on every bump, so Terraform redeploys all 8 stacks at once (parallelism 10) before the gate runs. | None. Stacks CI publishes the tags. | 8 in-place updates on every bump | Strongest alternative, rejected |
| (3c) Tags plus `ignore_changes`, with the gate retargeting each stack through the Portainer API in order | Yes | Yes | None | Gate needs Portainer admin JWT. `POST /stacks/{id}/git` replaces `env`, so it must echo back Terraform-managed secrets. | Rejected as fragile |

Why (1) wins over (3b):
- **Containment.** With (3b), a bad compose change in gateway would already have been redeployed to all 8 stacks, all at once, by the time the gate stops at gateway. Today, and under (1), that change never reaches auth or any later stack.
- **Load.** Under (3b), every bump runs 8 `docker stack deploy` operations with image pulls at once on the Always Free nodes.
- **Rollback.** (3b) can roll back only to SHAs that have a tag. Every SHA up to and including today's gitlink `6b00086` has none.

What (3b) does better:
- It needs no long-lived write credential in this repo.
- The deployed ref is immutable.

If the owner values those two properties above ordered containment, (3b) is the fallback. It would replace the Deploy Reference Advancement requirement with a tag-existence check. See tasks 1.6 and 7.1 for the cross-repo reconciliation either way.

### D2. The stacks-deploy-ref stage

- **Placement:** after `portainer-api-preflight`, before `portainer-apply-debug` (`ci/src/ci_pipeline/__main__.py:180-204`). At that point `phase7_runtime_sync` and `sync-configs` have put the hosts on STACKS_SHA. So compose (via `deploy`) never moves ahead of configs, and Portainer reads compose only after the move. That covers new stacks created by the apply and the gate's webhooks.
- **Condition:** `run_portainer_apply or run_health_redeploy`. The stage skips with `stacks-deploy-ref: skipped (no stacks_sha)` when STACKS_SHA is empty, matching `preflight.stacks_sha_trust`.
- **Implementation:** a new `.github/scripts/stacks/advance_stacks_deploy_ref.sh`, run through a new `portainer.stacks_deploy_ref` Dagger function. It uses the `infisical` profile plus `openssl` for the App JWT, and `_wire_infisical`. It is bound to the proxy like its neighbours. `github.com` and `infisical.com` are in `NO_PROXY` (`ci/src/ci_pipeline/proxy.py:24-36`), so its traffic goes direct.
- **Algorithm:**
  1. Fetch the credential from Infisical and mint a token.
  2. `GET /repos/JoseStud/stacks/git/ref/heads/deploy`.
     - On 404: `POST /git/refs {"ref":"refs/heads/deploy","sha":…}`.
     - If the ref already equals STACKS_SHA: no-op.
     - Otherwise: `PATCH /git/refs/heads/deploy {"sha":…,"force":true}`. `force` is required so a gitlink revert can move `deploy` backwards. Trust accepts any ancestor of `main`.
  3. Read the ref back and compare it with STACKS_SHA.
- **Shadow mode:** steps 1 and 2 still run (mint and read) and the stage prints the intended move. Only the write is skipped. A SHADOW run therefore also proves the credential works.
- **Logging:** print only SHAs, HTTP status and GitHub's `message` field. Never use `curl -v`, never echo response bodies or headers, and never echo the JWT or token. The repo is public.

### D3. Credential: GitHub App, stored in Infisical

- **Recommended: a GitHub App** installed only on `JoseStud/stacks` with `Contents: read & write`. Its App ID and PEM private key live in Infisical `prod` `/management` as `STACKS_DEPLOY_APP_ID` and `STACKS_DEPLOY_APP_PRIVATE_KEY`.
  - The stage signs an RS256 JWT, looks up the installation with `GET /repos/JoseStud/stacks/installation`, and mints a 1-hour installation token narrowed to `repositories: ["stacks"]` and `permissions: {contents: write}`.
  - Only an App can be a ruleset bypass actor that differs from the owner. That lets the `deploy` ruleset say "only automation moves this", and keeps the App off the bypass list for `main`.
- **Alternatives:**
  - *Fine-grained PAT* (`contents: write` on stacks only). Simpler, but it acts as the owner, so a ruleset cannot tell automation from the human. It also expires.
  - *Deploy key with write access.* It can be a bypass actor, but it pushes over SSH and needs the commit object locally.
- **Why `/management`:** the CI OIDC identity already reads it (`portainer_apply.sh:22`). None of the agent templates read `/management` (they use `/infrastructure` and `/stacks/*`), and the agent's helper reads only `/deployments`. Keep the key out of `/deployments`, which the node-side agent identity reads.

### D4. Manifest from the pinned local checkout

- **Module changes:**
  - `terraform/portainer` reads `yamldecode(file(local.stacks_manifest_path))`, where the path is `coalesce(var.stacks_manifest_path, "${path.module}/../../stacks/stacks.yaml")`.
  - The module drops `data "http"`, the `hashicorp/http` requirement, the `github_repo_*` locals and the `stacks_sha`, `stacks_manifest_url` and `stacks_manifest_token` variables.
  - `terraform/portainer-root` declares and forwards `stacks_manifest_path` (default `null`). `terraform validate` treats root variables as unknown, so `file()` is not evaluated in the `validate-terraform.yml` matrix, which checks out without submodules.
  - Both lock files drop the `hashicorp/http` entry in the same commit, because `init -lockfile=readonly` rejects provider-set changes.
- **Apply-stage changes:** `portainer_apply.sh` calls `checkout_stacks_sha "${STACKS_SHA:-}"` before `init` and no longer exports `TF_VAR_stacks_sha`. `ci/src/ci_pipeline/phases/portainer.py:69-71` stops setting it. The Terraform image already has `git` (`ci/src/ci_pipeline/containers.py:128-132`).
- **Alternative: keep HTTP with `lifecycle.postcondition { condition = self.status_code == 200 }`.** This fixes the 404 case. It keeps a network dependency, still trusts whatever URL is configured, and still requires `stacks_sha`/URL plumbing. The local file is already the trusted bytes. Rejected, and the guards in D5 apply regardless.

### D5. Hard guards as preconditions on an always-present object

- **Mechanism:** a `terraform_data "stacks_manifest_guard"` resource with no `input`, carrying four `lifecycle.precondition` blocks: version is 1, the managed set is non-empty, every `compose_path` is non-blank, and every managed stack has an env map. It never changes after its first create, so "no changes" plans stay clean.
- **Not on `portainer_stack.swarm`:** with an empty `for_each` that resource has no instances, so its preconditions would never be evaluated. That is the exact case being closed.
- **Not `check` blocks:** they only warn, by design.
- **Effect of a failing precondition:** it errors during plan, so `-out` writes no plan, and `portainer_apply.sh` exits on `plan_exit == 1` (`:60-63`).
- **Alternative: attach the preconditions to `infisical_secret.webhook_urls_combined`,** which is also always present. This avoids a new state object but hides the intent. Acceptable if the owner prefers it.

### D6. Health redeploy verifies the ref before any webhook

- **Check:** after `exit_if_shadow_mode`, `health_gated_redeploy.sh` runs `git ls-remote https://github.com/JoseStud/stacks refs/heads/deploy`. This is unauthenticated, since the repo is public, and `git` is in the `webhook` profile. The stage exits 1 unless the result equals STACKS_SHA.
- **Why:** it catches a skipped or failed advance, or a ref someone moved, before eight redeploys run. It costs one request.

### Paths affected

- **Orchestrator path:** D2, D4, D5 and D6 all apply.
- **Local / break-glass path (`docs/deployment-runbook.md` "Setting Up Portainer GitOps for a New Stack", manual `scripts/portainer-webhook.sh`, direct `docker stack deploy -c /opt/stacks/...`):**
  - A local `terraform apply` now reads the operator's local `stacks/stacks.yaml` and defaults to `refs/heads/deploy`. The operator must put the submodule at the `deploy` commit first, or a new stack whose compose file is missing at `deploy` fails to create.
  - Manual webhooks redeploy the last trusted SHA.
  - Direct `docker stack deploy` from `/opt/stacks` is unchanged.
  - Moving `deploy` by hand needs the App, or a temporary ruleset edit. The runbook must say so.

## Risks / Trade-offs

- **[Write credential leaks: someone moves `deploy` to an arbitrary commit, and the next webhook deploys it with Docker-socket-level privileges]** → The App is installed on `stacks` only, with `contents: write`. Tokens are minted per run for 1 hour and narrowed. The key is stored only in Infisical. The `main` ruleset has no App bypass. D6 catches a moved ref on the next orchestrator run. Ref updates appear in the stacks repo activity log.
- **[`deploy` is advanced but a later stage fails]** → `deploy` and the hosts are already on STACKS_SHA. Agent-triggered webhooks then deploy compose that matches the synced configs. Running services that were not redeployed stay on the old commit until the next successful run. This is strictly better than today, where they can drift to any `main` HEAD.
- **[Agent webhook fires between `phase7_runtime_sync` and the advance]** → For a few minutes it redeploys the previous trusted commit. This is transient and self-correcting at the gate.
- **[Rollout touches all 8 stacks]** → Each gets an in-place `POST /git` and `PUT /git/redeploy`. The trusted gitlink `6b00086` and stacks `main` (`7bf6d43`) differ only in `.github/` and `README.md`, so compose content is identical today. Expect no service restarts except where `pull_image` finds a new digest for a mutable tag. Verify the plan in SHADOW_MODE first: 8 updates, 1 create, 0 destroy.
- **[`validate-terraform.yml` evaluates `file()` without the submodule]** → The root variable plumbing keeps the path unknown. If validation still fails, add `submodules: true` to that checkout (task 2.5).
- **[GitHub API or Infisical outage]** → The advance fails and the run stops before any Portainer change. Running stacks keep the last trusted commit. This fails closed.
- **[Stale stacks README tells readers Portainer uses deploy tags]** → Cross-repo task to rewrite that section and decide whether to keep `publish-deploy-tag`. Keeping it is harmless; the tags just go unused.
- **[Concurrent orchestrator runs]** → The concurrency group has `cancel-in-progress: true`. The surviving run re-advances `deploy` to its own STACKS_SHA, forward or backward.

## Migration Plan

1. **Owner, before merge** (tasks group 1):
   - Create and install the GitHub App, and store its ID and key in Infisical `/management`.
   - Create `refs/heads/deploy` at the current `HEAD:stacks` (`6b0008699ba5a4151fbeb0a81cfac2398d5d3c35`).
   - Add the ruleset on `refs/heads/deploy`: restrict updates and deletions, block force pushes, App as the only bypass actor.
2. Set repo variable `SHADOW_MODE=true` and merge. The orchestrator runs with `run_portainer_apply` because `terraform/**` changed. Confirm three things:
   - stacks-deploy-ref mints a token and reports "already at".
   - The Portainer plan shows exactly 8 in-place updates of `repository_reference_name`, 1 `terraform_data` create, and 0 destroys.
   - The guards pass.
3. Unset `SHADOW_MODE`, then run `workflow_dispatch` with `skip_ansible_bootstrap: true` and `force_health_redeploy: true`. Confirm that Portainer shows `refs/heads/deploy` for every stack, the gate passes, and the `WEBHOOK_URL_*` values did not change.
4. The next stacks gitlink bump exercises the full path, including the `deploy` move.

**Rollback:**
- Revert the merge commit. The orchestrator applies `refs/heads/main` and the HTTP manifest again, as one in-place update per stack, and the lock files come back.
- Leave `deploy` and the App in place, or delete them.
- Break-glass without a revert: `terraform -chdir=terraform/portainer-root apply -var repository_reference=refs/heads/main` from a checkout of the reverted code.

## Open Questions

- Does the owner prefer a fine-grained PAT, or a deploy key, over the GitHub App? This changes only the credential-acquisition function and tasks group 1, not the specs.
- Should the deploy credential live in a new Infisical folder such as `/ci` instead of `/management`? Nothing in the specs depends on the folder.
- Is the stacks ruleset "Immutable deployment tags" (named in the stacks README at `7bf6d43`) actually active? It matters only if the owner later picks the D1 fallback (3b).
