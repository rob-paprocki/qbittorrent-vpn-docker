#!/usr/bin/env bash
#
# platforms/casaos/install.sh
#
# Purpose: run as root on a CasaOS or ZimaOS host (its terminal, or SSH).
# Installs this repository's Docker Compose stack (Gluetun, qBittorrent,
# Jackett, FlareSolverr, FileBrowser) as ONE CasaOS app, so it shows on the
# dashboard and is started, stopped and uninstalled there like any other app:
#
#   * the repository goes to /DATA/AppData/torrent-stack, with its .env
#     (the single source of truth for every setting) and configs/;
#   * a CasaOS flavour of compose.yaml is rendered from .env: absolute /DATA
#     paths, every value written out in full (CasaOS does not read .env
#     files), and the x-casaos metadata the dashboard needs;
#   * qBittorrent and Jackett are seeded with the repository's seeding CLI
#     (the host's python3 when it has one, otherwise a throwaway python
#     container; ZimaOS ships no python3, as far as we know), as the apps'
#     user, never as root;
#   * the app is installed (or updated) through CasaOS's app-management
#     API: the same call the dashboard's "Install a customized app > Import"
#     and `casaos-cli app-management install` make;
#   * once CasaOS has started it, the script checks what Docker cannot show:
#     that CasaOS really switched to the new definition, that qBittorrent,
#     Jackett and FlareSolverr are in Gluetun's network, that every web UI
#     answers, and that qBittorrent accepts the login in .env.
#
#   Install (wizard):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/casaos/install.sh)"
#   After editing /DATA/AppData/torrent-stack/.env:
#     bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --apply
#   Update the scripts and the container images:
#     bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh --update
#
# Run with --help for every option and environment variable. --dry-run shows
# what would be written and sent without changing anything.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# The msg_info / msg_ok / msg_error output style follows community-scripts/
# ProxmoxVE (https://github.com/community-scripts/ProxmoxVE, MIT), by way of
# the other installers in platforms/. The app format and the API calls follow
# IceWhaleTech's CasaOS-AppManagement and CasaOS-AppStore sources (links in
# platforms/casaos/README.md, References). Nothing from those projects is
# downloaded or sourced at run time, and this script sends no telemetry.

set -Eeuo pipefail
shopt -s inherit_errexit
# Folders and repository files readable by the apps whatever umask the
# caller's shell has; files holding secrets are created 0600 explicitly.
umask 022

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# The CasaOS app name is the Compose project name. It must match
# `name: torrent-stack` in compose.yaml, and it is the folder name under
# /DATA/AppData (CasaOS's convention: /DATA/AppData/<app name>).
readonly STACK="torrent-stack"
# Reverse-domain app id (x-casaos.id), as the CasaOS / ZimaOS AppStore
# validator requires. Used to recognise our own app on re-runs.
readonly APP_ID="io.github.rob-paprocki.torrent-stack"
# Version of the CasaOS rendering below. Bump it when the rendered compose
# changes shape; it is shown as the app version on the dashboard.
readonly RENDER_VERSION="1.1.0"

# Whether these were given on this run. When they were not, --update reuses
# the branch/tag and fork the stack was installed from (kept in
# .casaos-state), and the stack folder is found from the script's own
# location or the installed app instead of assuming /DATA/AppData.
TS_REF_GIVEN=${TS_REF:+1}
TS_REPO_URL_GIVEN=${TS_REPO_URL:+1}
TS_APPDATA_GIVEN=${TS_APPDATA:+1}
REPO_URL="${TS_REPO_URL:-https://github.com/rob-paprocki/qbittorrent-vpn-docker}"
REPO_URL="${REPO_URL%.git}"
readonly RAW_URL="https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/casaos/install.sh"
TS_REF="${TS_REF:-main}"
TS_SOURCE_DIR="${TS_SOURCE_DIR:-}"

# CasaOS and ZimaOS locations (the same on both; ZimaOS kept CasaOS's
# paths). The TS_CASAOS_* overrides exist for the test suite.
readonly CASAOS_RUNTIME_DIR="${TS_CASAOS_RUNTIME_DIR:-/var/run/casaos}"
readonly CASAOS_GATEWAY_INI="${TS_CASAOS_GATEWAY_INI:-/etc/casaos/gateway.ini}"
readonly CASAOS_APPS_DIR="${TS_CASAOS_APPS_DIR:-/var/lib/casaos/apps}"
readonly API_PREFIX="/v2/app_management"
# CasaOS 0.4.4 introduced compose apps and the v2 app-management API.
readonly MIN_CASAOS="0.4.4"

# Throwaway container for scripts/env-editor/seed_configs.py when the host's
# python3 cannot run it. Pinned by tag and by digest (the digest is what
# docker actually pulls), bumped by hand; the same image as Unraid's.
readonly SEED_IMAGE="python:3.14.9-slim-trixie@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8"
# The seeders to run. FileBrowser's is left out: compose.yaml sets its
# "admin" password on every start (FILEBROWSER_ADMIN_PASSWORD, from
# QBITTORRENT_PASSWORD), and the current image never reads the file that
# seeder writes. It is also the only one that needs bcrypt, so nothing is
# pip-installed anywhere.
readonly SEEDERS="jackett,qbit"

# CasaOS's own defaults for $PUID/$PGID in AppStore apps are 1000/1000.
readonly DEFAULT_PUID=1000
readonly DEFAULT_PGID=1000
readonly DEFAULT_APPDATA="/DATA/AppData"
# CasaOS's Downloads share. Deliberately NOT inside a folder named after the
# app: CasaOS's "delete app data" uninstall removes any mounted folder whose
# path contains the app name.
readonly DEFAULT_DOWNLOADS="/DATA/Downloads"

# The two config seeds tracked in git (copied into CONFIG_PATH when missing).
readonly TRACKED_SEEDS=(
  "jackett/Jackett/ServerConfig.json"
  "qbittorrent/qBittorrent/qBittorrent.conf"
)
# .env keys that hold secrets: never printed in full.
readonly SECRET_KEYS=" WIREGUARD_PRIVATE_KEY OPENVPN_PASSWORD QBITTORRENT_PASSWORD SCRIPT_NOTIFY_URL WATCHTOWER_NOTIFICATION_URL "
# Every .env key the rendered compose writes out. Each value is checked by
# check_inline_values before rendering.
readonly COMPOSE_KEYS=(
  PUID PGID TZ CONFIG_PATH DOWNLOADS_PATH INCOMPLETE_DOWNLOADS
  VPN_TYPE VPN_PROVIDER OPENVPN_USER OPENVPN_PASSWORD OPENVPN_PROTOCOL
  WIREGUARD_PRIVATE_KEY WIREGUARD_ADDRESSES PORT_FORWARD_ONLY
  VPN_PORT_FORWARDING SERVER_COUNTRIES
  QBIT_WEBUI_PORT JACKETT_PORT FLARESOLVERR_PORT FILEBROWSER_PORT
  QBITTORRENT_USER QBITTORRENT_PASSWORD SCRIPT_NOTIFY_URL
  COMPOSE_PROFILES WATCHTOWER_NOTIFICATION_URL WATCHTOWER_NOTIFICATION_LEVEL
  WATCHTOWER_TITLE_TAG WATCHTOWER_SCHEDULE
)
# Dashboard icon: a small SVG embedded as a data: URI, so the dashboard does
# not fetch anything from a third-party CDN. (A shield with a download arrow.)
readonly ICON_DATA_URI="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA2NCA2NCI+PHJlY3Qgd2lkdGg9IjY0IiBoZWlnaHQ9IjY0IiByeD0iMTQiIGZpbGw9IiMxZjNiNTciLz48cGF0aCBkPSJNMzIgOGwxOSA3djE0YzAgMTIuNS04IDIxLjUtMTkgMjZDMjEgNTAuNSAxMyA0MS41IDEzIDI5VjE1eiIgZmlsbD0iIzJmYTg2YiIvPjxwYXRoIGQ9Ik0zMiAxOXYxOW0tOC04bDggOCA4LThNMjMgNDVoMTgiIGZpbGw9Im5vbmUiIHN0cm9rZT0iI2ZmZiIgc3Ryb2tlLXdpZHRoPSI0IiBzdHJva2UtbGluZWNhcD0icm91bmQiIHN0cm9rZS1saW5lam9pbj0icm91bmQiLz48L3N2Zz4="

# Ports the apps listen on INSIDE Gluetun's network. Jackett listens on the
# Port in its ServerConfig.json (seeded as 9117) and FlareSolverr on its PORT
# variable (default 8191), so JACKETT_PORT and FLARESOLVERR_PORT in .env only
# choose the port on the host side (compose.yaml publishes JACKETT_PORT:9117
# and FLARESOLVERR_PORT:8191). qBittorrent is different: its WEBUI_PORT
# follows QBIT_WEBUI_PORT, so that port is the same inside and outside.
readonly JACKETT_INTERNAL_PORT=9117
readonly FLARESOLVERR_INTERNAL_PORT=8191
# The FileBrowser image always runs as uid 1000 (its Dockerfile: adduser -u
# 1000, USER filebrowser), whatever PUID is. compose.yaml adds the PGID group
# (group_add), so it reaches the downloads and its config folder through
# that group.
readonly FILEBROWSER_UID=1000

# Label on every container: a hash of that service's definition (for
# Gluetun, also of update-qbittorrent.sh). It tells, from `docker ps`, which
# containers CasaOS has really switched to the new definition.
readonly REV_LABEL="io.github.rob-paprocki.torrent-stack.rev"

# How long to wait for CasaOS to start the app (seconds), and how often to
# look. Image downloads plus Gluetun's first health check take minutes.
WAIT_SECS="${TS_WAIT:-900}"
POLL_SECS="${TS_POLL_INTERVAL:-5}"
# How long the web UIs get to answer once the containers run (seconds).
# qBittorrent first downloads the VueTorrent mod, which can take a while.
UI_WAIT="${TS_UI_WAIT:-300}"
# Where the kernel shows each process's network namespace (a test hook).
PROC_DIR="${TS_PROC_DIR:-/proc}"

# ---------------------------------------------------------------------------
# Output helpers (community-scripts style: msg_info / msg_ok / msg_error).
# Everything goes to stderr, so --print-yaml can keep stdout for the YAML.
# ---------------------------------------------------------------------------
if [[ -t 2 ]]; then
  YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m'
  DGN=$'\033[32m' BOLD=$'\033[1m' CL=$'\033[m'
else
  YW="" BL="" RD="" GN="" DGN="" BOLD="" CL=""
fi

msg_info() { printf '  %s... %s%s\n' "$YW" "$1" "$CL" >&2; }
msg_ok() { printf '  [ OK ] %s%s%s\n' "$GN" "$1" "$CL" >&2; }
msg_warn() { printf '  [WARN] %s%s%s\n' "$YW" "$1" "$CL" >&2; }
msg_error() { printf '  [FAIL] %s%s%s\n' "$RD" "$1" "$CL" >&2; }
msg_dry() { printf '  [DRY ] %s%s%s\n' "$BL" "$1" "$CL" >&2; }
show() { printf '  %s%-22s%s %s%s%s\n' "$BOLD$DGN" "$1:" "$CL" "$BL" "$2" "$CL" >&2; }
note() { printf '%s\n' "$@" >&2; }
die() {
  msg_error "$1"
  exit "${2:-1}"
}

header_info() {
  cat >&2 <<'EOF'

  _____                         _       ____  _             _
 |_   _|__  _ __ _ __ ___ _ __ | |_    / ___|| |_ __ _  ___| | __
   | |/ _ \| '__| '__/ _ \ '_ \| __|___\___ \| __/ _` |/ __| |/ /
   | | (_) | |  | | |  __/ | | | ||_____|__) | || (_| | (__|   <
   |_|\___/|_|  |_|  \___|_| |_|\__|   |____/ \__\__,_|\___|_|\_\
     Gluetun + qBittorrent + Jackett + FlareSolverr  (CasaOS / ZimaOS)

EOF
}

usage() {
  cat <<EOF
One-liner (as root on the CasaOS / ZimaOS host):
  bash -c "\$(curl -fsSL ${RAW_URL})"
  Options go after it as: bash -c "\$(curl -fsSL ...)" install.sh --dry-run

Usage (as root):
  install.sh                 Install, or re-run to change the answers. Asks
                             for the downloads folder, the VPN and the
                             qBittorrent login. Safe to re-run.
  install.sh --apply         After editing .env: check it, re-seed the
                             configs if the login changed, and send the new
                             app definition to CasaOS (it restarts only what
                             changed).
  install.sh --update        Download this repository again (keeps .env and
                             configs; same branch/tag as last time), pull new
                             container images, and apply with the new script.
  install.sh --print-yaml    Print the CasaOS app YAML for the current .env
                             to stdout, for the dashboard's manual Import.
                             It contains your VPN key and passwords.
  install.sh --uninstall     Remove the app from CasaOS. Keeps
                             ${DEFAULT_APPDATA}/${STACK} (configs, .env) and
                             your downloads.
  install.sh --uninstall --purge
                             Also delete ${DEFAULT_APPDATA}/${STACK}.
                             Downloads are never deleted.
Options:
  --no-register              Prepare everything (files, .env, seeding) but do
                             not talk to CasaOS; then import the YAML by hand.
  --dry-run                  Show what would be written and sent; change
                             nothing. (CasaOS is still asked to validate.)
  --unattended, -y           No questions: answers come from TS_* variables,
                             the existing .env, or the defaults.
  --help

Exit codes: 0 done; 1 error (nothing or not everything changed, see the
  message); 2 the app did not come up in time (usually the VPN login);
  3 the app runs but a check failed (a web UI does not answer, the
  qBittorrent login is refused, or an app lost Gluetun's network).

Environment variables (all optional; they also pre-fill the questions):
  TS_APPDATA=${DEFAULT_APPDATA}    The stack goes in <it>/${STACK}. Not needed
                             later: the script finds the installed stack.
  TS_DOWNLOADS=${DEFAULT_DOWNLOADS}  Downloads folder (incomplete/ inside).
  TS_TZ, TS_PUID (${DEFAULT_PUID}), TS_PGID (${DEFAULT_PGID})
  TS_VPN_PROVIDER (protonvpn), TS_VPN_TYPE (wireguard|openvpn),
  TS_WIREGUARD_ADDRESSES, TS_OPENVPN_USER, TS_OPENVPN_PROTOCOL,
  TS_SERVER_COUNTRIES, TS_QBITTORRENT_USER (admin), TS_WATCHTOWER (0|1)
  TS_QBIT_WEBUI_PORT, TS_JACKETT_PORT, TS_FLARESOLVERR_PORT, TS_FILEBROWSER_PORT
  Secrets are read from files, never from the command line (first line of
  the file; chmod 600 it):
  TS_WIREGUARD_PRIVATE_KEY_FILE, TS_OPENVPN_PASSWORD_FILE,
  TS_QBITTORRENT_PASSWORD_FILE, TS_SCRIPT_NOTIFY_URL_FILE
  TS_SOURCE_DIR=/path        Copy this local checkout instead of downloading.
  TS_REF=main                Branch or tag to download.  TS_REPO_URL  for a fork.
                             --update remembers both from the last download.
  TS_CASAOS_API=http://127.0.0.1:PORT
                             app-management address, if it cannot be found.
  TS_WAIT=${WAIT_SECS}               Seconds to wait for the app to come up.
  TS_UI_WAIT=${UI_WAIT}            Seconds the web UIs get to answer after that.
  TS_RESEED=1                Seed the qBittorrent login again even if .env's
                             login has not changed.
  TS_IPV6_SYSCTL=auto|on|off Gluetun's IPv6-off sysctl; auto leaves it out
                             when the kernel has no IPv6 (ipv6.disable=1).
  TS_FORCE=1                 Take over a CasaOS app named ${STACK} that this
                             installer did not create.
  TS_UI=whiptail|dialog|plain  Question style (default: whiptail if present).
EOF
}

# ---------------------------------------------------------------------------
# Error handling and cleanup
# ---------------------------------------------------------------------------
TEMP_DIR=""
on_exit() {
  local rc=$?
  [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]] && rm -rf "$TEMP_DIR"
  exit "$rc"
}
on_error() {
  local rc=$1 line=$2 cmd=$3
  trap - ERR
  msg_error "Line ${line}: '${cmd}' failed (exit ${rc})."
  exit "$rc"
}
trap 'on_error $? $LINENO "$BASH_COMMAND"' ERR
trap on_exit EXIT
trap 'echo >&2; msg_error "Interrupted."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
ACTION="install"
DRY_RUN=0
PURGE=0
NO_REGISTER=0
UNATTENDED="${TS_UNATTENDED:-0}"
TS_FORCE="${TS_FORCE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) ACTION="apply" ;;
    --update) ACTION="update" ;;
    --uninstall) ACTION="uninstall" ;;
    --print-yaml) ACTION="print-yaml" ;;
    --purge) PURGE=1 ;;
    --no-register) NO_REGISTER=1 ;;
    --dry-run) DRY_RUN=1 ;;
    --unattended | -y | --yes) UNATTENDED=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      die "Unknown option: $1"
      ;;
  esac
  shift
