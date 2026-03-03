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
| [oci_core_instance.app_server](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_instance) | resource |
| [oci_core_subnet.dmz_subnet](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_subnet) | resource |
| [oci_core_vcn.main_vcn](https://registry.terraform.io/providers/oracle/oci/latest/docs/resources/core_vcn) | resource |
| [oci_identity_availability_domains.ads](https://registry.terraform.io/providers/oracle/oci/latest/docs/data-sources/identity_availability_domains) | data source |

## Inputs

| Name | Description | Type | Default | Required |
|------|-------------|------|---------|:--------:|
| <a name="input_oci_compartment_ocid"></a> [oci\_compartment\_ocid](#input\_oci\_compartment\_ocid) | n/a | `any` | n/a | yes |
| <a name="input_oci_image_ocid"></a> [oci\_image\_ocid](#input\_oci\_image\_ocid) | n/a | `string` | `"ocid1.image.oc1..."` | no |
| <a name="input_ssh_ca_public_key"></a> [ssh\_ca\_public\_key](#input\_ssh\_ca\_public\_key) | n/a | `any` | n/a | yes |

## Outputs

| Name | Description |
|------|-------------|
| <a name="output_public_ips"></a> [public\_ips](#output\_public\_ips) | n/a |
