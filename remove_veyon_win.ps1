# ============================================================================
# SchoolGuard Pro — Headless Veyon Eradicator & Input Rescue (Windows)
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"

function Show-TuiProgress {
    param([int]$Percent, [string]$Status)
    $width = 28
    $filled = [math]::Floor(($Percent * $width) / 100)
    $empty = $width - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    $pad = $Status.PadRight(44).Substring(0, 44)
    Write-Host -NoNewline "`r  [$bar] $($Percent.ToString().PadLeft(3))%  $pad" -ForegroundColor Cyan
}

Show-TuiProgress -Percent 15 -Status "Unlocking input & Task Manager..."

try {
    Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public class VeyonInputUnlock {
    [DllImport("user32.dll")]
    public static extern bool BlockInput(bool fBlockIt);
}
"@ -ErrorAction SilentlyContinue
    [VeyonInputUnlock]::BlockInput($false) | Out-Null
} catch {}

Remove-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Force -ErrorAction SilentlyContinue
Remove-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System" -Name "DisableTaskMgr" -Force -ErrorAction SilentlyContinue

Show-TuiProgress -Percent 45 -Status "Stopping Veyon services & processes..."

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

Show-TuiProgress -Percent 75 -Status "Removing Veyon files & registry entries..."

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

Show-TuiProgress -Percent 90 -Status "Activating background Veyon blocker..."

$GuardDir = Join-Path $env:LOCALAPPDATA "SchoolGuard"
if (-not (Test-Path $GuardDir)) {
    New-Item -ItemType Directory -Path $GuardDir -Force | Out-Null
}
$BlockerScript = Join-Path $GuardDir "veyon_blocker.ps1"
@"
`$ErrorActionPreference = 'SilentlyContinue'
while (`$true) {
    Get-Process -Name 'veyon*' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
"@ | Set-Content -Path $BlockerScript -Encoding UTF8 -Force

$VbsBlocker = Join-Path $GuardDir "run_blocker.vbs"
@"
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$BlockerScript""", 0, False
"@ | Set-Content -Path $VbsBlocker -Encoding ASCII -Force

Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SchoolGuardVeyonBlocker" -Value "wscript.exe //B //NoLogo `"$VbsBlocker`"" -Force -ErrorAction SilentlyContinue
Start-Process -FilePath "wscript.exe" -ArgumentList "//B //NoLogo `"$VbsBlocker`"" -WindowStyle Hidden -ErrorAction SilentlyContinue

Show-TuiProgress -Percent 100 -Status "Complete"
Write-Host ""
Write-Host "  [OK] Veyon eradicated & blocked (headless mode)." -ForegroundColor Green