done
[[ "$PURGE" == 1 && "$ACTION" != uninstall ]] && die "--purge only goes with --uninstall."
[[ "$WAIT_SECS" =~ ^[0-9]+$ ]] || die "TS_WAIT must be a number of seconds."
[[ "$POLL_SECS" =~ ^[0-9]+$ ]] || die "TS_POLL_INTERVAL must be a number of seconds."
[[ "$UI_WAIT" =~ ^[0-9]+$ ]] || die "TS_UI_WAIT must be a number of seconds."

# Questions are asked only on a terminal and only when not unattended.
INTERACTIVE=0
[[ "$UNATTENDED" != 1 && -t 0 ]] && INTERACTIVE=1
if [[ "$INTERACTIVE" == 0 && "$UNATTENDED" != 1 && "$ACTION" == install && "$DRY_RUN" != 1 ]]; then
  die "No terminal to ask questions on. Run this in the CasaOS/ZimaOS terminal or over SSH, or add --unattended (answers from TS_* variables and defaults)."
fi

# ---------------------------------------------------------------------------
# Questions: whiptail (CasaOS on Debian/Ubuntu has it), dialog, or plain
# prompts (ZimaOS seems to have neither). Same helpers as platforms/truenas/install.sh.
# Answers are stored in the variable named by the first argument.
# ---------------------------------------------------------------------------
UI=plain
BACKTITLE="Torrent stack for CasaOS / ZimaOS"

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

# (Local variables start with _ui_ so they cannot hide the caller's
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
  ui_box --title "$_ui_title" "${_ui_extra[@]}" --yesno "$_ui_text" 18 76 || _ui_rc=$?
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

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

# run CMD...: run a command that changes something; in --dry-run, print it.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would run: $(printf '%q ' "$@")"
    return 0
  fi
  "$@"
}

# read_secret_file VAR PATH: first line of a file (for unattended secrets).
read_secret_file() {
  local __var=$1 path=$2 line=""
  [[ -f "$path" && -r "$path" ]] || die "Secret file '$path' does not exist or is not readable."
  if [[ -n "$(find "$path" -maxdepth 0 -perm /077 2>/dev/null)" ]]; then
    msg_warn "$path can be read by other users; chmod 600 it."
  fi
  IFS= read -r line <"$path" || true
  line="${line%$'\r'}"
  [[ -n "$line" ]] || die "Secret file '$path' is empty."
  printf -v "$__var" '%s' "$line"
}

# version_ge A B: true when version A >= B (dotted numbers).
version_ge() {
  [[ "$(printf '%s\n%s\n' "$2" "$1" | sort -V | head -n1)" == "$2" ]]
}

valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && ((10#$1 >= 1 && 10#$1 <= 65535)); }
is_secret_key() { [[ "$SECRET_KEYS" == *" $1 "* ]]; }

random_password() {
  # 20 letters and digits. head reads a fixed amount, so nothing in the
  # pipeline is cut off early (that would trip pipefail).
  head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20
}

sha256_of() { sha256sum | cut -d' ' -f1; }

# duration SECONDS: "15 min" or "45 s", for messages.
duration() { if (($1 >= 120)); then echo "$(($1 / 60)) min"; else echo "$1 s"; fi; }

# The host's LAN address, for the URLs printed at the end.
host_ip() {
  local ip=""
  ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1) || true
  [[ -n "$ip" ]] || ip=$(hostname -i 2>/dev/null | awk '{print $1}') || true
  echo "${ip:-<casaos-ip>}"
}

host_timezone() {
  local tz=""
  tz=$(timedatectl show -p Timezone --value 2>/dev/null) || tz=""
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz=$(readlink /etc/localtime 2>/dev/null | sed -n 's#.*/zoneinfo/##p') || tz=""
  fi
  [[ -z "$tz" && -r /etc/timezone ]] && tz=$(head -n1 /etc/timezone)
  echo "${tz:-Etc/UTC}"
}

os_release() { # KEY: value from /etc/os-release, quotes removed
  [[ -r /etc/os-release ]] || return 0
  sed -n "s/^$1=//p" /etc/os-release | head -n1 | sed 's/^"\(.*\)"$/\1/'
}

# ---------------------------------------------------------------------------
# .env reading and writing, in plain bash so secrets never appear in a
# process list. Same rules as platforms/unraid/install.sh, so the seeding
# CLI (scripts/env-editor/env_io.py parse_env_literal) reads every value
# back exactly as entered.
# ---------------------------------------------------------------------------

# env_get FILE KEY: print KEY's value as docker compose reads it (empty if
# unset). The same rules as compose and as the seeding CLI
# (scripts/env-editor/env_io.py parse_env_literal), so every reader of .env
# sees the same value:
#  - when KEY is set more than once, the last line wins; `export KEY=` works;
#  - 'single quotes' and "double quotes" are removed, and anything after the
#    closing quote (an inline comment) is ignored. Inside single quotes \' is
#    a quote; inside double quotes \" \\ \$ \n \t \r are unescaped;
#  - an unquoted value ends at the first " #" (space, then #), so
#    `QBIT_WEBUI_PORT=8090 # web UI` is 8090, while `a#b` stays `a#b`.
# (check_duplicate_keys refuses a .env with a key set twice anyway.)
env_get() {
  local file=$1 key=$2 line val q out c n i found=0 last=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*(export[[:space:]]+)?${key}[[:space:]]*=(.*)$ ]] || continue
    val="${BASH_REMATCH[2]}"
    val="${val#"${val%%[![:space:]]*}"}"
    q="${val:0:1}"
    if [[ "$q" == "'" || "$q" == '"' ]]; then
      # Walk to the closing quote, undoing backslash escapes on the way.
      out=""
      for ((i = 1; i < ${#val}; i++)); do
        c="${val:i:1}"
        n="${val:i+1:1}"
        if [[ "$c" == '\' && "$n" == "$q" ]]; then
          out+="$n"
          i=$((i + 1))
          continue
        fi
        if [[ "$c" == '\' && "$q" == '"' ]]; then
          case "$n" in
          '\' | '$') out+="$n" ;;
          n) out+=$'\n' ;;
          t) out+=$'\t' ;;
          r) out+=$'\r' ;;
          *) out+="$c$n" ;;
          esac
          i=$((i + 1))
          continue
        fi
        [[ "$c" == "$q" ]] && break
        out+="$c"
      done
      # No closing quote: keep the raw text (docker compose config, which
      # runs before anything is used, reports that line as an error).
      [[ $i -lt ${#val} ]] && val="$out"
    else
      val="${val%% #*}"
      val="${val%"${val##*[![:space:]]}"}"
    fi
    last=$val found=1
  done <"$file"
  ((found == 1)) && printf '%s' "$last"
  return 0
}

# env_key_lines FILE KEY: the line numbers that set KEY, space-separated.
env_key_lines() {
  local file=$1 key=$2 line n=0 out=""
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    n=$((n + 1))
    [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*= ]] && out+="${out:+ }${n}"
  done <"$file"
  printf '%s' "$out"
}

# env_quote VALUE: the VALUE as it should appear after KEY= in .env.
#  - plain characters: unquoted;
#  - anything else without a single quote: single quotes (read literally);
#  - with a single quote: double quotes with \ and " escaped.
# ($ and line breaks are refused earlier: CasaOS cannot keep them.)
env_quote() {
  local v=$1
  if [[ "$v" == *$'\n'* ]]; then
    return 1
  elif [[ "$v" =~ ^[A-Za-z0-9_./:@,+=%~-]*$ ]]; then
    printf '%s' "$v"
  elif [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
  else
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
  fi
}

# Settings to write into .env (KEY -> value), filled in by the wizard.
declare -A SETTINGS=()
SETTINGS_ORDER=()
set_setting() {
  [[ -v "SETTINGS[$1]" ]] || SETTINGS_ORDER+=("$1")
  SETTINGS[$1]=$2
}

# render_env TEMPLATE OUT: copy TEMPLATE (the existing .env, or .env.example)
# to OUT, replacing the value of every key in SETTINGS and appending keys
# the template lacks. Comments, order and other keys are kept. OUT is 0600.
# A key in SETTINGS that the template sets twice keeps only its first line
# (with the new value): a second line would win in docker compose and the
# seeding CLI, and quietly undo the answer.
render_env() {
  local template=$1 out=$2 line key q
  local -A seen=()
  (
    umask 077
    : >"$out"
  )
  {
    while IFS= read -r line || [[ -n "$line" ]]; do
      line="${line%$'\r'}"
      if [[ "$line" =~ ^[[:space:]]*([A-Z_][A-Z0-9_]*)[[:space:]]*= ]]; then
        key="${BASH_REMATCH[1]}"
        if [[ -v "SETTINGS[$key]" && -n "${seen[$key]:-}" ]]; then
          msg_warn "Removed a second ${key} line from .env (only one may set it)."
          continue
        fi
        if [[ -v "SETTINGS[$key]" ]]; then
          seen[$key]=1
          q=$(env_quote "${SETTINGS[$key]}") || die "The value for ${key} contains a line break; please choose another."
          printf '%s=%s\n' "$key" "$q"
          continue
        fi
      fi
      printf '%s\n' "$line"
    done <"$template"
    for key in "${SETTINGS_ORDER[@]}"; do
      if [[ -z "${seen[$key]:-}" ]]; then
        q=$(env_quote "${SETTINGS[$key]}") || die "The value for ${key} contains a line break."
        printf '%s=%s\n' "$key" "$q"
      fi
    done
  } >>"$out"
}

# print_env_masked FILE: show a rendered .env with secrets hidden.
print_env_masked() {
  local line key
  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ "$line" =~ ^[[:space:]]*# || -z "${line// /}" ]] && continue
    if [[ "$line" =~ ^([A-Z_][A-Z0-9_]*)=(.*)$ ]]; then
      key="${BASH_REMATCH[1]}"
      if is_secret_key "$key" && [[ -n "${BASH_REMATCH[2]}" ]]; then
        line="${key}=********"
      fi
    fi
    printf '         %s\n' "$line" >&2
  done <"$1"
}

# ---------------------------------------------------------------------------
# Platform checks
# ---------------------------------------------------------------------------
OS_NAME=""
OS_VERSION=""
BASE_OS=""
ARCH=""

check_root() {
  [[ "$(id -u)" == 0 ]] || die "Run this as root (on CasaOS: sudo -i first; on ZimaOS: the root account or sudo)."
}

# first_version TEXT: the first thing that looks like a version number.
first_version() {
  grep -m1 -o -E '[0-9]+\.[0-9]+(\.[0-9]+)?([-+][0-9A-Za-z.-]+)?' <<<"$1" || true
}

# version_of CMD: `CMD -v` (casaos -v / zimaos -v print the version and exit
# without starting anything), with a time limit when `timeout` exists.
version_of() {
  local out=""
  if command -v timeout >/dev/null 2>&1; then
    out=$(timeout 10 "$1" -v 2>&1) || true
  else
    out=$("$1" -v 2>&1) || true
  fi
  first_version "$out"
}

detect_platform() {
  local m
  m=$(uname -m)
  case "$m" in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "This ${m} machine is not supported: every image in the stack is published for amd64 and arm64 only." ;;
  esac
  BASE_OS=$(os_release PRETTY_NAME)
  # ZimaOS renamed CasaOS's services (zimaos, zimaos-app-management, ...) but
  # kept its paths and APIs. Look for it first: it may still ship `casaos`.
  if command -v zimaos >/dev/null 2>&1 || [[ "$(os_release ID) $(os_release NAME)" == *[Zz]ima* ]]; then
    OS_NAME="ZimaOS"
    command -v zimaos >/dev/null 2>&1 && OS_VERSION=$(version_of zimaos)
    [[ -n "$OS_VERSION" ]] || OS_VERSION=$(os_release VERSION_ID)
  elif command -v casaos >/dev/null 2>&1; then
    OS_NAME="CasaOS"
    OS_VERSION=$(version_of casaos)
  else
    die "This does not look like a CasaOS or ZimaOS host (no 'casaos' or 'zimaos' command). For other platforms see platforms/ in the repository."
  fi
  if [[ "$OS_NAME" == CasaOS ]]; then
    if [[ -z "$OS_VERSION" ]]; then
      msg_warn "Could not read the CasaOS version ('casaos -v'); carrying on."
    elif ! version_ge "${OS_VERSION%%[-+]*}" "$MIN_CASAOS"; then
      die "CasaOS ${OS_VERSION} is too old: compose apps need CasaOS ${MIN_CASAOS} or later. Update CasaOS from its dashboard (Settings > Update) first."
    fi
  fi
  msg_ok "${OS_NAME} ${OS_VERSION:-(version unknown)} on ${BASE_OS:-Linux} (${ARCH})"
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "The docker command is missing; ${OS_NAME} always ships Docker, so this host is not a normal ${OS_NAME} install."
  docker info >/dev/null 2>&1 || die "Docker is not running. Restart the host, or run: systemctl restart docker"
  msg_ok "Docker $(docker info --format '{{.ServerVersion}}' 2>/dev/null || echo '') is running"
}

check_tun() {
  # Gluetun needs /dev/net/tun. CasaOS silently drops a device that does not
  # exist on the host from the app, and Gluetun would then fail to start.
  if [[ ! -c /dev/net/tun ]]; then
    msg_info "Loading the tun kernel module (/dev/net/tun is missing)"
    run modprobe tun || true
    if [[ "$DRY_RUN" != 1 && ! -c /dev/net/tun ]]; then
      die "/dev/net/tun is still missing after 'modprobe tun'. Gluetun cannot run without it."
    fi
    msg_warn "Loaded tun by hand. If /dev/net/tun is missing after a reboot, add 'tun' to /etc/modules (CasaOS on Debian/Ubuntu)."
  else
    msg_ok "/dev/net/tun is available"
  fi
}

# ---------------------------------------------------------------------------
# CasaOS app-management API
#
# app-management accepts calls from 127.0.0.1 without a login (it skips its
# JWT check for local requests; that is how casaos-cli works), so this only
# ever talks to the local machine: secrets never cross the network.
# ---------------------------------------------------------------------------
API_BASE=""
API_HOW=""
API_STATUS=""
API_BODY=""

api_discover() {
  local port=""
  if [[ -n "${TS_CASAOS_API:-}" ]]; then
    API_BASE="${TS_CASAOS_API%/}"
    API_HOW="TS_CASAOS_API"
  elif [[ -r "${CASAOS_RUNTIME_DIR}/app-management.url" ]]; then
    # app-management listens on a random local port and writes it here.
    API_BASE=$(head -n1 "${CASAOS_RUNTIME_DIR}/app-management.url")
    API_BASE="${API_BASE%/}"
    API_HOW="${CASAOS_RUNTIME_DIR}/app-management.url"
  else
    # Otherwise go through the gateway (the dashboard's port), like casaos-cli.
    [[ -r "$CASAOS_GATEWAY_INI" ]] &&
      port=$(sed -n 's/^[[:space:]]*port[[:space:]]*=[[:space:]]*\([0-9]*\).*/\1/p' "$CASAOS_GATEWAY_INI" | head -n1)
    API_BASE="http://127.0.0.1:${port:-80}"
    API_HOW="the CasaOS gateway"
  fi
  [[ "$API_BASE" =~ ^http://(127\.0\.0\.1|localhost|\[::1\])(:[0-9]+)?$ ]] ||
    die "The app-management address '${API_BASE}' (from ${API_HOW}) is not on this machine. Only local calls work without a CasaOS login."
}

# api METHOD PATH [BODY_FILE] [ACCEPT]: sets API_STATUS (000 when CasaOS
# could not be reached) and API_BODY. The body is sent from a 0600 file, so
# no secret is on a command line. --noproxy: never send it via a proxy.
api() {
  local method=$1 path=$2 body=${3:-} accept=${4:-application/json}
  local out="$TEMP_DIR/api-response"
  local args=(--noproxy '*' -sS --max-time "${TS_API_TIMEOUT:-120}" -o "$out" -w '%{http_code}'
    -X "$method" -H "Accept: ${accept}")
  [[ -n "$body" ]] && args+=(-H "Content-Type: application/yaml" --data-binary "@${body}")
  : >"$out"
  API_STATUS=$(curl "${args[@]}" "${API_BASE}${API_PREFIX}${path}" 2>"$TEMP_DIR/api-error") || API_STATUS="000"
  API_BODY=$(cat "$out")
}

api_message() {
  printf '%s' "$API_BODY" | sed -n 's/.*"message":[[:space:]]*"\([^"]*\)".*/\1/p' | head -n1
}

# api_probe: is app-management there and willing to talk to us?
api_probe() {
  api GET "/compose"
  case "$API_STATUS" in
    200) msg_ok "CasaOS app-management answers (via ${API_HOW})" ;;
    000) die "Could not reach CasaOS app-management at ${API_BASE} ($(head -c 200 "$TEMP_DIR/api-error")). Is ${OS_NAME} running (systemctl status ${OS_NAME,,}-app-management)? Or use --no-register and import the app by hand." ;;
    401 | 403) die "CasaOS app-management at ${API_BASE} asked for a login (HTTP ${API_STATUS}). This ${OS_NAME} version does not accept local calls; use --no-register and import the app by hand (see platforms/casaos/README.md)." ;;
    404) die "CasaOS at ${API_BASE} has no compose-app API (HTTP 404). Update ${OS_NAME} (CasaOS ${MIN_CASAOS} or later), or set TS_CASAOS_API." ;;
    *) die "CasaOS app-management at ${API_BASE} answered HTTP ${API_STATUS}: $(api_message)" ;;
  esac
}

# Docker's view of this Compose project: "service|state|status|id|revision"
# lines (revision: the REV_LABEL value, empty for containers made before it).
project_rows() {
  docker ps -a --filter "label=com.docker.compose.project=${STACK}" \
    --format "{{.Label \"com.docker.compose.service\"}}|{{.State}}|{{.Status}}|{{.ID}}|{{.Label \"${REV_LABEL}\"}}" 2>/dev/null || true
}
service_ids() { # SERVICE...: running container ids of these services
  local svc
  for svc in "$@"; do
    docker ps -q --filter "label=com.docker.compose.project=${STACK}" \
      --filter "label=com.docker.compose.service=${svc}" 2>/dev/null || true
  done
}

# check_existing_app: sets APP_STATE to none (not installed), ours, or dies
# when the name is taken by something this installer did not make.
APP_STATE=""
check_existing_app() {
  local cfg rows
  api GET "/compose/${STACK}" "" application/yaml
  case "$API_STATUS" in
    404) APP_STATE=none ;;
    200)
      if grep -q -E "^[[:space:]]+id:[[:space:]]*['\"]?${APP_ID//./\\.}['\"]?[[:space:]]*$" <<<"$API_BODY"; then
        APP_STATE=ours
      else
        APP_STATE=other
      fi
      ;;
    *) die "CasaOS answered HTTP ${API_STATUS} when asked about '${STACK}': $(api_message)" ;;
  esac
  rows=$(project_rows)
  if [[ -z "$rows" && "$APP_STATE" == none ]]; then
    # An uninstall that is still finishing (CasaOS removes its own copy of
    # the app last) would delete the copy a new install writes. Give it time.
    local start=$SECONDS
    if [[ -e "${CASAOS_APPS_DIR}/${STACK}" ]]; then
      msg_info "Waiting for CasaOS to finish removing an earlier '${STACK}' app"
      while [[ -e "${CASAOS_APPS_DIR}/${STACK}" ]] && ((SECONDS - start < 120)); do sleep "$POLL_SECS"; done
    fi
    return 0
  fi
  # Which compose file made the existing containers?
  cfg=$(docker ps -a --filter "label=com.docker.compose.project=${STACK}" \
    --format '{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | head -n1) || cfg=""
  if [[ -n "$cfg" && "$cfg" != "${CASAOS_APPS_DIR}/${STACK}/"* ]]; then
    # Taking these over would let CasaOS overwrite that compose file.
    die "Containers of a Docker Compose project named '${STACK}' already exist, made from ${cfg} (not by CasaOS). Stop them first: docker compose -p ${STACK} -f ${cfg} down   then run this again."
  fi
  if [[ "$APP_STATE" == other ]]; then
    [[ "$TS_FORCE" == 1 ]] || die "A CasaOS app named '${STACK}' exists but was not installed by this script. Uninstall it from the dashboard, or re-run with TS_FORCE=1 to replace its settings."
    msg_warn "Replacing the settings of the existing CasaOS app '${STACK}' (TS_FORCE=1)."
    APP_STATE=ours
  elif [[ "$APP_STATE" == none ]]; then
    [[ "$TS_FORCE" == 1 ]] || die "Containers of '${STACK}' exist but CasaOS does not list the app (left over from an earlier attempt?). Remove them with: docker rm -f \$(docker ps -aq --filter label=com.docker.compose.project=${STACK})   or re-run with TS_FORCE=1."
  fi
}

# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------
APPDATA=""
STACK_DIR=""   # <appdata>/torrent-stack: repository files, .env, configs/
ENV_FILE=""
SRC_DIR=""     # where the repository files come from this run
STATE_FILE=""  # what was applied last (hashes), to know what to wait for

set_stack_dir() {
  check_path "TS_APPDATA" "$1"
  APPDATA="${1%/}"
  STACK_DIR="${APPDATA}/${STACK}"
  ENV_FILE="${STACK_DIR}/.env"
  STATE_FILE="${STACK_DIR}/.casaos-state"
}

# pick_appdata: where the stack lives when TS_APPDATA is not given. If this
# script is the copy inside an installed stack (<dir>/torrent-stack/
# platforms/casaos/install.sh with a .env next to it), that stack; else the
# default. So the follow-up commands the installer prints work for a stack
# installed outside /DATA/AppData too. (preflight may still switch to the
# folder the installed CasaOS app uses; see adopt_installed_dir.)
pick_appdata() {
  local self="" dir
  if [[ -n "$TS_APPDATA_GIVEN" ]]; then
    printf '%s' "$TS_APPDATA"
    return 0
  fi
  [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]] && self=$(readlink -f "${BASH_SOURCE[0]}" 2>/dev/null || true)
  if [[ "$self" == */"${STACK}"/platforms/casaos/install.sh ]]; then
    dir=${self%/platforms/casaos/install.sh}
    if [[ -f "${dir}/.env" ]]; then
      printf '%s' "${dir%/*}"
      return 0
    fi
  fi
  printf '%s' "$DEFAULT_APPDATA"
}

