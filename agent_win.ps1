# ============================================================================
# SchoolGuard Windows Agent (Zero-Dependency .NET / PowerShell)
# Chạy ngầm 100% không hiện cửa sổ trên Windows 10/11 (Không cần cài Python)
# Kết nối trực tiếp về VPS: wss://103-149-172-179.sslip.io/ws/agent
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"

# Đảm bảo chỉ chạy duy nhất 1 tiến trình (Chống trùng lặp khi Watchdog kiểm tra mỗi phút)
$createdNew = $false
$Global:SingleInstanceMutex = New-Object System.Threading.Mutex($true, "Local\SchoolGuardWindowsAgentMutex2026", [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Nạp C# WinGuardSecurity cho khóa chuột phím, chặn phím tắt cấp thấp và vô hiệu hóa Task Manager
$csharpCode = @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

public static class WinGuardSecurity {
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [StructLayout(LayoutKind.Sequential)]
    public struct KBDLLHOOKSTRUCT {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private static HookProc _proc = HookCallback;
    private static IntPtr _hookID = IntPtr.Zero;

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool UnhookWindowsHookEx(IntPtr hhk);

    [DllImport("user32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("kernel32.dll", CharSet = CharSet.Auto, SetLastError = true)]
    private static extern IntPtr GetModuleHandle(string lpModuleName);

    [DllImport("user32.dll")]
    public static extern short GetAsyncKeyState(int vKey);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool BlockInput(bool fBlockIt);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    public static void InstallHook() {
        if (_hookID == IntPtr.Zero) {
            using (Process curProcess = Process.GetCurrentProcess())
            using (ProcessModule curModule = curProcess.MainModule) {
                _hookID = SetWindowsHookEx(13, _proc, GetModuleHandle(curModule.ModuleName), 0);
            }
        }
    }

    public static void UninstallHook() {
        if (_hookID != IntPtr.Zero) {
            UnhookWindowsHookEx(_hookID);
            _hookID = IntPtr.Zero;
        }
    }

    public static void SetTaskMgrDisabled(bool disabled) {
        try {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey("Software\\Microsoft\\Windows\\CurrentVersion\\Policies\\System")) {
                if (key != null) {
                    if (disabled) {
                        key.SetValue("DisableTaskMgr", 1, RegistryValueKind.DWord);
                    } else {
                        key.DeleteValue("DisableTaskMgr", false);
                    }
                }
            }
        } catch {}
    }

    private static IntPtr HookCallback(int nCode, IntPtr wParam, IntPtr lParam) {
        if (nCode >= 0) {
            KBDLLHOOKSTRUCT hookStruct = (KBDLLHOOKSTRUCT)Marshal.PtrToStructure(lParam, typeof(KBDLLHOOKSTRUCT));
            uint vk = hookStruct.vkCode;
            bool alt = (hookStruct.flags & 0x20) != 0;
            bool ctrl = (GetAsyncKeyState(0x11) & 0x8000) != 0;

            // Chặn phím Windows: VK_LWIN(0x5B), VK_RWIN(0x5C), VK_APPS(0x5D)
            if (vk == 0x5B || vk == 0x5C || vk == 0x5D) {
                return (IntPtr)1;
            }
            // Chặn phím tắt Alt: Alt+Tab (0x09), Alt+Esc (0x1B), Alt+F4 (0x73)
            if (alt && (vk == 0x09 || vk == 0x1B || vk == 0x73)) {
                return (IntPtr)1;
            }
            // Chặn Ctrl+Esc (0x1B)
            if (ctrl && vk == 0x1B) {
                return (IntPtr)1;
            }
        }
        return CallNextHookEx(_hookID, nCode, wParam, lParam);
    }
}

public static class WinGuardNative {
    public static bool BlockInput(bool fBlockIt) {
        return WinGuardSecurity.BlockInput(fBlockIt);
    }
    public static bool SetForegroundWindow(IntPtr hWnd) {
        return WinGuardSecurity.SetForegroundWindow(hWnd);
    }
}
"@
if (-not ([System.Management.Automation.PSTypeName]'WinGuardSecurity').Type) {
    Add-Type -TypeDefinition $csharpCode -Language CSharp
}

$VPS_WS = "wss://103-149-172-179.sslip.io/ws/agent"
$VPS_HTTP = "https://103-149-172-179.sslip.io"
$SECRET = "schoolguard-xubuntu-secret-2026"
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "SchoolGuard"

# Tạo mã định danh máy duy nhất trên Windows (Dựa theo UUID Bo mạch chủ / MAC)
function Get-MachineId {
    try {
        $uuid = (Get-CimInstance Win32_ComputerSystemProduct).UUID
        if ($uuid -and $uuid -ne "FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF") {
            return ("win-" + $uuid.Replace("-", "").ToLower()).Substring(0, 24)
        }
    } catch {}
    $raw = $env:COMPUTERNAME + "-" + $env:USERNAME
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($raw)
    $hash = [System.Security.Cryptography.SHA256]::Create().ComputeHash($bytes)
    return "win-" + ([BitConverter]::ToString($hash).Replace("-", "").ToLower().Substring(0, 20))
}

function Get-LocalIp {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
    } catch {}
    return "127.0.0.1"
}

function Get-MacAddr {
    try {
        $mac = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1).MacAddress
        if ($mac) { return $mac.Replace("-", ":") }
    } catch {}
    return "00:00:00:00:00:00"
}

$MACHINE_ID = Get-MachineId
$HOSTNAME = $env:COMPUTERNAME
$DESKTOP_USER = $env:USERNAME
$SELF_SCRIPT_PATH = $MyInvocation.MyCommand.Path
$SELF_CODE = if ($SELF_SCRIPT_PATH -and (Test-Path $SELF_SCRIPT_PATH)) { [System.IO.File]::ReadAllText($SELF_SCRIPT_PATH) } else { "" }

# Bảng trạng thái đồng bộ giữa luồng WebSocket và luồng Giao diện Khóa/Trình chiếu
$Global:SharedState = [hashtable]::Synchronized(@{
    Mode          = "normal"     # "normal" | "lock" | "broadcast"
    MachineName   = $HOSTNAME
    LockMessage   = "Vui lòng trật tự và chú ý theo dõi hướng dẫn của Giáo viên."
    LockInput     = $true
    LiveFocus     = $false
    FrameBytes    = $null
    FrameTick     = 0
    VeyonStatus   = "disabled"
    VeyonRestarts = 0
})

# ============================================================================
# Luồng Giao diện Khóa Màn Hình & Trình Chiếu Toàn Màn Hình (STA UI Thread)
# Hỗ trợ Đa màn hình (Multi-Monitor VirtualScreen) và Giao diện Hiện đại
# ============================================================================
$uiRunspace = [runspacefactory]::CreateRunspace()
$uiRunspace.ApartmentState = "STA"
$uiRunspace.ThreadOptions = "ReuseThread"
$uiRunspace.Open()
$uiRunspace.SessionStateProxy.SetVariable("SharedState", $Global:SharedState)

$uiPowershell = [powershell]::Create()
$uiPowershell.Runspace = $uiRunspace
[void]$uiPowershell.AddScript({
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing

    $form = New-Object System.Windows.Forms.Form
    $form.Text = "SchoolGuard Classroom Overlay"
    $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $form.TopMost = $true
    $form.ShowInTaskbar = $false
    $form.BackColor = [System.Drawing.Color]::FromArgb(9, 13, 22)
    $form.KeyPreview = $true

    # Phủ toàn bộ màn hình thực tế (kể cả hệ thống có 2 hoặc nhiều màn hình nối dài)
    $vScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $form.Bounds = $vScreen

    # Chặn đóng cửa sổ (Alt+F4) và mọi phím bấm
    $form.Add_FormClosing({
        param($s, $e)
        if ($SharedState.Mode -eq "lock" -or $SharedState.Mode -eq "broadcast") {
            $e.Cancel = $true
        }
    })
    $form.Add_KeyDown({
        param($s, $e)
        $e.Handled = $true
        $e.SuppressKeyPress = $true
    })

    # Khung toàn diện che phủ
    $lockPanel = New-Object System.Windows.Forms.Panel
    $lockPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lockPanel.BackColor = [System.Drawing.Color]::FromArgb(9, 13, 22)

    # Căn giữa thẻ hiển thị khóa máy tại màn hình chính (Primary Screen)
    $pri = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $cardW = [Math]::Min(960, $pri.Width - 60)
    $cardH = 560
    $centerX = $pri.Left + [int](($pri.Width - $cardW) / 2) - $vScreen.Left
    $centerY = $pri.Top + [int](($pri.Height - $cardH) / 2) - $vScreen.Top

    $centerCard = New-Object System.Windows.Forms.Panel
    $centerCard.Size = New-Object System.Drawing.Size($cardW, $cardH)
    $centerCard.Location = New-Object System.Drawing.Point($centerX, $centerY)
    $centerCard.BackColor = [System.Drawing.Color]::FromArgb(9, 13, 22)
    $lockPanel.Controls.Add($centerCard)

    # 1. Huy hiệu Số Máy (Machine Slot Badge Pill)
    $lblBadge = New-Object System.Windows.Forms.Label
    $lblBadge.Text = "PHÒNG MÁY TIN HỌC  •  MÁY HỌC SINH"
    $lblBadge.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(23, 37, 84)
    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
    $lblBadge.AutoSize = $false
    $lblBadge.Width = 420
    $lblBadge.Height = 38
    $lblBadge.Left = [int](($cardW - $lblBadge.Width) / 2)
    $lblBadge.Top = 0
    $lblBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblBadge)

    # 2. Tiêu đề Khóa Máy
    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "🔒 MÁY TÍNH ĐANG ĐƯỢC KHÓA BỞI GIÁO VIÊN"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 24, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $lblTitle.AutoSize = $false
    $lblTitle.Width = $cardW
    $lblTitle.Height = 56
    $lblTitle.Left = 0
    $lblTitle.Top = 54
    $lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblTitle)

    # 3. Thẻ Thông Báo Giáo Viên Nổi Bật (Elevated Message Card)
    $msgCard = New-Object System.Windows.Forms.Panel
    $msgCard.Width = [Math]::Min(840, $cardW - 40)
    $msgCard.Height = 160
    $msgCard.Left = [int](($cardW - $msgCard.Width) / 2)
    $msgCard.Top = 126
    $msgCard.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)

    # Đường viền điểm nhấn đầu thẻ thông báo
    $accentLine = New-Object System.Windows.Forms.Panel
    $accentLine.Dock = [System.Windows.Forms.DockStyle]::Top
    $accentLine.Height = 3
    $accentLine.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
    $msgCard.Controls.Add($accentLine)

    $lblMsgHead = New-Object System.Windows.Forms.Label
    $lblMsgHead.Text = "💬 LỜI NHẮN TỪ GIÁO VIÊN:"
    $lblMsgHead.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
    $lblMsgHead.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
    $lblMsgHead.AutoSize = $false
    $lblMsgHead.Width = $msgCard.Width
    $lblMsgHead.Height = 26
    $lblMsgHead.Left = 0
    $lblMsgHead.Top = 14
    $lblMsgHead.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $msgCard.Controls.Add($lblMsgHead)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = $SharedState.LockMessage
    $lblMsg.Font = New-Object System.Drawing.Font("Segoe UI", 15, [System.Drawing.FontStyle]::Regular)
    $lblMsg.ForeColor = [System.Drawing.Color]::FromArgb(248, 250, 252)
    $lblMsg.AutoSize = $false
    $lblMsg.Width = $msgCard.Width - 30
    $lblMsg.Height = 100
    $lblMsg.Left = 15
    $lblMsg.Top = 46
    $lblMsg.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $msgCard.Controls.Add($lblMsg)
    $centerCard.Controls.Add($msgCard)

    # 4. Đồng Hồ Số Điện Tử (Digital Clock Ticker)
    $lblClock = New-Object System.Windows.Forms.Label
    $lblClock.Text = "--:--:--"
    $lblClock.Font = New-Object System.Drawing.Font("Consolas", 32, [System.Drawing.FontStyle]::Bold)
    $lblClock.ForeColor = [System.Drawing.Color]::FromArgb(96, 165, 250)
    $lblClock.AutoSize = $false
    $lblClock.Width = $cardW
    $lblClock.Height = 52
    $lblClock.Left = 0
    $lblClock.Top = 304
    $lblClock.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblClock)

    $lblDate = New-Object System.Windows.Forms.Label
    $lblDate.Text = "--/--/----"
    $lblDate.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
    $lblDate.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $lblDate.AutoSize = $false
    $lblDate.Width = $cardW
    $lblDate.Height = 28
    $lblDate.Left = 0
    $lblDate.Top = 360
    $lblDate.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblDate)

    # 5. Huy Hiệu Trạng Thái Bảo Mật (Security Status Footer)
    $lblFooter = New-Object System.Windows.Forms.Label
    $lblFooter.Text = "🛡️ Hệ thống Quản lý SchoolGuard Pro • Bàn phím & Chuột đang tạm khóa"
    $lblFooter.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblFooter.BackColor = [System.Drawing.Color]::FromArgb(30, 27, 75)
    $lblFooter.ForeColor = [System.Drawing.Color]::FromArgb(199, 210, 254)
    $lblFooter.AutoSize = $false
    $lblFooter.Width = [Math]::Min(620, $cardW - 40)
    $lblFooter.Height = 36
    $lblFooter.Left = [int](($cardW - $lblFooter.Width) / 2)
    $lblFooter.Top = 415
    $lblFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblFooter)

    # Khung Trình Chiếu Bài Giảng Toàn Màn Hình
    $picBox = New-Object System.Windows.Forms.PictureBox
    $picBox.Dock = [System.Windows.Forms.DockStyle]::Fill
    $picBox.BackColor = [System.Drawing.Color]::Black
    $picBox.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::Zoom
    $picBox.Visible = $false

    $form.Controls.Add($lockPanel)
    $form.Controls.Add($picBox)

    $lastTick = -1
    $isShowing = $false

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 70
    $timer.Add_Tick({
        $mode = $SharedState.Mode
        if ($mode -eq "lock" -or $mode -eq "broadcast") {
            if (-not $isShowing) {
                $isShowing = $true
                $form.Bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
                $form.Show()
            }
            $form.TopMost = $true
            $form.Activate()

            # Giữ chuột trong màn hình khóa nếu được kích hoạt
            if ($SharedState.LockInput) {
                $priCenter = New-Object System.Drawing.Point([int]($pri.Left + $pri.Width / 2), [int]($pri.Top + $pri.Height / 2))
                [System.Windows.Forms.Cursor]::Clip = New-Object System.Drawing.Rectangle($priCenter.X, $priCenter.Y, 1, 1)
                [System.Windows.Forms.Cursor]::Hide()
            }

            if ($mode -eq "lock") {
                $picBox.Visible = $false
                $lockPanel.Visible = $true
                $lblBadge.Text = "PHÒNG MÁY TIN HỌC  •  " + $SharedState.MachineName
                $lblMsg.Text = $SharedState.LockMessage
                $now = Get-Date
                $lblClock.Text = $now.ToString("HH:mm:ss")
                $lblDate.Text = $now.ToString("dddd, dd/MM/yyyy")
            } else {
                $lockPanel.Visible = $false
                $picBox.Visible = $true
                if ($SharedState.FrameTick -ne $lastTick -and $SharedState.FrameBytes) {
                    $lastTick = $SharedState.FrameTick
                    try {
                        $ms = New-Object System.IO.MemoryStream(,$SharedState.FrameBytes)
                        $newImg = [System.Drawing.Image]::FromStream($ms)
                        $oldImg = $picBox.Image
                        $picBox.Image = $newImg
                        if ($oldImg) { $oldImg.Dispose() }
                        $ms.Dispose()
                    } catch {}
                }
            }
        } else {
            if ($isShowing) {
                $isShowing = $false
                [System.Windows.Forms.Cursor]::Clip = [System.Drawing.Rectangle]::Empty
                [System.Windows.Forms.Cursor]::Show()
                $form.Hide()
            }
        }
    })
    $timer.Start()
    [System.Windows.Forms.Application]::Run()
})
$uiAsync = $uiPowershell.BeginInvoke()

