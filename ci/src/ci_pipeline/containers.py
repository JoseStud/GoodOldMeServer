"""Container factories for CI pipeline stages.

Each factory returns a pre-configured Dagger Container with the tools
required by a group of stage scripts.  Tool versions are pinned from
.github/ci/tool-versions.lock.
"""

from __future__ import annotations

from pathlib import Path

import dagger


# ---------------------------------------------------------------------------
# Tool version loader
# ---------------------------------------------------------------------------


def load_tool_versions(lock_path: str = ".github/ci/tool-versions.lock") -> dict[str, str]:
    """Parse KEY=VALUE assignments from tool-versions.lock."""
    versions: dict[str, str] = {}
    path = Path(lock_path)
    if not path.exists():
        return versions
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" in line:
            key, _, value = line.partition("=")
            versions[key.strip()] = value.strip()
    return versions


# ---------------------------------------------------------------------------
# Base container: curl, jq, bash, git
# ---------------------------------------------------------------------------


def base_container(
    client: dagger.Client,
    *,
    jq_version: str = "",
    jq_sha256: str = "",
) -> dagger.Container:
    """Alpine container with curl, jq, bash, and git.

    Used by: stacks-sha-trust, inventory-handover, build-network-access-policy.
    """
    ctr = (
        client.container()
        .from_("alpine:3.21")
        .with_exec(["apk", "add", "--no-cache", "bash", "curl", "git", "coreutils"])
    )

    if jq_version and jq_sha256:
        ctr = _install_jq(ctr, jq_version, jq_sha256)
    else:
        ctr = ctr.with_exec(["apk", "add", "--no-cache", "jq"])

    return ctr


# ---------------------------------------------------------------------------
# Extended base: adds yq, python3, netcat
# ---------------------------------------------------------------------------


def network_container(
    client: dagger.Client,
    *,
    jq_version: str = "",
    jq_sha256: str = "",
    yq_version: str = "",
    yq_sha256: str = "",
) -> dagger.Container:
    """Alpine container with curl, jq, yq, python3, netcat, bash, git.

    Used by: preflight-network-access, network-policy-sync.
    """
    ctr = base_container(client, jq_version=jq_version, jq_sha256=jq_sha256)
    ctr = ctr.with_exec(["apk", "add", "--no-cache", "python3", "netcat-openbsd"])

    if yq_version and yq_sha256:
        ctr = _install_yq(ctr, yq_version, yq_sha256)
    else:
        ctr = ctr.with_exec(["apk", "add", "--no-cache", "yq"])

    return ctr


# ---------------------------------------------------------------------------
# Infisical container: base + infisical CLI
# ---------------------------------------------------------------------------


def infisical_container(
    client: dagger.Client,
    *,
    jq_version: str = "",
    jq_sha256: str = "",
) -> dagger.Container:
    """Alpine container with curl, jq, bash, and infisical CLI.

    Used by: secret-validation, post-bootstrap-secret-check,
    portainer-api-preflight.
    """
    ctr = base_container(client, jq_version=jq_version, jq_sha256=jq_sha256)
    return _install_infisical(ctr)


# ---------------------------------------------------------------------------
# Terraform container: base + terraform + infisical
# ---------------------------------------------------------------------------


def terraform_container(
    client: dagger.Client,
    *,
    jq_version: str = "",
    jq_sha256: str = "",
) -> dagger.Container:
    """Alpine container with terraform, jq, curl, bash, and infisical CLI.

    Used by: portainer-apply.
    """
    ctr = (
        client.container()
        .from_("hashicorp/terraform:latest")
        .with_exec(["apk", "add", "--no-cache", "bash", "curl", "git"])
    )

    if jq_version and jq_sha256:
        ctr = _install_jq(ctr, jq_version, jq_sha256)
    else:
        ctr = ctr.with_exec(["apk", "add", "--no-cache", "jq"])

    return _install_infisical(ctr)


