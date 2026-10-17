# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Planned

- Migration path to [`itasca-mcp`](https://github.com/yusong652/itasca-mcp) once
  the tool/argument differences are verified against a real FLAC3D install.
- Linux/macOS support for the orchestration scripts (currently Windows-only).

## [1.0.0] - 2026-10-16

First public release. The package previously circulated as
`flac3d-ai-bridge-v1.0.zip`; this release is the same functionality, cleaned up
for open source.

### Added

- One-shot install orchestration: `configure.ps1` (environment detection and
  template rendering), `setup.ps1` (bridge + venv + self-check, idempotent),
  `install_bridge.ps1`, `start_bridge.ps1`.
- Diagnostics: `doctor.ps1` (9-point end-to-end check, including the
  bridge/flac-mcp version-pairing trap) and `verify_mcp.ps1` (MCP layer only,
  safe while a solve is running) with a dependency-free `mcp_stdio_probe.js`.
- `flacctl.py`, a stdlib-only CLI that talks to the bridge directly, without
  MCP or an AI client.
- Optional DeepSeek Harness integration: `apply_dsh_mcp.ps1` (idempotent managed
  block in the DSH profile patch, with backup and `-Remove`) and a
  `flac3d` agent preset with a `flac3d-simulation` skill.
- Repository checks in `tests/check_repo.py` (encoding, template/token
  consistency, JSON/YAML rendering, doc links, Python/Node syntax, CLI smoke
  tests, hygiene) and a GitHub Actions workflow running them on Ubuntu and
  Windows.
- Documentation in Chinese (`README.md`) and English (`README.en.md`),
  `NOTICE` for third-party components and trademarks, MIT `LICENSE`.

### Changed

- README rewritten for GitHub: quick start, tool table, version pairing,
  upstream status, security notes, compatibility matrix, uninstall steps.
- Fixed stale paths in the docs (`apply_dsh_mcp.ps1` lives at the repository
  root, not under `dsh\`).
- The `flac3d-simulation` skill no longer points at an unshipped
  `mc_dp_map.py`; the Mohr-Coulomb → Drucker-Prager formulas are stated inline
  with the sanity gate.
- Added a provenance note to the derived `agent.cordis.yml` snapshot.

### Security

- Documented that the bridge listens on `127.0.0.1` without authentication and
  executes arbitrary Python inside FLAC3D, so it must never be exposed.

[Unreleased]: https://github.com/jingjiesu9-code/flac3d-ai-bridge/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/jingjiesu9-code/flac3d-ai-bridge/releases/tag/v1.0.0
