#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# appimage-install.sh
# Installs an AppImage into ~/Applications, writes a .desktop launcher into
# ~/.local/share/applications, and copies an icon to ~/.local/share/icons.

# ===BUNDLE_CORE_HERE===

if ! declare -F core_install >/dev/null 2>&1; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=lib/core.sh
	source "$SCRIPT_DIR/lib/core.sh"
fi

usage() {
	cat <<'USAGE'
Usage: appimage-install.sh [OPTIONS] /path/to/AppImage

Installs an AppImage into ~/Applications and integrates it with a desktop entry and icon.

Options:
  --name NAME          Display name for the app (defaults to file basename)
  --categories CATS    Desktop Categories (default: Utility;)
  --comment TEXT       One-line description for the launcher
  --icon PATH          Path to a custom icon file (.png/.svg)
  --exec-args ARGS     Extra args appended to Exec= (e.g., --no-sandbox)
  --force              Overwrite existing AppImage, desktop, and icon
  -h, --help           Show this help and exit

Notes:
  - No root required. Writes only to user directories.
  - GNOME-based desktops are the primary target, but .desktop is freedesktop-compliant.
  - Sets the desktop entry working directory (Path=) to ~/Applications for more reliable launches.
  - Launchers now auto-fallback to --no-sandbox if the first launch fails (helps on Ubuntu 24.04).
USAGE
}

main() {
	local appimage_path=""
	local name=""
	local categories="Utility;"
	local comment=""
	local custom_icon=""
	local exec_args=""
	local force_overwrite=false

	while [ $# -gt 0 ]; do
		case "$1" in
		--name)
			shift
			name="${1:-}"
			[ -n "$name" ] || die "--name requires a value"
			shift || true
			;;
		--categories)
			shift
			categories="${1:-}"
			[ -n "$categories" ] || die "--categories requires a value"
			shift || true
			;;
		--comment)
			shift
			comment="${1:-}"
			[ -n "$comment" ] || die "--comment requires a value"
			shift || true
			;;
		--icon)
			shift
			custom_icon="${1:-}"
			[ -n "$custom_icon" ] || die "--icon requires a value"
			shift || true
			;;
		--exec-args)
			shift
			exec_args="${1:-}"
			[ -n "$exec_args" ] || die "--exec-args requires a value"
			shift || true
			;;
		--force)
			force_overwrite=true
			shift
			;;
		-h | --help)
			usage
			exit 0
			;;
		--)
			shift
			break
			;;
		-*)
			die "Unknown option: $1"
			;;
		*)
			# First non-flag is the AppImage
			if [ -z "$appimage_path" ]; then
				appimage_path="$1"
				shift
			else
				die "Unexpected positional argument: $1"
			fi
			;;
		esac
	done

	[ -n "$appimage_path" ] || {
		usage
		die "Missing AppImage path"
	}

	local -a args=(
		--appimage "$appimage_path"
		--name "$name"
		--categories "$categories"
		--comment "$comment"
		--icon "$custom_icon"
		--exec-args "$exec_args"
	)
	[ "$force_overwrite" = true ] && args+=(--force)

	core_install "${args[@]}"
}

main "$@"
