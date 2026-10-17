#!/usr/bin/env python3
"""Repository self-checks that need no FLAC3D, no Windows and no network.

Run from the repository root (this is what CI runs on Ubuntu and Windows):

    python -m pip install -r requirements-dev.txt
    python tests/check_repo.py

Exit code 0 means every check passed. The checks mirror the failure modes that
would otherwise only show up on a Windows machine with FLAC3D installed:

  * .ps1 files must be ASCII-only with no BOM (PowerShell 5.1 reads them as ANSI)
  * every @@TOKEN@@ in a template must be defined by configure.ps1, and the
    rendered JSON/YAML must actually parse
  * the agent preset and its skill must be structurally valid
  * Markdown links in the READMEs must point at files that exist
  * generated, machine-specific files must stay out of git
  * no absolute user paths or credentials in the tree
"""

from __future__ import annotations

import json
import os
import py_compile
import re
import shutil
import subprocess
import sys
import tempfile

try:
    import yaml
except ImportError:  # pragma: no cover - CI installs it
    sys.exit("PyYAML is required: python -m pip install -r requirements-dev.txt")


ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SELF = os.path.abspath(__file__)

VERBOSE = any(arg in ("-v", "--verbose") for arg in sys.argv[1:])

failures: list[tuple[str, str]] = []
warnings: list[str] = []
SECTION = ""
checked = 0


# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
def rel(path: str) -> str:
    return os.path.relpath(path, ROOT)


def section(title: str) -> None:
    global SECTION
    SECTION = title
    print(f"\n== {title} ==") if VERBOSE else None


def check(cond, msg: str) -> bool:
    global checked
    checked += 1
    if cond:
        if VERBOSE:
            print(f"PASS  {msg}")
    else:
        failures.append((SECTION, msg))
        print(f"FAIL  [{SECTION}] {msg}")
    return bool(cond)


def warn(msg: str) -> None:
    warnings.append(msg)
    print(f"WARN  {msg}")


def read_text(path: str) -> str:
    with open(path, "r", encoding="utf-8", newline="") as fh:
        return fh.read()


def walk(suffixes=None, skip_dirs=(".git", "__pycache__", ".venv-flac", "_piptmp", "_logs")):
    for base, dirs, files in os.walk(ROOT):
        dirs[:] = sorted(d for d in dirs if d not in skip_dirs)
        for name in sorted(files):
            if suffixes and not name.endswith(suffixes):
                continue
            yield os.path.join(base, name)


class PermissiveLoader(yaml.SafeLoader):
    """YAML loader that maps unknown tags (``!!js``) back to their source text."""


def _unknown_tag(loader, tag_suffix, node):
    if isinstance(node, yaml.ScalarNode):
        return {"__tag__": tag_suffix, "value": loader.construct_scalar(node)}
    if isinstance(node, yaml.SequenceNode):
        return loader.construct_sequence(node)
    return loader.construct_mapping(node)


PermissiveLoader.add_multi_constructor("", _unknown_tag)
PermissiveLoader.add_multi_constructor("tag:yaml.org,2002:", _unknown_tag)


def load_yaml(text: str):
    return yaml.load(text, Loader=PermissiveLoader)


# --------------------------------------------------------------------------- #
# 1. PowerShell encoding rules
# --------------------------------------------------------------------------- #
def check_powershell_encoding() -> None:
    section(".ps1 encoding (PowerShell 5.1 reads BOM-less files as ANSI)")
    files = list(walk((".ps1",)))
    check(bool(files), "found .ps1 files to check")
    for path in files:
        with open(path, "rb") as fh:
            raw = fh.read()
        non_ascii = sum(1 for b in raw if b > 0x7F)
        check(non_ascii == 0, f"{rel(path)} is ASCII-only ({non_ascii} non-ASCII bytes)")
        check(raw[:3] != b"\xef\xbb\xbf", f"{rel(path)} has no UTF-8 BOM")
        check(b"\r\n" not in raw, f"{rel(path)} uses LF line endings")


# --------------------------------------------------------------------------- #
# 2. template tokens agree with configure.ps1
# --------------------------------------------------------------------------- #
TEMPLATES = [
    "preset.template.json",
    "flac3d/run_bridge.dat.template",
    "dsh/mcp-flac3d.patch.yml.template",
]

