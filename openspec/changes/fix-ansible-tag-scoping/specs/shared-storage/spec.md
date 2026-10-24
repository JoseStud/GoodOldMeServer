## MODIFIED Requirements

### Requirement: Stack Configuration Sync
The tasks in `ansible/roles/glusterfs/tasks/sync-configs.yml`, imported from the glusterfs role (`tasks_from: sync-configs`) with tags `phase4_glusterfs` and `sync-configs`, SHALL copy files from the controller's `stacks/` checkout (`{{ playbook_dir }}/../../stacks`) onto the shared volume on `groups['oci_nodes'][0]` only, with owner `service_user:service_group` (`media-srv:media-srv`) and mode 0644, replacing destination files whose content differs.

#### Scenario: Configuration files synced
- **WHEN** the sync tasks run
- **THEN** `auth/config/configuration.yml` is copied to `/mnt/swarm-shared/auth/authelia/config/configuration.yml`, `observability/config/prometheus.yml` and `observability/config/alert-rules.yml` to `/mnt/swarm-shared/observability/prometheus/`, `observability/config/loki-config.yaml` to `/mnt/swarm-shared/observability/loki/` and `observability/config/promtail.yml` to `/mnt/swarm-shared/observability/promtail/`

#### Scenario: Source pinned to the stacks commit
- **WHEN** the CI runner was given a `STACKS_SHA`
- **THEN** the copied files come from the `stacks/` checkout at that commit, because the runner checks it out before running the playbook

#### Scenario: Config-sync-only run
- **WHEN** the playbook runs with `--tags sync-configs`, as the pipeline's config sync does after the Ansible bootstrap or host-sync run
- **THEN** the sync and seed tasks run on `groups['oci_nodes'][0]` with owner and group `media-srv`, and the run does not fail on an undefined `service_user` or `service_group`
- **AND** no other glusterfs task runs: no server install, peer probe, volume create or start, mount, or directory tree
