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
| <a name="output_gcp_witness_public_ip"></a> [gcp\_witness\_public\_ip](#output\_gcp\_witness\_public\_ip) | n/a |
| <a name="output_oci_public_ips"></a> [oci\_public\_ips](#output\_oci\_public\_ips) | n/a |
