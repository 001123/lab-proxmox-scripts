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

Tự động tạo LXC Container Template Debian 12 tích hợp Docker CE, Mise & Node.js LTS trên Proxmox VE.

Options:
  -i, --id <ID>           Container ID (Mặc định: 9000)
  -s, --storage <NAME>    Storage pool cho Rootfs (Mặc định: local-lvm)
  -t, --template <FILE>   Tên file template tar.zst (Mặc định: debian-12-standard_12.12-1_amd64.tar.zst)
  --tmpl-storage <NAME>   Storage lưu trữ file template (Mặc định: local)
  -k, --ssh-key <PATH>    Đường dẫn tới file SSH Public Key cần chèn vào root
  -b, --bridge <NAME>     Linux Network Bridge (Mặc định: vmbr0)
  -c, --cores <NUM>       Số CPU Cores (Mặc định: 2)
  -m, --memory <MB>       Dung lượng RAM MB (Mặc định: 2048)
  --swap <MB>             Dung lượng Swap MB (Mặc định: 1024)
  -d, --disk <GB>         Dung lượng ổ đĩa GB (Mặc định: 15)
  -n, --hostname <NAME>   Hostname cho container (Mặc định: lxc-debian)
  --no-docker             Bỏ qua bước cài đặt Docker CE
  --no-mise               Bỏ qua bước cài đặt Mise và Node.js
  --node-version <VER>    Phiên bản Node.js cần cài qua mise (Mặc định: lts)
  -f, --force             Ghi đè/xoá nếu Container ID đã tồn tại trước đó
  -h, --help              Hiển thị hướng dẫn này

Ví dụ:
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
            log_error "Tùy chọn không hợp lệ: $1"
            print_usage
            exit 1
            ;;
    esac
done

# --- Prerequisites Validation ---
log_info "=== Khởi động tạo LXC Container Template Debian 12 (Docker Ready) ==="

# 1. Check Root Privileges
if [[ "${EUID}" -ne 0 ]]; then
    log_error "Script này cần quyền root để thực thi các lệnh pct/pvesm trên Proxmox VE."
    exit 1
fi

# 2. Check Proxmox CLI tools
for cmd in pct pvesm; do
    if ! command -v "$cmd" &>/dev/null; then
        log_error "Lệnh '$cmd' không tồn tại. Hãy đảm bảo bạn đang chạy script này trực tiếp trên Proxmox VE host."
        exit 1
    fi
done

# 3. Check Target Storage
log_info "Kiểm tra storage lưu trữ Rootfs: '${STORAGE}'..."
if ! pvesm status --storage "$STORAGE" &>/dev/null; then
    log_error "Storage '${STORAGE}' không tồn tại hoặc không khả dụng trên node này."
    log_info "Các storage hiện có:"
    pvesm status
    exit 1
fi
log_success "Storage '${STORAGE}' sẵn sàng."

# 4. Check Template File
FULL_TMPL_SPEC="${TMPL_STORAGE}:vztmpl/${TMPL_FILE}"
TMPL_LOCAL_PATH="/var/lib/vz/template/cache/${TMPL_FILE}"

log_info "Kiểm tra template base OS: ${FULL_TMPL_SPEC}..."

TEMPLATE_FOUND=0
if [[ -f "$TMPL_LOCAL_PATH" ]]; then
    TEMPLATE_FOUND=1
elif pvesm list "$TMPL_STORAGE" --content vztmpl 2>/dev/null | grep -q "$TMPL_FILE"; then
    TEMPLATE_FOUND=1
fi

if [[ "$TEMPLATE_FOUND" -eq 0 ]]; then
    log_warn "Không tìm thấy template '${TMPL_FILE}' trong storage '${TMPL_STORAGE}'."
    log_info "Đang kiểm tra kho template có sẵn trên hệ thống qua pveam..."
    
    if command -v pveam &>/dev/null; then
        pveam update || true
        log_info "Đang thử tải '${TMPL_FILE}' vào storage '${TMPL_STORAGE}'..."
        if pveam download "$TMPL_STORAGE" "$TMPL_FILE"; then
            log_success "Đã tải thành công template: ${TMPL_FILE}"
        else
            log_error "Không thể tự động tải template '${TMPL_FILE}'. Vui lòng kiểm tra lại file trong /var/lib/vz/template/cache/."
            exit 1
        fi
    else
        log_error "Vui lòng đặt file '${TMPL_FILE}' vào thư mục cache của Proxmox (/var/lib/vz/template/cache/)."
        exit 1
    fi