DUMMY = {
    "@@FLAC3D_DIR@@": r"C:\Itasca\FLAC3D700",
    "@@FLAC3D_CONSOLE@@": r"C:\Itasca\FLAC3D700\exe64\flac3d700_console.exe",
    "@@FLAC3D_GUI@@": r"C:\Itasca\FLAC3D700\exe64\flac3d700_gui.exe",
    "@@FLAC3D_PYTHON@@": r"C:\Itasca\FLAC3D700\exe64\python36\python.exe",
    "@@FLAC3D_VERSION@@": "7.00",
    "@@FLAC3D_PROJECT@@": r"D:\work\my-model",
    "@@BRIDGE_VERSION@@": "0.5.5",
    "@@BRIDGE_HOST@@": "127.0.0.1",
    "@@BRIDGE_PORT@@": "9001",
    "@@FLAC_MCP_VERSION@@": "0.5.2",
    "@@VENV_DIR@@": r"C:\tools\flac3d-ai-bridge\.venv-flac",
    "@@MCP_EXE@@": r"C:\tools\flac3d-ai-bridge\.venv-flac\Scripts\flac-mcp.exe",
    "@@DSH_ENABLED@@": "true",
    "@@DSH_HOME@@": r"C:\Users\example\.dsh",
    "@@DSH_PROFILE@@": "desktop",
    "@@DSH_PROFILE_DIR@@": r"C:\Users\example\.dsh\profiles\desktop",
    "@@DSH_PATCH_FILE@@": r"C:\Users\example\.dsh\profiles\desktop\cordis.patch.yml",
    "@@HOST_PYTHON@@": r"C:\Python311\python.exe",
    "@@PRESET_DIR@@": r"C:\tools\flac3d-ai-bridge",
}

TOKEN_RE = re.compile(r"@@[A-Z0-9_]+@@")


def render(template_text: str, json_escape: bool) -> str:
    text = template_text
    for token, value in DUMMY.items():
        text = text.replace(token, value.replace("\\", "\\\\") if json_escape else value)
    return text


def check_templates() -> None:
    section("templates vs configure.ps1 token map")
    configure = read_text(os.path.join(ROOT, "configure.ps1"))
    defined = set(re.findall(r"'(@@[A-Z0-9_]+@@)'\s*=", configure))
    check(bool(defined), f"configure.ps1 defines {len(defined)} substitution tokens")

    used: set[str] = set()
    for template in TEMPLATES:
        path = os.path.join(ROOT, template)
        if not check(os.path.isfile(path), f"{template} exists"):
            continue
        text = read_text(path)
        tokens = set(TOKEN_RE.findall(text))
        used |= tokens
        missing = sorted(tokens - defined)
        check(not missing, f"{template}: every token is defined in configure.ps1"
                           + (f" (missing: {', '.join(missing)})" if missing else ""))

    unused = sorted(defined - used)
    if unused:
        warn(f"tokens defined but unused by templates: {', '.join(unused)}")

    check(used == defined or not (defined - used),
          "every token configure.ps1 defines is consumed by a template")


def check_render() -> None:
    section("rendered artifacts parse")

    preset_t = read_text(os.path.join(ROOT, "preset.template.json"))
    preset = json.loads(render(preset_t, json_escape=True))
    for dotted in ("flac3d.version", "flac3d.consoleExe", "flac3d.pythonExe",
                   "mcpServer.exe", "hostPython", "presetDir"):
        node = preset
        for part in dotted.split("."):
            node = node[part]
        check(bool(node), f"rendered preset.json field {dotted!r} is non-empty")
    check(preset["bridge"]["package"] == "itasca-mcp-bridge", "preset.json pins itasca-mcp-bridge")
    check(preset["mcpServer"]["package"] == "flac-mcp", "preset.json pins flac-mcp")
    check(preset["bridge"]["version"] == preset["bridge"]["version"], "bridge version is a string")

    dat_t = read_text(os.path.join(ROOT, "flac3d/run_bridge.dat.template"))
    dat = render(dat_t, json_escape=False)
    check("program call '" in dat, "run_bridge.dat uses the FLAC3D command console syntax")
    check(not TOKEN_RE.search(dat), "run_bridge.dat has no unsubstituted tokens")

    patch_t = read_text(os.path.join(ROOT, "dsh/mcp-flac3d.patch.yml.template"))
    patch_text = render(patch_t, json_escape=False)
    check(not TOKEN_RE.search(patch_text), "mcp-flac3d.patch.yml has no unsubstituted tokens")
    patch = load_yaml(patch_text)
    check(isinstance(patch, list) and len(patch) == 1, "patch renders to a single-row YAML list")
    check(patch_text.count("# >>> flac3d-mcp") == 1 and patch_text.count("# <<< flac3d-mcp") == 1,
          "patch has exactly one managed block")
    rows = (patch[0].get("insert") or []) if isinstance(patch[0], dict) else []
    check(bool(rows), "patch row uses an 'insert:' entry")
    if rows:
        row = rows[0]
        check(row.get("name") == "@deepseek-ai/dsh-mcp-client",
              "patch mounts @deepseek-ai/dsh-mcp-client")
        cfg = row.get("config") or {}
        check(cfg.get("serverName") == "flac3d", "patch serverName is flac3d")
        check(cfg.get("transport") == "stdio", "patch transport is stdio")
        check(cfg.get("command") == DUMMY["@@MCP_EXE@@"], "patch command is the rendered flac-mcp exe")
        check(cfg.get("failOnStartupError") is False,
              "patch keeps failOnStartupError false so a closed FLAC3D cannot block startup")


