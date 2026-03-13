"""Exhaustive stage derivation tests."""

from __future__ import annotations

import pytest

from ci_plan.models import ResolveContext
from ci_plan.resolver import derive_stages, resolve_meta_plan

from .conftest import DUMMY_SHA, FakeGit, make_dispatch_context, make_push_context


class TestDeriveStages:
    """Direct tests of the stage derivation logic."""

    def test_no_work(self):
        stages = derive_stages(
            run_infra_apply=False,
            run_ansible_bootstrap=False,
            run_portainer_apply=False,
            run_host_sync=False,
            run_config_sync=False,
            run_health_redeploy=False,
            has_work=False,
        )
        assert stages.stage_cloud_runner_guard is False
        assert stages.stage_secret_validation is False
        assert stages.stage_network_policy_sync is False
        assert stages.stage_infra_apply is False
        assert stages.stage_inventory_handover is False
        assert stages.stage_network_preflight_ssh is False
        assert stages.stage_ansible_bootstrap is False
        assert stages.stage_host_sync is False
        assert stages.stage_post_bootstrap_secret_check is False
        assert stages.stage_portainer_api_preflight is False
        assert stages.stage_portainer_apply is False
        assert stages.stage_config_sync is False
        assert stages.stage_health_gated_redeploy is False

    def test_full_infra_push(self):
        stages = derive_stages(
            run_infra_apply=True,
            run_ansible_bootstrap=True,
            run_portainer_apply=True,
            run_host_sync=False,
            run_config_sync=False,
            run_health_redeploy=False,
            has_work=True,
        )
        assert stages.stage_cloud_runner_guard is True
        assert stages.stage_secret_validation is True
        assert stages.stage_network_policy_sync is True
        assert stages.stage_infra_apply is True
        assert stages.stage_inventory_handover is True
        assert stages.stage_network_preflight_ssh is True
        assert stages.stage_ansible_bootstrap is True
        assert stages.stage_host_sync is False
        assert stages.stage_post_bootstrap_secret_check is True
        assert stages.stage_portainer_api_preflight is True
        assert stages.stage_portainer_apply is True
        assert stages.stage_config_sync is False
        assert stages.stage_health_gated_redeploy is False

    def test_repository_dispatch_reconcile(self):
        """Dispatch runs portainer, host_sync, config_sync, health_redeploy."""
        stages = derive_stages(
            run_infra_apply=False,
            run_ansible_bootstrap=False,
            run_portainer_apply=True,
            run_host_sync=True,
            run_config_sync=True,
            run_health_redeploy=True,
            has_work=True,
        )
        assert stages.stage_infra_apply is False
        assert stages.stage_ansible_bootstrap is False
        # host_sync enabled (no ansible_bootstrap to conflict)
        assert stages.stage_host_sync is True
        assert stages.stage_inventory_handover is True
        assert stages.stage_network_preflight_ssh is True
        assert stages.stage_post_bootstrap_secret_check is True
        assert stages.stage_portainer_api_preflight is True
        assert stages.stage_portainer_apply is True
        assert stages.stage_config_sync is True
        assert stages.stage_health_gated_redeploy is True

    def test_host_sync_mutually_exclusive_with_bootstrap(self):
        """host_sync is suppressed when ansible_bootstrap is also true."""
        stages = derive_stages(
            run_infra_apply=False,
            run_ansible_bootstrap=True,
            run_portainer_apply=True,
            run_host_sync=True,
            run_config_sync=False,
            run_health_redeploy=False,
            has_work=True,
        )
        assert stages.stage_ansible_bootstrap is True
        assert stages.stage_host_sync is False

    def test_inventory_handover_from_config_sync_only(self):
        """config_sync alone triggers inventory handover."""
        stages = derive_stages(
            run_infra_apply=False,
            run_ansible_bootstrap=False,
            run_portainer_apply=False,
            run_host_sync=False,
            run_config_sync=True,
            run_health_redeploy=False,
            has_work=True,
        )
        assert stages.stage_inventory_handover is True
        assert stages.stage_network_preflight_ssh is True

    def test_portainer_api_preflight_from_health_redeploy(self):
        """health_redeploy alone triggers portainer_api_preflight."""
        stages = derive_stages(
            run_infra_apply=False,
            run_ansible_bootstrap=False,
            run_portainer_apply=False,
            run_host_sync=False,
            run_config_sync=False,
            run_health_redeploy=True,
            has_work=True,
        )
        assert stages.stage_portainer_api_preflight is True
        assert stages.stage_portainer_apply is False


class TestStageDerivationEndToEnd:
    """Verify stage flags through the full resolver for each event type."""

    def test_push_full_stages(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)
        s = plan.meta.stages
        assert s.stage_cloud_runner_guard is True
        assert s.stage_infra_apply is True
        assert s.stage_ansible_bootstrap is True
        assert s.stage_host_sync is False
        assert s.stage_portainer_apply is True

    def test_push_ansible_only_stages(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["ansible/roles/docker/tasks/main.yml"])
        plan = resolve_meta_plan(ctx, git)
        s = plan.meta.stages
        assert s.stage_infra_apply is False
        assert s.stage_ansible_bootstrap is True
        assert s.stage_inventory_handover is True

    def test_dispatch_stages(self):
        ctx = make_dispatch_context()
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)
        s = plan.meta.stages
        assert s.stage_infra_apply is False
        assert s.stage_ansible_bootstrap is False
        assert s.stage_host_sync is True
        assert s.stage_config_sync is True
        assert s.stage_health_gated_redeploy is True
        assert s.stage_portainer_apply is True

    def test_workflow_dispatch_stages(self):
        ctx = ResolveContext(event_name="workflow_dispatch")
        git = FakeGit()
        plan = resolve_meta_plan(ctx, git)
        s = plan.meta.stages
        assert s.stage_infra_apply is True
        assert s.stage_ansible_bootstrap is True
        assert s.stage_portainer_apply is True
        assert s.stage_host_sync is False
