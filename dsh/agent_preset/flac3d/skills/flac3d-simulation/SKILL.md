---
name: flac3d-simulation
description: Use when driving ITASCA FLAC3D through the mcp__flac3d__* tools — building or editing a model, writing or reviewing a run script, checking a run in progress, mapping Mohr-Coulomb parameters onto Drucker-Prager, launching one case or a serial batch, or diagnosing a run that hangs, errors out, or returns implausible numbers.
---

# Driving FLAC3D

FLAC3D is a live, stateful, single-threaded solver — not a build tool. Almost every
expensive mistake here comes from treating it like one.

## Two paths, same bridge

```
mcp__flac3d__*  tools  ─┐
                        ├─→ itasca-mcp-bridge (HTTP :9001, inside FLAC3D) ─→ FLAC3D
flacctl.py (direct HTTP)─┘
```

`flac-mcp` is only a wrapper. The bridge is a plain HTTP service reachable directly with
`flacctl.py` (stdlib only), which is the better choice for scripted or batch work and for
debugging when the MCP layer is suspect.

```powershell
# host python is recorded in preset.json (.hostPython); any 3.8+ works
$py = (Get-Content .\preset.json -Raw | ConvertFrom-Json).hostPython
& $py flacctl.py ping
& $py flacctl.py code "print(itasca.cycle)"
& $py flacctl.py cmd "model new"
& $py flacctl.py tasks --limit 5
& $py flacctl.py run long_job.py "描述"
```

Global flags go **before** the subcommand: `flacctl.py --timeout 20 tasks` ✅, `flacctl.py tasks --timeout 20` ❌.

## Pick the right tool

| Goal | Tool |
|---|---|
| Read a value, set a variable, tiny poke | `flac_execute_code` |
| Anything that solves, loops, or takes >30 s | `flac_execute_task` |
| Watch a running task | `flac_check_task_status` (has live console tail) |
| Find a command / property / syntax | `flac_query_command`, `flac_browse_commands` |
| Find a Python SDK call | `flac_query_python_api`, `flac_browse_python_api` |
| Zone model / structural property names | `flac_browse_reference` |

`flac_execute_task` takes an **entry script path** and returns a task id immediately.
Submission does not lock parameters — refine live with `flac_execute_code` while it cycles.

## The four rules

**1. One process, one thread, strictly serial.** Two cases cannot run at once. `model new`
destroys the current model outright, so batch runs must chain inside a single task script,
not be submitted in parallel.

**2. Long work goes through `flac_execute_task`.** `flac_execute_code` is synchronous and
blocks until its timeout. A `model solve` sent through it will simply time out while the
solve continues, leaving you with no task id and no way to poll.

**3. FISH trigonometry is in RADIANS, and it is Python 3.6.** `math.sin(30.0)` returns
`-0.988032`, not `0.5` — a wrong number, not an error, so it propagates silently.
`math.deg2rad` does not exist. Write `deg * math.pi / 180.0` (`math.pi` does exist).

**4. Never feed FISH line-by-line through separate `execute_code` calls.** Sending
`fish define` and its body as separate commands leaves the interpreter parked at a `Fish>`
prompt, after which every bridge call returns `timeout` or `stuck_in_c` and the whole
bridge executor is wedged until FLAC3D is restarted. Put the FISH in a `.f3dat` file and
run it with `program call '<file>'`.

## FISH and .dat gotchas

- A FISH **compile error aborts the entire `.f3dat`** and the console hangs without
  reaching `program quit`. The error text appears in the task log — read it there.
- `model save` filenames **cannot be parameterized**. `'probe_[g_tag]_x'` writes a
  literal file; an unquoted parameter gives `Bad conversion of parameter number 1`;
  a FISH variable gives `String tokens must be surrounded by " or ' characters`.
  Keep save names literal and change the tag per case, or generate one `.dat` per case.
- Strings must be quoted in FLAC commands; paths with spaces need single quotes:
  `program call 'C:\path with space\run.dat'`.
- Do not nest `program call` inside a script that is itself being `program call`ed —
  it runs on FLAC3D 6/7 and blocks the bridge for the whole script duration.

## Mohr-Coulomb → Drucker-Prager

FLAC3D 7's Drucker-Prager model takes `q_φ` / `k_φ` / `q_ψ`, **not** `(c, φ)`. Four
matching conventions exist (average, inner, outer, plane-strain) and they give different
numbers, so pick one, write it down in the run script's header, and convert every case the
same way. The formulas below are the **average** convention.

The **average** convention (a common default; agree the choice with the project):

