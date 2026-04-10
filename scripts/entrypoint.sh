#!/bin/bash
set -e

# ==============================================================================
# HolyClaude — Container Entrypoint
# Handles: UID/GID remapping, first-boot bootstrap, s6-overlay handoff
# ==============================================================================

CLAUDE_USER="claude"
CLAUDE_HOME="/home/claude"
WORKSPACE_DIR="/workspace"

# ---------- UID/GID remapping ----------
PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CURRENT_UID=$(id -u "$CLAUDE_USER")
CURRENT_GID=$(id -g "$CLAUDE_USER")

if [ "$PGID" != "$CURRENT_GID" ]; then
    echo "[entrypoint] Changing claude GID from $CURRENT_GID to $PGID"
    groupmod -o -g "$PGID" claude
fi

if [ "$PUID" != "$CURRENT_UID" ]; then
    echo "[entrypoint] Changing claude UID from $CURRENT_UID to $PUID"
    usermod -o -u "$PUID" claude
fi

# ---------- Fix home directory ownership ----------
chown "$PUID:$PGID" "$CLAUDE_HOME"
chown "$PUID:$PGID" "$CLAUDE_HOME/.claude" 2>/dev/null || true

# ---------- Ensure /workspace is writable ----------
# Docker creates missing bind-mount directories as root on the host.
# Fix the top-level workspace ownership here so the mapped claude user can write.
mkdir -p "$WORKSPACE_DIR"
if ! runuser -u "$CLAUDE_USER" -- test -w "$WORKSPACE_DIR"; then
    echo "[entrypoint] /workspace is not writable for $CLAUDE_USER — attempting ownership fix"
    chown "$PUID:$PGID" "$WORKSPACE_DIR" 2>/dev/null || true
fi

if ! runuser -u "$CLAUDE_USER" -- test -w "$WORKSPACE_DIR"; then
    echo "[entrypoint] WARNING: /workspace is still not writable; fix host ownership or PUID/PGID"
fi

# ---------- Codex CLI config symlink (every boot) ----------
mkdir -p "$CLAUDE_HOME/.claude/.codex"
chown "$PUID:$PGID" "$CLAUDE_HOME/.claude/.codex"
[ -L "$CLAUDE_HOME/.codex" ] && [ ! -e "$CLAUDE_HOME/.codex" ] && rm -f "$CLAUDE_HOME/.codex"
if [ ! -e "$CLAUDE_HOME/.codex" ]; then
    ln -s "$CLAUDE_HOME/.claude/.codex" "$CLAUDE_HOME/.codex"
    chown -h "$PUID:$PGID" "$CLAUDE_HOME/.codex"
fi

# ---------- Gemini CLI config symlink (every boot) ----------
mkdir -p "$CLAUDE_HOME/.claude/.gemini"
chown "$PUID:$PGID" "$CLAUDE_HOME/.claude/.gemini"
[ -L "$CLAUDE_HOME/.gemini" ] && [ ! -e "$CLAUDE_HOME/.gemini" ] && rm -f "$CLAUDE_HOME/.gemini"
if [ ! -e "$CLAUDE_HOME/.gemini" ]; then
    ln -s "$CLAUDE_HOME/.claude/.gemini" "$CLAUDE_HOME/.gemini"
    chown -h "$PUID:$PGID" "$CLAUDE_HOME/.gemini"
fi

# ---------- Cursor CLI config symlink (every boot) ----------
mkdir -p "$CLAUDE_HOME/.claude/.cursor"
chown "$PUID:$PGID" "$CLAUDE_HOME/.claude/.cursor"
[ -L "$CLAUDE_HOME/.cursor" ] && [ ! -e "$CLAUDE_HOME/.cursor" ] && rm -f "$CLAUDE_HOME/.cursor"
if [ ! -e "$CLAUDE_HOME/.cursor" ]; then
    ln -s "$CLAUDE_HOME/.claude/.cursor" "$CLAUDE_HOME/.cursor"
    chown -h "$PUID:$PGID" "$CLAUDE_HOME/.cursor"
fi

# ---------- Android SDK config symlink + AVD seed (every boot) ----------
# Mirrors the Codex/Gemini/Cursor pattern above so the AVD and any
# installed-app state persist across `compose down` via the existing
# ./data/claude bind mount instead of a dedicated bind mount.
# Slim/full variants have no /opt/android-sdk-avd-seed so the seed copy
# is a no-op there — the symlink still gets created (harmless).
mkdir -p "$CLAUDE_HOME/.claude/.android"
chown "$PUID:$PGID" "$CLAUDE_HOME/.claude/.android"
[ -L "$CLAUDE_HOME/.android" ] && [ ! -e "$CLAUDE_HOME/.android" ] && rm -f "$CLAUDE_HOME/.android"
if [ ! -e "$CLAUDE_HOME/.android" ]; then
    ln -s "$CLAUDE_HOME/.claude/.android" "$CLAUDE_HOME/.android"
    chown -h "$PUID:$PGID" "$CLAUDE_HOME/.android"
fi

