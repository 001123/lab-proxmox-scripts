#!/usr/bin/env bash
# ==============================================================================
# Script: create-lxc-template.sh
# Purpose: Create a Debian 12 LXC Container Template with Docker CE on Proxmox VE
# Specs: 2 vCPU, 2048MB RAM, 1024MB Swap, 15GB SSD Disk, Unprivileged + Nesting + Keyctl
# Features: Docker CE, Docker Compose, Unprivileged Docker ready, Golden Template Sanitization
# ==============================================================================

set -euo pipefail

# --- Color Definitions for Output ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Default Configurations ---
CT_ID="${CT_ID:-9000}"
CORES="${CORES:-2}"
MEMORY="${MEMORY:-2048}"
SWAP="${SWAP:-1024}"
DISK_SIZE="${DISK_SIZE:-15}"          # in GB
STORAGE="${STORAGE:-local-lvm}"       # Storage pool for CT rootfs (SSD)
TMPL_STORAGE="${TMPL_STORAGE:-local}" # Storage pool containing template cache
TMPL_FILE="${TMPL_FILE:-debian-12-standard_12.12-1_amd64.tar.zst}"
BRIDGE="${BRIDGE:-vmbr0}"
HOSTNAME="${HOSTNAME:-lxc-debian}"
SSH_KEY_FILE="${SSH_KEY_FILE:-}"
FORCE="${FORCE:-0}"
INSTALL_DOCKER="${INSTALL_DOCKER:-1}"
INSTALL_MISE="${INSTALL_MISE:-1}"
NODE_VERSION="${NODE_VERSION:-lts}"

# --- Helper Functions ---
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1" >&2
}

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automated provisioning script to create a Debian 12 LXC Golden Template pre-configured with Docker CE, Mise, and Node.js LTS on Proxmox VE.

Options:
  -i, --id <ID>           Container ID (Default: 9000)
  -s, --storage <NAME>    Storage pool for rootfs (Default: local-lvm)
  -t, --template <FILE>   Template tar.zst filename (Default: debian-12-standard_12.12-1_amd64.tar.zst)
  --tmpl-storage <NAME>   Storage pool hosting the template file (Default: local)
  -k, --ssh-key <PATH>    Path to SSH public key to inject into root
  -b, --bridge <NAME>     Linux Network Bridge (Default: vmbr0)
  -c, --cores <NUM>       Number of CPU cores (Default: 2)
  -m, --memory <MB>       RAM size in MB (Default: 2048)
  --swap <MB>             Swap size in MB (Default: 1024)
  -d, --disk <GB>         Disk size in GB (Default: 15)
  -n, --hostname <NAME>   Container hostname (Default: lxc-debian)
  --no-docker             Skip Docker CE installation
  --no-mise               Skip Mise and Node.js toolchain installation
  --node-version <VER>    Node.js version to install via Mise (Default: lts)
  -f, --force             Overwrite / destroy existing Container ID if present
  -h, --help              Display this help message and exit

Examples:
  $(basename "$0") --ssh-key /tmp/id_ed25519.pub
  $(basename "$0") -i 9000 -s local-lvm --force -k /root/.ssh/id_ed25519.pub
  $(basename "$0") --force --node-version 22

EOF
}

# --- Parse Command Line Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--id)
            CT_ID="$2"
            shift 2
            ;;
        -s|--storage)
            STORAGE="$2"
            shift 2
            ;;
        -t|--template)
            TMPL_FILE="$2"
            shift 2
            ;;
        --tmpl-storage)
            TMPL_STORAGE="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY_FILE="$2"
            shift 2
            ;;
        -b|--bridge)
            BRIDGE="$2"
            shift 2
            ;;
        -c|--cores)
            CORES="$2"
            shift 2
            ;;
        -m|--memory)
            MEMORY="$2"
            shift 2
            ;;
        --swap)
            SWAP="$2"
            shift 2
            ;;
        -d|--disk)
            DISK_SIZE="$2"
            shift 2
            ;;
        -n|--hostname)
            HOSTNAME="$2"
            shift 2
            ;;
        --no-docker)
            INSTALL_DOCKER=0
            shift
            ;;
        --no-mise)
            INSTALL_MISE=0
            shift
            ;;
        --node-version)
            NODE_VERSION="$2"
            shift 2
            ;;
        -f|--force)
            FORCE=1
            shift
            ;;
        -h|--help)
            print_usage
            exit 0
            ;;
        *)
            log_error "Invalid option: $1"
            print_usage
            exit 1
            ;;
    esac
