# OCI Infrastructure

This module provisions the primary application infrastructure on Oracle Cloud Infrastructure (OCI) — two Ampere A1.Flex worker instances that run all Docker Swarm workloads, along with networking, security, and block storage.

## Architecture

The module creates:
- A **VCN** (`production-vcn`, `10.0.0.0/16`) with a **DMZ subnet** (`10.0.1.0/24`)
- **2× VM.Standard.A1.Flex instances** (`app-worker-1`, `app-worker-2`) — each with 2 OCPUs, 12 GB RAM, and 50 GB boot volume
- A **Gateway NSG** with ingress rules allowing TCP port 80 (HTTP) and 443 (HTTPS) from `0.0.0.0/0`
- **2× 50 GB block volumes** (`worker-volume-0`, `worker-volume-1`) attached via paravirtualized interface
- **Silver backup policy** assignments on both block volumes (daily backups, 5 retention)

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
| <a name="input_ssh_allowed_cidr"></a> [ssh\_allowed\_cidr](#input\_ssh\_allowed\_cidr) | CIDR block allowed to SSH into instances (restrict to your IP or VPN range) | `string` | n/a | yes |
| <a name="input_ssh_ca_public_key"></a> [ssh\_ca\_public\_key](#input\_ssh\_ca\_public\_key) | SSH CA public key injected into instances via cloud-init for certificate-based auth | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_public_worker_ips"></a> [public\_worker\_ips](#output\_public\_worker\_ips) | List of public IPv4 addresses for both OCI worker instances |