```
q_φ = 6√3·sinφ / (9 − sin²φ)          q_ψ = 6√3·sinψ / (9 − sin²ψ)
k_φ = 6√3·c·cosφ / (9 − sin²φ)
```

Worked example — φ=30°, c=43 kPa → **q_φ = 0.593846**, **k_φ = 44.23 kPa**.

**Sanity gate:** `q_φ` has a hard ceiling of `6√3/8 = 1.2990` (reached at φ=90°). Any value
above it is not a DP parameter at all. This is the check that catches unit errors:
back-converting `dilation-drucker 3.0` demands `sinψ = 1.732 > 1` (impossible, so it was
degrees); `friction-drucker 0.520` back-converts to φ=26.14° (plausible, so it was fine).

Back-conversion is an **identity, not a validation** — it cannot prove parameters are
physically sensible. Only the ceiling check discriminates a unit error.

Common dilation equivalents (average): ψ=0→0, 1→0.0202, 3→0.0605, 5→0.1007, 10→0.2012.

## Standard workflow

1. **Confirm the link** before anything else: bridge listening on 9001 and answering.
2. **Build or restore the model** — `model new` then geometry, or `model restore`.
3. **Set parameters** — `zone cmodel assign`, then `zone property`. Check names with
   `flac_browse_reference constitutive-models <name>` first; a wrong property name is a
   hard error, not a warning.
4. **Initialise in situ stress** before solving — densities and gradients must agree with
   the assigned densities, or the model starts out of balance for no visible reason.
5. **Solve to equilibrium**, then verify convergence (ratio, unbalanced force) before
   trusting anything downstream.
6. **Save named states** as checkpoints and drive the rest from them.
7. **Long runs**: submit via `flac_execute_task` and poll `flac_check_task_status`.

## Diagnosing

| Symptom | Cause | Fix |
|---|---|---|
| `400 Bad Request ... /execute_code` | bridge/flac-mcp version mismatch | 0.2.x bridge is WebSocket; flac-mcp 0.5.2 needs bridge ≥ 0.5. Reinstall and **restart FLAC3D** |
| Everything returns `timeout` / `stuck_in_c` | interpreter parked at `Fish>` | Restart FLAC3D. Prevent by shipping FISH in a `.f3dat` |
| Upgrade had no effect | old process still runs old code | Restart FLAC3D — an upgraded bridge is never live in a running process |
| `model save` wrote a literal filename | save names are not parameterizable | Use literal names; vary the tag per case |
| Numbers are subtly wrong, no error | degrees fed to a FISH trig function | Multiply by `math.pi / 180.0` |
| `UnicodeEncodeError` on output | GBK console vs returned characters | `flacctl.py` already sets `errors="replace"` |
| `Get-NetTCPConnection` shows no listener but connection works | it is unreliable here | Use `netstat -ano \| Select-String ':9001\s'` |
| `pip install` hangs | pip cache/temp not writable | Point `PIP_CACHE_DIR`/`TMP`/`TEMP` at a writable dir |

## Reading `zone.extra`

`zone.extra(z, i)` slots carry project state (damage, OCR, stiffness ratios, accumulated
strain, layer ids). **The slot map is project-specific and there is no registry** — more
than one map can be in circulation even inside one group, which makes a wrong assumption
here silently meaningless rather than wrong.

Discover the real map before relying on it:

1. Find every writer: search the `.dat` / FISH for `zone.extra(` and note the index and the
   quantity assigned at each call site.
2. Find every reader: search for `extra(i)` in `zone history`, `zone list`, or FISH that
   branches on it.
3. A slot that is **write-only** changes no computation on its own — setting it produces no
   effect and no error. Confirm a reader exists before expecting anything from a slot.

`zone history name 'x' extra index N source zone position ...` is the usual way a slot
reaches a plot or a table, so a history definition is often the only reader.

## Local facts

Do not assume paths — `preset.json` at the root of this installation is the single source of
truth for them (FLAC3D install, console/gui executables, embedded Python, the flac-mcp venv,
the bridge host/port, and the DSH profile). It is generated by `configure.ps1` on the
machine that installed this package.

To re-verify the whole link at any time:

```powershell
.\doctor.ps1        # 9-point check across FLAC3D, bridge, flac-mcp, DSH
.\verify_mcp.ps1    # MCP layer only; safe to run while a solve is in progress
```

Two facts worth knowing that `preset.json` cannot tell you:

- `itasca` is importable **only inside the FLAC3D process** — never from a normal shell.
- A full dynamic case can run for many hours and static equilibrium for tens of minutes, so
  budget wall-clock time rather than assuming a solve is hung.

