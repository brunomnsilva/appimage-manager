#!/usr/bin/env bash
set -Eeuo pipefail

# scripts/build.sh — bundle the shared library into self-contained entrypoints
# so they can be distributed as single files.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CORE="$ROOT/lib/core.sh"
DIST="$ROOT/dist"

mkdir -p "$DIST"

bundle_entry() {
	local src="$1" out="$2"
	local line
	: >"$out"
	while IFS= read -r line || [ -n "$line" ]; do
		if [ "$line" = "# ===BUNDLE_CORE_HERE===" ]; then
			cat "$CORE" >>"$out"
		else
			printf '%s\n' "$line" >>"$out"
		fi
	done <"$src"
	chmod +x "$out"
}

bundle_entry "$ROOT/appimage-install.sh" "$DIST/appimage-install.sh"
bundle_entry "$ROOT/appimage-install-tui.sh" "$DIST/appimage-install-tui.sh"

printf 'Bundled %s and %s\n' \
	"$DIST/appimage-install.sh" "$DIST/appimage-install-tui.sh"
