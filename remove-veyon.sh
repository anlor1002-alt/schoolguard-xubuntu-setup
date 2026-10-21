#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Pro - Veyon Clean Removal & Suppression Tool for Xubuntu
# Bước 1: Dừng, khóa và gỡ bỏ hoàn toàn Veyon khỏi máy học sinh
# Hỗ trợ cả khi CÓ root/sudo hoặc KHÔNG CÓ mật khẩu sudo!
# ============================================================================

set -u

# ANSI Color codes
BOLD='\033[1m'
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${CYAN}================================================================${NC}"
echo -e "${BOLD}${YELLOW}    BƯỚC 1: TIÊU DIỆT & XÓA SẠCH VEYON KHỎI MÁY HỌC SINH        ${NC}"
echo -e "${CYAN}================================================================${NC}"

# 1. Tiêu diệt ngay lập tức mọi tiến trình Veyon đang chạy
echo -e "${BLUE}[*] Tiêu diệt mọi tiến trình Veyon để giải phóng màn hình...${NC}"
pkill -9 -f "veyon-worker" 2>/dev/null || true
pkill -9 -f "veyon-master" 2>/dev/null || true
pkill -9 -f "veyon-service" 2>/dev/null || true
pkill -9 -f "veyon-server" 2>/dev/null || true
pkill -9 -f "veyon-configurator" 2>/dev/null || true

# 2. Giải phóng ngay lập tức bàn phím và chuột bị Veyon khóa (xinput)
if command -v xinput &>/dev/null; then
    DISP="${DISPLAY:-:0}"
    echo -e "${BLUE}[*] Đang khôi phục toàn bộ chuột và bàn phím (xinput trên DISPLAY ${DISP})...${NC}"
    for dev_id in $(DISPLAY="$DISP" xinput list --short 2>/dev/null | grep -E "slave\s+(pointer|keyboard)" | sed -n 's/.*id=\([0-9]\+\).*/\1/p'); do
        DISPLAY="$DISP" xinput enable "$dev_id" 2>/dev/null || true
    done
fi

