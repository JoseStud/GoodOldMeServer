# dns-management Specification

## Purpose
Reconcile Cloudflare round-robin DNS A records so that every hostname routed by Traefik in the stacks repository compose files resolves to all OCI public IPs, driven by the cloudflare-dns-sync pipeline stage (.github/scripts/stages/cloudflare_dns_sync.sh) and scripts/cloudflare-dns.sh.

## Requirements

### Requirement: DNS Sync Pipeline Placement
The pipeline SHALL run the cloudflare-dns-sync stage on every run with HAS_WORK true, after the stacks-sha-trust and secret-validation preflights complete and before any Ansible or Portainer stage. It SHALL run concurrently with network-policy-sync when RUN_INFRA_APPLY or RUN_ANSIBLE_BOOTSTRAP is true and alone otherwise, and SHALL never be bound to the Tailscale SOCKS5 proxy.

#### Scenario: Tailscale-first run
- **WHEN** a run has work but neither RUN_INFRA_APPLY nor RUN_ANSIBLE_BOOTSTRAP is true
- **THEN** cloudflare-dns-sync runs on its own and network-policy-sync is skipped

#### Scenario: Infra or bootstrap run
- **WHEN** RUN_INFRA_APPLY or RUN_ANSIBLE_BOOTSTRAP is true
- **THEN** cloudflare-dns-sync and network-policy-sync run concurrently

#### Scenario: DNS sync failure
- **WHEN** the cloudflare-dns-sync stage exits non-zero
- **THEN** the pipeline exits with status 1 and no Ansible or Portainer stage runs

### Requirement: DNS Sync Inputs
Outside extract-only mode the stage MUST have INFISICAL_PROJECT_ID, TFC_TOKEN and TFC_ORGANIZATION. It SHALL read CLOUDFLARE_API_TOKEN, ZONE_ID and BASE_DOMAIN from Infisical env `prod` folder `/infrastructure`, failing if any is empty, and SHALL read the `oci_public_ips` output from the current state version of TFC workspace TFC_WORKSPACE_INFRA (default `goodoldme-infra`) via TFC_API_URL (default `https://app.terraform.io/api/v2`).

#### Scenario: OCI IPs resolved
- **WHEN** the infra workspace's current state version has a non-empty `oci_public_ips` output
- **THEN** every listed IP is used as the desired record set for every hostname

#### Scenario: Missing OCI IP output
- **WHEN** the workspace ID, the state outputs link, or the `oci_public_ips` output cannot be resolved, or the output is an empty list
- **THEN** the stage fails before any Cloudflare change is made

#### Scenario: Empty Cloudflare secret
- **WHEN** CLOUDFLARE_API_TOKEN, ZONE_ID or BASE_DOMAIN is empty in `/infrastructure`
- **THEN** the stage fails with "One or more required Cloudflare secrets are empty"

### Requirement: Hostname Source Selection
The stage SHALL collect hostnames from the compose file of every stack in STACKS_MANIFEST (default `stacks/stacks.yaml`), regardless of `portainer_managed`, resolving each `compose_path` relative to the manifest's directory. It SHALL fail when the manifest lists no stacks, when a listed compose file does not exist, or when no hostname is found.

#### Scenario: Non-Portainer stack hosts included
- **WHEN** the `management` stack has `portainer_managed: false` and routes `portainer.${BASE_DOMAIN}` and `home.${BASE_DOMAIN}`
- **THEN** `portainer` and `home` are included in the reconciled hostnames

#### Scenario: Missing compose file
- **WHEN** a manifest entry points to a compose file that does not exist
- **THEN** the stage prints "Error: compose file not found: <path>" and fails

### Requirement: Traefik Host Rule Extraction
The stage SHALL scan every line matching `traefik.http.routers.<name>.rule` in list (`=`) or map (`:`) label syntax, normalize double and single quotes to backticks, and parse only `Host(...)` groups, splitting each group on commas into candidate hosts. Other matchers in the rule, such as `Path(...)`, SHALL be ignored.

#### Scenario: Host combined with Path
- **WHEN** a label is `` traefik.http.routers.gateway-health.rule=Host(`gateway-health.${BASE_DOMAIN}`) && Path(`/healthz`) ``
- **THEN** only `gateway-health` is extracted

#### Scenario: Multiple hosts in one group
- **WHEN** a rule is `` Host(`files.${BASE_DOMAIN}`, `status.${BASE_DOMAIN}`) ``
- **THEN** both `files` and `status` are extracted

#### Scenario: Map label syntax
- **WHEN** labels are written as `` traefik.http.routers.grafana.rule: Host(`grafana.${BASE_DOMAIN}`) ``
- **THEN** `grafana` is extracted

### Requirement: Hostname Normalization
Each candidate SHALL be trimmed and unquoted, have `${BASE_DOMAIN}` and `$BASE_DOMAIN` expanded, be lower-cased and have a `.<BASE_DOMAIN>` suffix removed to yield a subdomain label. Candidates that still contain `$`, equal the apex BASE_DOMAIN, or leave an empty label or a label containing `.` SHALL be skipped with a warning; the resulting labels SHALL be de-duplicated and processed in sorted order.

