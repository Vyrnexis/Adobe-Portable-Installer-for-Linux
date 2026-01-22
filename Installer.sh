#!/usr/bin/env bash
set -Eeuo pipefail

# ------------------------------------
# Adobe Portable Installer for Linux
#  - Installs Photoshop and/or Lightroom into ONE prefix: ~/.adobe (win64)
#  - Sets Windows version to Windows 7
#  - Installs winetricks deps once
#  - Optional prefix-only setup (deps + dark mode)
#  - Supports custom prefix path
#  - WORKAROUND: Wine 11 "new wow64 mode" + winetricks vcrun2015 may put
#    32-bit msvcp140.dll into system32. Detect + repair automatically.
#  - Extracts tarballs into drive_c/PortableApps/...
#  - Creates .desktop entries for installed apps (icons from extracted folder)
# ------------------------------------

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# ---------------- Config ----------------
DEFAULT_PREFIX="$HOME/.adobe"
PREFIX="$DEFAULT_PREFIX"
WINEARCH_DEFAULT="win64"
DESKTOP_DIR="$HOME/.local/share/applications"
LOG_DIR="$PREFIX/logs"

# App artifacts
PS_TARBALL="$SCRIPT_DIR/PhotoshopPortable.tar.gz"
LR_TARBALL="$SCRIPT_DIR/LightroomPortable.tar.gz"
PS_EXE_NAME="PhotoshopPortable.exe"
LR_EXE_NAME="LightroomPortable.exe"
PS_ICON_NAME="photoshop-icon.png"
LR_ICON_NAME="lightroom-icon.png"

WINETRICKS_DEPS=(
  vcrun2008 vcrun2010 vcrun2013 vcrun2015
  atmlib corefonts fontsmooth-rgb
  msxml3 msxml6
  gdiplus
)

DLL_OVERRIDES=(
  "msxml3=builtin"
)

# ---------------- Helpers ----------------
# Print error and exit.
die() { printf "Error: %s\n" "$*" >&2; exit 1; }
# Assert a required command exists.
need() { command -v "$1" >/dev/null 2>&1 || die "Missing dependency: $1"; }

# TTY helpers for consistent prompts.
TTY="/dev/tty"
to_tty() { if [[ -w "$TTY" ]]; then printf '%s\n' "$*" >"$TTY"; else printf '%s\n' "$*"; fi; }
to_tty_n() { if [[ -w "$TTY" ]]; then printf "%s" "$*" >"$TTY"; else printf "%s" "$*"; fi; }
# Read a line from TTY (or stdin).
read_tty_line() { local input; if [[ -r "$TTY" ]]; then IFS= read -r input <"$TTY"; else IFS= read -r input; fi; printf '%s' "$input"; }

# Initialize derived paths and app map.
init_paths() {
  LOG_DIR="$PREFIX/logs"
  PS_DEST="$PREFIX/drive_c/PortableApps/Photoshop"
  LR_DEST="$PREFIX/drive_c/PortableApps/Lightroom"
  PS_DESKTOP_FILE="$DESKTOP_DIR/photoshop.desktop"
  LR_DESKTOP_FILE="$DESKTOP_DIR/lightroom.desktop"

  APP_NAMES=("Photoshop" "Lightroom")
  APP_TARBALLS=("$PS_TARBALL" "$LR_TARBALL")
  APP_DESTS=("$PS_DEST" "$LR_DEST")
  APP_EXES=("$PS_EXE_NAME" "$LR_EXE_NAME")
  APP_ICONS=("$PS_ICON_NAME" "$LR_ICON_NAME")
  APP_DESKTOPS=("$PS_DESKTOP_FILE" "$LR_DESKTOP_FILE")
  APP_LOGS=("$LOG_DIR/photoshop-extract.log" "$LOG_DIR/lightroom-extract.log")
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

# Make Wine quieter by default (errors will still be logged)
export WINEDEBUG=-all

# Show installer header.
print_header() {
  [[ -t 1 ]] && clear || true
  cat <<EOF
====================================================
        Adobe Portable Installer for Linux
====================================================
Prefix: $PREFIX (win64)
Logs:   $LOG_DIR
====================================================

EOF
}

# Print a section heading.
section() {
  # Minimal heading (doesn't spam like banners)
  printf "\n== %s ==\n" "$1"
}

# Run command and append output to a log.
run_quiet() {
  # Usage: run_quiet /path/to/log command args...
  local log="$1"
  shift
  mkdir -p "$(dirname "$log")"
  "$@" >>"$log" 2>&1
}

# ---------------- Spinner ----------------
# Stop any active spinner.
spinner_cleanup() {
  if [[ -n "${_SPINNER_PID:-}" ]]; then
    kill "$_SPINNER_PID" 2>/dev/null || true
    wait "$_SPINNER_PID" 2>/dev/null || true
    _SPINNER_PID=""
  fi
}

# Start a background spinner.
spinner_start() {
  _SPINNER_MSG="$1"
  _SPINNER_CHARS='|/-\'
  (
    local i=0
    while :; do
      printf "\r[%c] %s" "${_SPINNER_CHARS:i%4:1}" "$_SPINNER_MSG"
      i=$((i+1))
      sleep 0.1
    done
  ) &
  _SPINNER_PID=$!
  disown "$_SPINNER_PID" 2>/dev/null || true
}

# Stop spinner and print final status.
spinner_stop() {
  local status="${1:-OK}"
  spinner_cleanup

  case "$status" in
    OK)   printf "\r[✓] %s\n" "$_SPINNER_MSG" ;;
    FAIL) printf "\r[✖] %s\n" "$_SPINNER_MSG" ;;
    *)    printf "\r[✓] %s\n" "$_SPINNER_MSG" ;;
  esac

  unset _SPINNER_MSG
}

