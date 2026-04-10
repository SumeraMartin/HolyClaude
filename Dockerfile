# ==============================================================================
# HolyClaude — Pre-configured Docker Environment for Claude Code CLI + CloudCLI
# https://github.com/coderluii/holyclaude
#
# Build variants:
#   docker build -t holyclaude .                          # full (default)
#   docker build --build-arg VARIANT=slim    -t holyclaude:slim .
#   docker build --build-arg VARIANT=android -t holyclaude:android .
# ==============================================================================

FROM node:22-bookworm-slim

LABEL org.opencontainers.image.source=https://github.com/CoderLuii/HolyClaude

# ---------- Build args ----------
ARG S6_OVERLAY_VERSION=3.2.0.2
ARG TARGETARCH
ARG VARIANT=full
# Android cmdline-tools pin (only consumed when VARIANT=android).
# Bump by editing both lines below in lockstep. Source:
# https://developer.android.com/studio
# Google labels the published checksum "SHA-256" but the value is 40 chars
# long — it is actually SHA-1. We verify with `sha1sum -c` after download.
ARG ANDROID_CMDLINE_VERSION=14742923
ARG ANDROID_CMDLINE_SHA1=48833c34b761c10cb20bcd16582129395d121b27

# ---------- Environment ----------
ENV DEBIAN_FRONTEND=noninteractive \
    LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8 \
    DISPLAY=:99 \
    DBUS_SESSION_BUS_ADDRESS=disabled: \
    CHROMIUM_FLAGS="--no-sandbox --disable-gpu --disable-dev-shm-usage" \
    CHROME_PATH=/usr/bin/chromium \
    PUPPETEER_EXECUTABLE_PATH=/usr/bin/chromium

# Android toolchain env (set unconditionally — directories simply do not
# exist on slim/full, which is harmless. Setting these via /etc/profile.d
# would not work because docker exec, the s6 services, and the CloudCLI PTY
# all spawn non-login non-interactive shells.)
ENV ANDROID_HOME=/opt/android-sdk \
    ANDROID_SDK_ROOT=/opt/android-sdk \
    JAVA_HOME=/usr/lib/jvm/default-java \
    GRADLE_USER_HOME=/workspace/.gradle \
    PATH="${PATH}:/opt/android-sdk/cmdline-tools/latest/bin:/opt/android-sdk/platform-tools:/opt/android-sdk/emulator"

