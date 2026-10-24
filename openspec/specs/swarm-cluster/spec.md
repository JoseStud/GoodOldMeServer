# swarm-cluster Specification

## Purpose
Defines phase 5 of node provisioning: forming a three-manager Docker Swarm over the Tailscale mesh with the first OCI node as founding manager and the second OCI node and the GCP witness joining as managers, applying node placement labels, and creating the shared `traefik_proxy` overlay network.

## Requirements

### Requirement: Node Address And Swarm State Discovery
Through the `swarm` role include (tag `phase5_swarm`) in the `Provision clustered services` play, every host SHALL record the trimmed output of `tailscale ip -4` as `ts_ip`, the output of `hostname` as `swarm_node_hostname`, and the output of `docker info --format '{{ .Swarm.LocalNodeState }}'` as its swarm state for the init and join decisions.

#### Scenario: Facts gathered on every node
- **WHEN** the swarm role runs
- **THEN** each OCI node and the witness has `ts_ip`, `swarm_node_hostname` and its local swarm state recorded
- **AND** because the play uses the default linear strategy, each task completes on all hosts before the next task starts

### Requirement: Swarm Initialization
`groups['oci_nodes'][0]` SHALL run `docker swarm init --advertise-addr <ts_ip> --listen-addr <ts_ip>:2377` when its local swarm state is not `active`, and SHALL skip initialization when the state is `active`.

#### Scenario: Founding manager initializes the swarm
- **WHEN** the first OCI node reports a swarm state other than `active`
- **THEN** it initializes a swarm advertising and listening on its Tailscale IPv4 address, port 2377

#### Scenario: Swarm already active
- **WHEN** the first OCI node reports swarm state `active`
- **THEN** `docker swarm init` is not run

### Requirement: Manager Join Token
On every run of the swarm role, `groups['oci_nodes'][0]` SHALL read `docker swarm join-token -q manager` and set the facts `swarm_manager_token` (the token) and `swarm_first_manager_ip` (its own `ts_ip`) for the joining nodes.

#### Scenario: Token published on an existing swarm
- **WHEN** the swarm role runs and the first OCI node was already a manager
- **THEN** the manager join token is still read, reported unchanged, and exposed through `hostvars` to the other hosts

### Requirement: Manager Joins
`groups['oci_nodes'][1]` and each `gcp_witness` host SHALL run `docker swarm join --token <swarm_manager_token> --advertise-addr <own ts_ip> <swarm_first_manager_ip>:2377`, joining as managers, when their own swarm state is not `active` and the first OCI node's `swarm_manager_token` fact is defined.

#### Scenario: Nodes join the new swarm
- **WHEN** the second OCI node and the witness report a swarm state other than `active`
- **THEN** each joins the swarm as a manager through the first node's Tailscale address on port 2377, advertising its own Tailscale IPv4 address

#### Scenario: Node already in a swarm
- **WHEN** a joining node reports swarm state `active`
- **THEN** no join command is run on that node

#### Scenario: Token not available
- **WHEN** `hostvars[groups['oci_nodes'][0]].swarm_manager_token` is not defined
- **THEN** the join tasks are skipped

### Requirement: Node Placement Labels
`groups['oci_nodes'][0]` SHALL build a hostname-to-node-ID map from `docker node ls --format '{{.ID}},{{.Hostname}}'` and run `docker node update --label-add location=cloud <id>` for every `oci_nodes` host and `docker node update --label-add role=witness <id>` for every `gcp_witness` host whose `swarm_node_hostname` is in that map, with these label tasks always reported unchanged.

#### Scenario: Labels applied
- **WHEN** both OCI nodes and the witness are listed by `docker node ls` under their `hostname` output
- **THEN** both OCI swarm nodes carry label `location=cloud` and the witness swarm node carries label `role=witness`

#### Scenario: Host missing from the swarm
- **WHEN** a host's `swarm_node_hostname` does not appear in the node list
- **THEN** the label command for that host is skipped without failing

### Requirement: Traefik Overlay Network
`groups['oci_nodes'][0]` SHALL ensure, with `community.docker.docker_network`, that a Docker network named `traefik_proxy` exists with driver `overlay` and `attachable` enabled.

#### Scenario: Network missing
- **WHEN** the swarm role runs and no `traefik_proxy` network exists
- **THEN** an attachable overlay network named `traefik_proxy` is created from the first OCI node

#### Scenario: Network present
- **WHEN** an attachable overlay network `traefik_proxy` already exists
- **THEN** the task leaves it in place