# Run a command with spinner and log output.
run_quiet_spinner() {
  # Usage: run_quiet_spinner "Message..." /path/to/log command args...
  local msg="$1"
  local log="$2"
  shift 2

  spinner_start "$msg"
  mkdir -p "$(dirname "$log")"

  "$@" >>"$log" 2>&1 &
  local cmd_pid=$!

  wait "$cmd_pid"
  local rc=$?

  if [[ $rc -eq 0 ]]; then
    spinner_stop OK
  else
    spinner_stop FAIL
  fi

  return "$rc"
}
# -----------------------------------------------

# ---------------- Errors/Traps ----------------
# Report failure with log pointers.
on_error() {
  local exit_code=$?
  echo
  echo "✖ Installer failed (exit code $exit_code)."
  echo "Logs are in: $LOG_DIR"
  echo "Useful logs:"
  echo "  - $LOG_DIR/wineboot.log"
  echo "  - $LOG_DIR/winetricks-win7.log"
  echo "  - $LOG_DIR/winetricks-deps.log"
  echo "  - $LOG_DIR/msvcp140-repair.log"
  echo "  - $LOG_DIR/darkmode.log"
  echo "  - $LOG_DIR/photoshop-extract.log"
  echo "  - $LOG_DIR/lightroom-extract.log"
  exit "$exit_code"
}

trap on_error ERR
trap spinner_cleanup EXIT INT TERM

# ---------------- Prefix/Deps ----------------
# Check if Wine prefix is initialized.
prefix_ready() {
  [[ -f "$PREFIX/system.reg" || -f "$PREFIX/user.reg" || -f "$PREFIX/userdef.reg" ]]
}

# Initialize and validate Wine prefix.
ensure_prefix() {
  need wine
  need winetricks
  need file
  need cabextract
  need tail
  need tar
  need awk
  need mktemp

  mkdir -p "$PREFIX" "$LOG_DIR"

  if ! prefix_ready; then
    section "Prefix setup"
    run_quiet_spinner "Initializing Wine prefix..." "$LOG_DIR/wineboot.log" \
      env WINEPREFIX="$PREFIX" WINEARCH="$WINEARCH_DEFAULT" wineboot -u

    # Wait up to 20 seconds for async init
    for _ in {1..200}; do
      prefix_ready && break
      sleep 0.1
    done
  fi

  if ! prefix_ready; then
    echo
    echo "Prefix still not initialized. Last 120 lines of wineboot log:"
    echo "--------------------------------------------------------"
    tail -n 120 "$LOG_DIR/wineboot.log" 2>/dev/null || true
    echo "--------------------------------------------------------"
    die "Prefix init failed (registry files not created)"
  fi

  # confirm prefix is 64-bit
  if [[ -f "$PREFIX/drive_c/windows/system32/kernel32.dll" ]]; then
    local kinfo
    kinfo="$(file -b "$PREFIX/drive_c/windows/system32/kernel32.dll" || true)"
    if ! grep -q "PE32+" <<<"$kinfo"; then
      die "Prefix does not appear to be 64-bit (kernel32.dll: $kinfo)"
    fi
  fi
}

