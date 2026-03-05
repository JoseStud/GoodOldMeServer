# OCI Infrastructure

This module provisions the primary application infrastructure on Oracle Cloud Infrastructure (OCI) — two Ampere A1.Flex worker instances that run all Docker Swarm workloads, along with networking, security, and block storage.

## Architecture

The module creates:
- A **VCN** (`production-vcn`, `10.0.0.0/16`) with a **DMZ subnet** (`10.0.1.0/24`)
- **2\u00d7 VM.Standard.A1.Flex instances** (`app-worker-1`, `app-worker-2`) \u2014 each with 2 OCPUs, 12 GB RAM, and 50 GB boot volume. Instances are spread across availability domains using `count.index % length(ads)` for AD-level resilience
- A **Gateway NSG** with ingress rules allowing TCP port 80 (HTTP) and 443 (HTTPS) from `0.0.0.0/0`
- **2\u00d7 50 GB block volumes** (`worker-volume-0`, `worker-volume-1`) co-located in the same AD as their attached instance
- **Silver backup policy** assignments on both block volumes (daily backups, 5 retention)

> **OCI Free Tier caveat:** A1.Flex capacity may only be available in a single AD per tenancy. If provisioning fails due to capacity limits in AD-2, consider temporarily overriding to a single AD or retrying until capacity is available.

### SSH CA Integration

Each instance receives the SSH CA public key via **cloud-init** `user_data`:
1. Writes the CA key to `/etc/ssh/trusted-user-ca-keys.pem`
2. Adds `TrustedUserCAKeys` directive to `/etc/ssh/sshd_config`
3. Restarts sshd

This enables [certificate-based SSH authentication](../ansible.md#ssh-certificate-authentication) — Ansible presents a signed certificate instead of distributing individual SSH keys.

### Storage Layout

After Ansible runs the `storage` role:
- Block volume `/dev/sdb` → partitioned, formatted ext4 → mounted at `/mnt/app_data`
- GlusterFS brick created at `/mnt/app_data/gluster_brick`
- GlusterFS volume mounted at `/mnt/swarm-shared` (replica 3 arbiter 1 — 2 OCI workers + GCP witness arbiter)

> See [Backup Strategy](../backup-strategy.md) for details on the Silver backup policy.

## NSG Rule Rationale

The OCI module attaches every worker VNIC to `gateway-nsg` and applies these ingress rules:

| Rule | Source | Port/Protocol | Rationale | Risk posture |
|------|--------|---------------|-----------|--------------|
| `gateway_http` | `0.0.0.0/0` | TCP `80` | Required for HTTP entrypoint and redirect-to-HTTPS behavior in Traefik | Public by design; limited to web ingress only |
| `gateway_https` | `0.0.0.0/0` | TCP `443` | Required for TLS-terminated service ingress via Traefik | Public by design; service access further constrained at app/middleware layer |
| `ssh` | `ssh_allowed_cidrs` only | TCP `22` | Restricted operator/automation access for Ansible and break-glass operations | Must remain least-privilege; do not open globally |

## SSH Allowed CIDRs Guidance

`ssh_allowed_cidrs` is intended for deterministic automation egress ranges and must be IPv4 CIDRs. Prefer narrowly scoped `/32` ranges whenever possible.

Recommended pattern:

- `203.0.113.10/32` (single trusted runner egress IP)
- `198.51.100.25/32` (secondary trusted runner egress IP)

Avoid broad ranges:

- `0.0.0.0/0` (overly permissive, unacceptable)
- `203.0.113.0/24` (too broad unless formally justified and approved)

Operational note:

- Keep `ssh_allowed_cidrs` aligned with centralized `TF_VAR_network_access_policy.oci_ssh.source_ranges` so Terraform root validation and pipeline policy sync stay consistent.

## Regenerating Docs

```bash
terraform-docs markdown table terraform/oci/ > docs/terraform/oci.md
```

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_oci"></a> [oci](#requirement\_oci) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_oci"></a> [oci](#provider\_oci) | 5.47.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [oci_core_default_route_table.default_rt](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_default_route_table) | resource |
| [oci_core_instance.app_worker](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_instance) | resource (count=2) |
| [oci_core_internet_gateway.igw](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_internet_gateway) | resource |
| [oci_core_network_security_group.gateway_nsg](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_network_security_group) | resource |
| [oci_core_network_security_group_security_rule.gateway_http](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_network_security_group_security_rule) | resource |
| [oci_core_network_security_group_security_rule.gateway_https](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_network_security_group_security_rule) | resource |
| [oci_core_network_security_group_security_rule.ssh](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_network_security_group_security_rule) | resource |
| [oci_core_subnet.dmz_subnet](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_subnet) | resource |
| [oci_core_vcn.main_vcn](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_vcn) | resource |
| [oci_core_volume.worker_volume](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_volume) | resource (count=2) |
| [oci_core_volume_attachment.worker_volume_attachment](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_volume_attachment) | resource (count=2) |
| [oci_core_volume_backup_policy_assignment.worker_volume_backup](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_volume_backup_policy_assignment) | resource (count=2) |
| [oci_core_volume_backup_policies.silver](https://registry.terraform.io/providers/oracle/oci/latest/docs/data-sources/core_volume_backup_policies) | data source |
| [oci_identity_availability_domains.ads](https://registry.terraform.io/providers/oracle/oci/latest/docs/data-sources/identity_availability_domains) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_oci_compartment_ocid"></a> [oci\_compartment\_ocid](#input\_oci\_compartment\_ocid) | OCI compartment OCID where all resources will be created | `string` | n/a | yes |
| <a name="input_oci_image_ocid"></a> [oci\_image\_ocid](#input\_oci\_image\_ocid) | OCI image OCID for the worker instances (Ubuntu aarch64) | `string` | n/a | yes |
| <a name="input_ssh_allowed_cidrs"></a> [ssh\_allowed\_cidrs](#input\_ssh\_allowed\_cidrs) | IPv4 CIDR blocks allowed to SSH into instances (restrict to deterministic runner egress) | `list(string)` | n/a | yes |
| <a name="input_ssh_enabled"></a> [ssh\_enabled](#input\_ssh\_enabled) | Whether SSH ingress should be managed for OCI worker instances | `bool` | `true` | no |
| <a name="input_ssh_ca_public_key"></a> [ssh\_ca\_public\_key](#input\_ssh\_ca\_public\_key) | SSH CA public key injected into instances via cloud-init for certificate-based auth | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_public_worker_ips"></a> [public\_worker\_ips](#output\_public\_worker\_ips) | List of public IPv4 addresses for both OCI worker instances |