done

# --- Prerequisites Validation ---
log_info "=== Initializing Debian 12 LXC Container Template (Docker & Node Ready) ==="

# 1. Check Root Privileges
if [[ "${EUID}" -ne 0 ]]; then
    log_error "This script requires root privileges to execute pct/pvesm on Proxmox VE."
    exit 1
fi

# 2. Check Proxmox CLI tools
for cmd in pct pvesm; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Command '$cmd' not found. Ensure this script runs directly on a Proxmox VE host."
        exit 1
    fi
done

# 3. Check Target Storage
log_info "Verifying rootfs storage pool: '${STORAGE}'..."
if ! pvesm status --storage "$STORAGE" &>/dev/null; then
    log_error "Storage pool '${STORAGE}' does not exist or is inactive on this node."
    log_info "Available storage pools:"
    pvesm status
    exit 1
fi
log_success "Storage pool '${STORAGE}' is ready."

# 4. Check Template File
FULL_TMPL_SPEC="${TMPL_STORAGE}:vztmpl/${TMPL_FILE}"
TMPL_LOCAL_PATH="/var/lib/vz/template/cache/${TMPL_FILE}"

log_info "Verifying base OS template: ${FULL_TMPL_SPEC}..."

TEMPLATE_FOUND=0
if [[ -f "$TMPL_LOCAL_PATH" ]]; then
    TEMPLATE_FOUND=1
elif pvesm list "$TMPL_STORAGE" --content vztmpl 2>/dev/null | grep -q "$TMPL_FILE"; then
    TEMPLATE_FOUND=1
fi

if [[ "$TEMPLATE_FOUND" -eq 0 ]]; then
    log_warn "Base template '${TMPL_FILE}' not found in storage '${TMPL_STORAGE}'."
    log_info "Checking available appliances repository via pveam..."
    
    if command -v pveam &>/dev/null; then
        pveam update || true
        log_info "Attempting to download '${TMPL_FILE}' to storage '${TMPL_STORAGE}'..."
        if pveam download "$TMPL_STORAGE" "$TMPL_FILE"; then
            log_success "Successfully downloaded template: ${TMPL_FILE}"
        else
            log_error "Failed to automatically download template '${TMPL_FILE}'. Please verify cache in /var/lib/vz/template/cache/."
            exit 1
        fi
    else
        log_error "Please place '${TMPL_FILE}' in Proxmox template cache directory (/var/lib/vz/template/cache/)."
        exit 1
    fi
else
    log_success "Verified base template file: ${FULL_TMPL_SPEC}"
fi

# 5. Check SSH Key
SSH_KEY_ARG=()
if [[ -n "$SSH_KEY_FILE" ]]; then
    if [[ -f "$SSH_KEY_FILE" ]]; then
        log_info "Using SSH Public Key from: ${SSH_KEY_FILE}"
        SSH_KEY_ARG=("--ssh-public-keys" "$SSH_KEY_FILE")
    else
        log_error "SSH Key file '${SSH_KEY_FILE}' not found!"
        exit 1
    fi
else
    # Check default host keys as fallback
    if [[ -f "/root/.ssh/authorized_keys" ]]; then
        log_info "No --ssh-key specified, automatically using host /root/.ssh/authorized_keys."
        SSH_KEY_ARG=("--ssh-public-keys" "/root/.ssh/authorized_keys")
    else
        log_warn "No SSH key found. Container will not have a pre-configured SSH key."
    fi
fi

