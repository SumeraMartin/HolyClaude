# HolyClaude Environment — Android Variant

You are running inside a **HolyClaude Docker container** (android variant). This is the slim base plus a complete Android toolchain — JDK 17, Android SDK, platform-tools, build-tools 34.0.0, the android-34 google_apis system image (arch-correct), the Android emulator, scrcpy, and a pre-baked `phone34` AVD. Run `holyclaude-info` to confirm.

This file is your global memory — customize it with your own preferences, projects, and context.

---

## Environment Overview

- **OS:** Debian Bookworm (slim) inside Docker
- **User:** `claude` (UID/GID configurable via PUID/PGID)
- **Working directory:** `/workspace` (bind-mounted from host)
- **Home directory:** `/home/claude`
- **Persistent storage:** `~/.claude/` is bind-mounted — settings, credentials, the AVD, and this file survive container rebuilds
- **Process manager:** s6-overlay v3 (PID 1) — manages all long-running services
- **Display:** Xvfb virtual display at `:99` for headless browser operations
- **Variant:** ANDROID — slim base + Android toolchain (JDK 17, SDK 34, emulator, scrcpy, AVD `phone34`)

## Running Services

| Service | What it does | Port |
|---------|-------------|------|
| **CloudCLI** | Web UI for Claude Code | `3001` |
| **Xvfb** | Virtual display for headless Chromium | `:99` (internal) |

The Android emulator is **NOT** an s6 service — it is started on demand by the `holyclaude-android-up` wrapper. This keeps idle RAM ≤ 250 MB above the slim baseline when you are not doing Android work.

## Android Toolchain (variant-specific)

### Pre-installed

| Tool | Where | Notes |
|------|-------|-------|
| **JDK 17** | `JAVA_HOME=/usr/lib/jvm/default-java` | `openjdk-17-jdk-headless` — meets AGP 8.x minimum |
| **Android SDK** | `ANDROID_HOME=/opt/android-sdk` | Also exposed as `ANDROID_SDK_ROOT` |
| **cmdline-tools** | `$ANDROID_HOME/cmdline-tools/latest/bin` | `sdkmanager`, `avdmanager` |
| **platform-tools** | `$ANDROID_HOME/platform-tools` | `adb`, `fastboot` |
| **build-tools 34.0.0** | `$ANDROID_HOME/build-tools/34.0.0` | `aapt`, `apksigner`, `d8`, `r8`, `zipalign` |
| **android-34 platform** | `$ANDROID_HOME/platforms/android-34` | API 34 (compileSdk target) |
| **system image** | `$ANDROID_HOME/system-images/android-34/google_apis/...` | arch-correct (`x86_64` on amd64, `arm64-v8a` on arm64) |
| **emulator** | `$ANDROID_HOME/emulator/emulator` | Use the wrappers below, not raw flags |
| **scrcpy** | `/usr/bin/scrcpy` | Headless mp4 recording |
| **AVD `phone34`** | `~/.android/avd/phone34.avd` (symlinked into `~/.claude/.android`) | Pixel 5 device profile, 1.5 GB RAM, 4 GB userdata |

### Canonical workflow (wrapper-based — preferred)

```bash
# 1. Build the APK (first run takes 3-8 minutes; see "Time expectations")
cd /workspace/<gradle-project>
./gradlew --no-daemon assembleDebug

# 2. Run it: idempotent boot + install + launch + record + logcat → run dir
holyclaude-android-run app/build/outputs/apk/debug/app-debug.apk --seconds 60

# 3. Inspect artifacts (auto-pruned to 20 most recent)
ls /workspace/.holyclaude-recordings/
```

`holyclaude-android-run` writes to `/workspace/.holyclaude-recordings/<ISO8601-utc>/`:

