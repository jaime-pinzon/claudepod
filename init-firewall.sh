#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Claude Code Container Firewall
# Adapted from Anthropic's official .devcontainer/init-firewall.sh
# Default-deny egress with allowlist for essential services.
#
# Security notes:
#   - DNS is restricted to the container's configured resolver only,
#     blocking DNS tunneling to arbitrary servers.
#   - SSH (port 22) is restricted to resolved GitHub and Bitbucket IPs only,
#     blocking SSH exfiltration to attacker-controlled hosts.
#   - IPv6 egress is default-deny in its entirety; the allowlist resolves
#     only A records, so there would be no matching v6 allow rules anyway.
#   - IP-based rules may go stale if DNS records rotate during long
#     sessions. Restart the container to refresh.
# =============================================================================

echo "[firewall] Initializing network restrictions..."

# Preserve Podman/Docker internal DNS rules before flushing
CONTAINER_DNS_RULES=$(iptables-save | grep -E "^-A OUTPUT.*172\.17\.0\.|^-A OUTPUT.*127\.0\.0\.11" || true)

# Flush existing rules
iptables -F OUTPUT
iptables -F INPUT
iptables -F FORWARD

# Create ipset for allowed IPs (hash:net supports both IPs and CIDRs)
ipset create allowed-domains hash:net -exist
ipset flush allowed-domains

# Create separate ipset for SSH-allowed IPs (GitHub only)
ipset create ssh-allowed hash:net -exist
ipset flush ssh-allowed

# ---- Allowed domains ----
# Anthropic (API + OAuth login via `claude login`)
ALLOWED_DOMAINS=(
  "api.anthropic.com"
  "claude.ai"
  "sentry.io"
  "statsig.anthropic.com"
  "o4509685579005952.ingest.us.sentry.io"
)

# AI APIs
ALLOWED_DOMAINS+=(
  "api.elevenlabs.io"
  "api.deepgram.com"
  "generativelanguage.googleapis.com"
)

# GitHub (for git operations over HTTPS + WebFetch reading repos/docs)
ALLOWED_DOMAINS+=(
  "github.com"
  "api.github.com"
  "raw.githubusercontent.com"
  "gist.github.com"
)

# Bitbucket (for git operations over HTTPS)
ALLOWED_DOMAINS+=(
  "bitbucket.org"
  "api.bitbucket.org"
)

# ----- Package registries (by language ecosystem) -----

# JavaScript / TypeScript (npm)
ALLOWED_DOMAINS+=(
  "registry.npmjs.org"
)

# Python (PyPI)
ALLOWED_DOMAINS+=(
  "pypi.org"
  "files.pythonhosted.org"
)

# Rust (crates.io)
ALLOWED_DOMAINS+=(
  "crates.io"
  "static.crates.io"
  "index.crates.io"
)

# Go (module proxy)
ALLOWED_DOMAINS+=(
  "proxy.golang.org"
  "sum.golang.org"
  "storage.googleapis.com"
)

# Elixir (Hex.pm)
ALLOWED_DOMAINS+=(
  "hex.pm"
  "repo.hex.pm"
  "builds.hex.pm"
)

# General (multi-language tools, CDNs used by installers)
ALLOWED_DOMAINS+=(
  "objects.githubusercontent.com"
  "dl.google.com"
  "mise.jdx.dev"
)

# ----- WebFetch: documentation and reference sites -----
# These allow Claude Code to read full pages when it finds them via WebSearch.
# WebSearch works without these (it's server-side), but WebFetch needs direct access.

# Anthropic docs
ALLOWED_DOMAINS+=(
  "docs.anthropic.com"
  "docs.claude.com"
  "code.claude.com"
  "platform.claude.com"
  "support.anthropic.com"
)

# Language and framework docs
ALLOWED_DOMAINS+=(
  "docs.python.org"
  "nodejs.org"
  "developer.mozilla.org"
  "www.typescriptlang.org"
  "doc.rust-lang.org"
  "go.dev"
  "pkg.go.dev"
  "learn.microsoft.com"
  "en.cppreference.com"
)

# Web framework docs
ALLOWED_DOMAINS+=(
  "react.dev"
  "vuejs.org"
  "angular.io"
  "nextjs.org"
  "svelte.dev"
  "kit.svelte.dev"
  "tailwindcss.com"
  "expressjs.com"
  "fastapi.tiangolo.com"
  "flask.palletsprojects.com"
  "docs.djangoproject.com"
)

# AI/ML ecosystem docs (your stack)
ALLOWED_DOMAINS+=(
  "python.langchain.com"
  "langchain-ai.github.io"
  "js.langchain.com"
  "docs.smith.langchain.com"
  "qdrant.tech"
  "docs.qdrant.tech"
  "modelcontextprotocol.io"
)

# Cloud and infrastructure docs
ALLOWED_DOMAINS+=(
  "docs.docker.com"
  "docs.podman.io"
  "kubernetes.io"
  "docs.aws.amazon.com"
  "cloud.google.com"
  "docs.oracle.com"
)

# Developer reference and Q&A
ALLOWED_DOMAINS+=(
  "stackoverflow.com"
  "stackexchange.com"
  "en.wikipedia.org"
  "man7.org"
)

