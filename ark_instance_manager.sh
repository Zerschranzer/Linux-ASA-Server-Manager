#!/bin/bash

export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export LANGUAGE=C.UTF-8

set -e

# Color definitions
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
RESET='\e[0m'

# Signal handling. When the user hits Ctrl-C or the script gets SIGTERM, we
# want already-started servers to keep running -- they are intentionally
# detached via setsid in start_server() and live in their own process group.
# We deliberately do NOT pkill children here: doing so used to kill the servers
# the message claims will keep running, leaving the user with a tidy lie.
trap 'echo -e "${RED}Script interrupted. Detached servers continue running in the background.${RESET}"; exit 130' SIGINT SIGTERM

# Base directory for all instances
BASE_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
INSTANCES_DIR="$BASE_DIR/instances"
RCON_SCRIPT="$BASE_DIR/rcon.py"
ARK_RESTART_MANAGER="$BASE_DIR/ark_restart_manager.sh"
ARK_INSTANCE_MANAGER="$BASE_DIR/ark_instance_manager.sh"

# Define the base paths as variables
STEAMCMD_DIR="$BASE_DIR/steamcmd"
SERVER_FILES_DIR="$BASE_DIR/server-files"

# umu-launcher configuration -- replaces direct proton invocation.
# umu-run handles Steam Linux Runtime, Proton prefix setup and protonfixes
# automatically. No Steam install required.
#
# The zipapp is a self-contained Python archive (PEP 441), distribution-agnostic.
# It is downloaded standalone into $BASE_DIR/umu-launcher (same pattern as the old
# Proton tarball download), so the script does not depend on any distro package
# for umu-launcher itself. Only python3 >= 3.10 is required on the host.
UMU_VERSION="1.4.0"
UMU_DIR="$BASE_DIR/umu-launcher"
UMU_RUN_BIN="$UMU_DIR/umu-run"
UMU_URL="https://github.com/Open-Wine-Components/umu-launcher/releases/download/$UMU_VERSION/umu-launcher-$UMU_VERSION-zipapp.tar"
UMU_GAMEID="${UMU_GAMEID:-umu-default}"
UMU_PREFIX_DIR="$BASE_DIR/umu-prefix"

# GE-Proton is pinned and downloaded deterministically into $BASE_DIR, exactly
# like the umu-launcher zipapp above -- rather than relying on umu's runtime
# alias resolution (PROTONPATH=GE-Proton). The alias makes umu resolve+download
# the latest GE-Proton from the GitHub *API* (api.github.com) on first run. That
# API is rate-limited to 60 requests/hour per IP for unauthenticated callers, so
# in containers, CI, CGNAT or shared-egress networks it frequently fails with
# "Failed to acquire release assets from 'https://api.github.com'". umu 1.4.0
# then aborts hard because PROTONPATH ends up empty (FileNotFoundError in
# download_proton), or -- depending on cache state -- because a required Steam
# Linux Runtime (e.g. steamrt4/toolmanifest.vdf) was never fetched.
#
# By downloading a fixed GE-Proton build from the release *download* URL
# (codeload / release-asset delivery -- NOT the API, not rate-limited) and
# pointing PROTONPATH at the concrete extracted directory, umu never needs to
# contact the GitHub API for Proton. UMU_RUNTIME_UPDATE=0 additionally stops umu
# from switching/upgrading the Steam Linux Runtime mid-flight (which would hit
# the network again). The runtime itself is still fetched once by umu on first
# run, but that comes from Valve's repos, not the GitHub API.
# PINNED TO THE 10-SERIES ON PURPOSE. GE-Proton11-1 (Wine 11 base, built
# 2026-06-24) has a regression with ArkAscendedServer.exe: the process hangs
# forever during static import resolution (last loaded DLL: imm32.dll), before
# a single line of engine code runs -- no crash, no exception, no UE log, the
# server just never comes up. Verified 2026-07-09 on fresh Arch installs; the
# identical setup works on GE-Proton10-34. Do not bump to a GE-Proton 11.x
# build without testing a full cold start (success criterion: the
# "minidumps folder is set to /tmp/dumps" line followed by UE log output).
GE_PROTON_VERSION="${GE_PROTON_VERSION:-GE-Proton10-34}"
GE_PROTON_DIR="$BASE_DIR/proton"
GE_PROTON_PATH="$GE_PROTON_DIR/$GE_PROTON_VERSION"
GE_PROTON_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$GE_PROTON_VERSION/$GE_PROTON_VERSION.tar.gz"
# PROTONPATH now points at the concrete build directory (overridable via env).
UMU_PROTONPATH="${UMU_PROTONPATH:-$GE_PROTON_PATH}"

# Define URL for SteamCMD.
STEAMCMD_URL="https://steamcdn-a.akamaihd.net/client/installer/steamcmd_linux.tar.gz"

check_dependencies() {
    local missing=()
    local package_manager=""
    local dependencies=()
    local config_file="$BASE_DIR/.ark_server_manager_config"

    # Detect the package manager
    # umu-launcher zipapp is self-contained for Proton/Wine (ships Steam Linux Runtime).
    # However, SteamCMD is a standalone 32-bit ELF binary requiring the host's 32-bit
    # dynamic linker (/lib/ld-linux.so.2). Without i386 multilib the kernel returns
    # ENOENT for the binary even though the file exists on disk.
    # Required at the host level:
    #   - 32-bit glibc : SteamCMD is a 32-bit ELF binary (libc, libdl, libm,
    #     libpthread, librt). Without i386 multilib the kernel cannot execute
    #     it (returns ENOENT even though the file exists).
    #   - wget/tar : download umu-launcher zipapp + steamcmd + GE-Proton
    #   - python3 (>= 3.10) : run the umu-launcher zipapp
    #   - libzstd1/libzstd.so.1 : umu uses pyzstd which links against system libzstd
    #   - pkill (procps) : process management
    #   - cron : scheduled restarts
    if command -v apt-get >/dev/null 2>&1; then
        package_manager="apt-get"
        dependencies=("wget" "tar" "grep" "python3" "libzstd1" "libc6:i386" "pkill" "cron")
    elif command -v zypper >/dev/null 2>&1; then
        package_manager="zypper"
        dependencies=("wget" "tar" "grep" "python3" "libzstd1" "glibc-32bit" "pkill" "cron")
    elif command -v dnf >/dev/null 2>&1; then
        package_manager="dnf"
        dependencies=("wget" "tar" "grep" "python3" "libzstd" "glibc.i686" "procps-ng" "cronie")
    elif command -v pacman >/dev/null 2>&1; then
        package_manager="pacman"
        dependencies=("wget" "tar" "grep" "python" "zstd" "cronie" "lib32-glibc")
    else
        echo -e "${RED}Error: No supported package manager found on this system.${RESET}"
        exit 1
    fi

    # Check for missing dependencies
    for cmd in "${dependencies[@]}"; do
        if [ "$package_manager" == "apt-get" ]; then
            # Library packages -- check with dpkg, since they don't expose a command
            if [[ "$cmd" == lib* ]]; then
                if ! dpkg-query -W -f='${Status}' "$cmd" 2>/dev/null | grep -q "install ok installed"; then
                    missing+=("$cmd")
                fi
            elif [ "$cmd" == "pkill" ]; then
                if ! command -v pkill >/dev/null 2>&1; then
                    missing+=("procps")
                fi
            else
                if ! command -v "${cmd}" >/dev/null 2>&1; then
                    missing+=("$cmd")
                fi
            fi
        elif [ "$package_manager" == "zypper" ] || [ "$package_manager" == "dnf" ]; then
            if ! rpm -q "${cmd}" >/dev/null 2>&1 && ! command -v "${cmd}" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        elif [ "$package_manager" == "pacman" ]; then
            if ! pacman -Qi "${cmd}" >/dev/null 2>&1 && ! ldconfig -p | grep -q "${cmd}"; then
                missing+=("$cmd")
            fi
        elif [ "$cmd" == "pkill" ]; then
            if ! command -v pkill >/dev/null 2>&1; then
                missing+=("procps")
            fi
        else
            if ! command -v "${cmd}" >/dev/null 2>&1; then
                missing+=("$cmd")
            fi
        fi
    done

    # Verify python3 is >= 3.10 (required by umu-launcher zipapp).
    # We check this only if python3 itself is present -- otherwise it'll already
    # be in the missing list above.
    if command -v python3 >/dev/null 2>&1; then
        local py_ok
        py_ok=$(python3 -c 'import sys; print("ok" if sys.version_info >= (3, 10) else "old")' 2>/dev/null)
        if [ "$py_ok" != "ok" ]; then
            local py_ver
            py_ver=$(python3 --version 2>&1)
            echo -e "${RED}Error: umu-launcher requires Python >= 3.10, but found: $py_ver${RESET}"
            echo -e "${YELLOW}Please update Python on your system. On older distros you may need a backports repo.${RESET}"
            exit 1
        fi
    fi

    # Report missing dependencies and ask to continue
    if [ ${#missing[@]} -ne 0 ]; then
        # Check if the user has chosen to suppress warnings
        if [ -f "$config_file" ] && grep -q "SUPPRESS_DEPENDENCY_WARNINGS=true" "$config_file"; then
            echo -e "${YELLOW}Continuing despite missing dependencies (warnings suppressed)...${RESET}"
            return
        fi

        echo -e "${RED}Warning: The following required packages are missing: ${missing[*]}${RESET}"
        echo -e "${CYAN}Please install them using the appropriate command for your system:${RESET}"
        case $package_manager in
            "apt-get")
                echo -e "${MAGENTA}sudo dpkg --add-architecture i386${RESET}"
                echo -e "${MAGENTA}sudo apt update${RESET}"
                echo -e "${MAGENTA}sudo apt-get install ${YELLOW}${missing[*]}${RESET}"
                ;;
            "zypper")
                echo -e "${MAGENTA}sudo zypper install ${YELLOW}${missing[*]}${RESET}"
                ;;
            "dnf")
                echo -e "${MAGENTA}sudo dnf install ${YELLOW}${missing[*]}${RESET}"
                ;;
            "pacman")
                echo -e "${BLUE}For Arch Linux users:${RESET}"
                echo -e "${CYAN}1. Edit the pacman configuration file:${RESET}"
                echo -e "   ${MAGENTA}sudo nano /etc/pacman.conf${RESET}"
                echo
                echo -e "${CYAN}2. Find and uncomment the following lines to enable the multilib repository:${RESET}"
                echo -e "   ${GREEN}[multilib]${RESET}"
                echo -e "   ${GREEN}Include = /etc/pacman.d/mirrorlist${RESET}"
                echo
                echo -e "${CYAN}3. Save the file and exit the editor${RESET}"
                echo
                echo -e "${CYAN}4. Update the package database:${RESET}"
                echo -e "   ${MAGENTA}sudo pacman -Sy${RESET}"
                echo
                echo -e "${CYAN}5. Install the missing packages:${RESET}"
                echo -e "   ${MAGENTA}sudo pacman -S ${YELLOW}${missing[*]}${RESET}"
                ;;
        esac

        echo -e "\n"
        echo -e "${YELLOW}Continue anyway?${RESET} ${RED}(not recommended)${RESET} ${YELLOW}[y/N]${RESET}"
        read -r response
        if [[ ! $response =~ ^[Yy]$ ]]; then
            echo -e "${RED}Exiting due to missing dependencies.${RESET}"
            exit 1
        fi

        echo
        echo -e "${YELLOW}Do you want to suppress this warning in the future? [y/N]${RESET}"
        read -r suppress_response
        if [[ $suppress_response =~ ^[Yy]$ ]]; then
            echo "SUPPRESS_DEPENDENCY_WARNINGS=true" >> "$config_file"
            echo -e "${GREEN}Dependency warnings will be suppressed in future runs.${RESET}"
        fi

        echo -e "${YELLOW}Continuing despite missing dependencies...${RESET}"
    fi
}

