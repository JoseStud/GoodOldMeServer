"""JSON output format verification."""

from __future__ import annotations

import json
import os
import tempfile

from ci_plan.github_actions import emit_output
from ci_plan.models import CIPlan, MetaPlan, Stages
from ci_plan.resolver import resolve_meta_plan

from .conftest import DUMMY_SHA, FakeGit, make_push_context


class TestJsonSerialization:
    def test_compact_json_format(self):
        """Output must be compact JSON (no spaces) matching jq -cn."""
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)
        plan_json = plan.to_json()

        # Must be valid JSON
        parsed = json.loads(plan_json)

        # Must be compact (no spaces after separators)
        assert " " not in plan_json.replace("infra-repo-push", "").replace(
            "ci-plan-v1", ""
        )

    def test_roundtrip_preserves_types(self):
        """JSON round-trip preserves booleans (not strings)."""
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)
        parsed = json.loads(plan.to_json())

        assert parsed["meta"]["run_infra_apply"] is True
        assert parsed["meta"]["has_work"] is True
        assert isinstance(parsed["meta"]["run_infra_apply"], bool)
        assert isinstance(parsed["meta"]["stages"]["stage_infra_apply"], bool)

    def test_key_order_matches_schema(self):
        """Top-level key order must match the ci-plan-v1 schema."""
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)
        parsed = json.loads(plan.to_json())

        top_keys = list(parsed.keys())
        assert top_keys == ["plan_schema_version", "mode", "event_name", "meta"]

        meta_keys = list(parsed["meta"].keys())
        assert meta_keys == [
            "run_infra_apply",
            "run_ansible_bootstrap",
            "run_portainer_apply",
            "run_host_sync",
            "run_config_sync",
            "run_health_redeploy",
            "ansible_tags",
            "has_work",
            "stacks_sha",
            "reason",
            "stages",
        ]

        stage_keys = list(parsed["meta"]["stages"].keys())
        assert stage_keys == [
            "stage_cloud_runner_guard",
            "stage_secret_validation",
            "stage_network_policy_sync",
            "stage_infra_apply",
            "stage_inventory_handover",
            "stage_network_preflight_ssh",
            "stage_ansible_bootstrap",
            "stage_host_sync",
            "stage_post_bootstrap_secret_check",
            "stage_portainer_api_preflight",
            "stage_portainer_apply",
            "stage_config_sync",
            "stage_health_gated_redeploy",
        ]

    def test_schema_version_value(self):
        ctx = make_push_context()
        git = FakeGit(changed_files=["terraform/main.tf"])
        plan = resolve_meta_plan(ctx, git)
        parsed = json.loads(plan.to_json())
        assert parsed["plan_schema_version"] == "ci-plan-v1"
        assert parsed["mode"] == "meta"


class TestEmitOutput:
    def test_single_line_format(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".out", delete=False) as f:
            path = f.name

        try:
            os.environ["GITHUB_OUTPUT"] = path
            emit_output("plan_json", '{"key":"value"}')

            with open(path) as f:
                content = f.read()
            assert content == 'plan_json={"key":"value"}\n'
        finally:
            os.unlink(path)
            del os.environ["GITHUB_OUTPUT"]

    def test_multiline_format(self):
        with tempfile.NamedTemporaryFile(mode="w", suffix=".out", delete=False) as f:
            path = f.name

        try:
            os.environ["GITHUB_OUTPUT"] = path
            emit_output("data", "line1\nline2")

            with open(path) as f:
                content = f.read()
            # Should use heredoc delimiter format
            assert content.startswith("data<<EOF_")
            assert "line1\nline2\n" in content
        finally:
            os.unlink(path)
            del os.environ["GITHUB_OUTPUT"]
