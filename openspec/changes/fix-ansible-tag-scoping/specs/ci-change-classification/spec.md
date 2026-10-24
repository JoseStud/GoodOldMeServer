## MODIFIED Requirements

### Requirement: Ansible Phase Tag Mapping
For an ansible-only push, `ansible_tags` SHALL be the comma-joined unique phase tags of the changed roles, in first-seen order, per this map under `ansible/roles/`: `system_user/`, `storage/`, `infisical_cli/` → `phase1_base`; `docker/` → `phase2_docker`; `tailscale/` → `phase3_tailscale`; `glusterfs/` → `phase4_glusterfs`; `swarm/` → `phase5_swarm`; `portainer_bootstrap/` → `phase6_portainer`; `runtime_sync/` → `phase7_runtime_sync`. Any changed file outside these paths SHALL make it empty.

#### Scenario: Several roles map to tags
- **WHEN** the changed files are under `ansible/roles/glusterfs/` and `ansible/roles/runtime_sync/`
- **THEN** `ansible_tags=phase4_glusterfs,phase7_runtime_sync`

#### Scenario: Roles sharing a phase are de-duplicated
- **WHEN** the changed files are under `ansible/roles/system_user/` and `ansible/roles/storage/`
- **THEN** `ansible_tags=phase1_base`

#### Scenario: Infisical CLI role change
- **WHEN** the only changed file is under `ansible/roles/infisical_cli/`
- **THEN** `ansible_tags=phase1_base` instead of an empty value, so the bootstrap runs phase 1 only and not a full-scope bootstrap

#### Scenario: Unmapped path empties the tags
- **WHEN** any changed file is outside `ansible/roles/` (including `.ansible-lint` or a playbook) or under a role not in the map
- **THEN** `ansible_tags` is empty, which downstream means a full-scope bootstrap