# Ubuntu 23.10+ (and derivatives) restrict unprivileged user namespace creation
# via AppArmor (kernel.apparmor_restrict_unprivileged_userns=1). The Steam Linux
# Runtime container is built by pressure-vessel's *bundled* bwrap binary, which
# lives under ~/.local/share/umu/ -- a path no shipped AppArmor profile covers.
# Result: every umu/Proton launch dies with
#   "bwrap: setting up uid map: Permission denied".
# A per-binary AppArmor profile is impractical here (the bwrap path changes with
# runtime updates), so the supported fix is the sysctl below, which restores the
# upstream kernel default that Arch/Fedora/Debian use anyway. Arch and most
# other distros are unaffected (the sysctl does not exist there -> check is a
# silent no-op).
check_userns_restriction() {
    local restricted
    restricted="$(sysctl -n kernel.apparmor_restrict_unprivileged_userns 2>/dev/null)" || return 0
    if [ "$restricted" = "1" ]; then
        echo -e "${RED}Error: this system restricts unprivileged user namespaces (Ubuntu AppArmor hardening).${RESET}"
        echo -e "${YELLOW}The Steam Linux Runtime container cannot start under this restriction; server${RESET}"
        echo -e "${YELLOW}launches will fail with 'bwrap: setting up uid map: Permission denied'.${RESET}"
        echo
        echo -e "${CYAN}Fix (apply now + persist across reboots):${RESET}"
        echo "    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
        echo "    echo 'kernel.apparmor_restrict_unprivileged_userns = 0' | sudo tee /etc/sysctl.d/99-umu-userns.conf"
        echo
        echo -e "${CYAN}Then re-run this script. (This restores the upstream kernel default used by Arch, Fedora and Debian.)${RESET}"
        exit 1
    fi
}

# Check dependencies before proceeding
check_dependencies
check_userns_restriction

# Function to check if required scripts are executable
check_executables() {
    local required_files=("$RCON_SCRIPT" "$ARK_RESTART_MANAGER" "$ARK_INSTANCE_MANAGER")
    for file in "${required_files[@]}"; do
        if [ ! -x "$file" ]; then
            echo -e "${RED}Error: Required file '$file' is not executable.${RESET}"
            echo -e "${CYAN}Run 'chmod +x $file' to fix this issue.${RESET}"
            exit 1
        fi
    done
}

# Call the function at the start of the script
check_executables

#Sets up a symlink
setup_symlink() {
    # Target directory for the symlink
    local target_dir="$HOME/.local/bin"
    # Name under which the script can be invoked
    local script_name="asa-manager"

    # Check if the target directory exists
    if [ ! -d "$target_dir" ]; then
        echo -e "Creating directory $target_dir..."
        mkdir -p "$target_dir" || {
            echo -e "Error: Could not create directory $target_dir."
            exit 1
        }
    fi

    # Create or update the symlink
    echo -e "Creating or updating the symlink $target_dir/$script_name..."
    ln -sf "$(realpath "$0")" "$target_dir/$script_name" || {
        echo -e "Error: Could not create symlink."
        exit 1
    }

    # Check if $HOME/.local/bin is in the PATH
    if [[ ":$PATH:" != *":$target_dir:"* ]]; then
        echo -e "Adding $target_dir to PATH..."
        echo 'export PATH=$PATH:$HOME/.local/bin' >> "$HOME/.bashrc"
        echo "The change will take effect after restarting the shell or running 'source ~/.bashrc'."
    fi

    echo -e "Setup completed. You can now run the script using 'asa-manager'."
}


