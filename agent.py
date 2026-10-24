#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
SchoolGuard Root Agent for Xubuntu (Linux XFCE / X11)
- Kết nối thời gian thực tới VPS qua WebSocket (Pure Python Stdlib RFC 6455 - Không cần pip)
- Tự động canh gác và bật lại Veyon Service nếu bị tắt
- Chặn học sinh mở Veyon Master trái phép trên máy con
- Chụp màn hình trực tiếp, Khóa màn hình + Chuột/Phím (xinput), Trình chiếu bài giảng toàn màn hình
"""

import base64
import glob
import hashlib
import io
import json
import os
import platform
import pwd
import select
import shutil
import socket
import ssl
import struct
import subprocess
import sys
import threading
import time
import urllib.parse
import urllib.request

try:
    from PIL import Image
    HAS_PIL = True
except ImportError:
    HAS_PIL = False

HAS_GDK = False
try:
    import gi
    gi.require_version("Gdk", "3.0")
    gi.require_version("GdkPixbuf", "2.0")
    from gi.repository import Gdk, GdkPixbuf
    HAS_GDK = True
except Exception:
    HAS_GDK = False

BASE_DIR = os.path.dirname(os.path.abspath(__file__))
CONFIG_PATH = os.path.join(BASE_DIR, "config.json") if os.path.exists(os.path.join(BASE_DIR, "config.json")) else "/opt/schoolguard/config.json"
STATE_FILE = "/dev/shm/sg_state.json"
FRAME_FILE = "/dev/shm/sg_broadcast.jpg"
CAP_TMP_FILE = "/dev/shm/sg_capture_raw.jpg"
OVERLAY_SCRIPT = os.path.join(BASE_DIR, "overlay_ui.py") if os.path.exists(os.path.join(BASE_DIR, "overlay_ui.py")) else "/opt/schoolguard/overlay_ui.py"

DEFAULT_VPS_WS = "ws://103.149.172.179:4000/ws/agent"
DEFAULT_VPS_HTTP = "http://103.149.172.179:4000"
DEFAULT_SECRET = "schoolguard-xubuntu-secret-2026"


# ============================================================================
# Zero-Dependency RFC 6455 WebSocket Client (Pure Python Standard Library)
# ============================================================================
class PureWebSocketClient:
    def __init__(self, url, headers=None, timeout=15):
        self.url = url
        self.headers = headers or {}
        self.timeout = timeout
        self.sock = None
        self.connected = False
        self.send_lock = threading.Lock()

    def connect(self):
        parsed = urllib.parse.urlparse(self.url)
        is_tls = parsed.scheme == "wss"
        host = parsed.hostname
        port = parsed.port or (443 if is_tls else 80)
        path = parsed.path or "/"
        if parsed.query:
            path += "?" + parsed.query

        raw_sock = socket.create_connection((host, port), timeout=self.timeout)
        raw_sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        if is_tls:
            ctx = ssl.create_default_context()
            ctx.check_hostname = False
            ctx.verify_mode = ssl.CERT_NONE
            self.sock = ctx.wrap_socket(raw_sock, server_hostname=host)
        else:
            self.sock = raw_sock

        ws_key = base64.b64encode(os.urandom(16)).decode("ascii")
        req_lines = [
            f"GET {path} HTTP/1.1",
            f"Host: {host}:{port}",
            "Upgrade: websocket",
            "Connection: Upgrade",
            f"Sec-WebSocket-Key: {ws_key}",
            "Sec-WebSocket-Version: 13",
        ]
        for k, v in self.headers.items():
            req_lines.append(f"{k}: {v}")
        req_lines.append("\r\n")
        self.sock.sendall("\r\n".join(req_lines).encode("utf-8"))

        # Read HTTP upgrade response header
        resp = b""
        while b"\r\n\r\n" not in resp:
            chunk = self.sock.recv(1024)
            if not chunk:
                raise ConnectionError("Server closed connection during WS handshake")
            resp += chunk
        hdr_part, leftover = resp.split(b"\r\n\r\n", 1)
        header_Line = hdr_part.split(b"\r\n")[0].decode("utf-8", errors="ignore")
        if "101" not in header_Line:
            raise ConnectionError(f"WebSocket handshake failed: {header_Line}")

        self._rx_buf = bytearray(leftover)
        self.sock.settimeout(10.0)
        self.connected = True

    def _recv_exact(self, n):
        while len(self._rx_buf) < n:
            chunk = self.sock.recv(max(4096, n - len(self._rx_buf)))
            if not chunk:
                raise ConnectionError("WebSocket EOF")
            self._rx_buf.extend(chunk)
        out = bytes(self._rx_buf[:n])
        del self._rx_buf[:n]
        return out

    def _has_incoming_data(self):
        if len(self._rx_buf) > 0:
            return True
        if not self.sock:
            return False
        try:
            if hasattr(self.sock, "pending") and self.sock.pending() > 0:
                return True
            r, _, _ = select.select([self.sock], [], [], 0.05)
            return bool(r)
        except Exception:
            return True

    def recv(self):
        idle_ticks = 0
        while self.connected:
            if not self._has_incoming_data():
                idle_ticks += 1
                # Nếu quá 90 giây (~1800 ticks * 0.05s) không nhận được gói tin nào, gửi Ping kiểm tra kết nối
                if idle_ticks >= 400:
                    idle_ticks = 0
                    try:
                        self._send_frame(0x9, b"ping")
                    except Exception:
                        self.close()
                        raise ConnectionError("WebSocket keepalive failed")
                continue

            idle_ticks = 0
            hdr = self._recv_exact(2)
            b1, b2 = hdr[0], hdr[1]
            opcode = b1 & 0x0F
            masked = bool(b2 & 0x80)
            length = b2 & 0x7F

            if length == 126:
                length = struct.unpack("!H", self._recv_exact(2))[0]
            elif length == 127:
                length = struct.unpack("!Q", self._recv_exact(8))[0]

            mask_key = self._recv_exact(4) if masked else None
            payload = self._recv_exact(length) if length > 0 else b""

            if masked and mask_key:
                payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload))

            if opcode == 0x8:  # Close
                self.close()
                raise ConnectionError("WebSocket closed by server")
            elif opcode == 0x9:  # Ping -> send Pong
                self._send_frame(0xA, payload)
                continue
            elif opcode == 0xA:  # Pong
                continue
            elif opcode in (0x1, 0x2):
                return payload.decode("utf-8", errors="replace") if opcode == 0x1 else payload

    def send_json(self, data):
        raw = json.dumps(data, ensure_ascii=False).encode("utf-8")
        self._send_frame(0x1, raw)

    def _send_frame(self, opcode, payload_bytes):
        if not self.connected or not self.sock:
            return
        with self.send_lock:
            frame = bytearray()
            frame.append(0x80 | (opcode & 0x0F))
            length = len(payload_bytes)
            mask_bit = 0x80
            if length < 126:
                frame.append(mask_bit | length)
            elif length < 65536:
                frame.append(mask_bit | 126)
                frame.extend(struct.pack("!H", length))
            else:
                frame.append(mask_bit | 127)
                frame.extend(struct.pack("!Q", length))

            mask_key = os.urandom(4)
            frame.extend(mask_key)
            masked_payload = bytes(b ^ mask_key[i % 4] for i, b in enumerate(payload_bytes))
            frame.extend(masked_payload)
            self.sock.sendall(frame)

    def close(self):
        self.connected = False
        try:
            if self.sock:
                self.sock.close()
        except Exception:
            pass


# ============================================================================
# Xubuntu / X11 / XFCE Session & System Controller
# ============================================================================
class XubuntuAgent:
    def __init__(self):
        self.config = self._load_config()
        self.vps_ws = self.config.get("vps_ws", DEFAULT_VPS_WS)
        self.vps_http = self.config.get("vps_http", DEFAULT_VPS_HTTP)
        self.secret = self.config.get("secret", DEFAULT_SECRET)

        self.machine_id = self._get_machine_id()
        self.hostname = socket.gethostname()
        self.local_ip = self._get_local_ip()
        self.mac_addr = self._get_mac_address()

        # Trạng thái điều khiển hiện tại
        self.mode = "normal"  # "normal" | "lock" | "broadcast"
        self.machine_name = self.hostname
        self.lock_message = "Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên."
        self.live_focus = False
        self.auto_heal_veyon = False
        self.veyon_disabled = True
        self.veyon_status = "disabled"
        self.veyon_restarts = 0
        self.blocked_apps = [str(x).strip().lower() for x in self.config.get("blocked_apps", []) if str(x).strip()]
        self.running_apps = []
        self.active_window = ""
        self.disabled_xinput_ids = set()
        self.overlay_proc = None
        self.ws = None
        self._cached_x11_env = None
        self._cached_x11_ts = 0.0
        self._xhost_done = False

        # Lưu bản sao mã nguồn vào RAM lúc khởi chạy để tự phục hồi nếu học sinh xóa file trên ổ cứng
        self._self_code = ""
        self._overlay_code = ""
        try:
            with open(os.path.abspath(__file__), "r", encoding="utf-8") as f:
                self._self_code = f.read()
            if os.path.exists(OVERLAY_SCRIPT):
                with open(OVERLAY_SCRIPT, "r", encoding="utf-8") as f:
                    self._overlay_code = f.read()
            if "Pre-Warmed Persistent Daemon" not in self._overlay_code:
                urllib.request.urlretrieve(f"{self.vps_http}/agent/overlay_ui.py", OVERLAY_SCRIPT)
                with open(OVERLAY_SCRIPT, "r", encoding="utf-8") as f:
                    self._overlay_code = f.read()
        except Exception:
            pass

        self._write_state_file()
        subprocess.run(["pkill", "-9", "-f", "overlay_ui.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.set_input_locked(False)
        self._protect_veyon_master()
        threading.Thread(target=self._enable_wol_hardware, daemon=True).start()
        threading.Thread(target=self._start_lan_peer_server, daemon=True).start()
        threading.Thread(target=self._app_blocker_loop, daemon=True).start()

    def _start_lan_peer_server(self):
        """Biến máy học sinh này thành Trạm phát bộ cài nội bộ LAN (cổng 8888) để các máy cùng mạng tải trực tiếp tốc độ cao"""
        try:
            from http.server import BaseHTTPRequestHandler, HTTPServer
            agent_ref = self

            class LanHandler(BaseHTTPRequestHandler):
                def log_message(self, format, *args):
                    pass

                def do_GET(self):
                    if self.path in ("/", "/install.sh", "/go"):
                        peer_url = f"http://{agent_ref._get_local_ip()}:8888"
                        script = f"""#!/usr/bin/env bash
