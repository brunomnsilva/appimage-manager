#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=lib/core.sh
source "$ROOT/lib/core.sh"
export_all

TESTHOME="$(mktemp -d)"
trap 'rm -rf "$TESTHOME"' EXIT
export HOME="$TESTHOME"
export XDG_DATA_HOME="$TESTHOME/.local/share"
# Test stubs are shell scripts, not real AppImages; skip validation for the
# install/uninstall flows (the real check is tested separately below).
export APPIMAGE_MANAGER_SKIP_VALIDATE=1

# Stub the optional cache-refresh tools so the suite is deterministic (they may
# be absent on CI) and we can assert refresh_desktop_caches invokes them.
STUBBIN="$TESTHOME/stubbin"
mkdir -p "$STUBBIN"
export CACHE_LOG="$TESTHOME/cache-calls.log"
: >"$CACHE_LOG"
for cache_tool in gtk-update-icon-cache update-desktop-database; do
	cat >"$STUBBIN/$cache_tool" <<EOF
#!/usr/bin/env bash
printf '%s\n' "$cache_tool" >>"\$CACHE_LOG"
exit 0
EOF
	chmod +x "$STUBBIN/$cache_tool"
done
export PATH="$STUBBIN:$PATH"

pass=0
fail=0

ok() {
	printf 'PASS  %s\n' "$1"
	pass=$((pass + 1))
}
bad() {
	printf 'FAIL  %s\n' "$1"
	[ -n "${2:-}" ] && printf '      %s\n' "$2"
	fail=$((fail + 1))
}

assert_eq() { if [ "$1" = "$2" ]; then ok "$3"; else bad "$3" "expected [$2] got [$1]"; fi; }
assert_file() { if [ -f "$1" ]; then ok "$2"; else bad "$2" "missing file: $1"; fi; }
assert_nofile() { if [ ! -e "$1" ]; then ok "$2"; else bad "$2" "unexpected file: $1"; fi; }
assert_grep() { if grep -q -e "$1" "$2"; then ok "$3"; else bad "$3" "pattern not found: $1"; fi; }

# --- Fixtures --------------------------------------------------------------

FIX="$TESTHOME/fixtures"
mkdir -p "$FIX"

stub="$FIX/Stub App.AppImage"
printf '#!/usr/bin/env bash\nexit 0\n' >"$stub"
chmod +x "$stub"

nsapp="$FIX/Needs Sandbox.AppImage"
cat >"$nsapp" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "--no-sandbox" ] && exit 0
done
exit 1
EOF
chmod +x "$nsapp"

icon="$FIX/icon.png"
printf 'not-a-real-png' >"$icon"

# A file with the ELF + AppImage "AI" magic at offset 8 (not actually runnable).
realapp="$FIX/Real.AppImage"
printf '\x7f\x45\x4c\x46\x02\x01\x01\x00AI' >"$realapp"

svgicon="$FIX/icon.svg"
printf '<svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"/>' >"$svgicon"

# Extensionless icon fixtures for icon_extension content sniffing.
noext_svg="$FIX/noext-svg"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$noext_svg"
noext_png="$FIX/noext-png"
printf '\x89PNG\r\n\x1a\n' >"$noext_png"

# A `.DirIcon` symlink to an SVG (common in AppImages, e.g. WaveScope).
dircicon_dir="$FIX/diricon"
mkdir -p "$dircicon_dir"
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >"$dircicon_dir/wavescope.svg"
ln -sf wavescope.svg "$dircicon_dir/.DirIcon"

# Stub "AppImage" whose --appimage-extract emits a symlinked .DirIcon + SVG.
extract_stub="$FIX/Extractor.AppImage"
cat >"$extract_stub" <<'EOF'
#!/usr/bin/env bash
[ "$1" = "--appimage-extract" ] || exit 1
mkdir -p squashfs-root
printf '<svg xmlns="http://www.w3.org/2000/svg"/>' >squashfs-root/wavescope.svg
ln -sf wavescope.svg squashfs-root/.DirIcon
exit 0
EOF
chmod +x "$extract_stub"

# --- is_appimage validation -------------------------------------------------

if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	is_appimage "$realapp"
); then
	ok "is_appimage accepts ELF+AI magic"
else
	bad "is_appimage accepts ELF+AI magic"
fi

if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	is_appimage "$icon"
); then
	bad "is_appimage rejects non-AppImage"
else
	ok "is_appimage rejects non-AppImage"
fi

if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	core_install --appimage "$icon" --name "Bad" >/dev/null 2>&1
); then
	bad "core_install hard-rejects non-AppImage"
else
	ok "core_install hard-rejects non-AppImage"
fi

# --- Pure functions --------------------------------------------------------

