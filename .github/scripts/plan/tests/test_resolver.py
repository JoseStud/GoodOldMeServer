"""Port of test_resolve_ci_plan.sh cases 1-4b."""

from __future__ import annotations

import pytest

from ci_plan.models import ResolveContext
from ci_plan.resolver import resolve_meta_plan

from .conftest import DUMMY_SHA, DUMMY_SHA_B, FakeGit, make_dispatch_context, make_push_context


class TestPushFullReconcile:
    """Case 1: infra-repo push always runs the full infra-side reconcile path."""

    def test_flags(self):
        ctx = make_push_context()
        # Non-ansible file changed → full infra apply
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)

        assert plan.meta.run_infra_apply is True
        assert plan.meta.run_ansible_bootstrap is True
        assert plan.meta.run_portainer_apply is True
        assert plan.meta.run_health_redeploy is False
        assert plan.meta.reason == "infra-repo-push"
        assert plan.plan_schema_version == "ci-plan-v1"

    def test_stacks_sha_populated(self):
        stacks_sha = "c" * 40
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"], stacks_sha=stacks_sha)
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.stacks_sha == stacks_sha


class TestRepositoryDispatchFullReconcile:
    """Case 2: repository_dispatch v5 always runs full reconcile."""

    def test_flags(self):
        ctx = make_dispatch_context()
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)

        assert plan.meta.run_portainer_apply is True
        assert plan.meta.run_host_sync is True
        assert plan.meta.run_config_sync is True
        assert plan.meta.run_health_redeploy is True
        assert plan.meta.reason == "full-reconcile"
        assert plan.meta.stacks_sha == DUMMY_SHA

    def test_infra_and_ansible_not_run(self):
        ctx = make_dispatch_context()
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)

        assert plan.meta.run_infra_apply is False
        assert plan.meta.run_ansible_bootstrap is False


class TestWorkflowDispatchFullReconcile:
    """Case 3: workflow_dispatch runs full infra-side reconcile."""

    def test_flags(self):
        ctx = ResolveContext(event_name="workflow_dispatch")
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)

        assert plan.meta.run_infra_apply is True
        assert plan.meta.run_ansible_bootstrap is True
        assert plan.meta.run_portainer_apply is True
        assert plan.meta.run_health_redeploy is False
        assert plan.meta.reason == "manual-dispatch"
        assert plan.meta.stacks_sha == DUMMY_SHA


class TestPushAnsibleOnly:
    """Case 4a: ansible-only push skips infra apply, runs bootstrap + portainer."""

    def test_skips_infra(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["ansible/roles/runtime_sync/tasks/main.yml"])
        plan = resolve_meta_plan(ctx, git)

        assert plan.meta.run_infra_apply is False
        assert plan.meta.run_ansible_bootstrap is True
        assert plan.meta.run_portainer_apply is True
        assert plan.meta.run_health_redeploy is False
        assert plan.meta.reason == "infra-repo-push"


class TestDispatchAnsibleOnly:
    """Case 4b: dispatch_ansible_only skips infra apply."""

    def test_skips_infra(self):
        ctx = ResolveContext(event_name="dispatch_ansible_only")
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)

        assert plan.meta.run_infra_apply is False
        assert plan.meta.run_ansible_bootstrap is True
        assert plan.meta.run_portainer_apply is True
        assert plan.meta.run_health_redeploy is False
        assert plan.meta.reason == "manual-dispatch"
        assert plan.meta.stacks_sha == DUMMY_SHA


class TestUnsupportedMode:
    """Case 4: iac mode is retired."""

    def test_iac_mode_rejected(self):
        ctx = ResolveContext(event_name="push", ci_plan_mode="iac")
        git = FakeGit()
        with pytest.raises(SystemExit):
            resolve_meta_plan(ctx, git)


class TestUnsupportedEvent:
    def test_unknown_event_rejected(self):
        ctx = ResolveContext(event_name="schedule")
        git = FakeGit()
        with pytest.raises(SystemExit):
            resolve_meta_plan(ctx, git)


class TestNullShaHandling:
    """First push or null SHA falls back to full infra apply."""

    def test_null_push_before(self):
        ctx = make_push_context(push_before="0" * 40)
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)
        # Cannot compute diff → not ansible-only → full infra apply
        assert plan.meta.run_infra_apply is True

    def test_empty_push_before(self):
        ctx = make_push_context(push_before="")
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.run_infra_apply is True

    def test_empty_push_sha(self):
        ctx = make_push_context(push_sha="")
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.run_infra_apply is True


class TestEmptyDiff:
    """No changed files returns safe defaults (full infra apply)."""

    def test_empty_changed_files(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=[])
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.run_infra_apply is True


class TestGitDiffFailure:
    """git diff failure falls back to full infra apply."""

    def test_diff_error_fallback(self):
        from ci_plan.git import GitDiffError

        ctx = make_push_context()
        git = FakeGit(diff_error=GitDiffError("fatal: bad revision"))
        plan = resolve_meta_plan(ctx, git)
        assert plan.meta.run_infra_apply is True
        assert plan.meta.run_ansible_bootstrap is True
