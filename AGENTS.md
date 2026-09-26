# AGENTS.md

## Project

`appimage-manager` installs AppImages into the user environment
(`~/Applications`, `~/.local/share/applications`, `~/.local/share/icons`) and
integrates them with the desktop menu. It ships a CLI and a gum-based TUI that
share a single library.

## Layout

- `lib/core.sh` — shared library (functions only, no side effects).
- `appimage-manager.sh` — CLI entrypoint.
- `appimage-manager-tui.sh` — TUI entrypoint (requires `gum`).
- `scripts/build.sh` — bundles `lib/core.sh` into standalone `dist/` entrypoints.
- `tests/run-tests.sh` — headless test harness.

## Commands

- `make test` — shellcheck + shfmt check + bundle + tests.
- `make lint` — shellcheck only.
- `make fmt` — `shfmt -w` on all sources.
- `make bundle` — generate `dist/appimage-manager.sh` and `dist/appimage-manager-tui.sh`.
- `make clean` — remove `dist/`.

## Conventions

- Sources are formatted with `shfmt` and must pass `shellcheck`.
- `lib/core.sh` must contain no top-level code; it is sourced and inlined by the bundler.
- The bundler marker in entrypoints is `# ===BUNDLE_CORE_HERE===`.
- The install registry is TSV and every field must be non-empty (`read` collapses
  empty IFS fields and would misalign columns).
- Never commit `dist/` or `PLAN.md`.