# ---------------------------------------------------------------------------
# Webhook container: base + yq + gomplate
# ---------------------------------------------------------------------------


def webhook_container(
    client: dagger.Client,
    *,
    jq_version: str = "",
    jq_sha256: str = "",
    yq_version: str = "",
    yq_sha256: str = "",
) -> dagger.Container:
    """Alpine container with curl, jq, yq, gomplate, bash, infisical.

    Used by: health-gated-redeploy.
    """
    ctr = network_container(
        client,
        jq_version=jq_version,
        jq_sha256=jq_sha256,
        yq_version=yq_version,
        yq_sha256=yq_sha256,
    )
    ctr = ctr.with_exec([
        "sh", "-c",
        "curl -sSL https://github.com/hairyhenderson/gomplate/releases/latest/download/gomplate_linux-amd64"
        " -o /usr/local/bin/gomplate && chmod +x /usr/local/bin/gomplate",
    ])
    return _install_infisical(ctr)


# ---------------------------------------------------------------------------
# Helpers: pinned tool installers
# ---------------------------------------------------------------------------


def _install_jq(ctr: dagger.Container, version: str, sha256: str) -> dagger.Container:
    """Install a specific jq version with checksum verification."""
    url = f"https://github.com/jqlang/jq/releases/download/jq-{version}/jq-linux-amd64"
    return ctr.with_exec([
        "sh", "-c",
        f'curl -sSL "{url}" -o /usr/local/bin/jq'
        f' && echo "{sha256}  /usr/local/bin/jq" | sha256sum -c'
        " && chmod +x /usr/local/bin/jq",
    ])


def _install_yq(ctr: dagger.Container, version: str, sha256: str) -> dagger.Container:
    """Install a specific yq version with checksum verification."""
    url = f"https://github.com/mikefarah/yq/releases/download/v{version}/yq_linux_amd64"
    return ctr.with_exec([
        "sh", "-c",
        f'curl -sSL "{url}" -o /usr/local/bin/yq'
        f' && echo "{sha256}  /usr/local/bin/yq" | sha256sum -c'
        " && chmod +x /usr/local/bin/yq",
    ])


def _install_infisical(ctr: dagger.Container) -> dagger.Container:
    """Install the Infisical CLI via official install script."""
    return ctr.with_exec([
        "sh", "-c",
        "curl -1sLf 'https://dl.cloudsmith.io/public/infisical/infisical-cli/setup.alpine.sh'"
        " | sh && apk add --no-cache infisical",
    ])


# ---------------------------------------------------------------------------
# Convenience: auto-load versions from lock file
# ---------------------------------------------------------------------------


def container_from_profile(
    client: dagger.Client,
    profile: str,
    lock_path: str = ".github/ci/tool-versions.lock",
) -> dagger.Container:
    """Create a container by profile name, auto-loading tool versions.

    Profiles: base, network, infisical, terraform, webhook.
    Ansible runs as a host subprocess (not containerized).
    """
    versions = load_tool_versions(lock_path)
    jq_kw = {
        "jq_version": versions.get("JQ_VERSION", ""),
        "jq_sha256": versions.get("JQ_SHA256", ""),
    }
    yq_kw = {
        "yq_version": versions.get("YQ_VERSION", ""),
        "yq_sha256": versions.get("YQ_SHA256", ""),
    }

    factories = {
        "base": lambda: base_container(client, **jq_kw),
        "network": lambda: network_container(client, **jq_kw, **yq_kw),
        "infisical": lambda: infisical_container(client, **jq_kw),
        "terraform": lambda: terraform_container(client, **jq_kw),
        "webhook": lambda: webhook_container(client, **jq_kw, **yq_kw),
    }

    factory = factories.get(profile)
    if factory is None:
        raise ValueError(
            f"Unknown container profile '{profile}'. "
            f"Available: {', '.join(sorted(factories))}"
        )
    return factory()