# Resolve and add all allowed domains
for domain in "${ALLOWED_DOMAINS[@]}"; do
  ips=$(dig +short "$domain" A 2>/dev/null | grep -E '^[0-9]+\.' || true)
  # shellcheck disable=SC2086 # intentional word-split: ips is whitespace-separated
  for ip in $ips; do
    ipset add allowed-domains "$ip" -exist
  done
done

# Resolve GitHub meta IPs (covers all GitHub services)
# These are also the only IPs allowed for SSH (git@github.com)
GITHUB_META=$(curl -fsSL https://api.github.com/meta 2>/dev/null || true)
if [ -n "$GITHUB_META" ]; then
  # shellcheck disable=SC2046 # intentional word-split: jq prints CIDRs one per line
  for cidr in $(echo "$GITHUB_META" | jq -r '(.git // [])[] , (.web // [])[] , (.api // [])[]' 2>/dev/null | grep -v ':' || true); do
    ipset add allowed-domains "$cidr" -exist 2>/dev/null || true
    ipset add ssh-allowed "$cidr" -exist 2>/dev/null || true
  done
fi

# Resolve Bitbucket Cloud IPs (for git operations over HTTPS + SSH)
BITBUCKET_META=$(curl -fsSL https://ip-ranges.atlassian.com/ 2>/dev/null || true)
if [ -n "$BITBUCKET_META" ]; then
  # shellcheck disable=SC2046 # intentional word-split: jq prints CIDRs one per line
  for cidr in $(echo "$BITBUCKET_META" | jq -r '.items[] | select(.product == "bitbucket") | .cidr' 2>/dev/null | grep -v ':' || true); do
    ipset add allowed-domains "$cidr" -exist 2>/dev/null || true
    ipset add ssh-allowed "$cidr" -exist 2>/dev/null || true
  done
fi

# ---- Identify container DNS resolver ----
# Only allow DNS to the resolver the container is configured to use,
# not to arbitrary DNS servers (prevents DNS tunneling exfiltration).
CONTAINER_DNS=$(grep -m1 'nameserver' /etc/resolv.conf | awk '{print $2}' || echo "")

# ---- iptables rules ----

# Allow loopback
iptables -A OUTPUT -o lo -j ACCEPT
iptables -A INPUT -i lo -j ACCEPT

# Allow established connections
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT

# Allow DNS only to the container's configured resolver
if [ -n "$CONTAINER_DNS" ]; then
  iptables -A OUTPUT -p udp -d "$CONTAINER_DNS" --dport 53 -j ACCEPT
  iptables -A OUTPUT -p tcp -d "$CONTAINER_DNS" --dport 53 -j ACCEPT
  echo "[firewall] DNS restricted to resolver: $CONTAINER_DNS"
else
  # Fallback: allow DNS to common resolvers only
  for dns in 127.0.0.11 8.8.8.8 8.8.4.4 1.1.1.1; do
    iptables -A OUTPUT -p udp -d "$dns" --dport 53 -j ACCEPT
    iptables -A OUTPUT -p tcp -d "$dns" --dport 53 -j ACCEPT
  done
  echo "[firewall] WARNING: Could not detect container DNS, using fallback resolvers"
fi

# Allow SSH only to GitHub IPs (not to arbitrary hosts)
iptables -A OUTPUT -p tcp --dport 22 -m set --match-set ssh-allowed dst -j ACCEPT

# Allow HTTPS/HTTP connections to allowlisted IPs (ports 80 and 443 only)
iptables -A OUTPUT -p tcp -m multiport --dports 80,443 -m set --match-set allowed-domains dst -j ACCEPT

# Restore any Podman/Docker internal DNS rules
if [ -n "$CONTAINER_DNS_RULES" ]; then
  echo "$CONTAINER_DNS_RULES" | while IFS= read -r rule; do
    # shellcheck disable=SC2086 # rule is an iptables argv string that must word-split
    iptables $rule 2>/dev/null || true
  done
fi

# Default deny everything else
iptables -P OUTPUT DROP
iptables -P INPUT DROP
iptables -P FORWARD DROP

# ---- IPv6: default-deny the whole address family ----
# The allowlist above is resolved via A records only, so IPv6 has no
# matching allow rules. If the container's network has v6 connectivity,
# unrestricted v6 egress would silently bypass the v4 allowlist. Apply the
# same default-deny policy over ip6tables, leaving only loopback and
# established connections open. Each command is guarded with `|| true` so
# missing kernel support or ip6tables doesn't trip `set -e`.
if command -v ip6tables >/dev/null 2>&1; then
  ip6tables -F OUTPUT 2>/dev/null || true
  ip6tables -F INPUT 2>/dev/null || true
  ip6tables -F FORWARD 2>/dev/null || true
  ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -i lo -j ACCEPT 2>/dev/null || true
  ip6tables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT 2>/dev/null || true
  ip6tables -P OUTPUT DROP 2>/dev/null || true
  ip6tables -P INPUT DROP 2>/dev/null || true
  ip6tables -P FORWARD DROP 2>/dev/null || true
  echo "[firewall] IPv6 egress: default-deny (allowlist is IPv4-only)."
else
  echo "[firewall] WARNING: ip6tables unavailable — IPv6 egress is NOT restricted." >&2
fi

echo "[firewall] Network restrictions active."
echo "[firewall] SSH restricted to GitHub and Bitbucket IPs only."
echo "[firewall] All other outbound traffic is BLOCKED."
