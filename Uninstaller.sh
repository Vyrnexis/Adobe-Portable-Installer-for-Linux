#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------
# Adobe Portable Uninstaller for Linux
#  - Removes Photoshop and/or Lightroom artifacts
#  - Removes corresponding .desktop entries
#  - Optionally removes the entire Wine prefix (~/.adobe)
#  - Supports custom prefix path
#  - Interactive menu + CLI flags
# ------------------------------------

# ---------------- Config ----------------
DEFAULT_PREFIX="$HOME/.adobe"
PREFIX="$DEFAULT_PREFIX"
DESKTOP_DIR="$HOME/.local/share/applications"

PS_DESKTOP="$DESKTOP_DIR/photoshop.desktop"
LR_DESKTOP="$DESKTOP_DIR/lightroom.desktop"

PS_DEST=""
LR_DEST=""

# ---------------- Helpers ----------------
# Print error and exit.
die() { printf "Error: %s\n" "$*" >&2; exit 1; }
TTY="/dev/tty"

# Print to TTY if available.
to_tty() {
  if [[ -w "$TTY" ]]; then
    printf '%s\n' "$*" >"$TTY"
  else
    printf '%s\n' "$*"
  fi
}

# Print without newline to TTY if available.
to_tty_n() {
  if [[ -w "$TTY" ]]; then
    printf "%s" "$*" >"$TTY"
  else
    printf "%s" "$*"
  fi
}

# Read a line from TTY (or stdin).
read_tty_line() {
  local input
  if [[ -r "$TTY" ]]; then
    IFS= read -r input <"$TTY"
  else
    IFS= read -r input
  fi
  printf '%s' "$input"
}

# Initialize derived paths.
init_paths() {
  PS_DEST="$PREFIX/drive_c/PortableApps/Photoshop"
  LR_DEST="$PREFIX/drive_c/PortableApps/Lightroom"
}

# Choose prefix path (default or custom).
choose_prefix() {
  to_tty "Use default prefix ($DEFAULT_PREFIX)? [Y/n]"
  to_tty_n "> "
  local answer
  answer="$(read_tty_line)"
  case "${answer,,}" in
    ""|y|yes) PREFIX="$DEFAULT_PREFIX" ;;
    *)
      to_tty "Enter custom prefix path:"
      to_tty_n "> "
      local custom
      custom="$(read_tty_line)"
      [[ -n "$custom" ]] || die "Prefix path cannot be empty"
      custom="${custom/#\~/$HOME}"
      PREFIX="$custom"
      ;;
  esac
}

# Remove path if it exists (with basic safety guard).
rm_if_exists() {
  local path="$1"
  [[ -n "$path" && "$path" != "/" ]] || die "Refusing to remove: $path"
  if [[ -e "$path" ]]; then
    rm -rf -- "$path"
    to_tty "Removed: $path"
  else
    to_tty "Not found (skipped): $path"
  fi
}

# Refresh desktop database if available.
refresh_desktop_db() {
  if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "$DESKTOP_DIR" >/dev/null 2>&1 || true
  fi
}

# ---------------- Menu/Usage ----------------
# Show uninstall menu.
show_menu() {
  to_tty "===================================================="
  to_tty "      Adobe Portable Uninstaller for Linux"
  to_tty "===================================================="
  to_tty "Prefix: $PREFIX"
  to_tty "  1) Remove Photoshop"
  to_tty "  2) Remove Lightroom"
  to_tty "  3) Remove all"
  to_tty "  4) Exit"
  to_tty "===================================================="
}

# Read a menu choice.
get_choice() {
  local c=""
  show_menu
  to_tty_n "Choice [1-4]: "
  c="$(read_tty_line)"
  printf '%s' "$c"
}

# Print usage.
usage() {
  cat <<EOF
Usage: $0 [--photoshop | --lightroom | --all]

  --photoshop   Remove Photoshop only
  --lightroom   Remove Lightroom only
  --all         Remove everything (apps + desktop entries + ~/.adobe prefix)

No flags = interactive menu.
You will be prompted for a prefix path (default: $DEFAULT_PREFIX).
EOF
}

# ---------------- Actions ----------------
# Remove Photoshop files.
remove_photoshop() {
  to_tty "Removing Photoshop..."
  rm_if_exists "$PS_DESKTOP"
  rm_if_exists "$PS_DEST"
}

# Remove Lightroom files.
remove_lightroom() {
  to_tty "Removing Lightroom..."
  rm_if_exists "$LR_DESKTOP"
  rm_if_exists "$LR_DEST"
}

# Remove all installed files and prefix.
remove_all() {
  to_tty "Removing all apps and prefix..."
  remove_photoshop
  remove_lightroom
  rm_if_exists "$PREFIX"
}

# ---------------- Main ----------------
# Main uninstaller flow.
main() {
  choose_prefix
  init_paths
  case "${1:-}" in
    --photoshop)
      remove_photoshop
      refresh_desktop_db
      to_tty ""
      to_tty "[✓] Done"
      ;;
    --lightroom)
      remove_lightroom
      refresh_desktop_db
      to_tty ""
      to_tty "[✓] Done"
      ;;
    --all)
      remove_all
      refresh_desktop_db
      to_tty ""
      to_tty "[✓] Done"
      ;;
    "")
      while true; do
        local choice
        choice="$(get_choice)"
        echo
        case "$choice" in
          1) remove_photoshop ;;
          2) remove_lightroom ;;
          3) remove_all ;;
          4) to_tty "Bye."; exit 0 ;;
          *) to_tty "Invalid option: $choice" ;;
        esac
        refresh_desktop_db
        to_tty ""
        to_tty "[✓] Done"
        echo
        to_tty_n "Press Enter to continue..."
        read_tty_line >/dev/null
        echo
      done
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
