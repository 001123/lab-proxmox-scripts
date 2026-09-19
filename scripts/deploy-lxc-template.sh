#!/usr/bin/env bash
# ==============================================================================
# Script: deploy-lxc-template.sh
# Purpose: Run from Mac/Local machine to deploy Debian 12 LXC template on Proxmox
# Dependencies: ssh, scp, credentials.env (optional, will auto-read if present)
# Features: Docker CE pre-installed, Unprivileged nesting+keyctl, Golden Template Sanitization
# ==============================================================================

set -euo pipefail

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE=""
if [[ -f "${SCRIPT_DIR}/credentials.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/credentials.env"
elif [[ -f "${SCRIPT_DIR}/../credentials.env" ]]; then
    ENV_FILE="${SCRIPT_DIR}/../credentials.env"
fi

# --- Load Defaults from credentials.env if available ---
PVE_HOST_RAW=""
PVE_STORAGE="local-lvm"
PVE_BRIDGE="vmbr0"

if [[ -n "$ENV_FILE" && -f "$ENV_FILE" ]]; then
    PVE_HOST_RAW="$(grep -E '^PVE_HOST=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' || true)"
    PVE_STORAGE_VAL="$(grep -E '^PVE_STORAGE=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' || true)"
    PVE_BRIDGE_VAL="$(grep -E '^PVE_BRIDGE=' "$ENV_FILE" | cut -d '=' -f2- | tr -d '"' || true)"
    
    [[ -n "$PVE_STORAGE_VAL" ]] && PVE_STORAGE="$PVE_STORAGE_VAL"
    [[ -n "$PVE_BRIDGE_VAL" ]] && PVE_BRIDGE="$PVE_BRIDGE_VAL"
fi

# Extract IP/Hostname from PVE_HOST URL (e.g. https://192.168.250.4:8006 -> 192.168.250.4)
DEFAULT_IP=""
if [[ -n "$PVE_HOST_RAW" ]]; then
    DEFAULT_IP="$(echo "$PVE_HOST_RAW" | sed -E 's|^https?://||; s|:[0-9]+/?.*$||')"
fi

PVE_IP="${DEFAULT_IP:-192.168.250.4}"
PVE_USER="root"
PVE_SSH_PORT="22"
CT_ID="9000"
HOSTNAME="lxc-debian"
CORES="2"
MEMORY="2048"
DISK_SIZE="15"
FORCE=0
INSTALL_DOCKER=1
INSTALL_MISE=1
NODE_VERSION="lts"

# Detect Mac SSH Public Key
DEFAULT_PUB_KEY=""
if [[ -f "$HOME/.ssh/id_ed25519.pub" ]]; then
    DEFAULT_PUB_KEY="$HOME/.ssh/id_ed25519.pub"
elif [[ -f "$HOME/.ssh/id_rsa.pub" ]]; then
    DEFAULT_PUB_KEY="$HOME/.ssh/id_rsa.pub"
else
    # First .pub file found in ~/.ssh/
    FIRST_PUB="$(ls "$HOME"/.ssh/*.pub 2>/dev/null | head -n 1 || true)"
    [[ -n "$FIRST_PUB" ]] && DEFAULT_PUB_KEY="$FIRST_PUB"
fi
SSH_KEY_FILE="${DEFAULT_PUB_KEY}"

# --- Helper Functions ---
log_info() { echo -e "${BLUE}[INFO]${NC} $1"; }
log_success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
log_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1" >&2; }

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Automated deployment script executed from a Mac/workstation to provision a Debian 12 LXC Golden Template (Docker CE & Node/Mise ready) on Proxmox VE.

Options:
  -h, --host <IP|HOST>     Proxmox VE IP / Hostname (Default from credentials.env: ${PVE_IP})
  -u, --user <USER>        SSH user for Proxmox VE (Default: root)
  -p, --port <PORT>        SSH port for Proxmox VE (Default: 22)
  -i, --id <ID>            Target Container ID (Default: 9000)
  -n, --hostname <NAME>    Template hostname (Default: lxc-debian)
  -c, --cores <NUM>        Number of vCPU cores (Default: 2)
  -m, --memory <MB>        Memory allocation in MB (Default: 2048)
  -d, --disk <GB>          Rootfs disk size in GB (Default: 15)
  -s, --storage <STORAGE>  Target storage pool for rootfs (Default: ${PVE_STORAGE})
  -b, --bridge <BRIDGE>    Network bridge (Default: ${PVE_BRIDGE})
  -k, --ssh-key <PATH>     Path to local SSH public key (Default: ${SSH_KEY_FILE})
  --no-docker              Skip Docker CE installation
  --no-mise                Skip Mise and Node.js toolchain installation
  --node-version <VER>     Node.js version to install via Mise (Default: lts)
  -f, --force              Overwrite / destroy existing CT ID if present
  --help                   Display this help message and exit

Examples:
  ./$(basename "$0") --force
  ./$(basename "$0") --force -i 9000 --hostname lxc-debian
  ./$(basename "$0") --force --node-version 22
  ./$(basename "$0") --host 192.168.250.4 --ssh-key ~/.ssh/id_ed25519.pub

EOF
}

# --- Parse Arguments ---
while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--host)
            PVE_IP="$2"
            shift 2
            ;;
        -u|--user)
            PVE_USER="$2"
            shift 2
            ;;
        -p|--port)
            PVE_SSH_PORT="$2"
            shift 2
            ;;
        -i|--id)
            CT_ID="$2"
            shift 2
            ;;
        -n|--hostname)
            HOSTNAME="$2"
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
        -d|--disk)
            DISK_SIZE="$2"
            shift 2
            ;;
        -s|--storage)
            PVE_STORAGE="$2"
            shift 2
            ;;
        -b|--bridge)
            PVE_BRIDGE="$2"
            shift 2
            ;;
        -k|--ssh-key)
            SSH_KEY_FILE="$2"
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
        --help)
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

