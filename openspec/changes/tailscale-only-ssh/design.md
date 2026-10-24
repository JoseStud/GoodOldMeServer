# Design

## Context

See proposal.md (Why) for the three defects. Facts this design relies on, checked against the code:

- **Public SSH is open.** `dmz-subnet` has no `security_list_ids` (terraform/oci/main.tf:95-102). Nothing manages `oci_core_default_security_list`. OCI's stock default list allows stateful TCP 22 from `0.0.0.0/0`, ICMP 3/4 from `0.0.0.0/0`, ICMP 3 from the VCN CIDR, and all egress. OCI applies the union of security lists and NSGs, so the per-CIDR NSG rule (terraform/oci/main.tf:189-203) narrows nothing. `gateway-nsg` has only INGRESS rules (:161-203), which means worker **egress today comes only from the default security list**.
- **The policy pipeline cannot work.** `dagger-pipeline` starts only after `infra-apply` has finished (.github/workflows/orchestrator.yml:129-131). `network_policy_sync` runs in layer 2 (ci/src/ci_pipeline/__main__.py:112-128), and `network_policy_revoke_ssh` runs last (:214-221). `main()` has no `finally` block (:226-231). The sync script writes the TFC variable and never starts a run (.github/scripts/stages/network_policy_sync.sh:30-31). `ansible_run.sh` keeps OCI hosts on public IPv4 when `RUN_INFRA_APPLY=true` (.github/scripts/stages/ansible_run.sh:13-18, 60-76).
- **The witness key is readable.** The witness interpolates the reusable key into `metadata.startup-script` (terraform/gcp/main.tf:146-186, :176). Global services with no placement constraint run on the witness: `portainer-agent` (stacks/management/docker-compose.yml:143-155), `node-exporter` and `cadvisor` (stacks/observability/docker-compose.yml:130-148, 167-182).
- **Changing user_data replaces an OCI worker.** The `oracle/oci` provider forces replacement when `metadata.user_data` or `ssh_authorized_keys` changes (`customdiff.ForceNewIfChange("metadata", …)` in `core_instance_resource.go`, verified on the provider's master branch). The lock pins 5.47.0 (terraform/oci/.terraform.lock.hcl:5-7). Terminating an instance deletes its boot volume unless `preserve_boot_volume` is set, and that attribute is unset here. GlusterFS bricks are addressed by Tailscale IP (ansible/roles/glusterfs/tasks/main.yml:91-93), so a replaced worker would break the volume.
- **Changing startup-script does not replace the witness.** The google provider updates `metadata["startup-script"]` in place. Only the separate `metadata_startup_script` attribute forces a recreate. GCE re-runs the script on every boot.
- **The Tailscale estate already works.** The runner joins as `tag:ci` (.github/workflows/orchestrator.yml:151-156). Non-infra runs already reach the OCI nodes over Tailscale. Phase 3 enrolled the OCI nodes without `--hostname`, so their Tailscale names follow the OS hostname (`app-worker-N`). The runner already tries `app-worker-N` as a fallback for `oci-node-N` (ansible_run.sh:115-117).
- **`oci_public_ips` must stay.** DNS sync reads it for the Cloudflare A records (dns-management "DNS Sync Inputs"), and the inventory renderer reads it to enumerate workers (.github/scripts/tfc/render_inventory_from_tfc_outputs.sh:46-56).

**Paths affected: both.** The orchestrator path changes: stages, transport and the infra apply. The local/break-glass path in docs/ also changes. `docs/deployment-runbook.md:280-295` (local `terraform -chdir=terraform/infra apply`) now needs the Tailscale OAuth secret, which it gets from Infisical through the same provider. `docs/ansible.md:11, 343-352` (local Ansible over public IPv4 with `TAILSCALE_AUTH_KEY`) becomes "operator machine on the tailnet". The break-glass ladder below replaces the "keep network policy sync enabled" control in the runbook's decision gate.

## Goals / Non-Goals

**Goals:**
- No public TCP 22 on any node outside an explicit, operator-started break-glass window.
- Every automated SSH session (CI Ansible) goes over Tailscale, on every run.
- No reusable Tailscale credential on any VM. Enrollment credentials are single-use and expire within an hour.
- The two existing workers and the witness are not replaced, rebooted or re-attached by the rollout.

**Non-Goals:**
- Retiring Infisical `TAILSCALE_AUTH_KEY` from the Ansible phase 3 role and from `secret_validation.sh`. Both are in a companion change; see proposal Impact.
- Rendering Tailscale hostnames in `inventory-ci.yml`. The public IPv4 there stays as a placeholder that the runner always overwrites.
- Making the `tailscale` CLI-absent branch fail closed (it belongs to node-provisioning "Tailscale Peer Resolution"). Even without that, the branch cannot reach OCI nodes once TCP 22 is closed.
- Managing the tailnet policy file (ACLs, `tagOwners`, SSH rules). It stays in the Tailscale admin console.
- Portainer bootstrap, stack pinning and Ansible tag scoping (separate changes).

## Decisions

### D1. Tailscale is the only automated SSH transport
`ansible_run.sh` drops the `RUN_INFRA_APPLY`/`PREFER_TAILSCALE_SSH` switch and always adds the `oci-node-N` aliases to the resolution list. Peer polling (300 s default) also covers a worker created by the same run, because cloud-init enrolls it within minutes. The failure hint at ansible_run.sh:137 ("valid reusable key") is rewritten to point at cloud-init and enrollment-key expiry. `preflight_network_access.sh` keeps its IPv4 branch. Only `portainer_api_preflight.sh` calls it, with `RUN_ANSIBLE=false` and `RUN_CONFIG=false`, so that branch is dormant; removing it is spec-only hygiene and is left out.
- *Alternative: keep public IPv4 for full runs and fix the policy timing* (run the sync before infra-apply, add an always-run revoke job). Rejected. It keeps a public management port, depends on GitHub runner egress IPs that are shared and reused, and adds a second TFC run per pipeline.

### D2. Close port 22 at the security list, and decouple egress
Add `oci_core_default_security_list` with `manage_default_resource_id = oci_core_vcn.main_vcn.default_security_list_id`, holding exactly: stateful egress all to `0.0.0.0/0`, ingress ICMP 3/4 from `0.0.0.0/0`, and ingress ICMP 3 from `10.0.0.0/16`. Add `gateway_egress_all` (EGRESS, all protocols, `0.0.0.0/0`) to `gateway-nsg`, and make the default list `depends_on` it, so egress never relies on one resource. `UpdateSecurityList` replaces the whole rule set in one call, so there is no egress gap during the apply. `dmz-subnet` stays as it is, with no `security_list_ids` diff.
- *Alternative: a dedicated security list attached via `security_list_ids`.* Rejected. It is an in-place subnet update for no gain, and the stock default list with its 22 rule would stay around to be re-attached by mistake.
- *Alternative: host firewall (OCI Ubuntu iptables).* Rejected. The repo doesn't manage it, and it doesn't fix the cloud-layer finding.

### D3. Keep `network_access_policy` as a manual break-glass, remove the automated stages
Remove both stages from `__main__.py` (the `manage_network_policy` branch and the revoke block) along with their functions in `phases/preflight.py`. Pass the disabled policy literal to `portainer_api_preflight` unconditionally. Keep the variable, its validation, the NSG `for_each`, and all scripts under `.github/scripts/network/` and `.github/scripts/stages/network_policy_{sync,revoke_ssh}.sh` as operator tools; they already support `BREAK_GLASS_POLICY_JSON/FILE` and `SHADOW_MODE`. The TFC variable is set to disabled by the owner. It keeps no Terraform default, so the workspace value stays authoritative and visible.
- *Alternative: remove the policy entirely* (variable, module inputs, NSG rule, scripts). Rejected for now. It would remove the only SSH path that works without Tailscale, and the spec removals would exceed one change. It can be revisited if the bastion option below is adopted.
- *Alternative: OCI Bastion service* (free). It needs the Bastion plugin on the instances and an ingress rule from the bastion's private endpoint subnet. Recorded as a future replacement for D3's NSG path.

### D4. Per-instance, single-use, tagged enrollment keys from the Tailscale provider
In terraform/infra:
```hcl
provider "tailscale" {
  oauth_client_id     = local.secrets.tailscale_oauth_client_id
  oauth_client_secret = local.secrets.tailscale_oauth_client_secret
  scopes              = ["auth_keys"]
}
resource "tailscale_tailnet_key" "oci_worker" {
  count         = 2
  reusable      = false
  ephemeral     = false
  preauthorized = true
  expiry        = 3600
  tags          = ["tag:server"]
  description   = "appworker${count.index + 1}"   # provider requires alphanumerics
  # recreate_if_invalid left at default: single-use keys are not recreated
}
resource "tailscale_tailnet_key" "witness" { /* same, description = "swarmwitness" */ }
```
The keys are passed as `module.oci.tailscale_auth_keys` (new sensitive `list(string)` input, validated to length 2) and as the existing `module.gcp.tailscale_auth_key`. The modules stay provider-agnostic. The OAuth client is a new Tailscale trust credential limited to `auth_keys` and `tag:server`. Its secret lives in Infisical `/infrastructure`, which TFC's Infisical identity already reads. The provider is pinned `~>` to the current minor version, and lock hashes are recorded for linux_amd64 and darwin_arm64, because validate-terraform runs `init -lockfile=readonly` (.github/workflows/validate-terraform.yml:67-68).
- *Why `recreate_if_invalid` stays unset ("never" for single-use keys):* with "always", every plan after expiry would replace the keys. That perpetual diff would block every infra-apply on manual confirmation and re-expose a fresh witness key each time.
- *Alternative: workload identity federation* (`identity_token_environment_variable_name = "TFC_WORKLOAD_IDENTITY_TOKEN"`, no stored secret). Deferred. The local break-glass `terraform apply` path would lose provider auth, and it needs TFC workspace settings plus a federated identity in Tailscale. It is a good follow-up.
- *Alternative: keep one reusable key and move it to GCP Secret Manager.* Rejected. It needs a service account, IAM and a startup-time fetch, and the key would still be reusable.
- *Alternative: ephemeral keys.* Rejected. Ephemeral nodes are removed when they go offline, which breaks Swarm and Gluster addressing.

### D5. OCI first-boot enrollment; existing workers protected from replacement
Extend the worker `#cloud-config` `runcmd` after the SSH CA lines. It installs Tailscale via `install.sh` (IPv4), runs `systemctl enable --now tailscaled`, then `tailscale up --authkey=<key> --ssh --hostname=app-worker-N --advertise-tags=tag:server --accept-dns=false --timeout=120s`, with the witness's retry pattern (3 attempts, 10 s apart). `runcmd` runs once per instance, so there is no re-run concern. Add to `oci_core_instance.app_worker`:
```hcl
lifecycle { ignore_changes = [metadata] }
```
Terraform core applies `ignore_changes` before the provider's `CustomizeDiff`, so the `ForceNewIfChange` never sees a diff. The existing workers keep their original user_data, which holds no key. Their keys are created and expire unused after an hour. To replace a worker on purpose, the operator replaces the instance **and** its key in one run (`-replace=module.oci.oci_core_instance.app_worker[i] -replace=tailscale_tailnet_key.oci_worker[i]`, or the TFC "replace" option); this is documented in docs/terraform/oci.md.
- *Alternative: `ignore_changes = [metadata["user_data"]]`.* Equivalent today, since `metadata` holds only `user_data`. The whole map is chosen so a future `ssh_authorized_keys` addition cannot trigger replacement either.

### D6. Witness startup script is idempotent across boots
After the existing `tailscaled` readiness wait, the script polls `tailscale status --json` for up to 60 s until `BackendState` leaves `NoState`/`Starting`. When it is `Running`, the script exits 0 without `tailscale up`. Otherwise it joins with the per-instance key (as in D4). The key now arrives from `tailscale_tailnet_key.witness.key`. On the existing witness the key update is an in-place metadata change, with no reboot. The witness is already enrolled, so the new key is never consumed: it stays readable from metadata until it expires one hour after the migration apply. After that, nothing in metadata is usable.

### D7. Break-glass ladder when Tailscale is unavailable
1. **Coordination-plane outage.** Existing WireGuard tunnels between enrolled nodes keep carrying Swarm, Gluster and Portainer traffic, and public 80/443 is unaffected. CI cannot enroll its ephemeral runner, so the orchestrator fails at "Connect to Tailnet" before mutating anything. Wait it out.
2. **One node off the tailnet, or Tailscale SSH broken.** Use the break-glass policy: the operator /32 via `network_policy_sync.sh` with `BREAK_GLASS_POLICY_JSON` (dry run with `SHADOW_MODE=true` first) or via the TFC UI. Then queue and confirm an infra run, with plan targeting on the `oci_core_network_security_group_security_rule.ssh` resources if other diffs are pending. Then SSH to the public IPv4 with a certificate signed by the SSH CA. sshd still listens on all interfaces and trusts the CA (cloud-init, terraform/oci/main.tf:130-139). Close the window with `network_policy_revoke_ssh.sh` and another infra run.
3. **sshd or networking broken on an OCI worker.** OCI Console Connection (serial console) with GRUB single-user boot. Ubuntu cloud users have no password.
4. **Witness unreachable.** It is quorum-only, so the cluster keeps 2 of 3 managers. Use the GCP serial console (requires `serial-port-enable` metadata and a local password). Alternatively, temporarily wire the gcp module's existing IPv6 `allow-ssh` inputs (unwired at the root) together with an `ssh-keys` metadata entry, since the witness's sshd does not trust the SSH CA.

### D8. Rollout in two pushes
Push A holds the pipeline and transport (D1, D3 code), and touches only `.github/**` and `ci/**`, so it triggers no orchestrator run. It is verified by `workflow_dispatch`, first with `SHADOW_MODE=true` and then a real `ansible_only=true` run. Push B holds the Terraform (D2, D4-D6) and triggers infra-apply, which needs manual confirmation. Push A goes first, so by the time port 22 closes no code path depends on it.

## Risks / Trade-offs

- [The TFC plan replaces a worker or the witness, destroying its boot volume and breaking Gluster] → `ignore_changes = [metadata]` on `app_worker`; the in-place `startup-script` key on the witness. The owner confirms the run only when the plan shows **0 to destroy** and no `app_worker`, `worker_volume_attachment` or `witness` replacement. Expected: 3 keys created, the default security list and NSG egress rule created, the witness updated in place, and NSG SSH rules destroyed.
- [Removing `oci_core_default_security_list` from the config later may reset or empty its rules] → The NSG egress rule (D2) keeps egress, and the docs say to edit the rules, never delete the resource. The destroy semantics of default resources were not verified, so treat them as unsafe.
- [Tailscale lockout: an untagged node's key expires, or the ACL lacks `tag:ci`→`tag:server` SSH] → Pre-rollout task: confirm all three machines carry `tag:server` (tagged devices have key expiry disabled) and that a non-shadow `ansible_only` dispatch succeeds over Tailscale. Then use the D7 ladder.
- [A worker is replaced later with an expired key and never joins] → It fails closed: the runner times out on peer resolution, no public exposure follows, and the error text names the cause. Recovery is the D5 paired `-replace`. A provider-forced replacement (e.g. a new `OCI_IMAGE_OCID`) also shows in the confirmed plan.
- [Unused witness key readable in metadata for up to 1 h after the migration apply] → It is single-use, so at most one rogue `tag:server` device could enroll. Optional post-apply step: revoke the three unused keys in the admin console. They are identifiable by description.
- [The OAuth secret leaks] → It can mint `tag:server` keys, the same blast radius as the old reusable key. But it never lands on a VM, it is scoped to `auth_keys` + `tag:server`, and it can be rotated in Infisical without touching the nodes.
- [Stale `network_access_policy` value (enabled, old runner /32) applied by push B] → Pre-merge task: set the TFC variable to disabled, and check the plan for SSH rule destruction.
- [The Tailscale plan does not offer OAuth clients] → OAuth clients are available on the free Personal plan today, and the owner confirms before rollout. If that changes, an API access token would be a spec-level change.
- [The exposed reusable `TAILSCALE_AUTH_KEY` stays valid] → Post-apply task: revoke it. Until the companion change retires the slot, store a fresh single-use `tag:server` key in Infisical `/infrastructure` `TAILSCALE_AUTH_KEY`, because `secret_validation.sh` still requires it for `RUN_ANSIBLE`.
- [`tailscale` CLI absent on a runner] → Resolution is skipped and SSH to the public IPv4 fails at the security list (fail closed). An explicit failure is deferred (Non-Goals).

## Migration Plan

1. **Owner, before any merge:** create the Tailscale OAuth client (`auth_keys` write, tag `tag:server`; check that `tagOwners` lets it assign the tag), and store `TAILSCALE_OAUTH_CLIENT_ID`/`TAILSCALE_OAUTH_CLIENT_SECRET` in Infisical `prod` `/infrastructure`. Confirm the three machines are `tag:server` with key expiry disabled. Set the TFC `network_access_policy` variable to `{"oci_ssh":{"enabled":false,"source_ranges":[]}}`.
2. **Push A** (pipeline and transport). Verify: a `workflow_dispatch` with `SHADOW_MODE=true` shows the new stage list and no network-policy logs. Then a real `ansible_only=true` dispatch succeeds over Tailscale.
3. **Push B** (Terraform). Review the TFC plan against the checklist in Risks, then confirm. Check from outside the tailnet that public TCP 22 is refused (`nc -z -w5 <public IP> 22` fails) and that 80/443 still answer. Check that the next orchestrator run is green.
4. **Owner, after apply:** revoke the old reusable key and, optionally, the three unused enrollment keys. Replace the Infisical `TAILSCALE_AUTH_KEY` value as described in Risks. Open the companion change listed in the proposal.
5. **Rollback:** see proposal Impact. Urgent public SSH uses D7 step 2, not a revert. Reverting push B restores the old witness script and needs a valid key in Infisical again; the default security list must be edited, never deleted.

## Open Questions

- What are the exact Tailscale machine names of the existing workers (`app-worker-N` or `oci-node-N`)? Resolution tries both, and new workers use `app-worker-N`, so this only affects docs.
- The key `expiry` value: one hour is the ceiling the spec allows. A shorter value (e.g. 30 min for the witness) can be tuned later without spec changes.
- Whether to adopt Tailscale workload identity federation for TFC later (D4 alternative).
