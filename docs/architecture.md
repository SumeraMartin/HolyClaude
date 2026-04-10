# Architecture

Technical deep-dive into how HolyClaude works.

---

## Overview

HolyClaude is a single Docker container running multiple supervised services. The architecture is designed for reliability, persistence, and zero-configuration startup.

```
┌─────────────────────────────────────────────────┐
│                Docker Container                  │
│                                                  │
│  entrypoint.sh (runs once)                       │
│    ├── UID/GID remapping                         │
│    ├── Pre-create required files                 │
│    ├── bootstrap.sh (first boot only)            │
│    │     ├── Copy settings.json                  │
│    │     ├── Copy CLAUDE.md (memory)             │
│    │     ├── Configure git                       │
│    │     └── Create sentinel file                │
│    └── exec /init (s6-overlay)                   │
│                                                  │
│  s6-overlay (PID 1)                              │
│    ├── cloudcli (longrun)                        │
│    │     └── claude-code-ui --port 3001          │
│    └── xvfb (longrun)                            │
│          └── Xvfb :99 -screen 0 1920x1080x24    │
│                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────────┐   │
│  │ Claude   │  │ Chromium │  │ Dev Tools    │   │
│  │ Code CLI │  │ headless │  │ Node, Python │   │
│  └──────────┘  └──────────┘  └──────────────┘   │
│                                                  │
│  Bind Mounts:                                    │
│    ~/.claude ←→ ./data/claude (host)             │
│    /workspace ←→ ./workspace (host)              │
└─────────────────────────────────────────────────┘
```

---

## Component Details

### Entrypoint (`entrypoint.sh`)

Runs every time the container starts. Responsibilities:

1. **UID/GID remapping** — Adjusts the `claude` user's UID/GID to match `PUID`/`PGID` environment variables. This prevents permission mismatches between container and host files.

2. **Workspace ownership fix** — Repairs the top-level `/workspace` bind mount if Docker auto-created it as `root:root` on first start.

3. **File pre-creation** — Ensures `~/.claude.json` exists as a file (not a directory). Docker creates bind-mount targets as directories if they don't exist, which breaks Claude Code.

4. **Bootstrap trigger** — Checks for sentinel file `.holyclaude-bootstrapped`. If absent, runs `bootstrap.sh`.

5. **Handoff** — `exec /init` replaces the entrypoint process with s6-overlay, which becomes PID 1.

### Bootstrap (`bootstrap.sh`)

Runs once on first container start. Creates the sentinel file so it doesn't re-run. Responsibilities:

1. **Settings** — Copies `settings.json` from the image to `~/.claude/settings.json`
2. **Memory** — Copies the variant-appropriate memory template (`claude-memory-full.md` or `claude-memory-slim.md`) to `~/.claude/CLAUDE.md`
3. **Git** — Configures git identity from `GIT_USER_NAME`/`GIT_USER_EMAIL` env vars
4. **Onboarding** — Creates `~/.claude.json` with `hasCompletedOnboarding: true` to skip the first-run wizard
5. **Permissions** — Fixes file ownership to match `PUID`/`PGID`

### s6-overlay

