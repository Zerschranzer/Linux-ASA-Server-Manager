FROM ubuntu:24.04

# No apt dialogs
ENV DEBIAN_FRONTEND=noninteractive

# SteamCMD/Proton directories
ENV STEAMCMDDIR="/opt/steamcmd"
ENV PROTON_VERSION="GE-Proton10-4"
ENV PROTONDIR="/opt/proton/${PROTON_VERSION}"

# Add SteamCMD to PATH
ENV PATH="$PATH:$STEAMCMDDIR"

# System packages
RUN dpkg --add-architecture i386 && \
    apt-get update && \
    apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        lib32gcc-s1 \
        lib32stdc++6 \
        locales \
        tar \
        python3 \
        libfreetype6:i386 \
        libfreetype6:amd64 \
    && rm -rf /var/lib/apt/lists/*

# Install SteamCMD
RUN mkdir -p "${STEAMCMDDIR}" && \
    curl -sSL "https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz" \
    | tar -xz -C "${STEAMCMDDIR}"

# Install GE-Proton
RUN mkdir -p "${PROTONDIR}" && \
    curl -sSL "https://github.com/GloriousEggroll/proton-ge-custom/releases/download/${PROTON_VERSION}/${PROTON_VERSION}.tar.gz" \
    | tar -xz --strip-components=1 -C "${PROTONDIR}"

# Copy entrypoint script
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Copy rcon.py client
COPY rcon.py /opt/rcon/rcon.py
RUN chmod +x /opt/rcon/rcon.py

# Default working directory and entrypoint
WORKDIR /ark
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/bin/bash"]
