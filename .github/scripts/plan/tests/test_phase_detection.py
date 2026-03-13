"""Phase tag computation tests — port of cases P1-P4."""

from __future__ import annotations

import pytest

from ci_plan.resolver import compute_ansible_tags, is_ansible_only, resolve_meta_plan

from .conftest import DUMMY_SHA, DUMMY_SHA_B, FakeGit, make_push_context


class TestIsAnsibleOnly:
    def test_all_ansible_roles(self):
        assert is_ansible_only(["ansible/roles/docker/tasks/main.yml"]) is True

    def test_ansible_lint(self):
        assert is_ansible_only([".ansible-lint"]) is True

    def test_mixed_ansible_and_lint(self):
        assert is_ansible_only(["ansible/roles/docker/tasks/main.yml", ".ansible-lint"]) is True

    def test_terraform_file(self):
        assert is_ansible_only(["terraform/main.tf"]) is False

    def test_mixed_ansible_and_terraform(self):
        assert is_ansible_only(["ansible/roles/docker/tasks/main.yml", "terraform/main.tf"]) is False

    def test_empty_list(self):
        assert is_ansible_only([]) is False


class TestComputeAnsibleTags:
    """Cases P1-P4 from test_resolve_ci_plan.sh."""

    def test_runtime_sync_only(self):
        """P1: runtime_sync only -> phase7_runtime_sync."""
        files = ["ansible/roles/runtime_sync/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase7_runtime_sync"

    def test_glusterfs_and_runtime(self):
        """P2: glusterfs + runtime_sync -> phase4_glusterfs,phase7_runtime_sync."""
        files = [
            "ansible/roles/runtime_sync/tasks/main.yml",
            "ansible/roles/glusterfs/tasks/main.yml",
        ]
        assert compute_ansible_tags(files) == "phase4_glusterfs,phase7_runtime_sync"

    def test_tailscale_only(self):
        """P2b: tailscale only -> phase3_tailscale."""
        files = ["ansible/roles/tailscale/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase3_tailscale"

    def test_playbook_fallback(self):
        """P3: playbook change falls back to full bootstrap (empty tags)."""
        files = ["ansible/playbooks/provision.yml"]
        assert compute_ansible_tags(files) == ""

    def test_non_role_ansible_file(self):
        """Changes outside ansible/roles/ trigger full bootstrap."""
        files = ["ansible/group_vars/all.yml"]
        assert compute_ansible_tags(files) == ""

    def test_empty_files(self):
        assert compute_ansible_tags([]) == ""

    def test_unrecognised_role(self):
        """Role not in ROLE_PHASE_MAP falls back to full bootstrap."""
        files = ["ansible/roles/unknown_role/tasks/main.yml"]
        assert compute_ansible_tags(files) == ""

    def test_system_user_maps_to_phase1(self):
        files = ["ansible/roles/system_user/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase1_base"

    def test_storage_maps_to_phase1(self):
        files = ["ansible/roles/storage/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase1_base"

    def test_docker_maps_to_phase2(self):
        files = ["ansible/roles/docker/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase2_docker"

    def test_swarm_maps_to_phase5(self):
        files = ["ansible/roles/swarm/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase5_swarm"

    def test_portainer_bootstrap_maps_to_phase6(self):
        files = ["ansible/roles/portainer_bootstrap/tasks/main.yml"]
        assert compute_ansible_tags(files) == "phase6_portainer"

    def test_multiple_roles_same_phase_deduplicated(self):
        """system_user + storage both map to phase1_base — should appear once."""
        files = [
            "ansible/roles/system_user/tasks/main.yml",
            "ansible/roles/storage/tasks/main.yml",
        ]
        assert compute_ansible_tags(files) == "phase1_base"


class TestPhaseDetectionEndToEnd:
    """Full resolver tests for phase detection (P1-P4)."""

    def test_p1_runtime_only(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["ansible/roles/runtime_sync/tasks/main.yml"])
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.ansible_tags == "phase7_runtime_sync"
        assert plan.meta.run_infra_apply is False
        assert plan.meta.run_ansible_bootstrap is True

    def test_p2_gluster_and_runtime(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=[
            "ansible/roles/runtime_sync/tasks/main.yml",
            "ansible/roles/glusterfs/tasks/main.yml",
        ])
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.ansible_tags == "phase4_glusterfs,phase7_runtime_sync"

    def test_p2b_tailscale_only(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["ansible/roles/tailscale/tasks/main.yml"])
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.ansible_tags == "phase3_tailscale"

    def test_p3_playbook_fallback(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["ansible/playbooks/provision.yml"])
        plan = resolve_meta_plan(ctx, git)
        # Playbook is under ansible/ so is_ansible_only=true, but
        # compute_ansible_tags returns "" because it's not in ansible/roles/
        assert plan.meta.ansible_tags == ""
        assert plan.meta.run_infra_apply is False

    def test_p4_non_ansible_push(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.ansible_tags == ""
        assert plan.meta.run_infra_apply is True
