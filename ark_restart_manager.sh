#!/bin/bash

# Note: Make sure that both this script (ark_restart_manager.sh) and the ark_instance_manager.sh script are located in the same directory.

# --------------------------------------------- CONFIGURATION STARTS HERE --------------------------------------------- #

# Define your server instances here (use the names you use in ark_instance_manager.sh)
instances=("instanceexample1" "instanceexample2")

# Define the exact announcement times in seconds
announcement_times=(1800 1200 600 180 10)

# Corresponding messages for each announcement time
announcement_messages=(
    "Server restart in 30 minutes"
    "Server restart in 20 minutes"
    "Server restart in 10 minutes"
    "Server restart in 3 minutes"
    "Server restart in 10 seconds"
)

# --------------------------------------------- CONFIGURATION ENDS HERE --------------------------------------------- #
#                                                                                         \   |   /                   #
#                               &&& &&  & &&                        .-~~~-.                 .-*-.                     #
#                           & &\/&\|& ()|/ @, &&                .-~~       ~~-.           --  *  --                   #
#                             &\/(/&/&||/& /_/)_&              (               )            '-*-'                     #
#                          &() &\/&|()|/&\/ '%" &               `-.__________.-'          /   |   \                   #
#                             &_\/_&&_/ \|&  _/&_&                                          .-~~~-.                   #
#                        &   && & &| &| /& & % ()& /&&                                  .-~~       ~~-.               #
#                  __      ()&_---()&\&\|&&-&&--%---()~                                (               )              #
#                 / _)                \|||                                              `-.__________.-'              #
#        _.----._/ /                   |||                                                                            #
#       /         /                    |||                                      O                                     #
#    __/ (  | (  |                     |||                                     /|\                                    #
#   /__.-'|_|--|_|                     |||                                     / \                                    #
#   , -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _, -=-~  .-^- _  #
#######################################################################################################################

# Define script and configuration paths as variables
script_dir="$(dirname "$(realpath "$0")")"
ark_manager="$script_dir/ark_instance_manager.sh"
log_file="$script_dir/ark_restart_manager.log"
# Time to wait between starting instances (in seconds). The server needs enough time to load the config, before the next instance starts.
start_wait_time=30

# Function to log messages
log_message() {
    local message="$1"
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $message" | tee -a "$log_file"
}

# Function to execute a command for each instance (with optional wait time)
manage_instances() {
    local action=$1
    local wait_time=$2
    for instance in "${instances[@]}"; do
        log_message "Executing '$action' for instance $instance..."
        $ark_manager "$instance" "$action"
        if [ $? -ne 0 ]; then
            log_message "Error: Failed to $action instance $instance."
        fi
        if [ -n "$wait_time" ]; then
            log_message "Waiting $wait_time seconds before proceeding to the next instance..."
            sleep $wait_time
        fi
    done
}

# Function to send RCON command to all instances
send_rcon_to_all() {
    local command=$1
    for instance in "${instances[@]}"; do
        log_message "Sending RCON command '$command' to instance $instance..."
        $ark_manager "$instance" send_rcon "$command"
    done
}

# Function to announce the restart to all players
announce_restart() {
    # Send each announcement
    for i in "${!announcement_times[@]}"; do
        local time_before_restart=${announcement_times[$i]}
        local message="${announcement_messages[$i]}"

        send_rcon_to_all "serverchat $message"
        log_message "Announced: $message."

        # Only if there is a next value, calculate the time difference
        if [ $i -lt $((${#announcement_times[@]} - 1)) ]; then
            local next_time=${announcement_times[$((i+1))]}
            local sleep_time=$(( time_before_restart - next_time ))
            sleep "$sleep_time"
        else
            # For the last entry: Wait for the defined time
            sleep "$time_before_restart"
        fi
    done
}

# ---------- MAIN SCRIPT ----------
log_message "Starting ARK server restart process."

# 1. Announce the restart with warning messages
announce_restart

# 2. Stop the server instances one by one (no wait time between stops)
manage_instances "stop" ""

# 3. Update the server
log_message "Updating all instances..."
$ark_manager update
log_message "Update completed."

# 4. Start the server instances one by one (with wait time between starts)
manage_instances "start" "$start_wait_time"

log_message "ARK servers have been successfully restarted and updated."
