#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

# appimage-manager-tui.sh
# Interactive (gum-based) frontend for appimage-manager.

# ===BUNDLE_CORE_HERE===

if ! declare -F core_install >/dev/null 2>&1; then
	SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
	# shellcheck source=lib/core.sh
	source "$SCRIPT_DIR/lib/core.sh"
fi

command_exists gum || die "gum is required for TUI mode. Install it with: sudo pacman -S gum (or: brew install gum / go install github.com/charmbracelet/gum@latest)"

export_all

# --- Palette ----------------------------------------------------------------
# Semantic accents as ANSI base colors (0-15), so the terminal theme defines
# the actual hue. Normal text uses the terminal default (no color); the app
# never sets backgrounds.
COLOR_SECONDARY=8 # muted: cancel/status, hints, empty states
COLOR_ACCENT=6    # primary accent: application title
COLOR_SUCCESS=2
COLOR_WARNING=3
COLOR_ERROR=1

# --- Presentation helpers ---------------------------------------------------

# Clear the screen and move the cursor home.
clear_screen() { printf '\033[2J\033[H'; }

# Width of the ASCII banner below (columns).
BANNER_WIDTH=67

# Terminal width in columns (falls back to 80 when it cannot be determined).
term_width() {
	local w
	w=$(tput cols 2>/dev/null || true)
	case "$w" in '' | *[!0-9]*) w=${COLUMNS:-} ;; esac
	case "$w" in '' | *[!0-9]*) w=80 ;; esac
	printf '%s' "$w"
}

# Application title banner (accent-colored; compact when the terminal is narrow).
app_title() {
	if [ "$(term_width)" -lt "$BANNER_WIDTH" ]; then
		gum style --foreground "$COLOR_ACCENT" --bold --margin "1 0 1 0" "appimage-manager"
		return
	fi
	{
		printf '\u200b'
		cat <<'BANNER'
  ▄▄▄▄▄                    ▄▄▄▄
▄██▀▀▀██▄ ▄▄▄▄▄▄▄  ▄▄▄▄▄▄▄ ▀██▀ ▄▄▄▄▄▄▄▄▄ ▄▄▄▄▄▄▄  ▄▄▄▄▄▄   ▄▄▄▄▄
██     ██ ██▀▀▀▀██ ██▀▀▀▀██ ██  ██▀▀██▀██▄ ▀▀▀▀▀██ ██▀▀▀██ ██▀▀▀██
█████████ ██    ██ ██    ██ ██  ██  ██ ██▀▄██▀▀███ ██   ██ ██▀▀▀▀▀
██     ██ ███████▀ ███████▀▄██▄ ██  ██ ██▄▀██▄▄███ ███████ ███████
          ██       ██                              ▄▄▄▄▄██
          ▀▀       ▀▀                              ▀▀▀▀▀▀
                                                   MANAGER
BANNER
	} | gum style --foreground "$COLOR_ACCENT" --margin "1 0 1 0"
}

# Transient outcome message shown at the top of the main menu.
STATUS=""
show_status() {
	if [ -n "$STATUS" ]; then
		gum style --foreground "$COLOR_SECONDARY" "$STATUS"
		STATUS=""
	fi
}

# Wait for the user so they can read the screen before it is cleared.
pause_key() {
	printf '\n'
	gum style --foreground "$COLOR_SECONDARY" "Press Enter to continue"
	read -rs _ || true
}

category_value() {
	case "$1" in
	Utility) printf 'Utility;' ;;
	Development) printf 'Development;' ;;
	Office) printf 'Office;' ;;
	Graphics) printf 'Graphics;' ;;
	AudioVideo) printf 'AudioVideo;' ;;
	Network) printf 'Network;' ;;
	Game) printf 'Game;' ;;
	Education) printf 'Education;' ;;
	Science) printf 'Science;' ;;
	System) printf 'System;' ;;
	*) printf 'Utility;' ;;
	esac
}

