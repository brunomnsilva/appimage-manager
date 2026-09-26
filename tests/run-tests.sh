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
export APPIMAGE_INSTALL_SKIP_VALIDATE=1

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

# --- is_appimage validation -------------------------------------------------

if (
	unset APPIMAGE_INSTALL_SKIP_VALIDATE
	is_appimage "$realapp"
); then
	ok "is_appimage accepts ELF+AI magic"
else
	bad "is_appimage accepts ELF+AI magic"
fi

if (
	unset APPIMAGE_INSTALL_SKIP_VALIDATE
	is_appimage "$icon"
); then
	bad "is_appimage rejects non-AppImage"
else
	ok "is_appimage rejects non-AppImage"
fi

if (
	unset APPIMAGE_INSTALL_SKIP_VALIDATE
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

# --- Install --------------------------------------------------------------

if (core_install --appimage "$stub" --name "Test App" --categories "Office;" --comment "A test app" --exec-args "--foo" --force >/dev/null 2>&1); then
	ok "core_install succeeds"
else
	bad "core_install succeeds"
fi

assert_file "$HOME/Applications/Test App.AppImage" "install copies AppImage"
assert_file "$HOME/.local/share/applications/test-app.desktop" "install writes desktop entry"
assert_file "$HOME/.local/bin/test-app-appimage-launcher" "install writes wrapper"
assert_file "$HOME/.local/share/appimage-install/registry.tsv" "install writes registry"

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

if bash -c 'set -Eeuo pipefail; core_install "$@"' _ --appimage "$stub" --name "Subshell App" --force >/dev/null 2>&1; then
	ok "core_install callable in subshell via export_all"
else
	bad "core_install callable in subshell via export_all"
fi

# --- List -------------------------------------------------------------------

core_list >"$FIX/list.tsv"
assert_grep $'^test-app\t' "$FIX/list.tsv" "list includes test-app"
assert_grep $'^needs-sandbox\t' "$FIX/list.tsv" "list includes needs-sandbox"
assert_grep $'^subshell-app\t' "$FIX/list.tsv" "list includes subshell-app"

# --- Uninstall --------------------------------------------------------------

if (core_uninstall "test-app" >/dev/null 2>&1); then
	ok "core_uninstall succeeds"
else
	bad "core_uninstall succeeds"
fi

assert_nofile "$HOME/Applications/Test App.AppImage" "uninstall removes AppImage"
assert_nofile "$HOME/.local/share/applications/test-app.desktop" "uninstall removes desktop entry"
assert_nofile "$HOME/.local/bin/test-app-appimage-launcher" "uninstall removes wrapper"
if grep -q $'^test-app\t' "$HOME/.local/share/appimage-install/registry.tsv" 2>/dev/null; then
	bad "uninstall removes registry row"
else
	ok "uninstall removes registry row"
fi

# --- Legacy scan (pre-registry) ----------------------------------------------

rm -f "$HOME/.local/share/appimage-install/registry.tsv"
core_list >"$FIX/list-legacy.tsv"
assert_grep $'^iconed-app\t' "$FIX/list-legacy.tsv" "legacy scan finds iconed-app"
assert_grep $'\t0$' "$FIX/list-legacy.tsv" "legacy rows marked untracked"

# --- CLI entrypoint ---------------------------------------------------------

if bash "$ROOT/appimage-install.sh" --name "CLI App" "$stub" >/dev/null 2>&1; then
	ok "CLI entrypoint installs"
else
	bad "CLI entrypoint installs"
fi
assert_file "$HOME/Applications/CLI App.AppImage" "CLI entrypoint copies AppImage"

if bash "$ROOT/appimage-install.sh" --help >/dev/null 2>&1; then
	ok "CLI --help exits 0"
else
	bad "CLI --help exits 0"
fi

if bash "$ROOT/appimage-install.sh" /nonexistent.AppImage >/dev/null 2>&1; then
	bad "CLI errors on missing file"
else
	ok "CLI errors on missing file"
fi

# --- Summary ---------------------------------------------------------------

printf '\n%d passed, %d failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
