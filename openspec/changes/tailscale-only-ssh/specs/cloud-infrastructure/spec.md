# Spec Delta

## MODIFIED Requirements

### Requirement: Infisical-Sourced Inputs
The infra root SHALL read secrets through `infisical_secrets` data sources in environment `prod` of workspace `var.infisical_project_id`: `SSH_CA_PUBLIC_KEY` from `/security`, `OCI_COMPARTMENT_OCID` and `OCI_IMAGE_OCID` from `/cloud-provider/oci`, `GCP_PROJECT_ID` from `/cloud-provider/gcp`, and `TAILSCALE_OAUTH_CLIENT_ID` and `TAILSCALE_OAUTH_CLIENT_SECRET` from `/infrastructure`; it MUST NOT read `TAILSCALE_AUTH_KEY`.

#### Scenario: Secrets resolved at plan time
- **WHEN** the infra root is planned
- **THEN** `local.secrets` exposes `ssh_ca_public_key`, `oci_compartment_id`, `oci_image_ocid`, `gcp_project_id`, `tailscale_oauth_client_id` and `tailscale_oauth_client_secret` from those folders
- **AND** these values feed the module inputs, the google provider project and the tailscale provider credentials

#### Scenario: Missing secret key
- **WHEN** one of the referenced keys is absent from its Infisical folder
- **THEN** the plan fails with an invalid map index error for that key

#### Scenario: Reusable auth key no longer consumed
- **WHEN** `TAILSCALE_AUTH_KEY` is absent from `/infrastructure`, or holds any value
- **THEN** the infra plan is unaffected
- **AND** no Terraform-managed instance metadata or user data contains that value

### Requirement: OCI Worker Ingress Rules
The oci module SHALL attach every worker VNIC to `gateway-nsg`, whose INGRESS rules allow TCP 80 and TCP 443 from `0.0.0.0/0` and whose EGRESS rule allows all protocols to `0.0.0.0/0`; it SHALL create one TCP 22 NSG rule per CIDR only when the operator-set network policy enables SSH, and it SHALL manage the VCN default security list that `dmz-subnet` uses so that it admits no TCP 22 ingress.

#### Scenario: SSH enabled by the network policy
- **WHEN** the operator has set `network_access_policy.oci_ssh` to `enabled = true` with two source ranges and an infra run applies it
- **THEN** `gateway-nsg` contains one INGRESS TCP 22 rule per source range with source type `CIDR_BLOCK` and description "SSH access — restricted to approved runner CIDRs"
- **AND** the TCP 80 and TCP 443 rules from `0.0.0.0/0` are also present

#### Scenario: SSH disabled by the network policy
- **WHEN** `network_access_policy.oci_ssh.enabled` is `false`, its value outside an operator break-glass window
- **THEN** no TCP 22 rule exists in `gateway-nsg`, and previously created SSH rules are destroyed on that apply
- **AND** the TCP 80 and TCP 443 rules remain

#### Scenario: Subnet security list
- **WHEN** the oci module is applied
- **THEN** the default security list of `production-vcn`, which `dmz-subnet` uses because it sets no `security_list_ids`, is managed by Terraform and holds exactly a stateful EGRESS rule for all protocols to `0.0.0.0/0`, an INGRESS ICMP type 3 code 4 rule from `0.0.0.0/0` and an INGRESS ICMP type 3 rule from `10.0.0.0/16`
- **AND** it holds no TCP 22 rule, and no other security list is attached to `dmz-subnet`

#### Scenario: Public SSH closed by default
- **WHEN** an internet host connects to a worker's public IPv4 on TCP 22 while the network policy is disabled
- **THEN** neither the default security list nor `gateway-nsg` admits the connection

#### Scenario: Egress independent of the security list
- **WHEN** the default security list's rules are reset, emptied or edited
- **THEN** workers keep outbound connectivity, including Tailscale, through the `gateway-nsg` EGRESS rule

### Requirement: Witness Tailscale Bootstrap
The witness `startup-script` SHALL create user `debian` with passwordless sudo when missing, install Tailscale over IPv6 from `https://tailscale.com/install.sh` when absent, enable `tailscaled`, and, unless the node is already connected, run `tailscale up` with the witness's single-use enrollment key, `--ssh`, `--hostname=swarm-witness`, `--advertise-tags=tag:server`, `--accept-dns=false` and `--timeout=120s`, trying install and join up to 3 times each.

