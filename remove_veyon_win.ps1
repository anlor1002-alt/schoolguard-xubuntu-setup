# ============================================================================
# SchoolGuard Pro - Veyon Clean Removal Engine for Windows (Pure ASCII)
# Buoc 1: Dung, khoa va go bo hoan toan Veyon khoi may hoc sinh Windows
# ============================================================================

[CmdletBinding()]
param()

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    BUOC 1: TIEU DIET & XOA SACH VEYON KHOI MAY HOC SINH        " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

try {
    $rescueCode = @"
using System;
using System.Runtime.InteropServices;
public class WinGuardRescue {
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    public static extern bool BlockInput([MarshalAs(UnmanagedType.Bool)] bool fBlockIt);
}
"@
    Add-Type -TypeDefinition $rescueCode -ErrorAction SilentlyContinue
    [WinGuardRescue]::BlockInput($false) | Out-Null
    Write-Host "[*] Da kich hoat lenh giai phong chuot va ban phim (BlockInput false)." -ForegroundColor Green
} catch {}

$policyPaths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
)
foreach ($p in $policyPaths) {
    if (Test-Path $p) {
        Remove-ItemProperty -Path $p -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
    }
}

Write-Host "[*] Tieu diet toan bo tien trinh Veyon dang chay..." -ForegroundColor Cyan
$veyonProcesses = @("VeyonWorker", "VeyonMaster", "VeyonService", "veyon-service", "veyon-worker", "veyon-master", "veyon-configurator", "veyon-server")

foreach ($procName in $veyonProcesses) {
    try {
        $found = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($found) {
            $found | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host "    -> Da tieu diet tien trinh: $procName" -ForegroundColor Yellow
        }
    } catch {}
    & taskkill.exe /F /IM "$procName.exe" /T 2>$null | Out-Null
}

Write-Host "[*] Dung va go bo Windows Service (VeyonService)..." -ForegroundColor Cyan
try {
    $svc = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
    if ($svc -and $svc.Status -eq "Running") {
        Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
    }
} catch {}

& sc.exe stop VeyonService 2>$null | Out-Null
& sc.exe config VeyonService start= disabled 2>$null | Out-Null
& sc.exe delete VeyonService 2>$null | Out-Null

Write-Host "[*] Tim kiem va thuc thi trinh go cai dat chinh thuc cua Veyon..." -ForegroundColor Cyan

$uninstallerCandidates = @(
    "$env:ProgramFiles\Veyon\uninstall.exe",
    "${env:ProgramFiles(x86)}\Veyon\uninstall.exe",
    "C:\Program Files\Veyon\uninstall.exe",
    "C:\Program Files (x86)\Veyon\uninstall.exe"
)

$uninstallKeys = @(
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
    "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
)
foreach ($k in $uninstallKeys) {
    Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -like "*Veyon*" } | ForEach-Object {
        if ($_.UninstallString) {
            $cleanPath = $_.UninstallString -replace '"',''
            if (Test-Path $cleanPath) {
                $uninstallerCandidates += $cleanPath
            }
        }
    }
}

foreach ($uPath in ($uninstallerCandidates | Select-Object -Unique)) {
    if (Test-Path $uPath) {
        Write-Host "    -> Phat hien trinh go cai dat: $uPath. Dang chay che do im lang (/S)..." -ForegroundColor Green
        try {
            Start-Process -FilePath $uPath -ArgumentList "/S" -Wait -PassThru -WindowStyle Hidden | Out-Null
            Start-Sleep -Seconds 2
            Write-Host "    -> Go cai dat hoan tat!" -ForegroundColor Green
            break
        } catch {}
    }
}

foreach ($procName in $veyonProcesses) {
    & taskkill.exe /F /IM "$procName.exe" /T 2>$null | Out-Null
}

Write-Host "[*] Xoa sach toan bo thu muc du lieu, cau hinh va file thuc thi Veyon..." -ForegroundColor Cyan
$foldersToRemove = @(
    "$env:ProgramFiles\Veyon",
    "${env:ProgramFiles(x86)}\Veyon",
    "C:\Program Files\Veyon",
    "C:\Program Files (x86)\Veyon",
    "C:\ProgramData\Veyon",
    "$env:APPDATA\Veyon",
    "$env:LOCALAPPDATA\Veyon",
    "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\Veyon",
    "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Veyon"
)

foreach ($f in ($foldersToRemove | Select-Object -Unique)) {
    if (Test-Path $f) {
        try {
            Remove-Item -Path $f -Recurse -Force -ErrorAction SilentlyContinue
            Write-Host "    -> Da xoa thu muc: $f" -ForegroundColor Green
        } catch {}
    }
}

$desktopShortcuts = @(
    "$env:USERPROFILE\Desktop\*veyon*.lnk",
    "$env:PUBLIC\Desktop\*veyon*.lnk",
    "C:\Users\*\Desktop\*veyon*.lnk"
)
foreach ($pattern in $desktopShortcuts) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

$registryKeys = @(
    "HKLM:\SOFTWARE\Veyon Solutions",
    "HKLM:\SOFTWARE\WOW6432Node\Veyon Solutions",
    "HKCU:\Software\Veyon Solutions",
    "HKLM:\SYSTEM\CurrentControlSet\Services\VeyonService"
)

foreach ($r in $registryKeys) {
    if (Test-Path $r) {
        try {
            Remove-Item -Path $r -Recurse -Force -ErrorAction SilentlyContinue
        } catch {}
    }
}

try {
    [WinGuardRescue]::BlockInput($false) | Out-Null
} catch {}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " [OK] DA XOA SACH VA VO HIEU HOA HOAN TOAN VEYON (WINDOWS)!" -ForegroundColor Green
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
