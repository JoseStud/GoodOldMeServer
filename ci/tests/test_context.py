"""Tests for ci_pipeline.context — execution context computation."""

from __future__ import annotations

import pytest

from ci_pipeline.context import (
    ExecutionContext,
    compute_ansible_tags,
    compute_context,
    is_metadata_only,
    is_ansible_only,
    is_stacks_sha_only_push,
)

from .conftest import DUMMY_SHA, DUMMY_SHA_B, FakeGit


# ── is_ansible_only ──────────────────────────────────────────────────────


class TestIsAnsibleOnly:
    def test_empty_files_returns_false(self):
        assert is_ansible_only([]) is False

    def test_only_ansible_files(self):
        assert is_ansible_only(["ansible/roles/docker/tasks/main.yml"]) is True

    def test_ansible_lint_is_ansible_only(self):
        assert is_ansible_only([".ansible-lint"]) is True

    def test_mixed_ansible_and_lint(self):
        assert is_ansible_only([
            "ansible/playbooks/provision.yml",
            ".ansible-lint",
        ]) is True

    def test_terraform_file_breaks_ansible_only(self):
        assert is_ansible_only([
            "ansible/roles/docker/tasks/main.yml",
            "terraform/infra/main.tf",
        ]) is False

    def test_stacks_file_breaks_ansible_only(self):
        assert is_ansible_only(["stacks"]) is False


class TestIsMetadataOnly:
    def test_empty_files_returns_false(self):
        assert is_metadata_only([]) is False

    def test_only_metadata_files(self):
        assert is_metadata_only([
            ".ansible-lint",
            "docs/ci-plan-contract.md",
            ".github/workflows/orchestrator.yml",
        ]) is True

    def test_markdown_outside_metadata_prefixes_is_not_metadata_only(self):
        assert is_metadata_only([
            "terraform/infra/NOTES.md",
        ]) is False

    def test_runtime_file_breaks_metadata_only(self):
        assert is_metadata_only([
            "docs/ci-plan-contract.md",
            "terraform/infra/main.tf",
        ]) is False


class TestIsStacksShaOnlyPush:
    def test_stacks_only_true(self):
        assert is_stacks_sha_only_push(["stacks"]) is True

    def test_stacks_plus_gitmodules_true(self):
        assert is_stacks_sha_only_push(["stacks", ".gitmodules"]) is True

    def test_gitmodules_only_false(self):
        assert is_stacks_sha_only_push([".gitmodules"]) is False

    def test_stacks_plus_runtime_file_false(self):
        assert is_stacks_sha_only_push([
            "stacks",
            "terraform/infra/main.tf",
        ]) is False


# ── compute_ansible_tags ─────────────────────────────────────────────────


class TestComputeAnsibleTags:
    def test_empty_returns_empty(self):
        assert compute_ansible_tags([]) == ""

    def test_single_role_returns_tag(self):
        assert compute_ansible_tags([
            "ansible/roles/docker/tasks/main.yml",
        ]) == "phase2_docker"

    def test_multiple_roles_deduped(self):
        tags = compute_ansible_tags([
            "ansible/roles/system_user/tasks/main.yml",
            "ansible/roles/storage/defaults/main.yml",
        ])
        assert tags == "phase1_base"

    def test_multiple_phases(self):
        tags = compute_ansible_tags([
            "ansible/roles/glusterfs/tasks/main.yml",
            "ansible/roles/runtime_sync/tasks/main.yml",
        ])
        assert tags == "phase4_glusterfs,phase7_runtime_sync"

    def test_non_role_ansible_file_returns_empty(self):
        assert compute_ansible_tags([
            "ansible/playbooks/provision.yml",
        ]) == ""

    def test_unrecognized_role_returns_empty(self):
        assert compute_ansible_tags([
            "ansible/roles/unknown_role/tasks/main.yml",
        ]) == ""

    def test_all_phases(self):
        tags = compute_ansible_tags([
            "ansible/roles/system_user/tasks/main.yml",
            "ansible/roles/docker/tasks/main.yml",
            "ansible/roles/tailscale/tasks/main.yml",
            "ansible/roles/glusterfs/tasks/main.yml",
            "ansible/roles/swarm/tasks/main.yml",
            "ansible/roles/portainer_bootstrap/tasks/main.yml",
            "ansible/roles/runtime_sync/tasks/main.yml",
        ])
        phases = tags.split(",")
        assert len(phases) == 7
        assert phases[0] == "phase1_base"
        assert phases[-1] == "phase7_runtime_sync"


# ── compute_context ──────────────────────────────────────────────────────


