#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Xubuntu 1-Click Installer (Chạy được CẢ KHI QUÊN MẬT KHẨU SUDO!)
# - Nếu có quyền root/sudo: Cài cấp hệ thống (/opt/schoolguard + systemd root + chattr +i)
# - Nếu KHÔNG có / Quên mật khẩu sudo: Tự động cài cấp User Daemon không cần mật khẩu!
#   (systemd --user Restart=always + XFCE Autostart + Cron Watchdog)
# ============================================================================

VPS_DOMAIN="103-149-172-179.sslip.io"
VPS_HTTP="https://${VPS_DOMAIN}"
VPS_WS="wss://${VPS_DOMAIN}/ws/agent"
AGENT_SECRET="schoolguard-xubuntu-secret-2026"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" &>/dev/null && pwd || echo "/tmp")"

echo "================================================================"
echo "   CÀI ĐẶT HỆ THỐNG QUẢN LÝ PHÒNG MÁY SCHOOLGUARD (XUBUNTU)     "
echo "   Kết nối về máy chủ VPS: ${VPS_HTTP}                          "
echo "================================================================"

download_or_copy_files() {
    local target_dir="$1"
    mkdir -p "${target_dir}"
    if [ -f "${SCRIPT_DIR}/agent.py" ] && [ -f "${SCRIPT_DIR}/overlay_ui.py" ]; then
        cp -f "${SCRIPT_DIR}/agent.py" "${target_dir}/agent.py"
        cp -f "${SCRIPT_DIR}/overlay_ui.py" "${target_dir}/overlay_ui.py"
    else
        echo " -> Đang tải mã nguồn trực tiếp từ VPS ${VPS_HTTP}..."
        python3 -c "import urllib.request; urllib.request.urlretrieve('${VPS_HTTP}/agent/agent.py', '${target_dir}/agent.py')"
        python3 -c "import urllib.request; urllib.request.urlretrieve('${VPS_HTTP}/agent/overlay_ui.py', '${target_dir}/overlay_ui.py')"
    fi
    chmod +x "${target_dir}/agent.py" "${target_dir}/overlay_ui.py"

    cat > "${target_dir}/config.json" <<EOF
{
  "vps_ws": "${VPS_WS}",
  "vps_http": "${VPS_HTTP}",
  "secret": "${AGENT_SECRET}"
}
EOF
}