state_get() { [[ -f "$STATE_FILE" ]] && sed -n "s/^$1=//p" "$STATE_FILE" | head -n1; return 0; }
state_set() { # KEY VALUE
  [[ "$DRY_RUN" == 1 ]] && return 0
  local tmp="${STATE_FILE}.tmp"
  (
    umask 077
    { [[ -f "$STATE_FILE" ]] && grep -v "^$1=" "$STATE_FILE" || true; } >"$tmp"
    printf '%s=%s\n' "$1" "$2" >>"$tmp"
  )
  mv "$tmp" "$STATE_FILE"
}

# check_path LABEL PATH: an absolute path CasaOS can mount.
check_path() {
  local label=$1 p=$2
  [[ "$p" == /?* ]] || die "${label} must be an absolute path (for example ${DEFAULT_DOWNLOADS}), not '${p}'."
  [[ "$p" != *..* ]] || die "${label} '${p}' must not contain '..'."
  [[ "$p" =~ ^[A-Za-z0-9_./@+,:%~=\ -]+$ ]] || die "${label} '${p}' has characters CasaOS cannot keep; please use letters, digits, spaces and - _ . / only."
}

# check_downloads_path LABEL PATH [CONFIG_PATH]: the downloads folder is
# shared on the LAN by FileBrowser (which runs as uid 1000 with the PGID
# group, so it can change what the apps can), so it must not contain the
# stack folder, the configs or other apps' data: from there FileBrowser
# could read Jackett's API key and change
# qBittorrent's search plugin, which qBittorrent runs. It also must not be a
# whole disk or a top-level folder such as /DATA, and must not contain the
# app's name (CasaOS's "delete app data" uninstall would delete it).
check_downloads_path() {
  local label=$1 p=${2%/} cfg=${3:-} inside
  check_path "$label" "${p:-/}"
  [[ -n "$p" && "$p" =~ ^/[^/]+/.+ ]] ||
    die "${label} '${p:-/}' is a top-level folder. FileBrowser would share all of it on the network; use a folder such as ${DEFAULT_DOWNLOADS}."
  if [[ "$p" =~ ^/(media|mnt)/[^/]+$ ]]; then
    die "${label} '${p}' is a whole disk. FileBrowser would share all of it on the network; use a folder on it, for example ${p}/Downloads."
  fi
  [[ "$p" != *"${STACK}"* ]] ||
    die "${label} '${p}' must not contain '${STACK}' in its path: CasaOS's 'delete app data' uninstall deletes every folder of the app whose path contains its name."
  for inside in "$STACK_DIR" "$APPDATA" ${cfg:+"$cfg"}; do
    [[ "${inside%/}/" != "${p}/"* ]] ||
      die "${label} '${p}' contains ${inside}. FileBrowser would share the stack's settings (Jackett's API key, qBittorrent's config) on the network; use a folder outside it, such as ${DEFAULT_DOWNLOADS}."
  done
  [[ "${p}/" != "${STACK_DIR}/"* ]] || die "${label} must not be inside ${STACK_DIR}."
}

# ---------------------------------------------------------------------------
# Getting the repository
# ---------------------------------------------------------------------------

# Copy SRC into DEST without git metadata, secrets or runtime state.
copy_tree() {
  local src=$1 dest=$2 f ex=()
  for f in "$src"/.env.*; do
    [[ -e "$f" && "${f##*/}" != .env.example ]] && ex+=("--exclude=./${f##*/}")
  done
  run mkdir -p "$dest"
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would copy ${src} to ${dest} (without .git, .env, configs/, downloads/)"
    return 0
  fi
  # Only options GNU tar and busybox tar both understand (ZimaOS may have
  # busybox's): plain --exclude patterns ("./x" only matches at the top,
  # "__pycache__" anywhere) and -o (do not restore the archive's owners).
  tar -C "$src" --exclude=__pycache__ --exclude='*.pyc' \
    --exclude=./.git --exclude=./.env --exclude=./configs \
    --exclude=./downloads --exclude=./incomplete --exclude=./scripts/env-editor/.venv \
    --exclude=./.casaos-state --exclude=./casaos-app.yml \
    ${ex[@]+"${ex[@]}"} -cf - . | tar -C "$dest" -x -o -f -
}

SRC_COMMIT=""
# Download the repository into TEMP_DIR/src: git when the host has it
# (CasaOS on Debian/Ubuntu usually does), otherwise a tarball with curl
# (ZimaOS does not seem to ship git).
download_source() {
  local dest="$TEMP_DIR/src"
  if command -v git >/dev/null 2>&1; then
    msg_info "Cloning ${REPO_URL} (${TS_REF})"
    git clone -q --depth 1 --branch "$TS_REF" "${REPO_URL}.git" "$dest" ||
      die "git clone of ${REPO_URL} (${TS_REF}) failed."
    SRC_COMMIT=$(git -C "$dest" rev-parse --short HEAD 2>/dev/null) || SRC_COMMIT=""
  else
    local url="${REPO_URL}/archive/${TS_REF}.tar.gz"
    msg_info "Downloading ${url} (git is not installed)"
    mkdir -p "$dest"
    curl -fsSL --retry 3 "$url" -o "$TEMP_DIR/src.tar.gz" || die "Download of ${url} failed."
    tar -x -z -o -f "$TEMP_DIR/src.tar.gz" -C "$dest" --strip-components=1 ||
      die "Could not unpack ${url}."
  fi
  [[ -f "$dest/compose.yaml" && -f "$dest/.env.example" && -f "$dest/platforms/casaos/install.sh" ]] ||
    die "The download has no compose.yaml/.env.example/platforms/casaos; is TS_REF='${TS_REF}' right?"
  SRC_DIR="$dest"
  msg_ok "Got the repository (${TS_REF}${SRC_COMMIT:+, ${SRC_COMMIT}})"
}

# prepare_source fresh|keep: decide where the repository files come from.
#   keep: use what is already in STACK_DIR (--apply)
#   fresh: TS_SOURCE_DIR, or a new download (install, --update)
prepare_source() {
  local mode=$1
  if [[ "$mode" == keep && -f "$STACK_DIR/compose.yaml" ]]; then
    SRC_DIR="$STACK_DIR"
    return 0
  fi
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    TS_SOURCE_DIR="${TS_SOURCE_DIR%/}"
    [[ -f "$TS_SOURCE_DIR/compose.yaml" && -f "$TS_SOURCE_DIR/platforms/casaos/install.sh" ]] ||
      die "TS_SOURCE_DIR '${TS_SOURCE_DIR}' is not a checkout of this repository."
    SRC_DIR="$TS_SOURCE_DIR"
    SRC_COMMIT=$(git -C "$SRC_DIR" rev-parse --short HEAD 2>/dev/null) || SRC_COMMIT=""
    return 0
  fi
  download_source
}

# install_source: put the repository files into STACK_DIR. Always an overlay
# copy, never `git pull`: the apps rewrite two git-tracked seed files under
# configs/, which would make a pull refuse to run.
install_source() {
  [[ "$SRC_DIR" == "$STACK_DIR" ]] && return 0
  msg_info "Copying the repository files to ${STACK_DIR}"
  copy_tree "$SRC_DIR" "$STACK_DIR"
  state_set source "${TS_SOURCE_DIR:-${REPO_URL}@${TS_REF}}${SRC_COMMIT:+ (${SRC_COMMIT})}"
  if [[ -z "$TS_SOURCE_DIR" ]]; then
    # Remembered for the next --update (a cron job passes neither).
    state_set repo_url "$REPO_URL"
    state_set ref "$TS_REF"
  fi
  msg_ok "Repository files are in ${STACK_DIR}"
}

