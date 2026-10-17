"""flacctl - drive a running FLAC3D from the command line.

Talks straight to the itasca-mcp-bridge HTTP API (bridge >= 0.5.x), so it
needs no MCP client, no Codex, and no third-party packages -- Python
stdlib only.

The bridge must already be running inside FLAC3D:

    import itasca_mcp_bridge
    itasca_mcp_bridge.start()

Usage
-----
    python flacctl.py ping
    python flacctl.py code "print('hi')"
    python flacctl.py code @script.py          # run a local .py file
    python flacctl.py cmd "model new"          # one FLAC command
    python flacctl.py cmd "model new" "zone create brick size 2 2 2"
    python flacctl.py tasks
    python flacctl.py check <task_id>
    python flacctl.py run script.py "my job"   # async task submission
    python flacctl.py interrupt <task_id>

Exit code is 0 on success and 1 on any error, so it composes in scripts.
Add --raw to print the untouched JSON envelope.
"""

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
import uuid

DEFAULT_URL = os.environ.get("FLAC_MCP_BRIDGE_URL", "http://127.0.0.1:9001")
OK_STATUSES = ("success", "ok", "completed", "running", "pending")


def _safe_stdio():
    """Windows 控制台常为 GBK；FLAC3D 回传的输出可能含无法编码的字符，
    不设 replace 会直接抛 UnicodeEncodeError 把整个命令打断。"""
    for stream in (sys.stdout, sys.stderr):
        try:
            stream.reconfigure(errors="replace")
        except Exception:
            pass