# Seed the baked phone34 AVD into the bind-mounted home if the user does
# not already have one. Image upgrades pick up a refreshed seed only when
# the user has no AVD by that name — we never overwrite user state.
if [ -d /opt/android-sdk-avd-seed/phone34.avd ] && \
   [ ! -d "$CLAUDE_HOME/.claude/.android/avd/phone34.avd" ]; then
    echo "[entrypoint] Seeding baked phone34 AVD into ~/.claude/.android/avd/"
    mkdir -p "$CLAUDE_HOME/.claude/.android/avd"
    cp -a /opt/android-sdk-avd-seed/phone34.avd "$CLAUDE_HOME/.claude/.android/avd/phone34.avd"
    if [ -f /opt/android-sdk-avd-seed/phone34.ini ]; then
        cp -a /opt/android-sdk-avd-seed/phone34.ini "$CLAUDE_HOME/.claude/.android/avd/phone34.ini"
    fi
    # avdmanager bakes the absolute seed path into phone34.ini ("path=...")
    # and may reference it from the AVD's config.ini — rewrite both so the
    # emulator can find the AVD at its new home. The hardware-qemu.ini is
    # regenerated on first boot, so it does not need rewriting.
    sed -i "s|/opt/android-sdk-avd-seed|$CLAUDE_HOME/.claude/.android/avd|g" \
        "$CLAUDE_HOME/.claude/.android/avd/phone34.ini" 2>/dev/null || true
    sed -i "s|/opt/android-sdk-avd-seed|$CLAUDE_HOME/.claude/.android/avd|g" \
        "$CLAUDE_HOME/.claude/.android/avd/phone34.avd/config.ini" 2>/dev/null || true
    chown -R "$PUID:$PGID" "$CLAUDE_HOME/.claude/.android"
fi

# ---------- Persist ~/.claude.json (every boot) ----------
# Claude Code overwrites symlinks, so we use copy-on-boot/copy-on-start.
# On restart (file exists): save current to bind mount, then use it
# On recreation (file gone): restore from bind mount
# On first boot (neither exists): create default
if [ -f "$CLAUDE_HOME/.claude.json" ]; then
    cp "$CLAUDE_HOME/.claude.json" "$CLAUDE_HOME/.claude/.claude.json.persist"
elif [ -f "$CLAUDE_HOME/.claude/.claude.json.persist" ]; then
    cp "$CLAUDE_HOME/.claude/.claude.json.persist" "$CLAUDE_HOME/.claude.json"
    chown "$PUID:$PGID" "$CLAUDE_HOME/.claude.json"
else
    echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "$CLAUDE_HOME/.claude.json"
    chown "$PUID:$PGID" "$CLAUDE_HOME/.claude.json"
fi

# ---------- Ensure DISPLAY is set ----------
export DISPLAY=:99

# ---------- KVM detect + device GID fixup (informational, all variants) ----------
# Marker file at /run/holyclaude/kvm: agent reads it via `cat`. We use a
# file rather than an env var because s6-overlay v3 services run with a
# minimal env unless they prepend with-contenv, and the CloudCLI PTY (which
# is what hosts the agent shell) is one of those services. The marker file
# lives in tmpfs and survives the s6 environment strip.
mkdir -p /run/holyclaude
if [ -c /dev/kvm ]; then
    KVM_GID=$(stat -c '%g' /dev/kvm)
    # The host's kvm group GID varies by distro (Arch=78, Ubuntu=108,
    # Debian=104) so a Dockerfile-baked GID would not work. We create a
    # matching group at runtime and add claude to it.
    if ! getent group "$KVM_GID" >/dev/null 2>&1; then
        groupadd -g "$KVM_GID" hostkvm 2>/dev/null || true
    fi
    usermod -aG "$KVM_GID" claude 2>/dev/null || true
    echo 1 > /run/holyclaude/kvm
    echo "[entrypoint] /dev/kvm detected (host GID $KVM_GID) — Android emulator will use KVM acceleration"
else
    echo 0 > /run/holyclaude/kvm
    echo "[entrypoint] /dev/kvm NOT detected — Android emulator will run in software mode (slow on Mac, hangs on Apple Silicon)"
fi

# Cross-arch trap detection: warn when host CPU disagrees with the image's
# baked system-image arch. Most common cause is `--platform linux/amd64`
# forced on Apple Silicon, which produces an x86_64 image running under
# Rosetta + TCG and the emulator hangs forever on first boot.
if [ -f /etc/holyclaude-variant ] && [ "$(cat /etc/holyclaude-variant)" = "android" ]; then
    HOST_ARCH=$(uname -m)
    EXPECTED="x86_64"
    [ -f /etc/holyclaude-img-arch ] && EXPECTED=$(cat /etc/holyclaude-img-arch)
    case "$EXPECTED:$HOST_ARCH" in
        x86_64:x86_64|arm64-v8a:aarch64|arm64-v8a:arm64) ;;
        *)
            echo "[entrypoint] WARNING: image is built for $EXPECTED but host CPU is $HOST_ARCH."
            echo "[entrypoint] WARNING: this usually means --platform was forced. The emulator will likely hang."
            ;;
    esac
fi

# ---------- First-boot bootstrap ----------
SENTINEL="$CLAUDE_HOME/.claude/.holyclaude-bootstrapped"
if [ ! -f "$SENTINEL" ]; then
    echo "[entrypoint] First boot detected — running bootstrap.sh"
    if ! /usr/local/bin/bootstrap.sh; then
        echo "[entrypoint] WARNING: bootstrap.sh failed — continuing anyway"
    fi
fi

# ---------- Background: persist ~/.claude.json every 60s ----------
(while true; do
    sleep 60
    [ -f "$CLAUDE_HOME/.claude.json" ] && cp "$CLAUDE_HOME/.claude.json" "$CLAUDE_HOME/.claude/.claude.json.persist" 2>/dev/null
done) &

# ---------- Hand off to s6-overlay ----------
echo "[entrypoint] Starting s6-overlay..."
exec /init "$@"
