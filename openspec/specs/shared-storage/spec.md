# shared-storage Specification

## Purpose
Defines phase 4 of node provisioning: the GlusterFS `swarm_data` volume replicated across both OCI nodes with the GCP witness as arbiter over Tailscale, its mount at `/mnt/swarm-shared`, the shared and node-local directory layout that stacks rely on, and the syncing of stack configuration files onto the shared volume.

## Requirements

### Requirement: GlusterFS Server And Tailscale Addressing
Through the `glusterfs` role include (tag `phase4_glusterfs`) in the `Provision clustered services` play, every host in `oci_nodes` or `gcp_witness` SHALL install `glusterfs-server`, keep `glusterd` started and enabled, and record the trimmed output of `tailscale ip -4` as the `ts_ip` fact used for all GlusterFS peer and brick addresses.

#### Scenario: Servers prepared on all nodes
- **WHEN** the glusterfs role runs
- **THEN** `glusterfs-server` is installed and `glusterd` is enabled and running on both OCI nodes and on the witness
- **AND** each of those hosts has a `ts_ip` fact holding its Tailscale IPv4 address before any peer probe runs

### Requirement: Brick Directories
The glusterfs role SHALL create the brick directory `/mnt/app_data/gluster_brick` (owner `media-srv:media-srv`, mode 0755) on each OCI node, on the block volume mounted by phase 1, and the arbiter brick directory `/mnt/arbiter_brick` (owner `root:root`, mode 0755) on the GCP witness.

#### Scenario: OCI data bricks
- **WHEN** the glusterfs role runs on an `oci_nodes` host
- **THEN** `/mnt/app_data/gluster_brick` exists, owned by `media-srv:media-srv` with mode 0755

#### Scenario: Witness arbiter brick
- **WHEN** the glusterfs role runs on the `gcp_witness` host
- **THEN** `/mnt/arbiter_brick` exists, owned by `root:root` with mode 0755

### Requirement: Peer Probing Over Tailscale
`groups['oci_nodes'][0]` SHALL run `gluster peer probe` against the `ts_ip` of `groups['oci_nodes'][1]` and of `groups['gcp_witness'][0]`, `groups['oci_nodes'][1]` SHALL probe the `ts_ip` of `groups['oci_nodes'][0]`, and the first OCI node SHALL then wait until `gluster peer status` reports at least two `State: Peer in Cluster` entries.

#### Scenario: Peers already known
- **WHEN** a probe's output contains `already in peer list`
- **THEN** the probe is reported unchanged and does not fail, even if its exit code is non-zero
- **AND** the witness issues no probe of its own

#### Scenario: Peers slow to connect
- **WHEN** `gluster peer status` on the first OCI node shows fewer than two peers in cluster
- **THEN** the check is repeated every 5 seconds for up to 12 retries, and the host fails if the condition is never met

### Requirement: Replicated Volume Creation
When `gluster volume info swarm_data` fails on `groups['oci_nodes'][0]`, that node SHALL run `gluster volume create swarm_data replica 3 arbiter 1 transport tcp` with bricks `<oci1 ts_ip>:/mnt/app_data/gluster_brick`, `<oci2 ts_ip>:/mnt/app_data/gluster_brick` and `<witness ts_ip>:/mnt/arbiter_brick` plus `force`, and SHALL run `gluster volume start swarm_data` on every run.

#### Scenario: First creation
- **WHEN** `gluster volume info swarm_data` exits non-zero on the first OCI node
- **THEN** the volume is created with the two OCI data bricks and the witness arbiter brick addressed by Tailscale IPv4

#### Scenario: Volume already exists
- **WHEN** `gluster volume info swarm_data` succeeds
- **THEN** volume creation is skipped

#### Scenario: Volume already started
- **WHEN** the output of `gluster volume start swarm_data` (stdout or stderr) contains `already started`
- **THEN** the task is reported unchanged and does not fail
- **AND** any other non-zero exit fails the task

### Requirement: Shared Volume Mount
Each OCI node SHALL install `glusterfs-client` and mount `localhost:/swarm_data` at `/mnt/swarm-shared` with fstype `glusterfs` and options `defaults,_netdev` as a persistent mount; the witness SHALL NOT install the client or mount the volume.

#### Scenario: Mount point missing
- **WHEN** `/mnt/swarm-shared` is not a mountpoint and the directory does not exist on an OCI node
- **THEN** the directory is created with owner `media-srv:media-srv` and mode 0755 before the volume is mounted there