# ---- WOW64/WINTRICKS BUG WORKAROUND -----------------------------------------
# Verify msvcp140.dll is 64-bit in system32.
msvcp140_system32_is_64bit() {
  local dll="$PREFIX/drive_c/windows/system32/msvcp140.dll"
  [[ -f "$dll" ]] || return 1
  file -b "$dll" | grep -q "PE32+.*x86-64"
}

# Repair broken/missing 64-bit msvcp140.dll.
repair_msvcp140_system32() {
  local redist="$HOME/.cache/winetricks/vcrun2015/vc_redist.x64.exe"
  [[ -f "$redist" ]] || die "Cannot repair msvcp140.dll: missing $redist"

  section "Fixing VC++ runtime (msvcp140.dll)"

  local t out chunk f
  t="$(mktemp -d)"
  out="$(mktemp -d)"
  chunk=""

  run_quiet "$LOG_DIR/msvcp140-repair.log" cabextract -q --directory="$t" "$redist"

  for f in "$t"/a*; do
    [[ -f "$f" ]] || continue
    if cabextract -l "$f" 2>/dev/null | grep -qi 'msvcp140\.dll'; then
      chunk="$f"
      break
    fi
  done
  [[ -n "$chunk" ]] || die "Failed to locate msvcp140.dll inside $redist chunks"

  run_quiet "$LOG_DIR/msvcp140-repair.log" cabextract -q --directory="$out" "$chunk" -F msvcp140.dll
  [[ -f "$out/msvcp140.dll" ]] || die "Extraction failed: msvcp140.dll not produced"

  if ! file -b "$out/msvcp140.dll" | grep -q "PE32+.*x86-64"; then
    run_quiet "$LOG_DIR/msvcp140-repair.log" file "$out/msvcp140.dll" || true
    die "Extracted msvcp140.dll is not 64-bit"
  fi

  local target="$PREFIX/drive_c/windows/system32/msvcp140.dll"
  mkdir -p "$(dirname "$target")"

  if [[ -f "$target" ]]; then
    mv "$target" "$target.bak.$(date +%s)" || true
  fi
  cp -f "$out/msvcp140.dll" "$target"

  echo "[✓] msvcp140.dll repaired (see $LOG_DIR/msvcp140-repair.log)"
  rm -rf "$t" "$out"
}

# Ensure VC++ runtime has correct 64-bit DLL.
ensure_vcrun2015_x64_ok() {
  if msvcp140_system32_is_64bit; then
    return 0
  fi

  echo "Detected broken or missing 64-bit system32/msvcp140.dll:"
  file "$PREFIX/drive_c/windows/system32/msvcp140.dll" 2>/dev/null || echo "(missing)"

  repair_msvcp140_system32
  msvcp140_system32_is_64bit || die "Repair failed: system32/msvcp140.dll is still not 64-bit"
}
# ---------------------------------------------------------------------------

# Install winetricks deps once per prefix.
install_deps_once() {
  local marker="$PREFIX/.winetricks_done"
  [[ -f "$marker" ]] && return 0

  section "Winetricks"
  run_quiet_spinner "Setting Windows version to Win7..." "$LOG_DIR/winetricks-win7.log" \
    env WINEPREFIX="$PREFIX" winetricks -q win7

  run_quiet_spinner "Installing components (vcrun/msxml/fonts)..." "$LOG_DIR/winetricks-deps.log" \
    env WINEPREFIX="$PREFIX" winetricks -q "${WINETRICKS_DEPS[@]}"

  # Reassert Win7 (some winetricks verbs flip versions)
  run_quiet_spinner "Re-applying Win7 (safety)..." "$LOG_DIR/winetricks-win7-post.log" \
    env WINEPREFIX="$PREFIX" winetricks -q win7

  ensure_vcrun2015_x64_ok
  touch "$marker"
}

# ---------------- Overrides ----------------
# Apply Wine DLL overrides for this prefix.
apply_dll_overrides() {
  local entry dll value
  for entry in "${DLL_OVERRIDES[@]}"; do
    dll="${entry%%=*}"
    value="${entry#*=}"
    run_quiet_spinner "Setting override ${dll}=${value}..." "$LOG_DIR/dll-overrides.log" \
      env WINEPREFIX="$PREFIX" wine reg add "HKCU\\Software\\Wine\\DllOverrides" /v "$dll" /t REG_SZ /d "$value" /f
  done
  echo "[✓] DLL overrides applied."
}

