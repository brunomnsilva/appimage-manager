# shellcheck shell=bash
# lib/core.sh — shared library for appimage-manager (functions only; no side effects)
#
# Source this file (or rely on it being inlined by scripts/build.sh) before
# calling core_install, core_list, or core_uninstall.

log() { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARN] %s\n' "$*" >&2; }
err() { printf '[ERROR] %s\n' "$*" >&2; }
die() {
	err "$*"
	exit 1
}

command_exists() { command -v "$1" >/dev/null 2>&1; }

abs_path() {
	# Best-effort absolute path resolution
	# Prefers realpath, falls back to readlink -f, else prefixes with $PWD
	if command_exists realpath; then
		realpath "$1"
	elif command_exists readlink; then
		readlink -f "$1" 2>/dev/null || printf '%s/%s' "$PWD" "${1#./}"
	else
		printf '%s/%s' "$PWD" "${1#./}"
	fi
}

slugify() {
	# Lowercase, replace spaces/underscores with dashes, strip invalids
	# shellcheck disable=SC2020
	printf '%s' "$1" |
		tr '[:upper:]' '[:lower:]' |
		tr ' ' '-' |
		tr '_' '-' |
		sed -E 's/[^a-z0-9.-]+/-/g; s/^-+//; s/-+$//'
}

copy_file() {
	# cp with parents
	# $1 src, $2 dest
	mkdir -p "$(dirname "$2")"
	cp -f "$1" "$2"
}

is_appimage() {
	# $1 file
	# Non-executing validity check: an AppImage is an ELF with the "AI" magic
	# at offset 8 (type-1 "AI\x01" / type-2 "AI\x02").
	# APPIMAGE_MANAGER_SKIP_VALIDATE=1 bypasses the check (used by tests).
	[ -f "$1" ] || return 1
	if [ "${APPIMAGE_MANAGER_SKIP_VALIDATE:-0}" = "1" ]; then
		return 0
	fi
	local magic
	magic=$(od -An -tx1 -N 10 "$1" 2>/dev/null | tr -d ' \n')
	if [ "${magic:0:8}" = "7f454c46" ] && [ "${magic:16:4}" = "4149" ]; then
		return 0
	fi
	return 1
}

try_extract_icon_from_appimage() {
	# $1 appimage_path, $2 dest_basename_without_ext, $3 icons_dir
	# Attempts to extract an icon from the AppImage payload.
	# Returns 0 on success and sets ICON_TARGET global; else 1.
	local appimage="$1" base="$2" icons_dir="$3"
	local tmp
	tmp=$(mktemp -d)
	# Guarded so it is safe if the RETURN trap also fires in a caller scope
	# (bash keeps the trap set for the enclosing function).
	trap '[ -n "${tmp-}" ] && rm -rf "$tmp" || true' RETURN

	# AppImage self-extractor writes into squashfs-root
	if ! (cd "$tmp" && "$appimage" --appimage-extract >/dev/null 2>&1); then
		return 1
	fi

	local root="$tmp/squashfs-root"
	[ -d "$root" ] || return 1

	# Priority: .DirIcon, then SVGs, then PNGs commonly placed in icons dirs.
	local candidate=""
	if [ -f "$root/.DirIcon" ]; then
		candidate="$root/.DirIcon"
	else
		# Prefer SVG, then PNG anywhere typical under usr/share/icons or top-level app icons
		# Gather a few common locations first to avoid scanning everything
		local -a search_dirs
		search_dirs=(
			"$root/usr/share/icons"
			"$root/usr/share/pixmaps"
			"$root"
		)
		for d in "${search_dirs[@]}"; do
			[ -d "$d" ] || continue
			# SVG first
			candidate=$(find "$d" -type f -name '*.svg' -print 2>/dev/null | head -n 1 || true)
			if [ -n "$candidate" ]; then break; fi
			# PNG next
			candidate=$(find "$d" -type f -name '*.png' -print 2>/dev/null | head -n 1 || true)
			if [ -n "$candidate" ]; then break; fi
		done
	fi

	if [ -z "$candidate" ]; then
		return 1
	fi

	local ext=""
	case "$candidate" in
	*.svg) ext=".svg" ;;
	*.png) ext=".png" ;;
	*)
		# Try to detect from mime
		if command_exists file; then
			local mime
			mime=$(file --mime-type -b "$candidate" || true)
			case "$mime" in
			image/svg+xml) ext=".svg" ;;
			image/png) ext=".png" ;;
			*) ext="" ;;
			esac
		fi
		;;
	esac

	# Default to .png if unknown
	[ -n "$ext" ] || ext=".png"

	local target="$icons_dir/${base}${ext}"
	mkdir -p "$icons_dir"
	cp -f "$candidate" "$target"
	ICON_TARGET="$target"
	return 0
}

