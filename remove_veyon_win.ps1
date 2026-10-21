# ============================================================================
# SchoolGuard Pro - Veyon Clean Removal Engine for Windows
# Bước 1: Dừng, khóa và gỡ bỏ hoàn toàn Veyon khỏi máy học sinh Windows
# ============================================================================

[CmdletBinding()]
param()

try { $Host.UI.RawUI.WindowTitle = "SchoolGuard Pro - Bước 1: Xóa Sạch Veyon (Windows)" } catch {}
Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "    BƯỚC 1: TIÊU DIỆT & XÓA SẠCH VEYON KHỎI MÁY HỌC SINH        " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""

# 1. Khởi tạo Win32 API giải phóng chuột/bàn phím nếu đang bị Veyon khóa
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
    Write-Host "[*] Đã kích hoạt lệnh giải phóng chuột và bàn phím (BlockInput false)." -ForegroundColor Green
} catch {
    Write-Host "[!] Không thể nạp WinGuardRescue API, tiếp tục dọn dẹp tiến trình..." -ForegroundColor DarkYellow
}

# 2. Khôi phục lại Task Manager nếu bị Veyon khóa
$policyPaths = @(
    "HKCU:\Software\Microsoft\Windows\CurrentVersion\Policies\System",
    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Policies\System"
)
foreach ($p in $policyPaths) {
    if (Test-Path $p) {
        Remove-ItemProperty -Path $p -Name "DisableTaskMgr" -ErrorAction SilentlyContinue
    }
}

# 3. Tiêu diệt triệt để mọi tiến trình Veyon đang chạy
Write-Host "[*] Tiêu diệt toàn bộ tiến trình Veyon đang chạy..." -ForegroundColor Cyan
$veyonProcesses = @("VeyonWorker", "VeyonMaster", "VeyonService", "veyon-service", "veyon-worker", "veyon-master", "veyon-configurator", "veyon-server")

foreach ($procName in $veyonProcesses) {
    try {
        $found = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if ($found) {
            $found | Stop-Process -Force -ErrorAction SilentlyContinue
            Write-Host "    -> Đã tiêu diệt tiến trình: $procName" -ForegroundColor Yellow
        }
    } catch {}
    & taskkill.exe /F /IM "$procName.exe" /T 2>$null | Out-Null
}

# 4. Dừng, vô hiệu hóa và xóa Windows Service VeyonService
Write-Host "[*] Dừng và gỡ bỏ Windows Service (VeyonService)..." -ForegroundColor Cyan
try {
    $svc = Get-Service -Name "VeyonService" -ErrorAction SilentlyContinue
    if ($svc) {
        if ($svc.Status -eq "Running") {
            Stop-Service -Name "VeyonService" -Force -ErrorAction SilentlyContinue
        }
    }
} catch {}

& sc.exe stop VeyonService 2>$null | Out-Null
& sc.exe config VeyonService start= disabled 2>$null | Out-Null
& sc.exe delete VeyonService 2>$null | Out-Null

# 5. Tìm kiếm và chạy trình gỡ cài đặt chính thức của Veyon (Silent Uninstall)
Write-Host "[*] Tìm kiếm và thực thi trình gỡ cài đặt chính thức của Veyon..." -ForegroundColor Cyan

$uninstallerCandidates = @(
    "$env:ProgramFiles\Veyon\uninstall.exe",
    "${env:ProgramFiles(x86)}\Veyon\uninstall.exe",
    "C:\Program Files\Veyon\uninstall.exe",
    "C:\Program Files (x86)\Veyon\uninstall.exe"
)

# Quét thêm từ Registry Uninstall
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

$uninstalledOfficial = $false
foreach ($uPath in ($uninstallerCandidates | Select-Object -Unique)) {
    if (Test-Path $uPath) {
        Write-Host "    -> Phát hiện trình gỡ cài đặt: $uPath. Đang chạy chế độ im lặng (/S)..." -ForegroundColor Green
        try {
            $p = Start-Process -FilePath $uPath -ArgumentList "/S" -Wait -PassThru -WindowStyle Hidden
            Start-Sleep -Seconds 3
            $uninstalledOfficial = $true
            Write-Host "    -> Gỡ cài đặt hoàn tất!" -ForegroundColor Green
            break
        } catch {
            Write-Host "    [!] Lỗi khi chạy $uPath : $_" -ForegroundColor DarkYellow
        }
    }
}

if (-not $uninstalledOfficial) {
    Write-Host "    -> Không tìm thấy trình gỡ cài đặt tự động, tiến hành xóa file thủ công triệt để." -ForegroundColor Yellow
}

# 6. Tiêu diệt lại một lần nữa các tiến trình phát sinh trong quá trình gỡ
foreach ($procName in $veyonProcesses) {
    & taskkill.exe /F /IM "$procName.exe" /T 2>$null | Out-Null
}

# 7. Xóa sạch thư mục Veyon trên ổ đĩa
Write-Host "[*] Xóa sạch toàn bộ thư mục dữ liệu, cấu hình và file thực thi Veyon..." -ForegroundColor Cyan
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
            Write-Host "    -> Đã xóa thư mục: $f" -ForegroundColor Green
        } catch {
            Write-Host "    [!] Không thể xóa thư mục $f : $_" -ForegroundColor DarkYellow
        }
    }
}

# 8. Xóa shortcut Veyon ngoài Desktop của tất cả người dùng
$desktopShortcuts = @(
    "$env:USERPROFILE\Desktop\*veyon*.lnk",
    "$env:PUBLIC\Desktop\*veyon*.lnk",
    "C:\Users\*\Desktop\*veyon*.lnk"
)
foreach ($pattern in $desktopShortcuts) {
    Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            Remove-Item -Path $_.FullName -Force -ErrorAction SilentlyContinue
            Write-Host "    -> Đã xóa shortcut: $($_.FullName)" -ForegroundColor Green
        } catch {}
    }
}

# 9. Xóa sạch Registry của Veyon
Write-Host "[*] Dọn dẹp khóa Registry Veyon..." -ForegroundColor Cyan
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
            Write-Host "    -> Đã xóa khóa Registry: $r" -ForegroundColor Green
        } catch {}
    }
}

# 10. Mở lại input một lần nữa để chắc chắn
try {
    [WinGuardRescue]::BlockInput($false) | Out-Null
} catch {}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host " ✅ ĐÃ XÓA SẠCH VÀ VÔ HIỆU HÓA HOÀN TOÀN VEYON (WINDOWS)!" -ForegroundColor Green
Write-Host " 👉 BƯỚC TIẾP THEO: Hãy chạy file 'Cai-Dat-SchoolGuard-Windows.bat'" -ForegroundColor Yellow
Write-Host "    để cài đặt hệ thống quản lý phòng máy SchoolGuard Pro." -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host ""
