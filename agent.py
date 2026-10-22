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
        self.disabled_xinput_ids = set()
        self.overlay_proc = None
        self.ws = None

        # Lưu bản sao mã nguồn vào RAM lúc khởi chạy để tự phục hồi nếu học sinh xóa file trên ổ cứng
        self._self_code = ""
        self._overlay_code = ""
        try:
            with open(os.path.abspath(__file__), "r", encoding="utf-8") as f:
                self._self_code = f.read()
            if os.path.exists(OVERLAY_SCRIPT):
                with open(OVERLAY_SCRIPT, "r", encoding="utf-8") as f:
                    self._overlay_code = f.read()
        except Exception:
            pass

        self._write_state_file()
        self._protect_veyon_master()

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

            # Đảm bảo file Autostart cùng máy Xubuntu luôn tồn tại
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

    def get_x11_env(self):
        """
        Tự động dò tìm phiên đồ họa X11/XFCE đang hoạt động trên Xubuntu
        ngay cả khi agent chạy dưới quyền root của systemd.
        """
        env = os.environ.copy()
        env["DISPLAY"] = ":0"
        desktop_user = "student"

        # 1. Quét tiến trình của phiên XFCE / X11 để lấy chính xác DISPLAY, XAUTHORITY, DBUS
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

        # 2. Dự phòng tìm XAUTHORITY nếu chưa có
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
        # Cho phép root truy cập X11
        try:
            subprocess.run(
                ["xhost", "+SI:localuser:root"],
                env=env,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=2,
            )
        except Exception:
            pass
        return env

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
        """Khóa hoặc mở khóa bàn phím & chuột vật lý của học sinh qua xinput"""
        env = self.get_x11_env()
        try:
            if locked:
                res = subprocess.run(["xinput", "list", "--short"], env=env, capture_output=True, text=True, timeout=3)
                for line in res.stdout.splitlines():
                    low = line.lower()
                    if "virtual core" in low or "xtest" in low or "power button" in low:
                        continue
                    if "slave  pointer" in low or "slave  keyboard" in low:
                        for part in line.split():
                            if part.startswith("id="):
                                dev_id = part.split("=")[1].strip()
                                if dev_id.isdigit():
                                    subprocess.run(
                                        ["xinput", "disable", dev_id],
                                        env=env,
                                        stdout=subprocess.DEVNULL,
                                        stderr=subprocess.DEVNULL,
                                        timeout=2,
                                    )
                                    self.disabled_xinput_ids.add(dev_id)
            else:
                # Bật lại toàn bộ các thiết bị đã khóa + quét lại các floating slave
                res = subprocess.run(["xinput", "list", "--short"], env=env, capture_output=True, text=True, timeout=3)
                all_ids = set(self.disabled_xinput_ids)
                for line in res.stdout.splitlines():
                    low = line.lower()
                    if "virtual core" in low or "xtest" in low:
                        continue
                    for part in line.split():
                        if part.startswith("id="):
                            dev_id = part.split("=")[1].strip()
                            if dev_id.isdigit():
                                all_ids.add(dev_id)
                for dev_id in all_ids:
                    subprocess.run(
                        ["xinput", "enable", dev_id],
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
        """Đảm bảo cửa sổ Khóa/Trình chiếu luôn hiển thị khi ở chế độ lock hoặc broadcast"""
        self._write_state_file()
        if self.mode in ("lock", "broadcast"):
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
        else:
            if self.overlay_proc is not None and self.overlay_proc.poll() is None:
                try:
                    self.overlay_proc.terminate()
                except Exception:
                    pass
                self.overlay_proc = None

    def capture_screen_base64(self):
        """Chụp màn hình X11 hiện tại của máy học sinh và nén JPEG Base64 (Hỗ trợ cả GdkPixbuf không cần scrot/sudo)"""
        env = self.get_x11_env()
        target_w, target_h = (1280, 720) if self.live_focus else (640, 360)
        quality = 72 if self.live_focus else 52

        # 1. Ưu tiên dùng GdkPixbuf (Có sẵn 100% trên Xubuntu, chụp thẳng trong RAM <15ms không cần scrot)
        if HAS_GDK:
            try:
                root_win = Gdk.get_default_root_window()
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

            if not os.path.exists(CAP_TMP_FILE):
                return None

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

        elif cmd == "LOCK":
            self.mode = "lock"
            if payload.get("message"):
                self.lock_message = payload["message"]
            self.ensure_overlay_process()
            self.set_input_locked(True)
            self._send_status()

        elif cmd == "UNLOCK":
            self.mode = "normal"
            # Rescue student screen from any lingering Veyon lock
            subprocess.run(["pkill", "-9", "-f", "veyon-worker"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            subprocess.run(["pkill", "-9", "-f", "veyon-master"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.set_input_locked(False)
            self.ensure_overlay_process()
            self._send_status()

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
            self.set_input_locked(bool(lock_input))
            self._send_status()

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
            self.set_input_locked(False)
            self.ensure_overlay_process()
            self._send_status()

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

        elif cmd == "SELF_UPDATE":
            threading.Thread(target=self._self_update, daemon=True).start()

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
            os._exit(0)  # systemd Restart=always sẽ tự khởi động lại bản mới ngay lập tức
        except Exception:
            pass

    def _send_status(self):
        if not self.ws or not self.ws.connected:
            return
        env = self.get_x11_env()
        try:
            self.ws.send_json(
                {
                    "type": "STATUS",
                    "machine_id": self.machine_id,
                    "hostname": self.hostname,
                    "ip": self._get_local_ip(),
                    "mac": self.mac_addr,
                    "os": f"Xubuntu ({platform.release()})",
                    "desktop_user": env.get("SG_DESKTOP_USER", "student"),
                    "mode": self.mode,
                    "veyon_status": self.veyon_status,
                    "veyon_restarts": self.veyon_restarts,
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

            # 3. Gửi trạng thái mỗi 4 giây
            if now - last_status_send >= 4.0:
                last_status_send = now
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

            sleep_interval = 0.45 if self.live_focus else 2.0
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
                env = self.get_x11_env()
                ws.send_json(
                    {
                        "type": "REGISTER",
                        "machine_id": self.machine_id,
                        "hostname": self.hostname,
                        "ip": self._get_local_ip(),
                        "mac": self.mac_addr,
                        "os": f"Xubuntu ({platform.release()})",
                        "desktop_user": env.get("SG_DESKTOP_USER", "student"),
                        "mode": self.mode,
                        "veyon_status": self.veyon_status,
                        "veyon_restarts": self.veyon_restarts,
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
