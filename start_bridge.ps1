# start_bridge.ps1 -- launch FLAC3D and bring up the bridge on port 9001.
#
# NOTE: ASCII-only on purpose (see install_bridge.ps1).
#
# Idempotent: if something is already listening on the bridge port this script
# reports it and exits without starting a second FLAC3D.
[CmdletBinding()]
param(
    [int]$WaitSeconds = 120,
    [switch]$Visible
)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$preset = Get-Content (Join-Path $here 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$port = $preset.bridge.port
$exe  = $preset.flac3d.consoleExe
$dat  = Join-Path $here 'flac3d\run_bridge.dat'

function Test-BridgePort {
    # Get-NetTCPConnection is unreliable under this sandbox (it has reported no
    # listener while netstat clearly showed LISTENING), so netstat is used.
    $hit = netstat -ano | Select-String ":$port\s" | Select-String 'LISTENING'
    return [bool]$hit
}

if (Test-BridgePort) {
    Write-Host "Port $port is already LISTENING -- a bridge is already up; not starting another FLAC3D." -ForegroundColor Yellow
    & $preset.hostPython (Join-Path $here 'flacctl.py') --timeout 20 ping
    exit $LASTEXITCODE
}

if (-not (Test-Path $exe)) { throw "FLAC3D console exe not found: $exe" }
if (-not (Test-Path $dat)) { throw "Launcher .dat not found: $dat" }

$logDir = Join-Path $here '_logs'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null

Write-Host "Starting FLAC3D: $exe"
$style = if ($Visible) { 'Normal' } else { 'Hidden' }
$proc = Start-Process -FilePath $exe -ArgumentList $dat `
    -WorkingDirectory $preset.flac3d.projectDir `
    -RedirectStandardOutput (Join-Path $logDir 'flac3d_out.txt') `
    -RedirectStandardError  (Join-Path $logDir 'flac3d_err.txt') `
    -PassThru -WindowStyle $style
Write-Host "FLAC3D PID: $($proc.Id)  (model is EMPTY -- restore or build before computing)"

Write-Host "Waiting for port $port (up to ${WaitSeconds}s) ..."
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$up = $false
while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 3
    if (Test-BridgePort) { $up = $true; break }
    if ($proc.HasExited) { break }
}

if (-not $up) {
    Write-Host "Bridge did NOT come up." -ForegroundColor Red
    Write-Host "--- flac3d_out.txt (tail) ---"
    Get-Content (Join-Path $logDir 'flac3d_out.txt') -Tail 25 -ErrorAction SilentlyContinue
    exit 1
}

Write-Host "Port $port is LISTENING." -ForegroundColor Green
Write-Host "`n--- bridge ping ---"
& $preset.hostPython (Join-Path $here 'flacctl.py') --timeout 20 ping
exit $LASTEXITCODE