# 6. Check Container ID Conflict / Cleanup
if pct status "$CT_ID" &>/dev/null || [[ -f "/etc/pve/lxc/${CT_ID}.conf" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        log_warn "Container / Template ID ${CT_ID} already exists. Stopping and purging (--force enabled)..."
        pct stop "$CT_ID" 2>/dev/null || true
        pct destroy "$CT_ID" --purge 1 --force 1 --destroy-unreferenced-disks 1
        log_success "Purged previous container / template: ${CT_ID}"
    else
        log_error "Container / Template ID ${CT_ID} already exists!"
        log_info "Suggestion: Specify another ID with '-i <ID>' or pass '-f / --force' to overwrite."
        exit 1
    fi
fi

# --- Print Plan Summary ---
echo ""
echo -e "${CYAN}--------------------------------------------------${NC}"
echo -e "${CYAN}           LXC TEMPLATE CONFIGURATION             ${NC}"
echo -e "${CYAN}--------------------------------------------------${NC}"
printf "%-20s : %s\n" "Container ID" "$CT_ID"
printf "%-20s : %s\n" "Hostname" "$HOSTNAME"
printf "%-20s : %s\n" "OS Template" "$FULL_TMPL_SPEC"
printf "%-20s : %s Cores\n" "CPU" "$CORES"
printf "%-20s : %s MB\n" "RAM" "$MEMORY"
printf "%-20s : %s MB\n" "Swap" "$SWAP"
printf "%-20s : %s GB (%s)\n" "Rootfs Storage" "$DISK_SIZE" "$STORAGE"
printf "%-20s : %s (DHCP, Firewall: on)\n" "Network" "$BRIDGE"
printf "%-20s : %s\n" "Features" "nesting=1,keyctl=1 (Docker ready)"
printf "%-20s : %s\n" "Install Docker CE" "$([[ $INSTALL_DOCKER -eq 1 ]] && echo 'YES (Docker CE + Compose Plugin)' || echo 'NO')"
printf "%-20s : %s\n" "Install Mise & Node" "$([[ $INSTALL_MISE -eq 1 ]] && echo "YES (Node.js ${NODE_VERSION} + pnpm + yarn)" || echo 'NO')"
if [[ ${#SSH_KEY_ARG[@]} -gt 0 ]]; then
printf "%-20s : %s\n" "SSH Key Injected" "${SSH_KEY_ARG[1]}"
else
printf "%-20s : %s\n" "SSH Key Injected" "None"
fi
echo -e "${CYAN}--------------------------------------------------${NC}"
echo ""

# --- Step 1: Create LXC Container ---
log_info "1. Creating LXC container ID: ${CT_ID}..."

pct create "$CT_ID" "$FULL_TMPL_SPEC" \
    --cores "$CORES" \
    --memory "$MEMORY" \
    --swap "$SWAP" \
    --rootfs "${STORAGE}:${DISK_SIZE}" \
    --net0 "name=eth0,bridge=${BRIDGE},ip=dhcp,firewall=1" \
    --unprivileged 1 \
    --features "nesting=1,keyctl=1" \
    --hostname "$HOSTNAME" \
    --onboot 0 \
    --start 0 \
    "${SSH_KEY_ARG[@]}"

log_success "LXC container ${CT_ID} created successfully."

# --- Step 2: Provision Software inside Container (if enabled) ---
NEED_START=0
if [[ "$INSTALL_DOCKER" -eq 1 || "$INSTALL_MISE" -eq 1 ]]; then
    NEED_START=1
fi

if [[ "$NEED_START" -eq 1 ]]; then
    log_info "2. Starting container ${CT_ID} for software provisioning..."
    pct start "$CT_ID"

    log_info "Waiting for container internet connectivity via DHCP..."
    NET_READY=0
    for i in $(seq 1 30); do
        if pct exec "$CT_ID" -- ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
            NET_READY=1
            break
        fi
        sleep 1
    done

    if [[ "$NET_READY" -eq 0 ]]; then
        log_error "Container ${CT_ID} has no internet connectivity after 30 seconds. Verify bridge '${BRIDGE}' and DHCP server."
        pct stop "$CT_ID" 2>/dev/null || true
        exit 1
    fi
    log_success "Container internet connectivity is operational."

    log_info "Updating APT and installing essential utilities (curl, wget, git, ca-certificates, sudo)..."
    pct exec "$CT_ID" -- bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        echo "[CT] Updating APT package index..."
        apt-get update -y

        echo "[CT] Installing core utilities..."
        apt-get install -y --no-install-recommends \
            ca-certificates \
            curl \
            wget \
            git \
            gnupg \
            lsb-release \
            sudo

        echo "[CT] Configuring Console Autologin for root user..."
        mkdir -p /etc/systemd/system/container-getty@.service.d
        cat << "AUTOLOGIN_EOF" > /etc/systemd/system/container-getty@.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud tty%I 115200,38400,9600 $TERM
AUTOLOGIN_EOF

        mkdir -p /etc/systemd/system/console-getty.service.d
        cat << "AUTOLOGIN_EOF" > /etc/systemd/system/console-getty.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear --keep-baud console 115200,38400,9600 $TERM
AUTOLOGIN_EOF

        mkdir -p /etc/systemd/system/getty@tty1.service.d
        cat << "AUTOLOGIN_EOF" > /etc/systemd/system/getty@tty1.service.d/override.conf
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin root --noclear %I $TERM
AUTOLOGIN_EOF

        systemctl daemon-reload
    '

    # --- Step 2.1: Install Docker CE (if enabled) ---
    if [[ "$INSTALL_DOCKER" -eq 1 ]]; then
        log_info "Installing Docker CE and Docker Compose Plugin from official Docker APT repository..."
        pct exec "$CT_ID" -- bash -c '
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive

            echo "[CT] Adding official Docker APT repository..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc

            ARCH="$(dpkg --print-architecture)"
            CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
            echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list

            echo "[CT] Installing Docker CE, CLI, Containerd, and Compose plugins..."
            apt-get update -y
            apt-get install -y --no-install-recommends \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin

            echo "[CT] Enabling and starting Docker daemon..."
            systemctl enable docker
            systemctl start docker
        '

        log_info "Verifying Docker installation in container:"
        pct exec "$CT_ID" -- docker --version
        pct exec "$CT_ID" -- docker compose version
        log_success "Docker CE successfully installed and running!"
    fi

    # --- Step 2.2: Install Mise & Node.js (if enabled) ---
    if [[ "$INSTALL_MISE" -eq 1 ]]; then
        log_info "Installing Mise via official APT repository and setting up Node.js (${NODE_VERSION})..."
        pct exec "$CT_ID" -- bash -c '
            set -euo pipefail
            NODE_VER="$1"
            export DEBIAN_FRONTEND=noninteractive

            echo "[CT] Adding official Mise APT repository..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor -o /etc/apt/keyrings/mise-archive-keyring.gpg
            chmod a+r /etc/apt/keyrings/mise-archive-keyring.gpg

            ARCH="$(dpkg --print-architecture)"
            echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=${ARCH}] https://mise.jdx.dev/deb stable main" > /etc/apt/sources.list.d/mise.list

            apt-get update -y
            apt-get install -y --no-install-recommends mise

            echo "[CT] Installing Node.js (${NODE_VER}) via Mise..."
            export MISE_DATA_DIR="/root/.local/share/mise"
            export MISE_CONFIG_DIR="/root/.config/mise"
            export MISE_CACHE_DIR="/root/.cache/mise"

            # Install specified Node version and configure as global default
            mise use -g "node@${NODE_VER}"

            # Enable Corepack (pnpm & yarn)
            echo "[CT] Enabling Corepack (pnpm & yarn)..."
            export PATH="/root/.local/share/mise/shims:$PATH"
            corepack enable || true
            corepack enable pnpm yarn || true
            mise reshim || true

            # Warm up pnpm and yarn through Corepack to pre-fetch binaries into template
            pnpm --version >/dev/null 2>&1 || true
            yarn --version >/dev/null 2>&1 || true

            # Create symlinks in /usr/bin and /usr/local/bin for immediate non-interactive/SSH access
            for tool in node npm npx corepack pnpm yarn; do
                if [[ -e "/root/.local/share/mise/shims/${tool}" ]]; then
                    ln -sf "/root/.local/share/mise/shims/${tool}" "/usr/local/bin/${tool}"
                    ln -sf "/root/.local/share/mise/shims/${tool}" "/usr/bin/${tool}"
                fi
            done

            echo "[CT] Configuring system-wide and root shell environments..."
            # 1. /etc/environment (for SSH non-interactive & PAM login)
            if grep -q "PATH=" /etc/environment 2>/dev/null; then
                if ! grep -q "/root/.local/share/mise/shims" /etc/environment; then
                    sed -i "s|PATH=\"|PATH=\"/root/.local/share/mise/shims:|" /etc/environment
                fi
            else
                echo "PATH=\"/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" >> /etc/environment
            fi

            # 2. /etc/profile.d/mise.sh (for interactive login shells)
            cat << "PROFILE_EOF" > /etc/profile.d/mise.sh
if [ -d "/root/.local/share/mise/shims" ]; then
    case ":$PATH:" in
        *:/root/.local/share/mise/shims:*) ;;
        *) export PATH="/root/.local/share/mise/shims:$PATH" ;;
    esac
fi
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi
PROFILE_EOF
            chmod +x /etc/profile.d/mise.sh

            # 3. /root/.bashrc (for root interactive shell)
            if ! grep -q "mise activate bash" /root/.bashrc 2>/dev/null; then
                cat << "BASHRC_EOF" >> /root/.bashrc

# Mise polyglot tool version manager
export PATH="/root/.local/share/mise/shims:$PATH"
if command -v mise >/dev/null 2>&1; then
    eval "$(mise activate bash)"
fi
BASHRC_EOF
            fi
        ' _ "$NODE_VERSION"

        log_info "Verifying Mise & Node.js environment in container:"
        pct exec "$CT_ID" -- mise --version
        pct exec "$CT_ID" -- node -v
        pct exec "$CT_ID" -- npm -v
        pct exec "$CT_ID" -- pnpm -v
        pct exec "$CT_ID" -- yarn -v
        log_success "Mise and Node.js (${NODE_VERSION}) installed and configured successfully!"
    fi

    # --- Step 3: Golden Template Sanitization ---
    log_info "3. Sanitizing container before creating golden template..."
    pct exec "$CT_ID" -- bash -c '
        set -euo pipefail

        echo "[CT] Stopping Docker daemon before sanitization..."
        systemctl stop docker 2>/dev/null || true

        echo "[CT] Purging Mise and NPM caches..."
        rm -rf /root/.cache/mise /root/.npm/_cacache

        echo "[CT] Purging APT cache and temporary files..."
        apt-get clean
        rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

        echo "[CT] Resetting /etc/machine-id to prevent DHCP conflicts across clones..."
        truncate -s 0 /etc/machine-id
        rm -f /var/lib/dbus/machine-id
        ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

        echo "[CT] Purging shell command history..."
        cat /dev/null > /root/.bash_history 2>/dev/null || true
        history -c 2>/dev/null || true

        echo "[CT] Truncating system log files..."
        find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true
    '
    log_success "Container sanitization completed successfully."

    log_info "Stopping container ${CT_ID}..."
    pct stop "$CT_ID"
    sleep 2
fi

# --- Step 4: Convert LXC to Template ---
log_info "4. Converting container ${CT_ID} to Proxmox VE template..."
pct template "$CT_ID"
log_success "Successfully converted Container ${CT_ID} to Template!"

echo ""
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}    LXC CONTAINER TEMPLATE CREATED SUCCESSFULLY! (${CT_ID})     ${NC}"
echo -e "${GREEN}==============================================================${NC}"
printf "%-20s : %s\n" "Template ID" "$CT_ID"
printf "%-20s : %s\n" "Template Name" "$HOSTNAME"
printf "%-20s : %s Cores | %s MB RAM | %s GB Disk\n" "Hardware Profile" "$CORES" "$MEMORY" "$DISK_SIZE"
printf "%-20s : %s\n" "Docker CE" "$([[ $INSTALL_DOCKER -eq 1 ]] && echo 'Pre-installed & Ready' || echo 'Not installed')"
printf "%-20s : %s\n" "Mise & Node.js" "$([[ $INSTALL_MISE -eq 1 ]] && echo "Node.js ${NODE_VERSION} + pnpm + yarn" || echo 'Not installed')"
echo -e "${GREEN}--------------------------------------------------------------${NC}"
echo -e "You can manage the template via Proxmox Web GUI or clone it via CLI:"
echo -e "  ${YELLOW}pct clone ${CT_ID} <NEW_ID> --hostname my-app --full 1${NC}"
echo -e "  ${YELLOW}pct start <NEW_ID>${NC}"
echo -e "  ${YELLOW}pct exec <NEW_ID> -- docker ps${NC}"
echo -e "  ${YELLOW}pct exec <NEW_ID> -- node -v${NC}"
echo ""