#### Scenario: Case and duplicates
- **WHEN** compose files route `AUTH.${BASE_DOMAIN}` and route `gateway.${BASE_DOMAIN}` from two different stacks
- **THEN** the labels `auth` and `gateway` each appear exactly once in the sorted host list

#### Scenario: Unresolved variable
- **WHEN** a rule is `` Host(`api.${OTHER_DOMAIN}`) ``
- **THEN** the host is skipped with "Warning: skipping unresolved host token"

#### Scenario: Apex and multi-label hosts
- **WHEN** a rule routes `${BASE_DOMAIN}` itself, `a.b.${BASE_DOMAIN}`, or `x.other.org`
- **THEN** the apex is skipped with "Warning: skipping apex host" and `a.b` and `x.other.org` are skipped with "Warning: skipping unsupported host"

#### Scenario: Bare single-label host
- **WHEN** a rule is `Host('foo')`
- **THEN** `foo` is kept as a label and reconciled as `foo.<BASE_DOMAIN>`

### Requirement: Legacy Stack Name Hostnames
When DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES is exactly `true` (default `false`) the stage SHALL also add each manifest stack name as a hostname label, in addition to the labels extracted from Traefik rules.

#### Scenario: Legacy names enabled
- **WHEN** DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES is `true` and stack `auth` routes only `login.${BASE_DOMAIN}`
- **THEN** the host list is `auth` and `login`

#### Scenario: Legacy names disabled
- **WHEN** DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES is unset
- **THEN** only labels extracted from Traefik `Host(...)` rules are used

### Requirement: Extract-Only Mode
When DNS_SYNC_EXTRACT_ONLY is exactly `true` the stage SHALL require BASE_DOMAIN from the environment, print the sorted unique hostname labels one per line, and exit 0 without contacting Infisical, Terraform Cloud or Cloudflare.

#### Scenario: Local extraction
- **WHEN** the stage runs with DNS_SYNC_EXTRACT_ONLY=true and BASE_DOMAIN=example.com
- **THEN** it prints the sorted labels and makes no API calls

#### Scenario: Missing BASE_DOMAIN in extract-only mode
- **WHEN** DNS_SYNC_EXTRACT_ONLY=true and BASE_DOMAIN is unset
- **THEN** the stage fails with "BASE_DOMAIN is required in DNS_SYNC_EXTRACT_ONLY mode"

### Requirement: A Record Reconciliation
For each hostname label, scripts/cloudflare-dns.sh SHALL list existing `A` records named `<label>.<BASE_DOMAIN>` in zone ZONE_ID, keep records whose IP is desired, create a record with TTL 1 and `proxied` from PROXIED (default `true`) for each missing desired IP, and delete each record whose IP is not desired. Kept records SHALL NOT be modified.

#### Scenario: Mixed existing state
- **WHEN** existing records point `vault.<BASE_DOMAIN>` to IP1 and IP3 and the desired IPs are IP1 and IP2
- **THEN** the IP1 record is kept, an IP2 record is created with `ttl: 1` and `proxied: true`, and the IP3 record is deleted
- **AND** the script prints "Done: 1 created, 1 kept, 1 deleted for vault.<BASE_DOMAIN>."

#### Scenario: DNS-only override
- **WHEN** the script runs with PROXIED=false
- **THEN** records it creates have `proxied: false`

#### Scenario: Shadow mode is not consulted
- **WHEN** the pipeline runs with SHADOW_MODE=true
- **THEN** cloudflare-dns-sync still creates and deletes records

### Requirement: Reconcile Script Input Validation
scripts/cloudflare-dns.sh MUST be given a hostname label and at least one IP, and SHALL reject any IP argument that does not match four dot-separated groups of 1 to 3 digits, exiting 1 before calling the Cloudflare API. ZONE_ID, CLOUDFLARE_API_TOKEN and BASE_DOMAIN MUST be set in its environment.

#### Scenario: IPv6 address supplied
- **WHEN** an IP argument is `2001:db8::1`
- **THEN** the script prints "Error: '2001:db8::1' is not a valid IPv4 address." and exits 1 without contacting Cloudflare

#### Scenario: Too few arguments
- **WHEN** the script is called with only a hostname label
- **THEN** it prints usage and exits 1

### Requirement: DNS Failure Handling
scripts/cloudflare-dns.sh SHALL exit 1 as soon as listing, creating or deleting a record returns a response whose `success` is not `true`. The stage SHALL continue with the remaining hostnames after a per-host failure and SHALL fail overall when at least one hostname failed.

#### Scenario: Listing fails
- **WHEN** the Cloudflare list request for a hostname does not return `success: true`
- **THEN** the script prints "Error: Failed to fetch existing DNS records." and exits 1 without changing records for that hostname

#### Scenario: One hostname fails
- **WHEN** reconciliation fails for one hostname and succeeds for the others
- **THEN** the stage attempts every hostname, prints "cloudflare-dns-sync: 1 hostname(s) failed.", and exits non-zero
