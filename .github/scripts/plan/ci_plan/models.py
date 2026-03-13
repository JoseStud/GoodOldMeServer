"""Typed dataclasses for the ci-plan-v1 schema."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass

PLAN_SCHEMA_VERSION = "ci-plan-v1"


@dataclass(frozen=True)
class Stages:
    stage_cloud_runner_guard: bool
    stage_secret_validation: bool
    stage_network_policy_sync: bool
    stage_infra_apply: bool
    stage_inventory_handover: bool
    stage_network_preflight_ssh: bool
    stage_ansible_bootstrap: bool
    stage_host_sync: bool
    stage_post_bootstrap_secret_check: bool
    stage_portainer_api_preflight: bool
    stage_portainer_apply: bool
    stage_config_sync: bool
    stage_health_gated_redeploy: bool


@dataclass(frozen=True)
class MetaPlan:
    run_infra_apply: bool
    run_ansible_bootstrap: bool
    run_portainer_apply: bool
    run_host_sync: bool
    run_config_sync: bool
    run_health_redeploy: bool
    ansible_tags: str
    has_work: bool
    stacks_sha: str
    reason: str
    stages: Stages


@dataclass(frozen=True)
class CIPlan:
    plan_schema_version: str
    mode: str
    event_name: str
    meta: MetaPlan

    def to_json(self) -> str:
        """Serialize to compact JSON matching jq -cn output format."""
        return json.dumps(asdict(self), separators=(",", ":"))


@dataclass(frozen=True)
class ResolveContext:
    """All inputs needed to compute a plan, decoupled from env vars."""

    event_name: str
    ci_plan_mode: str = "meta"
    push_before: str = ""
    push_sha: str = ""
    payload_json: str = ""
    payload_stacks_sha: str = ""
    payload_reason: str = ""
    payload_source_repo: str = ""
    payload_source_run_id: str = ""
    payload_source_sha: str = ""
    validate_dispatch_contract: bool = True
