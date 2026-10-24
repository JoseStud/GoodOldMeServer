# cloud-infrastructure Specification

## Purpose
Provision the homelab's cloud hosts with Terraform: two OCI Ampere workers with networking, ingress and block storage, plus a GCP e2-micro Swarm witness that joins the Tailscale mesh at first boot. The terraform/infra root composes both modules from Infisical-sourced inputs and is applied through the Terraform Cloud infra workspace.

## Requirements

### Requirement: Infra Root Module Wiring
The terraform/infra root module SHALL require Terraform >= 1.5.0, declare no backend or cloud block, call module `oci` (source `../oci`) and module `gcp` (source `../gcp`), and expose output `oci_public_ips` from `module.oci.public_worker_ips` and output `gcp_witness_tailscale_hostname` from `module.gcp.witness_tailscale_hostname`.

#### Scenario: OCI module inputs
- **WHEN** the infra root is planned
- **THEN** module `oci` receives `oci_compartment_ocid`, `ssh_ca_public_key` and `oci_image_ocid` from the Infisical-sourced secrets
- **AND** it receives `ssh_enabled` and `ssh_allowed_cidrs` from `var.network_access_policy.oci_ssh.enabled` and `var.network_access_policy.oci_ssh.source_ranges`

#### Scenario: GCP module inputs
- **WHEN** the infra root is planned
- **THEN** module `gcp` receives only `gcp_project` and `tailscale_auth_key`
- **AND** the module's `ssh_enabled` stays at its default `false`, so no `allow-ssh` firewall is created

#### Scenario: Outputs after apply
- **WHEN** an apply of the infra root completes
- **THEN** `oci_public_ips` lists the public IPv4 addresses of both `app-worker` instances
- **AND** `gcp_witness_tailscale_hostname` equals the witness instance name `swarm-witness`

### Requirement: Provider Configuration and Version Pinning
The infra root SHALL declare providers `oracle/oci` `~> 5.0`, `hashicorp/google` `~> 5.0` and `Infisical/infisical` `>= 0.8.0`, configure infisical with host `https://app.infisical.com`, oci with API-key auth and region `var.oci_region` (default `us-ashburn-1`), and google with the Infisical `GCP_PROJECT_ID` and region `us-central1`; the repository MUST commit `.terraform.lock.hcl` for terraform/infra, terraform/oci and terraform/gcp.

#### Scenario: OCI API-key credentials
- **WHEN** the infra root is planned
- **THEN** the oci provider authenticates with `var.oci_tenancy_ocid`, `var.oci_user_ocid`, `var.oci_fingerprint` and `var.oci_private_key`, which are sensitive string variables without defaults
- **AND** `var.infisical_project_id` is a required string variable without default

#### Scenario: Locked provider versions
- **WHEN** `terraform init` runs in terraform/infra with the committed lock file
- **THEN** it selects oracle/oci 5.47.0, hashicorp/google 5.45.2 and Infisical/infisical 0.16.5
- **AND** the terraform/oci lock file pins oracle/oci 5.47.0 and the terraform/gcp lock file pins hashicorp/google 5.45.2, while terraform/gcp/main.tf declares no `required_providers` block

#### Scenario: Ignored local Terraform artifacts
- **WHEN** files under terraform/ are staged for commit
- **THEN** terraform/.gitignore excludes `.terraform/`, `*.tfstate`, `*.tfstate.*`, `*.backup`, `*.log`, `*.pem`, `terraform.tfvars` and `*.tfplan`
- **AND** `.terraform.lock.hcl` files are not ignored

### Requirement: Infisical-Sourced Inputs
The infra root SHALL read secrets through `infisical_secrets` data sources in environment `prod` of workspace `var.infisical_project_id`: `SSH_CA_PUBLIC_KEY` from `/security`, `OCI_COMPARTMENT_OCID` and `OCI_IMAGE_OCID` from `/cloud-provider/oci`, `GCP_PROJECT_ID` from `/cloud-provider/gcp`, and `TAILSCALE_AUTH_KEY` from `/infrastructure`.

#### Scenario: Secrets resolved at plan time
- **WHEN** the infra root is planned
- **THEN** `local.secrets` exposes `ssh_ca_public_key`, `oci_compartment_id`, `oci_image_ocid`, `gcp_project_id` and `tailscale_auth_key` from those folders
- **AND** these values feed the module inputs and the google provider project

#### Scenario: Missing secret key
- **WHEN** one of the referenced keys is absent from its Infisical folder
- **THEN** the plan fails with an invalid map index error for that key

### Requirement: Terraform Cloud Infra Apply
When compute-context sets `run_infra_apply` to `true`, the orchestrator `infra-apply` job SHALL upload the `terraform` directory as a configuration version to workspace `TFC_WORKSPACE_INFRA` (default `goodoldme-infra`), create a run, and wait for it with manual confirmation required, failing when the run has auto-apply enabled or reaches `errored`, `canceled`, `discarded` or `force_canceled`.