assert_eq "$(slugify 'My App_Name')" 'my-app-name' "slugify basic"
assert_eq "$(slugify '  Foo!!Bar  ')" 'foo-bar' "slugify strips invalid chars"
assert_eq "$(abs_path "$TESTHOME/x")" "$TESTHOME/x" "abs_path identity"

# --- icon_extension --------------------------------------------------------

assert_eq "$(icon_extension "$svgicon")" '.svg' "icon_extension keeps named .svg"
assert_eq "$(icon_extension "$noext_svg")" '.svg' "icon_extension sniffs extensionless SVG"
assert_eq "$(icon_extension "$noext_png")" '.png' "icon_extension sniffs extensionless PNG"
assert_eq "$(icon_extension "$dircicon_dir/.DirIcon")" '.svg' "icon_extension resolves symlinked .DirIcon"

# --- Install --------------------------------------------------------------

: >"$CACHE_LOG"
if (core_install --appimage "$stub" --name "Test App" --categories "Office;" --comment "A test app" --exec-args "--foo" --force >/dev/null 2>&1); then
	ok "core_install succeeds"
else
	bad "core_install succeeds"
fi

assert_file "$HOME/Applications/Test App.AppImage" "install copies AppImage"
assert_file "$HOME/.local/share/applications/test-app.desktop" "install writes desktop entry"
assert_file "$HOME/.local/bin/test-app-appimage-launcher" "install writes wrapper"
assert_file "$HOME/.local/share/appimage-manager/registry.tsv" "install writes registry"
assert_grep '^gtk-update-icon-cache$' "$CACHE_LOG" "install refreshes icon cache"
assert_grep '^update-desktop-database$' "$CACHE_LOG" "install refreshes desktop database"

desktop="$HOME/.local/share/applications/test-app.desktop"
assert_grep '^Name=Test App$' "$desktop" "desktop Name correct"
assert_grep '^Categories=Office;$' "$desktop" "desktop Categories correct"
assert_grep '^Icon=.*Test App.AppImage$' "$desktop" "desktop Icon falls back to AppImage"
assert_grep '--foo' "$HOME/.local/bin/test-app-appimage-launcher" "wrapper contains exec-args"

# --- Overwrite / --force ---------------------------------------------------

if (core_install --appimage "$stub" --name "Test App" >/dev/null 2>&1); then
	bad "install without --force should fail"
else
	ok "install without --force fails when dest exists"
fi

if (core_install --appimage "$stub" --name "Test App" --force >/dev/null 2>&1); then
	ok "install with --force overwrites"
else
	bad "install with --force overwrites"
fi

# --- Custom icon -----------------------------------------------------------

if (core_install --appimage "$stub" --name "Iconed App" --icon "$icon" --force >/dev/null 2>&1); then
	ok "install with custom icon succeeds"
else
	bad "install with custom icon succeeds"
fi

assert_file "$HOME/.local/share/icons/hicolor/256x256/apps/iconed-app.png" "custom icon copied"
assert_grep '^Icon=iconed-app$' "$HOME/.local/share/applications/iconed-app.desktop" "desktop Icon uses theme name"

if (core_install --appimage "$stub" --name "Svg App" --icon "$svgicon" --force >/dev/null 2>&1); then
	ok "install with custom SVG icon succeeds"
else
	bad "install with custom SVG icon succeeds"
fi
assert_file "$HOME/.local/share/icons/hicolor/scalable/apps/svg-app.svg" "custom SVG icon placed in scalable"
assert_grep '^Icon=svg-app$' "$HOME/.local/share/applications/svg-app.desktop" "desktop Icon uses theme name for SVG"

# --- Icon extraction (symlinked .DirIcon, e.g. WaveScope) -------------------

extracted=$(
	try_extract_icon_from_appimage "$extract_stub" "wavescope" &&
		printf '%s' "$ICON_TARGET"
) || true
assert_eq "$extracted" "$HOME/.local/share/icons/hicolor/scalable/apps/wavescope.svg" "extracts symlinked SVG icon to scalable bucket"
assert_file "$HOME/.local/share/icons/hicolor/scalable/apps/wavescope.svg" "extracted SVG icon written"
assert_grep '<svg' "$HOME/.local/share/icons/hicolor/scalable/apps/wavescope.svg" "extracted SVG content preserved"

# --- Wrapper --no-sandbox fallback ------------------------------------------

(core_install --appimage "$nsapp" --name "Needs Sandbox" --force >/dev/null 2>&1)

wrapper="$HOME/.local/bin/needs-sandbox-appimage-launcher"
assert_file "$wrapper" "fallback wrapper exists"
if "$wrapper" >/dev/null 2>&1; then
	ok "wrapper falls back to --no-sandbox"
