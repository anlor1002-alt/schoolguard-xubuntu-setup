@echo off
setlocal EnableDelayedExpansion
title SchoolGuard Pro - Cai Dat SchoolGuard (Windows)

echo.
echo ================================================================
echo    CAI DAT HE THONG QUAN LY PHONG MAY SCHOOLGUARD PRO (WINDOWS)
echo ================================================================
echo.

:: Xac dinh thu muc cai dat (luon dam bao ghi duoc ke ca khong co Admin)
set "INSTALL_DIR=%LOCALAPPDATA%\SchoolGuard"
if not exist "!INSTALL_DIR!" mkdir "!INSTALL_DIR!" 2>nul

:: Neu co quyen ghi vao ProgramData thi tao them ban sao he thong
if exist "C:\ProgramData" (
    mkdir "C:\ProgramData\SchoolGuard" 2>nul
)

echo [*] Thu muc cai dat: !INSTALL_DIR!

:: Xoa ban cu de tai ban moi nhat
del /f /q "!INSTALL_DIR!\agent_win.ps1" 2>nul

:: Sao chep hoac tai agent_win.ps1
if exist "%~dp0agent_win.ps1" (
    echo [*] Sao chep agent_win.ps1 tu thu muc cuc bo...
    copy /y "%~dp0agent_win.ps1" "!INSTALL_DIR!\agent_win.ps1" >nul
)

if not exist "!INSTALL_DIR!\agent_win.ps1" (
    echo [*] Dang tai agent_win.ps1 tu may chu SchoolGuard...
    where curl.exe >nul 2>&1
    if !errorlevel! equ 0 (
        curl.exe -k -f -sSL "https://103-149-172-179.sslip.io/agent/agent_win.ps1" -o "!INSTALL_DIR!\agent_win.ps1" 2>nul
        if not exist "!INSTALL_DIR!\agent_win.ps1" (
            curl.exe -f -sSL "http://103.149.172.179:4000/agent/agent_win.ps1" -o "!INSTALL_DIR!\agent_win.ps1" 2>nul
        )
        if not exist "!INSTALL_DIR!\agent_win.ps1" (
            curl.exe -k -f -sSL "https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/agent_win.ps1" -o "!INSTALL_DIR!\agent_win.ps1" 2>nul
        )
    )
)

if not exist "!INSTALL_DIR!\agent_win.ps1" (
    powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; $wc = New-Object System.Net.WebClient; try { $wc.DownloadFile('http://103.149.172.179:4000/agent/agent_win.ps1', '!INSTALL_DIR!\agent_win.ps1') } catch { try { $wc.DownloadFile('https://103-149-172-179.sslip.io/agent/agent_win.ps1', '!INSTALL_DIR!\agent_win.ps1') } catch { $wc.DownloadFile('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/agent_win.ps1', '!INSTALL_DIR!\agent_win.ps1') } }"
)

if not exist "!INSTALL_DIR!\agent_win.ps1" (
    echo [ERROR] Khong the tai duoc file agent_win.ps1. Vui long kiem tra ket noi mang.
    pause
    exit /b 1
)

if exist "C:\ProgramData\SchoolGuard" (
    copy /y "!INSTALL_DIR!\agent_win.ps1" "C:\ProgramData\SchoolGuard\agent_win.ps1" >nul 2>&1
)

:: Tao file run_hidden.vbs de chay ngam hoan toan khong hien cua so console
echo [*] Tao trinh kich hoat chay ngam [run_hidden.vbs]...
(
echo Set WshShell = CreateObject^("WScript.Shell"^)
echo WshShell.Run "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File ""!INSTALL_DIR!\agent_win.ps1""", 0, False
) > "!INSTALL_DIR!\run_hidden.vbs"

:: Dang ky tu khoi dong cung Windows (HKCU luon thanh cong khong can Admin, HKLM neu co Admin)
echo [*] Dang ky tu dong khoi dong cung Windows...
reg add "HKCU\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SchoolGuardAgent" /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"!INSTALL_DIR!\agent_win.ps1\"" /f >nul 2>&1
reg add "HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Run" /v "SchoolGuardAgent" /t REG_SZ /d "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"!INSTALL_DIR!\agent_win.ps1\"" /f >nul 2>&1
schtasks /create /f /tn "SchoolGuardAgent" /tr "powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"!INSTALL_DIR!\agent_win.ps1\"" /sc onlogon /rl highest >nul 2>&1

:: Mo tuong lua neu co quyen Admin
netsh advfirewall firewall add rule name="SchoolGuard Pro Agent Outbound" dir=out action=allow program="%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" enable=yes >nul 2>&1

:: Tieu diet tien trinh agent cu neu dang chay
echo [*] Khoi dong SchoolGuard Pro Agent...
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ps = Get-CimInstance Win32_Process; foreach ($p in $ps) { if ($p.ProcessId -ne $PID -and $p.Name -eq 'powershell.exe' -and $p.CommandLine -match 'agent_win\.ps1') { Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue } }" >nul 2>&1

:: Khoi chay agent ngay lap tuc trong nen (dung WMI Win32_Process va wscript de dam bao 100% doc lap)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = 'wscript.exe \"!INSTALL_DIR!\run_hidden.vbs\"' }" >nul 2>&1
start "" wscript.exe "!INSTALL_DIR!\run_hidden.vbs" >nul 2>&1

powershell.exe -NoProfile -Command "Start-Sleep -Seconds 2" >nul 2>&1

echo.
echo ================================================================
echo  [OK] DA CAI DAT THANH CONG SCHOOLGUARD PRO TREN WINDOWS!
echo  [*] May tinh da tu dong ket noi ve Web Quan ly:
echo      https://103-149-172-179.sslip.io
echo  [*] Agent se tu dong chay ngam moi khi may tinh khoi dong.
echo ================================================================
echo.
exit /b 0
