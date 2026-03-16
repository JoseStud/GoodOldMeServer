# GCP Workload Identity Federation for Terraform Cloud

## Decision

**TFC dynamic provider credentials via GCP Workload Identity Federation (WIF) OIDC** replace the static `GOOGLE_CREDENTIALS` JSON service account key. No Terraform code changes are needed — the WIF pool, provider, service account, and IAM bindings are created manually in GCP, and `provider "google" ~> 5.0` picks up the injected `GOOGLE_OAUTH_ACCESS_TOKEN` environment variable automatically.

With WIF, TFC generates a short-lived OIDC JWT per run, exchanges it for a GCP access token via STS, and injects `GOOGLE_OAUTH_ACCESS_TOKEN`. The token expires after 1 hour. No long-lived credential is stored in TFC.

## How It Works

```
TFC plan/apply run
  │
  ├─ Generates OIDC JWT
  │   issuer: https://app.terraform.io
  │   sub: "organization:<org>:project:...:workspace:<ws>:run:..."
  │
  ├─ Exchanges JWT with GCP STS
  │   → short-lived access token for tfc-infra@<project>.iam.gserviceaccount.com
  │
  └─ TFC injects GOOGLE_OAUTH_ACCESS_TOKEN
      → provider "google" authenticates automatically
```

## Setup

### 1) Create the Workload Identity Pool

```bash
gcloud iam workload-identity-pools create tfc-pool \
  --location=global \
  --display-name="Terraform Cloud" \
  --description="WIF pool for TFC dynamic provider credentials"
```

### 2) Create the OIDC Provider

```bash
gcloud iam workload-identity-pools providers create-oidc tfc-provider \
  --location=global \
  --workload-identity-pool=tfc-pool \
  --display-name="Terraform Cloud OIDC" \
  --issuer-uri="https://app.terraform.io" \
  --attribute-mapping="google.subject=assertion.sub,attribute.terraform_organization_name=assertion.terraform_organization_name,attribute.terraform_workspace_name=assertion.terraform_workspace_name,attribute.terraform_run_phase=assertion.terraform_run_phase" \
  --attribute-condition="attribute.terraform_organization_name == \"<YOUR_TFC_ORG>\""
```

Replace `<YOUR_TFC_ORG>` with your TFC organization slug (same value as `vars.TFC_ORGANIZATION` in GitHub Actions).

### 3) Create the Service Account

```bash
gcloud iam service-accounts create tfc-infra \
  --display-name="TFC Infra SA" \
  --description="Service account impersonated by TFC dynamic credentials for goodoldme-infra"
```

### 4) Grant IAM roles to the service account

```bash
PROJECT_ID=$(gcloud config get-value project)

gcloud projects add-iam-policy-binding $PROJECT_ID \
  --member="serviceAccount:tfc-infra@${PROJECT_ID}.iam.gserviceaccount.com" \
  --role="roles/compute.admin"
```

Adjust the role if your GCP module manages additional resource types beyond compute.

### 5) Bind the WIF pool to the service account

This allows the `tfc-provider` OIDC pool to impersonate the service account, scoped to the `goodoldme-infra` workspace only:

```bash
PROJECT_NUMBER=$(gcloud projects describe $PROJECT_ID --format="value(projectNumber)")

gcloud iam service-accounts add-iam-policy-binding \
  tfc-infra@${PROJECT_ID}.iam.gserviceaccount.com \
  --role="roles/iam.workloadIdentityUser" \
  --member="principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/tfc-pool/attribute.terraform_workspace_name/goodoldme-infra"
```

### 6) Get the provider resource name

```bash
gcloud iam workload-identity-pools providers describe tfc-provider \
  --location=global \
  --workload-identity-pool=tfc-pool \
  --format="value(name)"
```

This outputs the full canonical resource name in the form:
`projects/<NUMBER>/locations/global/workloadIdentityPools/tfc-pool/providers/tfc-provider`

### 7) Configure TFC workspace variables

In TFC Console → Workspace `goodoldme-infra` → Variables → Environment Variables, add:

| Variable | Value |
|---|---|
| `TFC_GCP_PROVIDER_AUTH` | `true` |
| `TFC_GCP_WORKLOAD_PROVIDER_NAME` | output from step 6 |
| `TFC_GCP_SERVICE_ACCOUNT_EMAIL` | `tfc-infra@<project-id>.iam.gserviceaccount.com` |

Remove `GOOGLE_CREDENTIALS` from the workspace after setting these.

## Verification

- TFC plan succeeds with only the three `TFC_GCP_*` env vars (no `GOOGLE_CREDENTIALS`)
- GCP Console → IAM → Service Accounts shows `tfc-infra` with `compute.admin`
- GCP Console → IAM → Workload Identity Pools shows `tfc-pool` with `tfc-provider` (OIDC, issuer `https://app.terraform.io`)

## Troubleshooting

**403 immediately after removing `GOOGLE_CREDENTIALS`**

IAM bindings take 60–120 seconds to propagate. Wait 2 minutes before triggering the first dynamic-credentials run.

**`invalid_grant` or audience mismatch**

`TFC_GCP_WORKLOAD_PROVIDER_NAME` must be the full numeric-project-number form from step 6, not the project ID.

**`attribute_condition` rejected**

The TFC org slug in `--attribute-condition` must be an exact case-sensitive match to your TFC organization name.