#### Scenario: Confirmed apply
- **WHEN** the run is confirmed in Terraform Cloud and reaches `applied`, or reaches `planned_and_finished` with no changes and nothing to confirm
- **THEN** the wait step exits successfully
- **AND** the wait is bounded by `vars.TFC_INFRA_APPLY_WAIT_TIMEOUT_SECONDS` (default 7200 seconds) and polls every `vars.TFC_PLAN_POLL_INTERVAL_SECONDS` (default 10 seconds)

#### Scenario: Failed or timed-out run
- **WHEN** the run reaches a terminal failure status, has auto-apply enabled before reaching a success status, or exceeds the wait timeout
- **THEN** the infra-apply job fails
- **AND** the `dagger-pipeline` job does not run, because it requires infra-apply to have succeeded or been skipped

#### Scenario: Shadow mode
- **WHEN** `SHADOW_MODE` is true for the infra-apply job
- **THEN** the configuration upload and run creation still execute
- **AND** the wait step skips polling and exits 0

### Requirement: OCI Network Topology
The oci module SHALL create VCN `production-vcn` (`10.0.0.0/16`), enabled internet gateway `production-igw`, manage the VCN default route table as `production-default-rt` with one `0.0.0.0/0` `CIDR_BLOCK` route to the internet gateway, and create subnet `dmz-subnet` (`10.0.1.0/24`) on that route table, tagging these resources `project=goodoldme` and `managed_by=terraform`.

#### Scenario: Internet egress for workers
- **WHEN** the oci module is applied
- **THEN** instances in `dmz-subnet` route `0.0.0.0/0` traffic through `production-igw`
- **AND** the VCN, gateway, route table and subnet carry freeform tags `project=goodoldme` and `managed_by=terraform`

### Requirement: OCI Worker Instances
The oci module SHALL create two `VM.Standard.A1.Flex` instances `app-worker-1` and `app-worker-2` with 2 OCPUs, 12 GB memory and a 50 GB boot volume from `var.oci_image_ocid`, each with a public IP in `dmz-subnet` and its VNIC in `gateway-nsg`, placed in the availability domain at index `count.index` modulo the AD count, and booted with cloud-init that trusts the SSH CA.

#### Scenario: Availability domain spread
- **WHEN** the compartment exposes more than one availability domain
- **THEN** `app-worker-1` is placed in the first AD and `app-worker-2` in the second
- **AND** with a single availability domain both workers are placed in it

#### Scenario: SSH CA trust via cloud-init
- **WHEN** a worker boots for the first time
- **THEN** the base64-encoded `#cloud-config` runcmd writes `var.ssh_ca_public_key` to `/etc/ssh/trusted-user-ca-keys.pem`
- **AND** it appends `TrustedUserCAKeys /etc/ssh/trusted-user-ca-keys.pem` to `/etc/ssh/sshd_config` and runs `systemctl restart sshd`

### Requirement: OCI Worker Ingress Rules
The oci module SHALL attach every worker VNIC to `gateway-nsg`, whose INGRESS rules allow TCP 80 and TCP 443 from `0.0.0.0/0`; it SHALL create one TCP 22 NSG rule per CIDR only when the network policy enables SSH, and `dmz-subnet` SHALL set no `security_list_ids`, so it uses the VCN's default security list, which this Terraform does not manage.

#### Scenario: SSH enabled by the network policy
- **WHEN** `network_access_policy.oci_ssh` has `enabled = true` and two source ranges
- **THEN** `gateway-nsg` contains one INGRESS TCP 22 rule per source range with source type `CIDR_BLOCK` and description "SSH access — restricted to approved runner CIDRs"
- **AND** the TCP 80 and TCP 443 rules from `0.0.0.0/0` are also present

#### Scenario: SSH disabled by the network policy
- **WHEN** `network_access_policy.oci_ssh.enabled` is `false`
- **THEN** no TCP 22 rule exists in `gateway-nsg`, and previously created SSH rules are destroyed on that apply
- **AND** the TCP 80 and TCP 443 rules remain

#### Scenario: Subnet security list
- **WHEN** `dmz-subnet` is created
- **THEN** it has no `security_list_ids`, so OCI applies the default security list of `production-vcn`
- **AND** no Terraform resource in this repository manages that default security list or any other security list

### Requirement: OCI Block Storage and Backups
The oci module SHALL create two 50 GB block volumes `worker-volume-0` and `worker-volume-1` in the same availability domain as their workers, assign each the backup policy whose `display_name` is `silver`, and attach each volume to the worker with the same index using attachment type `paravirtualized`.

#### Scenario: Volume attachment pairing
- **WHEN** the oci module is applied
- **THEN** `worker-volume-0` is attached to `app-worker-1` and `worker-volume-1` to `app-worker-2` as paravirtualized attachments
- **AND** both volumes carry freeform tags `project=goodoldme` and `managed_by=terraform`