# This function searches all instance_config.ini files in the $INSTANCES_DIR folder
# and collects the ports into arrays
check_for_duplicate_ports() {
    declare -A port_occurrences
    declare -A rcon_occurrences
    declare -A query_occurrences

    local duplicates_found=false

    # Iterate over all instance folders
    for instance_dir in "$INSTANCES_DIR"/*; do
        if [ -d "$instance_dir" ]; then
            local config_file="$instance_dir/instance_config.ini"
            if [ -f "$config_file" ]; then
                local instance_name
                instance_name=$(basename "$instance_dir")

                # Extract ports from the config
                local game_port rcon_port query_port
                game_port=$(grep -E "^Port=" "$config_file" | cut -d= -f2- | xargs)
                rcon_port=$(grep -E "^RCONPort=" "$config_file" | cut -d= -f2- | xargs)
                query_port=$(grep -E "^QueryPort=" "$config_file" | cut -d= -f2- | xargs)

                # Ignore entries if they are empty
                [ -z "$game_port" ] && game_port="NULL"
                [ -z "$rcon_port" ] && rcon_port="NULL"
                [ -z "$query_port" ] && query_port="NULL"

                # Check for conflicts
                if [ "$game_port" != "NULL" ]; then
                    if [ -n "${port_occurrences[$game_port]}" ]; then
                        echo -e "${RED}Conflict: Game port $game_port is used by both '${port_occurrences[$game_port]}' and '$instance_name'.${RESET}"
                        duplicates_found=true
                    else
                        port_occurrences[$game_port]="$instance_name"
                    fi
                fi

                if [ "$rcon_port" != "NULL" ]; then
                    if [ -n "${rcon_occurrences[$rcon_port]}" ]; then
                        echo -e "${RED}Conflict: RCON port $rcon_port is used by both '${rcon_occurrences[$rcon_port]}' and '$instance_name'.${RESET}"
                        duplicates_found=true
                    else
                        rcon_occurrences[$rcon_port]="$instance_name"
                    fi
                fi

                if [ "$query_port" != "NULL" ]; then
                    if [ -n "${query_occurrences[$query_port]}" ]; then
                        echo -e "${RED}Conflict: Query port $query_port is used by both '${query_occurrences[$query_port]}' and '$instance_name'.${RESET}"
                        duplicates_found=true
                    else
                        query_occurrences[$query_port]="$instance_name"
                    fi
                fi
            fi
        fi
    done

    if [ "$duplicates_found" = true ]; then
        echo -e "${RED}Port duplicates were found. Please correct the ports in the instance_config.ini files.${RESET}"
        return 1
    else
        echo -e "${GREEN}No duplicate ports found.${RESET}"
        return 0
    fi
}
# Function to check if a server is running
is_server_running() {
    local instance=$1
    load_instance_config "$instance" || return 1
    if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
        return 0
    else
        return 1
    fi
}

# Function to install or update the base server
install_base_server() {
    local running_instances=0

    set +e

    # Iterate over all instance directories to check if any instance is running
    for instance in "$INSTANCES_DIR"/*; do
        if [ -d "$instance" ]; then
            local instance_name=$(basename "$instance")
            if is_server_running "$instance_name"; then
                echo -e "${RED}Instance '$instance_name' is currently running. Please stop all instances before updating the base server.${RESET}"
                ((running_instances++))
            fi
        fi
    done

    set -e

    # Check if any instances were running
    if [ "$running_instances" -gt 0 ]; then
        echo -e "${YELLOW}Base server update skipped because $running_instances instance(s) are running.${RESET}"
        return 0
    fi

    echo -e "${CYAN}Installing/updating base server...${RESET}"

    # Create necessary directories
    mkdir -p "$STEAMCMD_DIR" "$SERVER_FILES_DIR" "$UMU_DIR" "$UMU_PREFIX_DIR"

    # Download and unpack SteamCMD if not already installed
    if [ ! -f "$STEAMCMD_DIR/steamcmd.sh" ]; then
        echo -e "${CYAN}Downloading SteamCMD...${RESET}"
        wget -q -O "$STEAMCMD_DIR/steamcmd_linux.tar.gz" "$STEAMCMD_URL"
        tar -xzf "$STEAMCMD_DIR/steamcmd_linux.tar.gz" -C "$STEAMCMD_DIR"
        rm "$STEAMCMD_DIR/steamcmd_linux.tar.gz"
    else
        echo -e "${GREEN}SteamCMD already installed.${RESET}"
    fi

    # Download and unpack umu-launcher zipapp if not already installed.
    # The zipapp is a single self-contained Python archive that works on any
    # distribution with python3 >= 3.10 -- no distro packages needed.
    # umu-launcher itself downloads and manages the Steam Linux Runtime and
    # GE-Proton on first run (when PROTONPATH=GE-Proton is set).
    if [ ! -x "$UMU_RUN_BIN" ]; then
        echo -e "${CYAN}Downloading umu-launcher zipapp ($UMU_VERSION)...${RESET}"
        mkdir -p "$UMU_DIR"
        local umu_tar="$UMU_DIR/umu-launcher-$UMU_VERSION-zipapp.tar"
        wget -q -O "$umu_tar" "$UMU_URL"
        # The tar contains an `umu/` directory; we extract its contents into UMU_DIR.
        tar -xf "$umu_tar" -C "$UMU_DIR" --strip-components=1
        rm "$umu_tar"
        chmod +x "$UMU_RUN_BIN"
        echo -e "${GREEN}umu-launcher installed at $UMU_DIR.${RESET}"
    else
        echo -e "${GREEN}umu-launcher already installed.${RESET}"
    fi

    # Download the pinned GE-Proton build if not already present. We fetch it
    # ourselves from the release download URL (not the GitHub API) so umu never
    # has to resolve the "GE-Proton" alias online -- see the comment block near
    # the GE_PROTON_* definitions for why the alias path is unreliable.
    if [ ! -x "$GE_PROTON_PATH/proton" ]; then
        echo -e "${CYAN}Downloading $GE_PROTON_VERSION (~450 MB, may take several minutes)...${RESET}"
        mkdir -p "$GE_PROTON_DIR"
        local ge_tar="$GE_PROTON_DIR/$GE_PROTON_VERSION.tar.gz"
        if ! wget -q -O "$ge_tar" "$GE_PROTON_URL"; then
            rm -f "$ge_tar"
            echo -e "${RED}Error: failed to download $GE_PROTON_VERSION from:${RESET}"
            echo -e "${YELLOW}  $GE_PROTON_URL${RESET}"
            echo -e "${CYAN}Check your network connection, or set GE_PROTON_VERSION to a build that exists.${RESET}"
            exit 1
        fi
        # The tarball contains a top-level GE-ProtonXX-Y/ directory, so a plain
        # extract into $GE_PROTON_DIR yields $GE_PROTON_DIR/$GE_PROTON_VERSION.
        if ! tar -xzf "$ge_tar" -C "$GE_PROTON_DIR"; then
            rm -f "$ge_tar"
            echo -e "${RED}Error: extraction of $GE_PROTON_VERSION failed (corrupt download?).${RESET}"
            exit 1
        fi
        rm -f "$ge_tar"
        if [ ! -x "$GE_PROTON_PATH/proton" ]; then
            echo -e "${RED}Error: $GE_PROTON_VERSION extracted but $GE_PROTON_PATH/proton is missing.${RESET}"
            echo -e "${YELLOW}The archive layout may have changed; check $GE_PROTON_DIR.${RESET}"
            exit 1
        fi
        echo -e "${GREEN}$GE_PROTON_VERSION installed at $GE_PROTON_PATH.${RESET}"
    else
        echo -e "${GREEN}$GE_PROTON_VERSION already installed.${RESET}"
    fi

    # Pre-fetch the Steam Linux Runtime via a real umu invocation. Without this,
    # the first real server start would block on the runtime download -- which
    # can take several minutes and would race with the initial-config-generation
    # logic below. We deliberately do NOT use `umu-run --help` here: on umu 1.4.0
    # --help exits before the runtime layer is resolved/downloaded, so it no
    # longer triggers the fetch (this is exactly what left users with a missing
    # steamrt4/toolmanifest.vdf). `wineboot --init` runs through the full runtime
    # layer and thus reliably pulls the runtime. It also doubles as the Wine
    # prefix warm-up below, so the two former steps are merged into one.
    #
    # The Wine prefix must match the Proton generation that created it. A
    # prefix initialized by Wine 11 (GE-Proton11-x) must not be reused with
    # Wine 10 (GE-Proton10-x) -- Wine downgrades on an existing prefix are
    # unsupported and cause subtle breakage. We record which GE-Proton build
    # created the prefix in a marker file; on mismatch (or if the marker is
    # missing, i.e. the prefix predates this mechanism and its provenance is
    # unknown -- which includes every prefix created by the briefly-pinned,
    # ASA-incompatible GE-Proton11-1), the prefix is moved aside and recreated.
    # Recreating costs ~1 minute and loses nothing: all server data (configs,
    # saves) lives under server-files/, not in the prefix.
    local prefix_marker="$UMU_PREFIX_DIR/.created-by-proton"
    if [ -f "$UMU_PREFIX_DIR/system.reg" ]; then
        local prefix_proton=""
        [ -f "$prefix_marker" ] && prefix_proton="$(cat "$prefix_marker" 2>/dev/null)"
        if [ "$prefix_proton" != "$GE_PROTON_VERSION" ]; then
            local prefix_backup="${UMU_PREFIX_DIR}.bak-${prefix_proton:-unknown}"
            echo -e "${YELLOW}Existing Wine prefix was created by '${prefix_proton:-an unknown Proton build}', current is $GE_PROTON_VERSION.${RESET}"
            echo -e "${CYAN}Moving it to $prefix_backup and creating a fresh prefix...${RESET}"
            rm -rf "$prefix_backup"
            mv "$UMU_PREFIX_DIR" "$prefix_backup"
            mkdir -p "$UMU_PREFIX_DIR"
        fi
    fi

    # Runtime check: the required Steam Linux Runtime depends on the Proton
    # generation (GE-Proton 9/10 -> steamrt3 "sniper", GE-Proton 11 -> steamrt4),
    # so a present steamrt4 must not mask a missing steamrt3 after a downgrade
    # (and vice versa). Unknown/future generations fall back to accepting any
    # installed runtime and letting umu sort it out during the warm-up run.
    local umu_share="$HOME/.local/share/umu"
    local required_runtime_glob="steamrt*"
    case "$GE_PROTON_VERSION" in
        GE-Proton9-*|GE-Proton10-*) required_runtime_glob="steamrt3" ;;
        GE-Proton11-*)              required_runtime_glob="steamrt4" ;;
    esac
    local prefix_ready=1
    [ -f "$UMU_PREFIX_DIR/system.reg" ] && [ -d "$UMU_PREFIX_DIR/drive_c/windows/system32" ] || prefix_ready=0
    local runtime_ready=0
    if compgen -G "$umu_share/$required_runtime_glob/toolmanifest.vdf" >/dev/null 2>&1; then
        runtime_ready=1
    fi

    if [ "$runtime_ready" -eq 0 ] || [ "$prefix_ready" -eq 0 ]; then
        echo -e "${CYAN}First-time umu setup: downloading Steam Linux Runtime and initializing Wine prefix (may take several minutes)...${RESET}"
        echo -e "${YELLOW}You will see progress messages from umu below.${RESET}"
        # wineboot --init forces: (a) runtime download via the full umu layer,
        # (b) Wine prefix creation (drive_c, registry hives, built-in DLL
        # registration, fonts). Doing this synchronously here prevents ARK from
        # firing against a half-initialized prefix during the config-gen start
        # below (the classic "crashes silently for 10 minutes then works").
        #
        # Deliberately NO UMU_RUNTIME_UPDATE=0 on this one invocation: this is
        # the run that must be able to fetch a missing runtime. After a Proton
        # downgrade (11.x -> 10.x) the box may have steamrt4 but not steamrt3;
        # with updates disabled umu would not pull the missing one. All regular
        # server starts keep UMU_RUNTIME_UPDATE=0 -- by then the runtime is
        # guaranteed present.
        WINEPREFIX="$UMU_PREFIX_DIR" \
        GAMEID="$UMU_GAMEID" \
        PROTONPATH="$UMU_PROTONPATH" \
            "$UMU_RUN_BIN" wineboot --init >/dev/null 2>&1 || true
        # wineserver may not be on PATH (umu's wine binary is sandboxed), so we
        # poll until no wineserver instance is holding the prefix, with a
        # fixed-timeout fallback to avoid hanging forever.
        local waited=0
        while [ "$waited" -lt 90 ]; do
            if ! pgrep -f "wineserver.*$UMU_PREFIX_DIR" >/dev/null 2>&1; then
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done
        echo -e "${GREEN}umu runtime and Wine prefix ready.${RESET}"
    fi

    # Record which Proton build owns this prefix (see migration logic above).
    echo "$GE_PROTON_VERSION" > "$UMU_PREFIX_DIR/.created-by-proton"

    # Install or update ARK server using SteamCMD
    echo -e "${CYAN}Installing/updating ARK server...${RESET}"
    "$STEAMCMD_DIR/steamcmd.sh" +force_install_dir "$SERVER_FILES_DIR" +login anonymous +app_update 2430930 validate +quit

    # ------------------------------------------------------------------
    # ASA-on-Wine 10 compatibility fixes (idempotent -- safe to re-run).
    # Required since the GE-Proton 10 / Wine 10 stack:
    #
    #   1. Disable the Sentry crash-reporter plugin. ASA ships a sentry-native
    #      crashpad backend that reads StackLimit/StackBase from Wine's TEB.
    #      Wine 10 returns huge values there, so crashpad attempts to dump
    #      gigabytes of stack and the engine never proceeds past sentry_init.
    #      Renaming the plugin folder makes the engine skip loading it and
    #      sentry_init() fails cleanly with "invalid handler_path" -- engine
    #      then continues normally.
    #
    #   2. Place a steam_appid.txt next to ArkAscendedServer.exe. lsteamclient.dll
    #      reads this to identify itself to the Steam SDK without a running
    #      Steam client. AppID 2430930 = ARK: Survival Ascended.
    #
    #   3. Symlink SteamCMD's bundled steamclient.so into $HOME/.steam/sdk{32,64}/.
    #      Wine's lsteamclient.dll dlopen()'s these exact paths to bridge to the
    #      native Steam SDK. Without them, server crashes inside
    #      FSteamServerInstanceHandler with a stack trace through lsteamclient.dll.
    # ------------------------------------------------------------------
    local plugins_dir="$SERVER_FILES_DIR/ShooterGame/Plugins"
    if [ -d "$plugins_dir/sentry" ]; then
        echo -e "${CYAN}Disabling Sentry crashpad plugin (incompatible with Wine 10)...${RESET}"
        # If a previous .disabled directory exists (e.g. SteamCMD validate
        # re-downloaded the plugin while a stale .disabled was still around),
        # remove it first so mv doesn't fail under `set -e`.
        rm -rf "$plugins_dir/sentry.disabled"
        mv "$plugins_dir/sentry" "$plugins_dir/sentry.disabled"
        echo -e "${GREEN}Sentry plugin renamed to sentry.disabled.${RESET}"
    elif [ -d "$plugins_dir/sentry.disabled" ]; then
        echo -e "${GREEN}Sentry plugin already disabled.${RESET}"
    fi

    # Compare content, not just existence: older script versions wrote the
    # *game* AppID (2399830) here, and a stale file would otherwise never be
    # corrected. lsteamclient needs the *dedicated server* AppID (2430930).
    local win64_dir="$SERVER_FILES_DIR/ShooterGame/Binaries/Win64"
    if [ -d "$win64_dir" ] && [ "$(cat "$win64_dir/steam_appid.txt" 2>/dev/null)" != "2430930" ]; then
        echo "2430930" > "$win64_dir/steam_appid.txt"
        echo -e "${GREEN}Wrote steam_appid.txt (AppID 2430930).${RESET}"
    fi

    # Steam SDK symlinks. Use $HOME because lsteamclient.dll resolves them
    # via the runtime user's home directory, regardless of WINEPREFIX.
    local steam_sdk32="$HOME/.steam/sdk32"
    local steam_sdk64="$HOME/.steam/sdk64"
    local steamcmd_so32="$STEAMCMD_DIR/linux32/steamclient.so"
    local steamcmd_so64="$STEAMCMD_DIR/linux64/steamclient.so"
    if [ -f "$steamcmd_so32" ] && [ -f "$steamcmd_so64" ]; then
        mkdir -p "$steam_sdk32" "$steam_sdk64"
        # -f forces overwrite so a stale symlink (e.g. from a previous BASE_DIR)
        # gets refreshed to point at the current install.
        ln -sf "$steamcmd_so32" "$steam_sdk32/steamclient.so"
        ln -sf "$steamcmd_so64" "$steam_sdk64/steamclient.so"
        echo -e "${GREEN}Steam SDK symlinks in place ($steam_sdk32, $steam_sdk64).${RESET}"
    else
        echo -e "${YELLOW}Warning: SteamCMD steamclient.so not found at expected paths -- the server may fail to start.${RESET}"
    fi
    # ------------------------------------------------------------------

    # Check if configuration directory exists
    if [ ! -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/" ]; then
        echo -e "${CYAN}First installation detected. Generating initial server configuration via umu-launcher...${RESET}"
        echo -e "${CYAN}Starting server once to generate configuration files...${RESET}"

        # Log the initial bootstrap so failures are diagnosable instead of silent.
        local init_log="$BASE_DIR/initial-setup.log"

        # Initial server start to generate configs -- via umu-run
        WINEPREFIX="$UMU_PREFIX_DIR" \
        GAMEID="$UMU_GAMEID" \
        PROTONPATH="$UMU_PROTONPATH" \
        UMU_RUNTIME_UPDATE=0 \
            "$UMU_RUN_BIN" "$SERVER_FILES_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" \
            "TheIsland_WP?listen" \
            -NoBattlEye \
            -crossplay \
            -server \
            -log \
            -game \
            > "$init_log" 2>&1 &
        local init_pid=$!

        # Wait actively until the config directory appears, instead of a fixed sleep.
        # ARK generates the config dir within ~30-60s of a successful boot.
        local waited=0
        local timeout=180
        while [ "$waited" -lt "$timeout" ]; do
            if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/" ]; then
                echo -e "${GREEN}Initial config directory created after ${waited}s.${RESET}"
                # Let it run another 20s to make sure all default INIs are written.
                sleep 20
                break
            fi
            # Bail out early if the umu/server process died -- something is wrong,
            # and we shouldn't waste time waiting for files that will never appear.
            if ! kill -0 "$init_pid" 2>/dev/null && ! pgrep -f "ArkAscendedServer.exe" > /dev/null; then
                echo -e "${RED}Initial server process exited prematurely. See $init_log for details.${RESET}"
                tail -n 30 "$init_log" || true
                return 1
            fi
            sleep 5
            waited=$((waited + 5))
        done

        if [ "$waited" -ge "$timeout" ]; then
            echo -e "${YELLOW}Timeout waiting for config files. Check $init_log -- the server may still be starting.${RESET}"
        fi

        # Stop the server
        pkill -f "ArkAscendedServer.exe.*TheIsland_WP" || true
        # Give umu/proton time to clean up
        sleep 5
        echo -e "${GREEN}Initial server start completed.${RESET}"
    else
        echo -e "${GREEN}Server configuration directory already exists. Skipping initial server start.${RESET}"
    fi

    echo -e "${GREEN}Base server installation/update completed.${RESET}"
}

# Function to initialize Proton prefix (kept as no-op stub for backwards compatibility
# with existing menu/instance creation code paths -- umu-launcher initializes its own
# prefix automatically on first run, so nothing to do here).
initialize_proton_prefix() {
    # umu-launcher creates and manages WINEPREFIX itself on first run.
    # We just make sure the directory exists so umu has a place to write.
    mkdir -p "$UMU_PREFIX_DIR"
    echo -e "${GREEN}umu-launcher will initialize its prefix on first server start.${RESET}"
}

# Function to populate an array with available instances from INSTANCES_DIR
get_available_instances() {
    # Clear the array to avoid stale entries
    available_instances=()

    if [ -d "$INSTANCES_DIR" ]; then
        # Read all directories (one per line) into the array
        mapfile -t available_instances < <(ls -1 "$INSTANCES_DIR" 2>/dev/null)
    fi
}

# Function to list all instances
list_instances() {
    # Reuse the helper function
    get_available_instances

    if [ ${#available_instances[@]} -eq 0 ]; then
        echo -e "${RED}No instances found in '$INSTANCES_DIR'.${RESET}"
        return
    fi

    echo -e "${YELLOW}Available instances:${RESET}"
    for inst in "${available_instances[@]}"; do
        echo "$inst"
    done
}

# Function to create or edit instance configuration
edit_instance_config() {
    local instance=$1
    local config_file="$INSTANCES_DIR/$instance/instance_config.ini"
    local game_ini_file="$INSTANCES_DIR/$instance/Config/Game.ini"

    # Create instance directory if it doesn't exist
    if [ ! -d "$INSTANCES_DIR/$instance" ]; then
        mkdir -p "$INSTANCES_DIR/$instance"
    fi

      # Create the Config directory if it doesn't exist
    if [ ! -d "$INSTANCES_DIR/$instance/Config" ]; then
        mkdir -p "$INSTANCES_DIR/$instance/Config"
    fi

    # Create config file if it doesn't exist
    if [ ! -f "$config_file" ]; then
        cat <<EOF > "$config_file"
[ServerSettings]
ServerName=ARK Server $instance
ServerPassword=
ServerAdminPassword=adminpassword
MaxPlayers=70
MapName=TheIsland_WP
RCONPort=27020
QueryPort=27015
Port=7777
ModIDs=
CustomStartParameters=-NoBattlEye -crossplay -NoHangDetection
#When changing SaveDir, make sure to give it a unique name, as this can otherwise affect the stop server function.
#Do not use umlauts, spaces, or special characters.
SaveDir=$instance
ClusterID=
EOF
        chmod 600 "$config_file"  # Set file permissions to be owner-readable and writable
    fi

     # Create an empty Game.ini, if it doesnt exist
    if [ ! -f "$game_ini_file" ]; then
        touch "$game_ini_file"
        echo -e "${GREEN}Empty Game.ini for '$instance' Created. Optional: Edit it for your needs${RESET}"
    fi

    # Open the config file in the default text editor
    if [ -n "$EDITOR" ]; then
        "$EDITOR" "$config_file"
    elif command -v nano >/dev/null 2>&1; then
        nano "$config_file"
    elif command -v vim >/dev/null 2>&1; then
        vim "$config_file"
    else
        echo -e "${RED}No suitable text editor found. Please edit $config_file manually.${RESET}"
    fi
}

# Function to load instance configuration
load_instance_config() {
    local instance=$1
    local config_file="$INSTANCES_DIR/$instance/instance_config.ini"

    if [ ! -f "$config_file" ]; then
        echo -e "${RED}Configuration file for instance $instance not found.${RESET}"
        return 1
    fi

    # Read configuration into variables
    SERVER_NAME=$(grep -E '^ServerName=' "$config_file" | cut -d= -f2- | xargs)
    SERVER_PASSWORD=$(grep -E '^ServerPassword=' "$config_file" | cut -d= -f2- | xargs)
    ADMIN_PASSWORD=$(grep -E '^ServerAdminPassword=' "$config_file" | cut -d= -f2- | xargs)
    MAX_PLAYERS=$(grep -E '^MaxPlayers=' "$config_file" | cut -d= -f2- | xargs)
    MAP_NAME=$(grep -E '^MapName=' "$config_file" | cut -d= -f2- | xargs)
    RCON_PORT=$(grep -E '^RCONPort=' "$config_file" | cut -d= -f2- | xargs)
    QUERY_PORT=$(grep -E '^QueryPort=' "$config_file" | cut -d= -f2- | xargs)
    GAME_PORT=$(grep -E '^Port=' "$config_file" | cut -d= -f2- | xargs)
    MOD_IDS=$(grep -E '^ModIDs=' "$config_file" | cut -d= -f2- | xargs)
    SAVE_DIR=$(grep -E '^SaveDir=' "$config_file" | cut -d= -f2- | xargs)
    CLUSTER_ID=$(grep -E '^ClusterID=' "$config_file" | cut -d= -f2- | xargs)
    CUSTOM_START_PARAMETERS=$(grep -E '^CustomStartParameters=' "$config_file" | cut -d= -f2- | xargs)

    return 0
}

# Function to create a new instance (using 'read' with validation)
create_instance() {
    # Check if the directory exists
    if [ ! -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/" ]; then
        echo -e "${RED}The required directory does not exist: $SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/${RESET}"
        echo -e "${YELLOW}Cannot proceed with instance creation.You need to install Base Server first${RESET}"
        return
    fi

    while true; do
        echo -e "${CYAN}Enter the name for the new instance (or type 'cancel' to abort):${RESET}"
        read -r instance_name
        if [ "$instance_name" = "cancel" ]; then
            echo -e "${YELLOW}Instance creation cancelled.${RESET}"
            return
        elif [ -z "$instance_name" ]; then
            echo -e "${RED}Instance name cannot be empty.${RESET}"
        elif [ -d "$INSTANCES_DIR/$instance_name" ]; then
            echo -e "${RED}Instance already exists.${RESET}"
        else
            mkdir -p "$INSTANCES_DIR/$instance_name"
            edit_instance_config "$instance_name"
            initialize_proton_prefix "$instance_name"
            echo -e "${GREEN}Instance $instance_name created and configured.${RESET}"
            return
        fi
    done
}

# Function to select an instance using 'select'
select_instance() {
    local instances=()
    local i=1

    # Populate the instances array
    for dir in "$INSTANCES_DIR"/*; do
        if [ -d "$dir" ]; then
            instances+=("$(basename "$dir")")
        fi
    done

    if [ ${#instances[@]} -eq 0 ]; then
        echo -e "${RED}No instances found.${RESET}"
        return 1
    fi

    echo -e "${YELLOW}Available instances:${RESET}"
    PS3="Please select an instance: "
    select selected_instance in "${instances[@]}" "Cancel"; do
        if [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "${#instances[@]}" ]; then
            echo -e "${GREEN}You have selected: $selected_instance${RESET}"
            return 0
        elif [ "$REPLY" -eq $((${#instances[@]} + 1)) ]; then
            echo -e "${YELLOW}Operation cancelled.${RESET}"
            return 1
        else
            echo -e "${RED}Invalid selection.${RESET}"
        fi
    done
}

# Function to start the server
start_server() {
    export PROTON_VERB=run

    local instance=$1
    # Check for duplicate ports
    if ! check_for_duplicate_ports; then
        echo -e "${YELLOW}Port conflicts detected. Server start aborted.${RESET}"
        return 1
    fi

    if is_server_running "$instance"; then
        echo -e "${YELLOW}Server for instance $instance is already running.${RESET}"
        return 0
    fi

    load_instance_config "$instance" || return 1

    echo -e "${CYAN}Starting server for instance: $instance${RESET}"

    # Ensure umu prefix dir exists -- umu-launcher creates / migrates its prefix
    # automatically on first run inside WINEPREFIX.
    mkdir -p "$UMU_PREFIX_DIR"

    # Ensure per-instance Config directory exists
    local instance_config_dir="$INSTANCES_DIR/$instance/Config"
    if [ ! -d "$instance_config_dir" ]; then
        mkdir -p "$instance_config_dir"
        cp -r "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer/." "$instance_config_dir/" || true
        # Set permissions for GameUserSettings.ini
        chmod 600 "$instance_config_dir/GameUserSettings.ini" || true
    fi

    # Backup the original Config directory if not already backed up
    if [ ! -L "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" ] && [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer.bak" || true
    fi

    # Link the instance Config directory
    rm -rf "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true
    ln -s "$instance_config_dir" "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true

    # Ensure per-instance save directory exists
    local save_dir="$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$SAVE_DIR"
    mkdir -p "$save_dir" || true

    # Set cluster parameters if ClusterID is set
    local cluster_params=()
    if [ -n "$CLUSTER_ID" ]; then
        # ARK appends "clusters/<ClusterId>/" to -ClusterDirOverride by itself,
        # so the override must be the manager's BASE directory -- NOT
        # $BASE_DIR/clusters (yields clusters/clusters/<id>/) and NOT
        # $BASE_DIR/clusters/<id> (yields clusters/<id>/clusters/<id>/).
        # Verified against issue #31: override Z:\...\lasasm\clusters produced
        # ~/lasasm/clusters/clusters/deers. Final on-disk location is therefore
        # $BASE_DIR/clusters/<ClusterId>/.
        local cluster_root="$BASE_DIR"
        mkdir -p "$BASE_DIR/clusters" || true
        # ArkAscendedServer.exe is a Windows binary: it needs a Windows path.
        # A raw unix path has no drive letter, so UE treats it as *relative*
        # and resolves it against the CWD -- producing duplicated paths like
        # /home/user/home/user/... and, worse, *different* cluster dirs for
        # instances launched from different CWDs (breaks character transfer).
        # Wine maps Z: to /, so convert /path/to/clusters -> Z:\path\to\clusters.
        local cluster_dir_win="Z:${cluster_root//\//\\}"
        # Built as an array, expanded quoted at the call site -- the previous
        # string-with-embedded-escaped-quotes construction passed literal
        # quote characters into the exe's argv.
        cluster_params=(-ClusterDirOverride="$cluster_dir_win" -ClusterId="$CLUSTER_ID")
    fi

    # Start the server using the loaded configuration variables

    # Adding a trailing space to the ServerName to avoid conflicts if the ServerName is identical to the instance name.
    # This ensures the server processes the name correctly, even though the space is invisible to users.
    local server_log="$INSTANCES_DIR/$instance/server.log"
    local shootergame_log="$SERVER_FILES_DIR/ShooterGame/Saved/Logs/ShooterGame.log"

    # Write the exact command that's about to run to the top of server.log.
    # This makes silent-exit cases diagnosable: you can always see what argv ARK got.
    {
        echo "=== ark_instance_manager.sh server launch ==="
        echo "Timestamp:   $(date -Iseconds)"
        echo "Instance:    $instance"
        echo "WINEPREFIX:  $UMU_PREFIX_DIR"
        echo "GAMEID:      $UMU_GAMEID"
        echo "PROTONPATH:  $UMU_PROTONPATH"
        echo "UMU_RUN_BIN: $UMU_RUN_BIN"
        echo "Command:"
        echo "  $UMU_RUN_BIN \\"
        echo "    $SERVER_FILES_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe \\"
        echo "    \"$MAP_NAME?listen?SessionName=$SERVER_NAME ?ServerPassword=$SERVER_PASSWORD?RCONEnabled=True?ServerAdminPassword=$ADMIN_PASSWORD?AltSaveDirectoryName=$SAVE_DIR\" \\"
        echo "    $CUSTOM_START_PARAMETERS \\"
        echo "    -WinLiveMaxPlayers=$MAX_PLAYERS -Port=$GAME_PORT -QueryPort=$QUERY_PORT -RCONPort=$RCON_PORT \\"
        echo "    -game ${cluster_params[*]} -server -log -mods=\"$MOD_IDS\""
        echo "=== launch output below ==="
        echo
    } > "$server_log"

    # Start the server fully detached from the shell session:
    #   - setsid puts the process in its own session and process group, so it
    #     no longer receives SIGHUP when the controlling terminal closes (e.g.
    #     when the user exits the script, closes their terminal window, or
    #     disconnects from SSH).
    #   - nohup additionally ignores SIGHUP at the process level as a belt-and-
    #     braces measure, and prevents tty access errors when stdin is closed.
    #   - </dev/null detaches stdin so the process never blocks on terminal I/O.
    #   - Background (&) returns control to the script.
    #   - `disown` (after the &) removes the job from Bash's tracking, so a
    #     subsequent shell exit doesn't try to clean it up.
    setsid nohup env \
        WINEPREFIX="$UMU_PREFIX_DIR" \
        GAMEID="$UMU_GAMEID" \
        PROTONPATH="$UMU_PROTONPATH" \
        UMU_RUNTIME_UPDATE=0 \
        "$UMU_RUN_BIN" "$SERVER_FILES_DIR/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" \
    "$MAP_NAME?listen?SessionName=$SERVER_NAME ?ServerPassword=$SERVER_PASSWORD?RCONEnabled=True?ServerAdminPassword=$ADMIN_PASSWORD?AltSaveDirectoryName=$SAVE_DIR" \
    $CUSTOM_START_PARAMETERS \
    -WinLiveMaxPlayers=$MAX_PLAYERS \
    -Port=$GAME_PORT \
    -QueryPort=$QUERY_PORT \
    -RCONPort=$RCON_PORT \
    -game \
    "${cluster_params[@]}" \
    -server \
    -log \
    -mods="$MOD_IDS" \
    </dev/null >> "$server_log" 2>&1 &
    local launcher_pid=$!
    disown "$launcher_pid" 2>/dev/null || true

    echo -e "${CYAN}Launcher PID: $launcher_pid (detached). Verifying server boot...${RESET}"

    # Health check: ARK on Wine needs ~10-20 seconds before ArkAscendedServer.exe
    # is visible in the process tree (umu sets up SLR container, then wine, then
    # the .exe). We wait up to 30s for the process to appear, then another 15s
    # to see if it stays alive. Silent exits show up here instead of being
    # discovered minutes later when the user notices the server isn't pingable.
    local found=0
    local waited=0
    while [ "$waited" -lt 30 ]; do
        if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" >/dev/null 2>&1; then
            found=1
            break
        fi
        # Launcher itself died before ARK even spawned -- usually a umu/wine error.
        if ! kill -0 "$launcher_pid" 2>/dev/null; then
            break
        fi
        sleep 2
        waited=$((waited + 2))
    done

    if [ "$found" -ne 1 ]; then
        echo -e "${RED}ArkAscendedServer.exe did not appear within 30 seconds.${RESET}"
        echo -e "${YELLOW}--- last 30 lines of $server_log ---${RESET}"
        tail -n 30 "$server_log" 2>/dev/null || echo "(server.log not readable)"
        echo -e "${YELLOW}--- end of server.log ---${RESET}"
        if [ -f "$shootergame_log" ]; then
            echo -e "${YELLOW}--- last 20 lines of ShooterGame.log ---${RESET}"
            tail -n 20 "$shootergame_log"
            echo -e "${YELLOW}--- end of ShooterGame.log ---${RESET}"
        fi
        echo -e "${RED}Server failed to start. Full logs: $server_log${RESET}"
        return 1
    fi

    # Process appeared. Watch for ~15s more to make sure it doesn't die during
    # early engine init (the "PrimalGameData then silent exit" failure mode).
    local stable_waited=0
    while [ "$stable_waited" -lt 15 ]; do
        if ! pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" >/dev/null 2>&1; then
            echo -e "${RED}ArkAscendedServer.exe exited during engine init after ${stable_waited}s.${RESET}"
            echo -e "${YELLOW}--- last 30 lines of server.log ---${RESET}"
            tail -n 30 "$server_log" 2>/dev/null
            if [ -f "$shootergame_log" ]; then
                echo -e "${YELLOW}--- last 40 lines of ShooterGame.log ---${RESET}"
                tail -n 40 "$shootergame_log"
            fi
            echo -e "${RED}Server crashed during boot. Full logs: $server_log + $shootergame_log${RESET}"
            return 1
        fi
        sleep 3
        stable_waited=$((stable_waited + 3))
    done

    echo -e "${GREEN}Server for instance '$instance' is running (took ${waited}s to spawn, stable for ${stable_waited}s).${RESET}"
    echo -e "${GREEN}Full boot to playable state usually takes 30-90 seconds more (map load).${RESET}"
}

# Function to stop the server
stop_server() {
    local instance="$1"

    if ! is_server_running "$instance"; then
        echo -e "${YELLOW}Server for instance $instance is not running.${RESET}"
        return 0
    fi

    load_instance_config "$instance" || return 1

    echo -e "${GREEN}Attempting graceful shutdown for instance $instance...${RESET}"

    # Send the "DoExit" command and capture the response
    local response
    response=$(send_rcon_command "$instance" "DoExit")

    # Check if the response matches "Exiting..."
    if [[ "$response" == "Exiting..." ]]; then
        echo -e "${GREEN}Server instance $instance reported 'Exiting...'. Awaiting shutdown...(That can take up to 2 minutes.)${RESET}"

        # Check in a loop if the process is still running
        local timeout=120  # Give 120 seconds
        local waited=0

        while pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; do
            sleep 2
            (( waited+=2 ))
            if [ $waited -ge $timeout ]; then
                echo -e "${RED}Server $instance didn't shut down within $timeout seconds. Forcing kill...${RESET}"
                pkill -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR"
                break
            fi
        done

        echo -e "${GREEN}Server for instance $instance has exited (or was force-killed).${RESET}"
        return 0
    else
        echo -e "${RED}Graceful shutdown failed or timed out. Forcing shutdown.${RESET}"
        pkill -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" || true
        echo -e "${GREEN}Server for instance $instance has been forcefully stopped.${RESET}"
        return 0
    fi
}

# Function to start RCON CLI
start_rcon_cli() {
    local instance=$1

    if ! is_server_running "$instance"; then
        echo -e "${YELLOW}Server for instance $instance is not running.${RESET}"
        return 0
    fi

    load_instance_config "$instance" || return 1

    echo -e "${CYAN}Starting RCON CLI for instance: $instance${RESET}"

    # Use the new RCON-Client
    "$RCON_SCRIPT" "localhost:$RCON_PORT" -p "$ADMIN_PASSWORD" || {
        echo -e "${RED}Failed to start RCON CLI for instance $instance.${RESET}"
        return 1
    }

    return 0
}

# Function to change map
change_map() {
    local instance=$1
    load_instance_config "$instance" || return 1
    echo -e "${CYAN}Current map: $MAP_NAME${RESET}"
    echo -e "${CYAN}Enter the new map name (or type 'cancel' to abort):${RESET}"
    read -r new_map_name
    if [[ "$new_map_name" == "cancel" ]]; then
        echo -e "${YELLOW}Map change aborted.${RESET}"
        return 0
    fi
    sed -i "s/MapName=.*/MapName=$new_map_name/" "$INSTANCES_DIR/$instance/instance_config.ini"
    echo -e "${GREEN}Map changed to $new_map_name. Restart the server for changes to take effect.${RESET}"
}