# --------------------------------------------------------------------------- #
# 3. agent preset structure
# --------------------------------------------------------------------------- #
def check_agent_preset() -> None:
    section("agent preset")
    preset_dir = os.path.join(ROOT, "dsh", "agent_preset", "flac3d")

    meta_path = os.path.join(preset_dir, "preset.yml")
    if check(os.path.isfile(meta_path), "dsh/agent_preset/flac3d/preset.yml exists"):
        meta = load_yaml(read_text(meta_path))
        check(isinstance(meta, dict), "preset.yml is a mapping")
        check(bool(meta.get("name")), "preset.yml has a display name")
        check(bool(meta.get("description")), "preset.yml has a description")

    agent_path = os.path.join(preset_dir, "agent.cordis.yml")
    if not check(os.path.isfile(agent_path), "agent.cordis.yml exists"):
        return
    agent_text = read_text(agent_path)
    check(agent_text.startswith("# PROVENANCE:"),
          "agent.cordis.yml carries the generated-snapshot provenance header")
    rows = load_yaml(agent_text)
    if not check(isinstance(rows, list), "agent.cordis.yml is a list of plugin rows"):
        return
    ids = [row.get("id") for row in rows if isinstance(row, dict)]
    check(len(ids) == len(set(ids)), f"agent.cordis.yml row ids are unique ({len(ids)} rows)")

    for want in ("persona", "agent-instructions", "skill-filesystem", "tool-skill",
                 "planning", "compaction", "delegation"):
        check(want in ids, f"agent.cordis.yml contains the {want!r} row")

    for row in rows:
        if not isinstance(row, dict) or row.get("id") == "persona":
            continue
        name = row.get("name") or ""
        if name and name != "cordis:group":
            check(name.startswith("@deepseek-ai/"),
                  f"row {row.get('id')!r} mounts a DSH plugin ({name})")

    persona = next((r for r in rows if isinstance(r, dict) and r.get("id") == "persona"), None)
    if check(persona is not None, "persona row is present"):
        prefix = (persona.get("config") or {}).get("prefix") or ""
        check("FLAC3D" in prefix, "persona prefix mentions FLAC3D")
        check("flac3d-simulation" in prefix, "persona prefix tells the agent to load the skill")
        check("mcp__flac3d__" in prefix, "persona prefix names the tool prefix")

    skill_row = next((r for r in rows if isinstance(r, dict) and r.get("id") == "skill-filesystem"), None)
    if check(skill_row is not None, "skill-filesystem row is present"):
        dirs = (skill_row.get("config") or {}).get("customSkillDirs") or []
        check(bool(dirs), "skill-filesystem wires customSkillDirs (otherwise the preset contributes no skill)")
        check(any("skills/" in json.dumps(d) for d in dirs),
              "customSkillDirs resolves the preset's own skills/ directory")