exec_args_value() {
	case "$1" in
	"--no-sandbox") printf '%s' '--no-sandbox' ;;
	"--disable-gpu") printf '%s' '--disable-gpu' ;;
	"--disable-dev-shm-usage") printf '%s' '--disable-dev-shm-usage' ;;
	"Wayland (auto)") printf '%s' '--ozone-platform-hint=auto' ;;
	"Wayland (native)") printf '%s' '--enable-features=UseOzonePlatform,WaylandWindowDecorations --ozone-platform-hint=auto' ;;
	*) printf '%s' "$1" ;;
	esac
}

# --- Selection helpers -----------------------------------------------------

# Prompt for an AppImage under ~/Downloads (recursively), offering a "Browse
# files…" escape for files elsewhere. On success prints the chosen path and
# returns 0. Esc at the list (or at the empty-state picker) returns 1; Esc in
# the browse sub-picker re-renders the list (back one level).
select_appimage() {
	local start_dir="$HOME/Downloads"
	[ -d "$start_dir" ] || start_dir="$HOME"

	while true; do
		local -a files=() labels=()
		local f p
		while IFS= read -r f; do
			files+=("$f")
			labels+=("$(basename "$f")")
		done < <(find "$start_dir" -type f -iname '*.AppImage' 2>/dev/null | sort)

		if [ "${#labels[@]}" -eq 0 ]; then
			gum style --foreground "$COLOR_SECONDARY" "No .AppImage files found in $start_dir" >&2
			local picked
			picked=$(gum file --file --height 15 "$start_dir") || return 1
			printf '%s' "$picked"
			return 0
		fi

		local choice
		choice=$(gum choose --header "Select an AppImage" -- "${labels[@]}" "Browse files…") || return 1
		if [ "$choice" = "Browse files…" ]; then
			local picked
			picked=$(gum file --file --height 15 "$start_dir") || continue
			printf '%s' "$picked"
			return 0
		fi

		local i
		for i in "${!labels[@]}"; do
			if [ "${labels[$i]}" = "$choice" ]; then
				printf '%s' "${files[$i]}"
				return 0
			fi
		done
	done
}

# Prompt for one of the installed apps. On success prints
# "slug<TAB>label<TAB>tracked" and returns 0; returns 1 on cancel.
select_installed_app() {
	local header="$1"
	local -a slugs=() labels=() tracked_flags=()
	local slug name appimage tracked
	while IFS=$'\t' read -r slug name appimage _ _ _ tracked; do
		slugs+=("$slug")
		labels+=("$name — $(shorten_home "$appimage")")
		tracked_flags+=("$tracked")
	done < <(core_list)

	local choice
	choice=$(gum choose --header "$header" -- "${labels[@]}") || return 1
	[ -n "$choice" ] || return 1

	local i
	for i in "${!labels[@]}"; do
		if [ "${labels[$i]}" = "$choice" ]; then
			printf '%s\t%s\t%s' "${slugs[$i]}" "${labels[$i]}" "${tracked_flags[$i]}"
			return 0
		fi
	done
	return 1
}

# --- Wizard ---------------------------------------------------------------

