# install_bridge.ps1 -- install itasca-mcp-bridge into FLAC3D's embedded Python.
#
# NOTE: this file is intentionally ASCII-only. Windows PowerShell 5.1 reads
# .ps1 as ANSI unless a BOM is present, which would garble any non-ASCII text.
#
# Why this script exists: installing into the FLAC3D embedded interpreter is
# fiddly in three specific ways, all handled below.
#   1. pip hangs forever unless its cache/temp live in a writable directory.
#   2. The default index may be slow or unreachable; -IndexUrl overrides it.
#   3. The bridge version MUST pair with flac-mcp (see preset.json "pairing").
[CmdletBinding()]
param(
    [string]$Version,
    [string]$IndexUrl          # defaults to PyPI; pass a mirror if it is slow
)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$preset = Get-Content (Join-Path $here 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $Version) { $Version = $preset.bridge.version }

$py = $preset.flac3d.pythonExe
if (-not $py) { throw "preset.json has no flac3d.pythonExe -- run configure.ps1 first" }
if (-not (Test-Path $py)) { throw "FLAC3D embedded python not found: $py" }

# pip cache + temp MUST be writable, otherwise pip blocks indefinitely.
$tmp = Join-Path $here '_piptmp'
$cache = Join-Path $here '_piptmp\cache'
New-Item -ItemType Directory -Force -Path $tmp, $cache | Out-Null
$env:PIP_CACHE_DIR = $cache
$env:TMP = $tmp
$env:TEMP = $tmp

$pipArgs = @('--no-cache-dir', '--disable-pip-version-check', '--timeout', '30', '--retries', '2')
if ($IndexUrl) { $pipArgs += @('--index-url', $IndexUrl, '--trusted-host', ([uri]$IndexUrl).Host) }

Write-Host "FLAC3D python : $py"
& $py -c "import sys; print('version       :', sys.version.split()[0])"

Write-Host "`nInstalling $($preset.bridge.package)==$Version ..."
& $py -m pip install --user @pipArgs "$($preset.bridge.package)==$Version"
$code = $LASTEXITCODE

Write-Host "`n--- installed state ---"
& $py -c "import itasca_mcp_bridge as b; print('installed     :', b.__version__); print('location      :', b.__file__)"

if ($code -ne 0) { throw "pip exited with $code" }
Write-Host "`nOK. Restart FLAC3D if it was already running -- an upgraded bridge is NOT live in an old process." -ForegroundColor Green
