# flac3d-ai-bridge

[![CI](https://github.com/jingjiesu9-code/flac3d-ai-bridge/actions/workflows/ci.yml/badge.svg)](https://github.com/jingjiesu9-code/flac3d-ai-bridge/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Platform: Windows](https://img.shields.io/badge/platform-Windows%2010%2F11-0078D6.svg)](#compatibility)
[![FLAC3D](https://img.shields.io/badge/FLAC3D-7.x-orange.svg)](#compatibility)

**Let an AI assistant (DeepSeek Harness / Codex / Claude Desktop / any MCP client) drive your local ITASCA FLAC3D** — inspect the model, send commands, launch runs, and watch progress. You can also skip MCP entirely and script FLAC3D through the bundled stdlib-only CLI, `flacctl.py`.

> English | [简体中文](README.md)
>
> Targets **ITASCA FLAC3D 7.x on Windows 10/11**. Other versions are unverified. It is not tied to any specific geotechnical workflow — once installed, it is a generic control channel for FLAC3D.

---

## How it works

FLAC3D exposes no control interface of its own. This project starts a local HTTP service
(`itasca-mcp-bridge`) inside the FLAC3D process, then puts an MCP server (`flac-mcp`) in front of it
to translate HTTP into MCP tools.

```
   AI client (DSH / Codex / Claude Desktop / ...)
        │  MCP (stdio)
        ▼
   flac-mcp                 ← protocol translation, pure forwarding
        │  HTTP  127.0.0.1:9001
        ▼
   itasca-mcp-bridge        ← runs INSIDE FLAC3D, drives the model via the itasca SDK
        │
        ▼
   FLAC3D
```

**MCP is only the shell.** The bridge is a plain HTTP service; `flacctl.py` (standard library only)
talks to it directly — no MCP client, no AI, no third-party packages required. Two independent
paths, one backend, usable at the same time.

## Requirements

| Need | Notes |
|---|---|
| Windows 10/11 | Orchestration scripts are PowerShell; `flacctl.py` itself is portable |
| FLAC3D 7.x | Installed and able to start (auto-detected, or pass the path) |
| Python 3.8–3.12 | A normal host Python for the `flac-mcp` venv. **Not** FLAC3D's embedded 3.6 |
| PowerShell 5.1+ | Ships with Windows |
| Node.js (optional) | Only for the raw JSON-RPC probe in `verify_mcp.ps1` |
| Network (first install only) | Two packages come from PyPI; afterwards it runs fully offline |
| DSH (optional) | Only if you want the `mcp__flac3d__*` tools inside DeepSeek Harness |

## Install

```powershell
git clone https://github.com/jingjiesu9-code/flac3d-ai-bridge.git
cd flac3d-ai-bridge
.\configure.ps1                  # detect FLAC3D / Python / DSH, render every path-bearing file
.\setup.ps1                      # install the bridge, build the venv, install flac-mcp, self-check
```

If detection fails, point it at your install explicitly:

```powershell
.\configure.ps1 -Flac3dDir 'D:\Itasca\FLAC3D700' -Flac3dProject 'D:\my-model'
.\setup.ps1 -IndexUrl https://pypi.tuna.tsinghua.edu.cn/simple/   # use a mirror if PyPI is slow
```

`setup.ps1` is idempotent; re-run it any time. It generates `preset.json`,
`flac3d\run_bridge.dat` and `dsh\mcp-flac3d.patch.yml` — all gitignored, never commit them.

## Start the bridge

**Once per FLAC3D launch** — the bridge does not auto-start with FLAC3D.

In the FLAC3D **command console** (prompt `flac3d>`), *not* the IPython pane:

```
program call '<install-dir>\flac3d\run_bridge.dat'
```

> `program call` is FLAC3D command syntax, not Python. Pasting it into IPython yields
> `SyntaxError: invalid syntax`. If you only see IPython, the command console is usually in a
> View/Window menu.
>
> The IPython equivalent is:
>
> ```python
> import itasca_mcp_bridge as b; b.start(host="127.0.0.1", port=9001, mode="console", auto_upgrade=False)
> ```

`BRIDGE_READY: http://127.0.0.1:9001` means it is up. Or let the script do it:

```powershell
.\start_bridge.ps1               # launch FLAC3D and wait for the port
```

Health checks:

```powershell
.\doctor.ps1                     # 9-point end-to-end check; a red line points at the cause
.\verify_mcp.ps1                 # MCP layer only; safe while a solve is running
```

## Usage A — tools inside an AI chat

For DeepSeek Harness:

```powershell
.\apply_dsh_mcp.ps1              # idempotent, backs up the profile, -Remove undoes it
```

Restart DSH; new sessions get 10 `mcp__flac3d__*` tools (see [Tools](#tools)).

Other MCP clients (Claude Desktop, Codex, ...) use their standard `mcpServers` config with the
`flac-mcp.exe` from the venv — same arguments as `dsh\mcp-flac3d.patch.yml`:

```json
{
  "mcpServers": {
    "flac3d": {
      "command": "C:\\path\\to\\flac3d-ai-bridge\\.venv-flac\\Scripts\\flac-mcp.exe",
      "args": ["--bridge-url", "http://127.0.0.1:9001", "--log-level", "warning"]
    }
  }
}
```

## Usage B — script it directly (no AI)

```powershell
$py = (Get-Content .\preset.json -Raw | ConvertFrom-Json).hostPython

& $py flacctl.py ping                           # is the bridge alive?
& $py flacctl.py code "print(itasca.cycle())"   # run Python inside FLAC3D
& $py flacctl.py code @myscript.py              # run a local script file
& $py flacctl.py cmd "model new"
& $py flacctl.py cmd "zone create brick size 2 2 2"
& $py flacctl.py tasks --limit 5
& $py flacctl.py run long_job.py "description"  # submit an async task
& $py flacctl.py check <task_id>
& $py flacctl.py interrupt <task_id>
```

Global flags go **before** the subcommand: `flacctl.py --timeout 20 tasks` ✅,
`flacctl.py tasks --timeout 20` ❌. Exit code is 0 on success, 1 on error; `--raw` prints the
untouched JSON envelope. Override the bridge URL with `--url` or `FLAC_MCP_BRIDGE_URL`.

## Tools

Tool names carry the `mcp__<serverName>__` prefix (default `mcp__flac3d__`):

| Tool | Purpose |
|---|---|
| `flac_execute_code` | Run Python synchronously — reads, small pokes |
| `flac_execute_task` | Submit an async task script, returns a `task_id` immediately |
| `flac_check_task_status` | Task status with a live console tail |
| `flac_list_tasks` | List tracked tasks |
| `flac_interrupt_task` | Interrupt a running task |
| `flac_query_command` | Look up FLAC command syntax |
| `flac_browse_commands` | Browse the command reference |
| `flac_query_python_api` | Search the Python SDK |
| `flac_browse_python_api` | Browse the Python SDK |
| `flac_browse_reference` | Zone constitutive-model / structural property names |

## Repository layout

| Path | Purpose |
|---|---|
| `preset.template.json` | Config template with placeholders — **do not edit by hand** |
| `configure.ps1` | Detect the local layout and render every path-bearing file |
| `setup.ps1` | One-shot, idempotent install |
| `doctor.ps1` | 9-point end-to-end health check |
| `verify_mcp.ps1` | Verify the MCP layer without an AI client |
| `mcp_stdio_probe.js` | Raw JSON-RPC stdio probe (no SDK, needs node) |
| `install_bridge.ps1` | Install only the bridge into FLAC3D's embedded Python |
| `start_bridge.ps1` | Launch FLAC3D + bridge, wait for the port |
| `flacctl.py` | Direct-connection CLI, **stdlib only** |
| `apply_dsh_mcp.ps1` | Mount the MCP tools into DSH (optional) |
| `flac3d\start_bridge.py` | Code that actually starts the bridge |
| `dsh\mcp-flac3d.patch.yml.template` | The YAML written into the DSH profile |
| `dsh\agent_preset\` | Optional "FLAC3D modelling" agent preset |
| `tests\check_repo.py` | FLAC3D-free repository checks (used by CI) |

> Every `.ps1` file is **ASCII-only on purpose**: Windows PowerShell 5.1 reads a BOM-less `.ps1`
> as ANSI, which garbles non-ASCII text in diagnostic tools. CI enforces this.

## Version pairing and upstream status

| Component | Pinned here | Notes |
|---|---|---|
| `itasca-mcp-bridge` | **0.5.5** | Must be >= 0.5 |
| `flac-mcp` | **0.5.2** | Only speaks HTTP+SSE bridges |

A 0.2.x bridge speaks **WebSocket**; paired with flac-mcp 0.5.2 it fails with a bare
`400 Bad Request for url '.../execute_code'`, which looks nothing like a version problem.
The `pairing` line in `doctor.ps1` exists to catch exactly that.

Change versions with `configure.ps1 -BridgeVersion ... -FlacMcpVersion ...`, then re-run `setup.ps1`.

> **Upstream status (2026-10):** `flac-mcp` is marked deprecated on PyPI; its successor is
> [itasca-mcp](https://github.com/yusong652/itasca-mcp) (0.10.x, also MIT). v1.0 pins the
> **verified** bridge 0.5.5 + flac-mcp 0.5.2 combination and has not migrated — tool names and
> flags may differ after migration and would need re-testing. PRs for that migration are welcome,
> but please state the FLAC3D version you tested on.

## Three hard constraints

1. **One process, one thread, strictly serial.** Two cases cannot run concurrently; `model new`
   destroys the current model. Batch runs must be chained inside one task, never submitted in parallel.
2. **Long work goes through the async API.** `flac_execute_code` blocks until it times out, so a
   `model solve` sent through it leaves you with no task id to poll. Use `flac_execute_task`.
3. **FISH is Python 3.6 and its trigonometry is in radians.** There is no `math.deg2rad`;
   `math.sin(30.0)` returns `-0.988`, not `0.5` — silently wrong, not an error.

## Troubleshooting (short version)

| Symptom | Cause | Fix |
|---|---|---|
| `400 Bad Request ... /execute_code` | bridge/flac-mcp version mismatch | Check the `pairing` line in `doctor.ps1` |
| Upgrade had no effect | old process still runs old code | Restart FLAC3D — upgrades are never live in a running process |
| Everything returns `timeout` / `stuck_in_c` | interpreter parked at `Fish>` | Restart FLAC3D; ship FISH in a `.f3dat` and use `program call` |
| `program call` raises `SyntaxError` | pasted into the IPython pane | Use the FLAC3D **command console** (`flac3d>`) |
| No `mcp__flac3d__*` tools in chat | DSH not restarted / patch not applied | `verify_mcp.ps1` → `doctor.ps1` → restart DSH |
| Numbers subtly wrong, no error | degrees fed to FISH trig | Multiply by `math.pi / 180.0` |
| `pip install` hangs | pip cache/temp not writable | This project points `PIP_CACHE_DIR`/`TMP` inside its own folder |

The full Chinese README has a longer [troubleshooting table](README.md#排错).

## Security

- The bridge listens on `127.0.0.1` only and has **no authentication**. Do not expose it, do not
  forward the port; any local process can connect.
- Calls execute **arbitrary Python** inside the FLAC3D process — full process privileges. Use it
  only on machines and accounts you trust.
- No data leaves your machine; no network access after the first `pip install`.

## Compatibility

| Item | Status |
|---|---|
| Windows 10/11 + PowerShell 5.1 | ✅ primary target, tested |
| FLAC3D 7.0 / 7.1 | ✅ target versions |
| FLAC3D 6.x / 9.x | ❌ unverified |
| Orchestration scripts on macOS/Linux | ❌ unsupported (PowerShell, Windows paths, `netstat`) |
| `flacctl.py` on macOS/Linux | ⚠️ should work (stdlib HTTP) if the bridge port is reachable |

## License and third parties

Project code is [MIT licensed](LICENSE). See [NOTICE](NOTICE) for third-party components,
trademarks and disclaimers:

- **FLAC3D is commercial software by Itasca Consulting Group, Inc.** This project neither bundles
  nor redistributes it, and is not affiliated with or endorsed by Itasca. You need your own licence.
- `itasca-mcp-bridge`, `flac-mcp` (and the successor `itasca-mcp`) are MIT-licensed upstream
  projects by their authors. This repository only pins versions and wires them together.
- `dsh/agent_preset/flac3d/agent.cordis.yml` is derived from the `standard` preset shipped with
  DeepSeek Harness (see `dsh/build_preset.py`) so the preset stays reproducible and reviewable.
