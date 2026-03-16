"""Tests for ci_pipeline.context — execution context computation."""

from __future__ import annotations

import json

import pytest

from ci_pipeline.context import (
    DispatchValidationError,
    ExecutionContext,
    compute_ansible_tags,
    compute_context,
    is_ansible_only,
    validate_dispatch_payload,
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


# ── validate_dispatch_payload ────────────────────────────────────────────


def _valid_payload() -> dict:
    return {
        "schema_version": "v5",
        "stacks_sha": DUMMY_SHA,
        "source_sha": DUMMY_SHA_B,
        "reason": "full-reconcile",
        "source_repo": "JoseStud/stacks",
        "source_run_id": "12345",
    }


class TestValidateDispatchPayload:
    def test_valid_payload_passes(self):
        payload = _valid_payload()
        validate_dispatch_payload(
            json.dumps(payload),
            stacks_sha=payload["stacks_sha"],
            source_sha=payload["source_sha"],
            reason=payload["reason"],
            source_repo=payload["source_repo"],
            source_run_id=payload["source_run_id"],
        )

    def test_empty_payload_raises(self):
        with pytest.raises(DispatchValidationError, match="JSON object"):
            validate_dispatch_payload(
                "", stacks_sha="", source_sha="", reason="",
                source_repo="", source_run_id="",
            )

    def test_null_payload_raises(self):
        with pytest.raises(DispatchValidationError, match="JSON object"):
            validate_dispatch_payload(
                "null", stacks_sha="", source_sha="", reason="",
                source_repo="", source_run_id="",
            )

    def test_wrong_schema_version_raises(self):
        payload = _valid_payload()
        payload["schema_version"] = "v4"
        with pytest.raises(DispatchValidationError, match="v4"):
            validate_dispatch_payload(
                json.dumps(payload),
                stacks_sha=payload["stacks_sha"],
                source_sha=payload["source_sha"],
                reason=payload["reason"],
                source_repo=payload["source_repo"],
                source_run_id=payload["source_run_id"],
            )

    def test_extra_key_raises(self):
        payload = _valid_payload()
        payload["extra_field"] = "oops"
        with pytest.raises(DispatchValidationError, match="must contain only"):
            validate_dispatch_payload(
                json.dumps(payload),
                stacks_sha=payload["stacks_sha"],
                source_sha=payload["source_sha"],
                reason=payload["reason"],
                source_repo=payload["source_repo"],
                source_run_id=payload["source_run_id"],
            )

    def test_invalid_stacks_sha_raises(self):
        payload = _valid_payload()
        with pytest.raises(DispatchValidationError, match="stacks_sha"):
            validate_dispatch_payload(
                json.dumps(payload),
                stacks_sha="not-a-sha",
                source_sha=payload["source_sha"],
                reason=payload["reason"],
                source_repo=payload["source_repo"],
                source_run_id=payload["source_run_id"],
            )

    def test_wrong_reason_raises(self):
        payload = _valid_payload()
        with pytest.raises(DispatchValidationError, match="reason"):
            validate_dispatch_payload(
                json.dumps(payload),
                stacks_sha=payload["stacks_sha"],
                source_sha=payload["source_sha"],
                reason="partial-reconcile",
                source_repo=payload["source_repo"],
                source_run_id=payload["source_run_id"],
            )

    def test_invalid_source_repo_raises(self):
        payload = _valid_payload()
        with pytest.raises(DispatchValidationError, match="source_repo"):
            validate_dispatch_payload(
                json.dumps(payload),
                stacks_sha=payload["stacks_sha"],
                source_sha=payload["source_sha"],
                reason=payload["reason"],
                source_repo="no-slash",
                source_run_id=payload["source_run_id"],
            )

    def test_non_numeric_run_id_raises(self):
        payload = _valid_payload()
        with pytest.raises(DispatchValidationError, match="source_run_id"):
            validate_dispatch_payload(
                json.dumps(payload),
                stacks_sha=payload["stacks_sha"],
                source_sha=payload["source_sha"],
                reason=payload["reason"],
                source_repo=payload["source_repo"],
                source_run_id="abc",
            )


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


class TestComputeContextDispatch:
    def test_repository_dispatch(self, fake_git: FakeGit):
        payload = _valid_payload()
        ctx = compute_context(
            event_name="repository_dispatch",
            payload_json=json.dumps(payload),
            payload_stacks_sha=payload["stacks_sha"],
            payload_reason=payload["reason"],
            payload_source_repo=payload["source_repo"],
            payload_source_run_id=payload["source_run_id"],
            payload_source_sha=payload["source_sha"],
            git=fake_git,
        )
        assert ctx.run_infra_apply is False
        assert ctx.run_ansible_bootstrap is False
        assert ctx.run_portainer_apply is True
        assert ctx.run_host_sync is True
        assert ctx.run_config_sync is True
        assert ctx.run_health_redeploy is True
        assert ctx.stacks_sha == DUMMY_SHA
        assert ctx.reason == "full-reconcile"
        assert ctx.has_work is True

    def test_invalid_dispatch_raises(self, fake_git: FakeGit):
        with pytest.raises(DispatchValidationError):
            compute_context(
                event_name="repository_dispatch",
                payload_json="{}",
                git=fake_git,
            )


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
