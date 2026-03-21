"""Tests for Traefik Host(...) extraction in cloudflare_dns_sync stage wrapper."""

from __future__ import annotations

import os
import shutil
import subprocess
from pathlib import Path

import pytest


@pytest.fixture(scope="module")
def repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


@pytest.fixture(scope="module")
def stage_script(repo_root: Path) -> Path:
    return repo_root / ".github/scripts/stages/cloudflare_dns_sync.sh"


@pytest.fixture(autouse=True)
def require_yq() -> None:
    if shutil.which("yq") is None:
        pytest.skip("yq is required for DNS host extraction tests")


def _write(path: Path, content: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8")


def _run_extract(
    *,
    repo_root: Path,
    stage_script: Path,
    stacks_manifest: Path,
    base_domain: str,
    include_legacy: bool = False,
) -> list[str]:
    env = os.environ.copy()
    env.update(
        {
            "BASE_DOMAIN": base_domain,
            "DNS_SYNC_EXTRACT_ONLY": "true",
            "DNS_SYNC_INCLUDE_LEGACY_STACK_NAMES": "true" if include_legacy else "false",
            "STACKS_MANIFEST": str(stacks_manifest),
        }
    )

    result = subprocess.run(
        ["bash", str(stage_script)],
        cwd=repo_root,
        env=env,
        check=True,
        capture_output=True,
        text=True,
    )

    return [line.strip() for line in result.stdout.splitlines() if line.strip()]


def test_extract_hosts_normalizes_and_dedupes(
    tmp_path: Path,
    repo_root: Path,
    stage_script: Path,
) -> None:
    stacks_dir = tmp_path / "stacks"
    manifest = stacks_dir / "stacks.yaml"

    _write(
        manifest,
        """
version: 1
stacks:
  gateway:
    compose_path: gateway/docker-compose.yml
    portainer_managed: true
  observability:
    compose_path: observability/docker-compose.yml
    portainer_managed: true
  management:
    compose_path: management/docker-compose.yml
    portainer_managed: false
""".strip()
        + "\n",
    )

    _write(
        stacks_dir / "gateway/docker-compose.yml",
        """
services:
  app:
    labels:
      - "traefik.http.routers.gateway.rule=Host(`gateway.${BASE_DOMAIN}`)"
      - "traefik.http.routers.gateway-health.rule=Host(`gateway-health.${BASE_DOMAIN}`) && Path(`/healthz`)"
      - "traefik.http.routers.multi.rule=Host(`files.${BASE_DOMAIN}`, `status.${BASE_DOMAIN}`)"
      - "traefik.http.routers.skip.rule=Host(`api.${OTHER_DOMAIN}`)"
""".strip()
        + "\n",
    )

    _write(
        stacks_dir / "observability/docker-compose.yml",
        """
services:
  grafana:
    labels:
      traefik.http.routers.grafana.rule: Host(`grafana.${BASE_DOMAIN}`)
      traefik.http.routers.auth.rule: Host(`AUTH.${BASE_DOMAIN}`)
      traefik.http.routers.duplicate.rule: Host(`gateway.${BASE_DOMAIN}`)
""".strip()
        + "\n",
    )

    _write(
        stacks_dir / "management/docker-compose.yml",
        """
services:
  portainer:
    labels:
      - "traefik.http.routers.portainer.rule=Host(`portainer.${BASE_DOMAIN}`)"
""".strip()
        + "\n",
    )

    hosts = _run_extract(
        repo_root=repo_root,
        stage_script=stage_script,
        stacks_manifest=manifest,
        base_domain="example.com",
    )

    assert hosts == [
        "auth",
        "files",
        "gateway",
        "gateway-health",
        "grafana",
        "portainer",
        "status",
    ]


def test_extract_hosts_optional_legacy_stack_names(
    tmp_path: Path,
    repo_root: Path,
    stage_script: Path,
) -> None:
    stacks_dir = tmp_path / "stacks"
    manifest = stacks_dir / "stacks.yaml"

    _write(
        manifest,
        """
version: 1
stacks:
  auth:
    compose_path: auth/docker-compose.yml
    portainer_managed: true
""".strip()
        + "\n",
    )

    _write(
        stacks_dir / "auth/docker-compose.yml",
        """
services:
  authelia:
    labels:
      - "traefik.http.routers.authelia.rule=Host(`login.${BASE_DOMAIN}`)"
""".strip()
        + "\n",
    )

    hosts = _run_extract(
        repo_root=repo_root,
        stage_script=stage_script,
        stacks_manifest=manifest,
        base_domain="example.com",
        include_legacy=True,
    )

    assert hosts == ["auth", "login"]