# Esc backs one level: top step returns to the menu, other steps re-render the
# previous one. Enter accepts the current value/default and advances. Each step
# starts from a cleared screen.
tui_install() {
	local appimage="" name="" comment="" categories="Utility;" exec_args="" icon=""
	local base="" force=false skip_validation=false step="appimage"

	while [ "$step" != "done" ]; do
		clear_screen
		app_title
		printf '\n'

		case "$step" in
		appimage)
			if ! appimage=$(select_appimage); then
				STATUS="Cancelled."
				return
			fi

			skip_validation=false
			if ! is_appimage "$appimage"; then
				gum style --foreground "$COLOR_WARNING" --bold "Not a valid AppImage: $appimage"
				gum style --foreground "$COLOR_WARNING" \
					"It will be installed as-is; icon auto-extraction is skipped."
				if ! gum confirm "Install it anyway?"; then
					STATUS="Cancelled."
					return
				fi
				skip_validation=true
			fi

			base=$(basename "$appimage")
			base=${base%.*}
			step="name"
			;;

		name)
			if ! name=$(gum input --header "App name" --placeholder "App name" --value "$base"); then
				step="appimage"
				continue
			fi
			if [ -z "$name" ]; then
				gum style --foreground "$COLOR_ERROR" "Name cannot be empty."
				pause_key
				continue
			fi
			step="comment"
			;;

		comment)
			if ! comment=$(gum input --header "Comment" --placeholder "Comment (optional)"); then
				step="name"
				continue
			fi
			step="category"
			;;

		category)
			local cat_choice
			if ! cat_choice=$(gum choose --header "Category" \
				"Utility" "Development" "Office" "Graphics" "AudioVideo" \
				"Network" "Game" "Education" "Science" "System" "Custom…"); then
				step="comment"
				continue
			fi
			if [ "$cat_choice" = "Custom…" ]; then
				if ! categories=$(gum input --header "Categories" --placeholder "Categories" --value "Utility;"); then
					continue
				fi
				[ -n "$categories" ] || categories="Utility;"
			else
				categories=$(category_value "$cat_choice")
			fi
			step="args"
			;;

		args)
			local -a selected_args=()
			local args_choice a has_none=false has_custom=false
			# The preset values start with "--", so a "--" terminator is required to
			# stop gum (kong) from parsing them as flags.
			if ! args_choice=$(gum choose --no-limit --height 12 --header "Extra launch args (optional)" -- \
				"None (no extra args)" \
				"--no-sandbox" \
				"--disable-gpu" \
				"--disable-dev-shm-usage" \
				"Wayland (auto)" \
				"Wayland (native)" \
				"Custom…"); then
				step="category"
				continue
			fi
			exec_args=""
			if [ -n "$args_choice" ]; then
				while IFS= read -r a; do
					case "$a" in
					"None (no extra args)") has_none=true ;;
					"Custom…") has_custom=true ;;
					"--no-sandbox" | "--disable-gpu" | "--disable-dev-shm-usage" | "Wayland (auto)" | "Wayland (native)")
						selected_args+=("$(exec_args_value "$a")")
						;;
					*) : ;; # ignore any unexpected output (defensive)
					esac
				done <<<"$args_choice"
				if [ "$has_custom" = true ]; then
					local custom_args
					if ! custom_args=$(gum input --header "Extra args" --placeholder "e.g. --no-sandbox --disable-gpu"); then
						continue
					fi
					[ -n "$custom_args" ] && selected_args+=("$custom_args")
				fi
				if [ "$has_none" = false ]; then
					exec_args=$(printf '%s ' "${selected_args[@]}")
					exec_args=${exec_args% }
				fi
			fi
			step="icon"
			;;

		icon)
			local icon_choice
			if ! icon_choice=$(gum choose --header "Icon" \
				"Auto-extract (recommended)" "Provide custom icon"); then
				step="args"
				continue
			fi
			icon=""
			if [ "$icon_choice" = "Provide custom icon" ]; then
				if ! icon=$(gum file --file --height 15 "$HOME"); then
					continue
				fi
			fi
			step="confirm"
			;;

		confirm)
			local dest
			dest="$HOME/Applications/${name}.AppImage"
			if [ -e "$dest" ]; then
				if ! gum confirm "An install named \"$name\" already exists. Overwrite it?"; then
					STATUS="Cancelled."
					return
				fi
				force=true
			else
				force=false
			fi

			local icon_display="<auto>"
			[ -n "$icon" ] && icon_display=$(shorten_home "$icon")

			{
				printf 'AppImage:   %s\n' "$(shorten_home "$appimage")"
				printf 'Name:       %s\n' "$name"
				printf 'Categories: %s\n' "$categories"
				printf 'Exec args:  %s\n' "${exec_args:-<none>}"
				printf 'Icon:       %s\n' "$icon_display"
				printf 'Overwrite:  %s\n' "$force"
			} | gum style --border rounded --padding "1 2"

			if ! gum confirm "Proceed with installation?"; then
				STATUS="Cancelled."
				return
			fi

			local -a args=(--appimage "$appimage" --name "$name" --categories "$categories" --comment "$comment" --exec-args "$exec_args")
			[ -n "$icon" ] && args+=(--icon "$icon")
			[ "$force" = true ] && args+=(--force)
			[ "$skip_validation" = true ] && args+=(--skip-validation)

			gum spin --spinner dot --title "Installing $name…" --show-output -- \
				bash -c 'set -Eeuo pipefail; core_install "$@"' _ "${args[@]}"

			gum style --foreground "$COLOR_SUCCESS" --bold "Installed: $name"
			pause_key
			step="done"
			;;
		esac
	done
}