else
    log_success "Đã xác nhận template file: ${FULL_TMPL_SPEC}"
fi

# 5. Check SSH Key
SSH_KEY_ARG=()
if [[ -n "$SSH_KEY_FILE" ]]; then
    if [[ -f "$SSH_KEY_FILE" ]]; then
        log_info "Sử dụng SSH Public Key từ: ${SSH_KEY_FILE}"
        SSH_KEY_ARG=("--ssh-public-keys" "$SSH_KEY_FILE")
    else
        log_error "File SSH Key '${SSH_KEY_FILE}' không tồn tại!"
        exit 1
    fi
else
    # Check default host keys as fallback
    if [[ -f "/root/.ssh/authorized_keys" ]]; then
        log_info "Không chỉ định --ssh-key, tự động dùng /root/.ssh/authorized_keys của host Proxmox."
        SSH_KEY_ARG=("--ssh-public-keys" "/root/.ssh/authorized_keys")
    else
        log_warn "Không tìm thấy SSH key nào. Container sẽ không được gắn sẵn SSH key."
    fi
fi

# 6. Check Container ID Conflict / Cleanup
if pct status "$CT_ID" &>/dev/null || [[ -f "/etc/pve/lxc/${CT_ID}.conf" ]]; then
    if [[ "$FORCE" -eq 1 ]]; then
        log_warn "Container / Template ID ${CT_ID} đã tồn tại. Đang tiến hành dừng và xoá sạch (--force được kích hoạt)..."
        pct stop "$CT_ID" 2>/dev/null || true
        pct destroy "$CT_ID" --purge 1 --force 1 --destroy-unreferenced-disks 1
        log_success "Đã xoá hoàn toàn container / template cũ: ${CT_ID}"
    else
        log_error "Container / Template ID ${CT_ID} đã tồn tại!"
        log_info "Gợi ý: Chọn ID khác qua cờ '-i <ID>' hoặc thêm cờ '-f / --force' để ghi đè."
        exit 1
    fi
fi

