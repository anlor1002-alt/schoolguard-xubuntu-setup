@echo off
setlocal EnableDelayedExpansion
title SchoolGuard Pro - Buoc 1: Xoa Sach Veyon (Windows)

echo.
echo ================================================================
echo    BUOC 1: TIEU DIET VA XOA SACH VEYON KHOI MAY HOC SINH WINDOWS
echo ================================================================
echo.

echo [*] Dung va vo hieu hoa dich vu VeyonService...
sc.exe stop VeyonService >nul 2>&1
sc.exe config VeyonService start= disabled >nul 2>&1
sc.exe delete VeyonService >nul 2>&1

echo [*] Tieu diet moi tien trinh Veyon de giai phong chuot va ban phim...
taskkill /F /IM VeyonWorker.exe /T >nul 2>&1
taskkill /F /IM VeyonMaster.exe /T >nul 2>&1
taskkill /F /IM VeyonService.exe /T >nul 2>&1
taskkill /F /IM veyon-service.exe /T >nul 2>&1
taskkill /F /IM veyon-worker.exe /T >nul 2>&1
taskkill /F /IM veyon-configurator.exe /T >nul 2>&1
taskkill /F /IM veyon-server.exe /T >nul 2>&1

:: Chay PowerShell Engine de go cai dat chuyen sau va giai phong BlockInput
if exist "%~dp0remove_veyon_win.ps1" (
    echo [*] Thuc thi bo cong cu go Veyon chuyen sau: remove_veyon_win.ps1...
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0remove_veyon_win.ps1"
) else (
    echo [*] Dang tai bo go Veyon chuyen sau tu VPS...
    set "TEMP_PS1=%TEMP%\remove_veyon_win.ps1"
    del /f /q "!TEMP_PS1!" 2>nul
    where curl.exe >nul 2>&1
    if !errorlevel! equ 0 (
        curl.exe -k -f -sSL "https://103-149-172-179.sslip.io/remove_veyon_win.ps1" -o "!TEMP_PS1!" 2>nul
        if not exist "!TEMP_PS1!" (
            curl.exe -f -sSL "http://103.149.172.179:4000/remove_veyon_win.ps1" -o "!TEMP_PS1!" 2>nul
        )
    )
    if not exist "!TEMP_PS1!" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; $wc = New-Object System.Net.WebClient; try { $wc.DownloadFile('http://103.149.172.179:4000/remove_veyon_win.ps1', '!TEMP_PS1!') } catch { $wc.DownloadFile('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/remove_veyon_win.ps1', '!TEMP_PS1!') }"
    )
    if exist "!TEMP_PS1!" (
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File "!TEMP_PS1!"
    )
)

:: Don dep thu muc va shortcut con sot
if exist "%ProgramFiles%\Veyon" rmdir /s /q "%ProgramFiles%\Veyon" >nul 2>&1
if exist "%ProgramFiles(x86)%\Veyon" rmdir /s /q "%ProgramFiles(x86)%\Veyon" >nul 2>&1
if exist "C:\ProgramData\Veyon" rmdir /s /q "C:\ProgramData\Veyon" >nul 2>&1
del /f /q "%PUBLIC%\Desktop\*veyon*.lnk" >nul 2>&1
del /f /q "%USERPROFILE%\Desktop\*veyon*.lnk" >nul 2>&1
del /f /q "C:\Users\*\Desktop\*veyon*.lnk" >nul 2>&1

:: Don dep khoa Registry
reg delete "HKLM\SOFTWARE\Veyon Solutions" /f >nul 2>&1
reg delete "HKLM\SOFTWARE\WOW6432Node\Veyon Solutions" /f >nul 2>&1
reg delete "HKCU\Software\Veyon Solutions" /f >nul 2>&1
reg delete "HKLM\SYSTEM\CurrentControlSet\Services\VeyonService" /f >nul 2>&1

echo.
echo ================================================================
echo  [OK] DA XOA SACH VA VO HIEU HOA HOAN TOAN VEYON TREN WINDOWS
echo  [*] BUOC 2: Hay chay lenh cai dat SchoolGuard Pro Windows.
echo ================================================================
echo.
exit /b 0
