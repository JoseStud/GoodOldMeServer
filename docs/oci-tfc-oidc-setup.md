# OCI + Terraform Cloud OIDC Setup

This guide describes how to let Terraform Cloud runs obtain short-lived OCI credentials through OIDC federation and what to do when direct federation is unavailable.

## Prerequisites

- Terraform Cloud organization and workspace(s) already created.
- OCI tenancy admin access for Identity Providers, Dynamic Groups, and IAM Policies.
- Confirmed Terraform Cloud OIDC issuer URL and expected audience claim.
- Clear fallback decision: if direct TFC -> OCI OIDC federation is unavailable in your tenancy/subscription, use short-lived OCI credentials in a Terraform Cloud Variable Set.

## Verified Steps

### 1) Confirm Terraform Cloud OIDC issuer and audience

1. Identify the exact Terraform Cloud OIDC issuer URL used by runs.
2. Decide the audience value OCI should match.
3. Record both values in change documentation before touching OCI IAM.

### 2) Register OCI OIDC Identity Provider

1. Open OCI Console: `Identity & Security -> Identity Providers -> Add -> OpenID Connect`.
2. Create provider values:
   - Name: `terraform-cloud-oidc`
   - Issuer URL: `<TFC_OIDC_ISSUER_URL>`
   - Audience/Client ID: `<AUDIENCE_STRING>`
3. Save and copy provider identifiers for audit notes.

### 3) Create OCI Dynamic Group for Terraform Cloud identities

1. Open OCI Console: `Identity & Security -> Dynamic Groups -> Create Dynamic Group`.
2. Name: `tfc-dynamic-group`.
3. Add matching rules based on trusted claims (`sub`, `aud`, and any scoped claim strategy in your environment).
4. Keep matching narrow to required workspaces/use cases.

### 4) Grant least-privilege IAM policies

Create policies in target compartment(s), for example:

- `allow dynamic-group tfc-dynamic-group to manage instance-family in compartment MyCompartment`
- `allow dynamic-group tfc-dynamic-group to manage virtual-network-family in compartment MyCompartment`

Start least-privilege and expand only after denied-action evidence.

### 5) Configure Terraform Cloud run path

If direct federation is supported:

1. Configure workspace runtime/auth settings for federated OIDC.
2. Set OCI auth mode for token flow (commonly `OCI_CLI_AUTH=security_token`).
3. Run a plan and verify OCI actions without static key material.

If direct federation is not supported (fallback):

1. Store short-lived OCI credentials in a Terraform Cloud Variable Set (sensitive values).
2. Attach Variable Set to required workspaces only.
3. Define rotation cadence and ownership.

## Verification

- Trigger a Terraform Cloud run and record run ID/time.
- Confirm OCI API calls succeed using federated identity or approved fallback credentials.
- If denied, validate:
  - issuer URL exact match,
  - audience claim expected by OCI,
  - dynamic group claim matching rules,
  - IAM policy scope/verbs.

## Rollback

If federation rollout causes run failures:

1. Disable or detach new federation-specific workspace auth changes.
2. Reattach known-good fallback Variable Set credentials (short-lived, sensitive).
3. Re-run plan to confirm recovery.
4. Keep failed federation config for postmortem analysis (do not delete immediately).

## Troubleshooting

- **401/403 from OCI APIs:** usually claim mismatch (`iss`, `aud`, or `sub`) or missing IAM policy permission.
- **Terraform Cloud run cannot mint/forward expected token:** verify workspace auth capability and current subscription support.
- **Dynamic group rule too broad or too narrow:** inspect run identity claims and adjust rule precision.
- **Intermittent auth errors:** verify token lifetime/skew and runner clock consistency.
