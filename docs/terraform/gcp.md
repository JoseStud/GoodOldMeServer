# GCP Terraform Module

This module provisions a lightweight GCP instance that serves as the **3rd Docker Swarm manager** (witness/tiebreaker). It provides Raft quorum for the Swarm cluster — the witness node does not run application workloads.

## Architecture

The module creates:
- A **VPC** (`hybrid-swarm-network`) with no auto-created subnets
- An **IPv6-enabled subnet** (`hybrid-swarm-ipv6-subnet`) with dual-stack (`IPV4_IPV6`) and external IPv6 access
- **Three firewall rules:**
  - `allow_icmp` — ICMPv4 ping from all IPv4 sources (`0.0.0.0/0`)
  - `allow_icmpv6` — ICMPv6 ping from all IPv6 sources (`::/0`)
  - `allow_ssh` — TCP port 22 from explicit IPv6 `ssh_allowed_cidrs` with `ssh-access` target tag (only when `ssh_enabled=true`)
- A single **e2-micro** Debian 12 instance (`swarm-witness`) with dual-stack networking and premium-tier IPv6

After provisioning, Ansible installs Tailscale on this instance and joins it to the Docker Swarm as a manager. The witness communicates with OCI workers over the Tailscale mesh — the IPv6 address is primarily used for initial Ansible connectivity.

> **Note:** The witness instance has no external IPv4 `access_config` — it is reachable only via its external IPv6 address or through the Tailscale mesh.

> See [Network Architecture](../network-architecture.md#docker-swarm-topology) for the 3-manager quorum rationale.

## Regenerating Docs

```bash
terraform-docs markdown table terraform/gcp/ > docs/terraform/gcp.md
```

## Requirements

No requirements.

## Providers

| Name | Version |
|------|---------|
| <a name="provider_google"></a> [google](#provider\_google) | 5.45.2 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_compute_firewall.allow_icmp](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.allow_icmpv6](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_firewall.allow_ssh](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_instance.witness](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance) | resource |
| [google_compute_network.vpc_network](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_subnetwork.ipv6_subnet](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_gcp_project"></a> [gcp\_project](#input\_gcp\_project) | GCP project ID (injected from Infisical) | `string` | n/a | yes |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region for the subnet and resources | `string` | `"us-central1"` | no |
| <a name="input_gcp_zone"></a> [gcp\_zone](#input\_gcp\_zone) | GCP zone for the compute instance | `string` | `"us-central1-a"` | no |
| <a name="input_ssh_allowed_cidrs"></a> [ssh\_allowed\_cidrs](#input\_ssh\_allowed\_cidrs) | List of IPv6 CIDR blocks allowed to SSH into the witness instance | `list(string)` | n/a | yes |
| <a name="input_ssh_enabled"></a> [ssh\_enabled](#input\_ssh\_enabled) | Whether SSH ingress should be managed for the witness instance | `bool` | `true` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_witness_ipv6"></a> [witness\_ipv6](#output\_witness\_ipv6) | External IPv6 address of the Swarm witness instance |
