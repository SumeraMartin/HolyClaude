# Troubleshooting Guide

Solutions to common issues when running HolyClaude.

---

## Common Issues

### CloudCLI shows wrong default directory

**Symptom:** CloudCLI web UI opens to `/home/claude` instead of `/workspace`.

**Cause:** `WORKSPACES_ROOT` environment variable not reaching the CloudCLI process. Docker-compose env vars don't automatically pass through s6-overlay's `s6-setuidgid`.

**Fix:** Already handled in HolyClaude — the s6 run script sets `WORKSPACES_ROOT=/workspace` directly. If you've modified the s6 service scripts, ensure the env var is set in the `env` command.

---

### SQLite "database is locked" errors

**Symptom:** Constant lock errors from CloudCLI account database or other SQLite databases.

**Cause:** SQLite uses file-level locking that CIFS/SMB doesn't support properly.

**Fix:** Don't store SQLite databases on network mounts. HolyClaude keeps `.cloudcli` in container-local storage for this reason. If you're using your own SQLite databases in `/workspace` on a network mount, move them to a local path.

> If you want the CloudCLI account to persist across rebuilds, use a **named Docker volume** for `/home/claude/.cloudcli` (see the README's Data & Persistence section). Named volumes live on the Docker engine's local filesystem, so SQLite file locking works. Never bind-mount `.cloudcli` to a NAS, SMB, or NFS path.

---

### Chromium crashes or blank pages

**Symptom:** Playwright tests fail, screenshots are blank, Lighthouse hangs.

**Cause:** Insufficient shared memory.

**Fix:** Ensure `shm_size: 2g` or higher in your docker-compose file. If running many concurrent tabs, increase to `4g`.

---

### File watchers not detecting changes

**Symptom:** Hot reload doesn't work. Dev servers don't pick up file changes.

**Cause:** Running on SMB/CIFS mounts which don't support `inotify`.

**Fix:** Add polling environment variables:
```yaml
environment:
  - CHOKIDAR_USEPOLLING=1
  - WATCHFILES_FORCE_POLLING=true
```

Note: Polling uses more CPU than inotify. Only enable when needed.

---

### Permission denied errors

**Symptom:** Can't write files, `git` operations fail, npm install fails.

**Cause:** Usually one of these:

- `PUID`/`PGID` doesn't match your host user
- Docker auto-created `./workspace` as `root:root` on first start because the directory did not exist yet

**Fix:** Set `PUID` and `PGID` to match your host user:
```bash
# On your host, check your IDs
id -u  # This is your PUID
id -g  # This is your PGID
```

Then in your compose file:
```yaml
environment:
  - PUID=1000
  - PGID=1000
```

HolyClaude also auto-fixes the top-level `/workspace` ownership on boot if Docker created it as root. If you still have permission errors after startup, the remaining mismatch is in your host files, not the container's workspace mount point.

---

### `rm -rf *` doesn't delete dotfiles

**Symptom:** Bootstrap sentinel (`.holyclaude-bootstrapped`) survives deletion, so bootstrap never re-runs.

**Cause:** Bash glob `*` doesn't match dotfiles (files starting with `.`).

**Fix:** Target the sentinel directly:
```bash
rm ./data/claude/.holyclaude-bootstrapped
```

Never delete the entire `./data/claude/` directory — this wipes your credentials.

---

### Docker creates `.claude.json` as a directory

**Symptom:** Claude Code CLI crashes on startup with cryptic errors.

**Cause:** If the bind-mount target doesn't exist as a file before container start, Docker creates it as a directory.

**Fix:** Already handled in `entrypoint.sh` — it pre-creates the file if missing. If you're running a custom setup, ensure `~/.claude.json` exists as a file before starting the container.

---

### Claude Code asks to re-login after rebuild

**Symptom:** After `docker compose down && up`, Claude Code prompts for OAuth / API key again.

**Cause:** Versions before v1.1.7 didn't persist `~/.claude.json`, which holds the Claude Code session state. Container recreation wiped it.

**Fix:** Upgrade to v1.1.7 or later. The session is now auto-saved to `./data/claude/.claude.json.persist` on every boot and every 60 seconds, then restored on the next start. If you're on v1.1.7+ and still losing the session, check that `./data/claude/` is actually writable by the container user (PUID/PGID mismatch).

---

### Claude Code installer hangs during build

**Symptom:** `curl -fsSL https://claude.ai/install.sh | bash` hangs indefinitely during `docker build`.

**Cause:** Installer prompts or behaves differently when WORKDIR is root-owned.

**Fix:** Already handled in the Dockerfile — `WORKDIR /workspace` and `USER claude` are set before the installer runs.

---

### Bootstrap doesn't re-run after image update

**Symptom:** New settings/memory from updated image aren't applied.

**Cause:** Sentinel file `.holyclaude-bootstrapped` exists, so bootstrap is skipped.

**Fix:**
```bash
rm ./data/claude/.holyclaude-bootstrapped
docker compose restart holyclaude
```

---

## Android Variant

### Emulator hangs at boot on Apple Silicon Mac

**Symptom:** `holyclaude-android-up` (or `emulator @phone34 -no-window &`) sits at "boot" forever, or takes 10+ minutes, on an Apple Silicon Mac.

**Cause:** macOS does not expose `/dev/kvm` and Docker Desktop on M-series cannot pass HVF through. The arm64 system image runs under QEMU TCG (software emulation), which is roughly 5-10× slower than KVM. On a slow path it may never reach `sys.boot_completed=1`.

**Fix:** The android variant is officially **experimental** on Mac. Use a Linux host with `--device /dev/kvm` for any serious Android work. For ad-hoc Mac use, connect to a real device with USB debugging enabled:

```bash
# On the host (macOS):
adb -a -P 5037 nodaemon server start

# Inside the container:
adb connect host.docker.internal:5555
```

---

### `Permission denied` opening `/dev/kvm`

**Symptom:** Emulator dies on startup with `KVM is required to run this AVD: Permission denied`.

**Cause:** `--device /dev/kvm` passes the device through but the host's `kvm` group GID varies by distro (Arch=78, Ubuntu=108, Debian=104) and the `claude` user inside the container is not a member of the matching group.

**Fix:** Already handled in `entrypoint.sh` — on every boot it reads the host's `/dev/kvm` GID, creates a matching group, and adds `claude` to it. If you still hit this:

```bash
# Inside the container:
ls -l /dev/kvm           # note the group number
id claude                # claude should be in that group
```

If claude is not in the group, restart the container — the entrypoint runs every boot. If the GID does not appear at all, your host did not pass the device through (`--device /dev/kvm` missing from the compose file).

---

### Gradle: `Permission denied` on `.gradle/`

**Symptom:** `./gradlew assembleDebug` fails with permission errors when writing to `.gradle/` or `~/.gradle/`.

**Cause:** Bind-mount UID mismatch. Gradle writes to `/workspace/.gradle` (the variant pins `GRADLE_USER_HOME` there) and the per-project `.gradle/`, both inside the bind-mounted `/workspace`. If `PUID`/`PGID` does not match your host user, the writes land as the wrong owner.

**Fix:** Set `PUID=$(id -u)` and `PGID=$(id -g)` in your compose file:

```yaml
environment:
  - PUID=1000   # your host UID
  - PGID=1000   # your host GID
```

---

### `scrcpy: server did not start` on a google_apis emulator

**Symptom:** `holyclaude-android-run` reports that scrcpy failed and falls back to `adb shell screenrecord`.

**Cause:** Some `google_apis` system images do not expose hardware MediaCodec, which scrcpy needs for its H.264 encoder. This is a known limitation of non-Play-Store images.

**Fix:** No fix needed — `holyclaude-android-run` automatically falls back to `adb shell screenrecord` (3-minute hard cap, ships with Android, no extra dependencies). If you are calling raw scrcpy, switch to:

```bash
adb shell screenrecord --time-limit 180 /sdcard/run.mp4 && adb pull /sdcard/run.mp4
```

---

### Container OOM-killed when starting the emulator

**Symptom:** Container exits with no clear error, or `dmesg` on the host shows OOM-killer messages.

**Cause:** The android variant assumes 8 GB host RAM minimum. `shm_size: 4g` is tmpfs, which counts against container RSS, and the emulator itself uses 1.5-2 GB. On a small VPS this exceeds the cgroup memory limit.

**Fix:** Drop `shm_size` to `2g`, do not run Chromium concurrently with the emulator, and consider a host with at least 8 GB RAM.

---

### `phone34` AVD reset on every restart

**Symptom:** Installed APKs disappear when the container is recreated.

**Cause:** The `~/.android` symlink → `~/.claude/.android` bind mount path is missing or broken. The AVD seed at `/opt/android-sdk-avd-seed/phone34.avd` should be copied into the bind-mounted home on first boot.

**Fix:** Verify the symlink exists:

```bash
ls -l ~/.android                       # should be a symlink → /home/claude/.claude/.android
ls ~/.claude/.android/avd/phone34.avd  # should exist after first boot
```

If the symlink is missing, ensure your compose file binds `./data/claude` to `/home/claude/.claude` and restart the container. The entrypoint creates the symlink on every boot.

---

### Cross-arch trap (`--platform linux/amd64` on Apple Silicon)

**Symptom:** The image runs but the emulator hangs forever, or the entrypoint logs `WARNING: image is built for x86_64 but host CPU is arm64`.

**Cause:** Forcing `--platform linux/amd64` on Apple Silicon pulls an x86_64 image that runs under Rosetta. The Android emulator then runs under TCG-on-Rosetta, which is unworkably slow.

**Fix:** Drop the `--platform` override and let Docker pick the native arch — the multi-arch manifest publishes both `linux/amd64` and `linux/arm64`. The arm64 image uses an `arm64-v8a` system image so it runs natively on Apple Silicon (still TCG without KVM, but at least native arch).

---

## SMB/CIFS Gotchas

If your volumes are on a Samba/CIFS network share (common with Hyper-V VMs, NAS devices):

### No inotify support

File watchers must use polling:
```yaml
- CHOKIDAR_USEPOLLING=1
- WATCHFILES_FORCE_POLLING=true
```

### No symlinks (without `mfsymlinks`)

npm global installs and Python `.local` can break. This is why HolyClaude keeps `.npm` and `.local` in container-local storage — don't mount them on network shares.

If you need symlinks on CIFS, add `mfsymlinks` to your mount options:
```
//server/share /mnt/share cifs mfsymlinks,... 0 0
```

### SQLite file locking fails

Any SQLite database on CIFS will get "database is locked" errors. Keep SQLite databases on local storage.

### No Unix permissions

`chmod`/`chown` silently succeed but don't actually change permissions on CIFS (depends on mount options). Use `uid=`, `gid=`, `file_mode=`, `dir_mode=` in mount options to set permissions.

---

## Getting Help

If your issue isn't covered here:

1. Check the [GitHub Issues](https://github.com/CoderLuii/HolyClaude/issues) for existing reports
2. Open a new issue with:
   - Your docker-compose file (redact API keys)
   - Output of `docker logs holyclaude`
   - What you expected vs what happened
