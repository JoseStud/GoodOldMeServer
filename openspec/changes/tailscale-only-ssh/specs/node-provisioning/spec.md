# Spec Delta

## MODIFIED Requirements

### Requirement: SSH Transport Selection
`ansible_run.sh` SHALL resolve every `oci-node-N` host and every non-IP `ansible_host` (the witness) to its Tailscale IPv4 on every run, whatever the values of `RUN_INFRA_APPLY` and `PREFER_TAILSCALE_SSH`. No run mode SHALL keep a public IPv4 `ansible_host` as the SSH target of an OCI host, and a peer that never resolves fails the run as described in "Tailscale Peer Resolution".

#### Scenario: Run without infra apply
- **WHEN** `RUN_INFRA_APPLY` is unset or any value other than `true`
- **THEN** each `oci-node-N` alias listed under `all.hosts`, as well as the witness hostname, has its `ansible_host` replaced with the resolved Tailscale IPv4 address

#### Scenario: Run after infra apply
- **WHEN** `RUN_INFRA_APPLY` is `true`
- **THEN** the public IPv4 `ansible_host` values from the rendered inventory are replaced with the Tailscale IPv4 addresses of `oci-node-N` (or `app-worker-N`) before `ansible-playbook` runs
- **AND** the witness hostname is resolved and replaced in the same way

#### Scenario: Explicit Tailscale preference with infra apply
- **WHEN** `RUN_INFRA_APPLY` is `true` and `PREFER_TAILSCALE_SSH` is `true`, `false`, unset or any other value
- **THEN** the `oci-node-N` aliases are resolved to Tailscale IPv4 addresses as in a run without infra apply
- **AND** the value of `PREFER_TAILSCALE_SSH` has no effect on transport selection

#### Scenario: Freshly created worker
- **WHEN** infra-apply has just created an `app-worker-N` instance whose first-boot cloud-init is still enrolling it in the tailnet
- **THEN** the runner keeps polling for that peer for up to `TAILSCALE_PEER_WAIT_SECONDS`
- **AND** if the peer never appears the run fails before `ansible-playbook` starts, without falling back to the public IPv4 address
