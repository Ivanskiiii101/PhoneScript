#!/usr/bin/env bash
# provision.sh - update an Android phone, install Aurora Store, then install a list of apps.
#
# Runs on a computer (Linux/macOS, or Windows via WSL/Git Bash) with the phone connected by USB.
# Requires: adb (Android platform-tools), curl, jq.
#
# Usage: ./provision.sh [-s SERIAL] [--skip-update] [--aurora-only] [--force] [-c apps.conf]

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPS_CONF="$SCRIPT_DIR/apps.conf"
CACHE_DIR="$SCRIPT_DIR/cache"
CACHE_MAX_AGE_MIN=1440          # re-download APKs older than 24 h
AURORA_PKG="com.aurora.store"
AURORA_WAIT_SEC=600             # how long to wait for a tap-install in Aurora

SERIAL=""
SKIP_UPDATE=0
AURORA_ONLY=0
FORCE=0

INSTALLED=()
SKIPPED=()
FAILED=()

# ---------- output helpers ----------
log()  { printf '\033[1;34m[*]\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[+]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }
die()  { printf '\033[1;31m[x]\033[0m %s\n' "$*" >&2; exit 1; }
if { : </dev/tty; } 2>/dev/null; then TTY=/dev/tty; else TTY=/dev/stdin; fi
ask()  { local r=""; read -r -p "$1" r <"$TTY" || true; printf '%s' "$r"; }

usage() {
  sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
  cat <<EOF

Options:
  -s SERIAL       Use this device (needed when several phones are connected)
  -c FILE         App list to use (default: apps.conf)
  --skip-update   Skip the system update step
  --aurora-only   Install every app through Aurora Store (one tap per app on the phone)
  --force         Continue even if the phone model is not on the supported list
  -h, --help      Show this help
EOF
}

# ---------- argument parsing ----------
while [[ $# -gt 0 ]]; do
  case "$1" in
    -s) SERIAL="${2:?missing serial}"; shift 2 ;;
    -c) APPS_CONF="${2:?missing file}"; shift 2 ;;
    --skip-update) SKIP_UPDATE=1; shift ;;
    --aurora-only) AURORA_ONLY=1; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) usage; die "Unknown option: $1" ;;
  esac
done

for cmd in adb curl jq; do
  command -v "$cmd" >/dev/null 2>&1 || die "'$cmd' is not installed (see README)."
done
[[ -f "$APPS_CONF" ]] || die "App list not found: $APPS_CONF"
mkdir -p "$CACHE_DIR"

# ---------- device selection ----------
select_device() {
  local devices unauthorized
  devices=$(adb devices | awk 'NR>1 && $2=="device"{print $1}')
  unauthorized=$(adb devices | awk 'NR>1 && $2=="unauthorized"{print $1}')

  if [[ -z "$SERIAL" ]]; then
    local count
    count=$(printf '%s\n' "$devices" | grep -c . || true)
    if [[ "$count" -eq 0 ]]; then
      [[ -n "$unauthorized" ]] && die "Phone found but not authorized. Unlock it and tap 'Allow' on the USB debugging prompt."
      die "No phone found. Is USB debugging enabled and the cable a data cable?"
    fi
    [[ "$count" -gt 1 ]] && die "Several phones connected. Pick one with -s SERIAL:"$'\n'"$devices"
    SERIAL="$devices"
  fi
  ADB=(adb -s "$SERIAL")
}

prop() { "${ADB[@]}" shell getprop "$1" 2>/dev/null | tr -d '\r'; }

is_installed() { "${ADB[@]}" shell pm list packages "$1" 2>/dev/null | tr -d '\r' | grep -qx "package:$1"; }

check_model() {
  local model brand
  model=$(prop ro.product.model)
  brand=$(prop ro.product.brand)
  log "Connected: $brand $model (serial $SERIAL, Android $(prop ro.build.version.release))"

  # Samsung A06/A07/A13/A14/A15/A16/A17 (incl. 5G variants): SM-A065x, SM-A075x, SM-A13xx ... SM-A17xx
  # Pixel 7a/8a/9a/10a/10/10 Pro/10 Pro XL/10 Pro Fold
  if [[ "$model" =~ ^SM-A(0[67]|1[3-7])[0-9] ]] || \
     [[ "$model" =~ ^Pixel\ (7a|8a|9a|10a|10|10\ Pro|10\ Pro\ XL|10\ Pro\ Fold)$ ]]; then
    ok "Model is on the supported list."
  else
    [[ "$FORCE" -eq 1 ]] && warn "Model '$model' is not on the list - continuing because of --force." \
                         || die "Model '$model' is not on the supported list. Use --force to continue anyway."
  fi
}

