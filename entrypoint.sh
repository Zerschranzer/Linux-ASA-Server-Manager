#!/usr/bin/env bash
set -e
umask "${UMASK:-0007}"

GREEN="\e[32m"
YELLOW="\e[33m"
RED="\e[31m"
CYAN="\e[36m"
RESET="\e[0m"

UMU_DIR="${UMU_DIR:-/opt/umu-launcher}"
UMU_RUN_BIN="${UMU_RUN_BIN:-$UMU_DIR/umu-run}"
GE_PROTON_VERSION="${GE_PROTON_VERSION:-GE-Proton10-34}"
GE_PROTON_PATH="${GE_PROTON_PATH:-/opt/proton/$GE_PROTON_VERSION}"
UMU_GAMEID="${UMU_GAMEID:-umu-default}"
UMU_PREFIX_DIR="${UMU_PREFIX_DIR:-/tmp/umu-home/umu-prefix}"

ARK_APPID="2430930"
ARK_BINARIES="/ark/binaries"
ARK_INSTANCE="/ark/instance"
STEAMCMDDIR="${STEAMCMDDIR:-/opt/steamcmd}"

if [ ! -w "$HOME" ]; then
    export HOME="/tmp/umu-home"
fi
mkdir -p "$HOME/.local/share/umu" "$UMU_PREFIX_DIR" 2>/dev/null || true

_run_wineboot() {
    local output
    output=$(WINEPREFIX="$UMU_PREFIX_DIR" \
             GAMEID="$UMU_GAMEID" \
             PROTONPATH="$GE_PROTON_PATH" \
             "$UMU_RUN_BIN" wineboot --init 2>&1) || {
        if echo "$output" | grep -q "bwrap"; then
            echo -e "${RED}Error: Steam Linux Runtime cannot start -- user namespaces are restricted.${RESET}"
            echo -e "${CYAN}Fix on the Docker HOST (not inside this container):${RESET}"
            echo "    sudo sysctl -w kernel.unprivileged_userns_clone=1"
            echo "    # Ubuntu 23.10+ also needs:"
            echo "    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0"
            exit 1
        fi
        echo -e "${RED}wineboot --init failed:${RESET}"
        echo "$output" | tail -20
        exit 1
    }
}

check_prefix() {
    local prefix_marker="$UMU_PREFIX_DIR/.created-by-proton"

    if [ ! -f "$UMU_PREFIX_DIR/system.reg" ]; then
        echo -e "${CYAN}First run: initializing Wine prefix and downloading Steam Linux Runtime...${RESET}"
        echo -e "${YELLOW}This may take several minutes (one-time setup).${RESET}"
        mkdir -p "$UMU_PREFIX_DIR"
        _run_wineboot
        echo "$GE_PROTON_VERSION" > "$UMU_PREFIX_DIR/.created-by-proton"

        local waited=0
        while [ "$waited" -lt 90 ]; do
            if ! pgrep -f "wineserver.*$UMU_PREFIX_DIR" >/dev/null 2>&1; then
                break
            fi
            sleep 2
            waited=$((waited + 2))
        done
        echo -e "${GREEN}Wine prefix initialized.${RESET}"
        return 0
    fi

    local prefix_proton=""
    [ -f "$prefix_marker" ] && prefix_proton="$(cat "$prefix_marker" 2>/dev/null)"
    if [ "$prefix_proton" != "$GE_PROTON_VERSION" ]; then
        echo -e "${YELLOW}Wine prefix was created by '${prefix_proton:-unknown}', current is $GE_PROTON_VERSION.${RESET}"
        echo -e "${CYAN}Recreating prefix (saves/configs live outside the prefix, nothing is lost)...${RESET}"
        rm -rf "$UMU_PREFIX_DIR"
        mkdir -p "$UMU_PREFIX_DIR"
        _run_wineboot
        echo "$GE_PROTON_VERSION" > "$UMU_PREFIX_DIR/.created-by-proton"
        echo -e "${GREEN}Prefix recreated.${RESET}"
    fi

    if [ ! -f "$prefix_marker" ]; then
        echo "$GE_PROTON_VERSION" > "$prefix_marker"
    fi
}

apply_wine10_fixes() {
    local plugins_dir="$ARK_BINARIES/ShooterGame/Plugins"
    if [ -d "$plugins_dir/sentry" ]; then
        echo -e "${CYAN}Disabling Sentry crashpad plugin (incompatible with Wine 10)...${RESET}"
        rm -rf "$plugins_dir/sentry.disabled"
        mv "$plugins_dir/sentry" "$plugins_dir/sentry.disabled"
        echo -e "${GREEN}Sentry plugin renamed to sentry.disabled.${RESET}"
    elif [ -d "$plugins_dir/sentry.disabled" ]; then
        echo -e "${GREEN}Sentry plugin already disabled.${RESET}"
    fi

    local win64_dir="$ARK_BINARIES/ShooterGame/Binaries/Win64"
    if [ -d "$win64_dir" ] && [ "$(cat "$win64_dir/steam_appid.txt" 2>/dev/null)" != "$ARK_APPID" ]; then
        echo "$ARK_APPID" > "$win64_dir/steam_appid.txt"
        echo -e "${GREEN}Wrote steam_appid.txt (AppID $ARK_APPID).${RESET}"
    fi

    local steam_sdk32="$HOME/.steam/sdk32"
    local steam_sdk64="$HOME/.steam/sdk64"
    local steamcmd_so32="$STEAMCMDDIR/linux32/steamclient.so"
    local steamcmd_so64="$STEAMCMDDIR/linux64/steamclient.so"
    if [ -f "$steamcmd_so32" ] && [ -f "$steamcmd_so64" ]; then
        mkdir -p "$steam_sdk32" "$steam_sdk64"
        ln -sf "$steamcmd_so32" "$steam_sdk32/steamclient.so"
        ln -sf "$steamcmd_so64" "$steam_sdk64/steamclient.so"
        echo -e "${GREEN}Steam SDK symlinks in place.${RESET}"
    else
        echo -e "${YELLOW}Warning: steamclient.so not found -- server may fail to start.${RESET}"
    fi
}

