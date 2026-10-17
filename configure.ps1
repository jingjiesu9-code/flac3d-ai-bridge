# configure.ps1 -- detect this machine's FLAC3D / Python / DSH layout and render
# every path-bearing file from its template.
#
# NOTE: ASCII-only on purpose. Windows PowerShell 5.1 reads .ps1 as ANSI unless a
# BOM is present, which would garble non-ASCII text in a diagnostic tool.
#
# Renders:  preset.json, flac3d\run_bridge.dat, dsh\mcp-flac3d.patch.yml
# From:     preset.template.json, flac3d\run_bridge.dat.template,
#           dsh\mcp-flac3d.patch.yml.template
#
# Re-run it any time a path changes. Nothing here needs network access.
[CmdletBinding()]
param(
    [string]$Flac3dDir,        # install dir OR path to flac3d*_console.exe
    [string]$Flac3dProject,    # default working directory for new FLAC3D instances
    [string]$HostPython,       # python 3.8+ used to build the flac-mcp venv
    [string]$VenvDir,          # where the flac-mcp venv lives
    [string]$DshHome,
    [string]$DshProfile,
    [int]$BridgePort = 9001,
    [string]$BridgeVersion = '0.5.5',
    [string]$FlacMcpVersion = '0.5.2'
)

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function Info($m) { Write-Host "  $m" }
function Head($m) { Write-Host "`n$m" -ForegroundColor Cyan }

# ---------------------------------------------------------------- FLAC3D ----
function Test-Flac3dDir([string]$dir) {
    if (-not $dir -or -not (Test-Path $dir)) { return $null }
    $console = Get-ChildItem -LiteralPath $dir -Recurse -Depth 3 -File `
        -Filter 'flac3d*_console.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $console) { return $null }
    $exe64 = $console.Directory.FullName
    $py = Join-Path $exe64 'python36\python.exe'
    $gui = Get-ChildItem -LiteralPath $exe64 -Filter 'flac3d*_gui.exe' -File `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    [pscustomobject]@{
        Console = $console.FullName
        Gui     = if ($gui) { $gui.FullName } else { '' }
        Python  = if (Test-Path $py) { $py } else { '' }
        Install = Split-Path -Parent $exe64
    }
}

Head 'Detecting FLAC3D'
$flac = $null
$probes = @()
if ($Flac3dDir) {
    # accept either the exe itself or any containing directory
    $probes += if (Test-Path $Flac3dDir -PathType Leaf) {
        Split-Path -Parent (Split-Path -Parent $Flac3dDir)
    } else { $Flac3dDir }
}
foreach ($drv in (Get-PSDrive -PSProvider FileSystem -ErrorAction SilentlyContinue).Root) {
    foreach ($sub in 'FLAC3D', 'Itasca', 'Program Files\Itasca', 'Program Files (x86)\Itasca') {
        $probes += (Join-Path $drv $sub)
    }
}
foreach ($p in ($probes | Select-Object -Unique)) {
    if (-not (Test-Path $p)) { continue }
    $flac = Test-Flac3dDir $p
    if ($flac) { break }
}
if (-not $flac) {
    throw "FLAC3D not found. Pass -Flac3dDir <install dir or flac3d*_console.exe>."
}
Info "install : $($flac.Install)"
Info "console : $($flac.Console)"
Info "python  : $(if ($flac.Python) { $flac.Python } else { '(NOT FOUND - bridge cannot be installed)' })"

# Derived from the exe name (flac3d700_console.exe -> 7.00) rather than by
# invoking it: `flac3d*_console.exe -v` can start a console session and hang
# the script on a machine with no display or a pending license prompt.
$flacVer = ''
$m = [regex]::Match($flac.Console, 'flac3d(\d)(\d+)')
if ($m.Success) { $flacVer = "$($m.Groups[1].Value).$($m.Groups[2].Value)" }
Info "version : $(if ($flacVer) { $flacVer } else { '(unknown)' })"

