# ============================================================================
# SchoolGuard Windows Agent (Zero-Dependency .NET / PowerShell)
# Runs 100% hidden in background on Windows 7/10/11 (No Python required)
# Connects to VPS: wss://103-149-172-179.sslip.io/ws/agent (fallback ws://:4000)
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"

$createdNew = $false
$Global:SingleInstanceMutex = New-Object System.Threading.Mutex($true, "Local\SchoolGuardWindowsAgentMutex2026", [ref]$createdNew)
if (-not $createdNew) {
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$csharpCode = @"
using System;
using System.Diagnostics;
using System.Net;
using System.Net.Security;
using System.Runtime.InteropServices;
using System.Security.Cryptography.X509Certificates;
using Microsoft.Win32;

public static class WinGuardSecurity {
    public static void EnableTls() {
        try {
            ServicePointManager.ServerCertificateValidationCallback = new RemoteCertificateValidationCallback(
                delegate (object s, X509Certificate c, X509Chain ch, SslPolicyErrors e) { return true; }
            );
            ServicePointManager.SecurityProtocol = SecurityProtocolType.Tls12 | SecurityProtocolType.Tls11 | SecurityProtocolType.Tls;
        } catch {}
    }
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

            if (vk == 0x5B || vk == 0x5C || vk == 0x5D) {
                return (IntPtr)1;
            }
            if (alt && (vk == 0x09 || vk == 0x1B || vk == 0x73)) {
                return (IntPtr)1;
            }
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

$VPS_WS_LIST = @(
    "wss://103-149-172-179.sslip.io/ws/agent",
    "ws://103.149.172.179:4000/ws/agent"
)
$VPS_HTTP = "https://103-149-172-179.sslip.io"
$SECRET = "schoolguard-xubuntu-secret-2026"
$INSTALL_DIR = Join-Path $env:LOCALAPPDATA "SchoolGuard"

function Get-LocalIp {
    try {
        $ip = (Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.InterfaceAlias -notmatch "Loopback" -and $_.IPAddress -notlike "169.*" } | Select-Object -First 1).IPAddress
        if ($ip) { return $ip }
    } catch {}
    try {
        $ip2 = ([System.Net.Dns]::GetHostAddresses($env:COMPUTERNAME) | Where-Object { $_.AddressFamily -eq "InterNetwork" } | Select-Object -First 1).IPAddressToString
        if ($ip2) { return $ip2 }
    } catch {}
    return "127.0.0.1"
}

function Get-MacAddr {
    try {
        $mac = (Get-NetAdapter | Where-Object { $_.Status -eq "Up" } | Select-Object -First 1).MacAddress
        if ($mac) { return $mac.Replace("-", ":").ToLower() }
    } catch {}
    try {
        $wmiMac = (Get-CimInstance Win32_NetworkAdapterConfiguration | Where-Object { $_.IPEnabled -eq $true } | Select-Object -First 1).MACAddress
        if ($wmiMac) { return $wmiMac.ToLower() }
    } catch {}
    return "00:00:00:00:00:00"
}

function Get-MachineId {
    $hostClean = ($env:COMPUTERNAME.ToLower() -replace '[^a-z0-9_-]', '')
    if (-not $hostClean) { $hostClean = "winpc" }
    $macClean = ((Get-MacAddr) -replace '[^a-f0-9]', '')
    if ($macClean -and $macClean -ne "000000000000") {
        return "$hostClean-$macClean"
    }
    $ipClean = ((Get-LocalIp) -replace '[^0-9]', '-')
    return "$hostClean-$ipClean"
}

$MACHINE_ID = Get-MachineId
$HOSTNAME = $env:COMPUTERNAME
$DESKTOP_USER = $env:USERNAME
$SELF_SCRIPT_PATH = $MyInvocation.MyCommand.Path
$SELF_CODE = if ($SELF_SCRIPT_PATH -and (Test-Path $SELF_SCRIPT_PATH)) { [System.IO.File]::ReadAllText($SELF_SCRIPT_PATH) } else { "" }

$Global:SharedState = [hashtable]::Synchronized(@{
    Mode          = "normal"
    MachineName   = $HOSTNAME
    LockMessage   = "Vui long trat tu va chu y theo doi huong dan cua Giao vien."
    LockInput     = $true
    LiveFocus     = $false
    FrameBytes    = $null
    FrameTick     = 0
    VeyonStatus   = "disabled"
    VeyonRestarts = 0
})

# ============================================================================
# Fullscreen Lock & Broadcast UI Thread (STA Runspace)
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
    $form.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)
    $form.KeyPreview = $true

    $vScreen = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $form.Bounds = $vScreen

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

    $lockPanel = New-Object System.Windows.Forms.Panel
    $lockPanel.Dock = [System.Windows.Forms.DockStyle]::Fill
    $lockPanel.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)

    $pri = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $cardW = [Math]::Min(900, $pri.Width - 60)
    $cardH = 520
    $centerX = $pri.Left + [int](($pri.Width - $cardW) / 2) - $vScreen.Left
    $centerY = $pri.Top + [int](($pri.Height - $cardH) / 2) - $vScreen.Top

    $centerCard = New-Object System.Windows.Forms.Panel
    $centerCard.Size = New-Object System.Drawing.Size($cardW, $cardH)
    $centerCard.Location = New-Object System.Drawing.Point($centerX, $centerY)
    $centerCard.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)
    $lockPanel.Controls.Add($centerCard)

    $lblClock = New-Object System.Windows.Forms.Label
    $lblClock.Text = "--:--:--"
    $lblClock.Font = New-Object System.Drawing.Font("Consolas", 38, [System.Drawing.FontStyle]::Bold)
    $lblClock.ForeColor = [System.Drawing.Color]::FromArgb(237, 237, 239)
    $lblClock.AutoSize = $false
    $lblClock.Width = $cardW
    $lblClock.Height = 56
    $lblClock.Left = 0
    $lblClock.Top = 10
    $lblClock.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblClock)

    $lblDate = New-Object System.Windows.Forms.Label
    $lblDate.Text = "--/--/----"
    $lblDate.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Regular)
    $lblDate.ForeColor = [System.Drawing.Color]::FromArgb(110, 119, 133)
    $lblDate.AutoSize = $false
    $lblDate.Width = $cardW
    $lblDate.Height = 24
    $lblDate.Left = 0
    $lblDate.Top = 68
    $lblDate.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblDate)

    $lblBadge = New-Object System.Windows.Forms.Label
    $lblBadge.Text = "MAY HOC SINH - PHONG TIN HOC"
    $lblBadge.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
    $lblBadge.BackColor = [System.Drawing.Color]::FromArgb(18, 21, 28)
    $lblBadge.ForeColor = [System.Drawing.Color]::FromArgb(155, 163, 176)
    $lblBadge.AutoSize = $false
    $lblBadge.Width = 420
    $lblBadge.Height = 34
    $lblBadge.Left = [int](($cardW - $lblBadge.Width) / 2)
    $lblBadge.Top = 106
    $lblBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblBadge)

    $lblTitle = New-Object System.Windows.Forms.Label
    $lblTitle.Text = "Man hinh dang tam khoa"
    $lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
    $lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(237, 237, 239)
    $lblTitle.AutoSize = $false
    $lblTitle.Width = $cardW
    $lblTitle.Height = 48
    $lblTitle.Left = 0
    $lblTitle.Top = 152
    $lblTitle.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblTitle)

    $msgCard = New-Object System.Windows.Forms.Panel
    $msgCard.Width = [Math]::Min(780, $cardW - 40)
    $msgCard.Height = 150
    $msgCard.Left = [int](($cardW - $msgCard.Width) / 2)
    $msgCard.Top = 216
    $msgCard.BackColor = [System.Drawing.Color]::FromArgb(17, 20, 27)

    $accentLine = New-Object System.Windows.Forms.Panel
    $accentLine.Dock = [System.Windows.Forms.DockStyle]::Left
    $accentLine.Width = 3
    $accentLine.BackColor = [System.Drawing.Color]::FromArgb(47, 111, 235)
    $msgCard.Controls.Add($accentLine)

    $lblMsgHead = New-Object System.Windows.Forms.Label
    $lblMsgHead.Text = "Thong bao tu giao vien"
    $lblMsgHead.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $lblMsgHead.ForeColor = [System.Drawing.Color]::FromArgb(138, 145, 158)
    $lblMsgHead.AutoSize = $false
    $lblMsgHead.Width = $msgCard.Width - 40
    $lblMsgHead.Height = 24
    $lblMsgHead.Left = 24
    $lblMsgHead.Top = 16
    $lblMsgHead.TextAlign = [System.Drawing.ContentAlignment]::MiddleLeft
    $msgCard.Controls.Add($lblMsgHead)

    $lblMsg = New-Object System.Windows.Forms.Label
    $lblMsg.Text = $SharedState.LockMessage
    $lblMsg.Font = New-Object System.Drawing.Font("Segoe UI", 14, [System.Drawing.FontStyle]::Regular)
    $lblMsg.ForeColor = [System.Drawing.Color]::FromArgb(237, 237, 239)
    $lblMsg.AutoSize = $false
    $lblMsg.Width = $msgCard.Width - 48
    $lblMsg.Height = 90
    $lblMsg.Left = 24
    $lblMsg.Top = 46
    $lblMsg.TextAlign = [System.Drawing.ContentAlignment]::TopLeft
    $msgCard.Controls.Add($lblMsg)
    $centerCard.Controls.Add($msgCard)

    $lblFooter = New-Object System.Windows.Forms.Label
    $lblFooter.Text = "SchoolGuard - Chuot va ban phim dang duoc quan ly boi giao vien"
    $lblFooter.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Regular)
    $lblFooter.BackColor = [System.Drawing.Color]::FromArgb(9, 11, 14)
    $lblFooter.ForeColor = [System.Drawing.Color]::FromArgb(86, 94, 107)
    $lblFooter.AutoSize = $false
    $lblFooter.Width = $cardW
    $lblFooter.Height = 32
    $lblFooter.Left = 0
    $lblFooter.Top = 390
    $lblFooter.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $centerCard.Controls.Add($lblFooter)

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

            if ($SharedState.LockInput) {
                $priCenter = New-Object System.Drawing.Point([int]($pri.Left + $pri.Width / 2), [int]($pri.Top + $pri.Height / 2))
                [System.Windows.Forms.Cursor]::Clip = New-Object System.Drawing.Rectangle($priCenter.X, $priCenter.Y, 1, 1)
                [System.Windows.Forms.Cursor]::Hide()
            }

            if ($mode -eq "lock") {
                $picBox.Visible = $false
                $lockPanel.Visible = $true
                $lblBadge.Text = $SharedState.MachineName + " - PHONG TIN HOC"
                $lblMsg.Text = $SharedState.LockMessage
                $now = Get-Date
                $lblClock.Text = $now.ToString("HH:mm:ss")
                $lblDate.Text = $now.ToString("dd/MM/yyyy")
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

function Invoke-SelfHeal {
    try {
        if (-not (Test-Path $INSTALL_DIR)) {
            New-Item -ItemType Directory -Path $INSTALL_DIR -Force | Out-Null
        }
        $targetAgent = Join-Path $INSTALL_DIR "agent_win.ps1"
        if ($SELF_CODE -and -not (Test-Path $targetAgent)) {
            [System.IO.File]::WriteAllText($targetAgent, $SELF_CODE, [System.Text.Encoding]::ASCII)
        }
        $vbsPath = Join-Path $INSTALL_DIR "run_hidden.vbs"
        if (-not (Test-Path $vbsPath)) {
            $vbsContent = "Set ws = CreateObject(""Wscript.Shell"")`r`nws.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$targetAgent"""""", 0, False"
            [System.IO.File]::WriteAllText($vbsPath, $vbsContent, [System.Text.Encoding]::ASCII)
        }
        $regPath = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
        Set-ItemProperty -Path $regPath -Name "SchoolGuardAgent" -Value "wscript.exe `"$vbsPath`"" -Force

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
# Real-time WebSocket Loop (Supports TLS 1.2 + Fallback WS :4000)
# ============================================================================
[WinGuardSecurity]::EnableTls()

$wsIndex = 0
while ($true) {
    $currentWsUrl = $VPS_WS_LIST[$wsIndex % $VPS_WS_LIST.Count]
    $wsIndex++

    $ws = New-Object System.Net.WebSockets.ClientWebSocket
    $ws.Options.SetRequestHeader("X-SchoolGuard-Secret", $SECRET)
    $ws.Options.SetRequestHeader("X-Machine-Id", $MACHINE_ID)

    try {
        $uri = [Uri]$currentWsUrl
        $ws.ConnectAsync($uri, [System.Threading.CancellationToken]::None).GetAwaiter().GetResult()

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
                                        [System.Windows.Forms.MessageBox]::Show($m, "Thong bao tu Giao vien", 0, 64)
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
                            "WAKE_ON_LAN" {
                                try {
                                    $udp = New-Object System.Net.Sockets.UdpClient
                                    $udp.EnableBroadcast = $true
                                    foreach ($m in $payload.macs) {
                                        $hex = ($m -replace '[^0-9a-fA-F]','')
                                        if ($hex.Length -eq 12) {
                                            $macBytes = New-Object byte[] 6
                                            for ($i=0; $i -lt 6; $i++) { $macBytes[$i] = [Convert]::ToByte($hex.Substring($i*2,2), 16) }
                                            $packet = New-Object byte[] 102
                                            for ($i=0; $i -lt 6; $i++) { $packet[$i] = 0xFF }
                                            for ($i=1; $i -le 16; $i++) { [Array]::Copy($macBytes, 0, $packet, $i*6, 6) }
                                            foreach ($ip in @("255.255.255.255","192.168.1.255","192.168.0.255")) {
                                                $udp.Send($packet, $packet.Length, $ip, 9) | Out-Null
                                                $udp.Send($packet, $packet.Length, $ip, 7) | Out-Null
                                            }
                                        }
                                    }
                                    $udp.Close()
                                } catch {}
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
                $b64 = Capture-ScreenBase64
                if ($b64) {
                    Send-WsJson $ws @{
                        type         = "SCREEN"
                        machine_id   = $MACHINE_ID
                        image        = $b64
                        mode         = $Global:SharedState.Mode
                        veyon_status = $Global:SharedState.VeyonStatus
                    }
                }
            }

            if (($now - $lastHealTime).TotalSeconds -ge 4.0) {
                $lastHealTime = $now
                Invoke-SelfHeal
                Send-WsStatus $ws
            }
        }
    } catch {}
    finally {
        try { $ws.Dispose() } catch {}
    }

    Invoke-SelfHeal
    Start-Sleep -Seconds 2
}
