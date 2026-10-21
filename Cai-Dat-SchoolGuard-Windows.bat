@echo off
setlocal EnableDelayedExpansion
chcp 65001 >nul
title SchoolGuard Pro - Buoc 2: Cai Dat SchoolGuard (Windows)

:: Kiem tra quyen Administrator va thu nang quyen qua UAC
net session >nul 2>&1
if %errorlevel% neq 0 (
    echo [*] Chu y: Chay voi quyen Administrator giup dang ky dich vu he thong ben vung.
    echo [*] Dang yeu cau quyen Administrator qua UAC...
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Start-Process cmd.exe -ArgumentList '/c \"\"%~f0\"\"' -Verb RunAs" 2>nul
    if !errorlevel! equ 0 (
        exit /b
    )
    echo [*] Khong the tu dong nang quyen Administrator hoac UAC bi tu choi.
    echo [*] Tiep tuc cai dat o cap do User [Local AppData]...
)

echo.
echo ================================================================
echo    BƯỚC 2: CÀI ĐẶT HỆ THỐNG QUẢN LÝ PHÒNG MÁY SCHOOLGUARD PRO
echo ================================================================
echo.

:: Xac dinh thu muc cai dat
set "INSTALL_DIR=C:\ProgramData\SchoolGuard"
if not exist "%INSTALL_DIR%" mkdir "%INSTALL_DIR%" 2>nul
if not exist "%INSTALL_DIR%" (
    set "INSTALL_DIR=%LOCALAPPDATA%\SchoolGuard"
    if not exist "!INSTALL_DIR!" mkdir "!INSTALL_DIR!" 2>nul
)

echo [*] Thư mục cài đặt: !INSTALL_DIR!

:: Sao chép hoặc tải agent_win.ps1
if exist "%~dp0agent_win.ps1" (
    echo [*] Sao chép agent_win.ps1 từ thư mục cài đặt cục bộ...
    copy /y "%~dp0agent_win.ps1" "!INSTALL_DIR!\agent_win.ps1" >nul
) else (
    echo [*] Đang tải agent_win.ps1 từ máy chủ SchoolGuard HTTPS...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}; try { (New-Object System.Net.WebClient).DownloadFile('https://103-149-172-179.sslip.io/agent/agent_win.ps1', '!INSTALL_DIR!\agent_win.ps1') } catch { try { (New-Object System.Net.WebClient).DownloadFile('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/agent_win.ps1', '!INSTALL_DIR!\agent_win.ps1') } catch { (New-Object System.Net.WebClient).DownloadFile('http://103.149.172.179:4000/agent/agent_win.ps1', '!INSTALL_DIR!\agent_win.ps1') } }"
)

if not exist "!INSTALL_DIR!\agent_win.ps1" (
    echo [ERROR] Không thể tải được file agent_win.ps1. Vui lòng kiểm tra lại kết nối mạng.
    pause
    exit /b 1
)

:: Tạo file run_hidden.vbs để chạy ngầm hoàn toàn không hiện cửa sổ console
echo [*] Tạo trình kích hoạt chạy ngầm [run_hidden.vbs]...
(
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""!INSTALL_DIR!\agent_win.ps1""", 0, False
) > "!INSTALL_DIR!\run_hidden.vbs"

:: Đăng ký tự khởi động cùng Windows (Run key & Scheduled Task)
echo [*] Đăng ký tự động khởi động cùng hệ thống...
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SchoolGuardAgent" /t REG_SZ /d "wscript.exe \"!INSTALL_DIR!\run_hidden.vbs\"" /f >nul 2>&1
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SchoolGuardAgent" /t REG_SZ /d "wscript.exe \"!INSTALL_DIR!\run_hidden.vbs\"" /f >nul 2>&1

:: Đăng ký Scheduled Task chạy lúc đăng nhập với quyền cao nhất
schtasks /create /f /tn "SchoolGuardAgent" /tr "wscript.exe \"!INSTALL_DIR!\run_hidden.vbs\"" /sc onlogon /rl highest >nul 2>&1

:: Mở tường lửa cho kết nối WebSocket ra ngoài
echo [*] Cấu hình quy tắc Tường lửa Windows [Firewall]...
netsh advfirewall firewall add rule name="SchoolGuard Pro Agent Outbound" dir=out action=allow program="%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" enable=yes >nul 2>&1

:: Tiêu diệt tiến trình agent cũ nếu đang chạy
echo [*] Khởi động lại SchoolGuard Pro Agent...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps = Get-CimInstance Win32_Process; foreach ($p in $ps) { if ($p.Name -eq 'powershell.exe' -and $p.CommandLine -match 'agent_win\.ps1') { Stop-Process -Id $p.ProcessId -Force } }" >nul 2>&1

:: Khởi chạy agent ngay lập tức trong nền
start "" wscript.exe "!INSTALL_DIR!\run_hidden.vbs"

powershell -NoProfile -Command "Start-Sleep -Seconds 2" >nul 2>&1

echo.
echo ================================================================
echo  ✅ ĐÃ CÀI ĐẶT THÀNH CÔNG SCHOOLGUARD PRO TRÊN MÁY HỌC SINH
echo  📡 Máy tính đã tự động kết nối về Web Quản lý:
echo     👉 https://103-149-172-179.sslip.io
echo  🛡️ Agent sẽ tự động chạy ngầm mỗi khi máy tính khởi động.
echo ================================================================
echo.
pause
exit /b 0
