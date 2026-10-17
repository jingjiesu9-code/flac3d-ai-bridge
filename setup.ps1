# setup.ps1 -- one-shot install of the whole FLAC3D <-> AI link.
#
# NOTE: ASCII-only on purpose (see configure.ps1).
#
# Idempotent: safe to re-run. Each step is skipped when already satisfied.
# Steps:
#   1. render path-bearing files from templates   (configure.ps1)
#   2. install itasca-mcp-bridge into FLAC3D's embedded Python
#   3. build the flac-mcp venv with the pinned version
#   4. verify the MCP layer end to end            (verify_mcp.ps1)
#   5. optionally mount the tools into DSH        (apply_dsh_mcp.ps1)
[CmdletBinding()]
param(
    [string]$IndexUrl,          # pip index; defaults to PyPI, use a mirror if slow
    [switch]$SkipBridge,
    [switch]$SkipVenv,
    [switch]$SkipVerify,
    [switch]$WithDsh,           # also apply the DSH profile patch
    [switch]$Force              # reconfigure even if preset.json exists
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# ------------------------------------------------------------ 1. configure --
Head '1/5  configure'
$presetPath = Join-Path $root 'preset.json'
if ((Test-Path $presetPath) -and -not $Force) {
    Write-Host '  preset.json exists (use -Force to re-render)'
} else {
    & (Join-Path $root 'configure.ps1')
    if ($LASTEXITCODE -ne 0) { throw 'configure.ps1 failed' }
}
$preset = Get-Content -LiteralPath $presetPath -Raw -Encoding UTF8 | ConvertFrom-Json

# pip cache/temp inside the folder: on locked-down machines the default temp is
# not writable and pip then hangs forever instead of erroring.
$pipTmp = Join-Path $root '_piptmp'
New-Item -ItemType Directory -Force -Path $pipTmp | Out-Null
$env:PIP_CACHE_DIR = Join-Path $pipTmp 'cache'
$env:TMP = $pipTmp
$env:TEMP = $pipTmp

$pipArgs = @('--no-cache-dir', '--disable-pip-version-check', '--timeout', '30', '--retries', '2')
if ($IndexUrl) { $pipArgs += @('--index-url', $IndexUrl, '--trusted-host', ([uri]$IndexUrl).Host) }

# --------------------------------------------------------------- 2. bridge --
Head '2/5  bridge (inside FLAC3D)'
if ($SkipBridge) {
    Write-Host '  skipped'
} else {
    $py = $preset.flac3d.pythonExe
    if (-not $py -or -not (Test-Path $py)) {
        Write-Warning "FLAC3D embedded python not found; skipping bridge install."
        Write-Warning "Re-run with -Flac3dDir once FLAC3D is installed."
    } else {
        Write-Host "  target: $py"
        & $py -m pip install --user @pipArgs "$($preset.bridge.package)==$($preset.bridge.version)"
        if ($LASTEXITCODE -ne 0) { throw "bridge install failed (exit $LASTEXITCODE)" }
    }
}

# ----------------------------------------------------------------- 3. venv --
Head '3/5  flac-mcp venv'
$venv     = $preset.mcpServer.venv
$venvPy   = Join-Path $venv 'Scripts\python.exe'
$mcpExe   = $preset.mcpServer.exe
if ($SkipVenv) {
    Write-Host '  skipped'
} else {
    if (-not (Test-Path $venvPy)) {
        Write-Host "  creating venv: $venv"
        & $preset.hostPython -m venv $venv
        if ($LASTEXITCODE -ne 0) { throw "venv creation failed (exit $LASTEXITCODE)" }
    } else {
        Write-Host "  venv exists: $venv"
    }
    Write-Host "  installing $($preset.mcpServer.package)==$($preset.mcpServer.version)"
    & $venvPy -m pip install --upgrade pip @pipArgs | Out-Null
    & $venvPy -m pip install @pipArgs "$($preset.mcpServer.package)==$($preset.mcpServer.version)"
    if ($LASTEXITCODE -ne 0) { throw "flac-mcp install failed (exit $LASTEXITCODE)" }
    if (-not (Test-Path $mcpExe)) { throw "flac-mcp.exe not found after install: $mcpExe" }
    Write-Host "  ok: $(& $mcpExe --version 2>&1 | Select-Object -First 1)"
}

# --------------------------------------------------------------- 4. verify --
Head '4/5  verify MCP layer'
if ($SkipVerify) {
    Write-Host '  skipped'
} elseif (-not (Test-Path $mcpExe)) {
    Write-Warning '  flac-mcp.exe missing; skipping'
} else {
    & (Join-Path $root 'verify_mcp.ps1')
    if ($LASTEXITCODE -ne 0) {
        Write-Warning '  MCP handshake failed. This is expected if FLAC3D is not running yet:'
        Write-Warning '  the server itself starts fine, only calls to the bridge need FLAC3D.'
    }
}

# ------------------------------------------------------------------ 5. DSH --
Head '5/5  DSH integration'
if ($WithDsh) {
    & (Join-Path $root 'apply_dsh_mcp.ps1')
} else {
    Write-Host '  not requested (pass -WithDsh to mount the tools into DSH)'
}

Head 'Done'
Write-Host @"
  Start FLAC3D, then in its COMMAND console (prompt 'flac3d>', NOT the IPython pane):

    program call '$root\flac3d\run_bridge.dat'

  Then:  .\doctor.ps1
"@
