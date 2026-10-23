#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Pro — Công cụ Tự Động Triển Khai Toàn Phòng Máy Qua Mạng LAN
# Chạy trên 1 máy học sinh bất kỳ để tự động cài đặt cho tất cả các máy cùng mạng:
#   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan-deploy.sh | bash
# ============================================================================

VPS_URL="https://103-149-172-179.sslip.io"
SSH_USER="${1:-tinhocsaigon}"
SSH_PASS="${2:-}"

echo "================================================================"
echo "  SCHOOLGUARD PRO — TỰ ĐỘNG CÀI ĐẶT CHO CÁC MÁY CÙNG MẠNG LAN"
echo "================================================================"

# 1. Đảm bảo máy hiện tại đã được cài đặt trước
if ! pgrep -f "schoolguard/agent.py" >/dev/null 2>&1; then
    echo "[*] Đang cài đặt SchoolGuard trên máy trạm nguồn này trước..."
    curl -sSL "${VPS_URL}/remove-veyon.sh" | bash
    curl -sSL "${VPS_URL}/install.sh" | bash
fi

# 2. Xác định dải mạng LAN hiện tại (VD: 192.168.1)
LOCAL_IP=$(python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()" 2>/dev/null)
SUBNET=$(echo "${LOCAL_IP}" | awk -F. '{print $1"."$2"."$3}')

if [[ -z "${SUBNET}" || "${LOCAL_IP}" == "127.0.0.1" ]]; then
    echo "[!] Không xác định được dải mạng LAN."
    exit 1
fi

echo "[*] Máy nguồn hiện tại: ${LOCAL_IP} (Dải mạng LAN: ${SUBNET}.1 -> ${SUBNET}.254)"

if [[ -z "${SSH_PASS}" && -t 0 ]]; then
    read -r -p "[?] Nhập tài khoản máy học sinh (Enter để dùng '${SSH_USER}'): " inp_user
    [[ -n "${inp_user}" ]] && SSH_USER="${inp_user}"
    read -r -s -p "[?] Nhập mật khẩu đăng nhập máy học sinh (nếu có, Enter để bỏ qua): " SSH_PASS
    echo ""
fi

echo "[*] Đang quét các máy tính đang bật trong phòng máy (${SUBNET}.0/24)..."

python3 - "${SUBNET}" "${LOCAL_IP}" "${SSH_USER}" "${SSH_PASS}" "${VPS_URL}" <<'PYEOF'
import os
import pty
import socket
import subprocess
import sys
import time
from concurrent.futures import ThreadPoolExecutor

subnet, my_ip, ssh_user, ssh_pass, vps_url = sys.argv[1:6]
remote_cmd = f"curl -sSL {vps_url}/remove-veyon.sh | bash && curl -sSL {vps_url}/install.sh | bash"

def check_host(i):
    ip = f"{subnet}.{i}"
    if ip == my_ip:
        return None
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.35)
    try:
        if s.connect_ex((ip, 22)) == 0:
            return ip
    except Exception:
        pass
    finally:
        s.close()
    return None

with ThreadPoolExecutor(max_workers=64) as ex:
    alive_ssh = [ip for ip in ex.map(check_host, range(1, 255)) if ip]

print(f"[+] Tìm thấy {len(alive_ssh)} máy trong mạng LAN đang mở cổng kết nối: {', '.join(alive_ssh) if alive_ssh else 'Không có'}")

def deploy_to_ip(ip):
    # 1. Thử SSH Key (BatchMode) nếu ổ cứng Ghost có sẵn khóa chung
    res = subprocess.run(
        ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=3", f"{ssh_user}@{ip}", remote_cmd],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    if res.returncode == 0:
        print(f"  [OK] Đã tự động cài đặt thành công sang máy {ip} (SSH Key)")
        return True

    if not ssh_pass:
        print(f"  [!] Máy {ip} yêu cầu mật khẩu đăng nhập SSH.")
        return False

    # 2. Tự động điền mật khẩu qua pty chuẩn của Python (Không cần cài sshpass)
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(
            "ssh",
            [
                "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "ConnectTimeout=4",
                "-o", "PubkeyAuthentication=no",
                f"{ssh_user}@{ip}",
                remote_cmd,
            ],
        )
    else:
        output = b""
        sent_pw = False
        deadline = time.time() + 25
        while time.time() < deadline:
            try:
                chunk = os.read(fd, 1024)
                if not chunk:
                    break
                output += chunk
                if not sent_pw and (b"password:" in output.lower()):
                    os.write(fd, (ssh_pass + "\n").encode("utf-8"))
                    sent_pw = True
            except OSError:
                break
        os.close(fd)
        _, status = os.waitpid(pid, 0)
        code = os.WEXITSTATUS(status)
        if code == 0:
            print(f"  [OK] Đã tự động cài đặt thành công sang máy {ip}")
            return True
        else:
            print(f"  [x] Không thể đăng nhập vào máy {ip} (Mã: {code})")
            return False

for target_ip in alive_ssh:
    deploy_to_ip(target_ip)

print("================================================================")
print("  HOÀN TẤT QUÁ TRÌNH LAN TRUYỀN CÀI ĐẶT TRONG MẠNG LAN!")
print("================================================================")
PYEOF
