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

# ---------- Pre-create ~/.claude.json as a FILE ----------
# If this does not exist before Docker mounts, Docker creates it as a DIRECTORY
if [ ! -f "$CLAUDE_HOME/.claude.json" ]; then
    echo "[entrypoint] Pre-creating ~/.claude.json"
    echo '{"hasCompletedOnboarding":true,"installMethod":"native"}' > "$CLAUDE_HOME/.claude.json"
    chown "$PUID:$PGID" "$CLAUDE_HOME/.claude.json"
fi

# ---------- Ensure DISPLAY is set ----------
export DISPLAY=:99

# ---------- First-boot bootstrap ----------
SENTINEL="$CLAUDE_HOME/.claude/.holyclaude-bootstrapped"
if [ ! -f "$SENTINEL" ]; then
    echo "[entrypoint] First boot detected — running bootstrap.sh"
    if ! /usr/local/bin/bootstrap.sh; then
        echo "[entrypoint] WARNING: bootstrap.sh failed — continuing anyway"
    fi
fi

# ---------- Hand off to s6-overlay ----------
echo "[entrypoint] Starting s6-overlay..."
exec /init "$@"
