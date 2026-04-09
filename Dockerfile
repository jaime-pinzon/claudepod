# syntax=docker/dockerfile:1
FROM debian:trixie-slim

ENV DEBIAN_FRONTEND=noninteractive

# ── System packages ──────────────────────────────────────────────────
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
        openssh-client \
        procps \
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

# ── Environment ─────────────────────────────────────────────────────
ENV DEVCONTAINER=true \
    SHELL=/bin/bash \
    PATH="/home/${USERNAME}/.local/bin:/home/${USERNAME}/.local/share/mise/shims:/home/${USERNAME}/.claude/bin:${PATH}"

WORKDIR /workspace
USER $USERNAME

# ── Claude Code ─────────────────────────────────────────────────────
RUN curl -fsSL https://claude.ai/install.sh | bash

# ── Mise (runtime manager) + runtimes ───────────────────────────────
RUN curl -fsSL https://mise.run | bash \
    && mkdir -p /home/"$USERNAME"/.config/mise \
    && cat > /home/"$USERNAME"/.config/mise/config.toml <<'TOML'
[settings]
auto_install = true
idiomatic_version_file = true
TOML
RUN echo 'eval "$(mise activate bash)"' >> /home/"$USERNAME"/.bashrc \
    && mise use -g node@22.15.0 python@3.13.3

# ── Ralph ───────────────────────────────────────────────────────────
RUN git clone --depth 1 https://github.com/frankbria/ralph-claude-code.git /tmp/ralph \
    && cd /tmp/ralph && bash install.sh \
    && rm -rf /tmp/ralph

CMD ["bash"]