#### Scenario: First boot joins the tailnet
- **WHEN** the witness boots and the `debian` user does not exist
- **THEN** the script creates `debian` with a bash shell, adds it to group `sudo` and writes `/etc/sudoers.d/debian` (`NOPASSWD:ALL`, mode 440)
- **AND** after `tailscaled` is active with socket `/run/tailscale/tailscaled.sock` (waited up to 60 seconds) and its backend is not `Running`, the witness joins the tailnet as `swarm-witness` with tag `tag:server` and Tailscale SSH using its own key, and the script exits 0

#### Scenario: Later boot of an enrolled witness
- **WHEN** the startup script re-runs on a later boot and `tailscale status --json` reports `BackendState` `Running` within 60 seconds of `tailscaled` becoming active
- **THEN** the script runs no `tailscale up`, so the used or expired key is never presented
- **AND** the script exits 0

#### Scenario: Install or join keeps failing
- **WHEN** the Tailscale install fails 3 times, or `tailscale up` fails 3 times
- **THEN** the script exits 1 with "Failed to install Tailscale after 3 attempts" or "Failed to authenticate the witness with Tailscale after 3 attempts"
- **AND** it sleeps 10 seconds between attempts and restarts `tailscaled` between join attempts

#### Scenario: No reusable key in metadata
- **WHEN** any process on the witness, including a Swarm global service container, reads the instance metadata
- **THEN** the only Tailscale credential it finds is the witness's single-use key, which is invalid once used or one hour after creation
- **AND** a change of that key updates `metadata.startup-script` in place without replacing or rebooting the witness

## ADDED Requirements

### Requirement: Tailnet Enrollment Keys
The infra root SHALL create one Tailscale auth key per OCI worker and one for the witness with the `tailscale/tailscale` provider, authenticated by the Infisical-sourced OAuth client. Each key MUST be single-use, pre-authorized, non-ephemeral, tagged `tag:server`, expire at most one hour after creation, and never be recreated once used or expired. Each OCI worker's first-boot cloud-init SHALL join the tailnet with its own key.

#### Scenario: Keys created and wired
- **WHEN** the infra root is applied
- **THEN** a `tailscale_tailnet_key` exists for each of `app-worker-1`, `app-worker-2` and `swarm-witness` with `reusable = false`, `preauthorized = true`, `ephemeral = false`, `tags = ["tag:server"]` and an `expiry` of at most 3600 seconds
- **AND** module `oci` receives the worker keys in instance order, and module `gcp` receives the witness key as `tailscale_auth_key`
- **AND** the tailscale provider requests only the `auth_keys` scope, and `tailscale/tailscale` is pinned in the committed terraform/infra lock file

#### Scenario: Used or expired keys stay put
- **WHEN** a later plan runs after a key has been used or has expired
- **THEN** the plan proposes no new key and no change to any instance's metadata

#### Scenario: Fresh OCI worker joins at first boot
- **WHEN** an `app-worker-N` instance is created
- **THEN** its cloud-init, after the SSH CA steps, installs Tailscale from `https://tailscale.com/install.sh`, enables `tailscaled` and runs `tailscale up` with that worker's key, `--ssh`, `--hostname=app-worker-N`, `--advertise-tags=tag:server` and `--accept-dns=false`, trying install and join up to 3 times each
- **AND** the worker becomes reachable over Tailscale without any public TCP 22 rule

#### Scenario: Existing workers are not replaced
- **WHEN** this configuration is first applied while `app-worker-1` and `app-worker-2` are running
- **THEN** changes to their `metadata` are ignored, and the plan shows no update or replacement of either instance or of `worker_volume_attachment`
- **AND** a worker receives a new key only when that worker and its key are replaced in the same run

#### Scenario: OAuth client missing or not allowed
- **WHEN** `TAILSCALE_OAUTH_CLIENT_ID` or `TAILSCALE_OAUTH_CLIENT_SECRET` is missing, or the OAuth client may not create `tag:server` keys
- **THEN** the plan or apply fails before any instance is created and before any instance metadata is changed