update_ark() {
    echo -e "${GREEN}>>> Updating ARK server binaries at $ARK_BINARIES${RESET}"
    mkdir -p "$ARK_BINARIES"
    "$STEAMCMDDIR/steamcmd.sh" \
        +force_install_dir "$ARK_BINARIES" \
        +login anonymous \
        +app_update "$ARK_APPID" validate \
        +quit
    echo -e "${GREEN}>>> ARK update complete${RESET}"
    apply_wine10_fixes
    # SteamCMD may reset permissions during validate. Restore group-write
    # so the server container can write saved data, steam_appid.txt, etc.
    find "$ARK_BINARIES" ! -perm -0060 -exec chmod g+rwX {} + 2>/dev/null || true
}

generate_initial_config() {
    local config_dir="$ARK_BINARIES/ShooterGame/Saved/Config/WindowsServer"
    if [ -d "$config_dir" ]; then
        return 0
    fi
    echo -e "${CYAN}First run: generating initial server configuration...${RESET}"
    local init_log="$ARK_INSTANCE/initial-setup.log"
    WINEPREFIX="$UMU_PREFIX_DIR" \
    GAMEID="$UMU_GAMEID" \
    PROTONPATH="$GE_PROTON_PATH" \
    UMU_RUNTIME_UPDATE=0 \
        "$UMU_RUN_BIN" "$ARK_BINARIES/ShooterGame/Binaries/Win64/ArkAscendedServer.exe" \
        "TheIsland_WP?listen" \
        -NoBattlEye \
        -crossplay \
        -server \
        -log \
        -game \
        > "$init_log" 2>&1 &
    local init_pid=$!
    local waited=0
    local timeout=180
    while [ "$waited" -lt "$timeout" ]; do
        if [ -d "$config_dir" ]; then
            echo -e "${GREEN}Config directory created after ${waited}s.${RESET}"
            sleep 20
            break
        fi
        if ! kill -0 "$init_pid" 2>/dev/null && ! pgrep -f "ArkAscendedServer.exe" > /dev/null; then
            echo -e "${RED}Initial server process exited prematurely. See $init_log${RESET}"
            tail -n 30 "$init_log" || true
            return 1
        fi
        sleep 5
        waited=$((waited + 5))
    done
    pkill -f "ArkAscendedServer.exe.*TheIsland_WP" || true
    sleep 5
    echo -e "${GREEN}Initial server config generated.${RESET}"
}

run_server() {
    if [ $# -eq 0 ]; then
        echo -e "${RED}No start parameters provided. Aborting.${RESET}"
        exit 1
    fi
    check_prefix
    apply_wine10_fixes
    generate_initial_config

    local config_dir="$ARK_BINARIES/ShooterGame/Saved/Config/WindowsServer"
    mkdir -p "$config_dir"
    if [ -f "$ARK_INSTANCE/Game.ini" ]; then
        ln -sf "$ARK_INSTANCE/Game.ini" "$config_dir/Game.ini"
        echo -e "${GREEN}>>> Loaded instance Game.ini${RESET}"
    fi
    if [ -f "$ARK_INSTANCE/GameUserSettings.ini" ]; then
        ln -sf "$ARK_INSTANCE/GameUserSettings.ini" "$config_dir/GameUserSettings.ini"
        echo -e "${GREEN}>>> Loaded instance GameUserSettings.ini${RESET}"
    fi

    echo -e "${GREEN}>>> Starting ARK server: $@${RESET}"
    export PROTON_VERB=run
    cd "$ARK_BINARIES/ShooterGame/Binaries/Win64"
    exec env \
        WINEPREFIX="$UMU_PREFIX_DIR" \
        GAMEID="$UMU_GAMEID" \
        PROTONPATH="$GE_PROTON_PATH" \
        PROTON_VERB=run \
        UMU_RUNTIME_UPDATE=0 \
        "$UMU_RUN_BIN" ./ArkAscendedServer.exe "$@"
}

MODE="${1:-run}"
shift || true

case "$MODE" in
    update)
        update_ark
        ;;
    run)
        run_server "$@"
        ;;
    bash|shell)
        exec /bin/bash "$@"
        ;;
    *)
        echo "Unknown mode: $MODE"
        echo "Usage: entrypoint.sh [update|run|bash] [args...]"
        exit 1
        ;;
esac
