# apply_dsh_mcp.ps1 -- mount the FLAC3D MCP server into the DSH profile.
#
# NOTE: ASCII-only on purpose (see install_bridge.ps1).
#
# What it does: inserts (or refreshes) a managed block in the DSH profile's
# cordis.patch.yml. That user-layer patch is applied AFTER every bundle layer,
# so it is the sanctioned place to add a plugin that no bundle mounts.
#
# The whole block between the two marker comments is replaced on re-run, so
# this script is idempotent. The previous file is backed up every time.
[CmdletBinding()]
param(
    [switch]$Remove,
    [switch]$SkipVerify
)

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$preset = Get-Content (Join-Path $here 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$target  = $preset.dsh.patchFile
$payload = Join-Path $here 'dsh\mcp-flac3d.patch.yml'

$BEGIN = '# >>> flac3d-mcp'
$END   = '# <<< flac3d-mcp'

if (-not (Test-Path $target)) { throw "DSH profile patch not found: $target" }
if (-not (Test-Path $payload)) { throw "payload not found: $payload" }

# --- backup -------------------------------------------------------------
$stamp  = Get-Date -Format 'yyyyMMdd_HHmmss'
$backup = "$target.bak_$stamp"
Copy-Item -LiteralPath $target -Destination $backup -Force
Write-Host "backup: $backup"

# --- compose ------------------------------------------------------------
$current = Get-Content -LiteralPath $target -Raw -Encoding UTF8
$block   = (Get-Content -LiteralPath $payload -Raw -Encoding UTF8).TrimEnd()

if ($Remove) {
    if ($current -notmatch [regex]::Escape($BEGIN)) {
        Write-Host "managed block not present; nothing to remove."
        exit 0
    }
    $next = [regex]::Replace($current, "(?ms)^$([regex]::Escape($BEGIN)).*?^$([regex]::Escape($END)).*?$", '').TrimEnd()
    if (-not $next.Trim()) { $next = '[]' }
} elseif ($current -match [regex]::Escape($BEGIN)) {
    # Replace the existing managed block in place.
    $next = [regex]::Replace($current, "(?ms)^$([regex]::Escape($BEGIN)).*?^$([regex]::Escape($END)).*?$", $block).TrimEnd()
    Write-Host "mode: replace existing managed block"
} else {
    # First run: drop the empty-list placeholder, then append the block.
    # A YAML file cannot hold both a top-level '[]' and a block sequence.
    $lines = $current -split "`r?`n" | Where-Object { $_.Trim() -ne '[]' }
    $next  = (($lines -join "`r`n").TrimEnd() + "`r`n`r`n" + $block).TrimStart("`r", "`n")
    Write-Host "mode: first insert"
}

# --- write --------------------------------------------------------------
$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText($target, $next + "`r`n", $utf8NoBom)
Write-Host "wrote : $target"

# --- verify -------------------------------------------------------------
if ($SkipVerify) { exit 0 }

Write-Host "`n--- verifying composed profile tree ---"
$dump = & dsh --profile $preset.dsh.profile --dump-config 2>$null | Out-String
if ($dump -match 'mcp-flac3d') {
    Write-Host "OK: 'mcp-flac3d' is in the composed tree." -ForegroundColor Green
    ($dump -split "`r?`n" | Select-String -Pattern 'mcp-flac3d' -Context 0, 14) | ForEach-Object { $_.ToString() }
} else {
    Write-Host "NOT FOUND in composed tree -- check $target for YAML errors." -ForegroundColor Red
    Write-Host "restore with: Copy-Item '$backup' '$target' -Force"
    exit 1
}

Write-Host "`nRestart DSH (or let live patch reload pick it up) so the tools register." -ForegroundColor Cyan
