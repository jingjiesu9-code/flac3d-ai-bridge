# install_agent_preset.ps1 -- copy the authored agent preset into the USER root.
#
# NOTE: ASCII-only on purpose (see install_bridge.ps1).
#
# Target is `<dshHome>/.agent-presets/<id>/`, the roster's writable user root.
# It is NOT the shipped install beside the deployment: an upgrade overwrites
# that one, and the roster deliberately refuses to let you delete from it.
[CmdletBinding()]
param(
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$presetRoot = Split-Path -Parent $here
$preset = Get-Content (Join-Path $presetRoot 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$name = 'flac3d'
$src  = Join-Path $here "agent_preset\$name"
$userRoot = Join-Path $preset.dsh.home '.agent-presets'
$dst  = Join-Path $userRoot $name

if (-not (Test-Path $src)) { throw "authored preset not found: $src" }

# --- validate before installing ----------------------------------------
Write-Host "--- validating ---" -ForegroundColor Cyan
& $preset.hostPython (Join-Path $here 'validate_preset.py') $src
if ($LASTEXITCODE -ne 0) { throw "preset failed validation; refusing to install" }

# --- install ------------------------------------------------------------
if (Test-Path $dst) {
    if (-not $Force) {
        Write-Host "`n$dst already exists. Re-run with -Force to replace it." -ForegroundColor Yellow
        exit 0
    }
    $stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
    $backup = "$dst.bak_$stamp"
    Move-Item -LiteralPath $dst -Destination $backup -Force
    Write-Host "`nbacked up existing preset -> $backup"
}

New-Item -ItemType Directory -Force -Path $userRoot | Out-Null
Copy-Item -LiteralPath $src -Destination $dst -Recurse -Force

Write-Host "`ninstalled -> $dst" -ForegroundColor Green
Get-ChildItem $dst -Recurse -File | ForEach-Object {
    "  {0,-58} {1,6:N1} KB" -f $_.FullName.Replace("$dst\", ''), ($_.Length / 1KB)
}

Write-Host "`nThe roster scans this root on every read, so no restart is needed to LIST it." -ForegroundColor Cyan
Write-Host "Only an empty session can SWITCH to it -- a session that has produced any message" -ForegroundColor Cyan
Write-Host "or tool call keeps the composition it started with. Start a new session to use it." -ForegroundColor Cyan