class TestComputeContextPush:
    def test_push_full_infra(self, fake_git: FakeGit):
        """Push with terraform changes triggers full pipeline."""
        fake_git.changed_files = [
            "terraform/infra/main.tf",
            "ansible/roles/docker/tasks/main.yml",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is True
        assert ctx.run_ansible_bootstrap is True
        assert ctx.run_portainer_apply is True
        assert ctx.run_host_sync is False
        assert ctx.run_config_sync is False
        assert ctx.run_health_redeploy is False
        assert ctx.has_work is True
        assert ctx.stacks_sha == DUMMY_SHA
        assert ctx.reason == "infra-repo-push"
        assert ctx.ansible_tags == ""

    def test_push_ansible_only_with_tags(self, fake_git: FakeGit):
        """Push touching only ansible roles derives phase tags."""
        fake_git.changed_files = [
            "ansible/roles/runtime_sync/tasks/main.yml",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is True
        assert ctx.run_portainer_apply is True
        assert ctx.ansible_tags == "phase7_runtime_sync"

    def test_push_metadata_only_noop(self, fake_git: FakeGit):
        """Push touching only metadata produces a no-op context."""
        fake_git.changed_files = [
            "docs/ci-plan-contract.md",
            ".ansible-lint",
            ".github/workflows/orchestrator.yml",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is False
        assert ctx.run_portainer_apply is False
        assert ctx.run_host_sync is False
        assert ctx.run_config_sync is False
        assert ctx.run_health_redeploy is False
        assert ctx.has_work is False
        assert ctx.reason == "infra-repo-metadata-only"

    def test_push_mixed_metadata_and_runtime_changes(self, fake_git: FakeGit):
        """Mixed metadata + runtime keeps existing full-run fallback."""
        fake_git.changed_files = [
            "docs/ci-plan-contract.md",
            "terraform/infra/main.tf",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is True
        assert ctx.run_ansible_bootstrap is True
        assert ctx.run_portainer_apply is True
        assert ctx.has_work is True
        assert ctx.reason == "infra-repo-push"

    def test_push_ansible_only_playbook_full_bootstrap(self, fake_git: FakeGit):
        """Push touching ansible playbook (not roles) = full bootstrap."""
        fake_git.changed_files = [
            "ansible/playbooks/provision.yml",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is True
        assert ctx.ansible_tags == ""

    def test_push_ansible_only_regression_non_metadata_path(self, fake_git: FakeGit):
        """Ansible-only behavior remains unchanged for runtime ansible files."""
        fake_git.changed_files = [
            "ansible/roles/docker/tasks/main.yml",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is True
        assert ctx.run_portainer_apply is True
        assert ctx.has_work is True
        assert ctx.ansible_tags == "phase2_docker"

    def test_push_stacks_sha_bump_uses_tailscale_reconcile(self, fake_git: FakeGit):
        """Push touching only stacks gitlink uses full-reconcile without infra."""
        fake_git.changed_files = [
            "stacks",
        ]
        ctx = compute_context(
            event_name="push",
            push_before=DUMMY_SHA,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is False
        assert ctx.run_portainer_apply is True
        assert ctx.run_host_sync is True
        assert ctx.run_config_sync is True
        assert ctx.run_health_redeploy is True
        assert ctx.has_work is True
        assert ctx.reason == "infra-repo-stacks-sha-bump"

    def test_push_no_diff_available(self, fake_git: FakeGit):
        """Push with null before SHA (initial push) triggers full pipeline."""
        fake_git.changed_files = []
        ctx = compute_context(
            event_name="push",
            push_before="0" * 40,
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is True
        assert ctx.run_ansible_bootstrap is True

    def test_push_empty_before(self, fake_git: FakeGit):
        """Push with empty before SHA triggers full pipeline."""
        ctx = compute_context(
            event_name="push",
            push_before="",
            push_sha=DUMMY_SHA_B,
            git=fake_git,
        )
        assert ctx.run_infra_apply is True


class TestComputeContextWorkflowDispatch:
    def test_workflow_dispatch_full(self, fake_git: FakeGit):
        ctx = compute_context(
            event_name="workflow_dispatch",
            workflow_ansible_only=False,
            git=fake_git,
        )
        assert ctx.run_infra_apply is True
        assert ctx.run_ansible_bootstrap is True
        assert ctx.run_portainer_apply is True
        assert ctx.reason == "manual-dispatch"

    def test_workflow_dispatch_ansible_only(self, fake_git: FakeGit):
        ctx = compute_context(
            event_name="workflow_dispatch",
            workflow_ansible_only=True,
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is True
        assert ctx.run_portainer_apply is True
        assert ctx.reason == "manual-dispatch"


class TestComputeContextEdgeCases:
    def test_unsupported_event_raises(self, fake_git: FakeGit):
        with pytest.raises(RuntimeError, match="Unsupported event"):
            compute_context(event_name="schedule", git=fake_git)

    def test_has_work_false_when_no_flags(self):
        ctx = ExecutionContext()
        assert ctx.has_work is False

    def test_has_work_true_single_flag(self):
        ctx = ExecutionContext(run_host_sync=True)
        assert ctx.has_work is True

    def test_stacks_sha_failure_raises(self):
        git = FakeGit(stacks_sha="")
        with pytest.raises(RuntimeError, match="stacks gitlink SHA"):
            compute_context(event_name="push", git=git)
