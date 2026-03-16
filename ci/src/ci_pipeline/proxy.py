"""Tailscale SOCKS5 proxy wiring for Dagger containers.

The tailscale/github-action@v3 exposes a SOCKS5 proxy on localhost:1055
on the GitHub Actions runner.  Dagger containers cannot natively see
this.  This module maps the proxy into containers via Dagger's Host
Service binding.

Usage:
    proxy = TailscaleProxy(client)
    container = proxy.bind(container)  # adds service binding + env vars
"""

from __future__ import annotations

import dagger

SOCKS5_PORT = 1055
SERVICE_NAME = "tailscale-proxy"

# Public internet domains that must bypass the Tailscale SOCKS5 proxy.
# The proxy only routes Tailscale-internal destinations; routing public
# traffic through it causes curl error 97 (connection to proxy closed).
# curl matches a NO_PROXY entry against the hostname and all its subdomains.
NO_PROXY_DOMAINS = ",".join([
    "github.com",           # api.github.com, raw.githubusercontent.com, etc.
    "githubusercontent.com",
    "infisical.com",        # app.infisical.com
    "docker.io",            # registry-1.docker.io
    "docker.com",           # hub.docker.com, production.cloudflare.docker.com
    "alpinelinux.org",      # dl-cdn.alpinelinux.org
    "terraform.io",         # app.terraform.io, registry.terraform.io
    "hashicorp.com",
    "dagger.cloud",
    "ipify.org",            # api.ipify.org
])


class TailscaleProxy:
    """Wraps a Dagger Host Service for the Tailscale SOCKS5 proxy."""

    def __init__(self, client: dagger.Client) -> None:
        self._service = (
            client.host()
            .service(
                ports=[
                    dagger.PortForward(
                        backend=SOCKS5_PORT,
                        frontend=SOCKS5_PORT,
                        protocol=dagger.NetworkProtocol.TCP,
                    )
                ]
            )
        )

    def bind(self, container: dagger.Container) -> dagger.Container:
        """Bind the SOCKS5 proxy to a container.

        Adds:
          - Service binding at hostname 'tailscale-proxy'
          - ALL_PROXY env var for curl/general HTTP clients
          - SSH_PROXY_HOST and SSH_PROXY_PORT for SSH ProxyCommand
        """
        return (
            container
            .with_service_binding(SERVICE_NAME, self._service)
            .with_env_variable(
                "ALL_PROXY", f"socks5://{SERVICE_NAME}:{SOCKS5_PORT}"
            )
            .with_env_variable("NO_PROXY", NO_PROXY_DOMAINS)
            .with_env_variable("SSH_PROXY_HOST", SERVICE_NAME)
            .with_env_variable("SSH_PROXY_PORT", str(SOCKS5_PORT))
        )
