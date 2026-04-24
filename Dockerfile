# syntax=docker/dockerfile:1
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ── Version pins (override with --build-arg) ────────────────────────
# Claude Code: "stable" | "latest" | "X.Y.Z" (parsed by claude.ai/install.sh)
ARG CLAUDE_CODE_VERSION=stable
# mise: must be a "v…"-prefixed release tag on jdx/mise
ARG MISE_VERSION=v2026.4.19
# Ralph: a git ref (branch, tag, or commit SHA) on frankbria/ralph-claude-code
ARG RALPH_REF=main

# ── System packages ──────────────────────────────────────────────────
# DL3008: apt version pinning across 17+ packages on Debian stable isn't
# workable — the suite moves and `apt-get update` refetches on every rebuild.
# hadolint ignore=DL3008
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        curl \
        dnsutils \
        fd-find \
        gh \
        git \
        gpg \
        gpg-agent \
        iproute2 \
        iptables \
        ipset \
        jq \
        neovim \
        openssh-client \
        procps \
        python3 \
        ripgrep \
        sudo \
        tmux \
    && apt-get clean \
    && rm -rf /var/lib/apt/lists/*

# ── Non-root user ───────────────────────────────────────────────────
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

RUN groupadd --gid "$USER_GID" "$USERNAME" \
    && useradd --uid "$USER_UID" --gid "$USER_GID" -m -s /bin/bash "$USERNAME" \
    && mkdir -p /workspace /home/"$USERNAME"/.claude \
    && chown -R "$USERNAME":"$USERNAME" /workspace /home/"$USERNAME"/.claude

# ── Firewall script (needs root — do this before switching user) ────
COPY --chmod=755 init-firewall.sh /usr/local/bin/init-firewall.sh
RUN printf '%s ALL=(root) NOPASSWD: /usr/local/bin/init-firewall.sh\n' "$USERNAME" \
        > /etc/sudoers.d/"$USERNAME"-firewall \
    && chmod 0440 /etc/sudoers.d/"$USERNAME"-firewall

# ── Ctrl+Z filter (PTY proxy that drops 0x1A from stdin) ────────────
COPY --chmod=755 nosusp.py /usr/local/bin/nosusp

# ── Environment ─────────────────────────────────────────────────────
ENV DEVCONTAINER=true \
    SHELL=/bin/bash \
    EDITOR=nvim \
    VISUAL=nvim \
    PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.claude/bin:${PATH}"

WORKDIR /workspace
USER $USERNAME

# Propagate pipe failures through `curl | bash` installers below so a failed
# curl doesn't silently leave a half-installed binary behind (fixes DL4006).
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ── Claude Code ─────────────────────────────────────────────────────
# install.sh accepts `stable`, `latest`, or an explicit X.Y.Z as $1.
RUN curl -fsSL https://claude.ai/install.sh | bash -s -- "$CLAUDE_CODE_VERSION"

# ── Mise (runtime manager) + runtimes ───────────────────────────────
# mise.run honours MISE_VERSION (must be "v…"-prefixed).
RUN MISE_VERSION="$MISE_VERSION" curl -fsSL https://mise.run | bash \
    && mkdir -p /home/"$USERNAME"/.config/mise \
    && printf '[settings]\nauto_install = true\nidiomatic_version_file = true\n' \
        > /home/"$USERNAME"/.config/mise/config.toml
# SC2016: the single quotes are intentional — we want the literal
# `eval "$(mise activate bash)"` written to .bashrc, evaluated at shell
# startup, not expanded now during image build.
# hadolint ignore=SC2016
RUN echo 'eval "$(mise activate bash)"' >> /home/"$USERNAME"/.bashrc \
    && mise use -g node@22.15.0 python@3.13.3

# ── Ralph ───────────────────────────────────────────────────────────
# Pin to a git ref so upstream main moving doesn't silently change the build.
# DL3003: using WORKDIR here would split this into four layers and leak the
# scratch directory into later instructions. `cd` inside one RUN is cleaner.
# hadolint ignore=DL3003
RUN git clone https://github.com/frankbria/ralph-claude-code.git /tmp/ralph \
    && cd /tmp/ralph && git checkout "$RALPH_REF" && bash install.sh \
    && rm -rf /tmp/ralph

CMD ["bash"]