else
	bad "wrapper falls back to --no-sandbox"
fi

# --- Subshell invocation (gum spin mechanism) --------------------------------

: >"$CACHE_LOG"
if bash -c 'set -Eeuo pipefail; core_install "$@"' _ --appimage "$stub" --name "Subshell App" --force >/dev/null 2>&1; then
	ok "core_install callable in subshell via export_all"
else
	bad "core_install callable in subshell via export_all"
fi
assert_grep '^gtk-update-icon-cache$' "$CACHE_LOG" "cache refresh exported to subshell"

# --- List -------------------------------------------------------------------

core_list >"$FIX/list.tsv"
assert_grep $'^test-app\t' "$FIX/list.tsv" "list includes test-app"
assert_grep $'^needs-sandbox\t' "$FIX/list.tsv" "list includes needs-sandbox"
assert_grep $'^subshell-app\t' "$FIX/list.tsv" "list includes subshell-app"

# --- Uninstall --------------------------------------------------------------

: >"$CACHE_LOG"
if (core_uninstall "test-app" >/dev/null 2>&1); then
	ok "core_uninstall succeeds"
else
	bad "core_uninstall succeeds"
fi

assert_nofile "$HOME/Applications/Test App.AppImage" "uninstall removes AppImage"
assert_nofile "$HOME/.local/share/applications/test-app.desktop" "uninstall removes desktop entry"
assert_nofile "$HOME/.local/bin/test-app-appimage-launcher" "uninstall removes wrapper"
if grep -q $'^test-app\t' "$HOME/.local/share/appimage-manager/registry.tsv" 2>/dev/null; then
	bad "uninstall removes registry row"
else
	ok "uninstall removes registry row"
fi
assert_grep '^gtk-update-icon-cache$' "$CACHE_LOG" "uninstall refreshes icon cache"
assert_grep '^update-desktop-database$' "$CACHE_LOG" "uninstall refreshes desktop database"

# --- Legacy scan (pre-registry) ----------------------------------------------

rm -f "$HOME/.local/share/appimage-manager/registry.tsv"
core_list >"$FIX/list-legacy.tsv"
assert_grep $'^iconed-app\t' "$FIX/list-legacy.tsv" "legacy scan finds iconed-app"
assert_grep $'\t0$' "$FIX/list-legacy.tsv" "legacy rows marked untracked"

# --- CLI entrypoint ---------------------------------------------------------

if bash "$ROOT/appimage-manager.sh" --name "CLI App" "$stub" >/dev/null 2>&1; then
	ok "CLI entrypoint installs"
else
	bad "CLI entrypoint installs"
fi
assert_file "$HOME/Applications/CLI App.AppImage" "CLI entrypoint copies AppImage"

if bash "$ROOT/appimage-manager.sh" --help >/dev/null 2>&1; then
	ok "CLI --help exits 0"
else
	bad "CLI --help exits 0"
fi

if bash "$ROOT/appimage-manager.sh" /nonexistent.AppImage >/dev/null 2>&1; then
	bad "CLI errors on missing file"
else
	ok "CLI errors on missing file"
fi

# --- CLI --list -------------------------------------------------------------

if bash "$ROOT/appimage-manager.sh" --list >"$FIX/cli-list.out" 2>&1; then
	ok "CLI --list exits 0"
else
	bad "CLI --list exits 0"
fi
assert_grep 'CLI App' "$FIX/cli-list.out" "CLI --list shows installed app"
tilde='~'
assert_grep "${tilde}/Applications/CLI App.AppImage" "$FIX/cli-list.out" "CLI --list shortens home"

empty_home="$(mktemp -d)"
if HOME="$empty_home" XDG_DATA_HOME="$empty_home/.local/share" \
	bash "$ROOT/appimage-manager.sh" --list >"$FIX/cli-list-empty.out" 2>&1; then
	ok "CLI --list exits 0 with empty registry"
else
	bad "CLI --list exits 0 with empty registry"
fi
assert_grep 'No apps installed' "$FIX/cli-list-empty.out" "CLI --list reports none installed"
rm -rf "$empty_home"

# --- Update -----------------------------------------------------------------

up_stub="$FIX/Updatable.AppImage"
printf '#!/usr/bin/env bash\necho old\n' >"$up_stub"
chmod +x "$up_stub"
core_install --appimage "$up_stub" --name "Updatable" --force >/dev/null 2>&1

up_new="$FIX/Updatable-2.AppImage"
printf '#!/usr/bin/env bash\necho new\n' >"$up_new"

: >"$CACHE_LOG"
if (core_update --target updatable --appimage "$up_new" >/dev/null 2>&1); then
	ok "core_update succeeds"
else
	bad "core_update succeeds"
