#!/bin/bash

export LC_ALL=C.UTF-8
export LANG=C.UTF-8
export LANGUAGE=C.UTF-8

# Color definitions
RED='\e[31m'
GREEN='\e[32m'
YELLOW='\e[33m'
BLUE='\e[34m'
MAGENTA='\e[35m'
CYAN='\e[36m'
RESET='\e[0m'

# Docker-Image-Name
IMAGE_NAME="ark-ascended-base"

# Base directory for all instances
BASE_DIR="$(cd "$(dirname "$(realpath "$0")")" && pwd)"
BINARIES_DIR="$BASE_DIR/server-files"
INSTANCES_DIR="$BASE_DIR/instances"
RCON_SCRIPT="$BASE_DIR/rcon.py"
ARK_RESTART_MANAGER="$BASE_DIR/ark_restart_manager.sh"
ARK_INSTANCE_MANAGER="$BASE_DIR/ark_docker_manager.sh"

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

# Function to check docker
check_docker() {
    if ! command -v docker &> /dev/null; then
        echo -e "${RED}Error: Docker is not installed or not in PATH.${RESET}"
        exit 1
    fi
}
# Call the functions at the start of the script
check_executables
check_docker

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

ensure_base_image() {
    setup_host_directory
    echo -e "${YELLOW}=== Building base image: $IMAGE_NAME ===${RESET}"
    docker build -t "$IMAGE_NAME" "$BASE_DIR"
    echo -e "${GREEN}Done!${RESET}"
}

# Function to check if a container is running
is_server_running() {
    local instance="$1"

    # Check if an instance was provided
    if [[ -z "$instance" ]]; then
        echo "Error: No instance specified." >&2
        return 1
    fi

    # Check if a container with the instance name is running
    if docker ps --filter "name=${instance}" --format "{{.Names}}" | grep -qw "${instance}"; then
        return 0
    else
        return 1
    fi
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
    local instance=$1
    local inst_dir="$INSTANCES_DIR/$instance"
    local config_dir="$inst_dir/Config"
    local container_name="ark_${instance}"
    setup_host_directory

    # Check for duplicate ports
    if ! check_for_duplicate_ports; then
        echo -e "${YELLOW}Port conflicts detected. Server start aborted.${RESET}"
        return 1
    fi

    # Remove existing container with the same name if it exists
    if docker ps -a --filter "name=${container_name}" --format "{{.Names}}" | grep -q "^${container_name}$"; then
        echo -e "${YELLOW}A container with the name '${container_name}' already exists. Removing it...${RESET}"
        docker rm -f "$container_name" || {
            echo -e "${RED}Failed to remove existing container. Aborting server start.${RESET}"
            return 1
        }
    fi

    if is_server_running "ark_$instance"; then
        echo -e "${YELLOW}Server for instance $instance is already running.${RESET}"
        return 0
    fi

    load_instance_config "$instance" || return 1

    echo -e "${CYAN}Starting server for instance: $instance${RESET}"

    # Set cluster parameters if ClusterID is set
    local cluster_params=""
    if [ -n "$CLUSTER_ID" ]; then
        local cluster_dir="$BASE_DIR/clusters/$CLUSTER_ID"
        mkdir -p "$cluster_dir" || true
        cluster_params="-ClusterDirOverride=\"$cluster_dir\" -ClusterId=\"$CLUSTER_ID\""
    fi

    # # Ensure configuration files exists
    mkdir -p "$config_dir"
    touch "$config_dir/Game.ini" "$config_dir/GameUserSettings.ini"

    # Ensure configuration directory exists and contains necessary files
    if [ ! -f "$config_dir/Game.ini" ] || [ ! -f "$config_dir/GameUserSettings.ini" ]; then
        echo -e "${RED}Configuration files are missing for instance: $instance${RESET}"
        echo -e "${YELLOW}Expected directory: $config_dir${RESET}"
        return 1
    fi

    # Start the server using Docker
    docker run -d \
         --env UMASK=0007 \
        --name "$container_name" \
        -p "${GAME_PORT}:${GAME_PORT}" \
        -p "${QUERY_PORT}:${QUERY_PORT}" \
        -p "${RCON_PORT}:${RCON_PORT}" \
        -v "$BINARIES_DIR:/ark/binaries" \
        -v "$inst_dir:/ark/instance" \
        -v "$config_dir/Game.ini:/ark/binaries/ShooterGame/Saved/Config/WindowsServer/Game.ini:rw" \
        -v "$config_dir/GameUserSettings.ini:/ark/binaries/ShooterGame/Saved/Config/WindowsServer/GameUserSettings.ini:rw" \
        "$IMAGE_NAME" run \
        "$MAP_NAME?listen?SessionName=$SERVER_NAME?ServerPassword=$SERVER_PASSWORD?RCONEnabled=True?ServerAdminPassword=$ADMIN_PASSWORD?AltSaveDirectoryName=$SAVE_DIR" \
            $CUSTOM_START_PARAMETERS \
            -WinLiveMaxPlayers=$MAX_PLAYERS \
            -Port=$GAME_PORT \
            -QueryPort=$QUERY_PORT \
            -RCONPort=$RCON_PORT \
            -game \
            $cluster_params \
            -server \
            -log \
            -mods="$MOD_IDS"

    if [ $? -eq 0 ]; then
        echo -e "${GREEN}Server started for instance: $instance. It should be fully operational in approximately 60 seconds.${RESET}"
    else
        echo -e "${RED}Failed to start the server for instance: $instance.${RESET}"
        return 1
    fi
}

