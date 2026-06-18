# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [2.0.0]

First public, production-ready release.

### Changed

- **BREAKING (distribution):** the runtime entry point is now
  `litellm-cost-map.js` (was `litellm-cost-map.mjs`). OpenCode auto-discovers
  local plugins with the glob `{plugin,plugins}/*.{ts,js}`, so a `.mjs` entry is
  **not** picked up. The logic library stays `litellm-cost-map-lib.mjs` on
  purpose so the same glob does not load it as a separate plugin.
- The canonical install directory is the plural `plugins/`
  (`~/.config/opencode/plugins/`). The singular `plugin/` still works for
  backward compatibility.
- Documentation rewritten in English and fully genericized (no deployment- or
  organization-specific references).

### Added

- Cross-platform, non-destructive, idempotent installer scripts:
  `scripts/install.ps1` (Windows PowerShell 5.1+) and `scripts/install.sh`
  (macOS/Linux). Both support `--dry-run`, an explicit `--config-dir` override,
  and an opt-in `--reference` mode that edits `opencode.json` additively after
  creating a timestamped backup.
- `INSTALL.md` with three installation methods (in-project script, manual copy,
  `opencode.json` reference), plus verification, troubleshooting, and uninstall.
- `agents/` directory documenting the helper agents used to productionize the
  plugin.
- GitHub Actions CI running `node --test` on pushes and pull requests.
- `LICENSE` (MIT) and packaging metadata (`repository`, `engines`, `files`,
  `exports`).

## [1.0.0]

Initial internal version.

- OpenCode `config` hook that fetches LiteLLM pricing from `/public/model_hub`
  with a BerriAI upstream cost-map fallback, converts per-token prices to
  per-million, and writes `model.cost` for `@ai-sdk/openai-compatible`
  providers.
- Unit tests covering price conversion, hub/upstream parsing, model lookup,
  fallback behavior, TLS opt-in, header building, and URL building.