def _post(url, command, payload, timeout):
    payload = dict(payload)
    payload["type"] = command
    payload.setdefault("request_id", str(uuid.uuid4()))
    req = urllib.request.Request(
        f"{url.rstrip('/')}/{command}",
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urllib.request.urlopen(req, timeout=timeout) as resp:
        return json.loads(resp.read().decode("utf-8"))


def _print_tasks(payload):
    """Render the task-list envelope (data is a list, plus pagination)."""
    rows = payload.get("data") or []
    page = payload.get("pagination") or {}
    if not rows:
        print("(no tasks)")
    for t in rows:
        elapsed = t.get("elapsed_time")
        elapsed = f"{elapsed:.1f}s" if isinstance(elapsed, (int, float)) else "-"
        print(f"  {t.get('task_id','?'):>8}  {t.get('status','?'):<10} {elapsed:>8}  "
              f"{t.get('name') or t.get('task_type') or ''}")
        if t.get("description"):
            print(f"            {t['description']}")
    if page:
        print(f"  -- {page.get('displayed_count')}/{page.get('total_count')} shown"
              f"{' (more available)' if page.get('has_more') else ''}")


def _emit(payload, show_raw=False, as_tasks=False):
    """Print a bridge envelope. Returns True when the business status is ok."""
    if show_raw:
        print(json.dumps(payload, indent=2, ensure_ascii=False))
        return True

    status = payload.get("status", "unknown")
    data = payload.get("data")

    if as_tasks:
        _print_tasks(payload)
    elif isinstance(data, dict):
        out = data.get("output")
        if out:
            print(out, end="" if out.endswith("\n") else "\n")
        if data.get("result") is not None:
            print("result:", data["result"])
    elif data is not None:
        # some commands (list_tasks) return a bare list
        print(json.dumps(data, indent=2, ensure_ascii=False))

    if status in OK_STATUSES:
        return True

    err = payload.get("error") or {}
    print(f"[{status}] {payload.get('message') or err.get('message') or 'failed'}",
          file=sys.stderr)
    if err.get("details"):
        print(f"  details: {json.dumps(err['details'], ensure_ascii=False)}", file=sys.stderr)
    return False


def _read_code(arg):
    if arg.startswith("@"):
        with open(arg[1:], "r", encoding="utf-8") as fh:
            return fh.read()
    if arg == "-":
        return sys.stdin.read()
    return arg


def _fail(msg):
    print(f"flacctl: {msg}", file=sys.stderr)
    return 1


def main():
    _safe_stdio()
    p = argparse.ArgumentParser(prog="flacctl", description=__doc__.split("\n")[0])
    p.add_argument("--url", default=DEFAULT_URL, help=f"bridge base URL (default {DEFAULT_URL})")
    p.add_argument("--timeout", type=float, default=30.0, help="request timeout seconds")
    p.add_argument("--raw", action="store_true", help="print the raw JSON envelope")
    sub = p.add_subparsers(dest="action", required=True)

    sub.add_parser("ping", help="check the bridge is reachable")

    c = sub.add_parser("code", help="run Python inside FLAC3D")
    c.add_argument("code", help="python source, @file.py, or - for stdin")
    c.add_argument("--timeout-ms", type=int, default=10000)

    m = sub.add_parser("cmd", help="run one or more FLAC commands")
    m.add_argument("commands", nargs="+")

    t = sub.add_parser("tasks", help="list recent tasks")
    t.add_argument("--offset", type=int, default=0)
    t.add_argument("--limit", type=int, default=20)

    k = sub.add_parser("check", help="check a task status")
    k.add_argument("task_id")
    k.add_argument("--limit", type=int, default=64)

    r = sub.add_parser("run", help="submit an async task script")
    r.add_argument("script_path")
    r.add_argument("description", nargs="?", default="cli task")

    i = sub.add_parser("interrupt", help="interrupt a running task")
    i.add_argument("task_id")

    args = p.parse_args()

    try:
        if args.action == "ping":
            payload = _post(args.url, "list_tasks", {"offset": 0, "limit": 1}, args.timeout)
            if not _emit(payload, args.raw, as_tasks=True):
                return 1
            total = (payload.get("pagination") or {}).get("total_count", "?")
            print(f"bridge OK at {args.url}  ({total} tracked task(s))")
            return 0

        if args.action == "code":
            payload = _post(
                args.url, "execute_code",
                {"code": _read_code(args.code), "timeout_ms": args.timeout_ms},
                max(args.timeout, args.timeout_ms / 1000.0 + 5.0),
            )
            return 0 if _emit(payload, args.raw) else 1

        if args.action == "cmd":
            src = "import itasca\n" + "\n".join(
                f"itasca.command({json.dumps(c)})" for c in args.commands
            )
            payload = _post(
                args.url, "execute_code",
                {"code": src, "timeout_ms": int(args.timeout * 1000)},
                args.timeout + 5.0,
            )
            return 0 if _emit(payload, args.raw) else 1

        if args.action == "tasks":
            payload = _post(args.url, "list_tasks",
                            {"offset": args.offset, "limit": args.limit}, args.timeout)
            return 0 if _emit(payload, args.raw, as_tasks=True) else 1

        if args.action == "check":
            payload = _post(args.url, "check_task_status",
                            {"task_id": args.task_id, "skip_newest": 0, "limit": args.limit},
                            args.timeout)
            return 0 if _emit(payload, args.raw) else 1

        if args.action == "run":
            if not os.path.isabs(args.script_path):
                args.script_path = os.path.abspath(args.script_path)
            payload = _post(args.url, "execute_task", {
                "task_id": uuid.uuid4().hex[:6],
                "script_path": args.script_path,
                "description": args.description,
                "source": "cli",
            }, 15.0)
            return 0 if _emit(payload, args.raw) else 1

        if args.action == "interrupt":
            payload = _post(args.url, "interrupt_task", {"task_id": args.task_id}, 10.0)
            return 0 if _emit(payload, args.raw) else 1

    except urllib.error.HTTPError as exc:
        return _fail(f"bridge returned HTTP {exc.code}: {exc.read()[:300]!r}")
    except urllib.error.URLError as exc:
        return _fail(
            f"cannot reach bridge at {args.url} ({exc.reason}).\n"
            "        Is FLAC3D running with 'itasca_mcp_bridge.start()' executed?"
        )
    except TimeoutError:
        return _fail(f"request timed out after {args.timeout}s")
    except OSError as exc:
        return _fail(f"{type(exc).__name__}: {exc}")

    return _fail("no action")


if __name__ == "__main__":
    sys.exit(main())