tui_list() {
	clear_screen
	app_title
	printf '\n'

	local rows
	rows=$(core_list)

	if [ -z "$rows" ]; then
		gum style --foreground "$COLOR_SECONDARY" "No apps installed."
		pause_key
		return
	fi

	local name appimage tracked
	{
		while IFS=$'\t' read -r _ name appimage _ _ _ tracked; do
			local status="🟢 tracked"
			[ "$tracked" = "0" ] && status="🔴 legacy"
			printf '%s\t%s\t%s\n' "$name" "$(shorten_home "$appimage")" "$status"
		done <<<"$rows"
	} | gum table --print --separator $'\t' --columns "Name,Path,Status" --widths 30,45,12
	pause_key
}

tui_uninstall() {
	clear_screen
	app_title
	printf '\n'

	local rows
	rows=$(core_list)

	if [ -z "$rows" ]; then
		gum style --foreground "$COLOR_SECONDARY" "No apps installed."
		pause_key
		return
	fi

	local selection target_slug target_name target_tracked
	selection=$(select_installed_app "Select an AppImage to uninstall") || {
		STATUS="Cancelled."
		return
	}
	IFS=$'\t' read -r target_slug target_name target_tracked <<<"$selection"

	local confirm_text="Remove \"$target_name\"?"
	if [ "$target_tracked" = "0" ]; then
		gum style --foreground "$COLOR_WARNING" --bold "This AppImage is untracked (legacy) — it was not installed by appimage-manager."
		gum style --foreground "$COLOR_WARNING" "Its desktop entry, launcher wrapper, and icon are inferred from the filename and may not be accurate."
		confirm_text="Remove \"$target_name\" anyway?"
	fi

	if ! gum confirm "$confirm_text"; then
		STATUS="Cancelled."
		return
	fi

	gum spin --spinner dot --title "Uninstalling…" --show-output -- \
		bash -c 'set -Eeuo pipefail; core_uninstall "$@"' _ "$target_slug"

	gum style --foreground "$COLOR_SUCCESS" --bold "Uninstalled: $target_name"
	pause_key
}