# remembered_source: for --update, reuse the fork and branch/tag of the last
# download unless TS_REPO_URL / TS_REF were given, so a stack pinned to a
# tag is not moved back to main by a nightly `--update -y`.
remembered_source() {
  local v
  if [[ -z "$TS_REF_GIVEN" ]]; then
    v=$(state_get ref)
    if [[ -n "$v" && "$v" =~ ^[A-Za-z0-9._/-]+$ ]]; then TS_REF=$v; fi
  fi
  if [[ -z "$TS_REPO_URL_GIVEN" ]]; then
    v=$(state_get repo_url)
    if [[ -n "$v" && "$v" =~ ^[A-Za-z]+://[^[:space:]\'\"]+$ ]]; then REPO_URL=$v; fi
  fi
  return 0
}

# ---------------------------------------------------------------------------
# The wizard
# ---------------------------------------------------------------------------
GENERATED_PASSWORD=""

placeholder() { env_get "$SRC_DIR/.env.example" "$1"; }

# is_placeholder KEY VALUE: empty, or still the .env.example value.
is_placeholder() {
  [[ -z "$2" || "$2" == "$(placeholder "$1")" ]]
}

# current KEY DEFAULT: the existing .env value unless it is a placeholder.
current() {
  local v
  v=$(env_get "$ENV_FILE" "$1")
  if is_placeholder "$1" "$v"; then printf '%s' "$2"; else printf '%s' "$v"; fi
}

# pick VAR KEY DEFAULT: TS_<KEY> if set, else the existing .env, else DEFAULT.
pick() {
  local __var=$1 key=$2 def=$3 tsvar="TS_$2"
  if [[ -n "${!tsvar:-}" ]]; then
    printf -v "$__var" '%s' "${!tsvar}"
  else
    printf -v "$__var" '%s' "$(current "$key" "$def")"
  fi
}

# pick_secret VAR KEY: TS_<KEY>_FILE if set, else the existing .env value
# (empty when it is a placeholder).
pick_secret() {
  local __var=$1 key=$2 filevar="TS_$2_FILE" val=""
  if [[ -n "${!filevar:-}" ]]; then
    read_secret_file val "${!filevar}"
  else
    val=$(current "$key" "")
  fi
  printf -v "$__var" '%s' "$val"
}

valid_wg_key() { [[ "$1" =~ ^[A-Za-z0-9+/]{43}=$ ]]; }

wizard() {
  local tz puid pgid downloads provider vtype wg_key="" wg_addr ovpn_user ovpn_pass="" ovpn_proto
  local countries quser qpass="" notify="" qport jport fport bport watchtower profiles tmp

  pick tz TZ "$(host_timezone)"
  pick puid PUID "$DEFAULT_PUID"
  pick pgid PGID "$DEFAULT_PGID"
  downloads="${TS_DOWNLOADS:-$(current DOWNLOADS_PATH "$DEFAULT_DOWNLOADS")}"
  pick provider VPN_PROVIDER "protonvpn"
  pick vtype VPN_TYPE "wireguard"
  pick wg_addr WIREGUARD_ADDRESSES ""
  pick ovpn_user OPENVPN_USER ""
  pick ovpn_proto OPENVPN_PROTOCOL "udp"
  pick countries SERVER_COUNTRIES "$(placeholder SERVER_COUNTRIES)"
  pick quser QBITTORRENT_USER "admin"
  pick qport QBIT_WEBUI_PORT "$(placeholder QBIT_WEBUI_PORT)"
  pick jport JACKETT_PORT "$(placeholder JACKETT_PORT)"
  pick fport FLARESOLVERR_PORT "$(placeholder FLARESOLVERR_PORT)"
  pick bport FILEBROWSER_PORT "$(placeholder FILEBROWSER_PORT)"
  pick_secret wg_key WIREGUARD_PRIVATE_KEY
  pick_secret ovpn_pass OPENVPN_PASSWORD
  pick_secret qpass QBITTORRENT_PASSWORD
  pick_secret notify SCRIPT_NOTIFY_URL
  profiles=$(env_get "$ENV_FILE" COMPOSE_PROFILES)
  watchtower=0
  [[ ",${profiles}," == *",watchtower,"* ]] && watchtower=1
  [[ -n "${TS_WATCHTOWER:-}" ]] && watchtower=$TS_WATCHTOWER

  if [[ "$INTERACTIVE" == 1 ]]; then
    ui_input downloads "Downloads folder" \
      "Where qBittorrent saves finished downloads (an 'incomplete' folder is made inside). FileBrowser shows this folder. ${DEFAULT_DOWNLOADS} is CasaOS's Downloads share; a disk under /media works too." \
      "$downloads"
    ui_input tz "Time zone" "Time zone for the logs (IANA name, for example Europe/Berlin)." "$tz"

    tmp=$provider
    case "$provider" in protonvpn | "private internet access" | "perfect privacy" | privatevpn) ;; *) tmp=other ;; esac
    ui_menu tmp "VPN provider" \
      "Port forwarding (needed so peers can reach you) works with these Gluetun providers. 'other' connects, but qBittorrent's port stays closed." \
      "$tmp" \
      protonvpn "ProtonVPN" \
      "private internet access" "Private Internet Access" \
      "perfect privacy" "Perfect Privacy" \
      privatevpn "PrivateVPN" \
      other "Another Gluetun provider (type its name)"
    if [[ "$tmp" == other ]]; then
      [[ "$provider" == protonvpn ]] && provider=""
      ui_input provider "VPN provider" "Gluetun's name for your provider (see the Gluetun wiki, setup/providers)." "$provider"
    else
      provider=$tmp
    fi
    ui_menu vtype "VPN protocol" "WireGuard is faster; use OpenVPN if your provider only offers that." "$vtype" \
      wireguard "WireGuard" openvpn "OpenVPN"

    if [[ "$vtype" == wireguard ]]; then
      while :; do
        tmp=""
        ui_password tmp "WireGuard private key" \
          "The PrivateKey line of the WireGuard config from your VPN provider.$([[ -n "$wg_key" ]] && echo ' Leave empty to keep the current key.')"
        [[ -n "$tmp" ]] && wg_key=$tmp
        if [[ -n "$wg_key" ]] && valid_wg_key "$wg_key"; then break; fi
        ui_yesno "Key not accepted" "That is not a WireGuard key (44 characters ending in '='). Try again?" yes ||
          die "A WireGuard private key is needed." 1
      done
      while :; do
        ui_input wg_addr "WireGuard address" "The Address line of the same config, for example 10.2.0.2/32." "$wg_addr"
        [[ -n "$wg_addr" && "$wg_addr" != "$(placeholder WIREGUARD_ADDRESSES)" && "$wg_addr" =~ ^[0-9A-Fa-f.:/,\ ]+$ ]] && break
        ui_yesno "Address not accepted" "That does not look like an address such as 10.2.0.2/32. Try again?" yes ||
          die "The WireGuard address is needed." 1
      done
    else
      while :; do
        ui_input ovpn_user "OpenVPN username" "Your provider's OpenVPN (not account) username. ProtonVPN: add +pmp at the end for port forwarding." "$ovpn_user"
        [[ -n "$ovpn_user" ]] && break
        ui_yesno "Username needed" "An OpenVPN username is needed. Try again?" yes || die "An OpenVPN username is needed." 1
      done
      while :; do
        tmp=""
        ui_password tmp "OpenVPN password" \
          "Your provider's OpenVPN password.$([[ -n "$ovpn_pass" ]] && echo ' Leave empty to keep the current one.')"
        [[ -n "$tmp" ]] && ovpn_pass=$tmp
        [[ -n "$ovpn_pass" ]] && break
        ui_yesno "Password needed" "An OpenVPN password is needed. Try again?" yes || die "An OpenVPN password is needed." 1
      done
      ui_menu ovpn_proto "OpenVPN transport" "UDP unless your network blocks it." "$ovpn_proto" udp UDP tcp TCP
    fi
    ui_input countries "Server countries" "Comma-separated VPN exit countries, for example: Switzerland,Netherlands" "$countries"

    ui_input quser "qBittorrent user" "Login for qBittorrent's web UI. (FileBrowser's user is always 'admin', with the same password.)" "$quser"
    tmp=""
    ui_password tmp "qBittorrent password" \
      "$([[ -n "$qpass" ]] && echo 'Leave empty to keep the current password.' || echo 'Leave empty to generate one (shown at the end).')"
    [[ -n "$tmp" ]] && qpass=$tmp
    tmp=""
    ui_password tmp "Discord webhook (optional)" \
      "A Discord webhook URL for port-forward messages.$([[ -n "$notify" ]] && echo ' Leave empty to keep the current one.' || echo ' Leave empty for none.')"
    [[ -n "$tmp" ]] && notify=$tmp

    printf -v tmp 'Ports on this box: qBittorrent %s, Jackett %s, FlareSolverr %s, FileBrowser %s.\n\nChange them (for example because another app uses one)?' \
      "$qport" "$jport" "$fport" "$bport"
    if ui_yesno "Web UI ports" "$tmp" no; then
      ui_input qport "qBittorrent port" "Port for qBittorrent's web UI on this box." "$qport"
      ui_input jport "Jackett port" "Port for Jackett on this box (inside, Jackett keeps ${JACKETT_INTERNAL_PORT})." "$jport"
      ui_input fport "FlareSolverr port" "Port for FlareSolverr on this box (inside, it keeps ${FLARESOLVERR_INTERNAL_PORT})." "$fport"
      ui_input bport "FileBrowser port" "Port for FileBrowser on this box." "$bport"
    fi
    printf -v tmp '%s\n\n%s' \
      "CasaOS does not update custom apps. Run this stack's own Watchtower, which pulls new images nightly and recreates the containers?" \
      "No: update with 'install.sh --update' when you choose."
    if ui_yesno "Automatic updates" "$tmp" "$([[ "$watchtower" == 1 ]] && echo yes || echo no)"; then
      watchtower=1
    else
      watchtower=0
    fi
  fi

  if [[ -z "$qpass" ]]; then
    qpass=$(random_password)
    GENERATED_PASSWORD=$qpass
  fi

  # An absolute CONFIG_PATH already in .env is kept (someone may have moved
  # the configs); otherwise the configs live in the stack folder.
  local cfg
  cfg=$(current CONFIG_PATH "")
  [[ "$cfg" == /* ]] || cfg="${STACK_DIR}/configs"
  cfg="${cfg%/}"

  # Checks that apply to answers from any source.
  downloads="${downloads%/}"
  check_downloads_path "Downloads folder" "$downloads" "$cfg"
  [[ "$puid" =~ ^[0-9]+$ && "$pgid" =~ ^[0-9]+$ && "$puid" != 0 && "$pgid" != 0 ]] ||
    die "PUID and PGID must be numbers other than 0 (got ${puid}/${pgid})."
  local p
  for p in "$qport" "$jport" "$fport" "$bport"; do
    valid_port "$p" || die "'${p}' is not a valid port (1-65535)."
  done
  [[ "$vtype" == wireguard || "$vtype" == openvpn ]] || die "VPN type must be wireguard or openvpn, not '${vtype}'."
  local why
  why=$(filebrowser_password_problem "$qpass")
  [[ -z "$why" ]] || die "The qBittorrent password is also FileBrowser's admin password, and ${why}. Please choose another."
  if [[ -n "$wg_key" ]] && ! valid_wg_key "$wg_key"; then
    die "The WireGuard private key is not a valid key (44 characters ending in '=')."
  fi
  [[ "${TS_WATCHTOWER:-0}" == 0 || "${TS_WATCHTOWER:-0}" == 1 ]] || die "TS_WATCHTOWER must be 0 or 1."

  set_setting PUID "$puid"
  set_setting PGID "$pgid"
  set_setting TZ "$tz"
  set_setting CONFIG_PATH "$cfg"
  set_setting DOWNLOADS_PATH "$downloads"
  set_setting INCOMPLETE_DOWNLOADS "${downloads}/incomplete"
  set_setting VPN_PROVIDER "$provider"
  set_setting VPN_TYPE "$vtype"
  [[ -n "$wg_key" ]] && set_setting WIREGUARD_PRIVATE_KEY "$wg_key"
  [[ -n "$wg_addr" ]] && set_setting WIREGUARD_ADDRESSES "$wg_addr"
  [[ -n "$ovpn_user" ]] && set_setting OPENVPN_USER "$ovpn_user"
  [[ -n "$ovpn_pass" ]] && set_setting OPENVPN_PASSWORD "$ovpn_pass"
  set_setting OPENVPN_PROTOCOL "$ovpn_proto"
  set_setting SERVER_COUNTRIES "$countries"
  set_setting QBIT_WEBUI_PORT "$qport"
  set_setting JACKETT_PORT "$jport"
  set_setting FLARESOLVERR_PORT "$fport"
  set_setting FILEBROWSER_PORT "$bport"
  set_setting QBITTORRENT_USER "$quser"
  set_setting QBITTORRENT_PASSWORD "$qpass"
  # An unused placeholder webhook would make the port script post to a
  # made-up Discord URL; empty means "no notifications".
  set_setting SCRIPT_NOTIFY_URL "$notify"
  if [[ "$watchtower" == 1 ]]; then
    set_setting COMPOSE_PROFILES "watchtower"
  else
    set_setting COMPOSE_PROFILES ""
  fi
}

# ---------------------------------------------------------------------------
# .env checks (before anything is rendered)
# ---------------------------------------------------------------------------
declare -A E=() # values from .env, filled by load_env

load_env() { # FILE
  local key
  E=()
  for key in "${COMPOSE_KEYS[@]}"; do
    E[$key]=$(env_get "$1" "$key")
  done
}

# check_inline_values: every value is written into the CasaOS YAML. CasaOS
# runs that YAML through Compose variable substitution once when it is
# installed and again on every start, so a '$' cannot survive (it turns
# into an empty variable), and a line break would end the value.
check_inline_values() {
  local key v
  check_duplicate_keys "$ENV_SOURCE"
  for key in "${COMPOSE_KEYS[@]}"; do
    v=${E[$key]}
    [[ "$v" != *'$'* ]] || die "${key} contains a '\$'. CasaOS replaces '\$...' with an empty value, so it cannot be used here; please choose a value without it (edit ${ENV_FILE})."
    [[ "$v" != *[[:cntrl:]]* ]] || die "${key} contains a line break or control character; please fix it in ${ENV_FILE}."
  done
  for key in PUID PGID; do
    [[ "${E[$key]}" =~ ^[0-9]+$ && "${E[$key]}" != 0 ]] || die "${key} in ${ENV_FILE} must be a number other than 0."
  done
  for key in QBIT_WEBUI_PORT JACKETT_PORT FLARESOLVERR_PORT FILEBROWSER_PORT; do
    valid_port "${E[$key]}" || die "${key}='${E[$key]}' in ${ENV_FILE} is not a valid port."
  done
  local dup
  dup=$(printf '%s\n' "${E[QBIT_WEBUI_PORT]}" "${E[JACKETT_PORT]}" "${E[FLARESOLVERR_PORT]}" "${E[FILEBROWSER_PORT]}" | sort | uniq -d | head -n1)
  [[ -z "$dup" ]] || die "Port ${dup} is used for two web UIs in ${ENV_FILE}; give each its own port."
  # qBittorrent listens on QBIT_WEBUI_PORT inside Gluetun's network, next to
  # Jackett (9117), FlareSolverr (8191) and Gluetun's own control (8000) and
  # health (9999) servers.
  case "${E[QBIT_WEBUI_PORT]}" in
    "$JACKETT_INTERNAL_PORT" | "$FLARESOLVERR_INTERNAL_PORT" | 8000 | 9999)
      die "QBIT_WEBUI_PORT=${E[QBIT_WEBUI_PORT]} is taken inside Gluetun's network (Jackett 9117, FlareSolverr 8191, Gluetun 8000 and 9999); please pick another." ;;
  esac
  check_path CONFIG_PATH "${E[CONFIG_PATH]}"
  for key in DOWNLOADS_PATH INCOMPLETE_DOWNLOADS; do
    check_downloads_path "$key in ${ENV_FILE}" "${E[$key]}" "${E[CONFIG_PATH]}"
  done
  [[ "${E[VPN_TYPE]}" == wireguard || "${E[VPN_TYPE]}" == openvpn ]] || die "VPN_TYPE in ${ENV_FILE} must be wireguard or openvpn."
  [[ -n "${E[VPN_PROVIDER]}" && -n "${E[TZ]}" ]] || die "VPN_PROVIDER and TZ must be set in ${ENV_FILE}."
  if is_placeholder QBITTORRENT_USER "${E[QBITTORRENT_USER]}" || is_placeholder QBITTORRENT_PASSWORD "${E[QBITTORRENT_PASSWORD]}"; then
    die "QBITTORRENT_USER/QBITTORRENT_PASSWORD in ${ENV_FILE} are still placeholders. Set them, then run --apply again."
  fi
  local why
  why=$(filebrowser_password_problem "${E[QBITTORRENT_PASSWORD]}")
  [[ -z "$why" ]] || die "QBITTORRENT_PASSWORD in ${ENV_FILE} is also FileBrowser's admin password, and ${why}. Please choose another, then run --apply again."
}

# filebrowser_password_problem PASSWORD: compose.yaml gives FileBrowser's
# "admin" user the qBittorrent password (FILEBROWSER_ADMIN_PASSWORD), set
# again on every start. FileBrowser Quantum 2.0 ignores the value "admin"
# (a new database then gets a random password, an existing one keeps its
# old one), refuses fewer than 5 characters
# when it sets the password on a later start, and its bcrypt hash cannot
# take more than 72 bytes. Prints why PASSWORD would not work, or nothing.
filebrowser_password_problem() {
  local n
  n=$(printf '%s' "$1" | wc -c)
  if [[ "$1" == admin ]]; then
    echo "FileBrowser ignores the password 'admin' (it would make up its own, or keep the old one)"
  elif ((n < 5)); then
    echo "FileBrowser needs at least 5 characters"
  elif ((n > 72)); then
    echo "FileBrowser takes at most 72 bytes (letters outside A-Z can take 2-4 bytes each)"
  fi
  return 0
}

# check_duplicate_keys FILE: refuse a .env that sets one of the stack's keys
# twice (for example a new password added at the end instead of edited in
# place). docker compose and the seeding CLI take the last line, and a mix
# could give qBittorrent one password and Gluetun's port script another.
check_duplicate_keys() {
  local file=$1 key lines bad=""
  for key in "${COMPOSE_KEYS[@]}"; do
    lines=$(env_key_lines "$file" "$key")
    [[ "$lines" == *" "* ]] && bad+="    ${key} (lines ${lines// /, })"$'\n'
  done
  [[ -z "$bad" ]] && return 0
  msg_error "These settings appear more than once in ${ENV_FILE}:"
  printf '%s' "$bad" >&2
  die "Keep one line for each (the one with the value you want), then run --apply again."
}

# vpn_ready: are the VPN credentials real? Gluetun and the apps behind it
# must not be started with the .env.example placeholders (startup gating).
vpn_ready() {
  if [[ "${E[VPN_TYPE]}" == wireguard ]]; then
    ! is_placeholder WIREGUARD_PRIVATE_KEY "${E[WIREGUARD_PRIVATE_KEY]}" &&
      ! is_placeholder WIREGUARD_ADDRESSES "${E[WIREGUARD_ADDRESSES]}"
  else
    ! is_placeholder OPENVPN_USER "${E[OPENVPN_USER]}" &&
      ! is_placeholder OPENVPN_PASSWORD "${E[OPENVPN_PASSWORD]}"
  fi
}

watchtower_on() { [[ ",${E[COMPOSE_PROFILES]}," == *",watchtower,"* ]]; }

# ---------------------------------------------------------------------------
# Rendering the CasaOS app (compose.yaml with values written out)
# ---------------------------------------------------------------------------
COMPOSE_SRC="" # the repository's compose.yaml this run reads image names from

# compose_image SERVICE: the image line of SERVICE in compose.yaml, so an
# image bump there reaches CasaOS without editing this script.
compose_image() {
  local img
  img=$(awk -v svc="$1" '
    /^services:[[:space:]]*$/ { in_s = 1; next }
    in_s && /^[^[:space:]#]/ { in_s = 0 }
    in_s && /^  [A-Za-z0-9_.-]+:[[:space:]]*$/ { cur = $1; sub(/:$/, "", cur); next }
    in_s && cur == svc && /^    image:/ {
      sub(/^    image:[[:space:]]*/, ""); sub(/[[:space:]]+#.*$/, ""); gsub(/["\047]/, ""); print; exit
    }' "$COMPOSE_SRC")
  [[ "$img" =~ ^[A-Za-z0-9][A-Za-z0-9._/:@-]*$ ]] ||
    die "Could not read the image of service '$1' from ${COMPOSE_SRC}."
  printf '%s' "$img"
}

# q VALUE: a YAML single-quoted scalar ('' stands for one ').
q() { printf "'%s'" "${1//\'/\'\'}"; }
# v KEY: the .env value of KEY as a YAML scalar ('********' when masking).
MASK=0
v() {
  if [[ "$MASK" == 1 ]] && is_secret_key "$1" && [[ -n "${E[$1]}" ]]; then
    q '********'
  else
    q "${E[$1]}"
  fi
}

# Descriptions shown in the CasaOS app settings (service-level x-casaos).
xenv() { printf '        - container: %s\n          description:\n            en_US: %s\n' "$1" "$(q "$2")"; }
xport() { printf '        - container: %s\n          description:\n            en_US: %s\n' "$(q "$1")" "$(q "$2")"; }
xvol() { printf '        - container: %s\n          description:\n            en_US: %s\n' "$(q "$1")" "$(q "$2")"; }
port_entry() { printf '      - target: %s\n        published: %s\n        protocol: tcp\n' "$1" "$(q "$2")"; }
bind_entry() { # source target [ro]
  printf '      - type: bind\n        source: %s\n        target: %s\n' "$(q "$1")" "$(q "$2")"
  [[ "${3:-}" == ro ]] && printf '        read_only: true\n'
  return 0
}

# ipv6_sysctl_on: compose.yaml turns IPv6 off inside Gluetun's network with
# a sysctl. A kernel booted with ipv6.disable=1 has no IPv6 anywhere (and no
# /proc/sys/net/ipv6), so Docker cannot set that sysctl and refuses to start
# Gluetun; there nothing can leak over IPv6 and the sysctl is left out.
ipv6_sysctl_on() {
  case "${TS_IPV6_SYSCTL:-auto}" in
    on) return 0 ;;
    off) return 1 ;;
    auto) [[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] ;;
    *) die "TS_IPV6_SYSCTL must be auto, on or off." ;;
  esac
}
ipv6_sysctl_block() {
  if ipv6_sysctl_on; then
    printf '    sysctls:\n      net.ipv6.conf.all.disable_ipv6: %s\n' "'1'"
  else
    printf '    # No IPv6 sysctl: this kernel has IPv6 switched off entirely.\n'
  fi
}

