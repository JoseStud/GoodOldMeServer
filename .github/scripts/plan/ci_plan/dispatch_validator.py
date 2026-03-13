"""Dispatch payload validation — port of validate_dispatch_payload.sh."""

from __future__ import annotations

import json
import re

from .models import ResolveContext

_SHA_RE = re.compile(r"^[0-9a-f]{40}$")
_SOURCE_REPO_RE = re.compile(r"^[A-Za-z0-9_.\-]+/[A-Za-z0-9_.\-]+$")
_EXPECTED_PAYLOAD_KEYS = sorted(
    ["reason", "schema_version", "source_repo", "source_run_id", "source_sha", "stacks_sha"]
)

_REMOVED_ENV_FIELDS = (
    ("PAYLOAD_CHANGED_STACKS", "changed_stacks"),
    ("PAYLOAD_CHANGED_STACKS_JSON", "changed_stacks"),
    ("PAYLOAD_HOST_SYNC_STACKS", "host_sync_stacks"),
    ("PAYLOAD_HOST_SYNC_STACKS_JSON", "host_sync_stacks"),
    ("PAYLOAD_CONFIG_STACKS", "config_stacks"),
    ("PAYLOAD_CONFIG_STACKS_JSON", "config_stacks"),
    ("PAYLOAD_STRUCTURAL_CHANGE", "structural_change"),
    ("PAYLOAD_CHANGED_PATHS", "changed_paths"),
    ("PAYLOAD_CHANGED_PATHS_JSON", "changed_paths"),
)


class DispatchValidationError(Exception):
    pass


def _is_valid_sha(value: str) -> bool:
    return bool(_SHA_RE.match(value))


def _validate_payload_shape(payload_json: str) -> None:
    if not payload_json or payload_json == "null":
        return

    try:
        payload = json.loads(payload_json)
    except json.JSONDecodeError:
        raise DispatchValidationError("repository_dispatch payload must be a JSON object.")

    if not isinstance(payload, dict):
        raise DispatchValidationError("repository_dispatch payload must be a JSON object.")

    actual_keys = sorted(payload.keys())
    if actual_keys != _EXPECTED_PAYLOAD_KEYS:
        raise DispatchValidationError(
            "repository_dispatch payload must contain only: "
            "schema_version, stacks_sha, source_sha, source_repo, source_run_id, reason."
        )


def _validate_schema_version(payload_json: str) -> None:
    if not payload_json or payload_json == "null":
        raise DispatchValidationError(
            "repository_dispatch payload must include client_payload.schema_version."
        )

    payload = json.loads(payload_json)
    version = payload.get("schema_version", "")
    if not version:
        raise DispatchValidationError(
            "repository_dispatch payload must include client_payload.schema_version."
        )
    if version != "v5":
        raise DispatchValidationError(
            f"Unsupported dispatch schema_version '{version}'. Expected 'v5'."
        )


def _validate_sha(field_name: str, sha: str) -> None:
    if not sha or sha == "null":
        raise DispatchValidationError(
            f"repository_dispatch payload must include non-empty client_payload.{field_name}."
        )
    if not _is_valid_sha(sha):
        raise DispatchValidationError(
            f"Invalid {field_name}: '{sha}' (must be 40-char lowercase hex)."
        )


def _validate_reason(reason: str) -> None:
    if not reason or reason == "null":
        raise DispatchValidationError(
            "repository_dispatch payload must include non-empty client_payload.reason."
        )
    if reason != "full-reconcile":
        raise DispatchValidationError(
            f"Invalid reason '{reason}'. Expected 'full-reconcile'."
        )


def _validate_source_repo(value: str) -> None:
    if not value or value == "null":
        raise DispatchValidationError(
            "repository_dispatch payload must include client_payload.source_repo."
        )
    if not _SOURCE_REPO_RE.match(value):
        raise DispatchValidationError(
            f"Invalid source_repo '{value}'. Expected 'owner/repo'."
        )


def _validate_source_run_id(value: str) -> None:
    if not value or value == "null":
        raise DispatchValidationError(
            "repository_dispatch payload must include client_payload.source_run_id."
        )
    if not value.isdigit():
        raise DispatchValidationError(
            f"Invalid source_run_id '{value}'. Expected numeric run id."
        )


def _reject_removed_fields(extra_env: dict[str, str]) -> None:
    for env_key, field_name in _REMOVED_ENV_FIELDS:
        value = extra_env.get(env_key, "")
        if value and value != "null":
            raise DispatchValidationError(
                f"repository_dispatch payload must not include removed client_payload.{field_name}."
            )


def validate_dispatch_payload(
    ctx: ResolveContext,
    extra_env: dict[str, str] | None = None,
) -> None:
    """Validate a repository_dispatch payload. Raises DispatchValidationError on failure."""
    if ctx.event_name != "repository_dispatch":
        return

    _validate_payload_shape(ctx.payload_json)
    _validate_schema_version(ctx.payload_json)
    _validate_sha("stacks_sha", ctx.payload_stacks_sha)
    _validate_sha("source_sha", ctx.payload_source_sha)
    _validate_reason(ctx.payload_reason)
    _validate_source_repo(ctx.payload_source_repo)
    _validate_source_run_id(ctx.payload_source_run_id)
    _reject_removed_fields(extra_env or {})
