# doctor.ps1 -- one-shot health check for the whole FLAC3D <-> AI link.
#
# NOTE: ASCII-only on purpose (see install_bridge.ps1).
#
# Run this FIRST whenever anything misbehaves. It encodes the failure modes
# that actually cost time while building this setup, so a red line here points
# straight at the cause instead of at a symptom.
[CmdletBinding()]
param()

$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$preset = Get-Content (Join-Path $here 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$script:results = @()
function Add-Result($name, $status, $detail) {
    $script:results += [pscustomobject]@{ Check = $name; Status = $status; Detail = $detail }
    $color = switch ($status) { 'PASS' { 'Green' } 'WARN' { 'Yellow' } default { 'Red' } }
    Write-Host ("  [{0}] {1,-34} {2}" -f $status, $name, $detail) -ForegroundColor $color
}

function Get-PortListening([int]$port) {
    return [bool](netstat -ano | Select-String ":$port\s" | Select-String 'LISTENING')
}

Write-Host "`n=== FLAC3D <-> AI link doctor ===" -ForegroundColor Cyan
Write-Host "preset: $here\preset.json`n"

# --- 1. FLAC3D install -------------------------------------------------
if (Test-Path $preset.flac3d.consoleExe) {
    Add-Result 'flac3d console exe' 'PASS' $preset.flac3d.consoleExe
} else {
    Add-Result 'flac3d console exe' 'FAIL' "missing: $($preset.flac3d.consoleExe)"
}

$py = $preset.flac3d.pythonExe
if (Test-Path $py) {
    $v = & $py -c "import sys;print(sys.version.split()[0])" 2>&1
    Add-Result 'flac3d embedded python' 'PASS' "$v  ($py)"
} else {
    Add-Result 'flac3d embedded python' 'FAIL' "missing: $py"
}

# --- 2. bridge package in FLAC3D python --------------------------------
$bridgeVer = $null
try {
    $bridgeVer = (& $py -c "import itasca_mcp_bridge as b;print(b.__version__)" 2>&1 | Select-Object -First 1)
    if ($bridgeVer -match '^\d+\.\d+') {
        Add-Result 'itasca-mcp-bridge installed' 'PASS' "version $bridgeVer"
    } else {
        Add-Result 'itasca-mcp-bridge installed' 'FAIL' "import failed: $bridgeVer"
        $bridgeVer = $null
    }
} catch {
    Add-Result 'itasca-mcp-bridge installed' 'FAIL' $_.Exception.Message
}

if ($bridgeVer -ne $null -and $preset.bridge.version -and $bridgeVer -ne $preset.bridge.version) {
    Add-Result 'bridge version vs preset' 'WARN' "installed $bridgeVer, preset says $($preset.bridge.version)"
}

# --- 3. flac-mcp server -------------------------------------------------
$mcpExe = $preset.mcpServer.exe
$mcpVer = $null
if (Test-Path $mcpExe) {
    $mcpVer = (& $mcpExe --version 2>&1 | Select-Object -First 1)
    Add-Result 'flac-mcp server' 'PASS' "$mcpVer  ($mcpExe)"
} else {
    Add-Result 'flac-mcp server' 'FAIL' "missing: $mcpExe"
}

# Version pairing is the single nastiest trap here: the bridge speaks either
# WebSocket (0.2.x) or HTTP/SSE (0.5.x), and flac-mcp 0.5.2 only speaks the
# latter. A mismatch surfaces as a bare '400 Bad Request' on execute_code.
if ($bridgeVer -ne $null -and $mcpVer -ne $null) {
    $bMajor = [int]($bridgeVer -split '\.')[0]
    $bMinor = [int]($bridgeVer -split '\.')[1]
    if ($bMajor -eq 0 -and $bMinor -lt 5) {
        Add-Result 'bridge/flac-mcp pairing' 'FAIL' "bridge $bridgeVer uses WebSocket; flac-mcp $mcpVer needs HTTP bridge >= 0.5"
    } else {
        Add-Result 'bridge/flac-mcp pairing' 'PASS' "bridge $bridgeVer (HTTP/SSE) + $mcpVer"
    }
}

# --- 4. bridge liveness -------------------------------------------------
$port = $preset.bridge.port
if (Get-PortListening $port) {
    Add-Result "port $port listening" 'PASS' 'a FLAC3D with the bridge is running'
    Push-Location $here
    try {
        $ping = & $preset.hostPython (Join-Path $here 'flacctl.py') --timeout 20 ping 2>&1 | Out-String
        if ($LASTEXITCODE -eq 0) {
            Add-Result 'bridge responds to ping' 'PASS' ($ping.Trim() -replace '\s+', ' ' | ForEach-Object { if ($_.Length -gt 70) { $_.Substring(0,70) + '...' } else { $_ } })
        } else {
            Add-Result 'bridge responds to ping' 'FAIL' ($ping.Trim() -replace '\s+', ' ')
        }
    } finally { Pop-Location }
} else {
    Add-Result "port $port listening" 'WARN' 'no bridge running -- start FLAC3D and run flac3d/run_bridge.dat'
}

# --- 5. DSH side --------------------------------------------------------
$patch = $preset.dsh.patchFile
if (Test-Path $patch) {
    $txt = Get-Content $patch -Raw -Encoding UTF8
    if ($txt -match 'flac3d-mcp \(managed block') {
        Add-Result 'dsh mcp patch present' 'PASS' $patch
    } else {
        Add-Result 'dsh mcp patch present' 'WARN' 'managed block absent -- run apply_dsh_mcp.ps1'
    }
} else {
    Add-Result 'dsh mcp patch present' 'FAIL' "missing: $patch"
}

try {
    $dump = & dsh --profile $preset.dsh.profile --dump-config 2>$null | Out-String
    if ($dump -match 'mcp-flac3d') {
        Add-Result 'dsh profile mounts mcp-flac3d' 'PASS' "tools appear as $($preset.dsh.toolPrefix)*"
    } else {
        Add-Result 'dsh profile mounts mcp-flac3d' 'WARN' 'entry not in composed tree -- restart DSH after applying the patch'
    }
} catch {
    Add-Result 'dsh profile mounts mcp-flac3d' 'WARN' "could not run 'dsh --dump-config': $($_.Exception.Message)"
}

# --- summary ------------------------------------------------------------
$fails = @($script:results | Where-Object Status -eq 'FAIL').Count
$warns = @($script:results | Where-Object Status -eq 'WARN').Count
Write-Host "`n=== summary: $($script:results.Count) checks, $fails FAIL, $warns WARN ===" -ForegroundColor Cyan
if ($fails -eq 0 -and $warns -eq 0) {
    Write-Host "All green. In a DSH session, FLAC3D tools are named $($preset.dsh.toolPrefix)<tool>." -ForegroundColor Green
}
exit $(if ($fails -gt 0) { 1 } else { 0 })
