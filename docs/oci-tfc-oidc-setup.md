OCI + Terraform Cloud (TFC) federated OIDC setup

Goal
- Enable Terraform Cloud remote runs to acquire short-lived credentials from Oracle Cloud Infrastructure (OCI) using OIDC federation (avoid long‑lived API keys).

Important note
- Terraform Cloud must be able to act as an OIDC client to obtain tokens that OCI will accept. If Terraform Cloud does not support acting as the OIDC token requester for OCI in your subscription, the practical fallback is to store short‑lived OCI credentials (rotated) in a TFC Variable Set.

High-level approach
1. Identify the OIDC issuer URL that Terraform Cloud will use when requesting tokens (TFC OIDC issuer). This may be a Terraform Cloud endpoint or a dedicated OIDC URL. If TFC does not expose an issuer that can be used, you will need to use the fallback approach.
2. In OCI, register an OIDC identity provider that trusts the TFC issuer.
3. Create a Dynamic Group in OCI that matches tokens issued by TFC (use claims such as `sub` or `aud` as configured).
4. Create OCI IAM policies granting the Dynamic Group the least-privilege permissions required by your Terraform configurations.
5. Configure Terraform Cloud workspace(s) to use the federated identity (if TFC supports direct OIDC federation). If not supported, add OCI API credentials to a TFC Variable Set (marked Sensitive) as the fallback.

OCI steps (console or CLI)
- You will need the exact TFC issuer URL and the audience (aud) value you want OCI to match.

1) Register an OIDC Identity Provider in OCI
- In the OCI Console: Identity & Security → Identity Providers → Add → OpenID Connect
  - Name: terraform-cloud-oidc
  - Issuer URL: <TFC_OIDC_ISSUER_URL>  # e.g. https://app.terraform.io/.well-known/openid-configuration (confirm exact URL)
  - Client ID / Audience: <AUDIENCE_STRING>
  - Save the provider.

2) Create a Dynamic Group
- In the OCI Console: Identity & Security → Dynamic Groups → Create Dynamic Group
  - Name: tfc-dynamic-group
  - Matching rule: create a rule that matches the token claims (for example, a claim for subject or audience). Exact rule syntax depends on the token mapping used. Examples you may adapt:
    - If tokens contain a `sub` claim like `org/xxxxx/workspace/...`, match by `token.sub`.
    - If tokens contain repository or other claims, use that mapping.

3) Create an IAM Policy granting permissions
- Example minimal policy (replace compartment and resources):
  - allow dynamic-group tfc-dynamic-group to manage instance-family in compartment MyCompartment
  - allow dynamic-group tfc-dynamic-group to manage virtual-network-family in compartment MyCompartment

4) Configure Terraform Cloud
- If Terraform Cloud supports registering an external OIDC provider for workspace remote runs, add the TFC client configuration and audience there and map the OCI trust accordingly. Required environment variable is typically just `OCI_CLI_AUTH="security_token"`.

Verification
- Trigger a TFC run and check cloud logs.
- If OCI denies access, verify the issuer/audience and token claims accepted by the Dynamic Group rule.


