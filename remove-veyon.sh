#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Pro — Headless Veyon Eradicator & Input Rescue (Xubuntu / Linux)
# ============================================================================

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

tui_progress 10 "Initializing silent Veyon removal..."

# Silent root elevation attempt (never prompts interactively)
if [ "$EUID" -ne 0 ] && [ -z "${SG_NO_ELEVATE:-}" ] && [ -f "$0" ] && [[ "$0" != */bash ]] && [[ "$0" != "bash" ]]; then
    if sudo -n true 2>/dev/null; then
        SG_NO_ELEVATE=1 exec sudo -n -E bash "$0" "$@"
    fi
    for _pw in "123456" "1" "admin" "tinhocsaigon" "root" "12345678" "student" "ubuntu"; do
        if echo "$_pw" | sudo -S -p "" true >/dev/null 2>&1; then
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

unlock_xinput_devices() {
    if command -v xinput >/dev/null 2>&1; then
        for disp in ":0" ":1" "${DISPLAY:-:0}"; do
            for id in $(DISPLAY="$disp" xinput list --id-only 2>/dev/null); do
                DISPLAY="$disp" xinput enable "$id" >/dev/null 2>&1 || true
            done
        done
    fi
}

kill_veyon_processes() {
    for proc in veyon-worker veyon-master veyon-service veyon-server veyon-configurator veyon-cli veyon-auth-helper; do
        pkill -9 -f "$proc" >/dev/null 2>&1 || true
        killall -9 "$proc" >/dev/null 2>&1 || true
    done
}

tui_progress 35 "Stopping Veyon processes & unlocking input..."
kill_veyon_processes
unlock_xinput_devices

if [ "$EUID" -eq 0 ]; then
    tui_progress 65 "Purging Veyon packages & masking services..."
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
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y >/dev/null 2>&1 || true
    rm -rf /etc/veyon /usr/lib/x86_64-linux-gnu/veyon /usr/share/veyon /var/log/veyon >/dev/null 2>&1 || true

    for bin in /usr/bin/veyon-service /usr/bin/veyon-server /usr/bin/veyon-worker /usr/bin/veyon-master /usr/bin/veyon-configurator /usr/bin/veyon-cli /usr/bin/veyon-auth-helper; do
        rm -f "$bin" >/dev/null 2>&1 || true
        printf '#!/bin/sh\nexit 0\n' > "$bin" 2>/dev/null || true
        chmod 755 "$bin" >/dev/null 2>&1 || true
    done

    for uhome in /home/*; do
        [ -d "$uhome" ] || continue
        rm -rf "$uhome/.veyon" "$uhome/.config/Veyon"* "$uhome/Desktop/veyon"* "$uhome/Màn hình nền/veyon"* >/dev/null 2>&1 || true
    done

    kill_veyon_processes
    unlock_xinput_devices
    tui_progress 100 "Complete"
    printf "\n  \033[1;32m[OK]\033[0m ĐÃ XÓA SẠCH VÀ VÔ HIỆU HÓA HOÀN TOÀN VEYON (CẤP ROOT).\n"
    exit 0
fi

# User-level headless fallback when root is unavailable
tui_progress 65 "Configuring user-level Veyon blocker daemon..."
rm -rf "$HOME/.veyon" "$HOME/.config/Veyon"* "$HOME/Desktop/veyon"* "$HOME/Màn hình nền/veyon"* >/dev/null 2>&1 || true

GUARD_DIR="$HOME/.local/share/.schoolguard"
KILLER_SCRIPT="$GUARD_DIR/veyon-killer.sh"
mkdir -p "$GUARD_DIR" "$HOME/.config/autostart" "$HOME/.config/systemd/user"

cat << 'EOF' > "$KILLER_SCRIPT"
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
chmod +x "$KILLER_SCRIPT"

cat << EOF > "$HOME/.config/systemd/user/schoolguard-veyon-blocker.service"
[Unit]
Description=SchoolGuard Veyon Blocker & Input Rescue Daemon
After=default.target

[Service]
Type=simple
Environment="DISPLAY=:0"
ExecStart=/bin/bash ${KILLER_SCRIPT}
Restart=always
RestartSec=1

[Install]
WantedBy=default.target
EOF

systemctl --user daemon-reload >/dev/null 2>&1 || true
systemctl --user enable schoolguard-veyon-blocker.service >/dev/null 2>&1 || true
systemctl --user restart schoolguard-veyon-blocker.service >/dev/null 2>&1 || true

cat << EOF > "$HOME/.config/autostart/schoolguard-veyon-blocker.desktop"
[Desktop Entry]
Type=Application
Name=System Input Helper
Exec=/bin/bash -c "nohup '${KILLER_SCRIPT}' >/dev/null 2>&1 &"
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
EOF

for vapp in veyon-worker veyon-server veyon-master veyon-tray; do
    cat << EOF > "$HOME/.config/autostart/${vapp}.desktop"
[Desktop Entry]
Type=Application
Name=${vapp}
Hidden=true
X-GNOME-Autostart-enabled=false
EOF
done

CRON_JOB="* * * * * pgrep -f '${KILLER_SCRIPT}' >/dev/null 2>&1 || DISPLAY=:0 nohup /bin/bash '${KILLER_SCRIPT}' >/dev/null 2>&1 &"
(crontab -l 2>/dev/null | grep -v "veyon-killer.sh"; echo "$CRON_JOB") | crontab - 2>/dev/null || true

pkill -f "$KILLER_SCRIPT" >/dev/null 2>&1 || true
nohup /bin/bash "$KILLER_SCRIPT" >/dev/null 2>&1 &

tui_progress 100 "Complete"
printf "\n  \033[1;32m[OK]\033[0m Veyon eradicated & blocked (headless mode).\n"
exit 0
