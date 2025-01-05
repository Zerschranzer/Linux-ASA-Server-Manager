# ARK: Survival Ascended Linux Server Manager – Docker & Non-Docker

This repository provides a set of scripts—primarily **`ark_instance_manager.sh`** and **`ark_docker_manager.sh`**—for installing and managing **ARK: Survival Ascended** (ASA) servers on Linux. Since there is **no official Linux server** for ASA, these scripts leverage **Proton** (plus other utilities) to run the Windows server executable on Linux. The solution does *not* require Docker and includes features for multi-instance management, backups, automated restarts, and more.

> **Note**: There is **also a Docker-based script**, **`ark_docker_manager.sh`**, which containerizes the entire setup if you prefer Docker. This script uses Docker containers to run the server instances, with the **server files and configurations mounted as Docker volumes**. This approach ensures that the server data remains accessible and separate from the containerized runtime environment while leveraging Docker for process isolation and dependency management.  
The **usage** of both scripts is nearly **identical**—commands, instance creation, backups, and restarts work the same way. With the Docker-based script, the server binaries and save data are shared through volumes, allowing the same file structure as the non-Docker setup. For simplicity, this README focuses on **`ark_instance_manager.sh`**; if you choose the Docker route, simply run **`ark_docker_manager.sh`** instead and follow the same steps.  

If you prefer the flexibility and modularity of Docker, the **`ark_docker_manager.sh`** script makes it easy to containerize your server setup without changing the workflow or configuration methods.

---

## Table of Contents