# ---------------- Prompts ----------------
# Prompt for app install selection.
select_menu() {
  local c
  to_tty "Install into prefix: $PREFIX"
  to_tty "  1) Photoshop"
  to_tty "  2) Lightroom"
  to_tty "  3) Both"
  to_tty "  4) Prefix only (deps + optional dark mode)"
  to_tty "  5) Quit"
  to_tty_n "Choice [1-5]: "
  c="$(read_tty_line)"
  case "$c" in
    1) echo "photoshop" ;;
    2) echo "lightroom" ;;
    3) echo "both" ;;
    4) echo "prefix-only" ;;
    5) exit 0 ;;
    *) die "Invalid choice" ;;
  esac
}

# Ask whether to apply dark mode.
ask_dark_mode() {
  local d
  to_tty ""
  to_tty "Enable Wine dark mode colors?"
  to_tty "  1) Yes"
  to_tty "  2) No"
  to_tty_n "Choice [1-2]: "
  d="$(read_tty_line)"
  case "$d" in
    1) echo "yes" ;;
    2) echo "no" ;;
    *) echo "no" ;;
  esac
}

# ---------------- Actions ----------------
# Patch Wine registry for dark colors.
set_dark_mode() {
  local reg="$PREFIX/user.reg"
  [[ -f "$reg" ]] || die "user.reg not found (prefix not initialized?): $reg"

  section "Dark mode"

  local tmp_block
  tmp_block="$(mktemp)"

  cat > "$tmp_block" <<'EOF'
[Control Panel\\Colors] 1491939580
#time=1d2b2fb5c69191c
"ActiveBorder"="49 54 58"
"ActiveTitle"="49 54 58"
"AppWorkSpace"="60 64 72"
"Background"="49 54 58"
"ButtonAlternativeFace"="200 0 0"
"ButtonDkShadow"="154 154 154"
"ButtonFace"="49 54 58"
"ButtonHilight"="119 126 140"
"ButtonLight"="60 64 72"
"ButtonShadow"="60 64 72"
"ButtonText"="219 220 222"
"GradientActiveTitle"="49 54 58"
"GradientInactiveTitle"="49 54 58"
"GrayText"="155 155 155"
"Hilight"="119 126 140"
"HilightText"="255 255 255"
"InactiveBorder"="49 54 58"
"InactiveTitle"="49 54 58"
"InactiveTitleText"="219 220 222"
"InfoText"="159 167 180"
"InfoWindow"="49 54 58"
"Menu"="49 54 58"
"MenuBar"="49 54 58"
"MenuHilight"="119 126 140"
"MenuText"="219 220 222"
"Scrollbar"="73 78 88"
"TitleText"="219 220 222"
"Window"="35 38 41"
"WindowFrame"="49 54 58"
"WindowText"="219 220 222"
EOF

  # Patch registry file quietly (log the operation)
  run_quiet_spinner "Writing dark mode colors..." "$LOG_DIR/darkmode.log" \
    bash -c '
      reg="'"$reg"'"
      tmp="'"$tmp_block"'"
      if grep -q "^\[Control Panel\\\\\\\\Colors\]" "$reg"; then
        out="$(mktemp)"
        awk -v repl_file="$tmp" '"'"'
          BEGIN {
            in_section=0
            while ((getline line < repl_file) > 0) repl[++n]=line
            close(repl_file)
          }
          /^\[Control Panel\\\\Colors\]/ {
            for (i=1; i<=n; i++) print repl[i]
            in_section=1
            next
          }
          /^\[/ { if (in_section==1) in_section=0 }
          in_section==1 { next }
          { print }
        '"'"' "$reg" > "$out"
        mv "$out" "$reg"
      else
        printf "\n" >> "$reg"
        cat "$tmp" >> "$reg"
      fi
    '

  rm -f "$tmp_block"

  # Reload Wine services (don’t “|| true” inside the spinner; let it show FAIL if it really fails)
  run_quiet_spinner "Reloading wineserver..." "$LOG_DIR/darkmode.log" \
    env WINEPREFIX="$PREFIX" wineserver -w || true

  # This is a harmless no-op just to touch registry; keep quiet.
  run_quiet_spinner "Refreshing registry..." "$LOG_DIR/darkmode.log" \
    env WINEPREFIX="$PREFIX" wine regedit /S /dev/null || true

  echo "[✓] Dark mode colors applied."
}

# Extract tarball into destination.
extract_tarball() {
  local tarball="$1"
  local dest="$2"
  local log="$3"

  [[ -f "$tarball" ]] || die "Tarball not found: $tarball"
  mkdir -p "$LOG_DIR"

  # Clean destination so reruns are deterministic
  [[ -n "$dest" && "$dest" != "/" ]] || die "Refusing to remove destination: $dest"
  rm -rf "$dest"
  mkdir -p "$dest"

  run_quiet_spinner "Extracting $(basename "$tarball")..." "$log" \
    tar -xzf "$tarball" -C "$dest" --strip-components=1

  if ! find "$dest" -mindepth 1 -maxdepth 2 | head -n 1 >/dev/null 2>&1; then
    die "Extraction produced an empty folder: $dest (check $log)"
  fi
}

# Create a .desktop entry for an app.
create_desktop_for_exe() {
  local name="$1"
  local desktop_file="$2"
  local workdir="$3"
  local exe_abs="$4"
  local icon_abs="$5"

  mkdir -p "$DESKTOP_DIR"
  [[ -f "$exe_abs" ]] || die "EXE not found: $exe_abs"

  local icon_field="wine"
  if [[ -f "$icon_abs" ]]; then
    icon_field="$icon_abs"
  else
    echo "WARNING: Icon not found for $name ($icon_abs). Using generic wine icon."
  fi

  run_quiet_spinner "Creating .desktop for $name..." "$LOG_DIR/desktop-$name.log" \
    bash -c '
      dest="$1"
      app_name="$2"
      prefix="$3"
      exe="$4"
      workdir="$5"
      icon="$6"
      tmp="$(mktemp)"
      printf "[Desktop Entry]\nType=Application\nName=%s\nExec=env WINEPREFIX=\"%s\" wine \"%s\"\nPath=%s\nIcon=%s\nTerminal=false\nCategories=Graphics;Photography;\nStartupNotify=true\n" \
        "$app_name" "$prefix" "$exe" "$workdir" "$icon" > "$tmp"
      chmod 0644 "$tmp"
      mv "$tmp" "$dest"
    ' bash "$desktop_file" "$name" "$PREFIX" "$exe_abs" "$workdir" "$icon_field"

  if command -v update-desktop-database >/dev/null 2>&1; then
    run_quiet_spinner "Updating desktop database..." "$LOG_DIR/desktop-db.log" \
      update-desktop-database "$DESKTOP_DIR"
  fi

  echo "Created: $desktop_file"
}

# Install a portable app from a tarball.
install_app() {
  local name="$1"
  local tarball="$2"
  local dest="$3"
  local exe_name="$4"
  local icon_name="$5"
  local desktop_file="$6"
  local log="$7"

  section "$name"
  extract_tarball "$tarball" "$dest" "$log"

  local exe="$dest/$exe_name"
  local icon="$dest/$icon_name"
  [[ -f "$exe" ]] || die "$name EXE not found after extraction: $exe"

  create_desktop_for_exe "$name" "$desktop_file" "$dest" "$exe" "$icon"
}

# ---------------- Main ----------------
# Main installer flow.
main() {
  local choice dark
  local prefix_only=false
  choose_prefix
  init_paths
  print_header
  choice="$(select_menu)"

  ensure_prefix
  install_deps_once
  apply_dll_overrides

  dark="$(ask_dark_mode)"
  if [[ "$dark" == "yes" ]]; then
    set_dark_mode
  fi

  local -a install_keys

  case "$choice" in
    photoshop) install_keys=(0) ;;
    lightroom) install_keys=(1) ;;
    both) install_keys=(0 1) ;;
    prefix-only)
      install_keys=()
      prefix_only=true
      ;;
    *) die "Invalid selection" ;;
  esac
  for idx in "${install_keys[@]}"; do
    install_app "${APP_NAMES[$idx]}" "${APP_TARBALLS[$idx]}" "${APP_DESTS[$idx]}" \
      "${APP_EXES[$idx]}" "${APP_ICONS[$idx]}" "${APP_DESKTOPS[$idx]}" "${APP_LOGS[$idx]}"
  done

  echo
  echo "[✓] Done"
  echo "Prefix:  $PREFIX"
  if [[ "$prefix_only" == "true" ]]; then
    echo "Apps:    (none installed)"
  else
    echo "Apps:    $PREFIX/drive_c/PortableApps"
  fi
  echo "Logs:    $LOG_DIR"
  echo "Desktop: $DESKTOP_DIR"
  [[ -f "$PS_DESKTOP_FILE" ]] && echo "Photoshop desktop: $PS_DESKTOP_FILE"
  [[ -f "$LR_DESKTOP_FILE" ]] && echo "Lightroom desktop: $LR_DESKTOP_FILE"
}

main "$@"