# ------------------------------------------------------------ host python ---
function Get-PyVersion([string]$exe) {
    try {
        $v = & $exe -c "import sys;print('%d.%d'%sys.version_info[:2])" 2>$null
        if ($v -match '^\d+\.\d+$') { return [version]$v }
    } catch { }
    return $null
}

Head 'Detecting host Python (runs flac-mcp and flacctl)'
$pyCands = @()
if ($HostPython) { $pyCands += $HostPython }
foreach ($n in 'python', 'python3') {
    $c = Get-Command $n -ErrorAction SilentlyContinue
    if ($c) { $pyCands += $c.Source }
}
foreach ($pat in "$env:ProgramFiles\Python3*\python.exe",
                 "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe",
                 "$env:ProgramFiles\Python3*\python.exe") {
    $pyCands += (Get-ChildItem $pat -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
}
$best = $null; $bestScore = -1
foreach ($c in ($pyCands | Where-Object { $_ } | Select-Object -Unique)) {
    if (-not (Test-Path $c)) { continue }
    $v = Get-PyVersion $c
    if (-not $v -or $v -lt [version]'3.8') { continue }
    # Prefer the range the MCP stack is actually exercised on (3.9-3.12) over
    # merely-newest: a brand-new interpreter is the likeliest to break a
    # transitive dependency, and nothing here needs new syntax.
    $score = if ($v -ge [version]'3.9' -and $v -le [version]'3.12') { 1000 + $v.Minor }
             else { $v.Minor }
    if ($score -gt $bestScore) { $best = $c; $bestVer = $v; $bestScore = $score }
}
if (-not $best) { throw "No Python >= 3.8 found. Pass -HostPython <python.exe>." }
Info "$best  ($bestVer)"

# ------------------------------------------------------------------ venv ----
if (-not $VenvDir) { $VenvDir = Join-Path $root '.venv-flac' }
$mcpExe = Join-Path $VenvDir 'Scripts\flac-mcp.exe'
Info "venv    : $VenvDir"
Info "flac-mcp: $(if (Test-Path $mcpExe) { 'present' } else { 'not built yet - setup.ps1 will create it' })"

# ------------------------------------------------------------------- DSH ----
Head 'Detecting DSH (optional)'
if (-not $DshHome) {
    $DshHome = if ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $HOME '.dsh' }
}
$dshEnabled = $false
$profileDir = ''
$patchFile = ''
if (Test-Path $DshHome) {
    if (-not $DshProfile) {
        $profilesRoot = Join-Path $DshHome 'profiles'
        if (Test-Path $profilesRoot) {
            $existing = Get-ChildItem $profilesRoot -Directory -ErrorAction SilentlyContinue |
                Select-Object -Expand Name
            $DshProfile = if ($existing -contains 'desktop') { 'desktop' }
                          elseif ($existing) { $existing[0] }
                          else { 'desktop' }
        } else { $DshProfile = 'desktop' }
    }
    $profileDir = Join-Path $DshHome "profiles\$DshProfile"
    $patchFile = Join-Path $profileDir 'cordis.patch.yml'
    $dshEnabled = Test-Path $patchFile
    Info "home    : $DshHome"
    Info "profile : $DshProfile  ($(if ($dshEnabled) { 'patch file found' } else { 'no patch file - DSH step will be skipped' }))"
} else {
    if (-not $DshProfile) { $DshProfile = 'desktop' }
    Info "not found at $DshHome - DSH integration disabled (everything else still works)"
}

# --------------------------------------------------------------- project ----
if (-not $Flac3dProject) { $Flac3dProject = (Get-Location).Path }
Info "`nproject : $Flac3dProject (default working dir for new FLAC3D instances)"