- [1. Key Features](#1-key-features)  
- [2. System Requirements](#2-system-requirements)  
- [3. Installation & Setup](#3-installation--setup)  
- [4. Usage](#4-usage)  
  - [4.1 Interactive Menu](#41-interactive-menu)  
  - [4.2 Command-Line Usage](#42-command-line-usage)  
- [5. Managing Instances](#5-managing-instances)  
  - [5.1 Creating a New Instance](#51-creating-a-new-instance)  
  - [5.2 Configuration Files](#52-configuration-files)  
  - [5.3 Maps and Mods](#53-maps-and-mods)  
  - [5.4 Clustering](#54-clustering)  
- [6. Backups & Restores](#6-backups--restores)  
- [7. Automated Restarts](#7-automated-restarts)  
- [8. RCON Console](#8-rcon-console)  
- [9. Troubleshooting](#9-troubleshooting)  
- [10. Credits](#10-credits)  
- [11. License](#11-license)

---

## 1. Key Features

- **No Docker Required** – Runs the Windows ASA server on Linux via Proton. (Or use the Docker script if you prefer!)  
- **Automatic Dependency Checking** – Installs or warns about missing libraries (e.g., 32-bit libs, Python). (only for non Docker version)
- **Multi-Instance Management** – Configure and run multiple servers on one machine.  
- **Interactive Menu** – User-friendly text-based UI for setup, instance creation, and day-to-day tasks.  
- **Command-Line Interface** – Ideal for automation (cron jobs, scripts) or remote management.  
- **Support for Mods & Maps** – Specify custom maps and Mod IDs in each instance’s config.  
- **Custom Start Parameters** – Easily enable crossplay or disable BattlEye in `instance_config.ini`.  
- **Cluster Support** – Link multiple servers under one Cluster ID for cross-server transfers.  
- **Backup & Restore** – Archive world folders to `.tar.gz` and restore them when needed.  
- **Automated Restarts** – Optional script announces, updates, and restarts your servers on a schedule.  
- **RCON Integration** – A Python-based RCON client (`rcon.py`) for server commands and chat messages.

---

## 2. System Requirements

- **CPU**: Minimum 4 cores (6–8 recommended).  
- **RAM**: Minimum 16 GB (8 GB often leads to crashes or poor performance).  
- **Storage**: Enough disk space for ARK server files (can be quite large).  
- **Linux Distribution** with a package manager (`apt-get`, `zypper`, `dnf`, or `pacman`).  
- **sudo/root privileges** if you need to install missing dependencies.  
- **Internet Connection** for downloading server files, SteamCMD, and Proton.

> **Note**: ASA is resource-intensive. Monitor your CPU/RAM usage if running multiple instances.

---

## 3. Installation & Setup

1. **Clone this repository**:
   ```bash
   git clone https://github.com/Zerschranzer/Linux-ASA-Server-Manager.git
   cd Linux-ASA-Server-Manager
   ```

2. **Make scripts executable**:
   ```bash
   chmod +x ark_instance_manager.sh ark_restart_manager.sh rcon.py
   ```
   *(If using Docker, also `chmod +x ark_docker_manager.sh`.)*

3. **Run `ark_instance_manager.sh` (no arguments)**:
   ```bash
   ./ark_instance_manager.sh
   ```
   - From the **interactive menu**, choose **"Install/Update Base Server"**.  
   - This installs (or updates) ASA server files via SteamCMD.  
   - **Important**: Always do this step before creating any instances to ensure all server binaries and Proton are properly set up.

4. **(Optional) Create a symlink** to run the script from anywhere:
   ```bash
   ./ark_instance_manager.sh setup
   ```
   - This adds `asa-manager` to `~/.local/bin` (if on your PATH), so you can type `asa-manager` globally.

> If you prefer Docker, the above steps also apply to **`ark_docker_manager.sh`**. Just pick **"Create ARK base image"** from the menu instead of **"Install/Update Base Server"**.

![Installing or Updating the Base Server](https://raw.githubusercontent.com/Zerschranzer/Linux-ASA-Server-Manager/refs/heads/main/docs/images/Installing%E2%81%84Updating_Baseserver.png)

---

## 4. Usage

### 4.1 Interactive Menu

Running **`./ark_instance_manager.sh`** with **no arguments** enters a menu-based interface:
```
1) Install/Update Base Server
2) List Instances
3) Create New Instance
4) Manage Instance
...
```
Use the numbered options to install the server, create/edit instances, start/stop servers, manage backups, etc.

*(With Docker: `./ark_docker_manager.sh` provides a nearly identical menu.)*

### 4.2 Command-Line Usage

For quick tasks or automation, pass arguments directly:

```bash
# Installs/updates the base server
./ark_instance_manager.sh update

# Starts all existing instances
./ark_instance_manager.sh start_all

# Stops all running instances
./ark_instance_manager.sh stop_all

# Shows which instances are currently running
./ark_instance_manager.sh show_running

# Deletes an instance (prompts for confirmation)
./ark_instance_manager.sh delete <instance_name>

# Managing a specific instance
./ark_instance_manager.sh <instance_name> start
./ark_instance_manager.sh <instance_name> stop
./ark_instance_manager.sh <instance_name> restart
./ark_instance_manager.sh <instance_name> send_rcon "<RCON command>"
./ark_instance_manager.sh <instance_name> backup <world_folder>
```
*(In Docker mode, replace `ark_instance_manager.sh` with `ark_docker_manager.sh`.)*

Use these for scripts (like cron) or when you know exactly what action is needed.

---

## 5. Managing Instances

Each instance lives in `instances/<instance_name>` with its own configs and logs, allowing fully independent servers.

### 5.1 Creating a New Instance

1. In the **interactive menu**, choose **"Create New Instance"**.  
2. Enter a **unique name** (e.g., `island_server_1`, `gen2_pvp`); avoid extremely similar names like `instance` vs. `instance1`.  
3. The script creates the folder structure and opens `instance_config.ini` for you to edit.

![Create Instance](https://raw.githubusercontent.com/Zerschranzer/Linux-ASA-Server-Manager/refs/heads/main/docs/images/Create_Instance.png)

### 5.2 Configuration Files

1. **`instance_config.ini`**  
   - Main server settings for each instance, such as:
     - `ServerName`, `ServerPassword`, `ServerAdminPassword`, `MaxPlayers`  
     - `MapName`, `ModIDs`, `Port`, `QueryPort`, `RCONPort`, `SaveDir`  
     - `ClusterID` (if clustering), `CustomStartParameters` (e.g., `-NoBattlEye -crossplay`)  
2. **`GameUserSettings.ini`** in `instances/<instance_name>/Config/`  
   - ARK’s standard server settings (XP rates, rules, etc.).  
3. **`Game.ini`** (optional)  
   - For advanced config (engrams, spawn weights, etc.).

> **Tip**: Stopping the server before editing these files is recommended. Changes apply on the next start.

### 5.3 Maps and Mods

- **Map**: Set `MapName` in `instance_config.ini` (e.g., `TheIsland_WP`, `Fjordur_WP`).  
- **Mods**: Add a comma-separated list of mod IDs under `ModIDs=`.

### 5.4 Clustering

1. Set a **shared `ClusterID`** in each instance’s `instance_config.ini`.  
2. The script automatically creates a cluster directory and links them.  
3. Players can transfer characters/dinos/items between these servers in-game.

---

## 6. Backups & Restores

**Backups** preserve your world data in `.tar.gz` archives:

- **Via menu**: **"Backup a World from Instance"**. Select the instance and world folder.  
- **Via CLI**:
  ```bash
  ./ark_instance_manager.sh <instance_name> backup <world_folder>
  ```
  It creates an archive in `backups/`.  
  > **Stop** the server first to avoid corrupt backups.

**Restores** are menu-driven under **"Load Backup to Instance"**. This overwrites existing world files with those from your chosen archive.

![Backup and Restore Menu](https://raw.githubusercontent.com/Zerschranzer/Linux-ASA-Server-Manager/refs/heads/main/docs/images/Backup.png)

---

## 7. Automated Restarts

The **ARK Server Manager** now makes it easy to configure automated restarts, tailored for users of all experience levels. Restart automation is integrated directly into the interactive menu, eliminating the need for manual configuration.

### Configuration via the Interactive Menu

To set up automated restarts:

1. Open the **ARK Server Manager** and select **"12) Configure Restart Manager"** from the main menu.  
2. Follow the prompts to:
   - Select the instances for which you want to enable automated restarts.  
   - Define announcement times and messages for notifying players before the restart.  
   - Schedule a daily restart time using Cron (e.g., every day at 3:00 AM).  

The configuration is automatically applied, and any existing Cron jobs for the restart manager are updated or replaced. This ensures the process is both simple and error-free for all users.

![Restart Manager Menu](https://raw.githubusercontent.com/Zerschranzer/Linux-ASA-Server-Manager/refs/heads/main/docs/images/Restart_Manager.png)

### Advanced: Manual Configuration

For advanced users, manual configuration is still possible by editing the top of `ark_restart_manager.sh`:

- `instances=("myserver1" "myserver2")`  
- `announcement_times=(1800 1200 600 180 10)`  
- `announcement_messages=("Server restart in 30 minutes" ... )`  

### Scheduling with Cron

The interactive menu also automates the Cron job setup. If you prefer manual scheduling, you can still add the following to your crontab:

```bash
crontab -e
# Example: daily restarts at 4:00 AM
0 4 * * * /path/to/ark_restart_manager.sh
```

Logs are kept in `ark_restart_manager.log`.

---

## 8. RCON Console

The **`rcon.py`** script is a Python-based RCON client:

```bash
./rcon.py 127.0.0.1:27020 -p "MyRconPassword"
```
- Opens an interactive console (`RCON>`) to send commands (e.g., `broadcast Hello!`).

Or send a single command:
```bash
./rcon.py 127.0.0.1:27020 -p "MyRconPassword" -c "SaveWorld"
```

**`ark_instance_manager.sh`** uses `rcon.py` for graceful shutdown and interactive RCON access from the menu.  
*(Again, this applies equally to **`ark_docker_manager.sh`**.)*

![RCON Console Example](https://raw.githubusercontent.com/Zerschranzer/Linux-ASA-Server-Manager/refs/heads/main/docs/images/RCON_Example.png)

---

## 9. Troubleshooting

- **Check Logs**: `instances/<instance_name>/server.log` for server errors. In Docker mode, you can also check with `docker logs ark_<instance_name>`.  
- **Dependencies**: If missing, the script instructs how to install them for your distro.  
- **Unique Ports**: Ensure each instance uses different ports, and open them in your firewall if needed.  
- **Naming Collisions**: Distinct instance names prevent accidentally stopping the wrong server.  
- **System Resources**: ASA is resource-heavy; watch CPU/RAM usage, especially with multiple instances.  

---

## 10. Credits

- [SteamCMD](https://developer.valvesoftware.com/wiki/SteamCMD) for server file updates.  
- [Proton GE Custom](https://github.com/GloriousEggroll/proton-ge-custom) for running Windows apps on Linux.  
- **Docker** (for `ark_docker_manager.sh`) if you choose the containerized approach.

---

## 11. License

This project is licensed under the [MIT License](LICENSE). Feel free to modify and share these scripts. If you enhance or fix them, consider opening a PR so others benefit.

---

**Enjoy managing your Ark Survival Ascended server(s) on Linux!**  
If you run into any issues or have suggestions, please open an issue or pull request on GitHub.