#### Scenario: Silver backup policy assignment
- **WHEN** the backup policy is resolved
- **THEN** the first result of `oci_core_volume_backup_policies` filtered by `display_name = "silver"` is assigned to both volumes

### Requirement: OCI Module Input Validation
The oci module MUST reject `oci_compartment_ocid` not matching `^ocid1\.compartment\.oc1\..*$`, `oci_image_ocid` not matching `^ocid1\.image\.oc1\..*$`, and `ssh_allowed_cidrs` containing an invalid CIDR or a value with `:`, or empty while `ssh_enabled` is true; `oci_image_ocid` and `ssh_allowed_cidrs` have no default, `ssh_enabled` defaults to `true`, and `ssh_ca_public_key` is sensitive.

#### Scenario: Invalid compartment OCID
- **WHEN** `oci_compartment_ocid` does not start with `ocid1.compartment.oc1.`
- **THEN** validation fails with "Must be a valid OCI compartment OCID (ocid1.compartment.oc1...)."

#### Scenario: Non-IPv4 or empty SSH CIDRs
- **WHEN** `ssh_allowed_cidrs` contains an IPv6 CIDR, or is empty while `ssh_enabled` is true
- **THEN** validation fails with "ssh_allowed_cidrs must contain valid IPv4 CIDRs and must be non-empty when ssh_enabled=true."

### Requirement: GCP Witness Networking
The gcp module SHALL create VPC `hybrid-swarm-network` without auto-created subnets, subnet `hybrid-swarm-ipv6-subnet` (`10.0.0.0/24` in `var.gcp_region`, default `us-central1`) with stack type `IPV4_IPV6` and `EXTERNAL` IPv6 access, firewalls `allow-icmp` (ICMP from `0.0.0.0/0`) and `allow-icmpv6` (protocol 58 from `::/0`), and firewall `allow-ssh` only when `ssh_enabled` is true (default `false`).

#### Scenario: Default SSH posture
- **WHEN** the gcp module is applied with default inputs, as the infra root does
- **THEN** no `allow-ssh` firewall exists

#### Scenario: Break-glass SSH firewall
- **WHEN** `ssh_enabled` is true and `ssh_allowed_cidrs` holds IPv6 CIDRs
- **THEN** firewall `allow-ssh` allows TCP 22 from those CIDRs to instances tagged `ssh-access`

#### Scenario: Invalid witness SSH CIDRs
- **WHEN** `ssh_allowed_cidrs` contains an IPv4 or invalid CIDR, or is empty while `ssh_enabled` is true
- **THEN** validation fails with "ssh_allowed_cidrs must contain valid IPv6 CIDRs and must be non-empty when ssh_enabled=true."

### Requirement: GCP Witness Instance
The gcp module SHALL create instance `swarm-witness` of machine type `e2-micro` in `var.gcp_zone` (default `us-central1-a`) booting `debian-cloud/debian-12`, with network tag `ssh-access`, labels `project=goodoldme` and `managed_by=terraform`, a dual-stack interface on `hybrid-swarm-ipv6-subnet` with a `PREMIUM`-tier IPv6 access config and no IPv4 access config, and metadata `enable-oslogin = "FALSE"`.

#### Scenario: No external IPv4
- **WHEN** the witness is created
- **THEN** it receives an external IPv6 address and no external IPv4 address

#### Scenario: OS Login disabled
- **WHEN** the witness metadata is applied
- **THEN** instance metadata sets `enable-oslogin` to `FALSE`, disabling GCP OS Login for the witness

### Requirement: Witness Tailscale Bootstrap
The witness `startup-script` SHALL create user `debian` with passwordless sudo when missing, install Tailscale over IPv6 from `https://tailscale.com/install.sh` when absent, enable `tailscaled`, and run `tailscale up` with the Infisical `TAILSCALE_AUTH_KEY`, `--ssh`, `--hostname=swarm-witness`, `--advertise-tags=tag:server`, `--accept-dns=false` and `--timeout=120s`, trying install and join up to 3 times each.

#### Scenario: First boot joins the tailnet
- **WHEN** the witness boots and the `debian` user does not exist
- **THEN** the script creates `debian` with a bash shell, adds it to group `sudo` and writes `/etc/sudoers.d/debian` (`NOPASSWD:ALL`, mode 440)
- **AND** after `tailscaled` is active with socket `/run/tailscale/tailscaled.sock` (waited up to 60 seconds), the witness joins the tailnet as `swarm-witness` with tag `tag:server` and Tailscale SSH, and the script exits 0

#### Scenario: Install or join keeps failing
- **WHEN** the Tailscale install fails 3 times, or `tailscale up` fails 3 times
- **THEN** the script exits 1 with "Failed to install Tailscale after 3 attempts" or "Failed to authenticate the witness with Tailscale after 3 attempts"
- **AND** it sleeps 10 seconds between attempts and restarts `tailscaled` between join attempts