# 3. Kiểm tra nếu có quyền sudo không mật khẩu thì tự động nâng quyền root
if [ "$EUID" -ne 0 ] && sudo -n true 2>/dev/null; then
    echo -e "${GREEN}[*] Phát hiện có quyền sudo không mật khẩu, tự động nâng quyền Root...${NC}"
    if [ -f "$0" ]; then
        exec sudo bash "$0" "$@"
    else
        TMP_ROOT_SCRIPT="/tmp/sg_remove_veyon_root.sh"
        if (wget -qO "$TMP_ROOT_SCRIPT" https://103-149-172-179.sslip.io/remove-veyon.sh 2>/dev/null || \
            wget -qO "$TMP_ROOT_SCRIPT" https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove-veyon.sh 2>/dev/null || \
            curl -s -o "$TMP_ROOT_SCRIPT" https://103-149-172-179.sslip.io/remove-veyon.sh 2>/dev/null); then
            exec sudo bash "$TMP_ROOT_SCRIPT" "$@"
        fi
    fi
fi

# ============================================================================
# TRƯỜNG HỢP 1: CÓ QUYỀN ROOT / SUDO
# ============================================================================
if [ "$EUID" -eq 0 ]; then
    echo -e "${GREEN}[*] Đang thực hiện gỡ bỏ triệt để Veyon ở cấp ROOT SYSTEM...${NC}"

    # Dừng, vô hiệu hóa và khóa (mask) dịch vụ veyon hệ thống
    echo -e "${BLUE}[*] Dừng và khóa dịch vụ systemd veyon.service...${NC}"
    systemctl stop veyon.service 2>/dev/null || true
    systemctl disable veyon.service 2>/dev/null || true
    systemctl mask veyon.service 2>/dev/null || true

    # Dừng veyon systemd của tất cả người dùng đăng nhập
    for u in /home/*; do
        if [ -d "$u" ]; then
            uid=$(stat -c '%u' "$u" 2>/dev/null || true)
            if [ -n "$uid" ] && [ "$uid" -ge 1000 ]; then
                XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user stop veyon.service 2>/dev/null || true
                XDG_RUNTIME_DIR="/run/user/$uid" systemctl --user mask veyon.service 2>/dev/null || true
            fi
        fi
    done

    # Gỡ bỏ triệt để gói veyon qua apt-get
    echo -e "${BLUE}[*] Gỡ bỏ gói veyon và cấu hình hệ thống bằng apt...${NC}"
    DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y 'veyon*' 2>/dev/null || true
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y 2>/dev/null || true

    # Xóa file thực thi, autostart, thư viện và cấu hình còn sót
    echo -e "${BLUE}[*] Xóa sạch thư mục cấu hình và file thực thi Veyon...${NC}"
    rm -rf /etc/veyon /usr/bin/veyon-* /usr/sbin/veyon-* /usr/lib/x86_64-linux-gnu/veyon /usr/lib/veyon /usr/share/veyon
    rm -f /etc/xdg/autostart/*veyon*.desktop /usr/share/applications/*veyon*.desktop
    rm -f /home/*/Desktop/*veyon*.desktop /home/*/"Màn hình nền"/*veyon*.desktop
    rm -f /home/*/.config/autostart/*veyon*.desktop
    rm -rf /home/*/.config/veyon

    # Xóa bộ blocker tạm nếu trước đó từng cài ở chế độ user
    pkill -9 -f "schoolguard-blocker.sh" 2>/dev/null || true
    pkill -9 -f "veyon-killer.sh" 2>/dev/null || true
    rm -f /home/*/.local/share/.schoolguard/schoolguard-blocker.sh
    rm -f /home/*/.local/share/.schoolguard/veyon-killer.sh
    rm -f /home/*/.config/autostart/schoolguard-veyon-blocker.desktop
    rm -f /home/*/.config/systemd/user/schoolguard-veyon-blocker.service

    echo -e "${CYAN}================================================================${NC}"
    echo -e "${BOLD}${GREEN} ✅ ĐÃ XÓA SẠCH VÀ VÔ HIỆU HÓA HOÀN TOÀN VEYON (CẤP ROOT)!      ${NC}"
    echo -e "${BOLD}${YELLOW} 👉 Bây giờ bạn có thể chạy Bước 2: Cài Đặt SchoolGuard.         ${NC}"
    echo -e "${CYAN}================================================================${NC}"

    if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}" ]; then
        zenity --info --title="Xóa Sạch Veyon Thành Công" \
            --text="Đã dừng, khóa và gỡ bỏ hoàn toàn Veyon khỏi hệ thống!\n\nBây giờ bạn hãy chạy Bước 2: Cài đặt SchoolGuard." \
            --width=420 2>/dev/null &
    fi
    exit 0
fi

# ============================================================================
# TRƯỜNG HỢP 2: KHÔNG CÓ MẬT KHẨU SUDO / QUÊN MẬT KHẨU ADMIN
# ============================================================================
echo -e "${YELLOW}[*] Không có mật khẩu Root/Sudo. Đang thiết lập BỘ CHẶN NGẦM VEYON...${NC}"

USER_SG_DIR="${HOME}/.local/share/.schoolguard"
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
AUTOSTART_DIR="${HOME}/.config/autostart"

mkdir -p "${USER_SG_DIR}" "${USER_SYSTEMD_DIR}" "${AUTOSTART_DIR}"

# 1. Dọn dẹp shortcut ngoài desktop và autostart của user
echo -e "${BLUE}[*] Dọn dẹp shortcut Veyon trên Desktop và Autostart...${NC}"
rm -f "${HOME}/Desktop/"*veyon*.desktop "${HOME}/Màn hình nền/"*veyon*.desktop 2>/dev/null || true
rm -f "${HOME}/.config/autostart/"*veyon*.desktop 2>/dev/null || true
rm -rf "${HOME}/.config/veyon" 2>/dev/null || true

# 2. Khóa dịch vụ user systemd của veyon nếu có
systemctl --user stop veyon.service 2>/dev/null || true
systemctl --user mask veyon.service 2>/dev/null || true

