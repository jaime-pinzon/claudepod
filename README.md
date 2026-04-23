# claudepod

Run [Claude Code](https://claude.ai/code) inside a sandboxed Podman container with an egress firewall. Gives you a disposable, network-restricted environment where Claude can edit your code without unrestricted internet access.

## Features

- **Default-deny egress firewall** — only allowlisted domains (Anthropic API, GitHub, npm, PyPI, docs sites, etc.) can be reached
- **SSH restricted to GitHub/Bitbucket IPs only** — blocks SSH exfiltration to arbitrary hosts
- **DNS pinned to container resolver** — prevents DNS tunneling
- **File ownership preserved** — uses `podman --userns=keep-id` so mounted files keep your host UID/GID
- **Persistent home directory** — Claude config, shell history, and installed tools survive across sessions
- **Runtime version management** — [mise](https://mise.jdx.dev/) is pre-installed; detects `.tool-versions`, `mise.toml`, etc. and installs runtimes automatically

## Requirements

- [Podman](https://podman.io/) (rootless)
- A Claude Code API key (set `ANTHROPIC_API_KEY` or run `claude login` inside the container)

## Quick start

```bash
# Clone and run against the current directory
git clone https://github.com/youruser/claudepod.git
cd claudepod
./claudepod ~/projects/myapp
```

The container image builds automatically on first run.

## Usage

```
claudepod [options] [project-dir] [-- claude-args...]
```

| Option | Description |
|---|---|
| `-b`, `--build` | Force rebuild the container image (clean, no layer cache) |
| `-n`, `--no-firewall` | Skip firewall setup (faster start, less secure) |
| `-p`, `--prompt TEXT` | Run non-interactively with a prompt |
| `-s`, `--shell` | Drop into a bash shell instead of launching Claude |
| `-h`, `--help` | Show help |

### Examples

```bash
# Interactive session against current directory
./claudepod

# Specific project directory
./claudepod ~/projects/myapp

# Non-interactive task
./claudepod -p "fix all lint errors"

# Skip the firewall for faster startup
./claudepod -n

# Pass extra arguments to Claude Code
./claudepod -- --model opus

# Debug: drop into a shell inside the container
./claudepod -s
```

## How it works

1. **Builds** a Debian trixie-slim container with dev tools, Claude Code, and mise
2. **Mounts** your project directory into `/workspace` (read-write)
3. **Forwards** your SSH agent socket and mounts `~/.gitconfig` plus your SSH config / known_hosts / public keys read-only for git operations (private keys are never mounted)
4. **Starts the firewall** (unless `-n`): resolves allowlisted domains to IPs, sets iptables default-deny, and restricts DNS and SSH
5. **Launches Claude Code** with `--dangerously-skip-permissions` (safe because the container *is* the sandbox)

> **Security note:** Claude Code runs with `--dangerously-skip-permissions` and has SSH access via your forwarded SSH agent. This means Claude can push to any repository your loaded SSH keys have access to. If this is a concern, remove keys from your agent or use a separate agent with a limited key set.

## Firewall allowlist

The firewall permits HTTPS traffic to:

- **Anthropic** — `api.anthropic.com`, `claude.ai`, Sentry, StatsIG
- **Git hosts** — GitHub, Bitbucket (HTTPS + SSH)
- **Package registries** — npm, PyPI, crates.io, Go module proxy, Hex.pm
- **Documentation sites** — MDN, Stack Overflow, language/framework docs, Anthropic docs

All other outbound traffic is dropped. See [`init-firewall.sh`](init-firewall.sh) for the full list.

## License

MIT