# Function to change mods
change_mods() {
    local instance=$1
    load_instance_config "$instance" || return 1
    echo -e "${CYAN}Current mods: $MOD_IDS${RESET}"
    echo -e "${CYAN}Enter the new mod IDs (comma-separated, or type 'cancel' to abort):${RESET}"
    read -r new_mod_ids
    if [[ "$new_mod_ids" == "cancel" ]]; then
        echo -e "${YELLOW}Mod change aborted.${RESET}"
        return 0
    fi
    sed -i "s/ModIDs=.*/ModIDs=$new_mod_ids/" "$INSTANCES_DIR/$instance/instance_config.ini"
    echo -e "${GREEN}Mods changed to $new_mod_ids. Restart the server for changes to take effect.${RESET}"
}

# Function to check server status
check_server_status() {
    local instance=$1
    load_instance_config "$instance" || return 1
    if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
        echo -e "${GREEN}Server for instance $instance is running.${RESET}"
    else
        echo -e "${RED}Server for instance $instance is not running.${RESET}"
    fi
}

# Function to start all instances with a delay between each
start_all_instances() {
    echo -e "${CYAN}Starting all server instances...${RESET}"
    for instance in "$INSTANCES_DIR"/*; do
        if [ -d "$instance" ]; then
            instance_name=$(basename "$instance")

            # Check if the server is already running
            if is_server_running "$instance_name"; then
                echo -e "${YELLOW}Instance $instance_name is already running. Skipping...${RESET}"
                continue
            fi

            # Attempt to start the server
            if start_server "$instance_name"; then
                # Only wait 30 seconds if the server started successfully
                echo -e "${YELLOW}Waiting 30 seconds before starting the next instance...${RESET}"
                sleep 30
            else
                echo -e "${RED}Server $instance_name could not be started due to conflicts or errors. Skipping wait time.${RESET}"
            fi
        fi
    done
    echo -e "${GREEN}All instances have been processed.${RESET}"
}

# Function to stop all instances
stop_all_instances() {
    echo -e "${CYAN}Stopping all server instances...${RESET}"
    for instance in "$INSTANCES_DIR"/*; do
        if [ -d "$instance" ]; then
            instance_name=$(basename "$instance")
            if ! is_server_running "$instance_name"; then
                echo -e "${YELLOW}Instance $instance_name is not running. Skipping...${RESET}"
                continue
            fi
            stop_server "$instance_name"
        fi
    done
    echo -e "${GREEN}All instances have been stopped.${RESET}"
}

# Function to send RCON command
send_rcon_command() {
    local instance=$1
    local command=$2

    if ! is_server_running "$instance"; then
        echo -e "${YELLOW}Server for instance $instance is not running. Cannot send RCON command.${RESET}"
        return 1
    fi

    load_instance_config "$instance" || return 1

    # Always use the silent mode of the RCON client
    local response
    response=$("$RCON_SCRIPT" "localhost:$RCON_PORT" -p "$ADMIN_PASSWORD" -c "$command" --silent 2>&1)

    # Check if the RCON command was successful
    if [ $? -ne 0 ]; then
        echo -e "${RED}Failed to send RCON command to instance $instance.${RESET}"
        return 1
    fi

    # Return the RCON response
    echo "$response"
    return 0
}

# Function to show running instances
show_running_instances() {
    echo -e "${CYAN}Checking running instances...${RESET}"
    local running_count=0
    for instance in "$INSTANCES_DIR"/*; do
        if [ -d "$instance" ]; then
            instance_name=$(basename "$instance")
            # Load instance configuration
            load_instance_config "$instance_name" || continue
            # Check if the server is running
            if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
                echo -e "${GREEN}$instance_name is running${RESET}"
                ((running_count++)) || true
            else
                echo -e "${RED}$instance_name is not running${RESET}"
            fi
        fi
    done
    if [ $running_count -eq 0 ]; then
        echo -e "${RED}No instances are currently running.${RESET}"
    else
        echo -e "${GREEN}Total running instances: $running_count${RESET}"
    fi
}

# Function to delete an instance
delete_instance() {
    local instance=$1
    if [ -z "$instance" ]; then
        if ! select_instance; then
            return
        fi
        instance=$selected_instance
    fi
    if [ -d "$INSTANCES_DIR/$instance" ]; then
        echo -e "${RED}Warning: This will permanently delete the instance '$instance' and all its data.${RESET}"
        echo "Type CONFIRM to delete the instance '$instance', or cancel to abort"
        read -p "> " response

        if [[ $response == "CONFIRM" ]]; then
            # Load instance config
            load_instance_config "$instance"
            # Stop instance if it's running
            if pgrep -f "ArkAscendedServer.exe.*AltSaveDirectoryName=$SAVE_DIR" > /dev/null; then
                echo -e "${CYAN}Stopping instance '$instance'...${RESET}"
                stop_server "$instance"
            fi
            # Check if other instances are running
            if pgrep -f "ArkAscendedServer.exe" > /dev/null; then
                echo -e "${YELLOW}Other instances are still running. Not removing the Config symlink to avoid affecting other servers.${RESET}"
            else
                # Remove the symlink and restore the original configuration directory
                rm -f "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true
                if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer.bak" ]; then
                    mv "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer.bak" "$SERVER_FILES_DIR/ShooterGame/Saved/Config/WindowsServer" || true
                fi
            fi
            # Deleting the instance directory and save games
            rm -rf "$INSTANCES_DIR/$instance" || true
            rm -rf "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" || true
            rm -rf "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" || true
            echo -e "${GREEN}Instance '$instance' has been deleted.${RESET}"
        elif [[ $response == "cancel" ]]; then
            echo -e "${YELLOW}Deletion cancelled.${RESET}"
        else
            echo -e "${YELLOW}Invalid response. Deletion cancelled.${RESET}"
        fi
    else
        echo -e "${RED}Instance '$instance' does not exist.${RESET}"
    fi
}

# Function to change instance name
change_instance_name() {
    local instance=$1
    load_instance_config "$instance" || return 1

    echo -e "${CYAN}Enter the new name for instance '$instance' (or type 'cancel' to abort):${RESET}"
    read -r new_instance_name

    # Validation
    if [ "$new_instance_name" = "cancel" ]; then
        echo -e "${YELLOW}Instance renaming cancelled.${RESET}"
        return
    elif [ -z "$new_instance_name" ]; then
        echo -e "${RED}Instance name cannot be empty.${RESET}"
        return 1
    elif [ -d "$INSTANCES_DIR/$new_instance_name" ]; then
        echo -e "${RED}An instance with the name '$new_instance_name' already exists.${RESET}"
        return 1
    fi

    # Stop the server if running
    if is_server_running "$instance"; then
        echo -e "${CYAN}Stopping running server for instance '$instance' before renaming...${RESET}"
        stop_server "$instance"
    fi

    # Rename instance directory
    mv "$INSTANCES_DIR/$instance" "$INSTANCES_DIR/$new_instance_name" || {
        echo -e "${RED}Failed to rename instance directory.${RESET}"
        return 1
    }

    # Rename save directories if they exist
    if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/$instance" "$SERVER_FILES_DIR/ShooterGame/Saved/$new_instance_name" || true
    fi

    if [ -d "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" ]; then
        mv "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$instance" "$SERVER_FILES_DIR/ShooterGame/Saved/SavedArks/$new_instance_name" || true
    fi

    # Update SaveDir in the instance configuration
    sed -i "s/^SaveDir=.*/SaveDir=$new_instance_name/" "$INSTANCES_DIR/$new_instance_name/instance_config.ini"

    echo -e "${GREEN}Instance renamed from '$instance' to '$new_instance_name'.${RESET}"
}

