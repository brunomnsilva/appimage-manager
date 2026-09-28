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
- `make bundle` — generate `dist/appimage-manager` and `dist/appimage-manager-tui`.
- `make install` — bundle and copy both into `$(PREFIX)/bin` (default `~/.local/bin`).
- `make uninstall` — remove them from `$(PREFIX)/bin`.
- `make clean` — remove `dist/`.

## Conventions

- Sources are formatted with `shfmt` and must pass `shellcheck`.
- `lib/core.sh` must contain no top-level code; it is sourced and inlined by the bundler.
- The bundler marker in entrypoints is `# ===BUNDLE_CORE_HERE===`.
- The install registry is TSV and every field must be non-empty (`read` collapses
  empty IFS fields and would misalign columns).
- New `lib/core.sh` functions used by `core_*` must be added to `export_all`, or
  `gum spin -- bash -c ...` subshells cannot call them.
- Lifecycle ops best-effort refresh desktop caches via `refresh_desktop_caches`
  (`gtk-update-icon-cache -f -t`, `update-desktop-database`); both tools are
  optional and guarded with `command_exists`.
- Icon typing goes through `icon_extension` (resolves symlinks, sniffs magic;
  `file` is only a fallback) and placement through `icon_dir_for_ext` (SVG ->
  `scalable/apps`, raster -> `256x256/apps`; raster size is not detected).
- Never commit `dist/` or `PLAN.md`.
