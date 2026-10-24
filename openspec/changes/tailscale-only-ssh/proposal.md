# Proposal

## Why

Public SSH on the OCI workers is open to the whole internet. `dmz-subnet` sets no `security_list_ids` (terraform/oci/main.tf:95-102), so the VCN default security list applies, and its stock TCP 22 rule from `0.0.0.0/0` is unioned with `gateway-nsg`. The runner-IP policy that was meant to narrow SSH cannot take effect: it is written after `infra-apply` has finished and never starts a run, and its revoke step is skipped whenever an earlier stage fails. Separately, the witness carries a reusable Tailscale auth key in instance metadata (terraform/gcp/main.tf:176), where any process on that VM can read it, including Swarm global services. Every node is already on the tailnet, so public SSH is not needed and can be closed.

## What Changes

- **BREAKING (network)**: Terraform manages the `production-vcn` default security list. It keeps all egress and the ICMP type 3 rules and has no TCP 22 ingress. `gateway-nsg` also gets an all-protocol egress rule, so egress no longer depends on the security list alone.
- `network_access_policy` stays as a **manual, operator-only break-glass**. Its TFC variable is set to disabled and nothing automated writes it. An NSG TCP 22 rule exists only while the operator has enabled the policy for specific /32s.
- **BREAKING (CI)**: The orchestrator no longer has the `network-policy-sync` and `network-policy-revoke-ssh` stages. `network_policy_sync.sh` and `network_policy_revoke_ssh.sh` are kept as the operator's break-glass tools.
- **BREAKING (CI)**: `ansible_run.sh` always sends OCI hosts and the witness over Tailscale. The `RUN_INFRA_APPLY`-dependent public-IPv4 path and the `PREFER_TAILSCALE_SSH=false` behaviour are removed.
- New OCI workers join the tailnet at first boot through cloud-init (`--ssh`, `--hostname=app-worker-N`, `tag:server`). A fresh node never needs public SSH. The existing workers are protected from replacement with `lifecycle.ignore_changes` on `metadata`.
- Each instance (both workers and the witness) gets its own Tailscale auth key, created with the `tailscale/tailscale` provider: single-use, pre-authorized, tagged `tag:server`, expiring within one hour and never recreated. The provider authenticates with a new Tailscale OAuth client stored in Infisical `/infrastructure`. Terraform stops reading `TAILSCALE_AUTH_KEY`.
- The witness startup script skips `tailscale up` when the node is already `Running`, so re-runs on boot never use a consumed or expired key.

## Capabilities

### New Capabilities
- (none)

### Modified Capabilities
- `cloud-infrastructure`: OCI ingress/security-list posture, per-instance tailnet enrollment keys (new requirement), witness bootstrap key source and boot-time idempotence, Infisical inputs (OAuth client replaces `TAILSCALE_AUTH_KEY`).
- `network-access-policy`: removes the automated runner sync and revocation stages. The scripts' shadow-mode contract now describes operator use, not pipeline use.
- `node-provisioning`: SSH transport selection is always Tailscale.
- `ci-pipeline-orchestration`: stage layering and run conditions no longer include the network-policy stages.

## Impact

**Blast radius**
- OCI workers: no instance update or replacement, and no restart. The default security list's rule set is replaced (public TCP 22 is dropped). Any `gateway-nsg` TCP 22 rules are destroyed once the TFC variable is disabled. One NSG egress rule is added. Block volumes, attachments, GlusterFS bricks (`/mnt/app_data/gluster_brick`) and node-local DB directories are not touched, provided the TFC plan is confirmed only when it shows no `app_worker`, `worker_volume_attachment` or `witness` replacement.
- GCP witness: `metadata.startup-script` is updated in place (google provider; not `metadata_startup_script`). There is no reboot and no replacement, and the arbiter brick at `/mnt/arbiter_brick` is untouched.
- Stacks and services: nothing restarts. HTTP/HTTPS ingress (`gateway_http`, `gateway_https`) is unchanged. Portainer DB and stacks are untouched.
- Tailscale: one new OAuth client, and three keys created on the first apply after this change. The old reusable key must be revoked, because it has been exposed through metadata.
- CI: runs no longer write the TFC `network_access_policy` variable. Ansible needs the runner's tailnet connection on every run, including full runs.

**Rollback**
- Pipeline and transport: `git revert`. The stage scripts are kept, so the stages come back cleanly. Do not revert the transport while public TCP 22 is closed; if public SSH is needed, use the break-glass policy.
- Public SSH needed urgently: set `network_access_policy` to the operator /32 and queue an infra run. Do not revert the security list.
- Terraform: revert the key and cloud-init parts. The witness metadata then returns to the Infisical key, which must be a valid key again. **Never** roll back by deleting `oci_core_default_security_list` from the config. To restore the old posture, edit its rules and keep the egress rule.

**Code**: terraform/infra/main.tf and lock file, terraform/oci/main.tf, terraform/gcp/main.tf, ci/src/ci_pipeline/__main__.py, ci/src/ci_pipeline/phases/preflight.py, .github/scripts/stages/ansible_run.sh, ansible/inventory/terraform.yml, and docs/ (network-architecture, terraform/oci, terraform/gcp, ansible, scripts, ci-orchestrator-execution-rules, github-actions-workflows, infisical-workflow, deployment-runbook, meta-pipeline-cutover-checklist), plus README.md.

**New credentials the owner must create**: a Tailscale OAuth client with only the `auth_keys` write scope and tag `tag:server`, stored as `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET` in Infisical `/infrastructure`. This is separate from the GitHub `TS_OAUTH_CLIENT_ID`/`TS_OAUTH_SECRET` used for `tag:ci`.

**Billing**: none. The default security list, the NSG rule, Tailscale keys and OAuth clients are free (Tailscale Personal plan; the owner should confirm OAuth clients are enabled). No new OCI or GCP resources.

**Cross-repo**: none. The stacks repo is unaffected.

**Deferred to a companion change (validator delta limit)**: these baseline statements still describe the removed stages or `TAILSCALE_AUTH_KEY` and must be brought in line before or with archive:
- ci-pipeline-orchestration: "Stage Failure Semantics", "Shadow Mode Propagation", "Containerized Stage Provisioning", "Inventory Handover".
- dns-management: "DNS Sync Pipeline Placement".
- stacks-trust-verification: "Orchestrator Preflight Enforcement".
- network-access-policy: "Portainer API Preflight Invocation".
- secrets-management: "Terraform Secret Consumption", plus "Infrastructure and Bootstrap Secret Validation" and "Infisical Seed Script" when `TAILSCALE_AUTH_KEY` is retired.
- node-provisioning: "Tailscale Enrollment" and "Tailscale Peer Resolution" (make a missing `tailscale` CLI fail closed).
