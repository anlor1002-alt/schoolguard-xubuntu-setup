@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
title SchoolGuard Pro - Buoc 1: Xoa Sach Veyon (Windows)

:: Kiem tra quyen Administrator va thu nang quyen neu chua co
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [*] Chu y: Script can quyen Administrator de xoa sach dich vu Veyon.
    echo [*] Dang yeu cau quyen Administrator qua UAC...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs" 2>nul
    if !errorlevel! equ 0 (
        exit /b
    )
    echo [*] Khong the tu dong nang quyen Administrator hoac UAC bi tu choi.
    echo [*] Tiep tuc don dep tien trinh va go bo o cap do User...
)

echo.
echo ================================================================
echo    BƯỚC 1: TIÊU DIỆT ^& XÓA SẠCH VEYON KHỎI MÁY HỌC SINH WINDOWS
echo ================================================================
echo.

echo [*] Dừng và vô hiệu hóa dịch vụ VeyonService...
sc.exe stop VeyonService >nul 2>&1
sc.exe config VeyonService start= disabled >nul 2>&1
sc.exe delete VeyonService >nul 2>&1

echo [*] Tiêu diệt mọi tiến trình Veyon để giải phóng chuột và bàn phím...
taskkill /F /IM VeyonWorker.exe /T >nul 2>&1
taskkill /F /IM VeyonMaster.exe /T >nul 2>&1
taskkill /F /IM VeyonService.exe /T >nul 2>&1
taskkill /F /IM veyon-service.exe /T >nul 2>&1
taskkill /F /IM veyon-worker.exe /T >nul 2>&1
taskkill /F /IM veyon-configurator.exe /T >nul 2>&1
taskkill /F /IM veyon-server.exe /T >nul 2>&1

:: Chạy PowerShell Engine để gỡ cài đặt chuyên sâu và giải phóng BlockInput
if exist "%~dp0remove_veyon_win.ps1" (
    echo [*] Thực thi bộ công cụ gỡ Veyon chuyên sâu: remove_veyon_win.ps1...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remove_veyon_win.ps1"
) else (
    echo [*] Đang tải bộ gỡ Veyon chuyên sâu từ VPS...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$dst = Join-Path ([System.IO.Path]::GetTempPath()) 'remove_veyon_win.ps1'; [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}; try { (New-Object System.Net.WebClient).DownloadFile('https://103-149-172-179.sslip.io/remove_veyon_win.ps1', $dst) } catch { try { (New-Object System.Net.WebClient).DownloadFile('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove_veyon_win.ps1', $dst) } catch { (New-Object System.Net.WebClient).DownloadFile('http://103.149.172.179:4000/remove_veyon_win.ps1', $dst) } }; if (Test-Path $dst) { & $dst }"
)

:: Dọn dẹp thư mục và shortcut còn sót
if exist "%ProgramFiles%\Veyon" rmdir /s /q "%ProgramFiles%\Veyon" >nul 2>&1
if exist "%ProgramFiles(x86)%\Veyon" rmdir /s /q "%ProgramFiles(x86)%\Veyon" >nul 2>&1
if exist "C:\ProgramData\Veyon" rmdir /s /q "C:\ProgramData\Veyon" >nul 2>&1
del /f /q "%PUBLIC%\Desktop\*veyon*.lnk" >nul 2>&1
del /f /q "%USERPROFILE%\Desktop\*veyon*.lnk" >nul 2>&1
del /f /q "C:\Users\*\Desktop\*veyon*.lnk" >nul 2>&1

:: Dọn dẹp khóa Registry
reg delete "HKLM\SOFTWARE\Veyon Solutions" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\WOW6432Node\Veyon Solutions" /f >nul 2>&1
reg delete "HKCU\Software\Veyon Solutions" /f >nul 2>&1
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\VeyonService" /f >nul 2>&1

echo.
echo ================================================================
echo  ✅ ĐÃ XÓA SẠCH VÀ VÔ HIỆU HÓA HOÀN TOÀN VEYON TRÊN WINDOWS
echo  👉 BƯỚC 2: Hãy chạy file "Cai-Dat-SchoolGuard-Windows.bat"
echo     để cài đặt hệ thống quản lý phòng máy SchoolGuard Pro
echo ================================================================
echo.
pause
exit /b 0