# --- Validations ---
if [[ -z "$SSH_KEY_FILE" || ! -f "$SSH_KEY_FILE" ]]; then
    log_error "SSH Public Key not found at '${SSH_KEY_FILE}'. Please verify ~/.ssh/ or supply a key using -k <path>."
    exit 1
fi

REMOTE_SCRIPT="${SCRIPT_DIR}/create-lxc-template.sh"
if [[ ! -f "$REMOTE_SCRIPT" ]]; then
    log_error "Required script not found at ${REMOTE_SCRIPT}!"
    exit 1
fi

KEY_BASENAME="$(basename "$SSH_KEY_FILE")"
REMOTE_TMP_DIR="/tmp/pve-template-deploy-$$"

echo ""
echo -e "${CYAN}==============================================================${NC}"
echo -e "${CYAN}    DEPLOY DEBIAN 12 LXC TEMPLATE (DOCKER & MISE/NODE)        ${NC}"
echo -e "${CYAN}==============================================================${NC}"
printf "%-22s : %s\n" "Proxmox Host" "${PVE_USER}@${PVE_IP}:${PVE_SSH_PORT}"
printf "%-22s : %s (%s)\n" "Template ID / Name" "$CT_ID" "$HOSTNAME"
printf "%-22s : %s vCPU | %s MB RAM | %s GB Disk\n" "Hardware Profile" "$CORES" "$MEMORY" "$DISK_SIZE"
printf "%-22s : %s\n" "Local SSH Public Key" "$SSH_KEY_FILE"
printf "%-22s : %s\n" "Target Storage" "$PVE_STORAGE"
printf "%-22s : %s\n" "Network Bridge" "$PVE_BRIDGE"
printf "%-22s : %s\n" "Install Docker CE" "$([[ $INSTALL_DOCKER -eq 1 ]] && echo 'YES (Docker CE + Compose Plugin)' || echo 'NO')"
printf "%-22s : %s\n" "Install Mise & Node" "$([[ $INSTALL_MISE -eq 1 ]] && echo "YES (Node.js ${NODE_VERSION} + pnpm + yarn)" || echo 'NO')"
printf "%-22s : %s\n" "Force Overwrite" "$([[ $FORCE -eq 1 ]] && echo 'YES' || echo 'NO')"
echo -e "${CYAN}==============================================================${NC}"
echo ""

# --- Step 1: Transfer Script & SSH Key to Proxmox ---
log_info "1. Creating remote temporary directory and uploading scripts to Proxmox (${PVE_IP})..."

ssh -p "$PVE_SSH_PORT" -o BatchMode=no -o ConnectTimeout=10 "${PVE_USER}@${PVE_IP}" "mkdir -p '${REMOTE_TMP_DIR}'"

scp -P "$PVE_SSH_PORT" "$REMOTE_SCRIPT" "$SSH_KEY_FILE" "${PVE_USER}@${PVE_IP}:${REMOTE_TMP_DIR}/"

log_success "Successfully uploaded provisioning scripts and public key to ${REMOTE_TMP_DIR} on Proxmox."

# --- Step 2: Execute create-lxc-template.sh on Proxmox ---
log_info "2. Launching LXC template creation on Proxmox VE host..."

EXTRA_ARGS=""
if [[ "$FORCE" -eq 1 ]]; then
    EXTRA_ARGS="${EXTRA_ARGS} --force"
fi
if [[ "$INSTALL_DOCKER" -eq 0 ]]; then
    EXTRA_ARGS="${EXTRA_ARGS} --no-docker"
fi
if [[ "$INSTALL_MISE" -eq 0 ]]; then
    EXTRA_ARGS="${EXTRA_ARGS} --no-mise"
fi
if [[ -n "$NODE_VERSION" && "$NODE_VERSION" != "lts" ]]; then
    EXTRA_ARGS="${EXTRA_ARGS} --node-version '${NODE_VERSION}'"
fi

ssh -p "$PVE_SSH_PORT" "${PVE_USER}@${PVE_IP}" \
    "bash ${REMOTE_TMP_DIR}/create-lxc-template.sh \
        --id '${CT_ID}' \
        --hostname '${HOSTNAME}' \
        --cores '${CORES}' \
        --memory '${MEMORY}' \
        --disk '${DISK_SIZE}' \
        --storage '${PVE_STORAGE}' \
        --bridge '${PVE_BRIDGE}' \
        --ssh-key '${REMOTE_TMP_DIR}/${KEY_BASENAME}' \
        ${EXTRA_ARGS}"

# --- Step 3: Cleanup ---
log_info "3. Cleaning up temporary files on Proxmox host..."
ssh -p "$PVE_SSH_PORT" "${PVE_USER}@${PVE_IP}" "rm -rf '${REMOTE_TMP_DIR}'" 2>/dev/null || true

log_success "LXC Template deployment completed successfully (${CT_ID} - ${HOSTNAME})!"
