#!/usr/bin/env bash
set -e

# Colors
GREEN="\e[32m"
RED="\e[31m"
RESET="\e[0m"

STEAMCMDDIR="/opt/steamcmd"
PROTON_VERSION="${PROTON_VERSION:-GE-Proton10-4}"
PROTONDIR="/opt/proton/${PROTON_VERSION}"
PROTON_BIN="$PROTONDIR/proton"

# ARK Ascended AppID
ARK_APPID="2430930"

# Binaries directory: where the ARK server is located
ARK_BINARIES="/ark/binaries"

# Instance directory: where configs/saves/logs are stored
ARK_INSTANCE="/ark/instance"

# Ensure the correct ownership and permissions
prepare_permissions() {
    echo "Setting ownership to root:docker and permissions to g+rw for /ark/binaries..."
    chown -R root:docker /ark/binaries
    chmod -R g+rw /ark/binaries
}
#prepare_permissions

update_ark() {
  echo -e "${GREEN}>>> Updating ARK server binaries at $ARK_BINARIES${RESET}"
  mkdir -p "$ARK_BINARIES"
  "${STEAMCMDDIR}/steamcmd.sh" \
    +force_install_dir "$ARK_BINARIES" \
    +login anonymous \
    +app_update "${ARK_APPID}" validate \
    +quit
  echo -e "${GREEN}>>> ARK update complete${RESET}"
}

init_proton_prefix() {
  local prefix="$ARK_BINARIES/steamapps/compatdata/$ARK_APPID"
  if [ ! -d "$prefix/pfx" ]; then
    echo -e "${GREEN}>>> Initializing Proton prefix in $prefix${RESET}"
    mkdir -p "$prefix"
    cp -r "$PROTONDIR/files/share/default_pfx/." "$prefix/" || {
      echo -e "${RED}Error copying default_pfx!${RESET}"
      exit 1
    }
  fi
}

run_server() {
  if [ $# -eq 0 ]; then
    echo -e "${RED}No start parameters provided. Aborting.${RESET}"
    exit 1
  fi

  echo -e "${GREEN}>>> Starting ARK server with parameters: $@${RESET}"

  # Proton environment variables
  export STEAM_COMPAT_DATA_PATH="$ARK_BINARIES/steamapps/compatdata/$ARK_APPID"
  export STEAM_COMPAT_CLIENT_INSTALL_PATH="/opt"

  init_proton_prefix

  # Change to the Win64 directory
  cd "$ARK_BINARIES/ShooterGame/Binaries/Win64"

  # Instance-specific configurations
  if [ -f "$ARK_INSTANCE/Game.ini" ]; then
    echo -e "${GREEN}>>> Loaded instance-specific Game.ini${RESET}"
    ln -sf "$ARK_INSTANCE/Game.ini" "$ARK_BINARIES/ShooterGame/Saved/Config/WindowsServer/Game.ini"
  fi

  if [ -f "$ARK_INSTANCE/GameUserSettings.ini" ]; then
    echo -e "${GREEN}>>> Loaded instance-specific GameUserSettings.ini${RESET}"
    ln -sf "$ARK_INSTANCE/GameUserSettings.ini" "$ARK_BINARIES/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini"
  fi

  # Start the server with the provided parameters
  exec "$PROTON_BIN" run ./ArkAscendedServer.exe "$@"
}

MODE="${1:-run}"
shift

case "$MODE" in
  update)
    update_ark
    ;;
  run)
    #update_ark   # Optional: update before each start
    run_server "$@"
    ;;
  bash|shell)
    exec /bin/bash "$@"
    ;;
  *)
    echo "Unknown mode: $MODE"
    exit 1
    ;;
esac