| File | What it is |
|------|-----------|
| `run.mp4` | Video of the session (scrcpy → fallback to `adb screenrecord`) |
| `logcat.txt` | Full default-buffer logcat for the run |
| `logcat-crash.txt` | Crash buffer logcat (separate, don't miss it) |
| `app.apk` | Hardlink to the installed APK for traceability |
| `meta.json` | `{apk, package, activity, install_seconds, record_seconds, recording_backend, kvm}` |
| `command.sh` | The exact commands the wrapper ran |
| `install.log`, `scrcpy.log` | Raw stdout/stderr from each step |

### Wrappers shipped at `/usr/local/bin/`

| Wrapper | What it does |
|---------|-------------|
| `holyclaude-info` | JSON dump of variant, kvm status, tool versions, AVDs. Run this first every session. |
| `holyclaude-android-up [--avd phone34] [--timeout 300]` | Idempotent emulator boot. Logs to `/tmp/holyclaude-emulator.log`. Emits `ERROR kind=... message=... remediation=...` on failure. |
| `holyclaude-android-down` | Clean kill of any running emulator. Safe to call when nothing is running. The SessionEnd hook calls this. |
| `holyclaude-android-run <apk> [--seconds 60] [--activity name] [--no-recording]` | The "one outcome" tool — boot + install + launch + record + logcat. |

### Raw primitives (escape hatch — use only when wrappers don't fit)

```bash
emulator @phone34 -no-window -no-audio -no-boot-anim \
  -accel auto -gpu swiftshader_indirect \
  -memory 1536 -no-snapshot-load -no-snapshot-save &
timeout 300 adb wait-for-device shell \
  'while [ "$(getprop sys.boot_completed | tr -d "\r")" != "1" ]; do sleep 1; done'
adb shell input keyevent 82                                 # unlock
cd /workspace/<gradle-project> && ./gradlew --no-daemon assembleDebug
adb logcat -c
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n <package>/<activity>
scrcpy --no-playback --no-window \
  --record=/workspace/.holyclaude-recordings/run.mp4 --time-limit=60
adb logcat -d > /workspace/.holyclaude-recordings/logcat.txt
adb emu kill
```

Notes that bite people who skip the wrappers:

- `scrcpy --no-display` was **removed in scrcpy 3.x** — use `--no-playback --no-window`.
- `adb wait-for-device` alone is racy — it returns the moment adbd's socket opens, typically 5-15 s before the framework finishes booting. The polling form with `tr -d '\r'` is mandatory.
- Some `google_apis` system images lack hardware MediaCodec, in which case scrcpy fails. Fall back to `adb shell screenrecord /sdcard/run.mp4 --time-limit 180 && adb pull /sdcard/run.mp4` (3-min hard cap).

### KVM check

```bash
cat /run/holyclaude/kvm    # 1 = hardware acceleration, 0 = software mode
```

- `1` (Linux host with `--device /dev/kvm` passed through): emulator boots in 30-60 s, runs at near-native speed.
- `0` (Mac host, or Linux host with no KVM): emulator falls back to TCG. **On Apple Silicon expect 5-10× slowdown or full hangs.** Mac is officially "experimental" for the android variant.

### Time expectations (DO NOT retry on perceived hangs)

| Operation | First run | Steady state |
|-----------|-----------|--------------|
| `holyclaude-android-up` (KVM) | 30-90 s | 30-60 s |
| `holyclaude-android-up` (no KVM) | 5-10 min | 3-7 min |
| `./gradlew --no-daemon assembleDebug` (cold) | **3-8 min** | 30-90 s |
| `adb install -r` | 5-15 s | 3-8 s |
| `scrcpy` recording | wall-clock = `--time-limit` | same |

The first `./gradlew assembleDebug` downloads the wrapper, starts the JVM, resolves dependencies, and runs dex2oat. This is **expected to take minutes**, not seconds. Do not retry it on perceived hangs — wait for the actual error.

### Common failures → check → fix

| Symptom | Check | Fix |
|---------|-------|-----|
| `adb devices` is empty | Is the emulator process alive? `pgrep -f emulator` | `holyclaude-android-up` |
| Emulator hangs at boot | `cat /run/holyclaude/kvm` | If `0` on Apple Silicon, you are running TCG arm64 — switch to a Linux+KVM host or use a real device via `adb connect host.docker.internal:5555` |
| `Permission denied` opening `/dev/kvm` | `ls -l /dev/kvm` inside the container | Restart the container — entrypoint adds claude to a group matching the host's kvm GID on every boot |
| `gradle: Permission denied` on `.gradle/` | Host UID vs container UID | Set `PUID=$(id -u) PGID=$(id -g)` in the compose file |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | Old APK with different signature | `adb uninstall <package> && adb install -r <apk>` |
| `scrcpy: server did not start` | google_apis image lacks MediaCodec | The wrapper auto-falls-back to `adb screenrecord`. If you are using raw scrcpy, switch to `adb shell screenrecord` |
| `OOM` or container killed | Host RAM | Reduce `shm_size` to 2g and don't run Chromium concurrently with the emulator. Min host RAM: 8 GB |
| Emulator log nowhere visible | `tail -F /tmp/holyclaude-emulator.log` | The wrapper redirects all emulator output there |
| AVD reset on every restart | Did you bind-mount `./data/claude`? | The AVD lives at `~/.claude/.android/avd/phone34.avd` — ephemeral if `./data/claude` is not bind-mounted |

### NOT pre-installed (install per project as needed)

- **Maestro** (`curl -Ls "https://get.maestro.mobile.dev" | bash`)
- **Appium** (`npm i -g appium && appium driver install uiautomator2`)
- **uiautomator2** Python bindings (`pip install --break-system-packages uiautomator2`)
- **Espresso / robolectric** test runners (Gradle dependencies, per project)

These are intentionally not baked in — locking the image to one driver hurts more than it helps. Install the one your project actually uses.

### Threat model — read this before exposing the variant

The android variant runs with `--device /dev/kvm` plus the existing `NOPASSWD sudo`, `seccomp=unconfined`, and `cap_add: [SYS_ADMIN, SYS_PTRACE]`. That combination materially widens the host-adjacent privilege boundary (KVM ioctl access through unfiltered seccomp). **Do not expose the android variant to untrusted input.** Treat it as a developer workstation only, not a multi-tenant or public-facing surface.

## Node.js & npm (v22 LTS)

### Pre-installed global packages
- **Languages:** typescript, tsx
- **Package managers:** pnpm, npm (built-in)
- **Build tools:** vite, esbuild
- **Code quality:** eslint, prettier
- **Dev servers:** serve, nodemon
- **Utilities:** concurrently, dotenv-cli

### NOT pre-installed (install when needed)
```bash
npm i -g wrangler vercel netlify-cli prisma drizzle-kit eas-cli lighthouse
```

## Python 3

### Pre-installed packages
HTTP (requests, httpx), scraping (beautifulsoup4, lxml), images (Pillow), data (pandas, numpy), Excel (openpyxl), templating (jinja2, markdown), config (pyyaml, python-dotenv), CLIs (rich, click, tqdm), browser (playwright).

```bash
# Add what you need
pip install --break-system-packages reportlab matplotlib fastapi
```

## AI CLI Providers

| CLI | Command | Notes |
|-----|---------|-------|
| **Claude Code** | `claude` | Primary — you are running inside this |
| **Gemini CLI** | `gemini` | Requires `GEMINI_API_KEY` |
| **OpenAI Codex** | `codex` | Requires `OPENAI_API_KEY` |
| **Cursor** | `cursor` | Requires `CURSOR_API_KEY` |
| **TaskMaster AI** | `task-master` | Task planning |

## System Tools

### Command-line utilities
- **Search:** ripgrep (`rg`), fd (`fdfind`), fzf, grep
- **Files:** tree, bat (`bat`), jq, zip/unzip
- **Network:** curl, wget, openssh-client
- **Process:** htop, lsof, strace, iproute2 (`ip`, `ss`)
- **Terminal:** tmux
- **Version control:** git, gh (GitHub CLI)

### Database CLIs
PostgreSQL (`psql`), Redis (`redis-cli`), SQLite (`sqlite3`).

### Browser
Chromium at `/usr/bin/chromium` — headless by default. Playwright installed. Xvfb virtual display at `:99`.

## GitHub CLI (gh)

```bash
gh auth login
gh repo clone owner/repo
gh pr create --title "..." --body "..."
```

## Notifications (Apprise)

Optional push notifications via Apprise. Disabled by default.

**To enable:**
1. Set one or more `NOTIFY_*` env vars (`NOTIFY_DISCORD`, `NOTIFY_TELEGRAM`, ...).
2. Create the flag file: `touch ~/.claude/notify-on`.

## Workspace

- All projects live in `/workspace` (bind-mounted from host)
- Git is pre-configured with `safe.directory /workspace`
- Identity is set via `GIT_USER_NAME` / `GIT_USER_EMAIL`
- `GRADLE_USER_HOME=/workspace/.gradle` so the gradle cache persists with your code

## Permissions

Claude Code runs in `acceptEdits` mode by default:
- File edits: allowed without confirmation
- Shell commands: asks for confirmation
- Full bypass: change `acceptEdits` to `bypassPermissions` in `~/.claude/settings.json`

The `SessionEnd` hook calls `holyclaude-android-down` so the emulator does not leak 2-3 GB of RAM after every session.

## Container Lifecycle

- **First boot:** Bootstrap runs once — copies settings, memory, configures git
- **Subsequent boots:** Bootstrap skipped (sentinel file exists)
- **Re-trigger:** `rm ~/.claude/.holyclaude-bootstrapped`
- **AVD persists** via the `~/.claude/.android` symlink → `./data/claude/.android` bind mount
- **Credentials persist** via the `./data/claude` bind mount

## Tips

- **shm_size:** This variant assumes `shm_size: 4g` if you run the emulator alongside Chromium. `2g` is fine if Chromium is idle, but min host RAM is 8 GB.
- **Cross-arch trap:** Do **NOT** force `--platform linux/amd64` on Apple Silicon. You will get an x86_64 image under Rosetta under TCG and the emulator will hang on first boot. The entrypoint warns when it detects this mismatch.
- **PUID/PGID match the host:** Set `PUID=$(id -u) PGID=$(id -g)` in your compose file or the gradle cache will hit "permission denied".
- **Web Terminal plugin in CloudCLI** is more reliable than "Continue in Shell".
- If on SMB/CIFS mounts, enable `CHOKIDAR_USEPOLLING=1` and `WATCHFILES_FORCE_POLLING=true`.

---

## Your Preferences

Add your personal preferences below. This section persists across container rebuilds.

```
# Example:
# - Default Android module layout: app + core + ui + data
# - Prefer Compose over views
# - Always run lint + ktlint before pushing
```