# ---------------------------------------------------------------- render ----
Head 'Rendering'
$tokens = @{
    '@@FLAC3D_DIR@@'      = $flac.Install
    '@@FLAC3D_CONSOLE@@'  = $flac.Console
    '@@FLAC3D_GUI@@'      = $flac.Gui
    '@@FLAC3D_PYTHON@@'   = $flac.Python
    '@@FLAC3D_VERSION@@'  = $flacVer
    '@@FLAC3D_PROJECT@@'  = $Flac3dProject
    '@@BRIDGE_VERSION@@'  = $BridgeVersion
    '@@BRIDGE_HOST@@'     = '127.0.0.1'
    '@@BRIDGE_PORT@@'     = "$BridgePort"
    '@@FLAC_MCP_VERSION@@'= $FlacMcpVersion
    '@@VENV_DIR@@'        = $VenvDir
    '@@MCP_EXE@@'         = $mcpExe
    '@@DSH_ENABLED@@'     = if ($dshEnabled) { 'true' } else { 'false' }
    '@@DSH_HOME@@'        = $DshHome
    '@@DSH_PROFILE@@'     = $DshProfile
    '@@DSH_PROFILE_DIR@@' = $profileDir
    '@@DSH_PATCH_FILE@@'  = $patchFile
    '@@HOST_PYTHON@@'     = $best
    '@@PRESET_DIR@@'      = $root
}

$renders = @(
    # JsonEscape: JSON strings need backslashes doubled ("X:\\FLAC3D"); a raw
    # Windows path yields "X:\FLAC3D", where \F is an invalid escape and the
    # whole file fails to parse. YAML single-quoted scalars and FLAC command
    # strings are literal, so those two render raw.
    @{ T = 'preset.template.json';              O = 'preset.json';               JsonEscape = $true },
    @{ T = 'flac3d\run_bridge.dat.template';    O = 'flac3d\run_bridge.dat';     JsonEscape = $false },
    @{ T = 'dsh\mcp-flac3d.patch.yml.template'; O = 'dsh\mcp-flac3d.patch.yml';  JsonEscape = $false }
)
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($r in $renders) {
    $tp = Join-Path $root $r.T
    $op = Join-Path $root $r.O
    if (-not (Test-Path $tp)) { throw "template missing: $tp" }
    $text = Get-Content -LiteralPath $tp -Raw -Encoding UTF8
    foreach ($k in $tokens.Keys) {
        $val = [string]$tokens[$k]
        if ($r.JsonEscape) { $val = $val.Replace('\', '\\') }
        $text = $text.Replace($k, $val)
    }
    # a leftover token means the template and this script disagree -- fail loudly
    $left = [regex]::Matches($text, '@@[A-Z_]+@@')
    if ($left.Count) {
        throw "unsubstituted token(s) in $($r.T): $(($left | ForEach-Object { $_.Value }) -join ', ')"
    }
    [System.IO.File]::WriteAllText($op, $text, $utf8)
    Info "rendered $($r.O)"
}

# Prove the JSON render actually parses. A malformed preset.json otherwise fails
# much later, inside whichever script reads it first, with a confusing error.
try {
    $check = Get-Content -LiteralPath (Join-Path $root 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    foreach ($f in 'flac3d.consoleExe', 'flac3d.pythonExe', 'mcpServer.exe', 'hostPython') {
        $node = $check
        foreach ($part in $f.Split('.')) { $node = $node.$part }
        if (-not $node) { throw "preset.json field '$f' is empty" }
    }
    Info 'preset.json parses and has all required fields'
} catch {
    throw "rendered preset.json is not usable: $($_.Exception.Message)"
}

# UTF-8 no BOM is required: the cordis YAML loader reads these as UTF-8 and a
# BOM would end up inside the first key.
Head 'Next'
Write-Host @'
  1. .\setup.ps1                 install bridge + build the flac-mcp venv
  2. start FLAC3D, then in its COMMAND console (flac3d>, not the IPython pane):
       program call '<project>\flac3d\run_bridge.dat'
  3. .\doctor.ps1                9-point health check
  4. .\apply_dsh_mcp.ps1         mount the tools into DSH (optional), then restart DSH
'@