[s6-overlay](https://github.com/just-containers/s6-overlay) is a process supervisor designed for Docker containers. It's used instead of supervisord or systemd because:

- **Proper PID 1 behavior** — Handles signal forwarding and zombie reaping
- **Service supervision** — Restarts crashed services automatically
- **Clean shutdown** — Graceful stop signals to all services
- **Small footprint** — Minimal overhead

#### Important: Clean environment

s6's `s6-setuidgid` runs services with a clean environment. Docker-compose environment variables are **not** automatically available to s6 services. Each service's `run` script must explicitly set needed variables in the `env` command. This is a security feature, not a bug.

### CloudCLI Service

```sh
#!/bin/sh
cd /workspace
exec s6-setuidgid claude env HOME=/home/claude NODE_OPTIONS=--no-deprecation WORKSPACES_ROOT=/workspace claude-code-ui --port 3001
```

- Runs as user `claude` (not root)
- Sets `WORKSPACES_ROOT` directly (can't rely on docker-compose env vars due to s6 clean environment)
- `NODE_OPTIONS=--no-deprecation` suppresses noisy deprecation warnings
- Managed as a `longrun` service — auto-restarts on crash

### Xvfb Service

```sh
#!/bin/sh
exec Xvfb :99 -screen 0 1920x1080x24 -nolisten tcp
```

- Provides a virtual display at `:99` (1920x1080, 24-bit color)
- Required for Chromium, Playwright, Lighthouse — they need a display even in headless mode
- `-nolisten tcp` prevents remote X connections (security)

---

## Design Decisions

### Why s6-overlay instead of supervisord?

s6-overlay is purpose-built for Docker. supervisord is a full process manager designed for bare-metal servers — it's heavier, requires XML configuration, and doesn't handle PID 1 responsibilities (signal forwarding, zombie reaping) out of the box.

### Why sentinel-based bootstrap instead of always running?

Bootstrap copies default settings and memory. Running it every time would overwrite user customizations. The sentinel pattern means:
- First boot: fresh defaults installed
- Subsequent boots: user's customizations preserved
- Manual re-trigger: delete sentinel file

### Why plugins baked into the image?

CloudCLI plugins require `git clone` + `npm install` + `npm run build`. Running this at container start (in bootstrap) is unreliable because:
- Bind mounts may be on network storage with permission issues
- Network may be unavailable at boot
- Adds 30+ seconds to every first boot

Baking them into the Dockerfile ensures a clean, controlled build environment.

### Why `runuser` instead of `su`?

`su` uses PAM authentication, which can fail with renamed users (the base image's `node` user renamed to `claude`). `runuser` skips PAM entirely — it's designed for scripts that need to run commands as another user.

### Why no `.env` file by default?

Every configuration option has a sensible default. Most users authenticate through the CloudCLI web UI, not environment variables. Requiring a `.env` file adds a setup step that most users don't need. Power users can use `docker-compose.full.yaml` which has all options documented inline.

### Why bind mounts instead of named volumes?

Bind mounts let users see and manage their data on disk. Named volumes hide data in Docker's internal storage, making backup and inspection harder. For a development workstation where users want to access their code and config files directly, bind mounts are the right choice.

---

## Image Variants

The `VARIANT` build arg controls which packages are installed:

```dockerfile
ARG VARIANT=full
```

The variant is stored at build time in `/etc/holyclaude-variant`. Bootstrap reads this file to copy the correct memory template.

| Variant | npm packages | pip packages | apt packages |
|---------|-------------|-------------|-------------|
| `full` | All | All | All |
| `slim` | Core only | Core only | No pandoc/ffmpeg/libvips |
| `android` | Core only | Core only | Slim base **+** JDK 17 + Android SDK + emulator + scrcpy |

See [What's Inside](../README.md#rocket-whats-inside) for the complete package lists.

### Android variant

Layered on the **slim** base (not full), the android variant adds JDK 17, the Android SDK + cmdline-tools, platform-tools, build-tools 34.0.5, the android-34 google_apis system image (arch-correct via `TARGETARCH`), the Android emulator, scrcpy, and a pre-baked `phone34` AVD. Compressed image size is roughly the slim base plus ~5 GB per arch — comfortably under the 12 GB Docker Hub soft ceiling.

Key design points:

- **Slim, not full, as the base.** Stacking Android on top of full would push the compressed image past 10 GB and punish Docker Hub pull times. Web/backend users on the full image do not pay the Android tax.
- **No new s6 service for the emulator.** The emulator boot tax (60-120 s, 1.5 GB idle RAM) only matters when the agent is actually doing Android work. The `holyclaude-android-up` wrapper boots it on demand.
- **`/dev/kvm` passthrough on Linux, software fallback on Mac.** The entrypoint detects `/dev/kvm` at runtime, writes a marker file at `/run/holyclaude/kvm`, and adds the `claude` user to a group matching the host's KVM device GID (which varies by distro). Apple Silicon Mac is **experimental / known-slow** — TCG arm64 boot can take 10+ minutes or hang outright.
- **Pre-baked AVD seed at `/opt/android-sdk-avd-seed/`.** On first boot, `entrypoint.sh` copies the seed into `~/.claude/.android/avd/` (which is symlinked from `~/.android` matching the Codex/Gemini/Cursor pattern) and rewrites the absolute paths in `phone34.ini`. The user's installed APKs and emulator state then persist across `compose down` via the existing `./data/claude` bind mount.
- **Headless mp4 recording via scrcpy** (with `adb shell screenrecord` fallback for system images that lack hardware MediaCodec). No noVNC, no X forwarding, no extra ports.
- **Threat model widens.** `--device /dev/kvm` + the existing `NOPASSWD sudo` + `seccomp=unconfined` materially widens the host-adjacent privilege boundary. Document explicitly: do not expose the android variant to untrusted input.

---

## Multi-Architecture Support

The Dockerfile uses Docker's `TARGETARCH` build arg to download the correct s6-overlay binary:

```dockerfile
RUN S6_ARCH=$(case "$TARGETARCH" in arm64) echo "aarch64";; *) echo "x86_64";; esac)
```

Supported architectures:
- `amd64` (x86_64) — Intel/AMD servers, most VPS providers
- `arm64` (aarch64) — Apple Silicon, AWS Graviton, Raspberry Pi 4+

Build for a specific platform:
```bash
docker buildx build --platform linux/arm64 -t holyclaude .
```
