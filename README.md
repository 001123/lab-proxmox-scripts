# Proxmox VE - Debian 12 LXC Container Template (Docker & Node/Mise Ready)

Bộ công cụ tự động hóa khởi tạo **LXC Container Golden Template** chạy **Debian 12 (Bookworm)** tích hợp sẵn **Docker CE, Docker Compose, Mise Tool Manager & Node.js LTS** trên Proxmox VE (Node `pve-n150`), với cấu hình chuẩn cho homelab/production:
- **Tên template (Hostname)**: `lxc-debian` (Template ID: `9000`).
- **Tài nguyên**: 2 vCPU, 2048MB (2GB) RAM, 1024MB Swap, 15GB SSD Disk (Rootfs trên `local-lvm`).
- **Mạng**: DHCP trên bridge `vmbr0`, kích hoạt firewall.
- **Docker Stack cài sẵn**:
  - Docker CE chính hãng (`docker-ce`, `docker-ce-cli`, `containerd.io`).
  - Docker Compose Plugin (`docker compose`) & Buildx Plugin.
  - Tự động kích hoạt service Docker khởi chạy cùng hệ thống (`systemctl enable docker`).
- **Node.js & Developer Toolchain (quản lý bởi Mise)**:
  - Cài sẵn **Mise** qua APT repository chính hãng (`/usr/bin/mise`).
  - Cài sẵn **Node.js LTS** thiết lập global default (`mise use -g node@lts`).
  - Kích hoạt sẵn **Corepack** với cả **pnpm** lẫn **yarn** bên cạnh **npm** mặc định.
  - Cấu hình PATH toàn diện (`/etc/environment`, `/etc/profile.d/mise.sh`, `/root/.bashrc`, symlinks `/usr/local/bin`), hỗ trợ chạy ngay qua SSH, Web GUI Console hay remote `pct exec`.
  - Cài sẵn **git**, **curl**, **wget**, **sudo**, **ca-certificates**.
- **Bảo mật & Tính năng**: Unprivileged container (`unprivileged=1`), bật **features: nesting=1,keyctl=1** (chuẩn Proxmox cho Docker bên trong LXC unprivileged).
- **Console Autologin**: Tự động đăng nhập vào `root` khi mở Web GUI Console (xterm.js / noVNC) mà không cần nhập username hay password.
- **Chuẩn hóa Golden Template (Sanitization)**:
  - Tự động reset `/etc/machine-id` (tránh trùng IP khi nhận DHCP giữa các container clone ra).
  - Dọn sạch cache Mise (`/root/.cache/mise`), NPM cache, APT cache, log files và bash history.
- **Xác thực**: Tự động inject SSH Public Key từ máy Mac (`~/.ssh/id_ed25519.pub`) vào tài khoản `root` của container.
- **OS Template gốc**: `debian-12-standard_12.12-1_amd64.tar.zst` (lưu tại `local:vztmpl/`).

---

## Cấu trúc thư mục

```text
lab-proxmox/
├── credentials.env                   # File cấu hình IP / Storage / Bridge của cụm Proxmox
├── credentials.env.example           # File mẫu cấu hình
├── README.md                         # Hướng dẫn chi tiết
└── scripts/
    ├── create-lxc-template.sh        # Script chạy trực tiếp trên Proxmox VE node
    └── deploy-lxc-template.sh        # Script chạy từ máy Mac (tự đẩy key và script lên Proxmox)
```

---

## Cách 1: Triển khai trực tiếp từ máy Mac (Khuyên dùng - 1 câu lệnh)

Script `deploy-lxc-template.sh` sẽ tự động:
1. Đọc địa chỉ IP host (`192.168.250.4`) và storage (`local-lvm`) từ [credentials.env](file:///Users/timi/lab/lab-proxmox/credentials.env).
2. Lấy public key từ máy Mac của bạn (`~/.ssh/id_ed25519.pub`).
3. Sử dụng `scp` chuyển file script và SSH key lên Proxmox.
4. Kích hoạt `create-lxc-template.sh` trên Proxmox qua SSH và dọn dẹp file tạm sau khi hoàn tất.

### Lệnh thực thi:

```bash
cd /Users/timi/lab/lab-proxmox

# Tạo hoặc ghi đè template 9000 (tên: lxc-debian, cài sẵn Docker + Mise + Node LTS):
./scripts/deploy-lxc-template.sh --force
```

Nếu muốn tuỳ biến phiên bản Node.js hoặc cấu hình phần cứng:
```bash
# Cài đặt phiên bản Node.js cụ thể (ví dụ: Node 22):
./scripts/deploy-lxc-template.sh --force --node-version 22

# Bỏ qua cài đặt Docker (chỉ cài Node/Mise):
./scripts/deploy-lxc-template.sh --force --no-docker

# Bỏ qua cài đặt Mise/Node (chỉ cài Docker):
./scripts/deploy-lxc-template.sh --force --no-mise

# Tùy biến toàn diện tài nguyên:
./scripts/deploy-lxc-template.sh --force -i 9000 --hostname lxc-debian --cores 2 --memory 2048 --disk 15
```

---

## Cách 2: Chạy thủ công trên Proxmox VE Host

Nếu bạn đã SSH vào Proxmox VE node (`root@192.168.250.4`):

1. Chạy lệnh:

```bash
chmod +x scripts/create-lxc-template.sh

# Chạy với tham số mặc định (ID 9000, tên lxc-debian, ghi đè template cũ nếu có):
./scripts/create-lxc-template.sh --force -k /root/.ssh/authorized_keys
```

---

## Cách nhân bản (Clone) và sử dụng Container sau khi tạo

Sau khi template được tạo thành công với ID **9000** (`lxc-debian`):

### 1. Tạo container mới từ Template bằng lệnh Proxmox (CLI):
```bash
# Clone một container mới (ID 101, hostname 'my-app', full clone):
pct clone 9000 101 --hostname my-app --full 1

# Khởi động container:
pct start 101

# Kiểm tra Docker ngay lập tức bên trong container:
pct exec 101 -- docker --version
pct exec 101 -- docker compose version
pct exec 101 -- docker run --rm hello-world

# Kiểm tra Node.js toolchain và Mise:
pct exec 101 -- mise --version
pct exec 101 -- node -v
pct exec 101 -- npm -v
pct exec 101 -- pnpm -v
pct exec 101 -- yarn -v
```

### 2. Tạo container mới qua Proxmox Web GUI:
1. Mở giao diện Proxmox Web (`https://192.168.250.4:8006`).
2. Chuột phải vào Template **9000 (lxc-debian)** -> Chọn **Clone**.
3. Đặt VMID mới (ví dụ: `101`) và Hostname mong muốn.
4. Chọn Mode: **Full Clone**.
5. Nhấn **Clone** và Start container mới.

### 3. Đăng nhập SSH từ máy Mac:
Vì SSH Public Key (`id_ed25519.pub`) của máy Mac đã được tích hợp sẵn vào template, bạn có thể SSH thẳng vào container mới mà không cần mật khẩu:

```bash
ssh root@<IP_CONTAINER_MOI>

# Khi vào trong container, kiểm tra môi trường:
node -v
pnpm -v
yarn -v
docker ps
```

---

## Giấy phép (License)

Dự án được phân phối theo giấy phép [MIT License](LICENSE).
