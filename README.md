# Bộ Cài Đặt Phòng Máy Xubuntu (SchoolGuard Setup)

Repo này **chỉ chứa bộ cài đặt dành cho máy học sinh Xubuntu** (Không bao gồm mã nguồn Web Quản lý).

---

## Cách 1: Cài Đặt Siêu Nhanh Bằng 1 Dòng Lệnh (Không Cần Mật Khẩu `sudo`)

Trên máy học sinh Xubuntu, nhấn **`Ctrl + Alt + T`** để mở Terminal, dán lệnh sau và nhấn **Enter**:

```bash
wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | bash
```

*(Hoặc tải trực tiếp từ máy chủ HTTPS)*:
```bash
wget -qO- https://103-149-172-179.sslip.io/install.sh | bash
```

---

## Cách 2: Tải File Bấm Đúp Чуột (Double-Click)

1. Bấm tải file **[SchoolGuard-Xubuntu-Setup.tar.gz](./SchoolGuard-Xubuntu-Setup.tar.gz)** hoặc **[Cai-Dat-SchoolGuard.desktop](./Cai-Dat-SchoolGuard.desktop)** ngay trong Repo này.
2. Nếu tải file `.tar.gz`: Bấm chuột phải chọn **Extract Here** (Giải nén tại đây) $\rightarrow$ Mở thư mục `SchoolGuard-Setup`.
3. **Bấm đúp chuột (Double-click)** vào **`Cai-Dat-SchoolGuard.desktop`** (nếu Xubuntu hỏi thì bấm **Launch Anyway**).
4. Quá trình cài đặt tự động hoàn tất trong **2 giây** mà không cần nhập mật khẩu Admin!
