# Proposal

## Why

The stacks trust gate checks a SHA that does not decide what runs. `stacks-sha-trust` verifies the gitlink SHA (`.github/scripts/stacks/verify_trusted_stacks_sha.sh`), but every Portainer stack is a Git stack that tracks `refs/heads/main` (`terraform/portainer/main.tf:274-279`, default at `terraform/portainer-root/main.tf:65-69`). `stacks_sha` only chooses which `stacks.yaml` is fetched (`terraform/portainer/main.tf:30-31,146-148`). As a result, every webhook redeploy pulls stacks `main` HEAD. That covers the health-gated redeploy (`.github/scripts/stacks/trigger_webhooks_with_gates.sh:94-102`) and the runtime agent's `/usr/local/bin/portainer-stack-webhook` (`ansible/roles/runtime_sync/templates/portainer-stack-webhook.sh.j2:48-65`). HEAD may be a commit whose CI is red or still pending. Meanwhile `/opt/stacks` and the GlusterFS configs come from the pinned SHA (`.github/scripts/stages/ansible_run.sh:152`), so the compose files and their configs can come from different commits. `docs/deployment-runbook.md:392` already admits this gap.

The manifest fetch can also wipe every stack. `data "http" "stacks_manifest"` (`terraform/portainer/main.tf:83-89`) never checks the status code. hashicorp/http 3.x (locked at 3.5.0) stopped failing on non-2xx responses: its 3.0.0 changelog says "Response status code is not checked anymore". A GitHub `404: Not Found` body is valid YAML, a map with no `stacks` key, so `try(local.stacks_manifest.stacks, {})` (`:150`) yields an empty set. The plan then destroys every `portainer_stack` and every `WEBHOOK_URL_*` secret, and `.github/scripts/stages/portainer_apply.sh:57-75` applies any plan that has changes unless `SHADOW_MODE` is set. The `check` blocks (`:231-263`) only warn.

## What Changes

- **New `deploy` branch in JoseStud/stacks.** After `stacks-sha-trust` passes, the orchestrator moves `refs/heads/deploy` to `STACKS_SHA`. This is a forced move, so a gitlink revert also rolls `deploy` back. The move happens after `sync-configs` and before `portainer-apply`, using a write-scoped GitHub credential read from Infisical. In `SHADOW_MODE` it skips the write.
- **BREAKING:** `repository_reference` defaults to `refs/heads/deploy` instead of `refs/heads/main` in `terraform/portainer-root` and `terraform/portainer`. Portainer, every stack webhook and the agent helper then deploy only commits that passed the trust gate. Webhooks, stack IDs and `WEBHOOK_URL_*` values stay the same, because the provider updates `repository_reference_name` in place.
- **BREAKING:** the module reads `stacks.yaml` from the local `stacks` checkout with `file()` instead of over HTTP. The `http` data source, the `hashicorp/http` provider and the `stacks_manifest_url`, `stacks_manifest_token` and `stacks_sha` variables are removed. `portainer_apply.sh` pins the checkout to `STACKS_SHA` (`checkout_stacks_sha`) before `terraform init` and stops exporting `TF_VAR_stacks_sha`.
- **BREAKING:** the advisory `check` blocks become plan-time preconditions on an object that always exists. The plan now fails when the manifest version is not 1, when no stack is Portainer-managed, when a managed stack has a blank `compose_path`, or when a managed stack has no env map.
- Before it triggers any webhook, `health_gated_redeploy.sh` checks that `refs/heads/deploy` resolves to `STACKS_SHA` and fails if it does not.
- No billable resources. A GitHub App or fine-grained PAT is free.

## Capabilities

### New Capabilities

None.

### Modified Capabilities

- `stack-deployment`: the default stack source reference becomes `deploy`, and the orchestrator keeps that branch at the trusted SHA. The manifest comes from the pinned local checkout. Manifest problems fail the plan instead of warning. The apply stage pins its checkout, the stage order gains a deploy-ref stage, and the health redeploy verifies the ref before triggering webhooks.

## Impact

- **Code:** `terraform/portainer/main.tf` (variables, manifest locals, guards, `repository_reference`). `terraform/portainer-root/main.tf` (variables, `module` inputs). Both `.terraform.lock.hcl` files lose `hashicorp/http`. `.github/scripts/stages/portainer_apply.sh`, `.github/scripts/stages/health_gated_redeploy.sh`, and a new deploy-ref script under `.github/scripts/stacks/`. `ci/src/ci_pipeline/__main__.py` and `ci/src/ci_pipeline/phases/portainer.py` gain the new stage and lose `TF_VAR_stacks_sha`.
- **Cross-repo and owner work (JoseStud/stacks):** create the `deploy` branch, add a ruleset so only the automation identity can update or delete it, and create the credential (recommended: a GitHub App installed only on `stacks` with `contents: write`) and store it in Infisical. Also rewrite the stacks README section "Verified deployment tags", added on stacks `main` in `7bf6d43` and not yet in the gitlink. It claims Portainer uses `refs/tags/deploy-<SHA>`, an alternative that design.md D1 evaluates and rejects. No compose edits are needed.
- **Blast radius at rollout:** the first apply updates all 8 Portainer-managed stacks in place: gateway, auth, network, observability, ai-interface, home-dashboard, uptime and cloud. Each update is a Portainer `POST /stacks/{id}/git` followed by `PUT /stacks/{id}/git/redeploy`. Services restart only where the compose spec or a re-pulled image digest differs. If stacks `main` is ahead of the trusted SHA at that moment, stacks move back to the trusted content. The Ansible-owned `management` stack (Portainer, Homarr) is not touched. No stack is destroyed, so the Portainer DB keeps the same stack records and webhooks. GlusterFS bricks, block volumes and node-local DB directories are not touched. Nodes are not reprovisioned.
- **Steady state:** a stacks gitlink bump redeploys exactly the trusted SHA. An unreachable or broken manifest fails the plan instead of destroying stacks.
- **Rollback:** revert the merge commit. Terraform returns to `refs/heads/main`, which is again one in-place git redeploy per stack, and to the HTTP manifest. The `deploy` branch and the credential can stay or be deleted. For break-glass without a revert, run `terraform -chdir=terraform/portainer-root apply -var repository_reference=refs/heads/main` from a checkout of the reverted code. If `deploy` is ever left at the wrong SHA, the next orchestrator run moves it again, or a `workflow_dispatch` with `force_health_redeploy` does.