# --- Print Plan Summary ---
echo ""
echo -e "${CYAN}--------------------------------------------------${NC}"
echo -e "${CYAN}             THÔNG SỐ LXC TEMPLATE                ${NC}"
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
printf "%-20s : %s\n" "Cài sẵn Docker CE" "$([[ $INSTALL_DOCKER -eq 1 ]] && echo 'CÓ (Docker CE + Compose)' || echo 'KHÔNG')"
printf "%-20s : %s\n" "Cài sẵn Mise & Node" "$([[ $INSTALL_MISE -eq 1 ]] && echo "CÓ (Node.js ${NODE_VERSION} + pnpm + yarn)" || echo 'KHÔNG')"
if [[ ${#SSH_KEY_ARG[@]} -gt 0 ]]; then
printf "%-20s : %s\n" "SSH Key Injected" "${SSH_KEY_ARG[1]}"
else
printf "%-20s : %s\n" "SSH Key Injected" "None"
fi
echo -e "${CYAN}--------------------------------------------------${NC}"
echo ""

# --- Step 1: Create LXC Container ---
log_info "1. Đang tạo LXC container ID: ${CT_ID}..."

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

log_success "Khởi tạo LXC container ${CT_ID} thành công."

# --- Step 2: Provision Software inside Container (if enabled) ---
NEED_START=0
if [[ "$INSTALL_DOCKER" -eq 1 || "$INSTALL_MISE" -eq 1 ]]; then
    NEED_START=1
fi

if [[ "$NEED_START" -eq 1 ]]; then
    log_info "2. Khởi động container ${CT_ID} để cấu hình phần mềm..."
    pct start "$CT_ID"

    log_info "Đang đợi container có kết nối mạng Internet qua DHCP..."
    NET_READY=0
    for i in $(seq 1 30); do
        if pct exec "$CT_ID" -- ping -c 1 -W 2 1.1.1.1 &>/dev/null; then
            NET_READY=1
            break
        fi
        sleep 1
    done

    if [[ "$NET_READY" -eq 0 ]]; then
        log_error "Container ${CT_ID} không thể kết nối Internet sau 30 giây. Vui lòng kiểm tra lại bridge '${BRIDGE}' và DHCP server."
        pct stop "$CT_ID" 2>/dev/null || true
        exit 1
    fi
    log_success "Kết nối Internet của container đã sẵn sàng."

    log_info "Cập nhật APT và cài đặt các gói phụ trợ cơ bản (curl, wget, git, ca-certificates, sudo)..."
    pct exec "$CT_ID" -- bash -c '
        set -euo pipefail
        export DEBIAN_FRONTEND=noninteractive

        echo "[CT] Cập nhật danh sách gói APT..."
        apt-get update -y

        echo "[CT] Cài đặt các gói phụ trợ cần thiết..."
        apt-get install -y --no-install-recommends \
            ca-certificates \
            curl \
            wget \
            git \
            gnupg \
            lsb-release \
            sudo

        echo "[CT] Cấu hình Console Autologin cho tài khoản root..."
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
        log_info "Đang cài đặt Docker CE và Docker Compose Plugin từ official Docker APT repository..."
        pct exec "$CT_ID" -- bash -c '
            set -euo pipefail
            export DEBIAN_FRONTEND=noninteractive

            echo "[CT] Thêm kho lưu trữ chính thức của Docker..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
            chmod a+r /etc/apt/keyrings/docker.asc

            ARCH="$(dpkg --print-architecture)"
            CODENAME="$(. /etc/os-release && echo "$VERSION_CODENAME")"
            echo "deb [arch=${ARCH} signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/debian ${CODENAME} stable" > /etc/apt/sources.list.d/docker.list

            echo "[CT] Cài đặt Docker CE, CLI, Containerd và Docker Compose plugin..."
            apt-get update -y
            apt-get install -y --no-install-recommends \
                docker-ce \
                docker-ce-cli \
                containerd.io \
                docker-buildx-plugin \
                docker-compose-plugin

            echo "[CT] Kích hoạt và kiểm tra Docker service..."
            systemctl enable docker
            systemctl start docker
        '

        log_info "Kiểm tra phiên bản Docker trong container:"
        pct exec "$CT_ID" -- docker --version
        pct exec "$CT_ID" -- docker compose version
        log_success "Docker CE đã được cài đặt và cấu hình thành công!"
    fi

    # --- Step 2.2: Install Mise & Node.js (if enabled) ---
    if [[ "$INSTALL_MISE" -eq 1 ]]; then
        log_info "Đang cài đặt Mise qua kho lưu trữ APT chính thức và thiết lập Node.js (${NODE_VERSION})..."
        pct exec "$CT_ID" -- bash -c '
            set -euo pipefail
            NODE_VER="$1"
            export DEBIAN_FRONTEND=noninteractive

            echo "[CT] Thêm kho lưu trữ chính thức của Mise..."
            install -m 0755 -d /etc/apt/keyrings
            curl -fsSL https://mise.jdx.dev/gpg-key.pub | gpg --dearmor -o /etc/apt/keyrings/mise-archive-keyring.gpg
            chmod a+r /etc/apt/keyrings/mise-archive-keyring.gpg

            ARCH="$(dpkg --print-architecture)"
            echo "deb [signed-by=/etc/apt/keyrings/mise-archive-keyring.gpg arch=${ARCH}] https://mise.jdx.dev/deb stable main" > /etc/apt/sources.list.d/mise.list

            apt-get update -y
            apt-get install -y --no-install-recommends mise

            echo "[CT] Cài đặt Node.js (${NODE_VER}) qua Mise..."
            export MISE_DATA_DIR="/root/.local/share/mise"
            export MISE_CONFIG_DIR="/root/.config/mise"
            export MISE_CACHE_DIR="/root/.cache/mise"

            # Cài đặt Node phiên bản chỉ định và đặt làm global default
            mise use -g "node@${NODE_VER}"

            # Kích hoạt Corepack (pnpm & yarn)
            echo "[CT] Kích hoạt Corepack (pnpm & yarn)..."
            export PATH="/root/.local/share/mise/shims:$PATH"
            corepack enable || true
            corepack enable pnpm yarn || true
            mise reshim || true

            # Warm up pnpm và yarn qua Corepack để tải sẵn binary vào template
            pnpm --version >/dev/null 2>&1 || true
            yarn --version >/dev/null 2>&1 || true

            # Tạo symlinks vào /usr/bin và /usr/local/bin để đảm bảo gọi trực tiếp mọi nơi (script, non-interactive SSH, pct exec)
            for tool in node npm npx corepack pnpm yarn; do
                if [[ -e "/root/.local/share/mise/shims/${tool}" ]]; then
                    ln -sf "/root/.local/share/mise/shims/${tool}" "/usr/local/bin/${tool}"
                    ln -sf "/root/.local/share/mise/shims/${tool}" "/usr/bin/${tool}"
                fi
            done

            echo "[CT] Cấu hình môi trường Shell toàn hệ thống và cho root..."
            # 1. /etc/environment (cho SSH non-interactive & PAM login)
            if grep -q "PATH=" /etc/environment 2>/dev/null; then
                if ! grep -q "/root/.local/share/mise/shims" /etc/environment; then
                    sed -i "s|PATH=\"|PATH=\"/root/.local/share/mise/shims:|" /etc/environment
                fi
            else
                echo "PATH=\"/root/.local/share/mise/shims:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\"" >> /etc/environment
            fi

            # 2. /etc/profile.d/mise.sh (cho mọi interactive login shell)
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

            # 3. /root/.bashrc (cho root interactive shell)
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

        log_info "Kiểm tra phiên bản Mise & Node.js trong container:"
        pct exec "$CT_ID" -- mise --version
        pct exec "$CT_ID" -- node -v
        pct exec "$CT_ID" -- npm -v
        pct exec "$CT_ID" -- pnpm -v
        pct exec "$CT_ID" -- yarn -v
        log_success "Mise và Node.js (${NODE_VERSION}) đã được cài đặt và cấu hình thành công!"
    fi

    # --- Step 3: Golden Template Sanitization ---
    log_info "3. Tiến hành dọn dẹp và chuẩn hoá (Sanitize) container trước khi đóng gói template..."
    pct exec "$CT_ID" -- bash -c '
        set -euo pipefail

        echo "[CT] Dừng Docker daemon trước khi dọn dẹp..."
        systemctl stop docker 2>/dev/null || true

        echo "[CT] Dọn dẹp cache của mise và npm..."
        rm -rf /root/.cache/mise /root/.npm/_cacache

        echo "[CT] Dọn dẹp APT cache và file tạm..."
        apt-get clean
        rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/*

        echo "[CT] Reset /etc/machine-id để đảm bảo DHCP IP độc lập khi clone..."
        truncate -s 0 /etc/machine-id
        rm -f /var/lib/dbus/machine-id
        ln -sf /etc/machine-id /var/lib/dbus/machine-id 2>/dev/null || true

        echo "[CT] Xoá lịch sử lệnh..."
        cat /dev/null > /root/.bash_history 2>/dev/null || true
        history -c 2>/dev/null || true

        echo "[CT] Làm sạch log files..."
        find /var/log -type f -name "*.log" -exec truncate -s 0 {} + 2>/dev/null || true
    '
    log_success "Đã hoàn tất dọn dẹp sạch sẽ container."

    log_info "Đang tắt container ${CT_ID}..."
    pct stop "$CT_ID"
    sleep 2
fi

# --- Step 4: Convert LXC to Template ---
log_info "4. Đang chuyển đổi container ${CT_ID} thành Proxmox Template..."
pct template "$CT_ID"
log_success "Đã chuyển đổi thành công Container ${CT_ID} thành Template!"

echo ""
echo -e "${GREEN}==============================================================${NC}"
echo -e "${GREEN}      TẠO LXC CONTAINER TEMPLATE THÀNH CÔNG! (${CT_ID})       ${NC}"
echo -e "${GREEN}==============================================================${NC}"
printf "%-20s : %s\n" "Template ID" "$CT_ID"
printf "%-20s : %s\n" "Template Name" "$HOSTNAME"
printf "%-20s : %s Cores | %s MB RAM | %s GB Disk\n" "Specs" "$CORES" "$MEMORY" "$DISK_SIZE"
printf "%-20s : %s\n" "Docker CE" "$([[ $INSTALL_DOCKER -eq 1 ]] && echo 'Pre-installed & Ready' || echo 'Not installed')"
printf "%-20s : %s\n" "Mise & Node.js" "$([[ $INSTALL_MISE -eq 1 ]] && echo "Node.js ${NODE_VERSION} + pnpm + yarn" || echo 'Not installed')"
echo -e "${GREEN}--------------------------------------------------------------${NC}"
echo -e "Bạn có thể kiểm tra trên Proxmox Web GUI hoặc dùng lệnh clone:"
echo -e "  ${YELLOW}pct clone ${CT_ID} <NEW_ID> --hostname my-app --full 1${NC}"
echo -e "  ${YELLOW}pct start <NEW_ID>${NC}"
echo -e "  ${YELLOW}pct exec <NEW_ID> -- docker ps${NC}"
echo -e "  ${YELLOW}pct exec <NEW_ID> -- node -v${NC}"
echo ""
