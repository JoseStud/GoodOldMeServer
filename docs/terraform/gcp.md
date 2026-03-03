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
| [google_compute_instance.witness](https://registry.terraform.io/providers/hashicorp/google/latest/docs/resources/compute_instance) | resource |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_gcp_project"></a> [gcp\_project](#input\_gcp\_project) | n/a | `any` | n/a | yes |
| <a name="input_gcp_region"></a> [gcp\_region](#input\_gcp\_region) | n/a | `string` | `"us-central1"` | no |
| <a name="input_gcp_zone"></a> [gcp\_zone](#input\_gcp\_zone) | n/a | `string` | `"us-central1-a"` | no |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_witness_public_ip"></a> [witness\_public\_ip](#output\_witness\_public\_ip) | n/a |