def check_skill() -> None:
    section("flac3d-simulation skill")
    skill_dir = os.path.join(ROOT, "dsh", "agent_preset", "flac3d", "skills")
    if not check(os.path.isdir(skill_dir), "skills/ directory exists"):
        return
    skill_md = os.path.join(skill_dir, "flac3d-simulation", "SKILL.md")
    if not check(os.path.isfile(skill_md), "skills/flac3d-simulation/SKILL.md exists"):
        return
    text = read_text(skill_md)
    if not check(text.startswith("---\n"), "SKILL.md starts with YAML frontmatter"):
        return
    end = text.find("\n---", 3)
    if not check(end > 0, "SKILL.md frontmatter is terminated"):
        return
    fm = yaml.safe_load(text[3:end]) or {}
    check(fm.get("name") == "flac3d-simulation", "SKILL.md frontmatter name matches its directory")
    desc = fm.get("description") or ""
    check(desc.startswith("Use when"), "SKILL.md description starts with 'Use when'")
    check(not re.search(r"\bmc_dp_map\b", text),
          "SKILL.md does not reference the unshipped mc_dp_map.py helper")
    for topic in ("RADIANS", "execute_task", "model new"):
        check(topic in text, f"SKILL.md documents the {topic!r} constraint")


# --------------------------------------------------------------------------- #
# 4. documentation links
# --------------------------------------------------------------------------- #
def check_docs() -> None:
    section("documentation")
    link_re = re.compile(r"!?\[[^\]]*\]\(([^)\s]+)(?:\s+\"[^\"]*\")?\)")
    for doc in ("README.md", "README.en.md", "CHANGELOG.md", "NOTICE"):
        path = os.path.join(ROOT, doc)
        if not check(os.path.isfile(path), f"{doc} exists"):
            continue
        text = read_text(path)
        check(len(text.splitlines()) > 20, f"{doc} is non-trivial ({len(text.splitlines())} lines)")
        for target in link_re.findall(text):
            if target.startswith(("http://", "https://", "mailto:", "#")):
                continue
            clean = target.split("#", 1)[0]
            if not clean:
                continue
            resolved = os.path.normpath(os.path.join(ROOT, clean))
            check(os.path.exists(resolved), f"{doc}: link target {clean!r} exists")

    readme = read_text(os.path.join(ROOT, "README.md"))
    for command in ("configure.ps1", "setup.ps1", "doctor.ps1", "verify_mcp.ps1",
                    "start_bridge.ps1", "apply_dsh_mcp.ps1", "flacctl.py"):
        check(command in readme, f"README.md documents {command}")
        check(os.path.exists(os.path.join(ROOT, command)), f"{command} exists at the repository root")


# --------------------------------------------------------------------------- #
# 5. syntax checks and CLI smoke tests
# --------------------------------------------------------------------------- #
def check_python() -> None:
    section("Python syntax")
    py_files = list(walk((".py",)))
    check(bool(py_files), f"found {len(py_files)} Python files")
    for path in py_files:
        try:
            with tempfile.TemporaryDirectory() as tmp:
                py_compile.compile(path, cfile=os.path.join(tmp, "out.pyc"), doraise=True)
            check(True, f"{rel(path)} compiles")
        except py_compile.PyCompileError as exc:
            check(False, f"{rel(path)} compiles: {exc.msg}")


def check_node() -> None:
    section("Node probe syntax")
    node = shutil.which("node")
    probe = os.path.join(ROOT, "mcp_stdio_probe.js")
    if not node:
        warn("node not on PATH; skipping mcp_stdio_probe.js syntax check")
        return
    proc = subprocess.run([node, "--check", probe], capture_output=True, text=True, timeout=60)
    check(proc.returncode == 0, "mcp_stdio_probe.js passes `node --check`"
                               + (f": {proc.stderr.strip()}" if proc.returncode else ""))


def check_cli() -> None:
    section("flacctl.py smoke tests")
    cli = os.path.join(ROOT, "flacctl.py")
    proc = subprocess.run([sys.executable, cli, "--help"], capture_output=True, text=True, timeout=120)
    check(proc.returncode == 0, "flacctl.py --help exits 0")
    for action in ("ping", "code", "cmd", "tasks", "check", "run", "interrupt"):
        check(action in proc.stdout, f"flacctl.py --help lists the {action!r} subcommand")

    # Nothing is listening on the discard port, so this must fail cleanly (exit 1,
    # readable message) instead of raising a traceback.
    proc = subprocess.run([sys.executable, cli, "--url", "http://127.0.0.1:9",
                           "--timeout", "2", "ping"], capture_output=True, text=True, timeout=120)
    combined = proc.stdout + proc.stderr
    check(proc.returncode == 1, "flacctl.py ping exits 1 when the bridge is unreachable")
    check("Traceback" not in combined, "flacctl.py reports an unreachable bridge without a traceback")
    check("cannot reach bridge" in combined.lower() or "refused" in combined.lower(),
          "flacctl.py explains how to fix an unreachable bridge")


