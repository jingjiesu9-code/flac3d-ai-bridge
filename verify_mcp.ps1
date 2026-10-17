# verify_mcp.ps1 -- prove the MCP layer works WITHOUT involving DSH.
#
# NOTE: ASCII-only on purpose (see install_bridge.ps1).
#
# Spawns flac-mcp over stdio, performs a real MCP handshake (initialize +
# tools/list), and prints every tool it advertises. Run this when tools are
# missing in the chat: if this passes, the server side is fine and the problem
# is on the DSH side (restart, or a bad profile patch).
#
# Note: tools/list does NOT touch FLAC3D, so this is safe to run while a long
# solve is in progress.
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$here   = Split-Path -Parent $MyInvocation.MyCommand.Path
$preset = Get-Content (Join-Path $here 'preset.json') -Raw -Encoding UTF8 | ConvertFrom-Json

$node = (Get-Command node -ErrorAction SilentlyContinue).Source
if (-not $node) { throw "node not found on PATH (needed to drive the stdio probe)" }

$probe = Join-Path $here 'mcp_stdio_probe.js'
$exe   = $preset.mcpServer.exe
if (-not (Test-Path $exe)) { throw "flac-mcp exe not found: $exe" }

$url = "http://$($preset.bridge.host):$($preset.bridge.port)"

Write-Host "probing $exe" -ForegroundColor Cyan
Write-Host "bridge    $url"

# flac-mcp logs to stderr. With $ErrorActionPreference = 'Stop' PowerShell
# turns any native stderr line into a terminating error, so relax it for the
# call and fold stderr into plain text instead.
$prev = $ErrorActionPreference
$ErrorActionPreference = 'Continue'
try {
    & $node $probe $exe --bridge-url $url --log-level warning 2>&1 |
        ForEach-Object { "$_" }
    $code = $LASTEXITCODE
} finally {
    $ErrorActionPreference = $prev
}

if ($code -eq 0) {
    Write-Host "`nMCP layer OK. In DSH these appear as $($preset.dsh.toolPrefix)<name>." -ForegroundColor Green
} else {
    Write-Host "`nMCP layer FAILED -- see messages above." -ForegroundColor Red
}
exit $code