# render_compose OUT: write the CasaOS app YAML for the values in E. It
# mirrors compose.yaml service for service (the test suite compares the two
# with `docker compose config`), with three CasaOS differences:
#   1. every ${VAR} is written out: CasaOS substitutes variables from its own
#      environment, not from .env, and keeps no .env next to the app;
#   2. every path is absolute: CasaOS loads the YAML in a temporary folder,
#      so ./update-qbittorrent.sh would point nowhere;
#   3. x-casaos metadata: one dashboard app, opened on qBittorrent's port.
# Two more differences (the test suite's drift check allows exactly these):
#   4. `restart: true` on depends_on: when the app is restarted, Compose
#      restarts Gluetun first and then the apps behind it, so they join its
#      new network instead of keeping the dead one of the old Gluetun
#      (reported for a change in compose.yaml too);
#   5. a revision label on each service (see REV_LABEL and finalize_rendering).
# Watchtower is included only when COMPOSE_PROFILES turns it on.
render_compose() {
  local out=$1 c=${E[CONFIG_PATH]} qp=${E[QBIT_WEBUI_PORT]} jp=${E[JACKETT_PORT]}
  local fp=${E[FLARESOLVERR_PORT]} bp=${E[FILEBROWSER_PORT]}
  local key
  (
    umask 077
    : >"$out"
  )
  {
    cat <<EOF
# CasaOS app for the torrent stack (rob-paprocki/qbittorrent-vpn-docker),
# rendered by platforms/casaos/install.sh (format ${RENDER_VERSION}) from
# ${STACK_DIR}/.env. It contains your VPN key and passwords: keep it private.
# Change settings in .env and run install.sh --apply; changes made in the
# CasaOS app settings are overwritten by the next --apply.
name: ${STACK}
services:

  # VPN gateway. qBittorrent, Jackett and FlareSolverr share its network
  # (network_mode: service:gluetun), so they have no internet without it.
  gluetun:
    image: $(q "$(compose_image gluetun)")
    cap_add:
      - NET_ADMIN
    devices:
      - /dev/net/tun:/dev/net/tun
    ports:
$(port_entry "$qp" "$qp")
$(port_entry "$JACKETT_INTERNAL_PORT" "$jp")
$(port_entry "$FLARESOLVERR_INTERNAL_PORT" "$fp")
    volumes:
$(bind_entry "${c}/gluetun" /gluetun)
$(bind_entry "${STACK_DIR}/update-qbittorrent.sh" /gluetun/update-qbittorrent.sh ro)
$(ipv6_sysctl_block)
    environment:
      VPN_SERVICE_PROVIDER: $(v VPN_PROVIDER)
      VPN_TYPE: $(v VPN_TYPE)
      OPENVPN_USER: $(v OPENVPN_USER)
      OPENVPN_PASSWORD: $(v OPENVPN_PASSWORD)
      OPENVPN_PROTOCOL: $(v OPENVPN_PROTOCOL)
      WIREGUARD_PRIVATE_KEY: $(v WIREGUARD_PRIVATE_KEY)
      WIREGUARD_ADDRESSES: $(v WIREGUARD_ADDRESSES)
      PORT_FORWARD_ONLY: $(v PORT_FORWARD_ONLY)
      VPN_PORT_FORWARDING: $(v VPN_PORT_FORWARDING)
      SERVER_COUNTRIES: $(v SERVER_COUNTRIES)
      TZ: $(v TZ)
      VPN_PORT_FORWARDING_UP_COMMAND: /gluetun/update-qbittorrent.sh
      QBIT_WEBUI_PORT: $(v QBIT_WEBUI_PORT)
      QBITTORRENT_USER: $(v QBITTORRENT_USER)
      QBITTORRENT_PASSWORD: $(v QBITTORRENT_PASSWORD)
      SCRIPT_NOTIFY_URL: $(v SCRIPT_NOTIFY_URL)
    healthcheck:
      test: ["CMD", "/gluetun-entrypoint", "healthcheck"]
      interval: 1m30s
      timeout: 10s
      retries: 3
      start_period: 60s
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.scope: ${STACK}
      ${REV_LABEL}: '@REV@'
    x-casaos:
      envs:
$(xenv VPN_SERVICE_PROVIDER "VPN provider (VPN_PROVIDER in .env)")
$(xenv VPN_TYPE "wireguard or openvpn")
$(xenv WIREGUARD_PRIVATE_KEY "WireGuard private key from your provider")
$(xenv WIREGUARD_ADDRESSES "WireGuard Address line, e.g. 10.2.0.2/32")
$(xenv OPENVPN_USER "OpenVPN username (only for openvpn)")
$(xenv OPENVPN_PASSWORD "OpenVPN password (only for openvpn)")
$(xenv SERVER_COUNTRIES "VPN exit countries, comma-separated")
$(xenv VPN_PORT_FORWARDING "on: ask the provider for a forwarded port")
$(xenv QBITTORRENT_USER "qBittorrent login used by the port-forward script")
$(xenv QBITTORRENT_PASSWORD "qBittorrent password used by the port-forward script")
$(xenv SCRIPT_NOTIFY_URL "Discord webhook for port-forward messages (optional)")
      ports:
$(xport "$qp" "qBittorrent web UI (served through Gluetun)")
$(xport "$JACKETT_INTERNAL_PORT" "Jackett web UI (served through Gluetun; change JACKETT_PORT in .env)")
$(xport "$FLARESOLVERR_INTERNAL_PORT" "FlareSolverr API (served through Gluetun; change FLARESOLVERR_PORT in .env)")
      volumes:
$(xvol /gluetun "Gluetun state (forwarded port, servers list)")
$(xvol /gluetun/update-qbittorrent.sh "Port-forward script from the repository (read-only)")

  # Cloudflare challenge solver for Jackett.
  flaresolverr:
    image: $(q "$(compose_image flaresolverr)")
    environment:
      TZ: $(v TZ)
      LOG_LEVEL: info
    volumes:
$(bind_entry "${c}/flaresolverr" /config)
    network_mode: service:gluetun
    depends_on:
      gluetun:
        condition: service_healthy
        restart: true
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.scope: ${STACK}
      ${REV_LABEL}: '@REV@'
    x-casaos:
      volumes:
$(xvol /config "FlareSolverr settings")

  # qBittorrent with the VueTorrent web UI (LinuxServer docker mod).
  qbittorrent:
    image: $(q "$(compose_image qbittorrent)")
    network_mode: service:gluetun
    environment:
      WEBUI_PORT: $(v QBIT_WEBUI_PORT)
      PUID: $(v PUID)
      PGID: $(v PGID)
      TZ: $(v TZ)
      DOCKER_MODS: ghcr.io/vuetorrent/vuetorrent-lsio-mod:latest
    volumes:
$(bind_entry "${c}/qbittorrent" /config)
$(bind_entry "${E[DOWNLOADS_PATH]}" /downloads)
$(bind_entry "${E[INCOMPLETE_DOWNLOADS]}" /downloads/incomplete)
    depends_on:
      gluetun:
        condition: service_healthy
        restart: true
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.scope: ${STACK}
      ${REV_LABEL}: '@REV@'
    x-casaos:
      envs:
$(xenv WEBUI_PORT "qBittorrent web UI port (QBIT_WEBUI_PORT in .env)")
$(xenv PUID "User id qBittorrent runs as")
$(xenv PGID "Group id qBittorrent runs as")
$(xenv TZ "Time zone")
      volumes:
$(xvol /config "qBittorrent settings")
$(xvol /downloads "Finished downloads")
$(xvol /downloads/incomplete "Downloads in progress")

  # Jackett indexer proxy.
  jackett:
    image: $(q "$(compose_image jackett)")
    environment:
      PUID: $(v PUID)
      PGID: $(v PGID)
      TZ: $(v TZ)
    volumes:
$(bind_entry "${c}/jackett" /config)
    network_mode: service:gluetun
    depends_on:
      gluetun:
        condition: service_healthy
        restart: true
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.scope: ${STACK}
      ${REV_LABEL}: '@REV@'
    x-casaos:
      volumes:
$(xvol /config "Jackett settings and indexers")

  # Web file manager, scoped to the downloads folder only. Its database
  # lives in its config folder, and its "admin" user gets the qBittorrent
  # password on every start. The image always runs as uid 1000; the PGID
  # group gives it the stack's access to the downloads and that folder.
  filebrowser:
    image: $(q "$(compose_image filebrowser)")
    environment:
      TZ: $(v TZ)
      FILEBROWSER_DATABASE_PATH: /config/database.sqlite
      FILEBROWSER_ADMIN_PASSWORD: $(v QBITTORRENT_PASSWORD)
    group_add:
      - $(v PGID)
    ports:
$(port_entry 80 "$bp")
    volumes:
$(bind_entry "${c}/filebrowser" /config)
$(bind_entry "${E[DOWNLOADS_PATH]}" /srv/downloads)
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.scope: ${STACK}
      ${REV_LABEL}: '@REV@'
    x-casaos:
      envs:
$(xenv FILEBROWSER_ADMIN_PASSWORD "Password of FileBrowser's admin user (QBITTORRENT_PASSWORD in .env)")
$(xenv FILEBROWSER_DATABASE_PATH "FileBrowser's database, kept in its config folder")
      ports:
$(xport 80 "FileBrowser web UI")
      volumes:
$(xvol /config "FileBrowser's database (users and settings)")
$(xvol /srv/downloads "The downloads folder")
EOF
    if watchtower_on; then
      cat <<EOF

  # Watchtower (COMPOSE_PROFILES=watchtower in .env): nightly image updates
  # for this stack's containers only.
  watchtower:
    image: $(q "$(compose_image watchtower)")
    volumes:
$(bind_entry /var/run/docker.sock /var/run/docker.sock)
    environment:
      WATCHTOWER_NOTIFICATION_URL: $(v WATCHTOWER_NOTIFICATION_URL)
      WATCHTOWER_NOTIFICATION_LEVEL: $(v WATCHTOWER_NOTIFICATION_LEVEL)
      WATCHTOWER_NOTIFICATION_TITLE_TAG: $(v WATCHTOWER_TITLE_TAG)
      TZ: $(v TZ)
      WATCHTOWER_SCOPE: ${STACK}
      WATCHTOWER_SCHEDULE: $(v WATCHTOWER_SCHEDULE)
    command: --cleanup
    restart: unless-stopped
    labels:
      com.centurylinklabs.watchtower.scope: ${STACK}
      ${REV_LABEL}: '@REV@'
EOF
    fi
    cat <<EOF

# Dashboard metadata (CasaOS app-management / AppStore format).
x-casaos:
  id: ${APP_ID}
  main: qbittorrent
  index: /
  port_map: $(q "$qp")
  scheme: http
  icon: ${ICON_DATA_URI}
  title:
    en_US: Torrent Stack
  tagline:
    en_US: qBittorrent, Jackett and FlareSolverr behind a Gluetun VPN
  description:
    en_US: |
      Gluetun VPN gateway with qBittorrent (VueTorrent web UI), Jackett,
      FlareSolverr and FileBrowser. qBittorrent, Jackett and FlareSolverr
      share Gluetun's network, so they have no internet at all when the VPN
      is down. The VPN's forwarded port is pushed into qBittorrent on every
      reconnect. The icon opens qBittorrent; Jackett is on port ${jp},
      FlareSolverr on ${fp} and FileBrowser on ${bp}.
  tips:
    before_install:
      en_US: |
        Installed and managed by platforms/casaos/install.sh from
        github.com/rob-paprocki/qbittorrent-vpn-docker.

        | Web UI | Port |
        | ------ | ---- |
        | qBittorrent | ${qp} |
        | Jackett | ${jp} |
        | FlareSolverr | ${fp} |
        | FileBrowser | ${bp} |

        Settings live in ${STACK_DIR}/.env. Edit that file, then run
        bash ${STACK_DIR}/platforms/casaos/install.sh --apply
        Changes made in this app's settings in CasaOS are overwritten
        by the next --apply. Restart the whole app, never Gluetun alone.
  author: rob-paprocki (qbittorrent-vpn-docker)
  developer: Gluetun, qBittorrent, Jackett, FlareSolverr, FileBrowser
  category: Media
  architectures:
    - amd64
    - arm64
  version: '${RENDER_VERSION}'
  website: ${REPO_URL}
  repo: ${REPO_URL}
  support: ${REPO_URL}/issues
  docs: ${REPO_URL}/blob/main/platforms/casaos/README.md
EOF
  } >>"$out"
  # Keys that must not be empty in the YAML above (an empty image line
  # would mean compose.yaml could not be read).
  for key in CONFIG_PATH DOWNLOADS_PATH INCOMPLETE_DOWNLOADS; do
    [[ -n "${E[$key]}" ]] || die "${key} is empty in ${ENV_FILE}."
  done
  finalize_rendering "$out"
}