# Function to edit GameUserSettins.ini
edit_gameusersettings() {
    local instance=$1
    local file_path="$INSTANCES_DIR/$instance/Config/GameUserSettings.ini"

    #Check if server is running
    if is_server_running "$instance"; then
        echo -e "${YELLOW}Server for instance $instance is running. Stop it to edit config${RESET}"
        return 0
    fi
    if [ ! -f "$file_path" ]; then
        echo -e "${RED}Error: No GameUserSettings.ini found. Start the server once to generate one or place your own in the instances/$instance/Config folder.${RESET}"
        return
    fi
    select_editor "$file_path"
}

# Function to edit Game.ini
edit_game_ini() {
    local instance=$1
    local file_path="$INSTANCES_DIR/$instance/Config/Game.ini"

    #Check if server is running
    if is_server_running "$instance"; then
        echo -e "${YELLOW}Server for instance $instance is running. Stop it to edit config${RESET}"
        return 0
    fi
    if [ ! -f "$file_path" ]; then
        echo -e "${YELLOW}Game.ini not found for instance '$instance'. Creating a new one.${RESET}"
        touch "$file_path"
    fi
    select_editor "$file_path"
}

# MENU ENTRY: Create a backup of an existing world
menu_backup_world() {
    echo -e "${CYAN}Please select an instance to create a backup from:${RESET}"
    if select_instance; then
        backup_instance_world "$selected_instance"
    fi
}

