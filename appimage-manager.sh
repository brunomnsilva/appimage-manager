#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# appimage-manager.sh
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
Usage: appimage-manager [OPTIONS] /path/to/AppImage
       appimage-manager --list
       appimage-manager --update <slug|name> /path/to/new.AppImage

Installs an AppImage into ~/Applications and integrates it with a desktop entry
and icon, lists installed AppImages, or updates an installed AppImage in place.

Options:
  --name NAME          Display name for the app (defaults to file basename)
  --categories CATS    Desktop Categories (default: Utility;)
  --mime-types TYPES   Semicolon-separated MIME types the app handles
                       (e.g. "image/png;text/plain;"), written to MimeType=
  --comment TEXT       One-line description for the launcher
  --icon PATH          Path to a custom icon file (.png/.svg)
  --exec-args ARGS     Extra args appended to Exec= (e.g., --no-sandbox)
  --force              Overwrite existing AppImage, desktop, and icon
  --skip-validation    Install/update a file even if it is not a valid AppImage
                       (e.g. a standalone binary); icon auto-extraction is skipped
  --list, -l           List installed AppImages and exit
  --update TARGET      Replace an installed app's AppImage with a new file
                       (TARGET is the app slug or display name); the positional
                       path is the new AppImage. Incompatible with --name,
                       --categories, --mime-types, --comment, --exec-args, and
                       --force.
  -h, --help           Show this help and exit

Notes:
  - No root required. Writes only to user directories.
  - GNOME-based desktops are the primary target, but .desktop is freedesktop-compliant.
  - Sets the desktop entry working directory (Path=) to ~/Applications for more reliable launches.
  - Launchers now auto-fallback to --no-sandbox if the first launch fails (helps on Ubuntu 24.04).
USAGE
}

print_list() {
	local rows
	rows=$(core_list)
	if [ -z "$rows" ]; then
		printf 'No apps installed.\n'
		return 0
	fi

	local slug name appimage desktop icon wrapper tracked status
	printf '%-28s  %-55s  %s\n' "NAME" "PATH" "STATUS"
	while IFS=$'\t' read -r slug name appimage desktop icon wrapper tracked; do
		if [ "$tracked" = "0" ]; then
			status="legacy"
		else
			status="tracked"
		fi
		printf '%-28s  %-55s  %s\n' "$name" "$(shorten_home "$appimage")" "$status"
	done <<<"$rows"
}

main() {
	local appimage_path=""
	local name=""
	local categories="Utility;"
	local comment=""
	local custom_icon=""
	local exec_args=""
	local mime_types=""
	local force_overwrite=false
	local list_mode=false
	local update_target=""
	local install_flags=false
	local skip_validation=false

	while [ $# -gt 0 ]; do
		case "$1" in
		--name)
			shift
			name="${1:-}"
			[ -n "$name" ] || die "--name requires a value"
			shift || true
			install_flags=true
			;;
		--categories)
			shift
			categories="${1:-}"
			[ -n "$categories" ] || die "--categories requires a value"
			shift || true
			install_flags=true
			;;
		--comment)
			shift
			comment="${1:-}"
			[ -n "$comment" ] || die "--comment requires a value"
			shift || true
			install_flags=true
			;;
		--mime-types)
			shift
			mime_types="${1:-}"
			[ -n "$mime_types" ] || die "--mime-types requires a value"
			shift || true
			install_flags=true
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
			install_flags=true
			;;
		--force)
			force_overwrite=true
			install_flags=true
			shift
			;;
		--skip-validation)
			skip_validation=true
			shift
			;;
		--list | -l)
			list_mode=true
			shift
			;;
		--update)
			shift
			update_target="${1:-}"
			[ -n "$update_target" ] || die "--update requires a target (slug or name)"
			shift || true
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

	if [ "$list_mode" = true ]; then
		print_list
		return 0
	fi

	if [ -n "$update_target" ]; then
		[ "$install_flags" = false ] ||
			die "--update cannot be combined with install options (--name, --categories, --mime-types, --comment, --exec-args, --force)"
		[ -n "$appimage_path" ] || {
			usage
			die "--update requires the path to the new AppImage"
		}
		local -a update_args=(--target "$update_target" --appimage "$appimage_path")
		[ -n "$custom_icon" ] && update_args+=(--icon "$custom_icon")
		[ "$skip_validation" = true ] && update_args+=(--skip-validation)
		core_update "${update_args[@]}"
		return 0
	fi

	[ -n "$appimage_path" ] || {
		usage
		die "Missing AppImage path"
	}

	local -a args=(
		--appimage "$appimage_path"
		--name "$name"
		--categories "$categories"
		--mime-types "$mime_types"
		--comment "$comment"
		--icon "$custom_icon"
		--exec-args "$exec_args"
	)
	[ "$force_overwrite" = true ] && args+=(--force)
	[ "$skip_validation" = true ] && args+=(--skip-validation)

	core_install "${args[@]}"
}

main "$@"
