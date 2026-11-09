#!/usr/bin/env bash
#
# platforms/truenas/install.sh
#
# Purpose: install (or update) the torrent stack on TrueNAS 25.10 as a
# TrueNAS "custom app": Gluetun (VPN), qBittorrent with VueTorrent,
# Jackett, FlareSolverr and FileBrowser, from this repository's
# compose.yaml. Run it in the TrueNAS shell (System > Shell, or SSH as an
# admin and `sudo -i` first). It
#   - asks a few questions (or reads TS_* variables when run unattended),
#   - creates the datasets for configs and downloads if they are missing,
#   - copies this repository onto the dataset (update-qbittorrent.sh is
#     mounted into Gluetun from there),
#   - writes the first-run configs (qBittorrent password, Jackett API key
#     and search plugin) with the repository's seeding CLI,
#   - pre-pulls the images, and
#   - creates the app through the TrueNAS middleware API (app.create), or
#     updates it (app.update) when it already exists.
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/truenas/install.sh)"
#
# Run with --help for the options and TS_* variables. See
# platforms/truenas/README.md for the details.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# The msg_info/msg_ok/msg_error output style follows community-scripts/
# ProxmoxVE (https://github.com/community-scripts/ProxmoxVE, misc/build.func,
# Copyright (c) 2021-2026 community-scripts ORG, MIT License). Nothing from
# that project is downloaded or sourced at run time, and this script sends
# no telemetry.

set -Eeuo pipefail
shopt -s inherit_errexit
# Files this script writes are private by default (several hold secrets).
# The few that must be readable by others are made under umask 022 below.
umask 077

# ---------------------------------------------------------------------------
# Constants and options
# ---------------------------------------------------------------------------
REPO_URL="${TS_REPO_URL:-https://github.com/rob-paprocki/qbittorrent-vpn-docker}"
TS_REF="${TS_REF:-main}"
TS_SOURCE_DIR="${TS_SOURCE_DIR:-}"
readonly BACKTITLE="qbittorrent-vpn-docker for TrueNAS"
# TrueNAS's built-in "apps" user and group. TrueNAS's own apps run as
# 568:568 and datasets made with the Apps preset grant this user access.
readonly APPS_UID=568
# gtsteffaniak/filebrowser always runs as uid 1000 (group 1000), whatever
# PUID is (its Dockerfile: adduser -u 1000 filebrowser, USER filebrowser).
# compose.yaml gives it PGID as an extra group (group_add), so the folders
# it uses are made writable for PGID (see group_share).
readonly FILEBROWSER_UID=1000
# Inside Gluetun's network Jackett always listens on 9117 (compose.yaml
# publishes it as JACKETT_PORT:9117), so qBittorrent's search plugin talks
# to 127.0.0.1:9117 whatever JACKETT_PORT is.
readonly JACKETT_INSIDE_PORT=9117
# The file that marks a folder as this installer's copy of the repository
# (the same name as SOURCE_MARKER in truenas_app.py). Only such a folder is
# ever emptied and refilled.
readonly SOURCE_MARKER=.torrent-stack-source
# The four VPN providers Gluetun can do port forwarding with (the stack
# needs it; see .env.example).
readonly PF_PROVIDERS=("protonvpn" "private internet access" "perfect privacy" "privatevpn")

MODE=install          # install | uninstall
DRY_RUN=0
PRINT_YAML=0
RESEED=0
NO_PULL="${TS_NO_PULL:-0}"
UNATTENDED="${TS_UNATTENDED:-0}"
APP_NAME="${TS_APP_NAME:-torrent-stack}"

usage() {
  cat <<EOF
Usage (as root in the TrueNAS shell):
  install.sh                 Install the stack as a custom app, or update the
                             app if it already exists (same command).
  install.sh --update        Update an existing app: refresh the repository
                             copy and re-render the YAML from compose.yaml,
                             keeping the settings in the app's current YAML.
  install.sh --reseed        Also rewrite the first-run configs (qBittorrent
                             password, Jackett API key) from the app's
                             settings. The app is stopped while this runs.
  install.sh --dry-run       Show what would be done and the API payload
                             (secrets masked). Changes nothing.
  install.sh --print-yaml    Print the app YAML (with secrets) to stdout for
                             TrueNAS's "Install via YAML" screen. Changes
                             nothing. Example: ... --print-yaml > app.yaml
  install.sh --uninstall     Delete the app. Datasets and data are kept.
  install.sh --unattended    No questions: take everything from TS_* variables.
  install.sh --no-pull       Do not pre-pull the images (TrueNAS pulls them
                             while it creates the app).
  install.sh --help

With the one-liner, put the options after "install.sh":
  bash -c "\$(curl -fsSL .../platforms/truenas/install.sh)" install.sh --update

Environment variables (all optional; they also pre-fill the wizard):
  TS_APP_NAME=torrent-stack   App name (lowercase letters, digits, -).
  TS_POOL                     Pool for the datasets (default: the Apps pool).
  TS_DATASET                  Parent dataset (default: <pool>/torrent-stack).
                              Its children: configs, and downloads unless
                              TS_DOWNLOADS_DATASET points elsewhere.
  TS_DOWNLOADS_DATASET        Dataset for downloads (default:
                              <TS_DATASET>/downloads).
  TS_<KEY>, TS_<KEY>_FILE     Any .env.example setting, e.g. TS_PUID=1000,
                              TS_TZ=Europe/Berlin, TS_VPN_PROVIDER=protonvpn,
                              TS_VPN_TYPE=wireguard, TS_WIREGUARD_ADDRESSES=...
                              For secrets prefer the _FILE form, a file only
                              root can read, e.g.
                              TS_WIREGUARD_PRIVATE_KEY_FILE=/root/wg.key
                              TS_QBITTORRENT_PASSWORD_FILE=/root/qbit.pw
                              (it is also FileBrowser's admin password:
                              6 characters to 72 bytes, not 'admin')
                              (CONFIG_PATH and the download paths come from
                              the datasets; Watchtower is not used.)
  TS_SOURCE_DIR=/path         Use this checkout instead of cloning GitHub.
  TS_REF=main                 Branch or tag to clone.
  TS_REPO_URL                 Repository to clone (default: this project).
  TS_UI=whiptail|dialog|plain Question style (default: whiptail or dialog if
                              installed, else plain prompts).
  TS_UNATTENDED=1             Same as --unattended.   TS_NO_PULL=1  Same as --no-pull.
  TS_REMOVE_IMAGES=1          With --uninstall, also delete the images.
EOF
}

# ---------------------------------------------------------------------------
# Output helpers (community-scripts style)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  YW=$'\033[33m' RD=$'\033[01;31m' GN=$'\033[1;92m' BL=$'\033[36m' BOLD=$'\033[1m' CL=$'\033[m'
else
  YW="" RD="" GN="" BL="" BOLD="" CL=""
fi
msg_info() { printf '  %s...%s %s\n' "$YW" "$CL" "$1"; }
msg_ok() { printf '  %s[ OK ]%s %s\n' "$GN" "$CL" "$1"; }
msg_warn() { printf '  %s[WARN]%s %s\n' "$YW" "$CL" "$1"; }
msg_error() { printf '  %s[FAIL]%s %s\n' "$RD" "$CL" "$1" >&2; }
show() { printf '  %s%-22s%s %s%s%s\n' "$BOLD" "$1:" "$CL" "$BL" "$2" "$CL"; }
die() {
  msg_error "$1"
  exit "${2:-1}"
}

# Set once this run starts changing the app itself (app.stop, app.create,
# app.update, app.start), so an error message can say what state it is in.
APP_TOUCHED=0
on_err() {
  local rc=$1 line=$2 cmd=$3
  # 130 = the user cancelled; die() has already explained other exits.
  ((rc == 130)) && exit 130
  msg_error "Stopped at line ${line} (exit ${rc}): ${cmd}"
  if ((APP_TOUCHED)); then
    msg_error "The app ${APP_NAME} may now be stopped or half-updated. Fix the cause and run the same command again: it finishes the update and starts the app."
  else
    msg_error "The app itself was not changed yet; fix the cause and run the same command again."
  fi
  exit "$rc"
}
trap 'on_err $? $LINENO "$BASH_COMMAND"' ERR

