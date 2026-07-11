FROM ubuntu:24.04

# No apt dialogs
ENV DEBIAN_FRONTEND=noninteractive

# ------------------------------------------------------------------
# umu-launcher + GE-Proton configuration.
# Mirrors ark_instance_manager.sh: umu-launcher zipapp v1.4.0 + pinned
# GE-Proton10-34, downloaded deterministically from release URLs (NOT
# the GitHub API, which is rate-limited to 60 req/h per IP).
#
# GE-Proton10-34 is PINNED to the 10-series on purpose. GE-Proton11-1
# has a regression where ArkAscendedServer.exe hangs forever during
# static import resolution (last loaded DLL: imm32.dll). Do not bump
# without testing a full cold start.
# ------------------------------------------------------------------
ENV UMU_VERSION="1.4.0"
ENV UMU_DIR="/opt/umu-launcher"
ENV UMU_RUN_BIN="$UMU_DIR/umu-run"
ENV GE_PROTON_VERSION="GE-Proton10-34"
ENV GE_PROTON_DIR="/opt/proton"
ENV GE_PROTON_PATH="$GE_PROTON_DIR/$GE_PROTON_VERSION"
ENV UMU_GAMEID="umu-default"
ENV UMU_PREFIX_DIR="/tmp/umu-home/umu-prefix"

# Home directory for steam user (umu needs a real home for runtime cache)
ENV HOME="/tmp/umu-home"

# SteamCMD
ENV STEAMCMDDIR="/opt/steamcmd"
ENV PATH="$PATH:$STEAMCMDDIR"

# System packages.
# libzstd1: required by umu-launcher's pyzstd binding.
# procps:     needed for pgrep (wineserver polling, health checks).
# xz-utils:   needed for umu-launcher tar extraction.
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        locales \
        procps \
        python3 \
        tar \
        xz-utils \
        libfreetype6:i386 \
        libfreetype6:amd64 \
        libzstd1 \
    && rm -rf /var/lib/apt/lists/*

# Generate locales (SteamCMD needs en_US.UTF-8)
RUN locale-gen en_US.UTF-8 && update-locale LANG=en_US.UTF-8



# Verify python3 >= 3.10 (umu-launcher requirement)
RUN python3 -c 'import sys; assert sys.version_info >= (3, 10), "Python >= 3.10 required"'

# Install SteamCMD and trigger initial self-update.
# The steamcmd tarball does NOT include steamclient.so; it's downloaded
# on first run. Running +quit here ensures steamclient.so exists for the
# SDK symlinks that entrypoint.sh creates at server start.
RUN mkdir -p "$STEAMCMDDIR" && \
    curl -sSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar -xz -C "$STEAMCMDDIR" && \
    "$STEAMCMDDIR/steamcmd.sh" +quit >/dev/null 2>&1 || true

# Install umu-launcher zipapp (self-contained, no distro package needed)
RUN mkdir -p "$UMU_DIR" && \
    curl -sSL "https://github.com/Open-Wine-Components/umu-launcher/releases/download/${UMU_VERSION}/umu-launcher-${UMU_VERSION}-zipapp.tar" \
    | tar -x -C "$UMU_DIR" --strip-components=1 && \
    chmod +x "$UMU_RUN_BIN"

# Install pinned GE-Proton (direct download, NOT GitHub API)
RUN mkdir -p "$GE_PROTON_DIR" && \
    curl -sSL "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${GE_PROTON_VERSION}/${GE_PROTON_VERSION}.tar.gz" \
    | tar -xz -C "$GE_PROTON_DIR" && \
    test -x "$GE_PROTON_PATH/proton" || { echo "ERROR: proton binary missing after extraction"; exit 1; }

# Wine prefix is NOT initialized at build time because umu-launcher
# refuses to run as root (Docker builds always run as root).
# Instead, entrypoint.sh handles first-run initialization when the
# container starts with a non-root user (--user flag).
# The prefix directory is created here so the path exists for bind-mounts.
# Create prefix and runtime cache directories under HOME (all under /tmp, writable by any UID)
RUN mkdir -p "$UMU_PREFIX_DIR" "$HOME/.local/share/umu" && chmod -R 777 "$HOME"

# Copy entrypoint and RCON client
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh
COPY rcon.py /opt/rcon/rcon.py
RUN chmod +x /opt/rcon/rcon.py

# Make all binaries world-readable/executable so non-root users can run them
RUN chmod -R a+rwx /opt/steamcmd && chmod -R a+rx /opt/umu-launcher /opt/proton /opt/rcon

# Make all binaries world-readable/executable so non-root users (--user flag) can run them.
# The container runs as a non-root UID from the manager script.

WORKDIR /ark
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