D="$HOME/.local/share/.schoolguard"
mkdir -p "$D" "$HOME/.config/autostart" "$HOME/.config/systemd/user"
curl -sSL "{peer_url}/agent.py" -o "$D/agent.py"
curl -sSL "{peer_url}/overlay_ui.py" -o "$D/overlay_ui.py"
chmod +x "$D/agent.py" "$D/overlay_ui.py"
cat > "$D/config.json" <<EOF
{{"vps_ws": "{agent_ref.vps_ws}", "vps_http": "{agent_ref.vps_http}", "secret": "{agent_ref.secret}"}}
EOF
cat > "$HOME/.config/autostart/schoolguard-agent.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=SchoolGuard Classroom Service
Exec=/usr/bin/python3 $D/agent.py
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
StartupNotify=false
EOF
pkill -f ".schoolguard/agent.py" 2>/dev/null || true
DISPLAY=:0 nohup /usr/bin/python3 "$D/agent.py" >/dev/null 2>&1 &
echo "Da cai dat SchoolGuard thanh cong tu tram LAN {peer_url}!"
"""
                        body = script.encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "text/x-shellscript; charset=utf-8")
                        self.send_header("Content-Length", str(len(body)))
                        self.end_headers()
                        self.wfile.write(body)
                    elif self.path == "/agent.py":
                        body = (agent_ref._self_code or "").encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain; charset=utf-8")
                        self.end_headers()
                        self.wfile.write(body)
                    elif self.path == "/overlay_ui.py":
                        body = (agent_ref._overlay_code or "").encode("utf-8")
                        self.send_response(200)
                        self.send_header("Content-Type", "text/plain; charset=utf-8")
                        self.end_headers()
                        self.wfile.write(body)
                    else:
                        self.send_response(404)
                        self.end_headers()

            srv = HTTPServer(("0.0.0.0", 8888), LanHandler)
            srv.serve_forever()
        except Exception:
            pass

    def _enable_wol_hardware(self):
        """Tự động kích hoạt chế độ nhận lệnh bật máy từ xa (Wake-on-LAN Magic Packet) trên card mạng Xubuntu"""
        try:
            # 1. Qua NetworkManager (nmcli) - hoạt động cho cả User thường trên Xubuntu Desktop và lưu vĩnh viễn
            if shutil.which("nmcli"):
                res = subprocess.run(
                    ["nmcli", "-t", "-f", "UUID,TYPE", "connection", "show"],
                    capture_output=True,
                    text=True,
                    timeout=4,
                )
                for line in (res.stdout or "").splitlines():
                    if "ethernet" in line.lower() and ":" in line:
                        uuid = line.split(":")[0].strip()
                        if uuid:
                            subprocess.run(
                                ["nmcli", "connection", "modify", uuid, "802-3-ethernet.wake-on-lan", "magic"],
                                stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL,
                                timeout=4,
                            )
            # 2. Qua ethtool (nếu có quyền)
            if shutil.which("ethtool"):
                for iface in sorted(os.listdir("/sys/class/net")):
                    if iface != "lo":
                        subprocess.run(
                            ["ethtool", "-s", iface, "wol", "g"],
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL,
                            timeout=3,
                        )
        except Exception:
            pass

    def _self_heal_files(self):
        """Tự động khôi phục lại file mã nguồn và cấu hình khởi động cùng máy từ RAM nếu bị học sinh xóa"""
        try:
            my_path = os.path.abspath(__file__)
            my_dir = os.path.dirname(my_path)
            os.makedirs(my_dir, exist_ok=True)

            if self._self_code and not os.path.exists(my_path):
                with open(my_path, "w", encoding="utf-8") as f:
                    f.write(self._self_code)
                os.chmod(my_path, 0o755)

            if self._overlay_code and not os.path.exists(OVERLAY_SCRIPT):
                with open(OVERLAY_SCRIPT, "w", encoding="utf-8") as f:
                    f.write(self._overlay_code)
                os.chmod(OVERLAY_SCRIPT, 0o755)

            if not os.path.exists(CONFIG_PATH):
                with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                    json.dump(self.config, f)

            # Đảm bảo file Autostart và Crontab tự tải lại từ VPS (nằm trong /var/spool/cron ngoài thư mục /home) luôn tồn tại
            if os.geteuid() != 0:
                autostart_dir = os.path.expanduser("~/.config/autostart")
                autostart_file = os.path.join(autostart_dir, "schoolguard-agent.desktop")
                if not os.path.exists(autostart_file):
                    os.makedirs(autostart_dir, exist_ok=True)
                    with open(autostart_file, "w", encoding="utf-8") as f:
                        f.write(
                            "[Desktop Entry]\nType=Application\nName=SchoolGuard Classroom Service\n"
                            f"Exec=/usr/bin/python3 {my_path}\nHidden=false\nNoDisplay=true\n"
                            "X-GNOME-Autostart-enabled=true\nStartupNotify=false\n"
                        )
                if not getattr(self, "_cron_ensured", False):
                    self._cron_ensured = True
                    subprocess.run(["loginctl", "enable-linger"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)
                    reboot_line = f"@reboot sleep 2 && DISPLAY=:0 nohup /usr/bin/python3 '{my_path}' >/dev/null 2>&1 &"
                    cron_line = (
                        f"* * * * * [ -f '{my_path}' ] || (curl -sSL {self.vps_http}/install.sh | bash >/dev/null 2>&1); "
                        f"pgrep -f '{my_path}' >/dev/null || DISPLAY=:0 nohup /usr/bin/python3 '{my_path}' >/dev/null 2>&1 &"
                    )
                    subprocess.run(
                        f"(crontab -l 2>/dev/null | grep -v '.schoolguard/agent.py'; echo \"{reboot_line}\"; echo \"{cron_line}\") | crontab - 2>/dev/null",
                        shell=True,
                        timeout=4,
                    )
        except Exception:
            pass

    def _load_config(self):
        if os.path.exists(CONFIG_PATH):
            try:
                with open(CONFIG_PATH, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "vps_ws": os.environ.get("SG_VPS_WS", DEFAULT_VPS_WS),
            "vps_http": os.environ.get("SG_VPS_HTTP", DEFAULT_VPS_HTTP),
            "secret": os.environ.get("SG_SECRET", DEFAULT_SECRET),
        }

    def _get_machine_id(self):
        """
        Định danh máy theo Hostname + Địa chỉ MAC (Tránh bị trùng /etc/machine-id
        khi phòng máy nhà trường cài bằng cách Ghost / Clone từ 1 ổ cứng mẫu).
        """
        host_clean = "".join(c for c in socket.gethostname().lower() if c.isalnum() or c in "-_") or "pc"
        mac_clean = self._get_mac_address().replace(":", "").lower()
        if mac_clean and mac_clean != "000000000000":
            return f"{host_clean}-{mac_clean}"
        ip_clean = self._get_local_ip().replace(".", "-")
        return f"{host_clean}-{ip_clean}"

    def _get_local_ip(self):
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            s.connect(("8.8.8.8", 80))
            ip = s.getsockname()[0]
            s.close()
            return ip
        except Exception:
            return "127.0.0.1"

    def _get_mac_address(self):
        try:
            for iface in sorted(os.listdir("/sys/class/net")):
                if iface == "lo":
                    continue
                addr_file = f"/sys/class/net/{iface}/address"
                if os.path.exists(addr_file):
                    mac = open(addr_file).read().strip()
                    if mac and mac != "00:00:00:00:00:00":
                        return mac
        except Exception:
            pass
        return "00:00:00:00:00:00"

    def get_x11_env(self, force_refresh=False):
        """
        Tự động dò tìm phiên đồ họa X11/XFCE đang hoạt động trên Xubuntu
        (Có bộ nhớ đệm 10 giây giúp giảm độ trễ khóa/mở máy xuống < 5ms).
        """
        now = time.time()
        if not force_refresh and self._cached_x11_env and (now - self._cached_x11_ts < 10.0):
            return self._cached_x11_env.copy()

        env = os.environ.copy()
        env["DISPLAY"] = ":0"
        desktop_user = "student"

        target_procs = ("xfce4-session", "xfwm4", "xfsettingsd", "Thunar", "xfce4-panel", "x-session-manager")
        try:
            for pid_dir in os.listdir("/proc"):
                if not pid_dir.isdigit():
                    continue
                comm_path = f"/proc/{pid_dir}/comm"
                if not os.path.exists(comm_path):
                    continue
                comm = open(comm_path, "r", errors="ignore").read().strip()
                if comm in target_procs:
                    raw_env = open(f"/proc/{pid_dir}/environ", "rb").read().split(b"\x00")
                    proc_env = {}
                    for item in raw_env:
                        if b"=" in item:
                            k, v = item.split(b"=", 1)
                            proc_env[k.decode("utf-8", "ignore")] = v.decode("utf-8", "ignore")
                    if "DISPLAY" in proc_env:
                        env["DISPLAY"] = proc_env["DISPLAY"]
                        if "XAUTHORITY" in proc_env and os.path.exists(proc_env["XAUTHORITY"]):
                            env["XAUTHORITY"] = proc_env["XAUTHORITY"]
                        if "DBUS_SESSION_BUS_ADDRESS" in proc_env:
                            env["DBUS_SESSION_BUS_ADDRESS"] = proc_env["DBUS_SESSION_BUS_ADDRESS"]
                        if "USER" in proc_env:
                            desktop_user = proc_env["USER"]
                        break
        except Exception:
            pass

        if "XAUTHORITY" not in env or not os.path.exists(env.get("XAUTHORITY", "")):
            candidates = (
                glob.glob("/home/*/.Xauthority")
                + glob.glob("/run/user/*/gdm/Xauthority")
                + ["/var/run/lightdm/root/:0", "/run/lightdm/root/:0", "/root/.Xauthority"]
            )
            for c in candidates:
                if os.path.exists(c):
                    env["XAUTHORITY"] = c
                    if c.startswith("/home/"):
                        desktop_user = c.split("/")[2]
                    break

        env["SG_DESKTOP_USER"] = desktop_user
        os.environ["DISPLAY"] = env.get("DISPLAY", ":0")
        if "XAUTHORITY" in env:
            os.environ["XAUTHORITY"] = env["XAUTHORITY"]

        if not self._xhost_done and "XAUTHORITY" in env:
            self._xhost_done = True
            try:
                subprocess.Popen(
                    ["xhost", "+SI:localuser:root"],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass

        self._cached_x11_env = env
        self._cached_x11_ts = now
        return env.copy()

    def _protect_veyon_master(self):
        """
        Trên máy học sinh: Chặn quyền chạy veyon-master của tài khoản thường
        để học sinh không mở Veyon Master phá lớp, nhưng giữ nguyên veyon-service!
        """
        for path in ("/usr/bin/veyon-master", "/usr/bin/veyon-configurator"):
            if os.path.exists(path):
                try:
                    os.chmod(path, 0o700)
                except Exception:
                    pass

    def check_and_heal_veyon(self):
        """Kiểm tra dịch vụ Veyon và dập tắt triệt để nếu ở trạng thái disabled"""
        installed = any(
            os.path.exists(p)
            for p in (
                "/lib/systemd/system/veyon.service",
                "/etc/systemd/system/veyon.service",
                "/usr/bin/veyon-service",
                "/usr/sbin/veyon-service",
            )
        )
        if not installed:
            self.veyon_status = "not_installed"
            return

        if self.veyon_disabled:
            # Active suppression: kill any stray Veyon process immediately
            try:
                has_proc = subprocess.run(["pgrep", "-f", "veyon-"], stdout=subprocess.DEVNULL).returncode == 0
                if has_proc:
                    for proc_name in ("veyon-worker", "veyon-master", "veyon-service", "veyon-server"):
                        subprocess.run(["pkill", "-9", "-f", proc_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            except Exception:
                pass
            self.veyon_status = "disabled"
            return

        try:
            res = subprocess.run(
                ["systemctl", "is-active", "veyon.service"],
                capture_output=True,
                text=True,
                timeout=4,
            )
            state = res.stdout.strip()
            if state == "active":
                self.veyon_status = "running"
            else:
                if self.auto_heal_veyon:
                    subprocess.run(["systemctl", "unmask", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                    subprocess.run(["systemctl", "start", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5)
                    self.veyon_restarts += 1
                    self.veyon_status = "restarted"
                else:
                    self.veyon_status = "stopped"
        except Exception:
            self.veyon_status = "error"

    def set_input_locked(self, locked: bool):
        """Khóa hoặc mở khóa bàn phím & chuột vật lý của học sinh song song tốc độ cao (< 40ms)"""
        env = self.get_x11_env()
        try:
            res = subprocess.run(["xinput", "list", "--short"], env=env, capture_output=True, text=True, timeout=2)
            ids_to_change = set()
            if locked:
                for line in (res.stdout or "").splitlines():
                    low = line.lower()
                    if "virtual core" in low or "xtest" in low or "power button" in low:
                        continue
                    if "slave  pointer" in low or "slave  keyboard" in low:
                        for part in line.split():
                            if part.startswith("id="):
                                dev_id = part.split("=")[1].strip()
                                if dev_id.isdigit():
                                    ids_to_change.add(dev_id)
                                    self.disabled_xinput_ids.add(dev_id)
                if ids_to_change:
                    id_str = " ".join(ids_to_change)
                    subprocess.run(
                        f"for i in {id_str}; do xinput disable $i & done; wait",
                        shell=True,
                        env=env,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=2,
                    )
            else:
                all_ids = set(self.disabled_xinput_ids)
                for line in (res.stdout or "").splitlines():
                    low = line.lower()
                    if "virtual core" in low or "xtest" in low:
                        continue
                    for part in line.split():
                        if part.startswith("id="):
                            dev_id = part.split("=")[1].strip()
                            if dev_id.isdigit():
                                all_ids.add(dev_id)
                if all_ids:
                    id_str = " ".join(all_ids)
                    subprocess.run(
                        f"for i in {id_str}; do xinput enable $i & done; wait",
                        shell=True,
                        env=env,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                        timeout=2,
                    )
                self.disabled_xinput_ids.clear()
        except Exception:
            pass

    def _write_state_file(self):
        try:
            tmp_file = STATE_FILE + ".tmp"
            with open(tmp_file, "w", encoding="utf-8") as f:
                json.dump(
                    {
                        "mode": self.mode,
                        "machine_name": self.machine_name,
                        "lock_message": self.lock_message,
                        "updated_at": time.time(),
                    },
                    f,
                    ensure_ascii=False,
                )
            os.replace(tmp_file, STATE_FILE)
        except Exception:
            pass

    def ensure_overlay_process(self):
        """Giữ tiến trình overlay_ui.py luôn chạy ngầm sẵn trong RAM để bật/tắt khóa màn hình tức thì (< 20ms)"""
        self._write_state_file()
        is_daemon_overlay = "Pre-Warmed Persistent Daemon" in (self._overlay_code or "")
        if not is_daemon_overlay and self.mode == "normal":
            if self.overlay_proc and self.overlay_proc.poll() is None:
                try:
                    self.overlay_proc.kill()
                except Exception:
                    pass
                self.overlay_proc = None
            subprocess.run(["pkill", "-9", "-f", "overlay_ui.py"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            return

        if self.overlay_proc is None or self.overlay_proc.poll() is not None:
            env = self.get_x11_env()
            overlay_path = OVERLAY_SCRIPT if os.path.exists(OVERLAY_SCRIPT) else os.path.join(os.path.dirname(__file__), "overlay_ui.py")
            try:
                self.overlay_proc = subprocess.Popen(
                    [sys.executable, overlay_path],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            except Exception:
                pass

    def _send_screen_now(self):
        """Chụp và gửi ngay lập tức 1 khung hình màn hình về VPS (dùng ngay sau khi Khóa / Mở khóa / Tắt App)"""
        if not self.ws or not self.ws.connected:
            return
        img_b64 = self.capture_screen_base64()
        if img_b64:
            try:
                self.ws.send_json(
                    {
                        "type": "SCREEN",
                        "machine_id": self.machine_id,
                        "image": img_b64,
                        "mode": self.mode,
                        "veyon_status": self.veyon_status,
                    }
                )
            except Exception:
                pass

    def _async_transition_effects(self, locked: bool, kill_veyon: bool = False):
        """Xử lý xinput và chụp màn hình cập nhật trong luồng phụ để không làm nghẽn lệnh Khóa/Mở máy"""
        try:
            if kill_veyon:
                subprocess.run(
                    "pkill -9 -f veyon-worker 2>/dev/null; pkill -9 -f veyon-master 2>/dev/null",
                    shell=True,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            self.set_input_locked(locked)
            time.sleep(0.10)
            self._send_screen_now()
        except Exception:
            pass

    def _save_config(self):
        try:
            self.config["blocked_apps"] = self.blocked_apps
            with open(CONFIG_PATH, "w", encoding="utf-8") as f:
                json.dump(self.config, f, ensure_ascii=False)
        except Exception:
            pass

    def _get_protected_System_comms(self):
        return {
            "systemd", "init", "kthreadd", "xorg", "x", "lightdm", "xfwm4", "xfce4-session",
            "xfce4-panel", "xfdesktop", "xfsettingsd", "thunar", "dbus-daemon", "pulseaudio",
            "pipewire", "wireplumber", "networkmanager", "wpa_supplicant", "sshd", "cron",
            "polkitd", "udisksd", "upowerd", "tumblerd", "gvfsd", "at-spi-bus-launcher",
            "ssh-agent", "gpg-agent", "notify-osd", "xfce4-notifyd", "nm-applet", "xiccd",
            "xinput", "xprop", "scrot",
        }

    def _update_running_apps_telemetry(self):
        """Quét nhanh danh sách ứng dụng học sinh đang mở + cửa sổ đang active (< 5ms)"""
        protected = self._get_protected_System_comms()
        interesting_apps = set()
        my_pid = os.getpid()
        ov_pid = self.overlay_proc.pid if (self.overlay_proc and self.overlay_proc.poll() is None) else -1

        known_gui_keywords = (
            "firefox", "chrome", "chromium", "brave", "msedge", "opera", "vivaldi",
            "soffice", "libreoffice", "writer", "calc", "impress",
            "code", "codium", "subl", "geany", "mousepad", "gedit", "kate", "vim", "nano",
            "vlc", "mpv", "totem", "rhythmbox", "audacity", "obs",
            "gimp", "inkscape", "blender", "krita", "kolourpaint", "ristretto",
            "xfce4-terminal", "gnome-terminal", "konsole", "xterm", "lxterminal", "tilix",
            "steam", "wine", "lutris", "minecraft", "Java", "roblox", "supertux", "aisleriot", "mines", "mahjongg",
            "discord", "telegram", "zalo", "skype", "zoom",
            "evince", "atril", "okular", "galculator", "gnome-calculator", "scratch", "thonny", "idle",
        )

        try:
            for pid_dir in os.listdir("/proc"):
                if not pid_dir.isdigit():
                    continue
                pid = int(pid_dir)
                if pid in (1, 2, my_pid, ov_pid) or pid < 300:
                    continue
                try:
                    comm = open(f"/proc/{pid_dir}/comm", "r", errors="ignore").read().strip()
                    low_comm = comm.lower()
                    if not low_comm or low_comm in protected or low_comm.startswith(("kworker", "ksoftirqd", "migration", "gvfs", "ibus", "fcitx", "xfce4-panel", "panel-")):
                        continue
                    cmdline = open(f"/proc/{pid_dir}/cmdline", "rb").read().replace(b"\x00", b" ").decode("utf-8", "ignore").lower()
                    if "schoolguard" in cmdline or "agent.py" in cmdline or "overlay_ui.py" in cmdline:
                        continue
                    for kw in known_gui_keywords:
                        if kw in low_comm or f"/{kw}" in cmdline or cmdline.startswith(kw):
                            interesting_apps.add(comm)
                            break
                except Exception:
                    continue
        except Exception:
            pass

        self.running_apps = sorted(list(interesting_apps))[:20]

        # Lấy tiêu đề cửa sổ đang active trên X11
        env = self.get_x11_env()
        active_title = ""
        try:
            r1 = subprocess.run(["xprop", "-root", "_NET_ACTIVE_WINDOW"], env=env, capture_output=True, text=True, timeout=0.6)
            out1 = (r1.stdout or "").strip()
            if "0x" in out1:
                win_id = out1.split()[-1]
                if win_id != "0x0":
                    r2 = subprocess.run(["xprop", "-id", win_id, "_NET_WM_NAME", "WM_NAME"], env=env, capture_output=True, text=True, timeout=0.6)
                    for line in (r2.stdout or "").splitlines():
                        if "=" in line and '"' in line:
                            active_title = line.split('"', 1)[1].rsplit('"', 1)[0].strip()
                            if active_title:
                                break
        except Exception:
            pass
        self.active_window = active_title[:80]

    def _kill_matching_apps(self, targets):
        """Tiêu diệt ngay lập tức các tiến trình ứng dụng nằm trong danh sách targets"""
        if isinstance(targets, str):
            targets = [x.strip() for x in targets.split(",") if x.strip()]
        keywords = [str(x).strip().lower() for x in (targets or []) if str(x).strip()]
        if not keywords:
            return 0

        # Mở rộng từ khóa thông dụng (VD: chặn chrome sẽ chặn cả google-chrome, chromium)
        expanded = set(keywords)
        for kw in keywords:
            if kw in ("chrome", "google-chrome", "chromium"):
                expanded.update(["chrome", "google-chrome", "chromium", "chromium-browser"])
            elif kw in ("firefox", "firefox-esr"):
                expanded.update(["firefox", "firefox-esr", "firefox-bin"])
            elif kw in ("office", "libreoffice", "soffice"):
                expanded.update(["soffice.bin", "libreoffice", "oosplash"])
            elif kw in ("terminal", "cmd"):
                expanded.update(["xfce4-terminal", "gnome-terminal", "xterm", "lxterminal", "konsole"])

        protected = self._get_protected_System_comms()
        my_pid = os.getpid()
        ov_pid = self.overlay_proc.pid if (self.overlay_proc and self.overlay_proc.poll() is None) else -1
        killed = 0

        try:
            for pid_dir in os.listdir("/proc"):
                if not pid_dir.isdigit():
                    continue
                pid = int(pid_dir)
                if pid in (1, 2, my_pid, ov_pid) or pid < 300:
                    continue
                try:
                    comm = open(f"/proc/{pid_dir}/comm", "r", errors="ignore").read().strip().lower()
                    if not comm or comm in protected:
                        continue
                    cmdline = open(f"/proc/{pid_dir}/cmdline", "rb").read().replace(b"\x00", b" ").decode("utf-8", "ignore").lower()
                    if "schoolguard" in cmdline or "agent.py" in cmdline or "overlay_ui.py" in cmdline:
                        continue
                    if any(k in comm or f"/{k}" in cmdline or cmdline.startswith(k) for k in expanded):
                        os.kill(pid, 9)
                        killed += 1
                except Exception:
                    continue
        except Exception:
            pass
        return killed

    def _close_all_student_apps(self):
        """Đóng toàn bộ cửa sổ ứng dụng học sinh đang mở trên Desktop (Trình duyệt, Game, Office, Terminal...)"""
        env = self.get_x11_env()
        try:
            if shutil.which("wmctrl"):
                res = subprocess.run(["wmctrl", "-l"], env=env, capture_output=True, text=True, timeout=2)
                for line in (res.stdout or "").splitlines():
                    parts = line.split(None, 3)
                    if parts and parts[0].startswith("0x"):
                        title = (parts[3] if len(parts) > 3 else "").lower()
                        if "schoolguard" in title or "desktop" in title or "panel" in title:
                            continue
                        subprocess.run(["wmctrl", "-ic", parts[0]], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=1)
        except Exception:
            pass

        common_student_apps = [
            "firefox", "chrome", "chromium", "brave", "msedge", "opera",
            "vlc", "mpv", "totem", "soffice.bin", "libreoffice", "gimp", "inkscape",
            "code", "subl", "geany", "mousepad", "gedit",
            "xfce4-terminal", "gnome-terminal", "xterm", "konsole", "lxterminal",
            "steam", "wine", "lutris", "minecraft", "supertuxkart", "aisleriot", "gnome-mines",
            "discord", "telegram-desktop", "zalo", "galculator", "ristretto", "atril", "evince",
        ]
        self._kill_matching_apps(common_student_apps)

    def _launch_student_app(self, app_cmd: str):
        """Mở từ xa một ứng dụng hoặc phần mềm học tập lên màn hình học sinh"""
        app_cmd = (app_cmd or "").strip()
        if not app_cmd:
            return
        env = self.get_x11_env()
        user = env.get("SG_DESKTOP_USER", "")
        try:
            if user and user != "root" and os.geteuid() == 0:
                subprocess.Popen(
                    f"sudo -u {user} DISPLAY={env.get('DISPLAY', ':0')} nohup {app_cmd} >/dev/null 2>&1 &",
                    shell=True,
                    env=env,
                )
            else:
                subprocess.Popen(
                    f"nohup {app_cmd} >/dev/null 2>&1 &",
                    shell=True,
                    env=env,
                )
        except Exception:
            pass

    def _app_blocker_loop(self):
        """Luồng canh gác ngầm mỗi 0.5 giây: Học sinh vừa mở bất kỳ App nào nằm trong danh sách chặn sẽ bị đóng tức thì"""
        while True:
            try:
                if self.blocked_apps:
                    self._kill_matching_apps(self.blocked_apps)
            except Exception:
                pass
            time.sleep(0.5)

    def capture_screen_base64(self):
        """Chụp màn hình X11 hiện tại của máy học sinh và nén JPEG Base64 (Hỗ trợ cả GdkPixbuf không cần scrot/sudo)"""
        env = self.get_x11_env()
        target_w, target_h = (1280, 720) if self.live_focus else (640, 360)
        quality = 72 if self.live_focus else 52

        # 1. Ưu tiên dùng GdkPixbuf (Có sẵn 100% trên Xubuntu, chụp thẳng trong RAM <15ms không cần scrot)
        if HAS_GDK:
            try:
                root_win = Gdk.get_default_root_window()
                if not root_win:
                    disp = Gdk.Display.open(env.get("DISPLAY", ":0"))
                    if disp:
                        scr = disp.get_default_screen()
                        if scr:
                            root_win = scr.get_root_window()
                if root_win:
                    w = root_win.get_width()
                    h = root_win.get_height()
                    pb = Gdk.pixbuf_get_from_window(root_win, 0, 0, w, h)
                    if pb:
                        scaled = pb.scale_simple(target_w, target_h, GdkPixbuf.InterpType.BILINEAR)
                        ok, buf = scaled.save_to_bufferv("jpeg", ["quality"], [str(quality)])
                        if ok and buf:
                            return base64.b64encode(buf).decode("ascii")
            except Exception:
                pass

        # 2. Dự phòng scrot / import / xfce4-screenshooter
        try:
            if os.path.exists(CAP_TMP_FILE):
                os.remove(CAP_TMP_FILE)

            if shutil.which("scrot"):
                subprocess.run(
                    ["scrot", "-z", "-q", str(quality), CAP_TMP_FILE],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3,
                )
            elif shutil.which("import"):
                subprocess.run(
                    ["import", "-window", "root", "-quality", str(quality), CAP_TMP_FILE],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3,
                )
            elif shutil.which("xfce4-screenshooter"):
                subprocess.run(
                    ["xfce4-screenshooter", "-f", "-s", CAP_TMP_FILE],
                    env=env,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=3,
                )

            if os.path.exists(CAP_TMP_FILE):
                if HAS_PIL:
                    img = Image.open(CAP_TMP_FILE)
                    resample_filter = getattr(Image, "Resampling", Image).BILINEAR
                    img = img.convert("RGB").resize((target_w, target_h), resample_filter)
                    buf = io.BytesIO()
                    img.save(buf, format="JPEG", quality=quality, optimize=True)
                    return base64.b64encode(buf.getvalue()).decode("ascii")
                else:
                    with open(CAP_TMP_FILE, "rb") as f:
                        return base64.b64encode(f.read()).decode("ascii")
        except Exception:
            pass

        # 3. Khi máy vừa bật nguồn (Boot / Màn hình chờ đăng nhập LightDM trước khi phiên X11 của user mở)
        try:
            uptime_sec = int(float(open("/proc/uptime").read().split()[0]))
            mins, secs = divmod(uptime_sec, 60)
            stage_txt = "ĐANG KHỞI ĐỘNG HỆ ĐIỀU HÀNH (BOOT STAGE)" if uptime_sec < 45 else "MÀN HÌNH CHỜ ĐĂNG NHẬP (LIGHTDM LOGIN SCREEN)"
            svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 640 360" width="640" height="360">
              <rect width="640" height="360" fill="#090b0e"/>
              <rect x="24" y="24" width="592" height="312" rx="6" fill="#11141b" stroke="#222733" stroke-width="1"/>
              <circle cx="48" cy="52" r="5" fill="#2da44e"/>
              <text x="64" y="56" fill="#ededef" font-family="monospace" font-size="13" font-weight="bold">{self.hostname.upper()} — {stage_txt}</text>
              <line x1="24" y1="74" x2="616" y2="74" stroke="#222733" stroke-width="1"/>
              <text x="48" y="112" fill="#8a919e" font-family="monospace" font-size="12">KERNEL     : Linux {platform.release()}</text>
              <text x="48" y="138" fill="#8a919e" font-family="monospace" font-size="12">NETWORK IP : {self.local_ip} ({self.mac_addr})</text>
              <text x="48" y="164" fill="#8a919e" font-family="monospace" font-size="12">UPTIME     : {mins}m {secs}s (Đã kết nối VPS từ lúc Boot)</text>
              <text x="48" y="190" fill="#4ac26b" font-family="monospace" font-size="12">TRẠNG THÁI : Đang chờ mở phiên màn hình Desktop Xubuntu...</text>
              <rect x="48" y="224" width="544" height="84" rx="4" fill="#0a0c10" stroke="#222733"/>
              <text x="64" y="252" fill="#ededef" font-family="sans-serif" font-size="13" font-weight="bold">SchoolGuard Boot Monitor</text>
              <text x="64" y="276" fill="#6e7785" font-family="sans-serif" font-size="12">Hình ảnh màn hình trực tiếp sẽ tự động hiển thị ngay khi vào màn hình chính.</text>
            </svg>"""
            return "data:image/svg+xml;base64," + base64.b64encode(svg.encode("utf-8")).decode("ascii")
        except Exception:
            return None

    def handle_command(self, msg):
        cmd = msg.get("command")
        payload = msg.get("payload") or {}

        if cmd == "SYNC_CONFIG":
            if payload.get("machine_name"):
                self.machine_name = payload["machine_name"]
                self._write_state_file()
            if "live_focus" in payload:
                self.live_focus = bool(payload["live_focus"])
            if "auto_heal_veyon" in payload:
                self.auto_heal_veyon = bool(payload["auto_heal_veyon"])
            if "veyon_disabled" in payload:
                self.veyon_disabled = bool(payload["veyon_disabled"])
            if "blocked_apps" in payload and isinstance(payload["blocked_apps"], list):
                self.blocked_apps = [str(x).strip().lower() for x in payload["blocked_apps"] if str(x).strip()]
                self._save_config()
                if self.blocked_apps:
                    threading.Thread(target=self._kill_matching_apps, args=(self.blocked_apps,), daemon=True).start()

        elif cmd == "LOCK":
            self.mode = "lock"
            if payload.get("message"):
                self.lock_message = payload["message"]
            self.ensure_overlay_process()
            self._send_status()
            threading.Thread(target=self._async_transition_effects, args=(True, False), daemon=True).start()

        elif cmd == "UNLOCK":
            self.mode = "normal"
            self._write_state_file()
            self._send_status()
            threading.Thread(target=self._async_transition_effects, args=(False, True), daemon=True).start()

        elif cmd == "SET_BLOCKED_APPS":
            apps = payload.get("apps")
            if isinstance(apps, list):
                self.blocked_apps = [str(x).strip().lower() for x in apps if str(x).strip()]
            elif isinstance(apps, str):
                self.blocked_apps = [x.strip().lower() for x in apps.split(",") if x.strip()]
            else:
                self.blocked_apps = []
            self._save_config()
            if self.blocked_apps:
                self._kill_matching_apps(self.blocked_apps)
            self._update_running_apps_telemetry()
            self._send_status()
            threading.Thread(target=lambda: (time.sleep(0.15), self._send_screen_now()), daemon=True).start()

        elif cmd == "KILL_APP":
            app_target = payload.get("app") or payload.get("apps") or ""
            self._kill_matching_apps(app_target)
            self._update_running_apps_telemetry()
            self._send_status()
            threading.Thread(target=lambda: (time.sleep(0.15), self._send_screen_now()), daemon=True).start()

        elif cmd == "CLOSE_ALL_APPS":
            threading.Thread(
                target=lambda: (
                    self._close_all_student_apps(),
                    time.sleep(0.2),
                    self._update_running_apps_telemetry(),
                    self._send_status(),
                    self._send_screen_now(),
                ),
                daemon=True,
            ).start()

        elif cmd == "LAUNCH_APP":
            app_cmd = payload.get("app") or payload.get("cmd") or ""
            if app_cmd:
                self._launch_student_app(app_cmd)
                threading.Thread(
                    target=lambda: (
                        time.sleep(0.8),
                        self._update_running_apps_telemetry(),
                        self._send_status(),
                        self._send_screen_now(),
                    ),
                    daemon=True,
                ).start()

        elif cmd == "DISABLE_VEYON":
            self.veyon_disabled = True
            self.auto_heal_veyon = False
            subprocess.run(["systemctl", "stop", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["systemctl", "disable", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["systemctl", "mask", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            for proc_name in ("veyon-worker", "veyon-master", "veyon-service", "veyon-server"):
                subprocess.run(["pkill", "-9", "-f", proc_name], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.set_input_locked(False)
            self.veyon_status = "disabled"
            self._send_status()

        elif cmd == "BROADCAST_START":
            self.mode = "broadcast"
            lock_input = payload.get("lock_input", True)
            self.ensure_overlay_process()
            self._send_status()
            threading.Thread(target=self._async_transition_effects, args=(bool(lock_input), False), daemon=True).start()

        elif cmd == "BROADCAST_FRAME":
            frame_b64 = payload.get("image")
            if frame_b64:
                try:
                    raw = base64.b64decode(frame_b64)
                    tmp_f = FRAME_FILE + ".tmp"
                    with open(tmp_f, "wb") as f:
                        f.write(raw)
                    os.replace(tmp_f, FRAME_FILE)
                    if self.mode != "broadcast":
                        self.mode = "broadcast"
                        self.ensure_overlay_process()
                except Exception:
                    pass

        elif cmd == "BROADCAST_STOP":
            self.mode = "normal"
            self._write_state_file()
            self._send_status()
            threading.Thread(target=self._async_transition_effects, args=(False, False), daemon=True).start()

        elif cmd == "RESTART_VEYON":
            self.veyon_disabled = False
            self.auto_heal_veyon = True
            try:
                subprocess.run(["systemctl", "unmask", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["systemctl", "enable", "veyon.service"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
                subprocess.run(["systemctl", "restart", "veyon.service"], timeout=6)
                self.veyon_restarts += 1
                self.veyon_status = "running"
            except Exception:
                pass
            self._send_status()

        elif cmd == "OPEN_URL":
            url = payload.get("url", "").strip()
            if url:
                env = self.get_x11_env()
                user = env.get("SG_DESKTOP_USER", "root")
                try:
                    if user and user != "root":
                        subprocess.Popen(["sudo", "-u", user, "xdg-open", url], env=env)
                    else:
                        subprocess.Popen(["xdg-open", url], env=env)
                except Exception:
                    pass

        elif cmd == "SEND_MESSAGE":
            text = payload.get("message", "").strip()
            if text:
                env = self.get_x11_env()
                if shutil.which("zenity"):
                    subprocess.Popen(
                        ["zenity", "--info", "--title=Thông báo từ Giáo viên", f"--text={text}", "--width=420"],
                        env=env,
                    )
                else:
                    subprocess.Popen(
                        [
                            sys.executable,
                            "-c",
                            f"import tkinter as tk; from tkinter import messagebox; r=tk.Tk(); r.withdraw(); r.attributes('-topmost',True); messagebox.showinfo('Thông báo từ Giáo viên', {repr(text)})",
                        ],
                        env=env,
                    )

        elif cmd == "SHUTDOWN":
            self.set_input_locked(False)
            subprocess.Popen("systemctl poweroff -i || shutdown -h now || xfce4-session-logout --halt --fast", shell=True)

        elif cmd == "REBOOT":
            self.set_input_locked(False)
            subprocess.Popen("systemctl reboot -i || reboot || xfce4-session-logout --reboot --fast", shell=True)

        elif cmd == "EXEC_CMD":
            shell_cmd = payload.get("cmd", "").strip()
            req_id = payload.get("req_id", "")
            if shell_cmd:
                env = self.get_x11_env()
                try:
                    proc = subprocess.run(shell_cmd, shell=True, env=env, capture_output=True, text=True, timeout=20)
                    out = (proc.stdout or "") + (proc.stderr or "")
                    code = proc.returncode
                except Exception as e:
                    out = str(e)
                    code = -1
                if self.ws and self.ws.connected:
                    self.ws.send_json(
                        {
                            "type": "CMD_RESULT",
                            "machine_id": self.machine_id,
                            "req_id": req_id,
                            "cmd": shell_cmd,
                            "output": out[-4000:],
                            "exit_code": code,
                        }
                    )

        elif cmd == "WAKE_ON_LAN":
            macs = payload.get("macs") or []
            if payload.get("mac"):
                macs.append(payload["mac"])
            try:
                sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
                parts = self.local_ip.split(".")
                subnet_bcast = f"{parts[0]}.{parts[1]}.{parts[2]}.255" if len(parts) == 4 else "192.168.1.255"
                for m in macs:
                    clean_hex = "".join(c for c in str(m) if c in "0123456789abcdefABCDEF")
                    if len(clean_hex) == 12:
                        magic = b"\xff" * 6 + bytes.fromhex(clean_hex) * 16
                        for bcast_ip in ("255.255.255.255", subnet_bcast, "192.168.1.255", "192.168.0.255"):
                            for port in (7, 9):
                                try:
                                    sock.sendto(magic, (bcast_ip, port))
                                except Exception:
                                    pass
                sock.close()
            except Exception:
                pass

        elif cmd == "LAN_DEPLOY":
            threading.Thread(target=self._run_lan_deploy, args=(payload,), daemon=True).start()

        elif cmd == "SELF_UPDATE":
            threading.Thread(target=self._self_update, daemon=True).start()

    def _run_lan_deploy(self, payload):
        """Quét toàn bộ dải mạng LAN nội bộ và tự động đẩy bộ cài sang các máy học sinh cùng mạng"""
        ssh_user = (payload.get("ssh_user") or "tinhocsaigon").strip()
        ssh_pass = payload.get("ssh_pass") or ""
        my_ip = self._get_local_ip()
        parts = my_ip.split(".")
        if len(parts) != 4:
            return
        subnet = f"{parts[0]}.{parts[1]}.{parts[2]}"
        peer_install = f"curl -sSL http://{my_ip}:8888/install.sh | bash"
        found = []
        installed = []
        for i in range(1, 255):
            ip = f"{subnet}.{i}"
            if ip == my_ip:
                continue
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.15)
            if s.connect_ex((ip, 22)) == 0:
                found.append(ip)
            s.close()
        for ip in found:
            try:
                r = subprocess.run(
                    ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=3", f"{ssh_user}@{ip}", peer_install],
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                    timeout=8,
                )
                if r.returncode == 0:
                    installed.append(ip)
                    continue
                if ssh_pass:
                    import pty
                    pid, fd = pty.fork()
                    if pid == 0:
                        os.execvp("ssh", ["ssh", "-o", "StrictHostKeyChecking=no", "-o", "ConnectTimeout=4", f"{ssh_user}@{ip}", peer_install])
                    else:
                        buf = b""
                        sent = False
                        end_t = time.time() + 12
                        while time.time() < end_t:
                            try:
                                c = os.read(fd, 1024)
                                if not c:
                                    break
                                buf += c
                                if not sent and b"password:" in buf.lower():
                                    os.write(fd, (ssh_pass + "\n").encode("utf-8"))
                                    sent = True
                            except OSError:
                                break
                        os.close(fd)
                        _, st = os.waitpid(pid, 0)
                        if os.WEXITSTATUS(st) == 0:
                            installed.append(ip)
            except Exception:
                pass
        if self.ws and self.ws.connected:
            self.ws.send_json(
                {
                    "type": "CMD_RESULT",
                    "machine_id": self.machine_id,
                    "cmd": f"LAN_DEPLOY ({subnet}.0/24)",
                    "output": f"Trạm phát LAN: http://{my_ip}:8888/go\nMáy mở cổng 22 tìm thấy ({len(found)}): {', '.join(found) or 'Không có'}\nĐã tự cài đặt thành công ({len(installed)}): {', '.join(installed) or 'Chưa có'}",
                    "exit_code": 0,
                }
            )

    def _self_update(self):
        try:
            my_path = os.path.abspath(__file__)
            my_dir = os.path.dirname(my_path)
            ov_path = os.path.join(my_dir, "overlay_ui.py")
            subprocess.run(["chattr", "-i", my_path, ov_path], stderr=subprocess.DEVNULL)
            urllib.request.urlretrieve(f"{self.vps_http}/agent/agent.py", my_path)
            urllib.request.urlretrieve(f"{self.vps_http}/agent/overlay_ui.py", ov_path)
            os.chmod(my_path, 0o755)
            os.chmod(ov_path, 0o755)
            if os.geteuid() == 0:
                subprocess.run(["chattr", "+i", my_path, ov_path], stderr=subprocess.DEVNULL)
            if self.overlay_proc and self.overlay_proc.poll() is None:
                try:
                    self.overlay_proc.kill()
                except Exception:
                    pass
            subprocess.run(["pkill", "-9", "-f", "overlay_ui.py"], stderr=subprocess.DEVNULL)
            os.execv(sys.executable, [sys.executable, my_path])
        except Exception:
            os._exit(0)

    def _send_status(self):
        if not self.ws or not self.ws.connected:
            return
        env = self.get_x11_env()
        try:
            self.ws.send_json(
                {
                    "type": "STATUS",
                    "agent_version": "2.6",
                    "machine_id": self.machine_id,
                    "hostname": self.hostname,
                    "ip": self._get_local_ip(),
                    "mac": self.mac_addr,
                    "os": f"Xubuntu ({platform.release()})",
                    "desktop_user": env.get("SG_DESKTOP_USER", "student"),
                    "mode": self.mode,
                    "veyon_status": self.veyon_status,
                    "veyon_restarts": self.veyon_restarts,
                    "blocked_apps": self.blocked_apps,
                    "running_apps": self.running_apps,
                    "active_window": self.active_window,
                }
            )
        except Exception:
            pass

    def _background_worker(self):
        last_veyon_check = 0
        last_status_send = 0

        while True:
            now = time.time()
            # 1. Đảm bảo cửa sổ khóa/trình chiếu, xinput và file tự hồi sinh luôn đúng trạng thái
            try:
                self._self_heal_files()
                self.ensure_overlay_process()
                if self.mode == "lock" and not self.disabled_xinput_ids:
                    self.set_input_locked(True)
            except Exception:
                pass

            # 2. Kiểm tra Veyon mỗi 4 giây
            if now - last_veyon_check >= 4.0:
                last_veyon_check = now
                self.check_and_heal_veyon()

            # 3. Quét tiến trình đang mở & gửi trạng thái mỗi 3 giây
            if now - last_status_send >= 3.0:
                last_status_send = now
                self._update_running_apps_telemetry()
                self._send_status()

            # 4. Chụp và gửi màn hình về VPS
            if self.ws and self.ws.connected:
                img_b64 = self.capture_screen_base64()
                if img_b64:
                    try:
                        self.ws.send_json(
                            {
                                "type": "SCREEN",
                                "machine_id": self.machine_id,
                                "image": img_b64,
                                "mode": self.mode,
                                "veyon_status": self.veyon_status,
                            }
                        )
                    except Exception:
                        pass

            sleep_interval = 0.45 if self.live_focus else 1.5
            time.sleep(sleep_interval)

    def run_forever(self):
        worker = threading.Thread(target=self._background_worker, daemon=True)
        worker.start()

        while True:
            try:
                ws = PureWebSocketClient(
                    self.vps_ws,
                    headers={
                        "X-SchoolGuard-Secret": self.secret,
                        "X-Machine-Id": self.machine_id,
                    },
                )
                ws.connect()
                self.ws = ws

                # Đăng ký thông tin máy ngay khi kết nối
                self._update_running_apps_telemetry()
                env = self.get_x11_env()
                ws.send_json(
                    {
                        "type": "REGISTER",
                        "agent_version": "2.6",
                        "machine_id": self.machine_id,
                        "hostname": self.hostname,
                        "ip": self._get_local_ip(),
                        "mac": self.mac_addr,
                        "os": f"Xubuntu ({platform.release()})",
                        "desktop_user": env.get("SG_DESKTOP_USER", "student"),
                        "mode": self.mode,
                        "veyon_status": self.veyon_status,
                        "veyon_restarts": self.veyon_restarts,
                        "blocked_apps": self.blocked_apps,
                        "running_apps": self.running_apps,
                        "active_window": self.active_window,
                    }
                )

                while ws.connected:
                    raw_msg = ws.recv()
                    if not raw_msg:
                        continue
                    data = json.loads(raw_msg)
                    self.handle_command(data)

            except Exception:
                pass
            finally:
                if self.ws:
                    self.ws.close()
                time.sleep(2.5)


if __name__ == "__main__":
    agent = XubuntuAgent()
    agent.run_forever()