fi
assert_grep 'echo new' "$HOME/Applications/Updatable.AppImage" "core_update replaces AppImage content"
assert_file "$HOME/.local/share/applications/updatable.desktop" "core_update keeps desktop entry"
assert_file "$HOME/.local/bin/updatable-appimage-launcher" "core_update keeps wrapper"
assert_grep $'^updatable\t' "$HOME/.local/share/appimage-manager/registry.tsv" "core_update keeps registry row"
assert_grep '^gtk-update-icon-cache$' "$CACHE_LOG" "update refreshes icon cache"
assert_grep '^update-desktop-database$' "$CACHE_LOG" "update refreshes desktop database"

if (core_update --target nope --appimage "$up_new" >/dev/null 2>&1); then
	bad "core_update rejects unknown target"
else
	ok "core_update rejects unknown target"
fi

icon2="$FIX/icon2.png"
printf 'not-a-real-png-2' >"$icon2"
if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	core_update --target updatable --appimage "$icon2" >/dev/null 2>&1
); then
	bad "core_update rejects non-AppImage"
else
	ok "core_update rejects non-AppImage"
fi

if (core_update --target updatable --appimage "$HOME/Applications/Updatable.AppImage" >/dev/null 2>&1); then
	bad "core_update rejects the already-installed file"
else
	ok "core_update rejects the already-installed file"
fi

if (core_update --target updatable --appimage "$up_new" --icon "$icon2" >/dev/null 2>&1); then
	ok "core_update with --icon succeeds"
else
	bad "core_update with --icon succeeds"
fi
assert_file "$HOME/.local/share/icons/hicolor/256x256/apps/updatable.png" "core_update copies new icon"
assert_grep 'updatable.png' "$HOME/.local/share/appimage-manager/registry.tsv" "core_update updates registry icon"

cli_new="$FIX/CLI-Updatable-2.AppImage"
printf '#!/usr/bin/env bash\necho cli-new\n' >"$cli_new"
if bash "$ROOT/appimage-manager.sh" --update "Updatable" "$cli_new" >/dev/null 2>&1; then
	ok "CLI --update succeeds"
else
	bad "CLI --update succeeds"
fi
assert_grep 'echo cli-new' "$HOME/Applications/Updatable.AppImage" "CLI --update replaces content"

if bash "$ROOT/appimage-manager.sh" --update "Updatable" --name "X" "$cli_new" >/dev/null 2>&1; then
	bad "CLI --update rejects install options"
else
	ok "CLI --update rejects install options"
fi

# --- --skip-validation (non-AppImage binaries) ------------------------------

plain="$FIX/PlainBinary.bin"
marker="$FIX/executed.marker"
printf '#!/usr/bin/env bash\ntouch %s\nexit 0\n' "$marker" >"$plain"
chmod +x "$plain"

if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	core_install --appimage "$plain" --name "Plain App" --skip-validation --force >/dev/null 2>&1
); then
	ok "core_install --skip-validation installs non-AppImage"
else
	bad "core_install --skip-validation installs non-AppImage"
fi
assert_file "$HOME/Applications/Plain App.AppImage" "skip-validation copies the file"
assert_nofile "$marker" "skip-validation does not execute the binary"
assert_grep '^Icon=.*Plain App.AppImage$' "$HOME/.local/share/applications/plain-app.desktop" "skip-validation icon falls back to app path"

plain2="$FIX/PlainBinary-2.bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$plain2"
if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	core_update --target "Plain App" --appimage "$plain2" --skip-validation >/dev/null 2>&1
); then
	ok "core_update --skip-validation succeeds"
else
	bad "core_update --skip-validation succeeds"
fi

if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	core_update --target "Plain App" --appimage "$plain2" >/dev/null 2>&1
); then
	bad "core_update rejects non-AppImage without --skip-validation"
else
	ok "core_update rejects non-AppImage without --skip-validation"
fi

cli_plain="$FIX/CLIPlain.bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$cli_plain"
if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	bash "$ROOT/appimage-manager.sh" --skip-validation --name "CLI Plain" "$cli_plain" >/dev/null 2>&1
); then
	ok "CLI --skip-validation installs non-AppImage"
else
	bad "CLI --skip-validation installs non-AppImage"
fi
assert_file "$HOME/Applications/CLI Plain.AppImage" "CLI --skip-validation copies the file"

if (
	unset APPIMAGE_MANAGER_SKIP_VALIDATE
	bash "$ROOT/appimage-manager.sh" --name "Reject" "$cli_plain" >/dev/null 2>&1
); then
	bad "CLI rejects non-AppImage without --skip-validation"
else
	ok "CLI rejects non-AppImage without --skip-validation"
fi

# --- Summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