# ============================================================================
# Hàm Chụp Màn Hình Windows Siêu Nhanh - Không Rò Rỉ Bộ Nhớ GDI
# ============================================================================
function Capture-ScreenBase64 {
    $bmp = $null
    $g = $null
    $resized = $null
    $rg = $null
    $ms = $null
    try {
        $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
        if ($bounds.Width -le 0 -or $bounds.Height -le 0) { return $null }

        $bmp = New-Object System.Drawing.Bitmap($bounds.Width, $bounds.Height)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)

        $tw = if ($Global:SharedState.LiveFocus) { 1280 } else { 640 }
        $th = if ($Global:SharedState.LiveFocus) { 720 } else { 360 }
        $resized = New-Object System.Drawing.Bitmap($tw, $th)
        $rg = [System.Drawing.Graphics]::FromImage($resized)
        $rg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::Bilinear
        $rg.DrawImage($bmp, 0, 0, $tw, $th)

        $ms = New-Object System.IO.MemoryStream
        $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Jpeg)
        return [Convert]::ToBase64String($ms.ToArray())
    } catch {
        return $null
    } finally {
        if ($null -ne $ms) { try { $ms.Dispose() } catch {} }
        if ($null -ne $rg) { try { $rg.Dispose() } catch {} }
        if ($null -ne $resized) { try { $resized.Dispose() } catch {} }
        if ($null -ne $g) { try { $g.Dispose() } catch {} }
        if ($null -ne $bmp) { try { $bmp.Dispose() } catch {} }
    }
}

