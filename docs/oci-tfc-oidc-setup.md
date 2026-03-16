# OCI Terraform Authentication

## Decision

**OIDC / Workload Identity is not supported by the OCI Terraform Provider.** The `oracle/oci` provider does not natively support Workload Identity tokens — there is no `auth = "WorkloadIdentity"` or equivalent mechanism for consuming TFC-issued OIDC tokens. This is a provider-level limitation, not a tenancy configuration issue; the provider cannot exchange a JWT for OCI credentials regardless of how IAM Dynamic Groups or Identity Domain federation are configured.

The `auth = "SecurityToken"` (OCI CLI session token) approach was also dropped: it requires interactive CLI auth and does not function in TFC remote runs.

**Current approach: API key authentication** (`tenancy_ocid` + `user_ocid` + `fingerprint` + `private_key` in `provider "oci"`).

## Setup

### 1) Generate an OCI API key pair

In OCI Console → Profile → User Settings → API Keys → Add API Key:

1. Generate a new API key pair (or upload your own public key).
2. Copy the **fingerprint** shown after upload.
3. Download or copy the **private key PEM** — this is the only time it is available in plain text.
4. Note the **user OCID** (shown on the User Settings page).
5. Note the **tenancy OCID** (OCI Console → Profile → Tenancy).

### 2) Grant IAM policies

Ensure the user has sufficient IAM permissions in the target compartment:

```
allow user <username> to manage instance-family in compartment <compartment-name>
allow user <username> to manage virtual-network-family in compartment <compartment-name>
allow user <username> to manage volume-family in compartment <compartment-name>
allow user <username> to read identity-availability-domains in compartment <compartment-name>
```

### 3) Store credentials in Infisical

Store the four credentials at `/cloud-provider/oci` in Infisical:

| Secret | Value |
|--------|-------|
| `OCI_TENANCY_OCID` | `ocid1.tenancy.oc1...` |
| `OCI_USER_OCID` | `ocid1.user.oc1...` |
| `OCI_FINGERPRINT` | `aa:bb:cc:...` |
| `OCI_PRIVATE_KEY` | Full PEM content (multi-line) |

### 4) Sync to TFC workspace as sensitive variables

The `provider "oci"` block cannot use Terraform data sources — provider config is resolved before data sources. These four credentials must be set as **sensitive Terraform variables** in the `goodoldme-infra` TFC workspace:

| TFC variable name | Maps to |
|-------------------|---------|
| `oci_tenancy_ocid` | `var.oci_tenancy_ocid` |
| `oci_user_ocid` | `var.oci_user_ocid` |
| `oci_fingerprint` | `var.oci_fingerprint` |
| `oci_private_key` | `var.oci_private_key` |

Set these in TFC Console → Workspace → Variables → Terraform Variables (mark all as Sensitive).

> `OCI_COMPARTMENT_OCID` and `OCI_IMAGE_OCID` continue to be read via the Infisical data source at plan time — no change needed for those.

## Verification

Trigger a TFC run on the `goodoldme-infra` workspace and confirm:

- Plan phase calls OCI APIs without auth errors.
- Instance and network resources resolve correctly.

## Troubleshooting

- **401 from OCI APIs:** verify fingerprint matches the uploaded public key exactly; verify `private_key` PEM is the matching private half.
- **403 / not authorized:** check IAM policy verbs and compartment scope for the user.
- **Invalid private key format:** ensure the full PEM block including `-----BEGIN RSA PRIVATE KEY-----` header/footer is stored (multi-line).