#### Scenario: Mount point already present
- **WHEN** `/mnt/swarm-shared` already exists or is already mounted
- **THEN** the mount point creation step is skipped and the mount state is enforced

### Requirement: Shared Directory Tree
On `groups['oci_nodes'][0]` only, the glusterfs role SHALL ensure the stack directories under `/mnt/swarm-shared` exist with owner `media-srv:media-srv` and mode 0755, and SHALL afterwards set `/mnt/swarm-shared/observability/prometheus_data` recursively to owner and group `65534` with mode 0755.

#### Scenario: Directories pre-created for stacks
- **WHEN** the glusterfs role runs on the first OCI node
- **THEN** these directories exist under `/mnt/swarm-shared`: `auth/authelia/config`, `ai-interface/open-webui`, `ai-interface/openclaw/config`, `observability/{prometheus_data,grafana_data,prometheus,loki,promtail,alertmanager,alertmanager_data}`, `gateway/traefik_acme`, `management/homarr/appdata`, `management/portainer/data`, `network/vaultwarden/data`, `network/pihole/node1/etc-pihole`, `network/pihole/node1/etc-dnsmasq.d`, `network/pihole/node2/etc-pihole`, `network/pihole/node2/etc-dnsmasq.d`, `uptime-kuma/data` and `cloud/filebrowser/database`

#### Scenario: Prometheus data ownership
- **WHEN** the directory tree has been ensured
- **THEN** `/mnt/swarm-shared/observability/prometheus_data` and its contents are owned by `65534:65534`

### Requirement: Node-Local State Directories
Each OCI node SHALL have node-local state directories with mode 0755 under `/mnt/app_data/local`: `network/vaultwarden-db`, `observability/grafana-db`, `ai-interface/open-webui-db` and `uptime/uptime-kuma-db` owned by `media-srv:media-srv`, `observability/loki_data` owned by `10001:10001`, and `observability/grafana_data` owned by `472:472`.

#### Scenario: Local directories on OCI nodes
- **WHEN** the glusterfs role runs on an `oci_nodes` host
- **THEN** all six directories exist under `/mnt/app_data/local` with the listed owners and mode 0755

#### Scenario: Witness has no local state directories
- **WHEN** the glusterfs role runs on the witness
- **THEN** no directories under `/mnt/app_data/local` are created

### Requirement: Stack Configuration Sync
The tasks in `ansible/roles/glusterfs/tasks/sync-configs.yml`, included with tags `phase4_glusterfs` and `sync-configs`, SHALL copy files from the controller's `stacks/` checkout (`{{ playbook_dir }}/../../stacks`) onto the shared volume on `groups['oci_nodes'][0]` only, with owner `media-srv:media-srv` and mode 0644, replacing destination files whose content differs.

#### Scenario: Configuration files synced
- **WHEN** the sync tasks run
- **THEN** `auth/config/configuration.yml` is copied to `/mnt/swarm-shared/auth/authelia/config/configuration.yml`, `observability/config/prometheus.yml` and `observability/config/alert-rules.yml` to `/mnt/swarm-shared/observability/prometheus/`, `observability/config/loki-config.yaml` to `/mnt/swarm-shared/observability/loki/` and `observability/config/promtail.yml` to `/mnt/swarm-shared/observability/promtail/`

#### Scenario: Source pinned to the stacks commit
- **WHEN** the CI runner was given a `STACKS_SHA`
- **THEN** the copied files come from the `stacks/` checkout at that commit, because the runner checks it out before running the playbook

### Requirement: Seed-Only Runtime Files
The sync tasks SHALL copy `stacks/auth/config/users_database.yml` to `/mnt/swarm-shared/auth/authelia/config/users_database.yml` and `stacks/observability/config/alertmanager.yml` to `/mnt/swarm-shared/observability/alertmanager/alertmanager.yml` only when the destination does not exist (`force: false`), with owner `media-srv:media-srv` and mode 0644.

#### Scenario: Destination missing
- **WHEN** `/mnt/swarm-shared/auth/authelia/config/users_database.yml` does not exist
- **THEN** it is seeded from `stacks/auth/config/users_database.yml`

#### Scenario: Destination already present
- **WHEN** `/mnt/swarm-shared/observability/alertmanager/alertmanager.yml` already exists
- **THEN** it is left unchanged even if the repository copy differs