# ============================================================================
# Tự Động Bảo Vệ File & Khởi Động Cùng Windows (RAM Self-Healing)
# ============================================================================
function Invoke-SelfHeal {
    try {
        if (-not (Test-Path $INSTALL_DIR)) {
            New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
        }
        $targetAgent = Join-Path $INSTALL_DIR "agent_win.ps1"
        if ($SELF_CODE -and -not (Test-Path $targetAgent)) {
            [System.IO.File]::WriteAllText($targetAgent, $SELF_CODE, [System.Text.Encoding]::UTF8)
        }
        $vbsPath = Join-Path $INSTALL_DIR "run_hidden.vbs"
        if (-not (Test-Path $vbsPath)) {
            $vbsContent = "Set ws = CreateObject(""Wscript.Shell"")`r`nws.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$targetAgent"""""", 0, False"
            [System.IO.File]::WriteAllText($vbsPath, $vbsContent, [System.Text.Encoding]::ASCII)
        }
        # Giữ khóa Registry tự chạy khi bật Windows
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        Set-ItemProperty -Path $regPath -Name "SchoolGuardAgent" -Value "wscript.exe `"$vbsPath`"" -Force

        # Giám sát và dập tắt Veyon (Tuyệt đối không tự động bật lại Veyon!)
        if ($Global:SharedState.VeyonStatus -eq "disabled") {
            $rogue = Get-Process -Name "*veyon*" -ErrorAction SilentlyContinue
            if ($rogue) {
                Stop-Process -Name "*veyon*" -Force -ErrorAction SilentlyContinue
            }
        } else {
            $vSvc = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
            if ($null -eq $vSvc) {
                $Global:SharedState.VeyonStatus = "not_installed"
            } elseif ($vSvc.Status -eq "Running") {
                $Global:SharedState.VeyonStatus = "running"
            } else {
                $Global:SharedState.VeyonStatus = "stopped"
            }
        }
    } catch {}
}

function Send-WsJson($ws, $obj) {
    try {
        if ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            $json = ConvertTo-Json $obj -Depth 5 -Compress
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
            $seg = New-Object System.ArraySegment[byte](,$bytes)
            $ws.SendAsync($seg, [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()
        }
    } catch {}
}

function Send-WsStatus($ws) {
    Send-WsJson $ws @{
        type           = "STATUS"
        machine_id     = $MACHINE_ID
        hostname       = $HOSTNAME
        ip             = (Get-LocalIp)
        mac            = (Get-MacAddr)
        os             = "Windows (" + [Environment]::OSVersion.Version.ToString() + ")"
        desktop_user   = $DESKTOP_USER
        mode           = $Global:SharedState.Mode
        veyon_status   = $Global:SharedState.VeyonStatus
        veyon_restarts = $Global:SharedState.VeyonRestarts
    }
}

# ============================================================================
# Vòng Lặp Kết Nối WebSocket Thời Gian Thực Về VPS
# ============================================================================
[System.Net.ServicePointManager]::ServerCertificateValidationCallback = { $true }

while ($true) {
    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.SetRequestHeader("X-SchoolGuard-Secret", $SECRET)
    $ws.Options.SetRequestHeader("X-Machine-Id", $MACHINE_ID)

    try {
        $uri = [Uri]$VPS_WS
        $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

        # Đăng ký máy với VPS
        Send-WsJson $ws @{
            type           = "REGISTER"
            machine_id     = $MACHINE_ID
            hostname       = $HOSTNAME
            ip             = (Get-LocalIp)
            mac            = (Get-MacAddr)
            os             = "Windows (" + [Environment]::OSVersion.Version.ToString() + ")"
            desktop_user   = $DESKTOP_USER
            mode           = $Global:SharedState.Mode
            veyon_status   = $Global:SharedState.VeyonStatus
            veyon_restarts = $Global:SharedState.VeyonRestarts
        }

        $recvBuf = New-Object byte[] 65536
        $recvSeg = New-Object System.ArraySegment[byte](,$recvBuf)
        $msMsg = New-Object System.IO.MemoryStream
        $recvTask = $ws.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None)

        $lastScreenTime = [DateTime]::MinValue
        $lastHealTime = [DateTime]::MinValue

        while ($ws.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            if ($recvTask.Wait(120)) {
                $res = $recvTask.GetAwaiter().GetResult()
                if ($res.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                    break
                }
                if ($res.Count -gt 0) {
                    $msMsg.Write($recvBuf, 0, $res.Count)
                }
                if ($res.EndOfMessage) {
                    $rawStr = [System.Text.Encoding]::UTF8.GetString($msMsg.ToArray())
                    $msMsg.SetLength(0)

                    try {
                        $msg = ConvertFrom-Json $rawStr
                        $cmd = $msg.command
                        $payload = $msg.payload

                        switch ($cmd) {
                            "SYNC_CONFIG" {
                                if ($payload.machine_name) { $Global:SharedState.MachineName = $payload.machine_name }
                                if ($null -ne $payload.live_focus) { $Global:SharedState.LiveFocus = [bool]$payload.live_focus }
                                if ($payload.veyon_disabled) { $Global:SharedState.VeyonStatus = "disabled" }
                            }
                            "LOCK" {
                                if ($payload.message) { $Global:SharedState.LockMessage = $payload.message }
                                $Global:SharedState.LockInput = $true
                                $Global:SharedState.Mode = "lock"
                                [WinGuardSecurity]::BlockInput($true) | Out-Null
                                [WinGuardSecurity]::InstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($true) | Out-Null
                                Send-WsStatus $ws
                            }
                            "UNLOCK" {
                                $Global:SharedState.Mode = "normal"
                                $Global:SharedState.LockInput = $false
                                # Giải phóng màn hình học sinh: Tiêu diệt triệt để tiến trình khóa của Veyon
                                Stop-Process -Name "VeyonWorker", "VeyonMaster", "*veyon*" -Force -ErrorAction SilentlyContinue
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Send-WsStatus $ws
                            }
                            "DISABLE_VEYON" {
                                $Global:SharedState.VeyonStatus = "disabled"
                                Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
                                & sc.exe config VeyonService start= disabled | Out-Null
                                Stop-Process -Name "*veyon*" -Force -ErrorAction SilentlyContinue
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Send-WsStatus $ws
                            }
                            "BROADCAST_START" {
                                $Global:SharedState.LockInput = if ($null -ne $payload.lock_input) { [bool]$payload.lock_input } else { $true }
                                $Global:SharedState.Mode = "broadcast"
                                if ($Global:SharedState.LockInput) {
                                    [WinGuardSecurity]::BlockInput($true) | Out-Null
                                    [WinGuardSecurity]::InstallHook() | Out-Null
                                    [WinGuardSecurity]::SetTaskMgrDisabled($true) | Out-Null
                                }
                                Send-WsStatus $ws
                            }
                            "BROADCAST_FRAME" {
                                if ($payload.image) {
                                    $Global:SharedState.FrameBytes = [Convert]::FromBase64String($payload.image)
                                    $Global:SharedState.FrameTick++
                                    if ($Global:SharedState.Mode -ne "broadcast") {
                                        $Global:SharedState.Mode = "broadcast"
                                    }
                                }
                            }
                            "BROADCAST_STOP" {
                                $Global:SharedState.Mode = "normal"
                                $Global:SharedState.LockInput = $false
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Send-WsStatus $ws
                            }
                            "OPEN_URL" {
                                if ($payload.url) { Start-Process $payload.url }
                            }
                            "SEND_MESSAGE" {
                                if ($payload.message) {
                                    $txt = $payload.message
                                    Start-Job -ScriptBlock {
                                        param($m)
                                        Add-Type -AssemblyName System.Windows.Forms
                                        [System.Windows.Forms.MessageBox]::Show($m, "Thông báo từ Giáo viên", 0, 64)
                                    } -ArgumentList $txt | Out-Null
                                }
                            }
                            "RESTART_VEYON" {
                                & sc.exe config VeyonService start= auto | Out-Null
                                Start-Service -Name "VeyonService" -ErrorAction SilentlyContinue
                                $Global:SharedState.VeyonRestarts++
                                $Global:SharedState.VeyonStatus = "running"
                                Send-WsStatus $ws
                            }
                            "SHUTDOWN" {
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Start-Process "shutdown.exe" -ArgumentList "/s /t 0 /f" -NoNewWindow
                            }
                            "REBOOT" {
                                [WinGuardSecurity]::BlockInput($false) | Out-Null
                                [WinGuardSecurity]::UninstallHook() | Out-Null
                                [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
                                Start-Process "shutdown.exe" -ArgumentList "/r /t 0 /f" -NoNewWindow
                            }
                            "EXEC_CMD" {
                                if ($payload.cmd) {
                                    $out = (Invoke-Expression $payload.cmd 2>&1 | Out-String)
                                    Send-WsJson $ws @{
                                        type       = "CMD_RESULT"
                                        machine_id = $MACHINE_ID
                                        cmd        = $payload.cmd
                                        output     = $out
                                        exit_code  = 0
                                    }
                                }
                            }
                        }
                    } catch {}
                }
                $recvTask = $ws.ReceiveAsync($recvSeg, [System.Threading.CancellationToken]::None)
            }

            $now = [DateTime]::UtcNow
            $intervalSec = if ($Global:SharedState.LiveFocus) { 0.45 } else { 2.0 }
            if (($now - $lastScreenTime).TotalSeconds -ge $intervalSec) {
                $lastScreenTime = $now
                $imgB64 = Capture-ScreenBase64
                if ($imgB64) {
                    Send-WsJson $ws @{
                        type         = "SCREEN"
                        machine_id   = $MACHINE_ID
                        image        = $imgB64
                        mode         = $Global:SharedState.Mode
                        veyon_status = $Global:SharedState.VeyonStatus
                    }
                }
            }

            if (($now - $lastHealTime).TotalSeconds -ge 4.0) {
                $lastHealTime = $now
                Invoke-SelfHeal
            }
        }
    } catch {}
    finally {
        [WinGuardSecurity]::BlockInput($false) | Out-Null
        [WinGuardSecurity]::UninstallHook() | Out-Null
        [WinGuardSecurity]::SetTaskMgrDisabled($false) | Out-Null
        try { $ws.Dispose() } catch {}
        Start-Sleep -Seconds 2
    }
}