# --- Path helpers -----------------------------------------------------------

# Replace a leading $HOME with ~ for compact display.
shorten_home() {
	case "$1" in
	"$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
	*) printf '%s' "$1" ;;
	esac
}

get_data_dir() { printf '%s' "${XDG_DATA_HOME:-$HOME/.local/share}"; }
get_install_dir() { printf '%s' "$HOME/Applications"; }
get_registry_file() { printf '%s/appimage-manager/registry.tsv' "$(get_data_dir)"; }

# --- Core operations --------------------------------------------------------

core_install() {
	local appimage_path="" name="" categories="Utility;" comment="" custom_icon="" exec_args="" force=false

	while [ $# -gt 0 ]; do
		case "$1" in
		--appimage)
			shift
			appimage_path="${1:-}"
			[ -n "$appimage_path" ] || die "--appimage requires a value"
			shift || true
			;;
		--name)
			shift
			name="${1:-}"
			shift || true
			;;
		--categories)
			shift
			categories="${1:-}"
			shift || true
			;;
		--comment)
			shift
			comment="${1:-}"
			shift || true
			;;
		--icon)
			shift
			custom_icon="${1:-}"
			shift || true
			;;
		--exec-args)
			shift
			exec_args="${1:-}"
			shift || true
			;;
		--force)
			force=true
			shift
			;;
		*) die "core_install: unknown option: $1" ;;
		esac
	done

	[ -n "$appimage_path" ] || die "Missing AppImage path"
	[ -f "$appimage_path" ] || die "File not found: $appimage_path"
	if ! is_appimage "$appimage_path"; then
		die "Not a valid AppImage: $appimage_path"
	fi

	# Make sure it's executable; some downloads are not +x
	if [ ! -x "$appimage_path" ]; then
		warn "AppImage is not executable; adding +x: $appimage_path"
		chmod +x "$appimage_path"
	fi

	local abs_appimage
	abs_appimage=$(abs_path "$appimage_path")

	local base_from_file
	base_from_file=$(basename "$abs_appimage")
	base_from_file=${base_from_file%.*}

	local app_name
	if [ -n "$name" ]; then
		app_name="$name"
	else
		app_name="$base_from_file"
	fi

	local app_slug
	app_slug=$(slugify "$app_name")
	[ -n "$app_slug" ] || die "Could not derive a valid slug from name: $app_name"

	local install_dir data_dir desktop_dir icons_dir
	install_dir=$(get_install_dir)
	data_dir=$(get_data_dir)
	desktop_dir="$data_dir/applications"
	icons_dir="$data_dir/icons/hicolor/256x256/apps"

	mkdir -p "$install_dir" "$desktop_dir" "$icons_dir"

	local dest_appimage="$install_dir/${app_name}.AppImage"
	if [ -e "$dest_appimage" ] && [ "$force" = false ]; then
		die "Destination already exists: $dest_appimage (use --force to overwrite)"
	fi

	log "Copying AppImage to: $dest_appimage"
	copy_file "$abs_appimage" "$dest_appimage"
	chmod +x "$dest_appimage"

	# Icon handling
	local icon_target=""
	if [ -n "$custom_icon" ]; then
		[ -f "$custom_icon" ] || die "Custom icon not found: $custom_icon"
		local ext
		case "$custom_icon" in
		*.png) ext=".png" ;;
		*.svg) ext=".svg" ;;
		*) die "Unsupported icon type (use .png or .svg): $custom_icon" ;;
		esac
		icon_target="$icons_dir/${app_slug}${ext}"
		log "Copying provided icon to: $icon_target"
		copy_file "$custom_icon" "$icon_target"
	else
		if try_extract_icon_from_appimage "$abs_appimage" "$app_slug" "$icons_dir"; then
			icon_target="$ICON_TARGET"
			log "Extracted icon to: $icon_target"
		else
			warn "Could not extract icon; launcher will reference the AppImage path as icon"
			icon_target="$dest_appimage"
		fi
	fi

	# Create a tiny wrapper so desktop launchers can retry with --no-sandbox if needed
	local bin_dir="$HOME/.local/bin"
	mkdir -p "$bin_dir"
	local wrapper_path="$bin_dir/${app_slug}-appimage-launcher"
	log "Writing launcher wrapper: $wrapper_path"

	local wrapper_template wrapper_content
	wrapper_template=$(
		cat <<'WRAP'
#!/usr/bin/env bash
set -Eeuo pipefail
app="__APPIMAGE_PATH__"
extra_args="__EXEC_ARGS__"

# If libfuse2 is missing, prefer extract-and-run to avoid mount issues
if command -v ldconfig >/dev/null 2>&1; then
  if ! ldconfig -p 2>/dev/null | grep -q 'libfuse\.so\.2'; then
    export APPIMAGE_EXTRACT_AND_RUN=1
  fi
fi

# Try normal launch first
# shellcheck disable=SC2086
if "$app" $extra_args "$@"; then
  exit 0
fi

# Fallback commonly needed for Electron-based AppImages on some Ubuntu configs
# shellcheck disable=SC2086
exec "$app" --no-sandbox $extra_args "$@"
WRAP
	)
	wrapper_content="${wrapper_template//__APPIMAGE_PATH__/$dest_appimage}"
	wrapper_content="${wrapper_content//__EXEC_ARGS__/$exec_args}"
	printf '%s\n' "$wrapper_content" >"$wrapper_path"
	chmod +x "$wrapper_path"

	# Use wrapper to handle fallbacks and pass through desktop arguments
	local exec_line
	exec_line="\"$wrapper_path\" %U"

	# Icon can be a name (no ext) if placed into icons theme; if a file path, keep absolute
	local icon_field
	case "$icon_target" in
	"$icons_dir/${app_slug}.png" | "$icons_dir/${app_slug}.svg")
		icon_field="$app_slug"
		;;
	*)
		icon_field="$icon_target"
		;;
	esac

	local desktop_file="$desktop_dir/${app_slug}.desktop"
	log "Writing desktop entry: $desktop_file"
	cat >"$desktop_file" <<DESKTOP
