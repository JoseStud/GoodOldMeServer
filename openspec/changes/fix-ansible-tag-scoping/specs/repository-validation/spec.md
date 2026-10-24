## MODIFIED Requirements

### Requirement: Ansible Lint And Syntax Check
Validate Ansible SHALL run `ansible-lint -c .ansible-lint ansible`, applying profile `basic` and skipping `yaml[line-length]`, `name[template]`, `no-changed-when` and `var-naming[no-role-prefix]`, and SHALL run `ansible-playbook --syntax-check` on `ansible/playbooks/provision.yml` against a generated local inventory, both with `ANSIBLE_ROLES_PATH=ansible/roles` so that the roles imported by the playbook resolve.

#### Scenario: Lint violation
- **WHEN** ansible-lint reports a violation under the `basic` profile that is not in the skip list
- **THEN** the `ansible-validate` job fails

#### Scenario: Syntax check inventory
- **WHEN** the syntax check runs
- **THEN** it uses `/tmp/ansible-syntax.ini`, which places `localhost` with `ansible_connection=local` in the groups `oci_nodes` and `gcp_witness`
- **AND** no remote host is contacted

#### Scenario: Imported role contents checked
- **WHEN** a role imported by `provision.yml` cannot be found under `ansible/roles`, or one of its tasks names a module that the collections installed from `ansible/requirements.yml` do not provide
- **THEN** the syntax check fails before any later step runs

## ADDED Requirements

### Requirement: Ansible Phase Tag Scoping Check
After the syntax check, Validate Ansible SHALL run `ansible-playbook --list-tasks --tags <tag>` on `ansible/playbooks/provision.yml` against `/tmp/ansible-syntax.ini` for every phase tag in `ROLE_PHASE_MAP` (`ci/src/ci_pipeline/context.py`) and for `sync-configs`. It SHALL fail unless each role mapped to a tag has at least one task listed under that tag, and SHALL fail when a directory under `ansible/roles/` has no map entry.

#### Scenario: Tag that reaches no role task
- **WHEN** the listing for a phase tag shows only the always-tagged tasks and the tagged statement itself, as a tagged dynamic include without `apply` tags does
- **THEN** the check fails, naming the tag and each role whose tasks are missing

#### Scenario: Config sync scope
- **WHEN** the check lists `--tags sync-configs`
- **THEN** it passes only if the listing contains the glusterfs sync tasks, such as `Sync Authelia configuration to GlusterFS`, and no glusterfs main-role task, such as `Install GlusterFS server`

#### Scenario: Role without a phase mapping
- **WHEN** a directory under `ansible/roles/` has no `ansible/roles/<name>/` key in `ROLE_PHASE_MAP`
- **THEN** the check fails, naming the role

#### Scenario: No hosts or secrets
- **WHEN** the check runs, including for a pull request from a fork or by Dependabot
- **THEN** it uses only the localhost inventory and the collections installed from `ansible/requirements.yml`
- **AND** it contacts no remote host and reads no secret

#### Scenario: Phase map edited alone
- **WHEN** a pull request or push changes only `ci/src/ci_pipeline/context.py`
- **THEN** Validate Ansible runs, so the check is evaluated against the edited map