# port_script: the update-qbittorrent.sh Gluetun will mount (the stack's
# copy once there is one).
port_script() {
  if [[ -f "${STACK_DIR}/update-qbittorrent.sh" ]]; then
    printf '%s' "${STACK_DIR}/update-qbittorrent.sh"
  else
    printf '%s' "${SRC_DIR}/update-qbittorrent.sh"
  fi
}

# finalize_rendering FILE: put each service's revision into its REV_LABEL
# ('@REV@' in the rendering) and note each service's image. The revision is
# a hash of the service's lines without comments, its x-casaos descriptions
# and the label itself, so it changes exactly when CasaOS has to recreate
# the container. Gluetun's also covers update-qbittorrent.sh: Docker keeps
# the old file mounted until Gluetun is recreated, so a new script must
# recreate it. The masked copy (--dry-run display) reuses the real revisions.
declare -A REVS=() IMAGE_OF=()
SERVICE_NAMES=()
finalize_rendering() {
  local file=$1 line svc="" in_services=0 in_x=0 s extra="" tmp="${1}.tmp"
  local -A body=()
  SERVICE_NAMES=()
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^services:[[:space:]]*$ ]]; then
      in_services=1
      continue
    fi
    if [[ "$line" =~ ^[^[:space:]#] ]]; then
      in_services=0 svc=""
      continue
    fi
    ((in_services == 1)) || continue
    if [[ "$line" =~ ^\ \ ([A-Za-z0-9_.-]+):[[:space:]]*$ ]]; then
      svc=${BASH_REMATCH[1]} in_x=0
      SERVICE_NAMES+=("$svc")
      body[$svc]=""
      continue
    fi
    [[ -n "$svc" ]] || continue
    [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
    if ((in_x == 1)); then
      [[ "$line" =~ ^\ \ \ \ \  ]] && continue
      in_x=0
    fi
    if [[ "$line" =~ ^\ \ \ \ x-casaos: ]]; then
      in_x=1
      continue
    fi
    [[ "$line" == *"@REV@"* ]] && continue
    [[ "$line" =~ ^\ \ \ \ image:\ \'(.*)\'$ ]] && IMAGE_OF[$svc]=${BASH_REMATCH[1]}
    body[$svc]+="${line}"$'\n'
  done <"$file"
  for s in "${SERVICE_NAMES[@]}"; do
    [[ "$MASK" == 1 && -n "${REVS[$s]:-}" ]] && continue
    extra=""
    [[ "$s" == gluetun ]] && extra=$(sha256_of <"$(port_script)")
    REVS[$s]=$(printf '%s%s' "${body[$s]}" "$extra" | sha256_of | cut -c1-16)
  done
  (
    umask 077
    : >"$tmp"
  )
  svc="" in_services=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ ^services:[[:space:]]*$ ]]; then
      in_services=1
    elif [[ "$line" =~ ^[^[:space:]#] ]]; then
      in_services=0
    elif ((in_services == 1)) && [[ "$line" =~ ^\ \ ([A-Za-z0-9_.-]+):[[:space:]]*$ ]]; then
      svc=${BASH_REMATCH[1]}
    fi
    if [[ "$line" == *"@REV@"* ]]; then
      [[ -n "$svc" && -n "${REVS[$svc]:-}" ]] || die "Internal error: no revision for service '${svc}'."
      line=${line//@REV@/${REVS[$svc]}}
    fi
    printf '%s\n' "$line"
  done <"$file" >>"$tmp"
  mv "$tmp" "$file"
}

images_in() { sed -n "s/^    image: '\(.*\)'$/\1/p" "$1"; }

# ---------------------------------------------------------------------------
# Folders, seeds, images
# ---------------------------------------------------------------------------
prepare_folders() {
  local d src c=${E[CONFIG_PATH]}
  for d in gluetun qbittorrent jackett flaresolverr filebrowser; do
    run mkdir -p "${c}/${d}"
  done
  prepare_downloads
  # Seeds (qBittorrent save paths and VueTorrent, Jackett's FlareSolverr URL)
  # only when there is no config yet: never overwrite a running setup.
  for src in "${TRACKED_SEEDS[@]}"; do
    [[ -e "${c}/${src}" || ! -f "${SRC_DIR}/configs/${src}" ]] && continue
    run mkdir -p "$(dirname "${c}/${src}")"
    if [[ "$DRY_RUN" == 1 ]]; then
      msg_dry "would copy the seed configs/${src} to ${c}/${src}"
    elif [[ -d "${SRC_DIR}/.git" ]] && command -v git >/dev/null 2>&1 &&
      git -C "$SRC_DIR" cat-file -e "HEAD:configs/${src}" 2>/dev/null; then
      # From a git checkout take the committed seed: a developer's copy may
      # already hold their own seeded password hash.
      git -C "$SRC_DIR" show "HEAD:configs/${src}" >"${c}/${src}"
      chmod 644 "${c}/${src}"
    else
      install -m 644 "${SRC_DIR}/configs/${src}" "${c}/${src}"
    fi
  done
  # Gluetun runs this as /gluetun/update-qbittorrent.sh, so it must be executable.
  run chmod 755 "${STACK_DIR}/update-qbittorrent.sh"
  fix_ownership
  msg_ok "Folders ready under ${STACK_DIR} and ${E[DOWNLOADS_PATH]}"
}

# prepare_downloads: the download folders. qBittorrent writes there as
# PUID:PGID; FileBrowser as uid 1000 with PGID as an extra group. A folder
# the installer makes (or its own 'incomplete' folder, when an app could not
# write there) gets PUID:PGID and mode 2775: group-writable, and the setgid
# bit keeps what is created inside in the PGID group. A downloads folder
# that already exists (CasaOS's /DATA/Downloads share is 0777 root) keeps
# its owner and mode, with a warning when an app could not write there.
# Nothing inside either folder is touched.
prepare_downloads() {
  local d u=${E[PUID]} g=${E[PGID]}
  for d in "${E[DOWNLOADS_PATH]}" "${E[INCOMPLETE_DOWNLOADS]}"; do
    if [[ ! -d "$d" ]]; then
      run mkdir -p "$d"
      share_with_group "$d"
      continue
    fi
    if writable_by "$u" "$d" "$g" && writable_by "$FILEBROWSER_UID" "$d" "$g" "$FILEBROWSER_UID"; then
      continue
    fi
    if [[ "$d" == "${E[INCOMPLETE_DOWNLOADS]}" ]]; then
      share_with_group "$d"
    else
      msg_warn "${d} belongs to $(stat -c 'uid %u, group %g (mode %a)' "$d"); qBittorrent (uid ${u}) or FileBrowser (uid ${FILEBROWSER_UID}, group ${g}) may not be able to write there. Fix: chown ${u}:${g} ${d} && chmod 2775 ${d}"
    fi
  done
}

# share_with_group DIR: PUID:PGID, mode 2775 (see prepare_downloads).
share_with_group() {
  run chown "${E[PUID]}:${E[PGID]}" "$1"
  run chmod 2775 "$1"
}

# writable_by UID DIR GID...: can a process running as UID, with the groups
# GID..., create files in DIR? Like the kernel, only the owner bits count
# for the owner and only the group bits for the group. (ACLs are not read.)
writable_by() {
  local uid=$1 dir=$2 owner group mode gid
  shift 2
  read -r owner group mode < <(stat -c '%u %g %a' "$dir")
  mode=$((8#$mode))
  [[ "$uid" == 0 ]] && return 0
  [[ "$uid" == "$owner" ]] && { (((mode & 8#300) == 8#300)); return; }
  for gid in "$@"; do
    [[ "$gid" == "$group" ]] && { (((mode & 8#030) == 8#030)); return; }
  done
  (((mode & 8#003) == 8#003))
}

fix_ownership() {
  local d c=${E[CONFIG_PATH]} u=${E[PUID]} g=${E[PGID]} fb="${E[CONFIG_PATH]}/filebrowser"
  # FileBrowser runs as uid 1000 (not PUID), with PGID as an extra group. It
  # keeps database.sqlite (and SQLite's -wal/-shm files) in its folder, so
  # the folder and those files must be group-writable, or it can no longer
  # save anything once they belong to PUID (when PUID is not 1000). The
  # setgid bit keeps the files it creates there in the PGID group. Group
  # write comes first, so the running FileBrowser never sees its database
  # read-only in between. (chmod -R does not follow links it finds inside.)
  [[ -d "$fb" || "$DRY_RUN" == 1 ]] && run chmod -R g+rwX "$fb"
  # Gluetun runs as root and keeps its own folder.
  for d in qbittorrent jackett flaresolverr filebrowser; do
    [[ -d "${c}/${d}" || "$DRY_RUN" == 1 ]] && run chown -R "${u}:${g}" "${c}/${d}"
  done
  [[ -d "$fb" || "$DRY_RUN" == 1 ]] && run chmod g+s "$fb"
  return 0
}

# pull_images FILE: pull every image of the rendered app now, so download
# progress and registry errors show here instead of inside CasaOS. (Whether
# CasaOS then switched to a new image is checked in wait_for_stack.)
pull_images() {
  local img
  while IFS= read -r img; do
    [[ -n "$img" ]] || continue
    if [[ "$DRY_RUN" == 1 ]]; then
      msg_dry "would pull ${img}"
      continue
    fi
    msg_info "Pulling ${img}"
    docker pull -q "$img" >/dev/null || die "Could not pull ${img}. Check the host's internet connection (and the image name in compose.yaml)."
  done < <(images_in "$1")
  [[ "$DRY_RUN" == 1 ]] || msg_ok "Images are up to date"
}

# ---------------------------------------------------------------------------
# Seeding (qBittorrent password + Jackett search plugin, Jackett API key)
# with the repository's seeding CLI. FileBrowser needs none: compose.yaml
# gives its "admin" user the qBittorrent password on every start.
# ---------------------------------------------------------------------------

# seed_needed: on first install, when the login changed, or when a seeded
# file went missing. Re-seeding means restarting qBittorrent, so skip it
# when nothing it depends on changed.
SEED_KEY=""
seed_needed() {
  local c=${E[CONFIG_PATH]}
  # (The third part used to be JACKETT_PORT; the plugin now always talks to
  # Jackett's own port, so the key stays the same for existing installs.)
  SEED_KEY=$(printf '%s\0%s\0%s\0' "${E[QBITTORRENT_USER]}" "${E[QBITTORRENT_PASSWORD]}" "$JACKETT_INTERNAL_PORT" | sha256_of)
  [[ "${TS_RESEED:-0}" == 1 ]] && return 0
  [[ "$(state_get seeded)" != "$SEED_KEY" ]] && return 0
  grep -q 'Password_PBKDF2' "${c}/qbittorrent/qBittorrent/qBittorrent.conf" 2>/dev/null || return 0
  grep -q '"APIKey"' "${c}/jackett/Jackett/ServerConfig.json" 2>/dev/null || return 0
  [[ -f "${c}/qbittorrent/qBittorrent/nova3/engines/jackett.json" ]] || return 0
  return 1
}

# stop_for_seeding: qBittorrent writes its settings back when it stops, so a
# running qBittorrent would overwrite a freshly seeded password hash the next
# time it restarts. Stop it first; CasaOS starts it again when the app is
# applied.
stop_for_seeding() {
  local ids
  ids=$(service_ids qbittorrent | tr '\n' ' ')
  [[ -n "${ids// /}" ]] || return 0
  msg_info "Stopping qBittorrent while its config is seeded"
  # shellcheck disable=SC2086  # ids is a list of container ids
  run docker stop $ids >/dev/null
}

# seed_configs: run the repository's seeding CLI: qBittorrent's login and
# Jackett search plugin (pinned, checked against native/versions.env), and
# Jackett's API key. The search plugin is pointed at Jackett's own port
# inside Gluetun's network (--jackett-port), not the host port. The CLI
# reads .env as root, then switches to PUID:PGID (--as-user) before it
# writes anything: the config folders belong to the apps, so a compromised
# app could have planted a symlink there (say qBittorrent.conf ->
# /etc/passwd), and root must never write through it. It also writes the
# login into qBittorrent 5's [WebUI] section once qBittorrent has moved it
# there. Secrets stay in .env; nothing is passed on a command line.
seed_configs() {
  local log="$TEMP_DIR/seed.log" rc=0 c=${E[CONFIG_PATH]}
  local args=(--env "$ENV_FILE" --only "$SEEDERS" --as-user "${E[PUID]}:${E[PGID]}" --jackett-port "$JACKETT_INTERNAL_PORT")
  if ! seed_needed; then
    msg_ok "Configs already seeded for this login"
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would seed qBittorrent and Jackett with scripts/env-editor/seed_configs.py (as ${E[PUID]}:${E[PGID]})"
    return 0
  fi
  stop_for_seeding
  # The host's python3 (3.8 or later) needs nothing extra: these seeders
  # only use Python's standard library. ZimaOS seems to ship no python3, so
  # the fallback is a throwaway container with the stack folder read-only
  # and only the configs writable. -I: never import from the current folder.
  if command -v python3 >/dev/null 2>&1 &&
    python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
    msg_info "Seeding the qBittorrent and Jackett configs (host python3)"
    python3 -I "${STACK_DIR}/scripts/env-editor/seed_configs.py" "${args[@]}" >"$log" 2>&1 || rc=$?
  else
    local mounts=(-v "${STACK_DIR}:${STACK_DIR}:ro" -v "${ENV_FILE}:${ENV_FILE}:ro" -v "${c}:${c}")
    msg_info "Seeding the qBittorrent and Jackett configs (${SEED_IMAGE%%@*} container)"
    docker rm -f "${STACK}-seed" >/dev/null 2>&1 || true
    docker run --rm --name "${STACK}-seed" "${mounts[@]}" --entrypoint python3 "$SEED_IMAGE" \
      -I "${STACK_DIR}/scripts/env-editor/seed_configs.py" "${args[@]}" >"$log" 2>&1 || rc=$?
  fi
  sed 's/^/         /' "$log" >&2
  ((rc == 0)) || die "Seeding failed (see above). It needs internet access once, for the Jackett search plugin (raw.githubusercontent.com)."
  fix_ownership
  state_set seeded "$SEED_KEY"
  msg_ok "Seeded the qBittorrent and Jackett configs"
}

# ---------------------------------------------------------------------------
# Registering the app with CasaOS, and waiting for it
# ---------------------------------------------------------------------------

# explain_api_refusal: CasaOS said no; say why in plain words.
explain_api_refusal() {
  local what=$1 msg ports
  msg=$(api_message)
  if [[ "$msg" == *"ports in use"* ]]; then
    # {"data":{"ports_in_use":{"TCP":["8090"],"UDP":[]}},...} -> "TCP:8090"
    ports=$(printf '%s' "$API_BODY" | grep -o -E '"(TCP|UDP)":[[:space:]]*\[[^]]*\]' |
      tr -d '" []' | grep -v ':$' | tr '\n' ' ') || ports=""
    ports="${ports% }"
    msg_error "CasaOS refused the app: ports already in use by something else (${ports:-see the dashboard})."
    note "  Pick other ports in ${ENV_FILE} (QBIT_WEBUI_PORT, JACKETT_PORT," \
      "  FLARESOLVERR_PORT, FILEBROWSER_PORT), or re-run the installer and answer" \
      "  'yes' to 'Change web UI ports', then try again."
    exit 1
  fi
  die "CasaOS refused to ${what} the app (HTTP ${API_STATUS}): ${msg:-$(head -c 300 <<<"$API_BODY")}"
}

# app_call: the request that installs (POST) or updates (PUT) the app.
APP_METHOD="" APP_PATH="" APP_VERB=""
app_call() {
  if [[ "$APP_STATE" == none ]]; then
    APP_METHOD=POST APP_PATH="/compose" APP_VERB=install
  else
    APP_METHOD=PUT APP_PATH="/compose/${STACK}" APP_VERB=update
  fi
}

# validate_app RENDERED_FILE: CasaOS's own validation (dry_run=true changes
# nothing). It parses the YAML exactly as the real call will and checks the
# ports. Done before anything is pulled, stopped or seeded, so a refusal
# leaves the running app exactly as it was.
validate_app() {
  app_call
  api "$APP_METHOD" "${APP_PATH}?dry_run=true" "$1"
  [[ "$API_STATUS" == 200 ]] || explain_api_refusal "$APP_VERB"
  msg_ok "CasaOS accepted the app definition (validation only)"
}

# send_app RENDERED_FILE: the real install or update.
send_app() {
  app_call
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would send: ${APP_METHOD} ${API_BASE}${API_PREFIX}${APP_PATH} (Content-Type: application/yaml, the YAML above)"
    return 0
  fi
  api "$APP_METHOD" "$APP_PATH" "$1"
  [[ "$API_STATUS" == 200 ]] || explain_api_refusal "$APP_VERB"
  msg_ok "CasaOS took the ${APP_VERB}: $(api_message)"
}

# image_is_current CONTAINER_ID IMAGE: does the container run the image that
# IMAGE (a name:tag) means on this host now? False until CasaOS has
# recreated the container after a new image was pulled.
image_is_current() {
  local have want
  have=$(docker inspect -f '{{.Image}}' "$1" 2>/dev/null) || return 1
  want=$(docker image inspect --format '{{.Id}}' "$2" 2>/dev/null) || return 1
  [[ -n "$have" && "$have" == "$want" ]]
}

# wait_for_stack: wait until every service of the rendering runs the new
# definition (its revision label matches and it runs the current image),
# all run, and Gluetun is healthy (connected to the VPN). CasaOS applies in
# the background, so this is the only way to know it is done. Sets
# WAIT_RESULT to ready, timeout, or stuck (everything runs and is healthy,
# but on the OLD definition for minutes: CasaOS rolled the change back,
# which it does silently when it cannot save or load the new definition;
# CasaOS 0.4.x ignores pull errors, so the images are pulled here first).
WAIT_RESULT=""
wait_for_stack() {
  local start=$SECONDS rows line svc st status id rev ok old stable=0 told=0 stuck_since=-1
  local stuck_secs=$((WAIT_SECS < 300 ? WAIT_SECS : 300))
  msg_info "Waiting for the app to start (up to $(duration "$WAIT_SECS"): images, then the VPN connection)"
  while :; do
    rows=$(project_rows)
    ok=1 old=0
    for svc in "${SERVICE_NAMES[@]}"; do
      line=$(grep -m1 "^${svc}|" <<<"$rows") || line=""
      IFS='|' read -r _ st status id rev <<<"$line"
      [[ "$st" == running ]] || ok=0
      [[ -n "$line" && "$rev" != "${REVS[$svc]}" ]] && old=1
      if [[ "$svc" == gluetun ]]; then
        [[ "$status" == *"(healthy)"* ]] || ok=0
        if [[ "$st" == running && "$status" == *unhealthy* && "$told" == 0 ]]; then
          msg_warn "Gluetun is running but has not connected to the VPN yet (still waiting). Its log: docker logs ${STACK}-gluetun-1"
          told=1
        fi
      fi
    done
    if ((ok == 1 && old == 0)); then
      # Same definition everywhere; now the images (a pulled update).
      for svc in "${SERVICE_NAMES[@]}"; do
        id=$(grep -m1 "^${svc}|" <<<"$rows" | cut -d'|' -f4)
        image_is_current "$id" "${IMAGE_OF[$svc]}" || old=1
      done
    fi
    if ((ok == 1 && old == 0)); then
      stuck_since=-1
      stable=$((stable + 1))
      if ((stable >= 3)); then
        WAIT_RESULT=ready
        return 0
      fi
    elif ((ok == 1)); then
      stable=0
      ((stuck_since < 0)) && stuck_since=$SECONDS
      if ((SECONDS - stuck_since >= stuck_secs)); then
        WAIT_RESULT=stuck
        return 1
      fi
    else
      stable=0 stuck_since=-1
    fi
    if ((SECONDS - start >= WAIT_SECS)); then
      # Everything runs, but still the old definition (or image): that is
      # CasaOS not switching, not the VPN. (With a TS_WAIT of 300 s or less
      # the stuck time above is the whole wait, so this decides.)
      if ((ok == 1 && old == 1)); then WAIT_RESULT=stuck; else WAIT_RESULT=timeout; fi
      return 1
    fi
    sleep "$POLL_SECS"
  done
}

report_not_ready() {
  local rows
  rows=$(project_rows)
  msg_error "The app did not come up within $(duration "$WAIT_SECS"). Container states:"
  if [[ -n "$rows" ]]; then
    printf '%s\n' "$rows" | awk -F'|' '{ printf "           %-13s %-9s %s\n", $1, $2, $3 }' >&2
  else
    note "           (no containers yet: CasaOS may still be downloading images; see the dashboard)"
  fi
  note "" \
    "  CasaOS keeps working on it in the background; the dashboard shows progress." \
    "  qBittorrent, Jackett and FlareSolverr only start once Gluetun is healthy," \
    "  which needs a working VPN login. Gluetun's log says why it is not:" \
    "    docker logs --tail 40 ${STACK}-gluetun-1" \
    "  Fix the VPN settings in ${ENV_FILE}, then run --apply again."
}

report_stuck() {
  msg_error "CasaOS did not switch the app to the new settings: its containers still run the previous ones."
  note "  CasaOS applies a change in the background. When that fails (it cannot" \
    "  save or load the app's definition, or Docker cannot start a new" \
    "  container), the app keeps its old settings and CasaOS does not say so." \
    "  Its log says why:" \
    "    journalctl -u ${OS_NAME,,}-app-management -n 50 --no-pager" \
    "  Then run --apply again. (The app keeps running with the old settings.)"
}

# netns_of CONTAINER_ID: the network namespace of the container's main
# process, as the kernel names it (net:[4026532624]); empty if unknown.
netns_of() {
  local pid
  [[ -n "$1" ]] || return 0
  pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || pid=""
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 0
  readlink "${PROC_DIR}/${pid}/ns/net" 2>/dev/null || true
}

# check_shared_network: qBittorrent, Jackett and FlareSolverr must be in
# Gluetun's CURRENT network namespace. When Gluetun alone is restarted (by
# hand, or by a dashboard restart that raced), it gets a new namespace and
# the apps keep the old one, which only has loopback: no leak, but their
# web UIs are dead and nothing downloads, while Docker shows them running.
# Restarting the apps makes them join Gluetun's namespace again.
check_shared_network() {
  local try gid gns svc id stale ids
  for try in 1 2; do
    gid=$(service_ids gluetun | head -n1)
    gns=$(netns_of "$gid")
    if [[ -z "$gns" ]]; then
      msg_warn "Could not read Gluetun's network namespace (${PROC_DIR}); skipped the shared-network check."
      return 0
    fi
    stale=() ids=()
    for svc in qbittorrent jackett flaresolverr; do
      id=$(service_ids "$svc" | head -n1)
      if [[ -z "$id" || "$(netns_of "$id")" != "$gns" ]]; then
        stale+=("$svc")
        [[ -n "$id" ]] && ids+=("$id")
      fi
    done
    if ((${#stale[@]} == 0)); then
      msg_ok "qBittorrent, Jackett and FlareSolverr share Gluetun's network"
      return 0
    fi
    ((try == 2)) && break
    msg_warn "${stale[*]} lost Gluetun's network (Gluetun was restarted on its own); restarting them"
    if ((${#ids[@]} > 0)); then
      docker restart "${ids[@]}" >/dev/null 2>&1 || break
    fi
  done
  msg_error "${stale[*]} are not in Gluetun's network, so their web UIs do not answer (they have no internet either: nothing leaks)."
  note "  Fix: in the ${OS_NAME} dashboard, Stop the Torrent Stack app, then Start it" \
    "  (that recreates the network in the right order). Then run --apply again."
  exit 3
}

# probe URL [CURL_ARGS...]: the HTTP status from this host, 000 when nothing
# answers; the response body goes to TEMP_DIR/probe-body. Only 127.0.0.1,
# never through a proxy.
probe() {
  local url=$1
  shift
  curl --noproxy '*' -s -m 10 -o "$TEMP_DIR/probe-body" -w '%{http_code}' "$@" "$url" 2>/dev/null || true
}

# qbit_login_code: try the .env login on qBittorrent's API. The user and
# password go to curl in 0600 files (--data-urlencode name@file), never on
# its command line. 204 (or 200 "Ok.") means accepted.
qbit_login_code() {
  local u="$TEMP_DIR/qb-user" p="$TEMP_DIR/qb-pass"
  (
    umask 077
    printf '%s' "${E[QBITTORRENT_USER]}" >"$u"
    printf '%s' "${E[QBITTORRENT_PASSWORD]}" >"$p"
  )
  probe "http://127.0.0.1:${E[QBIT_WEBUI_PORT]}/api/v2/auth/login" \
    --data-urlencode "username@${u}" --data-urlencode "password@${p}"
  rm -f "$u" "$p"
}

# check_web_uis: every web UI must answer on its port from this host, and
# qBittorrent must accept the login in .env (which Gluetun's port-forward
# script uses too). Docker saying "running" is not enough: a UI can be dead
# (wrong port inside, lost network) while its container runs.
check_web_uis() {
  local deadline=$((SECONDS + UI_WAIT)) name code body pending left refused="" banned=""
  pending=(qbittorrent jackett flaresolverr filebrowser)
  msg_info "Checking that every web UI answers (up to $(duration "$UI_WAIT"))"
  while :; do
    left=()
    for name in "${pending[@]}"; do
      case "$name" in
        qbittorrent)
          code=$(qbit_login_code)
          body=$(head -c 20 "$TEMP_DIR/probe-body" 2>/dev/null || true)
          if [[ "$code" == 204 || ("$code" == 200 && "$body" != Fails.*) ]]; then
            continue
          elif [[ "$code" == 401 || ("$code" == 200 && "$body" == Fails.*) ]]; then
            refused=$code
            continue
          elif [[ "$code" == 403 ]]; then
            banned=1
            continue
          fi
          ;;
        jackett) code=$(probe "http://127.0.0.1:${E[JACKETT_PORT]}/UI/Dashboard") ;;
        flaresolverr) code=$(probe "http://127.0.0.1:${E[FLARESOLVERR_PORT]}/") ;;
        filebrowser) code=$(probe "http://127.0.0.1:${E[FILEBROWSER_PORT]}/") ;;
      esac
      [[ "$code" =~ ^[23][0-9][0-9]$ ]] || left+=("$name")
    done
    pending=(${left[@]+"${left[@]}"})
    ((${#pending[@]} == 0 || SECONDS >= deadline)) && break
    sleep "$((POLL_SECS > 0 ? POLL_SECS : 1))"
  done
  if [[ -z "$refused$banned" && ${#pending[@]} -eq 0 ]]; then
    msg_ok "Every web UI answers, and qBittorrent accepts the login in .env"
    return 0
  fi
  for name in ${pending[@]+"${pending[@]}"}; do
    case "$name" in
      qbittorrent) code=${E[QBIT_WEBUI_PORT]} ;;
      jackett) code=${E[JACKETT_PORT]} ;;
      flaresolverr) code=${E[FLARESOLVERR_PORT]} ;;
      filebrowser) code=${E[FILEBROWSER_PORT]} ;;
    esac
    msg_error "${name} does not answer on port ${code} of this box. Its log: docker logs --tail 40 ${STACK}-${name}-1"
  done
  if [[ -n "$refused" ]]; then
    msg_error "qBittorrent refused the login in .env (HTTP ${refused}), so Gluetun's port-forward script cannot log in either."
    note "  Seed the login again (this restarts qBittorrent):" \
      "    TS_RESEED=1 bash ${STACK_DIR}/platforms/casaos/install.sh --apply"
  fi
  [[ -n "$banned" ]] &&
    msg_error "qBittorrent has blocked this box after failed logins (HTTP 403). It lifts the block after an hour; run --apply again then."
  exit 3
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
# Passwords are printed only to a terminal. Output that goes to a file (a
# nightly `--update -y >log` from cron) gets where to find them instead.
show_login() {
  show "qBittorrent login" "user ${E[QBITTORRENT_USER]}"
  if [[ -n "$GENERATED_PASSWORD" && -t 2 ]]; then
    show "Password" "${GENERATED_PASSWORD}  (generated; also in .env)"
  elif [[ -n "$GENERATED_PASSWORD" ]]; then
    show "Password" "generated: QBITTORRENT_PASSWORD in ${ENV_FILE}"
  else
    show "Password" "QBITTORRENT_PASSWORD in .env"
  fi
}

# FileBrowser's user is always "admin" (FileBrowser's own default; nothing
# in compose.yaml changes it). Its password is the qBittorrent one, set again
# on every start (FILEBROWSER_ADMIN_PASSWORD in compose.yaml).
filebrowser_login() {
  show "FileBrowser login" "user admin, the qBittorrent password"
}

summary() {
  local ip
  ip=$(host_ip)
  echo >&2
  msg_ok "Done. The app is on the ${OS_NAME} dashboard as 'Torrent Stack'."
  show "qBittorrent" "http://${ip}:${E[QBIT_WEBUI_PORT]}"
  show "Jackett" "http://${ip}:${E[JACKETT_PORT]}"
  show "FlareSolverr" "http://${ip}:${E[FLARESOLVERR_PORT]}"
  show "FileBrowser" "http://${ip}:${E[FILEBROWSER_PORT]}"
  show_login
  filebrowser_login
  show "Settings" "${ENV_FILE}"
  echo >&2
  note "  To change a setting: edit ${ENV_FILE}, then run" \
    "    bash ${STACK_DIR}/platforms/casaos/install.sh --apply" \
    "  To update the stack:  bash ${STACK_DIR}/platforms/casaos/install.sh --update" \
    "  Restart the whole app from the dashboard, never the gluetun container alone;" \
    "  if a web UI goes dead, run --apply (it puts the apps back in Gluetun's network)."
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

# write_env: write the wizard's answers into STACK_DIR/.env (0600), keeping
# comments and any other keys. Shows a masked copy in --dry-run.
write_env() {
  local template="$ENV_FILE" staged="$TEMP_DIR/env.staged"
  [[ -f "$template" ]] || template="$SRC_DIR/.env.example"
  render_env "$template" "$staged"
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would write ${ENV_FILE} (0600):"
    print_env_masked "$staged"
    ENV_SOURCE="$staged"
    return 0
  fi
  if [[ -f "$ENV_FILE" ]] && cmp -s "$staged" "$ENV_FILE"; then
    msg_ok ".env unchanged"
  else
    [[ -f "$ENV_FILE" ]] && cp -p "$ENV_FILE" "${ENV_FILE}.bak" && chmod 600 "${ENV_FILE}.bak"
    install -m 600 "$staged" "$ENV_FILE"
    msg_ok "Wrote ${ENV_FILE}$([[ -f "${ENV_FILE}.bak" ]] && echo " (previous one: .env.bak)")"
  fi
  ENV_SOURCE="$ENV_FILE"
}
ENV_SOURCE=""

# deploy: everything after .env exists. Shared by install, --apply, --update.
# Order matters: nothing that touches the running app (pulling, stopping
# qBittorrent for seeding) happens before CasaOS has validated the change.
deploy() {
  local rendered="$TEMP_DIR/casaos-app.yml" masked="$TEMP_DIR/casaos-app.masked.yml"
  load_env "$ENV_SOURCE"
  check_inline_values
  COMPOSE_SRC="${SRC_DIR}/compose.yaml"
  ipv6_sysctl_on || msg_warn "This kernel has IPv6 switched off entirely (ipv6.disable=1), so Gluetun's IPv6 sysctl is left out; nothing can leak over IPv6."
  render_compose "$rendered"
  MASK=1 render_compose "$masked"
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "the CasaOS app YAML would be (secrets masked):"
    sed 's/^/         /' "$masked" >&2
  fi
  prepare_folders
  if ! vpn_ready; then
    # Startup gating. Unlike the native installers (whose env-editor and
    # FileBrowser start right away), nothing is registered: on CasaOS the
    # settings are edited in .env, not in a web UI, and the dashboard would
    # otherwise show an app whose main web UI cannot start.
    msg_warn "The VPN settings in ${ENV_FILE} are still the .env.example placeholders."
    note "  Gluetun and the apps behind it are not started with placeholder VPN" \
      "  credentials, so the app is not added to the dashboard yet. Everything" \
      "  else is ready: fill in VPN_TYPE and the WireGuard (or OpenVPN) values" \
      "  in ${ENV_FILE}, then run:" \
      "    bash ${STACK_DIR}/platforms/casaos/install.sh --apply"
    show_login
    return 0
  fi
  [[ "$NO_REGISTER" == 1 ]] || validate_app "$rendered"
  pull_images "$rendered"
  seed_configs
  if [[ "$DRY_RUN" != 1 ]]; then
    # Keep the last rendering next to .env (0600), for a manual Import.
    install -m 600 "$rendered" "${STACK_DIR}/casaos-app.yml"
  fi
  if [[ "$NO_REGISTER" == 1 ]]; then
    msg_ok "Prepared without registering (--no-register). To add the app by hand:"
    note "  1. Dashboard: + (next to Apps) > Install a customized app > Import." \
      "  2. Paste the contents of ${STACK_DIR}/casaos-app.yml" \
      "     (or the output of: bash ${STACK_DIR}/platforms/casaos/install.sh --print-yaml)." \
      "  3. Submit, then Install."
    return 0
  fi
  send_app "$rendered"
  [[ "$DRY_RUN" == 1 ]] && return 0
  if ! wait_for_stack; then
    if [[ "$WAIT_RESULT" == stuck ]]; then
      report_stuck
      exit 1
    fi
    report_not_ready
    exit 2
  fi
  msg_ok "All containers are running the new settings and Gluetun is connected"
  check_shared_network
  check_web_uis
  summary
}

# installed_stack_dir: the stack folder the installed CasaOS app uses (the
# folder update-qbittorrent.sh is mounted from), from its YAML in API_BODY.
installed_stack_dir() {
  sed -n -e "s#^[[:space:]]*source:[[:space:]]*['\"]\{0,1\}\(/[^'\"]*\)/update-qbittorrent\.sh['\"]\{0,1\}[[:space:]]*\$#\1#p" \
    -e "s#^[[:space:]]*-[[:space:]]*['\"]\{0,1\}\(/[^:'\"]*\)/update-qbittorrent\.sh:/gluetun/.*#\1#p" <<<"$API_BODY" | head -n1
}

# adopt_installed_dir: when our app is installed from another stack folder
# than the one picked (for example the one-liner re-run without the
# TS_APPDATA used at install), use the installed one instead of starting a
# second stack and overwriting the app with it. An explicit TS_APPDATA that
# disagrees is refused.
adopt_installed_dir() {
  local dir
  [[ "$APP_STATE" == ours ]] || return 0
  dir=$(installed_stack_dir)
  [[ -n "$dir" && "$dir" != "$STACK_DIR" ]] || return 0
  [[ "${dir##*/}" == "$STACK" && -d "$dir" ]] ||
    die "The installed '${STACK}' app uses ${dir}, which is not a ${STACK} folder this script can use. Uninstall the app from the dashboard first."
  if [[ -n "$TS_APPDATA_GIVEN" ]]; then
    die "The installed '${STACK}' app uses ${dir}, not ${STACK_DIR}. Run this again with TS_APPDATA=${dir%/*} (or without TS_APPDATA)."
  fi
  msg_ok "The installed app uses ${dir}; working there"
  set_stack_dir "${dir%/*}"
}

preflight() {
  check_root
  detect_platform
  check_docker
  [[ "$ACTION" == uninstall ]] || check_tun
  set_stack_dir "$(pick_appdata)"
  if [[ "$NO_REGISTER" == 1 ]]; then
    APP_STATE=none
  else
    api_discover
    api_probe
    check_existing_app
    adopt_installed_dir
  fi
  [[ "$ACTION" == update ]] && remembered_source
  return 0
}

do_install() {
  [[ -d "$APPDATA" ]] || die "${APPDATA} does not exist. Is this a ${OS_NAME} host with its /DATA disk mounted? (Set TS_APPDATA to use another folder.)"
  prepare_source fresh
  ui_setup
  [[ -f "$ENV_FILE" ]] && msg_ok "Found ${ENV_FILE}; its values are the defaults"
  wizard
  if [[ "$INTERACTIVE" == 1 ]]; then
    local text
    printf -v text 'Install the torrent stack as a %s app?\n\nFolder:      %s\nDownloads:   %s\nVPN:         %s (%s)\nqBittorrent: user %s, port %s\nUpdates:     %s' \
      "$OS_NAME" "$STACK_DIR" "${SETTINGS[DOWNLOADS_PATH]}" "${SETTINGS[VPN_PROVIDER]}" "${SETTINGS[VPN_TYPE]}" \
      "${SETTINGS[QBITTORRENT_USER]}" "${SETTINGS[QBIT_WEBUI_PORT]}" \
      "$([[ "${SETTINGS[COMPOSE_PROFILES]}" == watchtower ]] && echo Watchtower || echo 'install.sh --update')"
    ui_yesno "Ready" "$text" yes || die "Cancelled; nothing was changed." 130
  fi
  install_source
  write_env
  deploy
}

do_apply() {
  [[ -f "$ENV_FILE" ]] || die "There is no ${ENV_FILE}; install first (run this script without --apply)."
  prepare_source keep
  ENV_SOURCE="$ENV_FILE"
  deploy
}

# do_update: new repository files, then apply them with the NEW install.sh
# (this running copy may be older than what was just downloaded, and the
# rendering lives in the script).
do_update() {
  local args=(--apply)
  [[ -f "$ENV_FILE" ]] || die "There is no ${ENV_FILE}; install first (run this script without --update)."
  prepare_source fresh
  install_source
  if [[ "$DRY_RUN" != 1 && "${TS_REEXEC:-0}" != 1 ]]; then
    [[ "$UNATTENDED" == 1 ]] && args+=(-y)
    [[ "$NO_REGISTER" == 1 ]] && args+=(--no-register)
    msg_ok "Applying with the updated installer"
    # exec does not run the EXIT trap, so clean up first. TS_REEXEC stops
    # the new copy from doing this again; TS_APPDATA keeps it on this stack.
    rm -rf "$TEMP_DIR"
    TEMP_DIR=""
    TS_REEXEC=1 TS_APPDATA="$APPDATA" exec bash "${STACK_DIR}/platforms/casaos/install.sh" "${args[@]}"
  fi
  ENV_SOURCE="$ENV_FILE"
  deploy
}

do_print_yaml() {
  check_root
  set_stack_dir "$(pick_appdata)"
  [[ -f "$ENV_FILE" ]] || die "There is no ${ENV_FILE} yet. Run: install.sh --no-register   first (it prepares the folders and .env)."
  SRC_DIR="$STACK_DIR"
  [[ -n "$TS_SOURCE_DIR" ]] && SRC_DIR="${TS_SOURCE_DIR%/}"
  [[ -f "${SRC_DIR}/compose.yaml" ]] || die "${SRC_DIR}/compose.yaml is missing."
  COMPOSE_SRC="${SRC_DIR}/compose.yaml"
  ENV_SOURCE="$ENV_FILE"
  load_env "$ENV_FILE"
  check_inline_values
  vpn_ready || msg_warn "The VPN settings in ${ENV_FILE} are still placeholders; Gluetun will not connect."
  render_compose "$TEMP_DIR/casaos-app.yml"
  msg_warn "The YAML below contains your VPN key and passwords. Paste it only into your own CasaOS (+ > Install a customized app > Import)."
  cat "$TEMP_DIR/casaos-app.yml"
}

do_uninstall() {
  local start
  if [[ "$APP_STATE" == none ]]; then
    msg_ok "There is no '${STACK}' app in CasaOS."
  elif [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would send: DELETE ${API_BASE}${API_PREFIX}/compose/${STACK}?delete_config_folder=false"
  else
    # delete_config_folder=false: keep /DATA/AppData/torrent-stack (CasaOS's
    # default would delete it). CasaOS also removes the app's images.
    api DELETE "/compose/${STACK}?delete_config_folder=false"
    [[ "$API_STATUS" == 200 ]] || die "CasaOS refused to uninstall the app (HTTP ${API_STATUS}): $(api_message)"
    msg_info "CasaOS is removing the app"
    # CasaOS removes the containers, then the images, then its own copy of
    # the app (${CASAOS_APPS_DIR}/${STACK}). Wait for all of it, so an
    # install right after this cannot race the end of the removal.
    start=$SECONDS
    while [[ -n "$(project_rows)" || -e "${CASAOS_APPS_DIR}/${STACK}" ]] && ((SECONDS - start < 300)); do
      sleep "$POLL_SECS"
    done
    [[ -z "$(project_rows)" ]] || die "The containers are still there after 5 minutes; check the dashboard."
    [[ ! -e "${CASAOS_APPS_DIR}/${STACK}" ]] || msg_warn "CasaOS has not finished removing ${CASAOS_APPS_DIR}/${STACK} yet; give it a minute before installing again."
    msg_ok "Removed the app and its containers from ${OS_NAME}"
  fi
  if [[ "$PURGE" == 1 ]]; then
    if [[ -d "$STACK_DIR" ]]; then
      if [[ "$INTERACTIVE" == 1 ]]; then
        ui_setup
        ui_yesno "Delete everything" "Delete ${STACK_DIR} (configs, .env, VPN keys)? Downloads in ${DEFAULT_DOWNLOADS} or wherever you put them are kept." no ||
          die "Kept ${STACK_DIR}." 0
      fi
      run rm -rf -- "$STACK_DIR"
      [[ "$DRY_RUN" == 1 ]] || msg_ok "Deleted ${STACK_DIR}"
    fi
  else
    note "  Kept ${STACK_DIR} (configs, .env) and the downloads. Re-install any time;" \
      "  --uninstall --purge deletes the folder too."
  fi
}

main() {
  # --print-yaml keeps stdout for the YAML and talks to nobody.
  if [[ "$ACTION" == print-yaml ]]; then
    TEMP_DIR=$(mktemp -d)
    do_print_yaml
    return 0
  fi
  [[ "${TS_REEXEC:-0}" == 1 ]] || header_info
  [[ "$DRY_RUN" == 1 ]] && msg_warn "Dry run: nothing will be changed."
  TEMP_DIR=$(mktemp -d)
  preflight
  case "$ACTION" in
    install) do_install ;;
    apply) do_apply ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
  esac
}

main "$@"
