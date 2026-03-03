# Root Terraform Module

The root module orchestrates all cloud infrastructure by pulling secrets from Infisical and passing them to the OCI and GCP child modules. It acts as the single entry point for `terraform apply`.

## How It Works

1. The **Infisical provider** authenticates to Infisical Cloud (hosted at `https://app.infisical.com`)
2. The `infisical_secrets` data source fetches all secrets from the `/Infrastructure` folder in the `prod` environment
3. Secrets like `OCI_COMPARTMENT_ID`, `INSTANCE_SSH_PUBKEY`, and `GCP_PROJECT_ID` are extracted and passed as variables to the child modules
4. Outputs from child modules (worker IPs, witness IPv6) are re-exported for Ansible's dynamic inventory

## Regenerating Docs

```bash
# From the repo root — requires terraform-docs installed
terraform-docs markdown table terraform/ > docs/terraform/root.md
terraform-docs markdown table terraform/gcp/ > docs/terraform/gcp.md
terraform-docs markdown table terraform/oci/ > docs/terraform/oci.md
```

> **Note:** After regeneration, re-add the manual context sections at the top of each file.

## Requirements

| Name | Version |
|------|---------|
| <a name="requirement_google"></a> [google](#requirement\_google) | ~> 5.0 |
| <a name="requirement_infisical"></a> [infisical](#requirement\_infisical) | >= 0.8.0 |
| <a name="requirement_oci"></a> [oci](#requirement\_oci) | ~> 5.0 |

## Providers

| Name | Version |
|------|---------|
| <a name="provider_infisical"></a> [infisical](#provider\_infisical) | 0.16.4 |

## Modules

| Name | Source | Version |
|------|--------|---------|
| <a name="module_gcp"></a> [gcp](#module\_gcp) | ./gcp | n/a |
| <a name="module_oci"></a> [oci](#module\_oci) | ./oci | n/a |

## Resources

| Name | Type |
|------|------|
| [infisical_secrets.infra](https://registry.terraform.io/providers/Infisical/infisical/latest/docs/data-sources/secrets) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_infisical_project_id"></a> [infisical\_project\_id](#input\_infisical\_project\_id) | n/a | `string` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_gcp_witness_ipv6"></a> [gcp\_witness\_ipv6](#output\_gcp\_witness\_ipv6) | External IPv6 address of the GCP Swarm witness instance |
| <a name="output_oci_public_ips"></a> [oci\_public\_ips](#output\_oci\_public\_ips) | List of public IPv4 addresses for the OCI worker instances |

> **Note:** `oci_public_ips` maps to the child module's `public_worker_ips` output. `gcp_witness_ipv6` maps to the child module's `witness_ipv6` output.