# Function to stop the server
stop_server() {
    local instance="$1"

    if ! is_server_running "ark_$instance"; then
        echo -e "${YELLOW}Server for instance $instance is not running.${RESET}"
        return 0
    fi

    echo -e "${GREEN}Stopping instance '$instance' ...${RESET}"
    send_rcon_command ${instance} "SaveWorld"
    docker stop "ark_${instance}" 2>/dev/null || true
    docker rm "ark_${instance}" 2>/dev/null || true
}

# Function to start RCON CLI
start_rcon_cli() {
    local instance=$1

    if ! is_server_running "ark_$instance"; then
        echo -e "${YELLOW}Server for instance $instance is not running.${RESET}"
        return 0
    fi

    load_instance_config "$instance" || return 1

    echo -e "${CYAN}Starting RCON CLI for instance: $instance${RESET}"

    # Use the new RCON-Client
    docker exec -it "ark_$instance" python3 /opt/rcon/rcon.py \
        "localhost:$RCON_PORT" \
        -p "$ADMIN_PASSWORD" || {
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
    local instance="$1"

    # Check if an instance was provided
    if [[ -z "$instance" ]]; then
        echo -e "${RED}Error: No instance specified.${RESET}"
        return 1
    fi

    # Load instance configuration
    if ! load_instance_config "$instance"; then
        echo -e "${RED}Error loading configuration for instance $instance.${RESET}"
        return 1
    fi

    # Check Docker status
    if docker ps --filter "name=ark_${instance}" --format "{{.Names}}" | grep -qw "ark_${instance}"; then
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
            if is_server_running "ark_$instance_name"; then
                echo -e "${YELLOW}Instance $instance_name is already running. Skipping...${RESET}"
                continue
            fi

            # Attempt to start the server
            if start_server "$instance_name"; then
                # Only wait if the server started successfully
                echo -e "${YELLOW}Waiting 5 seconds before starting the next instance...${RESET}"
                sleep 5
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
            if ! is_server_running "ark_$instance_name"; then
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

    if ! is_server_running "ark_$instance"; then
        echo -e "${YELLOW}Server for instance $instance is not running. Cannot send RCON command.${RESET}"
        return 1
    fi

    load_instance_config "$instance" || return 1

    # Always use the silent mode of the RCON client
    local response
    response=$(docker exec -i "ark_$instance" python3 /opt/rcon/rcon.py \
    "localhost:$RCON_PORT" \
    -p "$ADMIN_PASSWORD" \
    -c "$command" \
    --silent 2>&1)

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
    echo -e "${CYAN}Running instances (containers):${RESET}"
    docker ps --filter "name=ark_" --format "{{.Names}}"
}

# Function to delete an instance
delete_instance() {
    local instance="$1"

   # Select instance if none was provided
    if [[ -z "$instance" ]]; then
        if ! select_instance; then
            return
        fi
        instance="$selected_instance"
    fi

    # Check if the instance exists
    if [[ -d "$INSTANCES_DIR/$instance" ]]; then
        echo -e "${RED}Warning: This will permanently delete the instance '$instance' and all its data.${RESET}"
        echo "Type CONFIRM to delete the instance '$instance', or cancel to abort"
        read -p "> " response

        if [[ $response == "CONFIRM" ]]; then
            # Verify if the Docker container is running, and stop it
            if docker ps --filter "name=ark_${instance}" --format "{{.Names}}" | grep -qw "ark_${instance}"; then
                echo -e "${CYAN}Stopping instance '$instance'...${RESET}"
                stop_server "$instance"
            fi

            # Remove the Docker container
            if docker ps -a --filter "name=ark_${instance}" --format "{{.Names}}" | grep -qw "ark_${instance}"; then
                echo -e "${CYAN}Removing Docker container for instance '$instance'...${RESET}"
                docker rm "ark_${instance}" > /dev/null 2>&1 || echo -e "${RED}Failed to remove Docker container.${RESET}"
            fi

            # Delete the instance directory
            echo -e "${CYAN}Deleting instance directory for '$instance'...${RESET}"
            rm -rf "$INSTANCES_DIR/$instance" || echo -e "${RED}Failed to delete instance directory.${RESET}"
            rm -rf "$BINARIES_DIR/ShooterGame/Saved/$instance" || true
            rm -rf "$BINARIES_DIR/ShooterGame/Saved/SavedArks/$instance" || true

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
    if is_server_running "ark_$instance"; then
        echo -e "${CYAN}Stopping running server for instance '$instance' before renaming...${RESET}"
        stop_server "$instance"
    fi

    # Rename instance directory
    mv "$INSTANCES_DIR/$instance" "$INSTANCES_DIR/$new_instance_name" || {
        echo -e "${RED}Failed to rename instance directory.${RESET}"
        return 1
    }

    # Rename save directories if they exist
    if [ -d "$BINARIES_DIR/ShooterGame/Saved/$instance" ]; then
        mv "$BINARIES_DIR/ShooterGame/Saved/$instance" "$BINARIES_DIR/ShooterGame/Saved/$new_instance_name" || true
    fi

    if [ -d "$BINARIES_DIR/ShooterGame/Saved/SavedArks/$instance" ]; then
        mv "$BINARIES_DIR/ShooterGame/Saved/SavedArks/$instance" "$BINARIES_DIR/ShooterGame/Saved/SavedArks/$new_instance_name" || true
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
    if is_server_running "ark_$instance"; then
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
    if is_server_running "ark_$instance"; then
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
    if is_server_running "ark_$instance"; then
        echo -e "${RED}The server for instance '$instance' is running. Stop it before creating a backup.${RESET}"
        return 0
    fi

    # -- List all world folders in $BINARIES_DIR/ShooterGame/Saved/$instance --
    local worlds=()
    local instance_dir="$BINARIES_DIR/ShooterGame/Saved/$instance"
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
    if is_server_running "ark_$target_instance"; then
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

        # Extract the backup into $BINARIES_DIR/ShooterGame/Saved/$target_instance/
        mkdir -p "$BINARIES_DIR/ShooterGame/Saved/$target_instance"
        echo -e "${CYAN}Extracting backup...${RESET}"
        tar -xzf "$backup_file" -C "$BINARIES_DIR/ShooterGame/Saved/$target_instance/"

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
    if is_server_running "ark_$instance"; then
        echo -e "${RED}The server for instance '$instance' is running. Please stop it first.${RESET}"
        return 1
    fi

    local instance_dir="$BINARIES_DIR/ShooterGame/Saved/$instance"
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

        # 1) Read the current crontab (if any),
        # 2) Remove all lines referencing our manager script,
        # 3) Append a new line with the chosen schedule,
        # 4) Save back to crontab
        ( crontab -l 2>/dev/null | grep -v "$companion_script"
        echo "$cron_min $cron_hour * * * $companion_script"
        ) | crontab -

        echo -e "${GREEN}Cron job scheduled daily at $cron_time.${RESET}"
    fi
}

setup_host_directory() {
    # 1) Create directories (including subdirectory 'Saved')
    mkdir -p "$BINARIES_DIR/ShooterGame/Saved"

    # 2) (Optional) Set ownership
    chown -R root:$(whoami) "$BINARIES_DIR" 2>/dev/null || true

    # 3) Set base permissions with Set-GID bit for the entire tree
    chmod -R 2770 "$BINARIES_DIR" 2>/dev/null || true

    # 4) Completely remove existing ACLs (recursively)
    setfacl -bR "$BINARIES_DIR" 2>/dev/null || true

    # 5) Set new ACLs for existing files/directories
    setfacl -R -m u::rwx,g::rwx,o::--- "$BINARIES_DIR" 2>/dev/null || true

    # 6) Set default ACLs for FUTURE files/directories
    setfacl -R -m d:u::rwx,d:g::rwx,d:o::--- "$BINARIES_DIR" 2>/dev/null || true
}




# Update ARK server binaries
update_ark_binaries() {
    setup_host_directory
    echo -e "${YELLOW}=== Updating ARK Server Files===${RESET}"
    # Start a temporary container that runs in "update" mode
    docker run --rm \
      -v "$BINARIES_DIR:/ark/binaries" \
      --env UMASK=0007 \
      "$IMAGE_NAME" update
    echo -e "${GREEN}Update complete!${RESET}"
}

# Main menu using 'select'
main_menu() {
    while true; do
        echo -e "${YELLOW}ARK Server Instance Management${RESET}"
        echo

        options=(
            "Create ARK base image (if not already present)"   # 1
            "Update Server Files"                              # 2
            "List Instances"                                   # 3
            "Create New Instance"                              # 4
            "Manage Instance"                                  # 5
            "Change Instance Name"                             # 6
            "Delete Instance"                                  # 7
            "Start All Instances"                              # 8
            "Stop All Instances"                               # 9
            "Show Running Instances"                           # 10
            "Backup a World from Instance"                     # 11
            "Load Backup to Instance"                          # 12
            "Configure Restart Manager "                       # 13
            "Exit ARK Server Manager"                          # 14
        )

        PS3="Please choose an option: "
        select opt in "${options[@]}"; do
            case "$REPLY" in
                1)
                    ensure_base_image
                    break
                    ;;
                2)
                    update_ark_binaries
                    break
                    ;;
                3)
                    list_instances
                    break
                    ;;
                4)
                    create_instance
                    break
                    ;;
                5)
                    if select_instance; then
                        manage_instance "$selected_instance"
                    fi
                    break
                    ;;
                6)
                    if select_instance; then
                        change_instance_name "$selected_instance"
                    fi
                    break
                    ;;
                7)
                    if select_instance; then
                        delete_instance "$selected_instance"
                    fi
                    break
                    ;;
                8)
                    start_all_instances
                    break
                    ;;
                9)
                    stop_all_instances
                    break
                    ;;
                10)
                    show_running_instances
                    break
                    ;;
                11)
                    menu_backup_world
                    break
                    ;;
                12)
                    menu_restore_world
                    break
                    ;;
                13)
                    configure_companion_script
                    break
                    ;;
                14)
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
       install)
            ensure_base_image
            ;;
       update)
            update_ark_binaries
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
                    echo -e "${RED}Usage: $0 [install|update|setup|start_all|stop_all|show_running|delete <instance_name>]${RESET}"
                    echo -e "${RED}       $0 <instance_name> [start|stop|restart|send_rcon \"<rcon_command>\" |backup <world_folder>]${RESET}"
                    echo "Or run without arguments to enter interactive mode."
                    exit 1
                    ;;
            esac
            ;;
    esac
fi