# ---------- step 1: system update ----------
wait_for_boot() {
  "${ADB[@]}" wait-for-device
  until [[ "$(prop sys.boot_completed)" == "1" ]]; do sleep 3; done
  sleep 5
}

open_update_screen() {
  local out
  out=$("${ADB[@]}" shell am start -a android.settings.SYSTEM_UPDATE_SETTINGS 2>&1)
  if [[ "$out" == *Error* ]]; then
    # Fallback: open Settings; the technician taps "Software update"/"System update".
    "${ADB[@]}" shell am start -a android.settings.SETTINGS >/dev/null 2>&1
  fi
}

update_os() {
  log "STEP 1/3 - System update"
  local round=1 before after ans
  while true; do
    before=$(prop ro.build.fingerprint)
    log "Build: $(prop ro.build.display.id) | security patch: $(prop ro.build.version.security_patch)"
    open_update_screen
    echo "    On the phone: check for updates, then download and install any update."
    echo "    Android cannot be forced to update over USB on a normal (unrooted) phone,"
    echo "    so this step needs a tap. The script takes over again after the reboot."
    ans=$(ask "    [u] an update is installing  [d] phone says it is up to date  > ")
    case "$ans" in
      d|D) ok "Phone reports it is up to date."; return ;;
    esac

    log "Waiting for the phone to reboot (downloading can take a while)..."
    while "${ADB[@]}" get-state >/dev/null 2>&1; do sleep 5; done
    log "Phone is rebooting..."
    wait_for_boot

    after=$(prop ro.build.fingerprint)
    if [[ "$after" != "$before" ]]; then
      ok "Update $round installed. Checking for more (phones often need several in a row)."
    else
      warn "Build did not change. Checking again."
    fi
    round=$((round + 1))
  done
}

# ---------- download helpers ----------
fetch() {  # fetch URL DEST - download with cache
  local url="$1" dest="$2"
  if [[ -s "$dest" ]] && [[ -n "$(find "$dest" -mmin -"$CACHE_MAX_AGE_MIN" 2>/dev/null)" ]]; then
    return 0
  fi
  curl -fL --retry 3 --connect-timeout 20 -o "$dest.part" "$url" && mv "$dest.part" "$dest"
}

url_fdroid() {  # latest recommended APK from the main F-Droid repo
  local pkg="$1" vc
  vc=$(curl -fsSL "https://f-droid.org/api/v1/packages/$pkg" | jq -r '.suggestedVersionCode // empty') || return 1
  [[ "$vc" =~ ^[0-9]+$ ]] || return 1
  echo "https://f-droid.org/repo/${pkg}_${vc}.apk"
}

url_github() {  # url_github owner/repo REGEX - first asset of latest release matching REGEX
  local repo="$1" re="$2"
  curl -fsSL "https://api.github.com/repos/$repo/releases/latest" |
    jq -r --arg re "$re" '.assets[] | select(.name | test($re)) | .browser_download_url' | head -n1
}

url_json() {  # url_json URL JQ_PATH - e.g. Signal's latest.json
  curl -fsSL "$1" | jq -r "$2 // empty"
}

resolve_url() {  # resolve_url SOURCE ARG PKG
  local source="$1" arg="$2" pkg="$3"
  case "$source" in
    fdroid) url_fdroid "$pkg" ;;
    github) url_github "${arg%% *}" "${arg#* }" ;;
    json)   url_json "${arg%% *}" "${arg#* }" ;;
    url)    echo "$arg" ;;
    *)      return 1 ;;
  esac
}

