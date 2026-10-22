#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Pro — Công cụ Đặt lại Mật khẩu Quản trị (sudo / root) về 123456
# Cách chạy trong Terminal (Ctrl + Alt + T) hoặc GRUB Recovery Root Shell:
#   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/reset-sudo.sh | bash
# ============================================================================

NEW_PASS="${1:-123456}"

echo "================================================================"
echo "  ĐẶT LẠI MẬT KHẨU QUẢN TRỊ (SUDO / ROOT) XUBUNTU -> ${NEW_PASS}"
echo "================================================================"

apply_reset() {
    mount -o remount,rw / 2>/dev/null || true
    echo "root:${NEW_PASS}" | chpasswd
    for u in $(ls /home 2>/dev/null); do
        if id "$u" &>/dev/null; then
            echo "${u}:${NEW_PASS}" | chpasswd
            usermod -aG sudo "$u" 2>/dev/null || true
            echo " -> Đã đặt mật khẩu sudo cho tài khoản [${u}] thành: ${NEW_PASS}"
        fi
    done
    echo "✅ Hoàn tất đặt lại mật khẩu root và sudo thành: ${NEW_PASS}"
}

if [[ "$EUID" -eq 0 ]]; then
    apply_reset
else
    echo "[*] Vui lòng xác nhận quyền quản trị (sudo) để đặt lại mật khẩu thành ${NEW_PASS}:"
    sudo bash -c "$(declare -f apply_reset); NEW_PASS='${NEW_PASS}'; apply_reset"
fi