[Desktop Entry]
Type=Application
Name=$app_name
Exec=$exec_line
Path=$install_dir
Icon=$icon_field
Terminal=false
Categories=$categories
TryExec=$dest_appimage
Comment=${comment}
StartupNotify=true
DESKTOP

	chmod +x "$desktop_file"

	# Record the installation for list/uninstall
	local registry registry_dir safe_name reg_icon
	registry=$(get_registry_file)
	registry_dir=$(dirname "$registry")
	mkdir -p "$registry_dir"
	safe_name=${app_name//$'\t'/ }
	safe_name=${safe_name//$'\n'/ }
	# Keep the icon field non-empty (see core_list comment re: read collapsing
	# empty fields). For fallback installs it equals the AppImage path.
	reg_icon="$icon_target"
	printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
		"$app_slug" "$safe_name" "$dest_appimage" "$desktop_file" "$reg_icon" "$wrapper_path" \
		>>"$registry"

	log "Installed AppImage: $dest_appimage"
	log "Desktop entry created: $desktop_file"
	log "Icon installed: $icon_target"
	printf "\nDone. You may need to refresh your desktop's app index or log out/in.\n"
}

core_list() {
	# Prints one TSV row per installed app:
	#   slug \t name \t appimage_path \t desktop_path \t icon_path \t wrapper_path \t tracked
	# Fields are always non-empty (a "-" placeholder is used for unknown icon paths)
	# because `read` collapses consecutive/empty IFS fields and would misalign columns.
	local data_dir registry
	data_dir=$(get_data_dir)
	registry=$(get_registry_file)

	local -A seen=()
	local slug name appimage desktop icon wrapper

	if [ -f "$registry" ]; then
		while IFS=$'\t' read -r slug name appimage desktop icon wrapper; do
			[ -n "$slug" ] || continue
			seen["$appimage"]=1
			printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$slug" "$name" "$appimage" "$desktop" "$icon" "$wrapper" "1"
		done <"$registry"
	fi

	# Legacy installs (pre-registry): scan ~/Applications and report untracked entries
	local f base derived
	for f in "$(get_install_dir)"/*.AppImage; do
		[ -e "$f" ] || continue
		[ -n "${seen["$f"]+x}" ] && continue
		base=$(basename "$f")
		base=${base%.*}
		derived=$(slugify "$base")
		printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
			"$derived" "$base" "$f" \
			"$data_dir/applications/$derived.desktop" \
			"-" \
			"$HOME/.local/bin/$derived-appimage-launcher" \
			"0"
	done
}

core_uninstall() {
	local slug="$1"
	[ -n "$slug" ] || die "core_uninstall: missing slug"

	local data_dir registry
	data_dir=$(get_data_dir)
	registry=$(get_registry_file)

	local appimage="" desktop="" icon="" wrapper="" found=0

	if [ -f "$registry" ]; then
		local r_slug r_appimage r_desktop r_icon r_wrapper
		while IFS=$'\t' read -r r_slug _ r_appimage r_desktop r_icon r_wrapper; do
			if [ "$r_slug" = "$slug" ]; then
				appimage="$r_appimage"
				desktop="$r_desktop"
				icon="$r_icon"
				wrapper="$r_wrapper"
				found=1
				break
			fi
		done <"$registry"
	fi

	if [ "$found" -eq 0 ]; then
		# Not tracked: derive conventional paths from a matching AppImage filename
		local f base derived
		for f in "$(get_install_dir)"/*.AppImage; do
			[ -e "$f" ] || continue
			base=$(basename "$f")
			base=${base%.*}
			derived=$(slugify "$base")
			if [ "$derived" = "$slug" ]; then
				appimage="$f"
				found=1
				break
			fi
		done
		desktop="$data_dir/applications/$slug.desktop"
		wrapper="$HOME/.local/bin/$slug-appimage-launcher"
		icon=""
	fi

	[ "$found" -eq 1 ] || die "No installed app matches: $slug"

	local p
	for p in "$appimage" "$wrapper" "$desktop"; do
		if [ -n "$p" ] && [ -e "$p" ]; then
			rm -f "$p"
			log "Removed: $p"
		fi
	done

	if [ -n "$icon" ] && [ "$icon" != "$appimage" ] && [ "$icon" != "-" ]; then
		if [ -e "$icon" ]; then
			rm -f "$icon"
			log "Removed: $icon"
		fi
	else
		local e ip
		for e in png svg; do
			ip="$data_dir/icons/hicolor/256x256/apps/$slug.$e"
			if [ -e "$ip" ]; then
				rm -f "$ip"
				log "Removed: $ip"
			fi
		done
	fi

	if [ -f "$registry" ]; then
		local tmp line
		tmp=$(mktemp)
		while IFS= read -r line; do
			[ -z "$line" ] && continue
			case "$line" in
			"$slug"$'\t'*) continue ;;
			*) printf '%s\n' "$line" ;;
			esac
		done <"$registry" >"$tmp"
		mv "$tmp" "$registry"
		if [ ! -s "$registry" ]; then
			rm -f "$registry"
		fi
	fi

	log "Uninstalled: $slug"
}

# Replace the icon field of a registry row (tracked installs only).
core_registry_set_icon() {
	local slug="$1" new_icon="$2"
	local registry
	registry=$(get_registry_file)
	[ -f "$registry" ] || return 0

	local tmp line f_slug f_name f_app f_desk f_wrap
	tmp=$(mktemp)
	while IFS= read -r line; do
		[ -z "$line" ] && continue
		case "$line" in
		"$slug"$'\t'*)
			IFS=$'\t' read -r f_slug f_name f_app f_desk _ f_wrap <<<"$line"
			printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
				"$f_slug" "$f_name" "$f_app" "$f_desk" "$new_icon" "$f_wrap"
			;;
		*) printf '%s\n' "$line" ;;
		esac
	done <"$registry" >"$tmp"
	mv "$tmp" "$registry"
}

core_update() {
	# Replaces the installed AppImage payload, preserving the install identity
	# (slug/name), desktop entry, wrapper, and metadata. The registry does not
	# store Comment/Categories/exec-args, so the .desktop and wrapper are left
	# untouched.
	local target="" appimage_path="" custom_icon=""

	while [ $# -gt 0 ]; do
		case "$1" in
		--target)
			shift
			target="${1:-}"
			[ -n "$target" ] || die "--target requires a value"
			shift || true
			;;
		--appimage)
			shift
			appimage_path="${1:-}"
			[ -n "$appimage_path" ] || die "--appimage requires a value"
			shift || true
			;;
		--icon)
			shift
			custom_icon="${1:-}"
			[ -n "$custom_icon" ] || die "--icon requires a value"
			shift || true
			;;
		*) die "core_update: unknown option: $1" ;;
		esac
	done

	[ -n "$target" ] || die "core_update: missing --target"
	[ -n "$appimage_path" ] || die "core_update: missing --appimage"
	[ -f "$appimage_path" ] || die "File not found: $appimage_path"
	if ! is_appimage "$appimage_path"; then
		die "Not a valid AppImage: $appimage_path"
	fi

	# Resolve the installed app by slug (preferred) or exact name.
	local slug="" name="" installed="" desktop="" icon="" wrapper="" tracked="" found=0 matches=0
	local r_slug r_name r_app r_desk r_icon r_wrap r_tracked
	while IFS=$'\t' read -r r_slug r_name r_app r_desk r_icon r_wrap r_tracked; do
		[ -n "$r_slug" ] || continue
		if [ "$r_slug" = "$target" ]; then
			slug="$r_slug" name="$r_name" installed="$r_app" desktop="$r_desk"
			icon="$r_icon" wrapper="$r_wrap" tracked="$r_tracked"
			found=1
			break
		fi
		if [ "$r_name" = "$target" ]; then
			slug="$r_slug" name="$r_name" installed="$r_app" desktop="$r_desk"
			icon="$r_icon" wrapper="$r_wrap" tracked="$r_tracked"
			found=1
			matches=$((matches + 1))
		fi
	done < <(core_list)

	if [ "$found" -eq 0 ]; then
		die "No installed app matches: $target"
	fi
	if [ "$matches" -gt 1 ]; then
		die "Name matches more than one installed app; use the slug: $target"
	fi

	local new_abs
	new_abs=$(abs_path "$appimage_path")
	if [ "$new_abs" = "$installed" ]; then
		die "That is already the installed AppImage: $installed"
	fi

	# Replace atomically so a failed copy never truncates the installed app.
	local dest_dir tmp
	dest_dir=$(dirname "$installed")
	mkdir -p "$dest_dir"
	tmp=$(mktemp "$dest_dir/.update.XXXXXX")
	if ! cp -f "$appimage_path" "$tmp"; then
		rm -f "$tmp"
		die "Failed to copy new AppImage"
	fi
	chmod +x "$tmp"
	mv -f "$tmp" "$installed"
	chmod +x "$installed"
	log "Updated AppImage: $installed"

	# Icon: keep the existing one by default; replace only when provided.
	if [ -n "$custom_icon" ]; then
		[ -f "$custom_icon" ] || die "Custom icon not found: $custom_icon"
		local ext
		case "$custom_icon" in
		*.png) ext=".png" ;;
		*.svg) ext=".svg" ;;
		*) die "Unsupported icon type (use .png or .svg): $custom_icon" ;;
		esac

		local data_dir icons_dir new_icon
		data_dir=$(get_data_dir)
		icons_dir="$data_dir/icons/hicolor/256x256/apps"
		new_icon="$icons_dir/${slug}${ext}"
		copy_file "$custom_icon" "$new_icon"
		log "Copied provided icon to: $new_icon"

		if [ "$tracked" = "1" ]; then
			core_registry_set_icon "$slug" "$new_icon"
		fi

		if [ -n "$icon" ] && [ "$icon" != "$installed" ] && [ "$icon" != "-" ] &&
			[ "$icon" != "$new_icon" ] && [ -e "$icon" ]; then
			rm -f "$icon"
			log "Removed: $icon"
		fi
	fi

	log "Updated: $name"
}

# --- Subsell support --------------------------------------------------------

# Export every library function so subshells (e.g. `gum spin -- bash -c ...`)
# can invoke them.
export_all() {
	export -f log warn err die command_exists abs_path slugify copy_file \
		is_appimage try_extract_icon_from_appimage shorten_home get_data_dir get_install_dir get_registry_file \
		core_install core_list core_uninstall core_registry_set_icon core_update
}