# 3. Tạo daemon chặn ngầm schoolguard-blocker.sh
KILLER_SCRIPT="${USER_SG_DIR}/schoolguard-blocker.sh"
echo -e "${BLUE}[*] Tạo daemon chặn ngầm tự động: ${KILLER_SCRIPT}...${NC}"
pkill -9 -f "schoolguard-blocker.sh" 2>/dev/null || true
pkill -9 -f "veyon-killer.sh" 2>/dev/null || true
cat > "${KILLER_SCRIPT}" <<'EOF'
#!/usr/bin/env bash
# SchoolGuard Veyon Blocker Daemon (User Level)
# Liên tục phát hiện và tiêu diệt mọi tiến trình Veyon, mở khóa xinput
while true; do
    if pgrep "veyon-(worker|master|service|server|configurator)" >/dev/null 2>&1; then
        pkill -9 -f "veyon-worker" 2>/dev/null || true
        pkill -9 -f "veyon-master" 2>/dev/null || true
        pkill -9 -f "veyon-service" 2>/dev/null || true
        pkill -9 -f "veyon-server" 2>/dev/null || true
        pkill -9 -f "veyon-configurator" 2>/dev/null || true
        
        # Ngay khi diệt tiến trình Veyon, giải phóng khóa chuột & phím
        if command -v xinput &>/dev/null; then
            DISP="${DISPLAY:-:0}"
            for id in $(DISPLAY="$DISP" xinput list --short 2>/dev/null | grep -E "slave\s+(pointer|keyboard)" | sed -n 's/.*id=\([0-9]\+\).*/\1/p'); do
                DISPLAY="$DISP" xinput enable "$id" 2>/dev/null || true
            done
        fi
    fi
    sleep 1
done
EOF
chmod +x "${KILLER_SCRIPT}"

# 4. Đăng ký systemd --user cho daemon diệt Veyon
echo -e "${BLUE}[*] Đăng ký dịch vụ systemd --user schoolguard-veyon-blocker...${NC}"
cat > "${USER_SYSTEMD_DIR}/schoolguard-veyon-blocker.service" <<EOF
[Unit]
Description=SchoolGuard Continuous Veyon Blocker Daemon
After=graphical-session.target

[Service]
Type=simple
ExecStart=/bin/bash ${KILLER_SCRIPT}
Restart=always
RestartSec=1
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable schoolguard-veyon-blocker.service 2>/dev/null || true
systemctl --user restart schoolguard-veyon-blocker.service 2>/dev/null || true

# 5. Đăng ký XFCE Autostart
echo -e "${BLUE}[*] Đăng ký XFCE Autostart để tự kích hoạt khi học sinh đăng nhập...${NC}"
cat > "${AUTOSTART_DIR}/schoolguard-veyon-blocker.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SchoolGuard Veyon Blocker
Exec=/bin/bash ${KILLER_SCRIPT}
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF

# 6. Đăng ký Cron Watchdog tự phục hồi
echo -e "${BLUE}[*] Cấu hình Cron Watchdog kiểm tra định kỳ...${NC}"
CRON_JOB="* * * * * pgrep -f '${KILLER_SCRIPT}' >/dev/null || DISPLAY=:0 nohup /bin/bash '${KILLER_SCRIPT}' >/dev/null 2>&1 &"
(crontab -l 2>/dev/null | grep -v "schoolguard-blocker.sh" | grep -v "veyon-killer.sh"; echo "${CRON_JOB}") | crontab - 2>/dev/null || true

# 7. Kích hoạt chạy ngay trong nền
if ! pgrep -f "${KILLER_SCRIPT}" >/dev/null; then
    DISPLAY="${DISPLAY:-:0}" nohup /bin/bash "${KILLER_SCRIPT}" >/dev/null 2>&1 &
fi

echo -e "${CYAN}================================================================${NC}"
echo -e "${BOLD}${GREEN} ✅ ĐÃ KHỐNG CHẾ VÀ KÍCH HOẠT BỘ CHẶN VEYON TỰ ĐỘNG TRÊN MÁY!   ${NC}"
echo -e "${BOLD}${YELLOW} 👉 Bây giờ bạn có thể chạy Bước 2: Cài Đặt SchoolGuard.         ${NC}"
echo -e "${CYAN}================================================================${NC}"

if command -v zenity &>/dev/null && [ -n "${DISPLAY:-}" ]; then
    zenity --info --title="Đã Khống Chế & Vô Hiệu Hóa Veyon" \
        --text="Bộ chặn ngầm đã được cài đặt thành công (Không cần mật khẩu sudo).\nMọi tiến trình Veyon sẽ bị tiêu diệt ngay khi xuất hiện!\n\nBây giờ bạn hãy chạy Bước 2: Cài đặt SchoolGuard." \
        --width=440 2>/dev/null &
fi
exit 0