WORK=""
cleanup() {
  # The work folder holds the settings, including secrets. It lives in
  # RAM (/dev/shm) when possible.
  if [[ -n "$WORK" && -d "$WORK" ]]; then rm -rf -- "$WORK"; fi
  if [[ -n "$SEED_DIR" && -d "$SEED_DIR" ]]; then rm -rf -- "$SEED_DIR"; fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
# midclt passes its arguments to the API as JSON. Only for calls without
# secrets: anything on a command line is visible to every local user.
# midclt reads each argument as JSON when it can (so an app named "true"
# would arrive as a boolean); names are therefore passed through jstr.
tn() { midclt call "$@"; }
# Jobs (app.create, filesystem.chown, ...) need -j, or midclt returns the
# job number instead of waiting. Progress lines go to stderr.
tn_job() { midclt call -j -jp description "$@"; }
# The same for housekeeping jobs (owners, permissions): their progress lines
# are only shown when the job fails.
tn_job_quiet() {
  local rc=0
  midclt call -j -jp description "$@" 2>"$WORK/job.err" || rc=$?
  ((rc == 0)) || cat -- "$WORK/job.err" >&2
  return "$rc"
}

helper() { python3 "$HELPER" "$@"; }
jget() { python3 "$HELPER" json-get "$1"; }

# A JSON string literal, for the few user-supplied strings (dataset names,
# paths) that go into midclt arguments.
jstr() {
  local s=$1
  if [[ "$s" == *[$'\001'-$'\037']* ]]; then die "Control characters are not allowed: '$s'"; fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  printf '"%s"' "$s"
}

# Append KEY=VALUE records (NUL-separated) to a settings layer file. printf
# is a bash builtin, so the values never appear on a command line.
layer_add() {
  local file=$1
  shift
  while (($#)); do
    printf '%s=%s\0' "$1" "$2" >>"$file"
    shift 2
  done
}

# Read NUL-separated KEY=VALUE records into the associative array named $2.
read_records() {
  local file=$1 rec
  local -n _dest=$2
  while IFS= read -r -d '' rec; do
    _dest["${rec%%=*}"]="${rec#*=}"
  done <"$file"
}

valid_app_name() { [[ "$1" =~ ^[a-z]([-a-z0-9]*[a-z0-9])?$ && ${#1} -le 40 ]]; }
# Dataset names: pool/child/..., no spaces or quotes, no hidden or ix-apps
# parts. ZFS allows ':' in names, but it separates the parts of a Compose
# volume entry (host:container:mode), so a path holding one cannot be mounted.
valid_dataset() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*(/[A-Za-z0-9][A-Za-z0-9_.-]*)+$ ]] || return 1
  [[ "/$1/" != */ix-apps/* && "/$1/" != */.ix-apps/* ]]
}
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }

# ---------------------------------------------------------------------------
# Questions: whiptail or dialog when installed, plain prompts otherwise.
# Answers are stored in the variable named by the first argument.
# ---------------------------------------------------------------------------
UI=plain
INTERACTIVE=0

ui_setup() {
  case "${TS_UI:-auto}" in
  whiptail | dialog | plain) UI=$TS_UI ;;
  auto)
    if command -v whiptail >/dev/null 2>&1; then
      UI=whiptail
    elif command -v dialog >/dev/null 2>&1; then
      UI=dialog
    else
      UI=plain
    fi
    ;;
  *) die "TS_UI must be whiptail, dialog or plain" ;;
  esac
  if [[ "$UI" != plain ]] && ! command -v "$UI" >/dev/null 2>&1; then die "$UI is not installed"; fi
}

# whiptail and dialog draw on stdout and print the answer on stderr; swap
# the two so the answer can be captured while the box still shows.
ui_box() { "$UI" --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

# (Their local variables start with _ui_ so they cannot hide the caller's
# variable that the answer is written to.)
ui_yesno() { # title text [yes|no default]
  local _ui_title=$1 _ui_text=$2 _ui_def=${3:-yes} _ui_rc=0 _ui_a
  if [[ "$UI" == plain ]]; then
    printf '\n%s\n' "$_ui_text" >&2
    read -r -p "$_ui_title? [$([[ $_ui_def == yes ]] && echo Y/n || echo y/N)] " _ui_a ||
      die "No answer (end of input)." 130
    _ui_a=${_ui_a:-$_ui_def}
    [[ "$_ui_a" =~ ^[Yy] ]]
    return
  fi
  local _ui_extra=()
  [[ "$_ui_def" == no ]] && _ui_extra=(--defaultno)
  ui_box --title "$_ui_title" "${_ui_extra[@]}" --yesno "$_ui_text" 16 76 || _ui_rc=$?
  ((_ui_rc == 255)) && die "Cancelled." 130
  return "$_ui_rc"
}

ui_input() { # var title text default
  local -n _ui_out=$1
  local _ui_title=$2 _ui_text=$3 _ui_def=$4 _ui_a _ui_rc=0
  if [[ "$UI" == plain ]]; then
    printf '\n%s\n' "$_ui_text" >&2
    read -r -p "$_ui_title [$_ui_def]: " _ui_a || die "No answer (end of input)." 130
    _ui_out=${_ui_a:-$_ui_def}
    return 0
  fi
  _ui_a=$(ui_box --title "$_ui_title" --inputbox "$_ui_text" 14 76 "$_ui_def") || _ui_rc=$?
  ((_ui_rc != 0)) && die "Cancelled." 130
  _ui_out=$_ui_a
}

ui_password() { # var title text   (empty answer allowed)
  local -n _ui_out=$1
  local _ui_title=$2 _ui_text=$3 _ui_a _ui_rc=0
  if [[ "$UI" == plain ]]; then
    printf '\n%s\n' "$_ui_text" >&2
    read -r -s -p "$_ui_title (input hidden): " _ui_a || die "No answer (end of input)." 130
    printf '\n' >&2
    _ui_out=$_ui_a
    return 0
  fi
  # No initial text: whatever is passed to whiptail is on its command line.
  _ui_a=$(ui_box --title "$_ui_title" --passwordbox "$_ui_text" 14 76) || _ui_rc=$?
  ((_ui_rc != 0)) && die "Cancelled." 130
  _ui_out=$_ui_a
}

ui_menu() { # var title text default tag desc [tag desc ...]
  local -n _ui_out=$1
  local _ui_title=$2 _ui_text=$3 _ui_def=$4 _ui_a _ui_rc=0 _ui_i _ui_n
  shift 4
  local _ui_items=("$@")
  if [[ "$UI" == plain ]]; then
    printf '\n%s\n' "$_ui_text" >&2
    _ui_n=0
    for ((_ui_i = 0; _ui_i < ${#_ui_items[@]}; _ui_i += 2)); do
      _ui_n=$((_ui_n + 1))
      printf '   %d) %s  %s\n' "$_ui_n" "${_ui_items[_ui_i]}" "${_ui_items[_ui_i + 1]}" >&2
    done
    while :; do
      read -r -p "$_ui_title [$_ui_def]: " _ui_a || die "No answer (end of input)." 130
      _ui_a=${_ui_a:-$_ui_def}
      if [[ "$_ui_a" =~ ^[0-9]+$ ]] && ((_ui_a >= 1 && _ui_a <= _ui_n)); then
        _ui_out=${_ui_items[(_ui_a - 1) * 2]}
        return 0
      fi
      for ((_ui_i = 0; _ui_i < ${#_ui_items[@]}; _ui_i += 2)); do
        if [[ "${_ui_items[_ui_i]}" == "$_ui_a" ]]; then
          _ui_out=$_ui_a
          return 0
        fi
      done
      printf '   Please type one of the numbers above.\n' >&2
    done
  fi
  _ui_a=$(ui_box --title "$_ui_title" --default-item "$_ui_def" --menu "$_ui_text" 18 76 8 "${_ui_items[@]}") ||
    _ui_rc=$?
  ((_ui_rc != 0)) && die "Cancelled." 130
  _ui_out=$_ui_a
}

ui_note() { # title text
  if [[ "$UI" == plain ]]; then
    printf '\n%s\n' "$2" >&2
  else
    ui_box --title "$1" --msgbox "$2" 16 76 || true
  fi
}

# ---------------------------------------------------------------------------
# Preflight
# ---------------------------------------------------------------------------
TN_VERSION=""
preflight() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this as root. In the TrueNAS shell type: sudo -i   then run the command again."
  command -v midclt >/dev/null 2>&1 || die "midclt was not found. Run this in the TrueNAS shell (System > Shell)."
  command -v python3 >/dev/null 2>&1 || die "python3 was not found."
  # Used to do file work as the apps' user instead of root (util-linux).
  local t
  for t in setpriv unshare mount; do
    command -v "$t" >/dev/null 2>&1 || die "$t was not found (it is part of util-linux, which TrueNAS ships)."
  done
  python3 -c 'import yaml' 2>/dev/null || die "Python's yaml module is missing (TrueNAS ships it; is this TrueNAS?)."
  python3 -c 'import truenas_api_client' 2>/dev/null ||
    die "TrueNAS's Python API client (truenas_api_client) is missing; is this TrueNAS 24.10 or newer?"
  # Gluetun needs the tun device. TrueNAS's kernel has it, but check before
  # creating anything: an app whose first start fails is deleted by TrueNAS.
  if [[ "$MODE" != uninstall && ! -c /dev/net/tun ]]; then
    modprobe tun 2>/dev/null || true
    [[ -c /dev/net/tun ]] || die "/dev/net/tun is missing on this TrueNAS, and 'modprobe tun' did not create it. Gluetun needs it for the VPN tunnel."
  fi
}

# Checks through the API (they need the helper, so they run after fetch_source).
preflight_api() {
  TN_VERSION=$(tn system.version) || die "Could not ask the TrueNAS middleware for its version."
  local major minor
  if [[ "$TN_VERSION" =~ ([0-9]+)\.([0-9]+) ]]; then
    major=$((10#${BASH_REMATCH[1]}))
    minor=$((10#${BASH_REMATCH[2]}))
  else
    die "Unrecognised TrueNAS version: $TN_VERSION"
  fi
  # Docker-based apps and custom apps arrived in 24.10 (Electric Eel).
  if ((major * 100 + minor < 2410)); then
    die "$TN_VERSION is too old: custom Docker apps need TrueNAS 24.10 or newer (25.10 recommended)."
  fi
  if ((major != 25 || minor != 10)); then
    msg_warn "$TN_VERSION: this installer was written against the TrueNAS 25.10 API (27.0 documents the same calls)."
  fi

  local status
  status=$(tn docker.status | jget status) || die "Could not read the status of the Apps service (docker.status)."
  case "$status" in
  RUNNING) ;;
  UNCONFIGURED) die "Apps are not set up yet. In the web UI open Apps, click Configuration > Choose Pool, pick a pool, then run this again." ;;
  *) die "The Apps service is not running (status: ${status:-unknown}). Check Apps in the web UI, then run this again." ;;
  esac
  [[ "$(uname -m)" == x86_64 ]] || msg_warn "This is not an x86-64 system; not every image of the stack may be available."
}

# ---------------------------------------------------------------------------
# Repository
# ---------------------------------------------------------------------------
REPO=""
HELPER=""
fetch_source() {
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    [[ -f "$TS_SOURCE_DIR/compose.yaml" && -f "$TS_SOURCE_DIR/platforms/truenas/truenas_app.py" ]] ||
      die "TS_SOURCE_DIR=$TS_SOURCE_DIR is not a checkout of this repository."
    REPO=$(cd "$TS_SOURCE_DIR" && pwd -P)
    msg_ok "Using the local checkout $REPO"
  else
    [[ "$TS_REF" != -* ]] || die "TS_REF must be a branch or tag name."
    command -v git >/dev/null 2>&1 || die "git was not found (TrueNAS ships it)."
    msg_info "Downloading ${REPO_URL} (${TS_REF})"
    (umask 022 && git clone --quiet --depth 1 --branch "$TS_REF" -- "$REPO_URL" "$WORK/repo") ||
      die "Could not download the repository. Check the internet connection, TS_REF and TS_REPO_URL."
    REPO="$WORK/repo"
    msg_ok "Downloaded $(git -C "$REPO" rev-parse --short HEAD)"
  fi
  HELPER="$REPO/platforms/truenas/truenas_app.py"
}

# ---------------------------------------------------------------------------
# TrueNAS facts
# ---------------------------------------------------------------------------
POOL_NAMES=()
POOL_PATHS=()
DOCKER_POOL=""
SYS_TZ="UTC"
UI_PORTS=()
truenas_facts() {
  local pools general
  pools=$(tn pool.query '[]' '{"select": ["name", "path", "status", "healthy"]}')
  mapfile -t POOL_NAMES < <(jget '*.name' <<<"$pools")
  mapfile -t POOL_PATHS < <(jget '*.path' <<<"$pools")
  ((${#POOL_NAMES[@]})) || die "No storage pools found. Create a pool first (Storage)."
  DOCKER_POOL=$(tn docker.config | jget pool)
  [[ "$DOCKER_POOL" == null ]] && DOCKER_POOL=""
  general=$(tn system.general.config)
  SYS_TZ=$(jget timezone <<<"$general")
  [[ -n "$SYS_TZ" && "$SYS_TZ" != null ]] || SYS_TZ=UTC
  mapfile -t UI_PORTS < <(jget ui_port <<<"$general"; jget ui_httpsport <<<"$general")
}

pool_path() { # pool name -> its mount path
  local i
  for i in "${!POOL_NAMES[@]}"; do
    if [[ "${POOL_NAMES[i]}" == "$1" ]]; then
      printf '%s' "${POOL_PATHS[i]}"
      return 0
    fi
  done
  return 1
}

# Look up a dataset. Sets DS_EXISTS (0/1) and DS_MOUNT (its mountpoint, or
# where it will be mounted once created: under the nearest existing
# parent, as ZFS does by default).
DS_EXISTS=0
DS_MOUNT=""
dataset_info() {
  local name=$1 q n locked typ mount rest=""
  DS_EXISTS=0
  DS_MOUNT=""
  while :; do
    q=$(tn pool.dataset.query "[[\"id\", \"=\", $(jstr "$name")]]" '{"extra": {"retrieve_children": false}}')
    n=$(jget '*.id' <<<"$q" | wc -l)
    if ((n == 1)); then
      typ=$(jget '0.type' <<<"$q")
      locked=$(jget '0.locked' <<<"$q")
      mount=$(jget '0.mountpoint' <<<"$q")
      [[ "$typ" == FILESYSTEM ]] || die "$name is a $typ, not a filesystem dataset."
      [[ "$locked" != true ]] || die "$name is locked (encrypted). Unlock it in Datasets first."
      [[ -n "$mount" && "$mount" != null && "$mount" =~ ^/[A-Za-z0-9_./-]+$ ]] ||
        die "$name is not mounted, or its mountpoint ($mount) has spaces, ':' or other characters this installer does not handle. Use another dataset."
      DS_MOUNT="$mount$rest"
      [[ -z "$rest" ]] && DS_EXISTS=1
      return 0
    fi
    [[ "$name" == */* ]] || die "Pool ${name} does not exist."
    rest="/${name##*/}$rest"
    name=${name%/*}
  done
}

# ---------------------------------------------------------------------------
# Settings layers (see truenas_app.py merge)
# ---------------------------------------------------------------------------
APP_EXISTS=0
APP_STATE=""
declare -A EXMETA=()
read_existing_app() {
  local q n custom
  q=$(tn app.query "[[\"name\", \"=\", $(jstr "$APP_NAME")]]" '{"select": ["name", "state", "custom_app"]}')
  n=$(jget '*.name' <<<"$q" | wc -l)
  ((n == 0)) && return 0
  APP_EXISTS=1
  APP_STATE=$(jget '0.state' <<<"$q")
  custom=$(jget '0.custom_app' <<<"$q")
  [[ "$custom" == true ]] || die "An app named $APP_NAME already exists and is a catalog app, not a custom app. Choose another name (TS_APP_NAME)."
  # The app's YAML holds secrets: keep the copy private.
  (umask 077 && tn app.config "$(jstr "$APP_NAME")" >"$WORK/existing.json") ||
    die "Could not read the YAML of the app $APP_NAME (app.config)."
  helper extract --repo "$REPO" --config "$WORK/existing.json" \
    --out "$WORK/l_existing.nul" --meta "$WORK/existing.meta"
  read_records "$WORK/existing.meta" EXMETA
  if [[ "${EXMETA[FOREIGN]:-0}" == 1 ]]; then
    die "The custom app $APP_NAME does not look like this stack (no gluetun and qbittorrent services). Choose another name (TS_APP_NAME), or delete that app first if you no longer need it."
  fi
}

ENV_KEYS=()
build_layers() {
  mapfile -t ENV_KEYS < <(sed -n 's/^\([A-Z_][A-Z0-9_]*\)=.*/\1/p' "$REPO/.env.example")
  : >"$WORK/l_defaults.nul"
  : >"$WORK/l_env.nul"
  : >"$WORK/l_answers.nul"
  : >"$WORK/l_paths.nul"
  # TrueNAS defaults. The current app's settings (next layer) win over these.
  layer_add "$WORK/l_defaults.nul" PUID "$APPS_UID" PGID "$APPS_UID" TZ "$SYS_TZ" \
    QBITTORRENT_USER admin SCRIPT_NOTIFY_URL ""
  local key var fvar val
  for key in "${ENV_KEYS[@]}"; do
    var="TS_$key"
    fvar="TS_${key}_FILE"
    case "$key" in
    CONFIG_PATH | DOWNLOADS_PATH | INCOMPLETE_DOWNLOADS)
      if [[ -n "${!var+x}" || -n "${!fvar+x}" ]]; then
        die "$var is not used here: the paths come from the datasets (TS_DATASET, TS_DOWNLOADS_DATASET)."
      fi
      continue
      ;;
    COMPOSE_PROFILES | WATCHTOWER_*)
      if [[ -n "${!var:-}" ]]; then msg_warn "$var ignored: Watchtower is not used on TrueNAS (TrueNAS updates app images)."; fi
      continue
      ;;
    esac
    if [[ -n "${!fvar+x}" ]]; then
      [[ -r "${!fvar}" ]] || die "$fvar=${!fvar}: cannot read that file."
      val=$(<"${!fvar}")
      layer_add "$WORK/l_env.nul" "$key" "$val"
    elif [[ -n "${!var+x}" ]]; then
      layer_add "$WORK/l_env.nul" "$key" "${!var}"
    fi
  done
}

declare -A CUR=()
# Merge the layers into values.json and load the non-secret values into CUR
# (secrets only as CUR[__SET_<KEY>]=0/1).
merge_values() { # [extra merge options...]
  # Later layers win: TrueNAS defaults, the existing app (on an update), a
  # generated qBittorrent password (on an install), TS_* variables, wizard
  # answers, and the dataset paths.
  local layers=(--layer "$WORK/l_defaults.nul")
  [[ -f "$WORK/l_existing.nul" ]] && layers+=(--layer "$WORK/l_existing.nul")
  [[ -f "$WORK/l_generated.nul" ]] && layers+=(--layer "$WORK/l_generated.nul")
  layers+=(--layer "$WORK/l_env.nul" --layer "$WORK/l_answers.nul" --layer "$WORK/l_paths.nul")
  local rc=0
  helper merge --repo "$REPO" "${layers[@]}" --out "$WORK/values.json" --show "$WORK/show.nul" "$@" || rc=$?
  CUR=()
  read_records "$WORK/show.nul" CUR
  return "$rc"
}

# ---------------------------------------------------------------------------
# Storage
# ---------------------------------------------------------------------------
POOL=""
BASE_DS=""
CONF_DS=""
DL_DS=""
BASE_MOUNT=""
CONF_MOUNT=""
DL_MOUNT=""
SOURCE_DIR=""
CREATE_DS=() # "name share_type" pairs still to create

plan_storage_fresh() {
  CREATE_DS=()
  valid_dataset "$BASE_DS" || die "Invalid parent dataset name: $BASE_DS (use pool/name, letters, digits, - _ .)"
  valid_dataset "$DL_DS" || die "Invalid downloads dataset name: $DL_DS"
  CONF_DS="$BASE_DS/configs"
  pool_path "${BASE_DS%%/*}" >/dev/null || die "Pool ${BASE_DS%%/*} does not exist."
  pool_path "${DL_DS%%/*}" >/dev/null || die "Pool ${DL_DS%%/*} does not exist."
  # The parent holds the repository copy, whose update-qbittorrent.sh runs
  # as root in Gluetun, so it is a plain (Generic) dataset without the Apps
  # user's write access. Configs and downloads use TrueNAS's Apps preset.
  dataset_info "$BASE_DS"
  BASE_MOUNT=$DS_MOUNT
  ((DS_EXISTS)) || CREATE_DS+=("$BASE_DS GENERIC")
  dataset_info "$CONF_DS"
  CONF_MOUNT=$DS_MOUNT
  ((DS_EXISTS)) || CREATE_DS+=("$CONF_DS APPS")
  dataset_info "$DL_DS"
  DL_MOUNT=$DS_MOUNT
  ((DS_EXISTS)) || CREATE_DS+=("$DL_DS APPS")
  SOURCE_DIR="$BASE_MOUNT/source"
  : >"$WORK/l_paths.nul"
  layer_add "$WORK/l_paths.nul" CONFIG_PATH "$CONF_MOUNT" DOWNLOADS_PATH "$DL_MOUNT" \
    INCOMPLETE_DOWNLOADS "$DL_MOUNT/incomplete"
}

# The app named in a repository copy's marker file (see sync_source), or
# nothing when the folder has no marker.
marker_app() {
  local m="$1/$SOURCE_MARKER"
  [[ -f "$m" && ! -L "$m" ]] || return 0
  sed -n 's/^app=//p' -- "$m" | head -n 1
}

plan_storage_existing() {
  CREATE_DS=()
  [[ -n "${CUR[CONFIG_PATH]:-}" && "${CUR[CONFIG_PATH]}" == /* ]] ||
    die "Could not read CONFIG_PATH back from the app's YAML (the gluetun volumes were changed by hand?). Put the '<configs path>/gluetun:/gluetun' volume back in Apps > $APP_NAME > Edit, or uninstall and install again (your data is kept)."
  CONF_MOUNT=${CUR[CONFIG_PATH]}
  DL_MOUNT=${CUR[DOWNLOADS_PATH]}
  # The repository copy normally sits next to the configs dataset. The
  # YAML says where update-qbittorrent.sh is mounted from, but that line
  # can be edited in the web UI, and the installer replaces the whole
  # folder it names. So another folder is only used when it carries this
  # app's marker file; otherwise the mount goes back to the usual place.
  local default_src yaml_src
  default_src="$(dirname "$CONF_MOUNT")/source"
  yaml_src=${EXMETA[SOURCE_DIR]:-}
  SOURCE_DIR=$default_src
  if [[ -n "$yaml_src" && "$yaml_src" != "$default_src" ]]; then
    if [[ "$(marker_app "$yaml_src")" == "$APP_NAME" ]]; then
      SOURCE_DIR=$yaml_src
    else
      msg_warn "The app's YAML mounts update-qbittorrent.sh from $yaml_src, which is not this installer's copy of the repository. It is mounted from $default_src again; nothing in $yaml_src is touched."
    fi
  fi
  BASE_MOUNT=$(dirname "$SOURCE_DIR")
  if [[ -n "${TS_DATASET:-}${TS_DOWNLOADS_DATASET:-}${TS_POOL:-}" ]]; then
    msg_warn "TS_POOL/TS_DATASET/TS_DOWNLOADS_DATASET are ignored for an existing app; it keeps its folders."
  fi
}

# Is it safe to put the repository copy in SOURCE_DIR? sync_source empties
# that folder and refills it (rsync --delete), and makes it root-owned
# without ACLs, so it must be new, empty, or a copy this installer made
# (it holds the marker file). Runs before anything is changed, also for
# --dry-run. Sets SOURCE_STATE to new, empty or owned.
SOURCE_STATE=""
check_source() {
  local out rc=0 allowed=() p mapp="" q
  for p in "${POOL_PATHS[@]}"; do allowed+=(--allowed-root "$p"); done
  out=$(helper source-check --source-dir "$SOURCE_DIR" "${allowed[@]}" \
    --protect "$CONF_MOUNT" --protect "$DL_MOUNT" 2>&1) || rc=$?
  if ((rc)); then
    printf '%s\n' "$out" | sed 's/^ERROR: /    /' >&2
    die "Not using $SOURCE_DIR for the repository copy: the installer replaces everything in that folder and makes it root-owned. Pick a parent dataset that has no 'source' folder of your own (TS_DATASET or the wizard), or move that folder away first."
  fi
  SOURCE_STATE=$(sed -n 's/^STATE=//p' <<<"$out")
  mapp=$(sed -n 's/^MARKER_APP=//p' <<<"$out")
  # A parent folder that exists already must not be writable by the apps
  # (see check_source_parent); one this run creates is checked once made.
  if [[ -d "$BASE_MOUNT" ]] && ! base_created; then check_source_parent "$BASE_MOUNT" 0; fi
  if [[ "$SOURCE_STATE" == owned && -n "$mapp" && "$mapp" != "$APP_NAME" ]]; then
    # Another app's copy: fine once that app is gone (a reinstall under a
    # new name), not while it still uses the same folders.
    q=$(tn app.query "[[\"name\", \"=\", $(jstr "$mapp")]]" '{"select": ["name"]}')
    if [[ -n "$(jget '*.name' <<<"$q")" ]]; then
      die "$SOURCE_DIR is the repository copy of the app $mapp, which still exists. Use another parent dataset for $APP_NAME (TS_DATASET or the wizard)."
    fi
  fi
}

# update-qbittorrent.sh runs as root inside Gluetun. Whoever can write to
# the folder holding the repository copy could swap the copy for their own
# script, so neither the apps' user (PUID) nor TrueNAS's apps user (568,
# which other apps run as) may write there. A parent dataset this run
# created is fixed (root-owned, 755, no ACL); any other one is refused.
check_source_parent() {
  local parent=$1 created=$2 who
  who=$(source_parent_writers "$parent")
  [[ -z "$who" ]] && return 0
  if ((created)); then
    tn_job_quiet filesystem.setperm "{\"path\": $(jstr "$parent"), \"mode\": \"755\", \"uid\": 0, \"gid\": 0, \"options\": {\"stripacl\": true}}" >/dev/null ||
      die "Could not set the permissions of $parent."
    who=$(source_parent_writers "$parent")
    [[ -z "$who" ]] && return 0
  fi
  die "$parent can be written to by $who. The repository copy in it holds update-qbittorrent.sh, which runs as root in the VPN container, so only root may write to $parent. Remove that write access (Datasets > $parent > Permissions), or pick another parent dataset."
}

# Does this run create the parent dataset (BASE_DS)?
base_created() {
  local item
  for item in "${CREATE_DS[@]}"; do [[ "${item% *}" == "$BASE_DS" ]] && return 0; done
  return 1
}

source_parent_writers() { # folder -> "uid:gid ..." that can write to it
  local ids=("${CUR[PUID]}:${CUR[PGID]}") id writers=()
  [[ "${CUR[PUID]}:${CUR[PGID]}" == "$APPS_UID:$APPS_UID" ]] || ids+=("$APPS_UID:$APPS_UID")
  for id in "${ids[@]}"; do
    if setpriv --reuid="${id%%:*}" --regid="${id##*:}" --clear-groups -- test -w "$1" 2>/dev/null; then
      writers+=("$id")
    fi
  done
  printf '%s' "${writers[*]}"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
ask_vpn() {
  local provider type key user pw addr countries other def=other p
  for p in "${PF_PROVIDERS[@]}"; do [[ "${CUR[VPN_PROVIDER]}" == "$p" ]] && def=$p; done
  ui_menu provider "VPN provider" "Which VPN provider? Port forwarding (needed for seeding) works with these four. 'other' lets you type any Gluetun provider name." \
    "$def" \
    "protonvpn" "ProtonVPN" \
    "private internet access" "PIA" \
    "perfect privacy" "Perfect Privacy" \
    "privatevpn" "PrivateVPN" \
    "other" "another Gluetun provider (no port forwarding)"
  if [[ "$provider" == other ]]; then
    ui_input other "VPN provider" "Gluetun provider name (see the Gluetun wiki, setup/providers):" "${CUR[VPN_PROVIDER]}"
    provider=$other
  fi
  ui_menu type "VPN protocol" "WireGuard or OpenVPN?" "${CUR[VPN_TYPE]}" \
    wireguard "WireGuard (recommended)" openvpn "OpenVPN"
  layer_add "$WORK/l_answers.nul" VPN_PROVIDER "$provider" VPN_TYPE "$type"
  if [[ "$type" == wireguard ]]; then
    ui_password key "WireGuard private key" "PrivateKey from your provider's WireGuard config.$([[ ${CUR[__SET_WIREGUARD_PRIVATE_KEY]} == 1 ]] && echo ' Leave empty to keep the current key.')"
    [[ -n "$key" ]] && layer_add "$WORK/l_answers.nul" WIREGUARD_PRIVATE_KEY "$key"
    ui_input addr "WireGuard address" "The Address line of that config, e.g. 10.2.0.2/32:" "${CUR[WIREGUARD_ADDRESSES]}"
    layer_add "$WORK/l_answers.nul" WIREGUARD_ADDRESSES "$addr"
  else
    ui_input user "OpenVPN username" "OpenVPN username (ProtonVPN: add +pmp for port forwarding):" "${CUR[OPENVPN_USER]}"
    layer_add "$WORK/l_answers.nul" OPENVPN_USER "$user"
    ui_password pw "OpenVPN password" "OpenVPN password.$([[ ${CUR[__SET_OPENVPN_PASSWORD]} == 1 ]] && echo ' Leave empty to keep the current one.')"
    [[ -n "$pw" ]] && layer_add "$WORK/l_answers.nul" OPENVPN_PASSWORD "$pw"
  fi
  ui_input countries "Exit countries" "VPN exit countries, comma-separated (e.g. Switzerland,Netherlands):" "${CUR[SERVER_COUNTRIES]}"
  layer_add "$WORK/l_answers.nul" SERVER_COUNTRIES "$countries"
}

ask_ports() {
  local key p label
  for key in QBIT_WEBUI_PORT JACKETT_PORT FLARESOLVERR_PORT FILEBROWSER_PORT; do
    case "$key" in
    QBIT_WEBUI_PORT) label="qBittorrent web UI" ;;
    JACKETT_PORT) label="Jackett" ;;
    FLARESOLVERR_PORT) label="FlareSolverr" ;;
    FILEBROWSER_PORT) label="FileBrowser" ;;
    esac
    while :; do
      ui_input p "$label port" "Port on the TrueNAS address for $label:" "${CUR[$key]}"
      valid_port "$p" && break
      ui_note "Invalid port" "$p is not a port number (1-65535)."
    done
    layer_add "$WORK/l_answers.nul" "$key" "$p"
  done
}

ask_common() {
  local puid pgid user pw url why
  ui_input puid "PUID" "User ID the apps run as (owner of downloaded files). 568 is TrueNAS's built-in 'apps' user; use your own user's ID (id -u NAME) if you want the files to be yours." "${CUR[PUID]}"
  ui_input pgid "PGID" "Group ID the apps run as. 568 is TrueNAS's 'apps' group." "${CUR[PGID]}"
  layer_add "$WORK/l_answers.nul" PUID "$puid" PGID "$pgid"

  if [[ -n "${CUR[__VPN_MISSING]}" ]]; then
    if ui_yesno "VPN settings" "Enter the VPN settings now?

If you choose No, the app is created with only FileBrowser running. Gluetun, qBittorrent, Jackett and FlareSolverr start once you add the VPN settings: re-run this installer, or edit the app's YAML in Apps (README: 'Adding the VPN settings later')." yes; then
      ask_vpn
    fi
  elif ui_yesno "VPN settings" "VPN: ${CUR[VPN_PROVIDER]} (${CUR[VPN_TYPE]}). Change the VPN settings?" no; then
    ask_vpn
  fi

  if ui_yesno "Ports" "Web UI ports on the TrueNAS address:
  qBittorrent ${CUR[QBIT_WEBUI_PORT]}, Jackett ${CUR[JACKETT_PORT]}, FlareSolverr ${CUR[FLARESOLVERR_PORT]}, FileBrowser ${CUR[FILEBROWSER_PORT]}
Change them?" no; then
    ask_ports
  fi

  ui_input user "qBittorrent user" "qBittorrent web UI username. (FileBrowser's admin user is always 'admin', with the same password.)" "${CUR[QBITTORRENT_USER]}"
  layer_add "$WORK/l_answers.nul" QBITTORRENT_USER "$user"
  # The password is also FileBrowser's admin password. The helper checks it
  # with the same rules as the final check of all settings (read on stdin:
  # printf is a bash builtin, so the password is on no command line).
  while :; do
    ui_password pw "qBittorrent password" "qBittorrent web UI password, also FileBrowser's admin password: 6 characters or more, at most 72 bytes (a character outside ASCII, such as an accented letter, takes 2 to 4 bytes), not 'admin'. Leave empty to $([[ $APP_EXISTS == 1 ]] && echo 'keep the current one' || echo 'have one generated (shown at the end)')."
    [[ -z "$pw" ]] && break
    why=$(printf '%s' "$pw" | helper password-check) && break
    ui_note "Password not accepted" "$why"
  done
  [[ -n "$pw" ]] && layer_add "$WORK/l_answers.nul" QBITTORRENT_PASSWORD "$pw"

  ui_input url "Discord webhook" "Discord webhook URL for port-forward notifications (optional).$([[ ${CUR[__SET_SCRIPT_NOTIFY_URL]} == 1 ]] && echo ' A URL is set; leave empty to keep it, or type none to remove it.' || echo ' Leave empty for none.')" ""
  if [[ "$url" == none ]]; then
    layer_add "$WORK/l_answers.nul" SCRIPT_NOTIFY_URL ""
  elif [[ -n "$url" ]]; then
    layer_add "$WORK/l_answers.nul" SCRIPT_NOTIFY_URL "$url"
  fi
}

wizard_fresh() {
  local pool_items=() i ans
  ui_yesno "torrent-stack" "This installs the torrent stack as a TrueNAS custom app: Gluetun (VPN), qBittorrent, Jackett, FlareSolverr and FileBrowser. qBittorrent, Jackett and FlareSolverr can only reach the internet through the VPN.

TrueNAS ${TN_VERSION}. Continue?" yes || die "Cancelled." 130

  while :; do
    ui_input ans "App name" "Name of the app in TrueNAS (lowercase letters, digits and -, up to 40 characters):" "$APP_NAME"
    valid_app_name "$ans" && break
    ui_note "Invalid name" "'$ans' is not a valid app name."
  done
  if [[ "$ans" != "$APP_NAME" ]]; then
    APP_NAME=$ans
    read_existing_app
    if ((APP_EXISTS)); then
      die "An app named $APP_NAME already exists. Run the installer again to update it (it is detected automatically)."
    fi
  fi

  if ((${#POOL_NAMES[@]} > 1)); then
    for i in "${!POOL_NAMES[@]}"; do pool_items+=("${POOL_NAMES[i]}" "${POOL_PATHS[i]}"); done
    ui_menu POOL "Pool" "Pool for the stack's datasets (configs and downloads):" "$POOL" "${pool_items[@]}"
    BASE_DS="${TS_DATASET:-$POOL/torrent-stack}"
    DL_DS="${TS_DOWNLOADS_DATASET:-$BASE_DS/downloads}"
  fi
  while :; do
    ui_input ans "Parent dataset" "Dataset for the stack. It is created if missing, with a 'configs' child dataset and a copy of this repository in its 'source' folder:" "$BASE_DS"
    valid_dataset "$ans" && pool_path "${ans%%/*}" >/dev/null && break
    ui_note "Invalid dataset" "'$ans' is not a dataset name on one of your pools (${POOL_NAMES[*]})."
  done
  [[ "$ans" != "$BASE_DS" && -z "${TS_DOWNLOADS_DATASET:-}" ]] && DL_DS="$ans/downloads"
  BASE_DS=$ans
  while :; do
    ui_input ans "Downloads dataset" "Dataset for downloads (created if missing). An existing dataset, e.g. a media share, works too: the apps' PUID/PGID need write access to it." "$DL_DS"
    valid_dataset "$ans" && pool_path "${ans%%/*}" >/dev/null && break
    ui_note "Invalid dataset" "'$ans' is not a dataset name on one of your pools (${POOL_NAMES[*]})."
  done
  DL_DS=$ans
  ask_common
}

wizard_update() {
  ui_yesno "Update $APP_NAME" "The app $APP_NAME exists (state: $APP_STATE). Its YAML is rebuilt from the current compose.yaml, keeping the settings in it.

Change any settings first (PUID/PGID, VPN, ports, qBittorrent login)?" no || return 0
  ask_common
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------
declare -A OLD=()
port_conflicts() { # prints one line per problem
  local key p used=() listening=() own=() u
  mapfile -t used < <(tn app.used_ports | jget '*')
  if command -v ss >/dev/null 2>&1; then
    mapfile -t listening < <(ss -Htln 2>/dev/null | awk '{print $4}' | sed 's/.*://' | sort -u)
  fi
  if ((APP_EXISTS)); then
    own=("${OLD[QBIT_WEBUI_PORT]:-}" "${OLD[JACKETT_PORT]:-}" "${OLD[FLARESOLVERR_PORT]:-}" "${OLD[FILEBROWSER_PORT]:-}")
  fi
  local found=()
  for key in QBIT_WEBUI_PORT JACKETT_PORT FLARESOLVERR_PORT FILEBROWSER_PORT; do
    p=${CUR[$key]}
    if [[ " ${own[*]} " == *" $p "* ]]; then continue; fi
    for u in "${UI_PORTS[@]}"; do
      if [[ "$u" == "$p" ]]; then found+=("$key=$p is the TrueNAS web UI's port"); fi
    done
    for u in "${used[@]}"; do
      if [[ "$u" == "$p" ]]; then found+=("$key=$p is used by another app"); fi
    done
    for u in "${listening[@]}"; do
      if [[ "$u" == "$p" ]]; then found+=("$key=$p is already in use on this system"); fi
    done
  done
  if ((${#found[@]})); then printf '%s\n' "${found[@]}" | sort -u; fi
  return 0
}

# ---------------------------------------------------------------------------
# Changes
# ---------------------------------------------------------------------------
IMAGES=()
GATED=()
BINDS=()
render_yaml() { # output-file [--redact]
  local out=$1
  shift
  local allowed=() p
  for p in "${POOL_PATHS[@]}"; do allowed+=(--allowed-root "$p"); done
  helper render --repo "$REPO" --values "$WORK/values.json" --app-name "$APP_NAME" \
    --source-dir "$SOURCE_DIR" "${allowed[@]}" --out-yaml "$out" --meta "$WORK/meta.nul" "$@"
  IMAGES=()
  GATED=()
  BINDS=()
  local rec
  while IFS= read -r -d '' rec; do
    case "$rec" in
    IMAGE=*) IMAGES+=("${rec#IMAGE=}") ;;
    GATED=*) GATED+=("${rec#GATED=}") ;;
    BIND=*) BINDS+=("${rec#BIND=}") ;;
    esac
  done <"$WORK/meta.nul"
}

# Owner of a folder the stack mounts: PUID, unless only FileBrowser uses it.
bind_owner() {
  local path=$1 b svc src only_fb=1
  for b in "${BINDS[@]}"; do
    IFS=$'\t' read -r svc src _ <<<"$b"
    [[ "$src" == "$path" && "$svc" != filebrowser ]] && only_fb=0
  done
  if ((only_fb)); then echo "$FILEBROWSER_UID"; else echo "${CUR[PUID]}"; fi
}

tn_chown() { # path uid gid recursive(true|false)
  tn_job_quiet filesystem.chown "{\"path\": $(jstr "$1"), \"uid\": $2, \"gid\": $3, \"options\": {\"recursive\": $4}}" >/dev/null ||
    die "Could not set the owner of $1."
}

# Let the PGID group write to a folder, and make what is created in it
# belong to that group (setgid, the "s"). FileBrowser runs as uid 1000 and
# gets at the stack's files only through PGID (compose.yaml: group_add).
# The symbolic mode leaves the owner's and everyone else's bits alone
# (extra changes, such as o-rwx, can be added). This is a plain chmod, not
# filesystem.setperm, because setperm only sets a mode after stripping the
# ACL, and the Apps preset's ACL is what gives TrueNAS's apps user access.
# ZFS allows chmod on those datasets (the preset sets aclmode=passthrough);
# on one with aclmode=restricted (the SMB preset) it fails. Then the ACL
# decides, and there is only a warning if it keeps FileBrowser out.
group_share() { # folder [extra chmod changes]
  local dir=$1 extra=${2:-}
  [[ -d "$dir" && ! -L "$dir" ]] || return 0
  chmod "g+rwxs${extra:+,$extra}" -- "$dir" 2>/dev/null && return 0
  filebrowser_can_write "$dir" ||
    msg_warn "Could not make $dir writable for group ${CUR[PGID]} (chmod g+rwxs), so FileBrowser cannot change files there. Give that group write access in Datasets > Permissions."
}

# Can FileBrowser's user (uid 1000, group 1000, plus PGID from group_add)
# write to this folder?
filebrowser_can_write() {
  setpriv --reuid="$FILEBROWSER_UID" --regid="$FILEBROWSER_UID" --groups="${CUR[PGID]}" -- test -w "$1" 2>/dev/null
}

create_datasets() {
  local item name st q mount
  for item in "${CREATE_DS[@]}"; do
    name=${item% *}
    st=${item##* }
    msg_info "Creating dataset $name ($st)"
    tn pool.dataset.create "{\"name\": $(jstr "$name"), \"type\": \"FILESYSTEM\", \"share_type\": \"$st\", \"create_ancestors\": true, \"comments\": \"torrent-stack\"}" >/dev/null ||
      die "Could not create dataset $name."
    q=$(tn pool.dataset.query "[[\"id\", \"=\", $(jstr "$name")]]" '{"extra": {"retrieve_children": false}}')
    mount=$(jget '0.mountpoint' <<<"$q")
    case "$name" in
    "$BASE_DS") [[ "$mount" == "$BASE_MOUNT" ]] || die "$name is mounted at $mount, expected $BASE_MOUNT" ;;
    "$CONF_DS") [[ "$mount" == "$CONF_MOUNT" ]] || die "$name is mounted at $mount, expected $CONF_MOUNT" ;;
    "$DL_DS")
      [[ "$mount" == "$DL_MOUNT" ]] || die "$name is mounted at $mount, expected $DL_MOUNT"
      # qBittorrent writes completed downloads straight into it, and
      # FileBrowser manages them through the PGID group.
      tn_chown "$DL_MOUNT" "${CUR[PUID]}" "${CUR[PGID]}" false
      group_share "$DL_MOUNT"
      ;;
    esac
    msg_ok "Created dataset $name at $mount"
  done
}

prepare_folders() {
  local b svc src owner
  for b in "${BINDS[@]}"; do
    IFS=$'\t' read -r svc src _ <<<"$b"
    [[ "$src" == "$SOURCE_DIR"/* ]] && continue # repository files
    if [[ ! -e "$src" ]]; then
      # 0755 (umask 022), as Docker would create it; only the owner is set.
      (umask 022 && mkdir -p -- "$src")
      owner=$(bind_owner "$src")
      tn_chown "$src" "$owner" "${CUR[PGID]}" false
      # A new folder in the downloads (incomplete/): FileBrowser shows it
      # too, so the PGID group may write there. Only folders made in this
      # run are changed; FileBrowser itself can write in the downloads, so
      # the installer (root) does not chmod what it finds there later.
      if [[ "$src" == "$DL_MOUNT" || "$src" == "$DL_MOUNT"/* ]]; then group_share "$src"; fi
      msg_ok "Created $src (owner $owner:${CUR[PGID]})"
    fi
  done
  # The per-app config folders belong to the user each app runs as, also
  # after a PUID/PGID change (they are small, so this is quick).
  # FileBrowser's (only FileBrowser mounts it) belongs to uid 1000, the user
  # it runs as, with group PGID: 2770, writable for both and closed to
  # everyone else, as its database holds the password hashes and the key
  # that signs FileBrowser's logins. That folder is set on every run (an
  # older installer made it 0755); no container can swap it for a link, as
  # it is the folder mounted at /config, not something inside it.
  for b in "${BINDS[@]}"; do
    IFS=$'\t' read -r svc src _ <<<"$b"
    [[ "$src" == "$CONF_MOUNT"/* ]] || continue
    tn_chown "$src" "$(bind_owner "$src")" "${CUR[PGID]}" true
    if [[ "$(bind_owner "$src")" == "$FILEBROWSER_UID" && "$svc" == filebrowser ]]; then group_share "$src" o-rwx; fi
  done
  msg_ok "Config folders belong to ${CUR[PUID]}:${CUR[PGID]} (FileBrowser's to $FILEBROWSER_UID:${CUR[PGID]}, mode 2770)"
  # A downloads dataset the user brought along: check, do not change.
  if ! setpriv --reuid="${CUR[PUID]}" --regid="${CUR[PGID]}" --clear-groups -- test -w "$DL_MOUNT" 2>/dev/null; then
    msg_warn "User ${CUR[PUID]}:${CUR[PGID]} cannot write to $DL_MOUNT. qBittorrent will fail to save downloads until you fix its permissions (Datasets > Permissions)."
  fi
  if ! filebrowser_can_write "$DL_MOUNT"; then
    msg_warn "FileBrowser (user $FILEBROWSER_UID, extra group ${CUR[PGID]}) cannot write to $DL_MOUNT: it shows the downloads but cannot upload, rename or delete there. To allow it, give group ${CUR[PGID]} write access (Datasets > Permissions), or: chgrp ${CUR[PGID]} $DL_MOUNT && chmod g+rwxs $DL_MOUNT"
  fi
}

SCRIPT_CHANGED=0
sync_source() {
  local before="" after created=0
  base_created && created=1
  check_source_parent "$BASE_MOUNT" "$created"
  # Checked again right before copying (check_source ran before any change).
  check_source
  (umask 022 && mkdir -p -- "$SOURCE_DIR")
  # Re-run from the copy itself (TS_SOURCE_DIR=$SOURCE_DIR): nothing to copy.
  [[ "$(cd "$REPO" && pwd -P)" == "$(cd "$SOURCE_DIR" && pwd -P)" ]] && return 0
  [[ -f "$SOURCE_DIR/update-qbittorrent.sh" ]] && before=$(sha256sum "$SOURCE_DIR/update-qbittorrent.sh")
  # The marker goes in first: if the copy stops halfway, the next run still
  # recognises the folder as its own.
  rm -f -- "${SOURCE_DIR:?}/$SOURCE_MARKER"
  (umask 022 && printf 'app=%s\n%s\n' "$APP_NAME" \
    "# Copy of github.com/rob-paprocki/qbittorrent-vpn-docker made by platforms/truenas/install.sh. Everything in this folder is replaced on every update; do not keep your own files here." \
    >"$SOURCE_DIR/$SOURCE_MARKER")
  msg_info "Copying the repository to $SOURCE_DIR"
  # --one-file-system: never descend into (or empty) another dataset that
  # happens to be mounted inside this folder. The marker is excluded, so
  # --delete keeps it.
  (umask 022 && rsync -a --delete --one-file-system --no-owner --no-group \
    --exclude="/$SOURCE_MARKER" \
    --exclude=.git --exclude=/configs --exclude=/downloads --exclude=/.env \
    --include=/.env.example --exclude='/.env.*' \
    --exclude=.venv --exclude=__pycache__ -- "$REPO/" "$SOURCE_DIR/")
  # update-qbittorrent.sh runs as root inside Gluetun: only root may change
  # it. stripacl drops any ACL inherited from the parent dataset (such as
  # the Apps preset's write access for the apps user). Not recursive into
  # child datasets ("traverse" is off).
  tn_job_quiet filesystem.setperm "{\"path\": $(jstr "$SOURCE_DIR"), \"uid\": 0, \"gid\": 0, \"options\": {\"recursive\": true, \"stripacl\": true}}" >/dev/null ||
    die "Could not set the permissions of $SOURCE_DIR."
  # Readable by everyone (the apps' user runs the seeding CLI from this
  # copy), writable only by root. -xdev: this folder's dataset only;
  # symbolic links are skipped (chmod would change what they point to).
  find "$SOURCE_DIR" -xdev ! -type l -exec chmod u+rwX,go+rX,go-w -- {} +
  chmod 0755 -- "$SOURCE_DIR/update-qbittorrent.sh"
  after=$(sha256sum "$SOURCE_DIR/update-qbittorrent.sh")
  [[ "$before" == "$after" ]] || SCRIPT_CHANGED=1
  msg_ok "Repository copied to $SOURCE_DIR"
}

# Run a command as the apps' user (PUID:PGID) for the seeding, in a private
# mount namespace: qBittorrent's and Jackett's config folders and the
# repository copy are bind-mounted into SEED_DIR, the way the containers see
# their folders, and the command works only there. So that user never has
# to pass through the configs dataset itself (TrueNAS's Apps preset lets
# only root and the apps user 568 in, not, say, uid 1000), and the mounts
# disappear with the command.
seed_as_app_user() {
  # shellcheck disable=SC2016 # $1.. are expanded by the inner sh
  unshare --mount --propagation private -- sh -c '
    mount --bind -- "$1" "$2/code" &&
      mount --bind -- "$3" "$2/root/qbittorrent" &&
      mount --bind -- "$4" "$2/root/jackett" || exit 1
    uid=$5 gid=$6
    shift 6
    exec setpriv --reuid="$uid" --regid="$gid" --clear-groups -- "$@"' \
    sh "$SOURCE_DIR" "$SEED_DIR" "$CONF_MOUNT/qbittorrent" "$CONF_MOUNT/jackett" \
    "${CUR[PUID]}" "${CUR[PGID]}" "$@"
}

SEED_DIR=""
seed_configs() {
  # The config folders belong to the apps, so the containers can change
  # anything in them (a link, for instance). Everything that writes there
  # therefore runs as the apps' user, never as root (see seed_as_app_user),
  # with the code from the root-owned repository copy on the dataset. The
  # settings for the seeding CLI go in that user's private folder, in RAM,
  # removed again at the end.
  local rc=0 fail d
  if ((APP_EXISTS)); then
    fail="Seeding the configs failed (see above). The app $APP_NAME is stopped; fix the cause and run the same command again (it starts the app again)."
  else
    fail="Seeding the configs failed (see above). Nothing was created in Apps yet; run the same command again."
  fi
  for d in qbittorrent jackett; do
    [[ -d "$CONF_MOUNT/$d" && ! -L "$CONF_MOUNT/$d" ]] || die "$CONF_MOUNT/$d is missing or not a folder."
  done
  SEED_DIR=$(mktemp -d "$(dirname "$WORK")/torrent-stack.seed.XXXXXX")
  mkdir -p -- "$SEED_DIR/code" "$SEED_DIR/root/qbittorrent" "$SEED_DIR/root/jackett"
  helper envfile --repo "$REPO" --values "$WORK/values.json" --out "$SEED_DIR/seed.env"
  chown -R -- "${CUR[PUID]}:${CUR[PGID]}" "$SEED_DIR"
  chmod 700 -- "$SEED_DIR"
  # As the seeding user sees them (inside SEED_DIR):
  local code="$SEED_DIR/code" q="$SEED_DIR/root/qbittorrent/qBittorrent"

  msg_info "Writing first-run configs (qBittorrent, Jackett)"
  # 1. A qBittorrent.conf that does not exist yet gets the image's defaults
  #    first (downloads to /downloads, UPnP off). The LinuxServer image
  #    only adds them when there is no file at all, and step 3 creates one.
  seed_as_app_user python3 -I "$code/platforms/truenas/truenas_app.py" qbit-defaults \
    --repo "$code" --conf "$q/qBittorrent.conf" >/dev/null || die "$fail"
  # 2. The Jackett search plugin from the commit pinned in native/versions.env
  #    (checked against its sha256). The seeding CLI then keeps that file.
  seed_as_app_user python3 -I "$code/platforms/truenas/truenas_app.py" fetch-plugin \
    --repo "$code" --dest "$q/nova3/engines/jackett.py" >/dev/null || rc=$?
  # rc 4: no plugin pins in this copy's native/versions.env. The seeding
  # CLI refuses an unpinned plugin too, so there is no fallback.
  ((rc == 0)) || die "$fail"
  # 3. The seeding CLI: qBittorrent login and search plugin settings,
  #    Jackett API key. The search plugin reaches Jackett at
  #    127.0.0.1:9117 inside Gluetun's network (JACKETT_PORT is only the
  #    port on the TrueNAS address). FileBrowser needs nothing here:
  #    compose.yaml sets its "admin" password from QBITTORRENT_PASSWORD
  #    every time it starts.
  seed_as_app_user python3 -I "$code/scripts/env-editor/seed_configs.py" --env "$SEED_DIR/seed.env" \
    --config-root "$SEED_DIR/root" --only jackett,qbit --jackett-port "$JACKETT_INSIDE_PORT" || die "$fail"
  # 4. qBittorrent 5.3 reads its login from [WebUI] once it has started
  #    the first time. The seeding CLI writes it there as well by now; this
  #    step also moves the leftover [Preferences] WebUI\ copies there.
  seed_as_app_user python3 -I "$code/platforms/truenas/truenas_app.py" qbit-webui-fix \
    --repo "$code" --conf "$q/qBittorrent.conf" >/dev/null || die "$fail"
  rm -rf -- "$SEED_DIR"
  SEED_DIR=""
  local b svc src
  for b in "${BINDS[@]}"; do
    IFS=$'\t' read -r svc src _ <<<"$b"
    [[ "$src" == "$CONF_MOUNT"/* ]] || continue
    tn_chown "$src" "$(bind_owner "$src")" "${CUR[PGID]}" true
  done
  msg_ok "First-run configs written"
}

prepull_images() {
  local img
  # TrueNAS pulls missing images inside app.create, with a time limit, and
  # a failed pull there only says "Failed 'up' action". Pulling first gives
  # a clear error per image and makes the app start quickly.
  for img in "${IMAGES[@]}"; do
    msg_info "Pulling $img"
    tn_job app.image.pull "{\"image\": $(jstr "$img")}" >/dev/null ||
      die "Could not pull $img. Check the internet connection and DNS of TrueNAS (Network > Global Configuration); Docker Hub may also be rate-limiting you. Then run the same command again."
    msg_ok "Pulled $img"
  done
}

# The app's state as TrueNAS reports it now: RUNNING, DEPLOYING, STOPPED,
# STOPPING or CRASHED (empty if there is no such app).
app_state() {
  tn app.query "[[\"name\", \"=\", $(jstr "$APP_NAME")]]" '{"select": ["name", "state"]}' | jget '0.state'
}

# When this installer stops the app (to rewrite its configs), it leaves
# this file in the configs dataset until the app runs again. So if anything
# fails in between, the next run knows to start the app even when nothing
# else is left to change.
STOP_MARK=""

start_app() {
  APP_TOUCHED=1
  msg_info "Starting $APP_NAME"
  if ! tn_job app.start "$(jstr "$APP_NAME")" >/dev/null; then
    die "app.start failed (TrueNAS's log: /var/log/app_lifecycle.log). The app is $(app_state || true) now. Fix the cause and run the same command again, or start the app in Apps."
  fi
  [[ -n "$STOP_MARK" ]] && rm -f -- "$STOP_MARK"
  msg_ok "Started $APP_NAME"
}

deploy() {
  local mode=$1
  helper payload --mode "$mode" --app-name "$APP_NAME" --yaml "$WORK/app.yaml" --out "$WORK/payload.json"
  if [[ "$mode" == create ]]; then
    msg_info "Creating the app $APP_NAME (this can take a few minutes)"
  else
    msg_info "Updating the app $APP_NAME (its containers are recreated)"
  fi
  APP_TOUCHED=1
  if ! helper call "app.$mode" --job --params "$WORK/payload.json" --out "$WORK/result.json"; then
    msg_error "app.$mode failed. TrueNAS's own logs: /var/log/app_lifecycle.log and /var/log/middlewared.log."
    if [[ "$mode" == create ]]; then
      msg_error "TrueNAS removes an app whose first start fails; the datasets and configs stay, so you can run the same command again."
    else
      # TrueNAS saves the new YAML before it starts the containers, so the
      # YAML may already be the new one while the app is down.
      msg_error "The app is $(app_state || true) now; its YAML may already be the new one. Fix the cause and run the same command again: it starts the app if nothing else is left to change."
    fi
    exit 1
  fi
  rm -f -- "$WORK/payload.json"
  msg_ok "app.$mode finished (state: $(jget state <"$WORK/result.json"))"
}

lan_ip() {
  local ip
  ip=$(ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  printf '%s' "${ip:-<truenas-ip>}"
}

summary() {
  local ip state
  ip=$(lan_ip)
  state=$(app_state)
  echo
  printf '  %sDone.%s\n\n' "$GN" "$CL"
  show "App" "$APP_NAME (Apps in the TrueNAS web UI)"
  show "State" "${state:-unknown}"
  show "qBittorrent" "http://$ip:${CUR[QBIT_WEBUI_PORT]}"
  show "Jackett" "http://$ip:${CUR[JACKETT_PORT]}"
  show "FlareSolverr" "http://$ip:${CUR[FLARESOLVERR_PORT]}"
  show "FileBrowser" "http://$ip:${CUR[FILEBROWSER_PORT]}"
  show "Configs" "$CONF_MOUNT"
  show "Downloads" "$DL_MOUNT"
  if [[ "$SHOW_PASSWORD" == 1 ]]; then
    show "qBittorrent login" "${CUR[QBITTORRENT_USER]} / $(helper get --values "$WORK/values.json" QBITTORRENT_PASSWORD)"
    echo "    Write it down. It is also in the app's YAML (Apps > $APP_NAME > Edit, QBITTORRENT_PASSWORD)."
  fi
  echo "    FileBrowser login: admin, with the qBittorrent password (FileBrowser sets it again on every start)."
  case "$state" in
  RUNNING | DEPLOYING) ;;
  *)
    echo
    msg_warn "The app is ${state:-in an unknown state}, not running. Start it in Apps, or: midclt call -j app.start $APP_NAME"
    echo "    If it does not start, TrueNAS's log says why: /var/log/app_lifecycle.log"
    ;;
  esac
  if ((${#GATED[@]})); then
    echo
    msg_warn "The VPN settings are not filled in (${CUR[__VPN_MISSING]}). Only FileBrowser runs for now."
    echo "    To finish: run this installer again and enter the VPN settings, or in the web UI"
    echo "    open Apps > $APP_NAME > Edit, fill in the VPN settings under gluetun > environment,"
    echo "    delete the four 'profiles: [vpn-not-configured]' entries and save."
  fi
  if [[ "${OLD[PUID]:-${CUR[PUID]}}" != "${CUR[PUID]}" || "${OLD[PGID]:-${CUR[PGID]}}" != "${CUR[PGID]}" ]]; then
    msg_warn "PUID/PGID changed: the config folders were updated, the downloads were not. If needed: chown -R ${CUR[PUID]}:${CUR[PGID]} $DL_MOUNT"
  fi
}

# ---------------------------------------------------------------------------
# Uninstall
# ---------------------------------------------------------------------------
do_uninstall() {
  read_existing_app
  if ((APP_EXISTS == 0)); then
    msg_ok "There is no app named $APP_NAME. Nothing to do."
    return 0
  fi
  build_layers
  merge_values || true
  if ((INTERACTIVE)); then
    ui_yesno "Uninstall" "Delete the app $APP_NAME? Its containers are removed. The datasets and their data (configs ${CUR[CONFIG_PATH]:-?}, downloads ${CUR[DOWNLOADS_PATH]:-?}) are kept." no ||
      die "Cancelled." 130
  fi
  local remove_images=false
  [[ "${TS_REMOVE_IMAGES:-0}" == 1 ]] && remove_images=true
  if ((DRY_RUN)); then
    msg_info "Would call: midclt call -j app.delete $APP_NAME {\"remove_images\": $remove_images}"
    return 0
  fi
  msg_info "Deleting the app $APP_NAME"
  # Only remove_images: TrueNAS 27 dropped force_remove_ix_volumes, and this
  # app has no ix-volumes (its data lives on your datasets).
  tn_job app.delete "$(jstr "$APP_NAME")" "{\"remove_images\": $remove_images}" >/dev/null ||
    die "app.delete failed (see /var/log/app_lifecycle.log)."
  msg_ok "Deleted the app $APP_NAME"
  echo "    Kept: ${CUR[CONFIG_PATH]:-the configs}, ${CUR[DOWNLOADS_PATH]:-the downloads} and ${EXMETA[SOURCE_DIR]:-the repository copy}."
  echo "    To remove them too, delete the datasets in Datasets (select the dataset > Delete)."
  [[ "$remove_images" == false ]] && echo "    Images were kept; remove them in Apps > Configuration > Manage Container Images."
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
SHOW_PASSWORD=0

main() {
  local want_update=0
  while (($#)); do
    case "$1" in
    --update) want_update=1 ;;
    --reseed) RESEED=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --print-yaml) PRINT_YAML=1 ;;
    --uninstall) MODE=uninstall ;;
    --unattended) UNATTENDED=1 ;;
    --no-pull) NO_PULL=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "Unknown option: $1 (see --help)" ;;
    esac
    shift
  done
  # With --print-yaml only the YAML goes to stdout; messages go to stderr.
  if ((PRINT_YAML)); then
    exec 3>&1 1>&2
  fi
  valid_app_name "$APP_NAME" || die "TS_APP_NAME=$APP_NAME is not a valid app name (lowercase letters, digits, -)."

  if [[ "$UNATTENDED" != 1 && -t 0 && -t 2 ]]; then INTERACTIVE=1; fi
  # Tests drive the wizard through a stand-in whiptail or piped answers.
  [[ "${TS_INTERACTIVE:-0}" == 1 ]] && INTERACTIVE=1
  ((INTERACTIVE)) && ui_setup

  printf '\n  %storrent-stack for TrueNAS%s\n\n' "$BOLD" "$CL"
  preflight
  if [[ -d /dev/shm && -w /dev/shm ]]; then
    WORK=$(mktemp -d /dev/shm/torrent-stack.XXXXXX)
  else
    WORK=$(mktemp -d)
  fi
  chmod 700 "$WORK"
  fetch_source
  preflight_api

  if [[ "$MODE" == uninstall ]]; then
    do_uninstall
    return 0
  fi

  truenas_facts
  read_existing_app
  if ((APP_EXISTS == 0 && (want_update || RESEED))); then
    die "There is no app named $APP_NAME to update. Run without --update/--reseed to install it."
  fi
  build_layers

  if ((APP_EXISTS)); then
    msg_ok "Found the app $APP_NAME (state: $APP_STATE); it will be updated"
    # The app's settings as they are now (without TS_* or wizard changes),
    # to see later what changed.
    helper merge --repo "$REPO" --layer "$WORK/l_defaults.nul" --layer "$WORK/l_existing.nul" \
      --out "$WORK/values.old.json" --show "$WORK/old.nul" || true
    OLD=()
    read_records "$WORK/old.nul" OLD
    merge_values || true
    plan_storage_existing
    ((INTERACTIVE)) && wizard_update
  else
    POOL=${TS_POOL:-${DOCKER_POOL:-${POOL_NAMES[0]}}}
    pool_path "$POOL" >/dev/null || die "Pool $POOL does not exist (pools: ${POOL_NAMES[*]})."
    BASE_DS=${TS_DATASET:-$POOL/torrent-stack}
    DL_DS=${TS_DOWNLOADS_DATASET:-$BASE_DS/downloads}
    merge_values --generate-qbit-password || true
    # Keep that generated password unless TS_* or the wizard sets one: the
    # later merges run without --generate-qbit-password.
    if ! grep -qz '^QBITTORRENT_PASSWORD=' "$WORK/l_env.nul"; then
      printf 'QBITTORRENT_PASSWORD=%s\0' "$(helper get --values "$WORK/values.json" QBITTORRENT_PASSWORD)" \
        >"$WORK/l_generated.nul"
      SHOW_PASSWORD=1
    fi
    if ((INTERACTIVE)); then wizard_fresh; fi
    # A password typed in the wizard replaces the generated one.
    grep -qz '^QBITTORRENT_PASSWORD=' "$WORK/l_answers.nul" && SHOW_PASSWORD=0
    plan_storage_fresh
  fi

  if ! merge_values --need-paths; then
    die "Some settings are not valid (listed above). Fix them (TS_* variables or the wizard) and run again."
  fi

  # Port conflicts make TrueNAS's first `docker compose up` fail.
  local conflicts
  conflicts=$(port_conflicts)
  if [[ -n "$conflicts" ]]; then
    printf '%s\n' "$conflicts" | sed 's/^/    /' >&2
    die "Port conflict. Pick other ports (wizard, or TS_QBIT_WEBUI_PORT / TS_JACKETT_PORT / TS_FLARESOLVERR_PORT / TS_FILEBROWSER_PORT)."
  fi

  # Did the wizard or TS_* change the qBittorrent login of an existing app?
  # Then qBittorrent.conf must be re-seeded to match.
  if ((APP_EXISTS)) &&
    ! helper same --a "$WORK/values.old.json" --b "$WORK/values.json" QBITTORRENT_USER QBITTORRENT_PASSWORD; then
    RESEED=1
    msg_info "The qBittorrent login changed; the first-run configs will be rewritten to match"
  fi

  render_yaml "$WORK/app.yaml"

  if ((PRINT_YAML)); then
    cat -- "$WORK/app.yaml" >&3
    msg_warn "The YAML above holds your secrets (VPN key, qBittorrent password). Keep it private."
    if ((APP_EXISTS == 0)); then
      echo "    Before pasting it into Apps > Discover Apps > Install via YAML, create the folders it"
      echo "    mounts and copy update-qbittorrent.sh to $SOURCE_DIR (see README, 'Install via YAML by hand')."
    fi
    return 0
  fi

  # Before anything is changed (and for --dry-run too): is the repository
  # copy's folder one this installer may replace?
  check_source
  STOP_MARK="$CONF_MOUNT/.torrent-stack-stopped"

  local yaml_changed=1
  if ((APP_EXISTS)); then
    local d
    d=$(helper diff --old "$WORK/existing.json" --new-yaml "$WORK/app.yaml")
    if [[ -z "$d" ]]; then
      yaml_changed=0
      msg_ok "The app's YAML is already up to date"
    else
      echo "  Changes to the app's YAML (values are not shown):"
      printf '%s\n' "$d"
      if grep -q 'removed:' <<<"$d"; then
        msg_warn "Entries marked 'removed' are not in compose.yaml (for example edits you made by hand in the web UI) and will be dropped."
      fi
    fi
  fi
  local seed=0
  ((APP_EXISTS == 0 || RESEED)) && seed=1

  if ((DRY_RUN)); then
    echo
    echo "  Dry run: nothing is changed. Would:"
    local item
    for item in "${CREATE_DS[@]}"; do echo "    - create dataset ${item% *} (share type ${item##* })"; done
    case "$SOURCE_STATE" in
    owned) echo "    - replace the contents of $SOURCE_DIR (this installer's copy of the repository) with the current repository" ;;
    empty) echo "    - copy the repository into the empty folder $SOURCE_DIR" ;;
    *) echo "    - create $SOURCE_DIR and copy the repository into it" ;;
    esac
    echo "      (root-owned and read-only for everyone else; update-qbittorrent.sh runs as root in Gluetun)"
    echo "    - create missing folders and set owners (PUID ${CUR[PUID]}, PGID ${CUR[PGID]}); new download"
    echo "      folders and FileBrowser's config folder become writable for group ${CUR[PGID]} (setgid)"
    ((seed)) && echo "    - write the first-run configs in $CONF_MOUNT"
    ((NO_PULL)) || echo "    - pull ${IMAGES[*]}"
    # Sent through TrueNAS's Python API client, not midclt (see truenas_app.py).
    if ((APP_EXISTS)); then
      echo "    - call the job app.update with these parameters (secrets masked):"
    else
      echo "    - call the job app.create with these parameters (secrets masked):"
    fi
    render_yaml "$WORK/app.redacted.yaml" --redact
    helper payload --mode "$( ((APP_EXISTS)) && echo update || echo create)" --app-name "$APP_NAME" \
      --yaml "$WORK/app.redacted.yaml" --out -
    return 0
  fi

  if ((INTERACTIVE)); then
    ui_yesno "Ready" "$( ((APP_EXISTS)) && echo "Update the app $APP_NAME now?" || echo "Create the app $APP_NAME now?

Datasets: ${CREATE_DS[*]:-(all exist)}
Configs: $CONF_MOUNT
Downloads: $DL_MOUNT")" yes || die "Cancelled." 130
  fi

  create_datasets
  sync_source
  prepare_folders

  # Re-deploy only when something changed: a new app, a changed YAML, a
  # changed update-qbittorrent.sh (Gluetun mounts that file, so it must be
  # recreated to see the new one), or re-seeded configs.
  local deploy_needed=0
  ((APP_EXISTS == 0 || yaml_changed || SCRIPT_CHANGED || seed)) && deploy_needed=1
  # Pull before stopping anything, so the app is down for as short as possible.
  if ((deploy_needed && !NO_PULL)); then prepull_images; fi

  # The app counts as "running before" if it is not STOPPED, or if an
  # earlier run of this installer stopped it and did not get to start it
  # again (STOP_MARK).
  local was_running=0
  if ((APP_EXISTS)) && { [[ "$APP_STATE" != STOPPED ]] || [[ -e "$STOP_MARK" ]]; }; then
    was_running=1
  fi
  if ((seed)); then
    if ((APP_EXISTS)) && [[ "$APP_STATE" != STOPPED ]]; then
      # qBittorrent rewrites its config when it stops, so stop it first.
      msg_info "Stopping $APP_NAME to rewrite its configs"
      rm -f -- "$STOP_MARK"
      (umask 077 && printf 'stopped by platforms/truenas/install.sh; it starts the app again\n' >"$STOP_MARK")
      APP_TOUCHED=1
      tn_job app.stop "$(jstr "$APP_NAME")" >/dev/null
      APP_STATE=STOPPED
    fi
    seed_configs
  fi

  if ((APP_EXISTS == 0)); then
    deploy create
  elif ((deploy_needed)); then
    deploy update
    # app.update only recreates the containers of an app that is not
    # STOPPED; a stopped one is started here if it was running before.
    if [[ "$APP_STATE" == STOPPED ]]; then
      if ((was_running)); then
        start_app
      else
        msg_warn "$APP_NAME was stopped before; it stays stopped. Start it in Apps when you are ready."
      fi
    else
      [[ -e "$STOP_MARK" ]] && rm -f -- "$STOP_MARK"
    fi
  else
    # Nothing to change. Still make sure the app runs if an earlier run
    # left it down (STOP_MARK), or if it crashed.
    local state
    state=$(app_state)
    if [[ "$state" == RUNNING || "$state" == DEPLOYING ]]; then
      # Started by hand since; nothing left to finish.
      rm -f -- "$STOP_MARK"
    elif [[ -e "$STOP_MARK" || "$state" == CRASHED ]]; then
      msg_warn "$APP_NAME is ${state:-not running}$([[ -e $STOP_MARK ]] && echo ' (an earlier run of this installer stopped it)'); starting it."
      start_app
    elif [[ "$state" == STOPPED ]] && ((INTERACTIVE)); then
      if ui_yesno "Start $APP_NAME" "The app $APP_NAME is stopped. Start it now?" yes; then start_app; fi
    fi
  fi
  summary
}

main "$@"