# ---------- s6-overlay v3 (multi-arch) ----------
RUN apt-get update && apt-get install -y --no-install-recommends xz-utils curl ca-certificates && rm -rf /var/lib/apt/lists/*
ADD https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz /tmp/
RUN S6_ARCH=$(case "$TARGETARCH" in arm64) echo "aarch64";; *) echo "x86_64";; esac) && \
    curl -fsSL -o /tmp/s6-overlay-arch.tar.xz \
      "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" && \
    tar -C / -Jxpf /tmp/s6-overlay-noarch.tar.xz && \
    tar -C / -Jxpf /tmp/s6-overlay-arch.tar.xz && \
    rm /tmp/s6-overlay-*.tar.xz

# ---------- System packages (always installed) ----------
RUN apt-get update && apt-get install -y --no-install-recommends \
    # Core utilities
    git curl wget jq ripgrep fd-find unzip zip tree tmux fzf bat bubblewrap \
    # Build tools
    build-essential pkg-config python3 python3-pip python3-venv \
    # Browser (Playwright/Puppeteer)
    chromium \
    # Fonts
    fonts-liberation2 fonts-dejavu-core fonts-noto-core fonts-noto-color-emoji fonts-inter \
    # Locale support
    locales \
    # Debugging tools
    strace lsof iproute2 procps htop \
    # Database CLI tools
    postgresql-client redis-tools sqlite3 \
    # SSH client (NOT server)
    openssh-client \
    # Xvfb for headless Chrome
    xvfb \
    # Image processing
    imagemagick \
    # Sudo
    sudo \
    && rm -rf /var/lib/apt/lists/*

# ---------- bubblewrap setuid (Codex CLI sandbox on restricted kernels) ----------
RUN chmod u+s /usr/bin/bwrap

# ---------- Full-only system packages ----------
RUN if [ "$VARIANT" = "full" ]; then \
    apt-get update && apt-get install -y --no-install-recommends \
      pandoc ffmpeg libvips-dev \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# ---------- Azure CLI (full only) ----------
RUN if [ "$VARIANT" = "full" ]; then \
    curl -sL https://aka.ms/InstallAzureCLIDeb | bash \
    && rm -rf /var/lib/apt/lists/*; \
    fi

# ---------- GitHub CLI ----------
RUN curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
      | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
      > /etc/apt/sources.list.d/github-cli.list && \
    apt-get update && apt-get install -y gh && rm -rf /var/lib/apt/lists/*

# ---------- bat symlink (Debian names it batcat) ----------
RUN ln -sf /usr/bin/batcat /usr/local/bin/bat 2>/dev/null || true

# ---------- Locale configuration ----------
RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen

# ---------- Create claude user ----------
# node:22-bookworm-slim already has UID 1000 as 'node' — rename it to 'claude'
RUN usermod -l claude -d /home/claude -m node && \
    groupmod -n claude node && \
    echo "claude ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/claude && \
    chmod 0440 /etc/sudoers.d/claude

# ---------- Claude Code CLI (native installer) ----------
# CRITICAL: WORKDIR must be non-root-owned or the installer hangs
WORKDIR /workspace
USER claude
RUN curl -fsSL https://claude.ai/install.sh | bash
USER root
ENV PATH="/home/claude/.local/bin:${PATH}"

# ---------- npm global packages (slim — always installed) ----------
RUN npm i -g \
    typescript tsx \
    pnpm \
    vite esbuild \
    eslint prettier \
    serve nodemon concurrently \
    dotenv-cli

# ---------- npm global packages (full only) ----------
RUN if [ "$VARIANT" = "full" ]; then \
    npm i -g \
      wrangler vercel netlify-cli \
      pm2 \
      prisma drizzle-kit \
      eas-cli \
      lighthouse @lhci/cli \
      sharp-cli json-server http-server \
      @marp-team/marp-cli @cloudflare/next-on-pages; \
    fi

# ---------- Python packages (slim — always installed) ----------
RUN pip install --no-cache-dir --break-system-packages \
    requests httpx beautifulsoup4 lxml \
    Pillow \
    pandas numpy \
    openpyxl python-docx \
    jinja2 pyyaml python-dotenv markdown \
    rich click tqdm \
    playwright \
    apprise

# ---------- Python packages (full only) ----------
RUN if [ "$VARIANT" = "full" ]; then \
    pip install --no-cache-dir --break-system-packages \
      reportlab weasyprint cairosvg fpdf2 PyMuPDF pdfkit img2pdf \
      xlsxwriter xlrd \
      matplotlib seaborn \
      python-pptx \
      fastapi uvicorn \
      httpie; \
    fi

# ---------- AI CLI providers ----------
RUN npm i -g @google/gemini-cli @openai/codex task-master-ai
USER claude
RUN curl -fsSL https://cursor.com/install | bash
USER root

# ---------- Junie CLI (full only) ----------
USER claude
RUN if [ "$VARIANT" = "full" ]; then \
    curl -fsSL https://junie.jetbrains.com/install.sh | bash; \
    fi
USER root

# ---------- OpenCode CLI (full only) ----------
RUN if [ "$VARIANT" = "full" ]; then \
    npm i -g opencode-ai; \
    fi

COPY vendor/artifacts/siteboon-claude-code-ui-1.26.3.tgz /tmp/vendor/siteboon-claude-code-ui-1.26.3.tgz

# ---------- CloudCLI (web UI for Claude Code) ----------
RUN npm i -g /tmp/vendor/siteboon-claude-code-ui-1.26.3.tgz && rm -f /tmp/vendor/siteboon-claude-code-ui-1.26.3.tgz
RUN touch /usr/local/lib/node_modules/@siteboon/claude-code-ui/.env

# ---------- Patch: preserve WebSocket frame type in plugin proxy (Issue #11) ----------
RUN CLOUDCLI_INDEX="/usr/local/lib/node_modules/@siteboon/claude-code-ui/server/index.js" && \
    grep -q "upstream.on('message', (data) =>" "$CLOUDCLI_INDEX" && \
    sed -i "s/upstream.on('message', (data) => {/upstream.on('message', (data, isBinary) => {/" "$CLOUDCLI_INDEX" && \
    sed -i "s/if (clientWs.readyState === WebSocket.OPEN) clientWs.send(data)/if (clientWs.readyState === WebSocket.OPEN) clientWs.send(data, { binary: isBinary })/" "$CLOUDCLI_INDEX" && \
    sed -i "s/clientWs.on('message', (data) => {/clientWs.on('message', (data, isBinary) => {/" "$CLOUDCLI_INDEX" && \
    sed -i "s/if (upstream.readyState === WebSocket.OPEN) upstream.send(data)/if (upstream.readyState === WebSocket.OPEN) upstream.send(data, { binary: isBinary })/" "$CLOUDCLI_INDEX" && \
    echo "[patch] WebSocket frame type fix applied (both directions)" || \
    echo "[patch] WARNING: WebSocket pattern not found in vendored CloudCLI install, skipping patch"

# patch: preserve Shell tab scroll position across periodic refresh (issue #35)
RUN CLOUDCLI_BUNDLE="/usr/local/lib/node_modules/@siteboon/claude-code-ui/dist/assets/index-X3ImjnMV.js" && \
    grep -q 'const B=()=>{v.current?.focus()}' "$CLOUDCLI_BUNDLE" && \
    perl -pi -e 's/const B=\(\)=>\{v\.current\?\.focus\(\)\}/const B=()=>{const _vp=v.current?.buffer?.active?.viewportY??0;v.current?.focus();v.current?.scrollToLine(_vp)}/g' "$CLOUDCLI_BUNDLE" && \
    echo "[patch] Shell scroll position fix applied" || \
    echo "[patch] WARNING: Shell scroll pattern not found in vendored CloudCLI bundle, skipping patch"

# patch v1.2.2-1: commands.js expose newModel in spawn args (issue #36)
RUN CLOUDCLI_COMMANDS="/usr/local/lib/node_modules/@siteboon/claude-code-ui/server/routes/commands.js" && \
    grep -q 'message: args.length > 0' "$CLOUDCLI_COMMANDS" && \
    perl -pi -e 's/^(\s+)(message: args\.length > 0)/$1newModel: args.length > 0 ? args[0] : null,\n$1$2/' "$CLOUDCLI_COMMANDS" && \
    echo "[patch] commands.js newModel field added" || \
    echo "[patch] WARNING: commands.js newModel pattern not found, skipping patch"

# patch v1.2.2-2: bundle expose setClaudeModel in claudeModel context spread (issue #36)
RUN CLOUDCLI_BUNDLE="/usr/local/lib/node_modules/@siteboon/claude-code-ui/dist/assets/index-X3ImjnMV.js" && \
    grep -q 'claudeModel:W,codexModel:V' "$CLOUDCLI_BUNDLE" && \
    perl -pi -e 's/\QclaudeModel:W,codexModel:V\E/claudeModel:W,setClaudeModel:L,codexModel:V/g' "$CLOUDCLI_BUNDLE" && \
    echo "[patch] bundle setClaudeModel context spread applied" || \
    echo "[patch] WARNING: bundle claudeModel:W pattern not found, skipping patch"

# patch v1.2.2-3: bundle wire setClaudeModel:lS2 into cursorModel destructure (issue #36)
RUN CLOUDCLI_BUNDLE="/usr/local/lib/node_modules/@siteboon/claude-code-ui/dist/assets/index-X3ImjnMV.js" && \
    grep -q 'cursorModel:o,claudeModel:l,codexModel:c' "$CLOUDCLI_BUNDLE" && \
    perl -pi -e 's/\QcursorModel:o,claudeModel:l,codexModel:c\E/cursorModel:o,claudeModel:l,setClaudeModel:lS2,codexModel:c/g' "$CLOUDCLI_BUNDLE" && \
    echo "[patch] bundle setClaudeModel:lS2 destructure applied" || \
    echo "[patch] WARNING: bundle cursorModel destructure pattern not found, skipping patch"

# patch v1.2.2-4: bundle apply newModel on SSE model event (issue #36)
RUN CLOUDCLI_BUNDLE="/usr/local/lib/node_modules/@siteboon/claude-code-ui/dist/assets/index-X3ImjnMV.js" && \
    grep -q 'case"model":k({type:"assistant"' "$CLOUDCLI_BUNDLE" && \
    perl -pi -e 's/\Qcase"model":k({type:"assistant"\E/case"model":me.newModel\&\&lS2\&\&(lS2(me.newModel),localStorage.setItem("claude-model",me.newModel));k({type:"assistant"/g' "$CLOUDCLI_BUNDLE" && \
    echo "[patch] bundle SSE model event handler applied" || \
    echo "[patch] WARNING: bundle case\"model\" pattern not found, skipping patch"

# patch v1.2.2-5: bundle add custom model option to select (issue #36)
RUN CLOUDCLI_BUNDLE="/usr/local/lib/node_modules/@siteboon/claude-code-ui/dist/assets/index-X3ImjnMV.js" && \
    grep -q 'children:N.OPTIONS.map(({value:C,label:j})=>s.jsx("option",{value:C,children:j},C+j))}' "$CLOUDCLI_BUNDLE" && \
    perl -pi -e 's/\Qchildren:N.OPTIONS.map(({value:C,label:j})=>s.jsx("option",{value:C,children:j},C+j))}\E/children:[...N.OPTIONS.map(({value:C,label:j})=>s.jsx("option",{value:C,children:j},C+j)),!N.OPTIONS.some(C=>C.value===k)\&\&k\&\&s.jsx("option",{value:k,children:k},k+"custom")].filter(Boolean)}/g' "$CLOUDCLI_BUNDLE" && \
    echo "[patch] bundle custom model select option applied" || \
    echo "[patch] WARNING: bundle custom model select pattern not found, skipping patch"

# ---------- CloudCLI plugins (baked into image) ----------
USER claude
RUN mkdir -p /home/claude/.claude-code-ui/plugins && \
    git clone --depth 1 https://github.com/cloudcli-ai/cloudcli-plugin-starter.git /home/claude/.claude-code-ui/plugins/project-stats && \
    cd /home/claude/.claude-code-ui/plugins/project-stats && npm install && npm run build && \
    git clone --depth 1 https://github.com/cloudcli-ai/cloudcli-plugin-terminal.git /home/claude/.claude-code-ui/plugins/web-terminal && \
    cd /home/claude/.claude-code-ui/plugins/web-terminal && npm install && npm run build && \
    echo '{"project-stats":{"name":"project-stats","source":"https://github.com/cloudcli-ai/cloudcli-plugin-starter","enabled":true},"web-terminal":{"name":"web-terminal","source":"https://github.com/cloudcli-ai/cloudcli-plugin-terminal","enabled":true}}' > /home/claude/.claude-code-ui/plugins.json
USER root

# ---------- Android toolchain (android variant only) ----------
# Inserts JDK 17 + Android SDK + platform-tools + build-tools + emulator +
# scrcpy + arch-correct system image + a pre-baked AVD. The block is
# deliberately collapsed into one RUN so sdkmanager temp files and apt
# caches do not bloat intermediate layers (saves ~300-500 MB compressed).
#
# IMG_ARCH is derived inline from TARGETARCH the same way S6_ARCH is at
# the top of the file (arm64 → arm64-v8a, anything else → x86_64).
#
# The AVD is created at /opt/android-sdk-avd-seed/phone34.avd as the claude
# user. The seed location is outside any bind mount so it survives a
# `compose down`. On first boot, bootstrap.sh copies the seed into
# ~/.claude/.android/avd/ which is bind-mounted, so AVD state then
# persists across container recreation.
#
# License hashes pre-seeded so the install never blocks on an interactive
# prompt. The trailing `yes | sdkmanager --licenses` is a belt-and-braces
# safety net that swallows SIGPIPE under set -e via the explicit `|| true`.
RUN if [ "$VARIANT" = "android" ]; then \
      IMG_ARCH=$(case "$TARGETARCH" in arm64) echo "arm64-v8a";; *) echo "x86_64";; esac) && \
      apt-get update && apt-get install -y --no-install-recommends \
        openjdk-17-jdk-headless \
        scrcpy \
        libgl1 libx11-6 libxkbcommon0 libnss3 libasound2 \
      && rm -rf /var/lib/apt/lists/* && \
      mkdir -p /opt/android-sdk/cmdline-tools && \
      curl -fsSL -o /tmp/cli.zip \
        "https://dl.google.com/android/repository/commandlinetools-linux-${ANDROID_CMDLINE_VERSION}_latest.zip" && \
      echo "${ANDROID_CMDLINE_SHA1}  /tmp/cli.zip" | sha1sum -c - && \
      unzip -q /tmp/cli.zip -d /opt/android-sdk/cmdline-tools && \
      mv /opt/android-sdk/cmdline-tools/cmdline-tools /opt/android-sdk/cmdline-tools/latest && \
      rm /tmp/cli.zip && \
      mkdir -p /opt/android-sdk/licenses && \
      printf '\n8933bad161af4178b1185d1a37fbf41ea5269c55\nd56f5187479451eabf01fb78af6dfcb131a6481e\n24333f8a63b6825ea9c5514f83c2829b004d1fee\n' > /opt/android-sdk/licenses/android-sdk-license && \
      printf '\n84831b9409646a918e30573bab4c9c91346d8abd\n504667f4c0de7af1a06de9f4b1727b84351f2910\n' > /opt/android-sdk/licenses/android-sdk-preview-license && \
      printf '\nd975f751698a77b662f1254ddbeed3901e976f5a\n' > /opt/android-sdk/licenses/intel-android-extra-license && \
      printf '\n859f317696f67ef3d7f30a50a5560e7834b43903\n' > /opt/android-sdk/licenses/android-sdk-arm-dbt-license && \
      ( yes 2>/dev/null | /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk --licenses >/dev/null 2>&1 || true ) && \
      /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk \
        "platform-tools" \
        "platforms;android-34" \
        "build-tools;34.0.5" \
        "emulator" \
        "system-images;android-34;google_apis;${IMG_ARCH}" >/dev/null && \
      /opt/android-sdk/cmdline-tools/latest/bin/sdkmanager --sdk_root=/opt/android-sdk --list_installed | grep -q "system-images;android-34;google_apis;${IMG_ARCH}" && \
      rm -rf \
        /opt/android-sdk/build-tools/34.0.5/renderscript \
        /opt/android-sdk/emulator/lib64/qt/translations \
        /opt/android-sdk/platforms/android-34/skins \
        /opt/android-sdk/.downloadIntermediates \
        /root/.android/cache && \
      mkdir -p /opt/android-sdk-avd-seed && \
      chown -R claude:claude /opt/android-sdk /opt/android-sdk-avd-seed && \
      echo no | runuser -u claude -- env ANDROID_AVD_HOME=/opt/android-sdk-avd-seed HOME=/home/claude \
        /opt/android-sdk/cmdline-tools/latest/bin/avdmanager create avd \
          --force \
          -n phone34 \
          -k "system-images;android-34;google_apis;${IMG_ARCH}" \
          --tag google_apis \
          --abi "${IMG_ARCH}" \
          --device "pixel_5" && \
      printf 'hw.ramSize=1536\ndisk.dataPartition.size=4096M\n' >> /opt/android-sdk-avd-seed/phone34.avd/config.ini && \
      runuser -u claude -- env ANDROID_AVD_HOME=/opt/android-sdk-avd-seed HOME=/home/claude \
        /opt/android-sdk/cmdline-tools/latest/bin/avdmanager list avd | grep -q phone34 && \
      echo "[android] toolchain OK: jdk17 + sdk + build-tools 34.0.5 + system-images;android-34;google_apis;${IMG_ARCH} + AVD phone34" ; \
    fi

# ---------- Store variant + image arch for bootstrap and entrypoint ----------
# /etc/holyclaude-img-arch is read by entrypoint.sh on the android variant
# to detect cross-arch traps (e.g. --platform linux/amd64 forced on Apple
# Silicon, which produces an x86_64 image running under Rosetta+TCG and
# is guaranteed to hang on first emulator boot).
RUN echo "${VARIANT}" > /etc/holyclaude-variant && \
    IMG_ARCH=$(case "${TARGETARCH}" in arm64) echo "arm64-v8a";; *) echo "x86_64";; esac) && \
    echo "${IMG_ARCH}" > /etc/holyclaude-img-arch

# ---------- Copy config files ----------
COPY scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
COPY scripts/bootstrap.sh /usr/local/bin/bootstrap.sh
COPY scripts/notify.py /usr/local/bin/notify.py
COPY scripts/android/holyclaude-info /usr/local/bin/holyclaude-info
COPY scripts/android/holyclaude-android-up /usr/local/bin/holyclaude-android-up
COPY scripts/android/holyclaude-android-down /usr/local/bin/holyclaude-android-down
COPY scripts/android/holyclaude-android-run /usr/local/bin/holyclaude-android-run
COPY config/settings.json /usr/local/share/holyclaude/settings.json
COPY config/claude-memory-full.md /usr/local/share/holyclaude/claude-memory-full.md
COPY config/claude-memory-slim.md /usr/local/share/holyclaude/claude-memory-slim.md
COPY config/claude-memory-android.md /usr/local/share/holyclaude/claude-memory-android.md
RUN chmod +x /usr/local/bin/entrypoint.sh \
    /usr/local/bin/bootstrap.sh \
    /usr/local/bin/notify.py \
    /usr/local/bin/holyclaude-info \
    /usr/local/bin/holyclaude-android-up \
    /usr/local/bin/holyclaude-android-down \
    /usr/local/bin/holyclaude-android-run

# ---------- s6-overlay service definitions ----------
COPY s6-overlay/s6-rc.d/cloudcli/type /etc/s6-overlay/s6-rc.d/cloudcli/type
COPY s6-overlay/s6-rc.d/cloudcli/run /etc/s6-overlay/s6-rc.d/cloudcli/run
COPY s6-overlay/s6-rc.d/xvfb/type /etc/s6-overlay/s6-rc.d/xvfb/type
COPY s6-overlay/s6-rc.d/xvfb/run /etc/s6-overlay/s6-rc.d/xvfb/run
RUN chmod +x /etc/s6-overlay/s6-rc.d/cloudcli/run \
    /etc/s6-overlay/s6-rc.d/xvfb/run && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/cloudcli && \
    touch /etc/s6-overlay/s6-rc.d/user/contents.d/xvfb

# ---------- Working directory ----------
WORKDIR /workspace

# ---------- Health check ----------
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:3001/ || exit 1

# ---------- s6-overlay as PID 1 ----------
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