# MENU ENTRY: Restore an existing backup into an instance
menu_restore_world() {
    echo -e "${CYAN}Please select the target instance to restore the backup to:${RESET}"
    if select_instance; then
        restore_backup_to_instance "$selected_instance"
    fi
}

#Save a world's backup from an instance
backup_instance_world() {
    local instance=$1

    # Check if the server is running
    if is_server_running "$instance"; then
        echo -e "${RED}The server for instance '$instance' is running. Stop it before creating a backup.${RESET}"
        return 0
    fi

    # -- List all world folders in $SERVER_FILES_DIR/ShooterGame/Saved/$instance --
    local worlds=()
    local instance_dir="$SERVER_FILES_DIR/ShooterGame/Saved/$instance"
    if [ ! -d "$instance_dir" ]; then
        echo -e "${RED}Instance directory '$instance_dir' not found.${RESET}"
        return 1
    fi

    # Collect folders typical for ARK worlds (e.g., TheIsland_WP, Ragnarok_WP, etc.)
    for d in "$instance_dir"/*; do
        [ -d "$d" ] && worlds+=("$(basename "$d")")
    done

    if [ ${#worlds[@]} -eq 0 ]; then
        echo -e "${RED}No worlds found to backup (${instance_dir} is empty).${RESET}"
        return 1
    fi

    echo -e "${CYAN}Select a world to back up:${RESET}"
    PS3="Selection: "
    select world_folder in "${worlds[@]}" "Cancel"; do
        if [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "${#worlds[@]}" ]; then
            echo -e "${CYAN}Creating backup for world: $world_folder ...${RESET}"
        elif [ "$REPLY" -eq $((${#worlds[@]} + 1)) ]; then
            echo -e "${YELLOW}Operation canceled.${RESET}"
            return 0
        else
            echo -e "${RED}Invalid selection.${RESET}"
            continue
        fi

        # Create backup directory
        local backups_dir="$BASE_DIR/backups"
        mkdir -p "$backups_dir"

        local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
        local archive_name="${instance}_${world_folder}_${timestamp}.tar.gz"
        local archive_path="$backups_dir/$archive_name"

        tar -czf "$archive_path" -C "$instance_dir" "$world_folder"
        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Backup successfully created: $archive_path${RESET}"
        else
            echo -e "${RED}Error creating the backup.${RESET}"
        fi
        break
    done
}

#Load an existing backup (from the backups folder) into a target instance
restore_backup_to_instance() {
    local target_instance=$1

    # Check if the server is running
    if is_server_running "$target_instance"; then
        echo -e "${RED}The server for instance '$target_instance' is running. Stop it before restoring a backup.${RESET}"
        return 1
    fi

    local backups_dir="$BASE_DIR/backups"
    set +e
    if [ ! -d "$backups_dir" ]; then
        echo -e "${RED}Backup directory '$backups_dir' does not exist.${RESET}"
        return 1
    fi
    set -e

    # Gather all *.tar.gz files in $backups_dir
    local backup_files=()
    while IFS= read -r -d $'\0' file; do
        backup_files+=("$file")
    done < <(find "$backups_dir" -maxdepth 1 -type f -name "*.tar.gz" -print0 | sort -z)

    if [ ${#backup_files[@]} -eq 0 ]; then
        echo -e "${RED}No backups found in '$backups_dir'.${RESET}"
        return 1
    fi

    echo -e "${CYAN}Select a backup to load into instance '$target_instance':${RESET}"
    PS3="Selection: "
    select chosen_backup in "${backup_files[@]}" "Cancel"; do
        if [ "$REPLY" -gt 0 ] && [ "$REPLY" -le "${#backup_files[@]}" ]; then
            local backup_file="$chosen_backup"
            echo -e "${CYAN}Selected backup: $backup_file${RESET}"
        elif [ "$REPLY" -eq $((${#backup_files[@]} + 1)) ]; then
            echo -e "${YELLOW}Operation canceled.${RESET}"
            return 0
        else
            echo -e "${RED}Invalid selection.${RESET}"
            continue
        fi

        # WARNING about overwriting
        echo -e "${RED}WARNING: Restoring this backup may overwrite existing worlds.${RESET}"
        echo -e "Type '${YELLOW}CONFIRM${RESET}' to proceed, or '${YELLOW}cancel${RESET}' to abort:"
        read -r user_input
        if [ "$user_input" != "CONFIRM" ]; then
            echo -e "${YELLOW}Operation canceled.${RESET}"
            return 0
        fi

        # Extract the backup into $SERVER_FILES_DIR/ShooterGame/Saved/$target_instance/
        mkdir -p "$SERVER_FILES_DIR/ShooterGame/Saved/$target_instance"
        echo -e "${CYAN}Extracting backup...${RESET}"
        tar -xzf "$backup_file" -C "$SERVER_FILES_DIR/ShooterGame/Saved/$target_instance/"

        if [ $? -eq 0 ]; then
            echo -e "${GREEN}Backup successfully loaded into instance '$target_instance'.${RESET}"
        else
            echo -e "${RED}Error extracting the backup.${RESET}"
        fi

        break
    done
}
##Save a world's backup from an instance via CLI
backup_instance_world_cli() {
    local instance=$1
    local world_folder=$2

    # Check if the server is running
    if is_server_running "$instance"; then
        echo -e "${RED}The server for instance '$instance' is running. Please stop it first.${RESET}"
        return 1
    fi

    local instance_dir="$SERVER_FILES_DIR/ShooterGame/Saved/$instance"
    if [ ! -d "$instance_dir" ]; then
        echo -e "${RED}Instance directory '$instance_dir' not found.${RESET}"
        return 1
    fi

    local src_path="$instance_dir/$world_folder"
    if [ ! -d "$src_path" ]; then
        echo -e "${RED}World folder '$world_folder' does not exist (${src_path}).${RESET}"
        return 1
    fi

    local backups_dir="$BASE_DIR/backups"
    mkdir -p "$backups_dir"

    local timestamp=$(date +"%Y-%m-%d_%H-%M-%S")
    local archive_name="${instance}_${world_folder}_${timestamp}.tar.gz"
    local archive_path="$backups_dir/$archive_name"

    echo -e "${CYAN}Creating backup for '$world_folder' in instance '$instance'...${RESET}"
    tar -czf "$archive_path" -C "$instance_dir" "$world_folder"
    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Backup successfully created: $archive_path${RESET}"
    else
        echo -e "${RED}Error creating the backup.${RESET}"
        return 1
    fi
}


#Function to select editor and open a file in editor
select_editor() {
local file_path="$1"

# Open the file in the default text editor
    if [ -n "$EDITOR" ]; then
        "$EDITOR" "$file_path"
    elif command -v nano >/dev/null 2>&1; then
        nano "$file_path"
    elif command -v vim >/dev/null 2>&1; then
        vim "$file_path"
    else
        echo -e "${RED}No suitable text editor found. Please edit $file_path manually.${RESET}"
    fi
}

# Menu to edit configuration files
edit_configuration_menu() {
    local instance=$1
    echo -e "${CYAN}Choose configuration to edit:${RESET}"
    options=(
        "Instance Configuration"
        "GameUserSettings.ini"
        "Game.ini"
        "Back"
    )
    PS3="Please select an option: "
    select opt in "${options[@]}"; do
        case "$REPLY" in
            1)
                edit_instance_config "$instance"
                break
                ;;
            2)
                edit_gameusersettings "$instance"
                break
                ;;
            3)
                edit_game_ini "$instance"
                break
                ;;
            4)
                return
                ;;
            *)
                echo -e "${RED}Invalid option selected.${RESET}"
                ;;
        esac
    done
}
# Function to configure the restart_manager.sh
configure_companion_script() {
    local companion_script="$BASE_DIR/ark_restart_manager.sh"
    if [ ! -f "$companion_script" ]; then
        echo -e "${RED}Error: Companion script not found at '$companion_script'.${RESET}"
        return 1
    fi

    echo -e "${CYAN}-- Restart Manager Configuration --${RESET}"

    # 1) Dynamically get all available instances
    get_available_instances
    if [ ${#available_instances[@]} -eq 0 ]; then
        echo -e "${RED}No instances found in '$INSTANCES_DIR'. Returning to main menu.${RESET}"
        return 0
    fi

    # Show them to the user
    echo -e "${CYAN}Available instances:${RESET}"
    local i
    for i in "${!available_instances[@]}"; do
        echo "$((i+1))) ${available_instances[$i]}"
    done
    echo -e "Type the numbers of the instances you want to choose (space-separated), or type 'all' to select all."
    read -r user_input

    local selected_instances=()

    # 2) Parse user selection
    if [[ "$user_input" == "all" ]]; then
        selected_instances=("${available_instances[@]}")
    else
        local choices=($user_input)
        for choice in "${choices[@]}"; do
            local idx=$((choice - 1))
            if (( idx >= 0 && idx < ${#available_instances[@]} )); then
                selected_instances+=("${available_instances[$idx]}")
            else
                echo -e "${RED}Warning: '$choice' is not a valid selection and will be ignored.${RESET}"
            fi
        done
    fi

    if [ ${#selected_instances[@]} -eq 0 ]; then
        echo -e "${RED}No valid instances selected.${RESET}"
        return 1
    fi

    # 3) Ask for announcement times
    echo -e "${CYAN}Enter announcement times in seconds (space-separated), e.g. '1800 1200 600 180 10':${RESET}"
    read -r -a user_times

    # 4) Ask for corresponding announcement messages
    echo -e "${CYAN}Please enter one announcement message for each time above.${RESET}"
    user_messages=()
    for time in "${user_times[@]}"; do
        echo -e "Message for $time seconds before restart:"
        read -r msg
        user_messages+=( "$msg" )
    done

    # Build the config block
    local instances_str=""
    for inst in "${selected_instances[@]}"; do
        instances_str+="\"$inst\" "
    done

    local times_str=""
    for t in "${user_times[@]}"; do
        times_str+="$t "
    done

    local messages_str=""
    for m in "${user_messages[@]}"; do
        messages_str+="    \"$m\"\n"
    done

    local new_config_block="# --------------------------------------------- CONFIGURATION STARTS HERE --------------------------------------------- #

# Define your server instances here (use the names you use in ark_instance_manager.sh)
instances=($instances_str)

# Define the exact announcement times in seconds
announcement_times=($times_str)

# Corresponding messages for each announcement time
announcement_messages=(
$messages_str)

# --------------------------------------------- CONFIGURATION ENDS HERE --------------------------------------------- #"

    # Backup companion script
    cp "$companion_script" "$companion_script.bak"

    # Replace old config block with new one via awk
    awk -v new_conf="$new_config_block" '
        BEGIN { skip=0 }
        /# --------------------------------------------- CONFIGURATION STARTS HERE --------------------------------------------- #/ {
            print new_conf
            skip=1
            next
        }
        /# --------------------------------------------- CONFIGURATION ENDS HERE --------------------------------------------- #/ {
            skip=0
            next
        }
        skip==0 { print }
    ' "$companion_script.bak" > "$companion_script"

    echo -e "${GREEN}Restart Manager script has been updated successfully.${RESET}"

    # 5) Ask for cron job
    echo -e "${CYAN}Would you like to schedule a daily cron job for server restart? [y/N]${RESET}"
    read -r add_cron
    if [[ "$add_cron" =~ ^[Yy]$ ]]; then
        echo -e "${CYAN}At what time should the daily restart occur?${RESET}"
        echo -e "${YELLOW}(Use 24-hour format: HH:MM, e.g., '16:00' for 4 PM or '03:00' for 3 AM)${RESET}"
        read -r cron_time
        local cron_hour=$(echo "$cron_time" | cut -d':' -f1)
        local cron_min=$(echo "$cron_time" | cut -d':' -f2)

        # Robust crontab update using a temporary file
        local tmp_cron
        tmp_cron=$(mktemp)

        # Export current crontab (ignoring old entries of this script)
        # Use '|| true' to prevent script exit if crontab is currently empty
        crontab -l 2>/dev/null | grep -v "$companion_script" > "$tmp_cron" || true

        # Append the new schedule
        echo "$cron_min $cron_hour * * * $companion_script" >> "$tmp_cron"

        # Re-install the updated crontab
        if crontab "$tmp_cron"; then
            echo -e "${GREEN}Cron job successfully scheduled for $cron_time daily.${RESET}"
        else
            echo -e "${RED}Error: Failed to install crontab.${RESET}"
        fi

        # Clean up temporary file
        rm -f "$tmp_cron"
    fi
}

# Main menu using 'select'
main_menu() {
    while true; do
        echo -e "${YELLOW}ARK Server Instance Management${RESET}"
        echo

        options=(
            "Install/Update Base Server"          # 1
            "List Instances"                      # 2
            "Create New Instance"                 # 3
            "Manage Instance"                     # 4
            "Change Instance Name"                # 5
            "Delete Instance"                     # 6
            "Start All Instances"                 # 7
            "Stop All Instances"                  # 8
            "Show Running Instances"              # 9
            "Backup a World from Instance"        # 10
            "Load Backup to Instance"             # 11
            "Configure Restart Manager "          # 12
            "Exit ARK Server Manager"             # 13
        )

        PS3="Please choose an option: "
        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    install_base_server
                    break
                    ;;
                2)
                    list_instances
                    break
                    ;;
                3)
                    create_instance
                    break
                    ;;
                4)
                    if select_instance; then
                        manage_instance "$selected_instance"
                    fi
                    break
                    ;;
                5)
                    if select_instance; then
                        change_instance_name "$selected_instance"
                    fi
                    break
                    ;;
                6)
                    if select_instance; then
                        delete_instance "$selected_instance"
                    fi
                    break
                    ;;
                7)
                    start_all_instances
                    break
                    ;;
                8)
                    stop_all_instances
                    break
                    ;;
                9)
                    show_running_instances
                    break
                    ;;
                10)
                    menu_backup_world
                    break
                    ;;
                11)
                    menu_restore_world
                    break
                    ;;
                12)
                    configure_companion_script
                    break
                    ;;
                13)
                    echo -e "${GREEN}Exiting ARK Server Manager. Goodbye!${RESET}"
                    exit 0
                    ;;
                *)
                    echo -e "${RED}Invalid option selected.${RESET}"
                    ;;
            esac
        done
    done
}

# Instance management menu using 'select'
manage_instance() {
    local instance=$1
    while true; do
        echo -e "${YELLOW}Managing Instance: $instance${RESET}"
        echo

        options=(
            "Start Server"
            "Stop Server"
            "Restart Server"
            "Open RCON Console"
            "Edit Configuration"
            "Change Map"
            "Change Mods"
            "Check Server Status"
            "Change Instance Name"
            "Back to Main Menu"
        )

        PS3="Please choose an option: "
        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    start_server "$instance"
                    break
                    ;;
                2)
                    stop_server "$instance"
                    break
                    ;;
                3)
                    stop_server "$instance"
                    start_server "$instance"
                    break
                    ;;
                4)
                    start_rcon_cli "$instance"
                    break
                    ;;
                5)
                    edit_configuration_menu "$instance"
                    break
                    ;;
                6)
                    change_map "$instance"
                    break
                    ;;
                7)
                    change_mods "$instance"
                    break
                    ;;
                8)
                    check_server_status "$instance"
                    break
                    ;;
                9)
                    change_instance_name "$instance"
                    instance=$new_instance_name  # Update the instance variable
                    break
                    ;;
                10)
                    return
                    ;;
                *)
                    echo -e "${RED}Invalid option selected.${RESET}"
                    ;;
            esac
        done
    done
}

# Main script execution
if [ $# -eq 0 ]; then
    main_menu
else
    case $1 in
        update)
            install_base_server
            ;;
        setup)
            setup_symlink
            ;;
        start_all)
            start_all_instances
            ;;
        stop_all)
            stop_all_instances
            ;;
        show_running)
            show_running_instances
            ;;
        delete)
            if [ -z "$2" ]; then
                echo -e "${RED}Usage: $0 delete <instance_name>${RESET}"
                exit 1
            fi
            delete_instance "$2"
            ;;
        *)
            instance_name=$1
            action=$2
            case $action in
                start)
                    start_server "$instance_name"
                    ;;
                stop)
                    stop_server "$instance_name"
                    ;;
                restart)
                    stop_server "$instance_name"
                    start_server "$instance_name"
                    ;;
                send_rcon)
                    if [ $# -lt 3 ]; then
                        echo -e "${RED}Usage: $0 <instance_name> send_rcon \"<rcon_command>\"${RESET}"
                        exit 1
                    fi
                    rcon_command="${@:3}"  # Get all arguments from the third onwards
                    send_rcon_command "$instance_name" "$rcon_command"
                    ;;
                backup)
                    if [ $# -lt 3 ]; then
                        echo -e "${RED}Usage: $0 $instance_name backup <world_folder>${RESET}"
                        exit 1
                    fi
                    world_folder=$3
                    backup_instance_world_cli "$instance_name" "$world_folder"
                    ;;
                *)
                    echo -e "${RED}Usage: $0 [update|start_all|stop_all|show_running|delete <instance_name>]${RESET}"
                    echo -e "${RED}       $0 <instance_name> [start|stop|restart|send_rcon \"<rcon_command>\" |backup <world_folder>]${RESET}"
                    echo "Or run without arguments to enter interactive mode."
                    exit 1
                    ;;
            esac
            ;;
    esac
fi