# --------------------------------------------------------------------------- #
# 6. repository hygiene
# --------------------------------------------------------------------------- #
GENERATED = ("preset.json", "flac3d/run_bridge.dat", "dsh/mcp-flac3d.patch.yml")

SKIP_SCAN = {
    ".git", "__pycache__", ".venv-flac", "_piptmp", "_logs",
}
TEXT_SUFFIXES = (".md", ".ps1", ".py", ".js", ".json", ".yml", ".yaml", ".template",
                 ".txt", ".example", ".cfg", ".ini")
PERSONAL_PATTERNS = [
    (re.compile(r"[A-Za-z]:\\Users\\"), "absolute Windows user path"),
    (re.compile(r"/Users/[A-Za-z]"), "absolute macOS home path"),
    (re.compile(r"/home/[a-z]"), "absolute Linux home path"),
]
SECRET_PATTERNS = [
    (re.compile(r"ghp_[A-Za-z0-9]{30,}"), "GitHub personal access token"),
    (re.compile(r"github_pat_[A-Za-z0-9_]{20,}"), "GitHub fine-grained token"),
    (re.compile(r"sk-[A-Za-z0-9]{20,}"), "OpenAI-style API key"),
    (re.compile(r"AKIA[0-9A-Z]{16}"), "AWS access key id"),
    (re.compile(r"-----BEGIN [A-Z ]*PRIVATE KEY-----"), "private key"),
]


def check_hygiene() -> None:
    section("repository hygiene")
    gitignore = read_text(os.path.join(ROOT, ".gitignore"))
    for path in GENERATED:
        check(path.replace("/", "\\") in gitignore or path in gitignore,
              f".gitignore ignores generated file {path}")
        full = os.path.join(ROOT, path)
        if os.path.exists(full) and os.path.isdir(os.path.join(ROOT, ".git")):
            proc = subprocess.run(["git", "check-ignore", "-q", path],
                                  cwd=ROOT, capture_output=True, text=True)
            check(proc.returncode == 0, f"{path} is actually ignored by git")

    pyc = list(walk((".pyc",)))
    check(not pyc, f"no compiled .pyc files committed ({len(pyc)} found)")

    scanned = 0
    for path in walk():
        if os.path.abspath(path) == SELF:
            continue
        if os.path.dirname(path) != ROOT and os.path.basename(path).startswith(".git"):
            continue
        name = os.path.basename(path)
        if not (name in ("LICENSE", "NOTICE", ".gitignore", ".gitattributes",
                         "requirements-dev.txt", "CHANGELOG.md")
                or name.endswith(TEXT_SUFFIXES)):
            continue
        try:
            text = read_text(path)
        except UnicodeDecodeError:
            warn(f"skipped non-UTF-8 file: {rel(path)}")
            continue
        scanned += 1
        for pattern, label in PERSONAL_PATTERNS:
            match = pattern.search(text)
            check(match is None, f"{rel(path)} contains no {label}")
        for pattern, label in SECRET_PATTERNS:
            match = pattern.search(text)
            check(match is None, f"{rel(path)} contains no {label}")

    check(scanned >= 15, f"scanned {scanned} text files for paths and secrets")


# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
def main() -> int:
    print(f"flac3d-ai-bridge repository checks\nroot: {ROOT}")
    if not VERBOSE:
        print("(passing checks are silent; re-run with --verbose to see each one)")
    check_powershell_encoding()
    check_templates()
    check_render()
    check_agent_preset()
    check_skill()
    check_docs()
    check_python()
    check_node()
    check_cli()
    check_hygiene()

    print("\n" + "=" * 60)
    print(f"{checked} checks, {len(failures)} failed, {len(warnings)} warning(s)")
    if failures:
        print("\nFAILED:")
        last_section = None
        for sec, msg in failures:
            if sec != last_section:
                print(f"\n  [{sec}]")
                last_section = sec
            print(f"    - {msg}")
        return 1
    print("All checks passed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