tui_update() {
	clear_screen
	app_title
	printf '\n'

	local rows
	rows=$(core_list)
	if [ -z "$rows" ]; then
		gum style --foreground "$COLOR_SECONDARY" "No apps installed."
		pause_key
		return
	fi

	local selection target_slug target_name
	selection=$(select_installed_app "Select an AppImage to update") || {
		STATUS="Cancelled."
		return
	}
	IFS=$'\t' read -r target_slug target_name _ <<<"$selection"

	local new_appimage skip_validation=false
	if ! new_appimage=$(select_appimage); then
		STATUS="Cancelled."
		return
	fi
	if ! is_appimage "$new_appimage"; then
		gum style --foreground "$COLOR_WARNING" --bold "Not a valid AppImage: $new_appimage"
		gum style --foreground "$COLOR_WARNING" \
			"It will be installed as-is; icon auto-extraction is skipped."
		if ! gum confirm "Update anyway?"; then
			STATUS="Cancelled."
			return
		fi
		skip_validation=true
	fi

	clear_screen
	app_title
	printf '\n'
	local icon_choice icon=""
	if ! icon_choice=$(gum choose --header "Icon" \
		"Keep existing icon" "Provide custom icon"); then
		STATUS="Cancelled."
		return
	fi
	if [ "$icon_choice" = "Provide custom icon" ]; then
		if ! icon=$(gum file --file --height 15 "$HOME"); then
			STATUS="Cancelled."
			return
		fi
	fi

	clear_screen
	app_title
	printf '\n'
	local icon_display="<keep existing>"
	[ -n "$icon" ] && icon_display=$(shorten_home "$icon")
	{
		printf 'App:       %s\n' "$target_name"
		printf 'New file:  %s\n' "$(shorten_home "$new_appimage")"
		printf 'Icon:      %s\n' "$icon_display"
	} | gum style --border rounded --padding "1 2"

	gum style --foreground "$COLOR_WARNING" --bold \
		"The current AppImage in ~/Applications will be overwritten."
	gum style --foreground "$COLOR_WARNING" \
		"Back it up first if you might need to revert."

	if ! gum confirm "Update \"$target_name\"?"; then
		STATUS="Cancelled."
		return
	fi

	local -a args=(--target "$target_slug" --appimage "$new_appimage")
	[ -n "$icon" ] && args+=(--icon "$icon")
	[ "$skip_validation" = true ] && args+=(--skip-validation)

	gum spin --spinner dot --title "Updating $target_name…" --show-output -- \
		bash -c 'set -Eeuo pipefail; core_update "$@"' _ "${args[@]}"

	gum style --foreground "$COLOR_SUCCESS" --bold "Updated: $target_name"
	pause_key
}

tui_help() {
	clear_screen
	app_title
	printf '\n'
	gum format <<'EOF'
Install, list, update, and uninstall AppImages into your user environment.

- **Install** — pick an AppImage and configure name, categories, icon, and launch flags.
- **List** — show what is currently installed.
- **Update** — replace an installed AppImage with a newer file (name, menu entry,
  launch flags, and icon are kept unless you choose a new icon).
- **Uninstall** — remove an installed AppImage and its launcher.

The **Status** column on the List screen:

- **tracked** — installed by this tool and recorded in its registry
  (`~/.local/share/appimage-manager/registry.tsv`), so it can be cleanly removed.
- **legacy** — an AppImage found in `~/Applications` that is not in the registry
  (installed before tracking existed, or added manually); it can still be uninstalled.

All changes stay under your home directory (no root required).
EOF
	pause_key
}

# --- Entry -------------------------------------------------------------------

main_menu() {
	STATUS=""
	while true; do
		clear_screen
		app_title
		show_status
		local choice
		choice=$(gum choose --header "" \
			"Install an AppImage" "List installed" "Update an AppImage" "Uninstall" "Help" "Exit" || true)
		case "${choice:-}" in
		"Install an AppImage") tui_install ;;
		"List installed") tui_list ;;
		"Update an AppImage") tui_update ;;
		"Uninstall") tui_uninstall ;;
		"Help") tui_help ;;
		"Exit" | "") break ;;
		esac
	done
}

# Use the alternate screen buffer for the session and disable echo, so stray
# terminal responses (to gum's capability queries) are not echoed to the screen.
# Restore the terminal on exit, leaving no trace in the user's scrollback.
SAVED_STTY=$(stty -g 2>/dev/null || true)
restore_terminal() {
	printf '\033[?1049l'
	if [ -n "$SAVED_STTY" ]; then
		stty "$SAVED_STTY" 2>/dev/null || true
	fi
}
trap restore_terminal EXIT
if [ -n "$SAVED_STTY" ]; then
	stty -echo 2>/dev/null || true
fi
printf '\033[?1049h'

main_menu
