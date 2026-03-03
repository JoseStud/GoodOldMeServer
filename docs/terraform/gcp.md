# GCP Terraform Module

This module provisions a lightweight GCP instance that serves as the **3rd Docker Swarm manager** (witness/tiebreaker). It provides Raft quorum for the Swarm cluster — the witness node does not run application workloads.

## Architecture

The module creates:
- A **VPC** (`hybrid-swarm-network`) with no auto-created subnets
- An **IPv6-enabled subnet** (`hybrid-swarm-ipv6-subnet`) with dual-stack (`IPV4_IPV6`) and external IPv6 access
- An **ICMPv6 firewall rule** allowing ping from all IPv6 sources (`::/0`)
- A single **e2-micro** Debian 12 instance (`swarm-witness`) with dual-stack networking and premium-tier IPv6

After provisioning, Ansible installs Tailscale on this instance and joins it to the Docker Swarm as a manager. The witness communicates with OCI workers over the Tailscale mesh — the IPv6 address is primarily used for initial Ansible connectivity.

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
| <a name="provider_google"></a> [google](#provider\_google) | ~> 5.0 |

## Modules

No modules.

## Resources

| Name | Type |
|------|------|
| [google_compute_network.vpc_network](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_network) | resource |
| [google_compute_subnetwork.ipv6_subnet](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_subnetwork) | resource |
| [google_compute_firewall.allow_icmpv6](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_firewall) | resource |
| [google_compute_instance.witness](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_gcp_project"></a> [gcp\_project](#input\_gcp\_project) | GCP project ID (from Infisical) | `any` | n/a | yes |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | GCP region for the subnet | `string` | `"us-central1"` | no |
| <a name="input_gcp_zone"></a> [gcp\_zone](#input\_gcp\_zone) | GCP zone for the compute instance | `string` | `"us-central1-a"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_witness_ipv6"></a> [witness\_ipv6](#output\_witness\_ipv6) | External IPv6 address of the Swarm witness instance |
