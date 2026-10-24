## MODIFIED Requirements

### Requirement: Playbook Structure And Phase Tags
`ansible/playbooks/provision.yml` SHALL contain three plays with `become: true` and `gather_facts: false`: `Bootstrap OCI infrastructure` (`oci_nodes`, `strategy: free`, phases 1-3), `Bootstrap GCP witness over Tailscale` (`gcp_witness`, `strategy: free`, phases 1-3 without storage) and `Provision clustered services` (`all`, default strategy, phases 4-7). Each phase SHALL be a static role import carrying its phase tag, which every imported task and handler inherits.

#### Scenario: Connection gating tasks
- **WHEN** any play starts, with or without a tag filter
- **THEN** its `always`-tagged tasks run: in the first two plays `wait_for_connection` (delay 10, timeout 600 for OCI nodes and 900 for the witness), `setup` and `ping`; in the third play `ping`

#### Scenario: Full run order
- **WHEN** the playbook runs without a tag filter
- **THEN** OCI nodes run system_user, storage, infisical_cli, docker and tailscale, the witness runs system_user, infisical_cli, docker and tailscale, and only after both plays finish all hosts run glusterfs, sync-configs, swarm, portainer_bootstrap and runtime_sync
- **AND** portainer_bootstrap tasks run only on `groups['oci_nodes'][0]`, because the import's `when: inventory_hostname == groups['oci_nodes'][0]` is applied to every imported task and they are skipped on every other host

#### Scenario: Phase tag assignment
- **WHEN** a tag filter is supplied
- **THEN** it is matched against role imports tagged `phase1_base` (system_user, storage, infisical_cli), `phase2_docker` (docker), `phase3_tailscale` (tailscale), `phase4_glusterfs` (glusterfs), `phase4_glusterfs` and `sync-configs` (glusterfs with `tasks_from: sync-configs`), `phase5_swarm` (swarm), `phase6_portainer` (portainer_bootstrap) and `phase7_runtime_sync` (runtime_sync)
- **AND** the always-tagged connection tasks run, together with every task and notified handler of the matching imports, and no task of a non-matching import runs
- **AND** `ansible-playbook --list-tasks --tags <tag>` lists the matching roles' tasks without contacting any host

#### Scenario: Host sync converges phase 7
- **WHEN** the playbook runs with `--tags phase7_runtime_sync`, as the pipeline's host sync does on a stacks SHA bump
- **THEN** after the always-tagged tasks, every runtime_sync task runs on every inventory host, and the `Restart infisical agent` handler runs when notified
- **AND** no task of phases 1-6 runs

#### Scenario: Shared service account variables under any tag filter
- **WHEN** the playbook runs with any tag filter, including `sync-configs` alone, against either `inventory-ci.yml` or `ansible/inventory/terraform.yml`
- **THEN** `service_user` and `service_group` resolve to `media-srv` and `service_uid` and `service_gid` to `1500` from `ansible/playbooks/group_vars/all.yml`, which sits next to the playbook
- **AND** no role's defaults redefine these four variables

#### Scenario: Roles resolved at parse time
- **WHEN** `ansible-playbook` parses `provision.yml`
- **THEN** every imported role is resolved from `ansible/roles`: the CI runner sets `ANSIBLE_ROLES_PATH=ansible/roles`, and `ansible/ansible.cfg` sets `roles_path = roles` for runs from the `ansible/` directory
- **AND** a missing role or an unresolvable module fails the run before any host is contacted
