# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Is

`claudepod` is a tool that runs Claude Code inside a sandboxed Podman container with an egress firewall. It provides network-restricted, disposable environments for running Claude Code against local project directories.

## Key Files

- `claudepod` — Bash entrypoint script. Builds the container image (if needed), mounts the user's project at the same absolute path inside the container as on the host, optionally sets up the firewall, and launches Claude Code with `--dangerously-skip-permissions`.
- `Dockerfile` — Debian trixie-slim based image with dev tools, Claude Code (native installer), mise (runtime version manager), and Ralph. Runs as non-root user `dev` with UID/GID passed as build args (defaults to 1000).
- `init-firewall.sh` — iptables/ipset-based default-deny egress firewall. Allowlists specific domains (Anthropic API, GitHub, Bitbucket, npm, PyPI, Go proxy, crates.io, Hex.pm, documentation sites). DNS is locked to the container's configured resolver. SSH is restricted to GitHub and Bitbucket IPs only.
- `README.md` — User-facing documentation with features, usage, and firewall allowlist summary.
- `.gitignore` — Excludes editor swap files, OS files, and `.claude/` local state.

## Building and Running

```bash
# Run against current directory (builds image on first run)
./claudepod

# Force rebuild the image (clean, no layer cache)
./claudepod -b

# Run against a specific project
./claudepod ~/projects/myapp

# Non-interactive with a prompt
./claudepod -p "fix all lint errors"

# Skip firewall (faster start)
./claudepod -n

# Drop into a shell instead of launching Claude
./claudepod -s

# Resume a specific previous Claude session by its ID
./claudepod -r 01999c8a-b3f4-7c2d-9e8f-1a2b3c4d5e6f

# Pass extra args to claude
./claudepod -- --model opus
```

## Architecture Notes

- The container uses `podman run --userns=keep-id` to map the host user's UID/GID into the container, so file ownership in mounted project dirs is preserved. The Dockerfile accepts `USER_UID` and `USER_GID` as build args, set automatically by `claudepod` to match the host user.
- The project is mounted at its **real host absolute path** inside the container (e.g., `/home/jaime/projects/foo` on the host is `/home/jaime/projects/foo` in the container) and `--workdir` is set to that same path. This avoids translation issues with anything git records as an absolute path: git worktree pointers, submodules, and `core.worktree` resolve identically on both sides. The `/workspace` directory still exists in the image but is no longer the project mount target. Project paths under `/home/dev/` are refused at launch because they would collide with the container user's home volume.
- Host `~/.gitconfig` is mounted read-only. For SSH, the host's `SSH_AUTH_SOCK` is forwarded into the container along with read-only mounts of `~/.ssh/config`, `~/.ssh/known_hosts`, and public keys; private keys are never mounted — git relies entirely on the forwarded agent.
- A named volume `claudepod-home` persists the container user's home directory (Claude config, shell history, etc.) across sessions. The volume is automatically removed on image rebuild so it gets re-populated from the fresh image.
- Per-project Claude state (sessions, memory, plans, todos, checkpoints) lives in `<project>/.claudepod/` on the host. `claudepod` creates the dir on launch, appends `.claudepod/` to the project's `.gitignore` if one exists, and bind-mounts it onto Claude Code's per-cwd state path inside the container (`~/.claude/projects/<escaped-host-path>/`, where `/` becomes `-`). Claude is unaware of the redirection — it writes to its conventional location, but the bytes land in the project's own state dir. This gives memory isolation per host project for free, and persists session JSONL files so they're available to `-r/--resume <session-id>` on later runs. Resume is **not** automatic by default — running multiple claudepods concurrently in the same project would otherwise both latch onto the most recent session and stomp each other's appends. Pick the session ID explicitly to opt in.
- The firewall requires `NET_ADMIN` and `NET_RAW` capabilities and runs via a sudoers rule limited to the firewall script only.
- The firewall resolves domain allowlist entries to IPs at container start using `dig`, fetches GitHub's IP ranges from `api.github.com/meta`, and fetches Bitbucket's IP ranges from `ip-ranges.atlassian.com` for SSH restrictions.
- mise is pre-installed with Node.js 22 LTS and Python 3.13 globally. If the project directory contains a version file (`.tool-versions`, `mise.toml`, `.node-version`, etc.), runtimes are installed automatically at container start. Otherwise, Claude is given a system prompt hint about mise availability.
- Ralph (claudepod helper) is installed from `frankbria/ralph-claude-code` during the image build.