# ----------------------------------------------------------------------------
# TRƯỜNG HỢP 1: Đang chạy với quyền root (hoặc sudo không mật khẩu)
# ----------------------------------------------------------------------------
if [ "$EUID" -eq 0 ]; then
    INSTALL_DIR="/opt/schoolguard"
    SERVICE_FILE="/etc/systemd/system/schoolguard.service"
    echo "[*] Đang cài đặt ở chế độ ROOT SYSTEMD (Quyền cao nhất)..."

    chattr -i "${INSTALL_DIR}/agent.py" "${INSTALL_DIR}/overlay_ui.py" "${INSTALL_DIR}/config.json" "${SERVICE_FILE}" 2>/dev/null || true
    systemctl stop schoolguard.service 2>/dev/null || true

    download_or_copy_files "${INSTALL_DIR}"
    chmod -R 700 "${INSTALL_DIR}"

    if [ -f "/usr/bin/veyon-master" ]; then
        chmod 700 /usr/bin/veyon-master 2>/dev/null || true
    fi
    rm -f /home/*/Desktop/*veyon*.desktop 2>/dev/null || true

    cat > "${SERVICE_FILE}" <<EOF
[Unit]
Description=SchoolGuard Classroom Management & Veyon Watchdog Service
After=network-online.target graphical.target lightdm.service
Wants=network-online.target

[Service]
Type=simple
User=root
Group=root
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/agent.py
Restart=always
RestartSec=2
StartLimitIntervalSec=0
OOMScoreAdjust=-900
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable schoolguard.service
    systemctl restart schoolguard.service
    chattr +i "${INSTALL_DIR}/agent.py" "${INSTALL_DIR}/overlay_ui.py" "${INSTALL_DIR}/config.json" "${SERVICE_FILE}" 2>/dev/null || true

    echo "================================================================"
    echo " ✅ CÀI ĐẶT THÀNH CÔNG (CHẾ ĐỘ ROOT) TRÊN MÁY: $(hostname)"
    echo "================================================================"
    exit 0
fi

# ----------------------------------------------------------------------------
# TRƯỜNG HỢP 2: CÀI ĐẶT KHÔNG CẦN MẬT KHẨU SUDO / QUÊN MẬT KHẨU ADMIN!
# Chạy ngay lập tức chỉ với 1 cú Double-Click, không hỏi mật khẩu!
# ----------------------------------------------------------------------------
USER_INSTALL_DIR="${HOME}/.local/share/.schoolguard"
USER_SYSTEMD_DIR="${HOME}/.config/systemd/user"
AUTOSTART_DIR="${HOME}/.config/autostart"

echo "[*] Đang cài đặt nhanh chế độ KHÔNG CẦN MẬT KHẨU SUDO..."
download_or_copy_files "${USER_INSTALL_DIR}"
pkill -f ".schoolguard/agent.py" 2>/dev/null || true

# 1. Đăng ký systemd --user (Tự động bật lại trong 1 giây nếu bị tắt)
mkdir -p "${USER_SYSTEMD_DIR}"
cat > "${USER_SYSTEMD_DIR}/schoolguard.service" <<EOF
[Unit]
Description=SchoolGuard Classroom Agent
After=graphical-session.target

[Service]
Type=simple
WorkingDirectory=${USER_INSTALL_DIR}
ExecStart=/usr/bin/python3 ${USER_INSTALL_DIR}/agent.py
Restart=always
RestartSec=1
StartLimitIntervalSec=0
Environment=PYTHONUNBUFFERED=1
Environment=DISPLAY=:0

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload 2>/dev/null || true
systemctl --user enable schoolguard.service 2>/dev/null || true
systemctl --user restart schoolguard.service 2>/dev/null || true

# 2. Đăng ký XFCE Autostart (Tự khởi động ngay khi bật máy vào màn hình Xubuntu)
mkdir -p "${AUTOSTART_DIR}"
cat > "${AUTOSTART_DIR}/schoolguard-agent.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SchoolGuard Classroom Service
Exec=/usr/bin/python3 ${USER_INSTALL_DIR}/agent.py
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF

# 3. Đăng ký Cron Watchdog (Đảm bảo luôn tự bật lại nếu systemd --user không chạy)
CRON_CMD="* * * * * pgrep -f '${USER_INSTALL_DIR}/agent.py' >/dev/null || DISPLAY=:0 nohup /usr/bin/python3 '${USER_INSTALL_DIR}/agent.py' >/dev/null 2>&1 &"
(crontab -l 2>/dev/null | grep -v ".schoolguard/agent.py"; echo "${CRON_CMD}") | crontab - 2>/dev/null || true

# 4. Nếu tiến trình chưa chạy bởi systemd --user thì khởi chạy ngầm ngay lập tức
if ! pgrep -f "${USER_INSTALL_DIR}/agent.py" >/dev/null; then
    nohup /usr/bin/python3 "${USER_INSTALL_DIR}/agent.py" >/dev/null 2>&1 &
fi

# Tạo sẵn script hỗ trợ đặt lại mật khẩu sudo/root nhanh khi vào Recovery Mode
cat > "${USER_INSTALL_DIR}/reset-sudo.sh" <<'EOF'
#!/usr/bin/env bash
# Chạy script này trong GRUB Recovery Mode (Root Shell) để đặt lại mật khẩu sudo trong 3 giây
NEW_PASS="${1:-123456}"
mount -o remount,rw / 2>/dev/null || true
echo "root:${NEW_PASS}" | chpasswd
for u in $(ls /home 2>/dev/null); do
    if id "$u" &>/dev/null; then
        echo "${u}:${NEW_PASS}" | chpasswd
        usermod -aG sudo "$u" 2>/dev/null || true
        echo " -> Đã đặt lại mật khẩu sudo cho tài khoản [${u}] thành: ${NEW_PASS}"
    fi
done
echo "✅ Hoàn tất đặt lại mật khẩu sudo/root thành: ${NEW_PASS}"
EOF
chmod +x "${USER_INSTALL_DIR}/reset-sudo.sh"

# Xóa biểu tượng Veyon Master ngoài màn hình Desktop của học sinh (nếu có)
rm -f "${HOME}/Desktop/"*veyon*.desktop "${HOME}/Màn hình nền/"*veyon*.desktop 2>/dev/null || true

HOSTNAME_NOW="$(hostname)"
echo ""
echo "================================================================"
echo " ✅ CÀI ĐẶT THÀNH CÔNG (KHÔNG CẦN MẬT KHẨU ADMIN) TRÊN: ${HOSTNAME_NOW}"
echo " 🔗 Máy đã kết nối ngay về Web VPS: ${VPS_HTTP}"
echo "================================================================"

if command -v zenity &>/dev/null && [ -n "${DISPLAY}" ]; then
    zenity --info --title="Cài đặt SchoolGuard Thành Công" \
        --text="Máy [${HOSTNAME_NOW}] đã cài đặt và kết nối thành công về VPS (Không cần mật khẩu sudo)!\n\nĐịa chỉ quản lý Web:\n${VPS_HTTP}" \
        --width=420 2>/dev/null &
fi