install_apk_from() {  # install_apk_from NAME PKG SOURCE ARG
  local name="$1" pkg="$2" source="$3" arg="$4" url apk
  url=$(resolve_url "$source" "$arg" "$pkg") || true
  [[ -n "${url:-}" && "$url" != "null" ]] || { warn "$name: could not find a download link ($source)."; return 1; }
  apk="$CACHE_DIR/$pkg.apk"
  log "$name: downloading $url"
  fetch "$url" "$apk" || { warn "$name: download failed."; return 1; }
  log "$name: installing..."
  if "${ADB[@]}" install -r "$apk" >/dev/null 2>&1 && is_installed "$pkg"; then
    return 0
  fi
  warn "$name: adb install failed."
  return 1
}

# ---------- step 2: Aurora Store ----------
install_aurora() {
  log "STEP 2/3 - Aurora Store"
  if is_installed "$AURORA_PKG"; then
    ok "Aurora Store already installed."
  else
    install_apk_from "Aurora Store" "$AURORA_PKG" fdroid "" || die "Could not install Aurora Store."
    ok "Aurora Store installed."
  fi
  "${ADB[@]}" shell monkey -p "$AURORA_PKG" -c android.intent.category.LAUNCHER 1 >/dev/null 2>&1
  echo "    On the phone: finish Aurora's first-run setup (choose Anonymous login,"
  echo "    allow 'Install unknown apps' when asked)."
  ask "    Press Enter when Aurora shows its home screen... " >/dev/null
}

install_via_aurora() {  # install_via_aurora NAME PKG
  local name="$1" pkg="$2" waited=0 r
  "${ADB[@]}" shell am start -a android.intent.action.VIEW \
      -d "market://details?id=$pkg" -p "$AURORA_PKG" >/dev/null 2>&1
  echo "    $name is open in Aurora - tap Install (and confirm the prompt)."
  echo "    Waiting for it to install... (type s + Enter to skip)"
  while (( waited < AURORA_WAIT_SEC )); do
    if is_installed "$pkg"; then return 0; fi
    if read -r -t 5 r <"$TTY" && [[ "$r" == s || "$r" == S ]]; then return 2; fi
    waited=$((waited + 5))
  done
  return 1
}

# ---------- step 3: apps ----------
trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; echo "${s%"${s##*[![:space:]]}"}"; }

install_apps() {
  log "STEP 3/3 - Apps from $(basename "$APPS_CONF")"
  local line name pkg source arg rc
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    IFS='|' read -r name pkg source arg <<<"$line"
    name=$(trim "$name"); pkg=$(trim "$pkg"); source=$(trim "$source"); arg=$(trim "${arg:-}")

    if is_installed "$pkg"; then
      ok "$name already installed."; SKIPPED+=("$name (already installed)"); continue
    fi

    rc=1
    if [[ "$AURORA_ONLY" -eq 0 && "$source" != "aurora" ]]; then
      install_apk_from "$name" "$pkg" "$source" "$arg" && rc=0
      [[ $rc -ne 0 ]] && warn "$name: falling back to Aurora Store."
    fi
    if [[ $rc -ne 0 ]]; then
      install_via_aurora "$name" "$pkg" </dev/null; rc=$?
    fi

    case $rc in
      0) ok "$name installed."; INSTALLED+=("$name") ;;
      2) warn "$name skipped."; SKIPPED+=("$name (skipped by user)") ;;
      *) warn "$name NOT installed."; FAILED+=("$name") ;;
    esac
  done <"$APPS_CONF"
}

summary() {
  echo
  log "Done - $(prop ro.product.model) ($SERIAL)"
  log "Security patch: $(prop ro.build.version.security_patch)"
  for a in "${INSTALLED[@]+"${INSTALLED[@]}"}"; do ok "installed: $a"; done
  for a in "${SKIPPED[@]+"${SKIPPED[@]}"}";   do warn "skipped:   $a"; done
  for a in "${FAILED[@]+"${FAILED[@]}"}";     do printf '\033[1;31m[x]\033[0m failed:    %s\n' "$a"; done
  [[ ${#FAILED[@]} -eq 0 ]]
}

# ---------- main ----------
select_device
check_model
[[ "$SKIP_UPDATE" -eq 1 ]] && warn "Skipping system update (--skip-update)." || update_os
install_aurora
install_apps
summary
