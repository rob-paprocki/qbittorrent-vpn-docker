#!/usr/bin/env bash
#
# platforms/unraid/install.sh
#
# Purpose: run as root in the Unraid terminal (Unraid 7.x; 6.12 should work
# but is untested). Installs this repository's Docker Compose stack (Gluetun,
# qBittorrent, Jackett, FlareSolverr, FileBrowser) as a Compose Manager Plus
# stack:
#
#   * the repository (compose.yaml, .env, update-qbittorrent.sh, scripts) goes
#     to <appdata>/torrent-stack, for example /mnt/user/appdata/torrent-stack;
#   * .env gets absolute Unraid paths, PUID 99 / PGID 100 (nobody:users), your
#     time zone, and the VPN and qBittorrent settings you enter;
#   * the apps' settings go to <appdata>/torrent-stack/appdata; the
#     qBittorrent and Jackett configs are seeded with the repo's own seeding
#     CLI, run in a throwaway python container (Unraid has no python3);
#     FileBrowser needs no seeding (compose.yaml gives its "admin" user the
#     qBittorrent password), only folders it can write to;
#   * the stack is registered with Compose Manager Plus as an "indirect"
#     stack pointing at that folder, and started through the plugin's own
#     compose wrapper, so the plugin's Docker > Compose page shows and manages
#     it (start, stop, update, logs, autostart, the ENV editor).
#
#   Install (wizard):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/unraid/install.sh)"
#   After editing .env (Compose Manager > Edit Stack > ENV), re-seed and restart:
#     bash /mnt/user/appdata/torrent-stack/platforms/unraid/install.sh --apply
#   Update the scripts and the images:
#     bash /mnt/user/appdata/torrent-stack/platforms/unraid/install.sh --update
#
# Run with --help for every option and environment variable. --dry-run shows
# every file and command without changing anything.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# The msg_info / msg_ok / msg_error output style follows community-scripts/
# ProxmoxVE (https://github.com/community-scripts/ProxmoxVE, MIT), by way of
# platforms/proxmox/install.sh. The stack layout this script writes mirrors
# what Compose Manager Plus (https://github.com/mstrhakr/compose_plugin, MIT)
# writes itself when you add an indirect stack in its UI; nothing from either
# project is downloaded or sourced at run time, and this script sends no
# telemetry.

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# The stack name is also the Compose project name. It must match
# `name: torrent-stack` in compose.yaml, so that Compose Manager (which passes
# `-p torrent-stack`) and plain `docker compose` / the env-editor (which read
# the name from compose.yaml) work on the same containers.
readonly STACK="torrent-stack"
REPO_URL="${TS_REPO_URL:-https://github.com/rob-paprocki/qbittorrent-vpn-docker}"
REPO_URL="${REPO_URL%.git}"
readonly REPO_URL
readonly RAW_URL="https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/unraid/install.sh"
TS_REF_SET=0
[[ -n "${TS_REF:-}" ]] && TS_REF_SET=1
TS_REF="${TS_REF:-main}"
TS_SOURCE_DIR="${TS_SOURCE_DIR:-}"

# Unraid and Compose Manager locations. These are fixed by Unraid and by the
# plugin; see platforms/unraid/README.md (References) for where each comes from.
readonly UNRAID_VERSION_FILE="/etc/unraid-version"
readonly UNRAID_VAR_INI="/var/local/emhttp/var.ini"
readonly UNRAID_IDENT_CFG="/boot/config/ident.cfg"
readonly CM_PLG="/boot/config/plugins/compose.manager.plg"
readonly CM_CFG="/boot/config/plugins/compose.manager/compose.manager.cfg"
readonly CM_EMHTTP="/usr/local/emhttp/plugins/compose.manager"
readonly CM_DEFAULT_ROOT="/boot/config/plugins/compose.manager/projects"
# First Compose Manager Plus release that pins a stack's project name in its
# `project_name` file (2026.09.03). Older releases, and the original
# Compose Manager, could run this stack as "torrent_stack" instead.
readonly CM_MIN_VERSION="2026.09.03"
readonly MIN_UNRAID="6.12.0"

# Throwaway container that runs scripts/env-editor/seed_configs.py. Unraid
# has no python3; Docker is always there. Pinned by tag and by digest (the
# digest is what docker actually pulls), bumped by hand.
readonly SEED_IMAGE="python:3.14.9-slim-trixie@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8"
# Which seeders run. FileBrowser is left out on purpose: compose.yaml sets
# its "admin" password from QBITTORRENT_PASSWORD (FILEBROWSER_ADMIN_PASSWORD)
# on every start and keeps its database in its /config folder, while the
# FileBrowser image (ghcr.io/gtsteffaniak/filebrowser:stable, Quantum 2.x)
# never reads the /config/settings.yaml that seeder writes. Leaving it out
# also means the container needs nothing from PyPI (bcrypt is only for that
# seed).
readonly SEED_ONLY="jackett,qbit"
# Where qBittorrent's Jackett search plugin finds Jackett: 127.0.0.1:9117,
# because both share Gluetun's network and Jackett always listens on 9117
# there. JACKETT_PORT in .env is only the port on the Unraid server.
readonly JACKETT_INNER_PORT=9117
# The FileBrowser image always runs as uid 1000, whatever PUID is;
# compose.yaml adds it to the PGID group (group_add). FileBrowser's config
# folder and the download folders are therefore made writable for that group.
readonly FILEBROWSER_UID=1000

# The apps' live settings go in <stack folder>/appdata, not in the
# repository's configs/ folder. configs/ holds two files git tracks (the
# starting templates for qBittorrent and Jackett); if the apps wrote to them,
# `git pull` in --update would refuse as soon as the repository changed one.
readonly CONFIG_DIRNAME="appdata"

# Unraid's convention: containers run as nobody:users.
readonly DEFAULT_PUID=99
readonly DEFAULT_PGID=100
readonly ENV_EDITOR_PORT=9191

# The two config seeds tracked in git (copied into CONFIG_PATH when missing).
readonly TRACKED_SEEDS=(
  "jackett/Jackett/ServerConfig.json"
  "qbittorrent/qBittorrent/qBittorrent.conf"
)
# .env keys that hold secrets: never printed in full.
readonly SECRET_KEYS=" WIREGUARD_PRIVATE_KEY OPENVPN_PASSWORD QBITTORRENT_PASSWORD SCRIPT_NOTIFY_URL WATCHTOWER_NOTIFICATION_URL "

# ---------------------------------------------------------------------------
# Output helpers (community-scripts style: msg_info / msg_ok / msg_error)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m'
  DGN=$'\033[32m' BOLD=$'\033[1m' CL=$'\033[m'
else
  YW="" BL="" RD="" GN="" DGN="" BOLD="" CL=""
fi

msg_info() { printf '  %s... %s%s\n' "$YW" "$1" "$CL"; }
msg_ok() { printf '  [ OK ] %s%s%s\n' "$GN" "$1" "$CL"; }
msg_warn() { printf '  [WARN] %s%s%s\n' "$YW" "$1" "$CL"; }
msg_error() { printf '  [FAIL] %s%s%s\n' "$RD" "$1" "$CL" >&2; }
msg_dry() { printf '  [DRY ] %s%s%s\n' "$BL" "$1" "$CL"; }
show() { printf '  %s%-22s%s %s%s%s\n' "$BOLD$DGN" "$1:" "$CL" "$BL" "$2" "$CL"; }
die() {
  msg_error "$1"
  exit "${2:-1}"
}

header_info() {
  cat <<'EOF'

  _____                         _       ____  _             _
 |_   _|__  _ __ _ __ ___ _ __ | |_    / ___|| |_ __ _  ___| | __
   | |/ _ \| '__| '__/ _ \ '_ \| __|___\___ \| __/ _` |/ __| |/ /
   | | (_) | |  | | |  __/ | | | ||_____|__) | || (_| | (__|   <
   |_|\___/|_|  |_|  \___|_| |_|\__|   |____/ \__\__,_|\___|_|\_\
     Gluetun + qBittorrent + Jackett + FlareSolverr  (Unraid)

EOF
}

usage() {
  cat <<EOF
One-liner (as root in the Unraid terminal):
  bash -c "\$(curl -fsSL ${RAW_URL})"
  Options go after it as: bash -c "\$(curl -fsSL ...)" install.sh --dry-run

Usage (as root in the Unraid terminal):
  install.sh                 Install, or re-run to change the answers. Asks
                             for the appdata and downloads folders, the VPN
                             and the qBittorrent login. Safe to re-run.
  install.sh --apply         After editing .env (Compose Manager > Edit Stack
                             > ENV): check it, re-seed qBittorrent and
                             Jackett, and start or restart the stack.
  install.sh --update        Update this repository's files (git pull or a
                             fresh download), then pull new images and
                             recreate the containers (Compose Manager's
                             "Update Stack").
  install.sh --uninstall     Stop and remove the containers and the Compose
                             Manager entry. Keeps <appdata>/torrent-stack
                             (.env, app settings) and your downloads.
  install.sh --uninstall --purge
                             Also delete <appdata>/torrent-stack. Refused if
                             the downloads folder is inside it; downloads are
                             never deleted.
Options:
  --dry-run                  Print every file and command, change nothing.
  --unattended, -y           No questions: take answers from TS_* variables,
                             the existing .env, or the defaults.
  --help

Environment variables (all optional; they also pre-fill the questions):
  TS_APPDATA=/mnt/user/appdata  Appdata share; the stack goes in <it>/torrent-stack.
  TS_DOWNLOADS=/mnt/user/downloads
                             Downloads folder (incomplete/ is created inside).
  TS_TZ, TS_PUID (99), TS_PGID (100)
  TS_VPN_PROVIDER (protonvpn), TS_VPN_TYPE (wireguard|openvpn),
  TS_WIREGUARD_ADDRESSES, TS_OPENVPN_USER, TS_SERVER_COUNTRIES,
  TS_QBITTORRENT_USER (admin)
  TS_QBIT_WEBUI_PORT (8090), TS_JACKETT_PORT (9117), TS_FLARESOLVERR_PORT
  (8191), TS_FILEBROWSER_PORT (8081)
                             Ports on the Unraid server; all four must differ.
  Secrets are read from files, never from the command line:
  TS_WIREGUARD_PRIVATE_KEY_FILE, TS_OPENVPN_PASSWORD_FILE,
  TS_QBITTORRENT_PASSWORD_FILE  (first line of the file; chmod 600 it; it is
                                also FileBrowser's admin password)
  TS_SCRIPT_NOTIFY_URL_FILE     Discord webhook for port-forward messages
                                (same format; default: none)
  TS_SOURCE_DIR=/path        Copy this local checkout instead of downloading.
  TS_REF=main                Branch or tag to download.  TS_REPO_URL  for a fork.
  TS_FORCE=1                 Take over an existing Compose Manager stack named
                             torrent-stack that points somewhere else.
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
trap 'echo; msg_error "Interrupted."; exit 130' INT TERM

# ---------------------------------------------------------------------------
# Arguments
# ---------------------------------------------------------------------------
ACTION="install"
DRY_RUN=0
PURGE=0
UNATTENDED="${TS_UNATTENDED:-0}"
TS_FORCE="${TS_FORCE:-0}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --apply) ACTION="apply" ;;
    --update) ACTION="update" ;;
    --uninstall) ACTION="uninstall" ;;
    --purge) PURGE=1 ;;
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

# Questions are asked only on a terminal and only when not unattended.
INTERACTIVE=0
[[ "$UNATTENDED" != 1 && -t 0 ]] && INTERACTIVE=1
if [[ "$INTERACTIVE" == 0 && "$UNATTENDED" != 1 && "$ACTION" == install && "$DRY_RUN" != 1 ]]; then
  die "No terminal to ask questions on. Run this in the Unraid terminal, or add --unattended (answers from TS_* variables and defaults)."
fi

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

# ask VAR "Question" DEFAULT: read an answer (the default on Enter, or when
# not interactive).
ask() {
  local __var=$1 prompt=$2 def=${3-} reply=""
  if [[ "$INTERACTIVE" == 1 ]]; then
    read -r -p "  ${prompt} [${def}]: " reply || reply=""
  fi
  printf -v "$__var" '%s' "${reply:-$def}"
}

# ask_secret VAR "Question": read without echo. Empty answer leaves VAR as is.
ask_secret() {
  local __var=$1 prompt=$2 reply=""
  [[ "$INTERACTIVE" == 1 ]] || return 0
  read -r -s -p "  ${prompt}: " reply || reply=""
  echo
  [[ -n "$reply" ]] && printf -v "$__var" '%s' "$reply"
  return 0
}

# ask_yes_no "Question" DEFAULT(y|n): true for yes.
ask_yes_no() {
  local prompt=$1 def=${2:-n} reply=""
  if [[ "$INTERACTIVE" != 1 ]]; then
    [[ "$def" == y ]]
    return
  fi
  read -r -p "  ${prompt} [$([[ "$def" == y ]] && echo Y/n || echo y/N)]: " reply || reply=""
  reply="${reply:-$def}"
  [[ "${reply,,}" == y || "${reply,,}" == yes ]]
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

is_secret_key() { [[ "$SECRET_KEYS" == *" $1 "* ]]; }

random_password() {
  # 20 letters and digits. head reads a fixed amount, so nothing in the
  # pipeline is cut off early (that would trip pipefail).
  head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20
}

# Unraid's LAN address, for the URLs printed at the end.
host_ip() {
  local ip=""
  ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1) || true
  [[ -n "$ip" ]] || ip=$(hostname -i 2>/dev/null | awk '{print $1}') || true
  echo "${ip:-<unraid-ip>}"
}

# ---------------------------------------------------------------------------
# .env reading and writing, in plain bash so secrets never appear in a
# process list. Values are written so that docker compose, Compose Manager
# and the env-editor all read them back exactly as entered.
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

# env_quote VALUE: the VALUE as it should appear after KEY= in .env.
#  - plain characters: unquoted;
#  - anything else without a single quote: single quotes, which docker
#    compose reads literally (no $-interpolation, no escapes);
#  - with a single quote but no $: double quotes with \ and " escaped.
env_quote() {
  local v=$1
  if [[ "$v" == *$'\n'* ]]; then
    return 1
  elif [[ "$v" =~ ^[A-Za-z0-9_./:@,+=%~-]*$ ]]; then
    printf '%s' "$v"
  elif [[ "$v" != *"'"* ]]; then
    printf "'%s'" "$v"
  elif [[ "$v" != *'$'* ]]; then
    v="${v//\\/\\\\}"
    v="${v//\"/\\\"}"
    printf '"%s"' "$v"
  else
    return 1
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
        if [[ -v "SETTINGS[$key]" && -z "${seen[$key]:-}" ]]; then
          seen[$key]=1
          q=$(env_quote "${SETTINGS[$key]}") || die "The value for ${key} cannot be stored in .env (it contains a line break, or both ' and \$). Please choose another."
          printf '%s=%s\n' "$key" "$q"
          continue
        fi
      fi
      printf '%s\n' "$line"
    done <"$template"
    for key in "${SETTINGS_ORDER[@]}"; do
      if [[ -z "${seen[$key]:-}" ]]; then
        q=$(env_quote "${SETTINGS[$key]}") || die "The value for ${key} cannot be stored in .env."
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
    printf '         %s\n' "$line"
  done <"$1"
}

# write_file PATH CONTENT: write a Compose Manager metadata file (no trailing
# newline, like the plugin writes them). Unchanged files are left alone, which
# spares the flash drive.
write_file() {
  local path=$1 content=$2
  if [[ -f "$path" && "$(cat "$path")" == "$content" ]]; then
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would write ${path}: ${content}"
    return 0
  fi
  printf '%s' "$content" >"$path"
}

# ---------------------------------------------------------------------------
# Unraid and Compose Manager checks
# ---------------------------------------------------------------------------
UNRAID_VERSION=""
CM_VERSION=""
CM_ROOT=""
CM_STACK_DIR=""

check_root() {
  [[ "$(id -u)" == 0 ]] || die "Run this as root (the Unraid terminal is root)."
}

check_unraid() {
  [[ -f "$UNRAID_VERSION_FILE" ]] || die "This is not an Unraid server (no ${UNRAID_VERSION_FILE}). For other platforms see platforms/ in the repository."
  UNRAID_VERSION=$(sed -n 's/^version="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$UNRAID_VERSION_FILE" | head -n1)
  [[ -n "$UNRAID_VERSION" ]] || die "Could not read the Unraid version from ${UNRAID_VERSION_FILE}."
  # Drop a pre-release suffix (7.3.0-rc.1 -> 7.3.0) before comparing.
  local base="${UNRAID_VERSION%%-*}"
  version_ge "$base" "$MIN_UNRAID" || die "Unraid ${UNRAID_VERSION} is too old: Compose Manager Plus needs ${MIN_UNRAID} or later."
  if version_ge "$base" "7.0.0"; then
    msg_ok "Unraid ${UNRAID_VERSION}"
  else
    msg_warn "Unraid ${UNRAID_VERSION}: this installer is tested against Unraid 7.x only; 6.12 should work."
  fi
  # Compose Manager refuses to start stacks while the array is stopped, and
  # /mnt/user does not exist until it starts.
  if [[ -f "$UNRAID_VAR_INI" ]]; then
    local state
    state=$(sed -n 's/^mdState="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$UNRAID_VAR_INI" | head -n1)
    [[ "$state" == STARTED ]] || die "The array is not started (state: ${state:-unknown}). Start it on the Main tab, then run this again."
  fi
}

check_docker() {
  command -v docker >/dev/null 2>&1 || die "The docker command is missing. Enable Docker under Settings > Docker."
  docker info >/dev/null 2>&1 || die "Docker is not running. Enable it under Settings > Docker (Enable Docker: Yes), then run this again."
  msg_ok "Docker is running"
}

# Runs after check_compose_manager: stock Unraid has no `docker compose`;
# Compose Manager Plus installs it. So someone without the plugin gets the
# "install it from the Apps tab" steps first, not this message.
check_compose_cli() {
  docker compose version >/dev/null 2>&1 || die "'docker compose' is missing. Compose Manager Plus installs it; reinstall the plugin from the Plugins tab."
  msg_ok "Docker Compose $(docker compose version --short 2>/dev/null || echo "(version unknown)")"
}

explain_compose_manager() {
  cat <<'EOF'

  This installer needs the Compose Manager Plus plugin. It runs Docker
  Compose stacks on Unraid and shows them on the Docker tab. To install it:

    1. Open the Unraid web UI and go to the Apps tab (Community Applications).
       No Apps tab? Install Community Applications first; see
       https://docs.unraid.net/unraid-os/using-unraid-to/run-docker-containers/community-applications/
    2. Search for "Compose Manager Plus" and click Install.
    3. Run this installer again.

EOF
}

check_compose_manager() {
  if [[ ! -f "$CM_PLG" || ! -f "$CM_EMHTTP/scripts/compose.sh" ]]; then
    msg_error "Compose Manager Plus is not installed."
    explain_compose_manager
    exit 1
  fi
  local author
  author=$(sed -n 's/^[[:space:]]*<!ENTITY[[:space:]]\{1,\}author[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' "$CM_PLG" | head -n1)
  CM_VERSION=$(sed -n 's/^[[:space:]]*<!ENTITY[[:space:]]\{1,\}version[[:space:]]\{1,\}"\([^"]*\)".*/\1/p' "$CM_PLG" | head -n1)
  if [[ "$author" == dcflachs ]]; then
    msg_error "You have the original Docker Compose Manager plugin (dcflachs, ${CM_VERSION:-unknown version})."
    cat <<'EOF'

  It is deprecated and runs this stack under a different project name
  ("torrent_stack"), which would split it from the files this repository
  expects. Its successor, Compose Manager Plus, keeps your existing stacks:

    1. Apps tab: search for "Compose Manager Plus" and click Install. It
       replaces the old plugin (they share one name) and picks up every
       stack you already have.
    2. Run this installer again.

EOF
    exit 1
  fi
  [[ -n "$CM_VERSION" ]] || die "Could not read the Compose Manager version from ${CM_PLG}."
  if ! version_ge "$CM_VERSION" "$CM_MIN_VERSION"; then
    msg_error "Compose Manager Plus ${CM_VERSION} is too old (need ${CM_MIN_VERSION} or later)."
    echo "  Update it on the Plugins tab (Check for Updates), then run this installer again."
    exit 1
  fi
  [[ -f "$CM_EMHTTP/scripts/compose_args.php" ]] || die "Compose Manager Plus is missing scripts/compose_args.php; reinstall it from the Plugins tab."
  command -v php >/dev/null 2>&1 || die "php is missing (Unraid's web UI needs it, so this is not a normal Unraid system)."

  # Projects folder: Settings > Compose > Projects Folder (default on the flash).
  CM_ROOT=""
  if [[ -f "$CM_CFG" ]]; then
    CM_ROOT=$(sed -n 's/^PROJECTS_FOLDER="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$CM_CFG" | head -n1)
  fi
  CM_ROOT="${CM_ROOT:-$CM_DEFAULT_ROOT}"
  CM_ROOT="${CM_ROOT%/}"
  CM_STACK_DIR="${CM_ROOT}/${STACK}"
  msg_ok "Compose Manager Plus ${CM_VERSION} (projects in ${CM_ROOT})"
}

check_tun() {
  # Gluetun needs /dev/net/tun; docker refuses to start it when the host has
  # no such device.
  if [[ ! -c /dev/net/tun ]]; then
    msg_info "Loading the tun kernel module (/dev/net/tun is missing)"
    run modprobe tun || true
    if [[ "$DRY_RUN" != 1 && ! -c /dev/net/tun ]]; then
      die "/dev/net/tun is still missing after 'modprobe tun'. Gluetun cannot run without it."
    fi
    msg_warn "Loaded tun by hand. If /dev/net/tun is missing again after a reboot, add 'modprobe tun' to /boot/config/go."
  else
    msg_ok "/dev/net/tun is available"
  fi
}

# ---------------------------------------------------------------------------
# Where things are
# ---------------------------------------------------------------------------
STACK_DIR=""   # <appdata>/torrent-stack: repository checkout, compose.yaml, .env
ENV_FILE=""
SRC_DIR=""     # where the repository files come from this run

# Stack folder of an existing install, from the Compose Manager entry.
existing_stack_dir() {
  [[ -f "$CM_STACK_DIR/indirect" ]] && cat "$CM_STACK_DIR/indirect"
  return 0
}

set_stack_dir() {
  STACK_DIR="${1%/}"
  ENV_FILE="${STACK_DIR}/.env"
}

# The share a path is in: /mnt/<user|pool|disk>/<share>. (Callers have
# checked that the path has both parts.)
share_root() {
  local rest="${1#/mnt/}"
  local a="${rest%%/*}"
  rest="${rest#"$a"/}"
  echo "/mnt/${a}/${rest%%/*}"
}

# check_unraid_path LABEL PATH: an absolute path in an existing share (or
# pool/disk folder): /mnt/<user|pool|disk>/<share>[/more]. Two reasons:
#  - /mnt/user, /mnt/cache or /mnt/disk1 alone would hand the whole array to
#    qBittorrent and FileBrowser, and folders made directly in them become
#    new shares;
#  - creating /mnt/user/<new> by hand makes a share with default settings
#    behind the user's back, so the share must already exist.
check_unraid_path() {
  local label=$1 p=$2
  [[ "$p" =~ ^/mnt/[^/]+/[^/]+ ]] ||
    die "${label} must be a share, or a folder in one, such as /mnt/user/<share> or /mnt/user/<share>/<folder> (not '${p}')."
  [[ "$p" != *[[:space:]]* ]] || die "${label} '${p}' contains a space; please use a folder name without spaces."
  # ':' would break the volume lines in compose.yaml; quotes, $, \ and `
  # are trouble for every tool that reads .env.
  [[ "$p" != *[\'\"\$\\\`:]* ]] || die "${label} '${p}' contains one of : ' \" \$ \\ \`; please use a plain folder name."
  [[ "$p" != *//* && "$p" != */./* && "$p" != */. && "$p" != *..* ]] ||
    die "${label} '${p}' must not contain '//', '.' or '..' parts."
  local root
  root=$(share_root "$p")
  if [[ ! -d "$root" ]]; then
    if [[ "$root" == /mnt/user/* ]]; then
      die "${label}: the share '${root#/mnt/user/}' does not exist. Create it on the Shares tab first, then run this again."
    fi
    die "${label}: '${root}' does not exist (is the array started and the pool or disk mounted?)."
  fi
}

# share_path PATH: the path inside its share (/mnt/cache/appdata/x and
# /mnt/user/appdata/x both give appdata/x), because on Unraid /mnt/user/<share>
# and /mnt/<pool or disk>/<share> show the same files. Folders of the
# Unassigned Devices plugin (/mnt/disks, /mnt/remotes, ...) are not shares
# and are kept as they are.
share_path() {
  local rest="${1#/mnt/}"
  local a="${rest%%/*}"
  case "$a" in
    disks | remotes | addons | rootshare) echo "$1" ;;
    *) echo "${rest#"$a"/}" ;;
  esac
}

# paths_overlap A B: true if A and B are the same folder, or one is inside
# the other, also when one is written as /mnt/user/... and the other as
# /mnt/<pool>/....
paths_overlap() {
  local a="${1%/}" b="${2%/}"
  [[ -n "$a" && -n "$b" ]] || return 1
  [[ -e "$a" && -e "$b" && "$a" -ef "$b" ]] && return 0
  [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]] && return 0
  if [[ "$a" == /mnt/*/* && "$b" == /mnt/*/* ]]; then
    a=$(share_path "$a")
    b=$(share_path "$b")
    [[ "$a" == "$b" || "$a" == "$b"/* || "$b" == "$a"/* ]] && return 0
  fi
  return 1
}

# check_downloads_location DOWNLOADS INCOMPLETE: downloads must not be in
# the stack folder, or hold it. FileBrowser serves the downloads folder, so it
# would show .env (VPN keys, passwords) and the app configs; and
# --uninstall --purge, which deletes the stack folder, would delete them.
check_downloads_location() {
  local p
  for p in "$@"; do
    [[ -n "$p" ]] || continue
    if paths_overlap "$p" "$STACK_DIR"; then
      die "The downloads folder '${p}' and the stack folder '${STACK_DIR}' overlap (the same folder, or one inside the other). FileBrowser would then show your VPN keys and passwords, and --uninstall --purge would delete your downloads. Use a downloads folder of its own, for example /mnt/user/downloads."
    fi
  done
}

# ---------------------------------------------------------------------------
# Getting the repository
# ---------------------------------------------------------------------------

# Copy SRC into DEST without git metadata, secrets or runtime state. Used for
# TS_SOURCE_DIR and for tarball downloads; a git clone is copied whole.
copy_tree() {
  local src=$1 dest=$2 f ex=()
  for f in "$src"/.env.*; do
    [[ -e "$f" && "${f##*/}" != .env.example ]] && ex+=("--exclude=./${f##*/}")
  done
  run mkdir -p "$dest"
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would copy ${src} to ${dest} (without .git, .env, configs/, ${CONFIG_DIRNAME}/, downloads/)"
    return 0
  fi
  tar -C "$src" --no-anchored --exclude=__pycache__ --exclude='*.pyc' \
    --anchored --exclude=./.git --exclude=./.env --exclude=./configs \
    --exclude=./downloads --exclude=./incomplete --exclude="./${CONFIG_DIRNAME}" \
    --exclude=./scripts/env-editor/.venv \
    ${ex[@]+"${ex[@]}"} -cf - . | tar -C "$dest" --no-same-owner -xf -
}

# Download the repository into TEMP_DIR/src: git when Unraid has it (6.12 and
# 7.x ship git), otherwise a tarball from GitHub with curl.
download_source() {
  local dest="$TEMP_DIR/src"
  if command -v git >/dev/null 2>&1; then
    msg_info "Cloning ${REPO_URL} (${TS_REF})"
    git clone -q --depth 1 --branch "$TS_REF" "${REPO_URL}.git" "$dest" ||
      die "git clone of ${REPO_URL} (${TS_REF}) failed."
  else
    local url="${REPO_URL}/archive/${TS_REF}.tar.gz"
    msg_info "Downloading ${url} (git is not installed)"
    mkdir -p "$dest"
    curl -fsSL --retry 3 "$url" -o "$TEMP_DIR/src.tar.gz" || die "Download of ${url} failed."
    tar -xzf "$TEMP_DIR/src.tar.gz" -C "$dest" --strip-components=1 --no-same-owner ||
      die "Could not unpack ${url}."
  fi
  [[ -f "$dest/compose.yaml" && -f "$dest/.env.example" ]] || die "The download has no compose.yaml/.env.example; is TS_REF='${TS_REF}' right?"
  SRC_DIR="$dest"
  msg_ok "Got the repository (${TS_REF})"
}

# prepare_source update|keep: decide where the repository files come from.
prepare_source() {
  local mode=$1
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    TS_SOURCE_DIR="${TS_SOURCE_DIR%/}"
    [[ -f "$TS_SOURCE_DIR/compose.yaml" && -f "$TS_SOURCE_DIR/platforms/unraid/install.sh" ]] ||
      die "TS_SOURCE_DIR '${TS_SOURCE_DIR}' is not a checkout of this repository."
    SRC_DIR="$TS_SOURCE_DIR"
    return 0
  fi
  if [[ -f "$STACK_DIR/compose.yaml" ]]; then
    if [[ "$mode" == keep ]]; then
      SRC_DIR="$STACK_DIR"
      return 0
    fi
    if [[ -d "$STACK_DIR/.git" ]] && command -v git >/dev/null 2>&1; then
      SRC_DIR="$STACK_DIR"   # updated in place with git pull
      return 0
    fi
  fi
  download_source
}

# install_source update|keep: put the repository files into STACK_DIR.
install_source() {
  local mode=$1
  if [[ "$SRC_DIR" == "$STACK_DIR" ]]; then
    if [[ "$mode" == update ]]; then
      msg_info "Updating ${STACK_DIR} with git pull"
      if [[ "$TS_REF_SET" == 1 ]]; then
        # No --depth here: a depth-1 fetch would cut the new commit off from
        # the installed one, and git would call the two "unrelated". ^{commit}
        # also makes a tag fast-forward like a branch.
        run git -C "$STACK_DIR" fetch -q origin "$TS_REF"
        run git -C "$STACK_DIR" merge -q --ff-only 'FETCH_HEAD^{commit}' ||
          die "git could not fast-forward ${STACK_DIR} to ${TS_REF} (git says why above). Either files were changed there by hand ('git -C ${STACK_DIR} status' lists them), or ${TS_REF} is another branch or an older tag, which --update does not switch to. To switch by hand: git -C ${STACK_DIR} checkout --detach FETCH_HEAD"
      else
        run git -C "$STACK_DIR" pull -q --ff-only ||
          die "git pull in ${STACK_DIR} failed (git says why above). If it names files: they are repository files that were changed in that folder (for example compose.yaml edited in Compose Manager). 'git -C ${STACK_DIR} status' lists them, 'git -C ${STACK_DIR} diff' shows the changes; copy away what you want to keep, put a file back with 'git -C ${STACK_DIR} checkout -- FILE', then run --update again."
      fi
      msg_ok "Updated ${STACK_DIR} ($(git -C "$STACK_DIR" log -1 --format='%h %s' 2>/dev/null || echo git))"
    fi
    return 0
  fi
  if [[ -z "$TS_SOURCE_DIR" && -d "$SRC_DIR/.git" && ! -e "$STACK_DIR/compose.yaml" ]]; then
    # First install from this run's own fresh clone: keep .git so --update
    # can git pull. A TS_SOURCE_DIR (perhaps a working checkout with its own
    # .env, configs and downloads) always goes through copy_tree, which
    # leaves those out.
    msg_info "Copying the repository to ${STACK_DIR}"
    run mkdir -p "$STACK_DIR"
    if [[ "$DRY_RUN" == 1 ]]; then
      msg_dry "would copy the clone (with .git) to ${STACK_DIR}"
    else
      tar -C "$SRC_DIR" -cf - . | tar -C "$STACK_DIR" --no-same-owner -xf -
      # update-qbittorrent.sh is chmod +x below; do not let git call that a change.
      git -C "$STACK_DIR" config core.fileMode false
      # The apps' live settings folder is not part of the repository; tell
      # this checkout's git to ignore it (a local rule, not a tracked file).
      mkdir -p "$STACK_DIR/.git/info"
      grep -qxF "/${CONFIG_DIRNAME}/" "$STACK_DIR/.git/info/exclude" 2>/dev/null ||
        printf '/%s/\n' "$CONFIG_DIRNAME" >>"$STACK_DIR/.git/info/exclude"
    fi
  else
    msg_info "Copying ${SRC_DIR} to ${STACK_DIR}"
    copy_tree "$SRC_DIR" "$STACK_DIR"
  fi
  msg_ok "Repository files are in ${STACK_DIR}"
}

# ---------------------------------------------------------------------------
# The wizard
# ---------------------------------------------------------------------------
PUID="" PGID="" TZ_VALUE="" APPDATA="" DOWNLOADS="" CONFIG_PATH=""
VPN_READY=0
QBIT_PW_GENERATED=""

# Placeholders from .env.example: a value equal to the example's is unset.
placeholder() { env_get "$SRC_DIR/.env.example" "$1"; }

is_unset() {
  local key=$1 val=$2
  [[ -z "$val" || "$val" == "$(placeholder "$key")" ]]
}

# The value to start from for KEY: TS_<KEY>, else the existing .env, else DEFAULT.
current() {
  local key=$1 def=${2-} tsvar="TS_$1" val=""
  if [[ -n "${!tsvar:-}" ]]; then
    printf '%s' "${!tsvar}"
    return 0
  fi
  val=$(env_get "$ENV_FILE" "$key")
  if [[ -n "$val" ]]; then printf '%s' "$val"; else printf '%s' "$def"; fi
}

detect_tz() {
  # Settings > Date and Time stores the zone as timeZone in emhttp's state
  # (var.ini) and on the flash (ident.cfg); /etc/localtime is the fallback.
  local tz="" f
  for f in "$UNRAID_VAR_INI" "$UNRAID_IDENT_CFG"; do
    [[ -f "$f" ]] || continue
    tz=$(sed -n 's/^timeZone="\{0,1\}\([^"]*\)"\{0,1\}.*/\1/p' "$f" | head -n1)
    [[ -n "$tz" ]] && break
  done
  if [[ -z "$tz" && -L /etc/localtime ]]; then
    tz=$(readlink -f /etc/localtime 2>/dev/null) || tz=""
    tz="${tz#*/zoneinfo/}"
    [[ "$tz" == /* ]] && tz=""
  fi
  echo "$tz"
}

wizard() {
  local tz_default pf vpn_provider vpn_type wg_key wg_addr ovpn_user ovpn_pw countries qbit_user qbit_pw
  echo
  echo "  ${BOLD}Folders${CL}"
  # TS_APPDATA if given, else where the stack already is (or the default).
  local appdata_default="${TS_APPDATA:-}"
  [[ -n "$appdata_default" ]] || appdata_default="${STACK_DIR%/"$STACK"}"
  [[ -n "$appdata_default" ]] || appdata_default="/mnt/user/appdata"
  ask APPDATA "Appdata share (the stack goes in <it>/${STACK})" "$appdata_default"
  APPDATA="${APPDATA%/}"
  # "/mnt/user/appdata/torrent-stack" means the stack folder itself.
  APPDATA="${APPDATA%/"$STACK"}"
  check_unraid_path "Appdata" "$APPDATA"
  set_stack_dir "${APPDATA}/${STACK}"

  local dl_default
  dl_default=$(env_get "$ENV_FILE" DOWNLOADS_PATH)
  [[ "$dl_default" == /* ]] || dl_default=""
  dl_default="${TS_DOWNLOADS:-${dl_default:-/mnt/user/downloads}}"
  ask DOWNLOADS "Downloads folder" "$dl_default"
  DOWNLOADS="${DOWNLOADS%/}"
  check_unraid_path "Downloads" "$DOWNLOADS"
  check_downloads_location "$DOWNLOADS"

  # App settings: <stack>/appdata for a new install. An existing .env keeps
  # its CONFIG_PATH if that is a folder inside this stack folder, so a re-run
  # never moves the apps to an empty config folder.
  CONFIG_PATH="${STACK_DIR}/${CONFIG_DIRNAME}"
  local cfg_old
  cfg_old=$(env_get "$ENV_FILE" CONFIG_PATH)
  cfg_old="${cfg_old%/}"
  if [[ "$cfg_old" == "$STACK_DIR"/* && "$cfg_old" != *..* && "$cfg_old" != *[[:space:]]* ]]; then
    CONFIG_PATH="$cfg_old"
  fi
  if [[ "$CONFIG_PATH" == "$STACK_DIR/configs" || "$CONFIG_PATH" == "$STACK_DIR/configs/"* ]]; then
    msg_warn "CONFIG_PATH is ${CONFIG_PATH}, inside the repository's own configs/ folder. qBittorrent and Jackett rewrite files git tracks there, so --update's git pull can refuse to run. New installs use ${STACK_DIR}/${CONFIG_DIRNAME}."
  fi
  PUID=$(current PUID "$DEFAULT_PUID")
  PGID=$(current PGID "$DEFAULT_PGID")
  [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] || die "PUID/PGID must be numbers (got ${PUID}/${PGID})."
  [[ "$PUID" != 0 && "$PGID" != 0 ]] || die "PUID/PGID 0 would run qBittorrent and Jackett as root; Unraid uses 99/100."

  tz_default=$(current TZ "")
  if [[ -z "${TS_TZ:-}" && ( -z "$tz_default" || ( ! -f "$ENV_FILE" ) ) ]]; then
    tz_default=$(detect_tz)
    tz_default="${tz_default:-$(placeholder TZ)}"
  fi
  ask TZ_VALUE "Time zone" "$tz_default"
  [[ -f "/usr/share/zoneinfo/${TZ_VALUE}" || ! -d /usr/share/zoneinfo ]] ||
    msg_warn "'${TZ_VALUE}' is not a known time zone name; check it (for example Europe/Berlin)."

  echo
  echo "  ${BOLD}VPN${CL} (Gluetun). Leave the keys empty to fill them in later in"
  echo "  Compose Manager > Edit Stack > ENV; the stack waits until they are set."
  echo "  Port forwarding (needed for seeding) works with: protonvpn,"
  echo "  private internet access, perfect privacy, privatevpn."
  vpn_provider=$(current VPN_PROVIDER "protonvpn")
  ask vpn_provider "VPN provider (Gluetun name)" "$vpn_provider"
  vpn_type=$(current VPN_TYPE "wireguard")
  ask vpn_type "VPN protocol (wireguard or openvpn)" "$vpn_type"
  [[ "$vpn_type" == wireguard || "$vpn_type" == openvpn ]] || die "VPN protocol must be wireguard or openvpn."
  set_setting VPN_PROVIDER "$vpn_provider"
  set_setting VPN_TYPE "$vpn_type"

  if [[ "$vpn_type" == wireguard ]]; then
    wg_key=$(env_get "$ENV_FILE" WIREGUARD_PRIVATE_KEY)
    if [[ -n "${TS_WIREGUARD_PRIVATE_KEY_FILE:-}" ]]; then
      read_secret_file wg_key "$TS_WIREGUARD_PRIVATE_KEY_FILE"
    fi
    pf="(empty = keep current)"
    is_unset WIREGUARD_PRIVATE_KEY "$wg_key" && pf="(empty = fill in later)"
    ask_secret wg_key "WireGuard private key ${pf}"
    wg_addr=$(current WIREGUARD_ADDRESSES "")
    is_unset WIREGUARD_ADDRESSES "$wg_addr" && [[ -z "${TS_WIREGUARD_ADDRESSES:-}" ]] && wg_addr=""
    ask wg_addr "WireGuard address (the Address line, e.g. 10.2.0.2/32)" "$wg_addr"
    if ! is_unset WIREGUARD_PRIVATE_KEY "$wg_key"; then set_setting WIREGUARD_PRIVATE_KEY "$wg_key"; fi
    if [[ -n "$wg_addr" ]]; then set_setting WIREGUARD_ADDRESSES "$wg_addr"; fi
    if ! is_unset WIREGUARD_PRIVATE_KEY "$wg_key" && ! is_unset WIREGUARD_ADDRESSES "$wg_addr"; then VPN_READY=1; fi
  else
    ovpn_user=$(current OPENVPN_USER "")
    is_unset OPENVPN_USER "$ovpn_user" && [[ -z "${TS_OPENVPN_USER:-}" ]] && ovpn_user=""
    ask ovpn_user "OpenVPN username (ProtonVPN: add +pmp)" "$ovpn_user"
    ovpn_pw=$(env_get "$ENV_FILE" OPENVPN_PASSWORD)
    if [[ -n "${TS_OPENVPN_PASSWORD_FILE:-}" ]]; then
      read_secret_file ovpn_pw "$TS_OPENVPN_PASSWORD_FILE"
    fi
    pf="(empty = keep current)"
    is_unset OPENVPN_PASSWORD "$ovpn_pw" && pf="(empty = fill in later)"
    ask_secret ovpn_pw "OpenVPN password ${pf}"
    if [[ -n "$ovpn_user" ]]; then set_setting OPENVPN_USER "$ovpn_user"; fi
    if ! is_unset OPENVPN_PASSWORD "$ovpn_pw"; then set_setting OPENVPN_PASSWORD "$ovpn_pw"; fi
    if ! is_unset OPENVPN_USER "$ovpn_user" && ! is_unset OPENVPN_PASSWORD "$ovpn_pw"; then VPN_READY=1; fi
  fi
  countries=$(current SERVER_COUNTRIES "$(placeholder SERVER_COUNTRIES)")
  ask countries "VPN exit countries (comma-separated, empty = any)" "$countries"
  set_setting SERVER_COUNTRIES "$countries"

  echo
  echo "  ${BOLD}qBittorrent login${CL}. The password is also FileBrowser's: FileBrowser's"
  echo "  user is always \"admin\", with this password."
  qbit_user=$(current QBITTORRENT_USER "admin")
  is_unset QBITTORRENT_USER "$qbit_user" && qbit_user="admin"
  ask qbit_user "qBittorrent username" "$qbit_user"
  [[ "$qbit_user" =~ ^[A-Za-z0-9._@-]+$ ]] || die "Please use letters, digits and . _ @ - in the qBittorrent username."
  qbit_pw=$(env_get "$ENV_FILE" QBITTORRENT_PASSWORD)
  if [[ -n "${TS_QBITTORRENT_PASSWORD_FILE:-}" ]]; then
    read_secret_file qbit_pw "$TS_QBITTORRENT_PASSWORD_FILE"
  fi
  if is_unset QBITTORRENT_PASSWORD "$qbit_pw"; then
    qbit_pw=""
    ask_secret qbit_pw "qBittorrent password (empty = generate one)"
    if [[ -z "$qbit_pw" ]]; then
      qbit_pw=$(random_password)
      QBIT_PW_GENERATED="$qbit_pw"
    fi
  else
    ask_secret qbit_pw "qBittorrent password (empty = keep current)"
  fi
  check_qbit_password "$qbit_pw"
  set_setting QBITTORRENT_USER "$qbit_user"
  set_setting QBITTORRENT_PASSWORD "$qbit_pw"
  # Discord webhook for the port-forward script: from
  # TS_SCRIPT_NOTIFY_URL_FILE (a secret: it lets anyone post), else the
  # existing value; the .env.example placeholder becomes empty, which means
  # no notifications.
  local notify_url
  notify_url=$(env_get "$ENV_FILE" SCRIPT_NOTIFY_URL)
  if [[ -n "${TS_SCRIPT_NOTIFY_URL_FILE:-}" ]]; then
    read_secret_file notify_url "$TS_SCRIPT_NOTIFY_URL_FILE"
  elif is_unset SCRIPT_NOTIFY_URL "$notify_url"; then
    notify_url=""
  fi
  set_setting SCRIPT_NOTIFY_URL "$notify_url"

  # Paths, ids, time zone; Watchtower stays off (Compose Manager updates the
  # images, see README).
  set_setting PUID "$PUID"
  set_setting PGID "$PGID"
  set_setting TZ "$TZ_VALUE"
  set_setting CONFIG_PATH "$CONFIG_PATH"
  set_setting DOWNLOADS_PATH "$DOWNLOADS"
  set_setting INCOMPLETE_DOWNLOADS "${DOWNLOADS}/incomplete"
  local key val
  for key in QBIT_WEBUI_PORT JACKETT_PORT FLARESOLVERR_PORT FILEBROWSER_PORT; do
    val=$(current "$key" "$(placeholder "$key")")
    [[ "$val" =~ ^[0-9]+$ && "$val" -ge 1 && "$val" -le 65535 ]] || die "${key} must be a port number (got '${val}')."
    set_setting "$key" "$val"
  done
  check_ports "${SETTINGS[QBIT_WEBUI_PORT]}" "${SETTINGS[JACKETT_PORT]}" \
    "${SETTINGS[FLARESOLVERR_PORT]}" "${SETTINGS[FILEBROWSER_PORT]}"
  if [[ ! -f "$ENV_FILE" ]]; then
    set_setting COMPOSE_PROFILES ""
  fi
}

# check_qbit_password PASSWORD: the qBittorrent password is also FileBrowser's
# admin password (compose.yaml: FILEBROWSER_ADMIN_PASSWORD). FileBrowser
# stores it as a bcrypt hash, and bcrypt refuses more than 72 bytes, so
# FileBrowser could not create or update its admin user with a longer one.
check_qbit_password() {
  local pw=$1 bytes
  [[ ${#pw} -ge 8 ]] || die "The qBittorrent password must be at least 8 characters."
  # printf is a bash builtin, so the password is not on any command line.
  bytes=$(printf '%s' "$pw" | wc -c)
  [[ "$bytes" -le 72 ]] || die "The qBittorrent password is ${bytes} bytes long; at most 72 work, because it is also FileBrowser's admin password and FileBrowser (bcrypt) cannot store a longer one."
}

# check_ports QBIT JACKETT FLARESOLVERR FILEBROWSER: refuse ports this stack
# cannot use. All four are ports on the Unraid server, so they must be
# different numbers. compose.yaml publishes Jackett's JACKETT_PORT and
# FlareSolverr's FLARESOLVERR_PORT to the fixed ports they listen on inside
# Gluetun's network (9117 and 8191), so any free port works for those. It
# publishes QBIT_WEBUI_PORT as the same number inside that network, because
# qBittorrent's web UI rejects a request whose port differs, so that one
# must not be a port Jackett (9117), FlareSolverr (8191) or Gluetun's own
# control (8000) and health (9999) servers already use there.
check_ports() {
  local names=(QBIT_WEBUI_PORT JACKETT_PORT FLARESOLVERR_PORT FILEBROWSER_PORT)
  local i j
  local -a ports=("$@")
  for i in 0 1 2 3; do
    [[ "${ports[i]:-}" =~ ^[0-9]+$ && "${ports[i]}" -ge 1 && "${ports[i]}" -le 65535 ]] ||
      die "${names[i]} must be a port number from 1 to 65535 (got '${ports[i]:-}')."
  done
  for i in 0 1 2; do
    for ((j = i + 1; j < 4; j++)); do
      [[ "${ports[i]}" != "${ports[j]}" ]] ||
        die "${names[i]} and ${names[j]} are both ${ports[i]}; each app needs its own port on the server."
    done
  done
  case "${ports[0]}" in
  8000 | 8191 | 9117 | 9999) die "QBIT_WEBUI_PORT cannot be ${ports[0]}: qBittorrent shares Gluetun's network with Jackett (9117), FlareSolverr (8191) and Gluetun's own servers (8000, 9999), and uses the same port number inside it. Pick another port, such as 8090." ;;
  esac
  return 0
}

show_summary() {
  echo
  echo "  ${BOLD}Summary${CL}"
  show "Stack folder" "$STACK_DIR"
  show "Configs" "$CONFIG_PATH"
  show "Downloads" "$DOWNLOADS (incomplete: ${DOWNLOADS}/incomplete)"
  show "PUID/PGID" "${PUID}/${PGID}"
  show "Time zone" "$TZ_VALUE"
  show "VPN" "${SETTINGS[VPN_PROVIDER]} / ${SETTINGS[VPN_TYPE]} ($([[ "$VPN_READY" == 1 ]] && echo "keys set" || echo "keys not set yet: the stack will not start"))"
  show "qBittorrent user" "${SETTINGS[QBITTORRENT_USER]}"
  show "FileBrowser user" "admin (with the qBittorrent password)"
  show "Ports" "qBittorrent ${SETTINGS[QBIT_WEBUI_PORT]}, Jackett ${SETTINGS[JACKETT_PORT]}, FlareSolverr ${SETTINGS[FLARESOLVERR_PORT]}, FileBrowser ${SETTINGS[FILEBROWSER_PORT]}"
  show "Compose Manager" "$CM_STACK_DIR"
  echo
}

# ---------------------------------------------------------------------------
# Files on disk
# ---------------------------------------------------------------------------

# write_env: render .env from the existing one (or .env.example) and check it
# with `docker compose config` before it replaces the old file.
write_env() {
  local template="$ENV_FILE"
  [[ -f "$template" ]] || template="$SRC_DIR/.env.example"
  local staged="$TEMP_DIR/env.new"
  render_env "$template" "$staged"
  docker compose -p "$STACK" -f "$SRC_DIR/compose.yaml" --env-file "$staged" config -q ||
    die "docker compose rejected the new .env (see above). Nothing was changed."
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would write ${ENV_FILE} (mode 600):"
    print_env_masked "$staged"
    return 0
  fi
  if [[ -f "$ENV_FILE" ]] && cmp -s "$staged" "$ENV_FILE"; then
    msg_ok ".env unchanged"
  else
    [[ -f "$ENV_FILE" ]] && cp -p "$ENV_FILE" "${ENV_FILE}.bak"
    install -m 600 "$staged" "$ENV_FILE"
    [[ -f "${ENV_FILE}.bak" ]] && chmod 600 "${ENV_FILE}.bak"
    msg_ok "Wrote ${ENV_FILE}$([[ -f "${ENV_FILE}.bak" ]] && echo " (previous one: .env.bak)")"
  fi
}

# prepare_folders: config and download folders owned by PUID:PGID, the
# git-tracked config seeds, and an executable port-forward script.
prepare_folders() {
  local d src
  for d in gluetun qbittorrent jackett flaresolverr filebrowser; do
    run mkdir -p "${CONFIG_PATH}/${d}"
  done
  run mkdir -p "$DOWNLOADS" "${DOWNLOADS}/incomplete"
  # Seeds (qBittorrent save paths and VueTorrent, Jackett's FlareSolverr URL)
  # only when there is no config yet: never overwrite a running setup.
  for src in "${TRACKED_SEEDS[@]}"; do
    [[ -e "${CONFIG_PATH}/${src}" || ! -f "${SRC_DIR}/configs/${src}" ]] && continue
    run mkdir -p "$(dirname "${CONFIG_PATH}/${src}")"
    if [[ "$DRY_RUN" == 1 ]]; then
      msg_dry "would copy the seed configs/${src} to ${CONFIG_PATH}/${src}"
    elif [[ -d "${SRC_DIR}/.git" ]] && command -v git >/dev/null 2>&1 &&
      git -C "$SRC_DIR" cat-file -e "HEAD:configs/${src}" 2>/dev/null; then
      # From a git checkout take the committed seed: a developer's copy may
      # already hold their own seeded password hash.
      git -C "$SRC_DIR" show "HEAD:configs/${src}" >"${CONFIG_PATH}/${src}"
      chmod 644 "${CONFIG_PATH}/${src}"
    else
      install -m 644 "${SRC_DIR}/configs/${src}" "${CONFIG_PATH}/${src}"
    fi
  done
  # Gluetun runs this as /gluetun/update-qbittorrent.sh, so it must be executable.
  run chmod 755 "${STACK_DIR}/update-qbittorrent.sh"
  fix_ownership
  msg_ok "Folders ready (owned by ${PUID}:${PGID}; FileBrowser's uid ${FILEBROWSER_UID} writes through group ${PGID})"
}

fix_ownership() {
  local d
  # Gluetun runs as root and keeps its own folder; env-editor credentials stay
  # root-only. qBittorrent, Jackett and FlareSolverr run as PUID:PGID.
  for d in qbittorrent jackett flaresolverr; do
    [[ -d "${CONFIG_PATH}/${d}" || "$DRY_RUN" == 1 ]] && run chown -R "${PUID}:${PGID}" "${CONFIG_PATH}/${d}"
  done
  # FileBrowser runs as uid 1000 whatever PUID is, with PGID as an extra
  # group, and keeps its database (database.sqlite, plus the -wal and -shm
  # files SQLite adds next to it) in this folder. So: the folder belongs to
  # PUID:PGID and the group may write in it; setgid (the "s") gives new files
  # the PGID group. Files FileBrowser already made keep their owner (uid
  # 1000) and get the PGID group with group write. A plain chown -R to PUID,
  # as for the other apps, would leave FileBrowser a database it cannot write.
  d="${CONFIG_PATH}/filebrowser"
  if [[ -d "$d" || "$DRY_RUN" == 1 ]]; then
    run chown "${PUID}:${PGID}" "$d"
    run chgrp -R "$PGID" "$d"
    run chmod -R g+rwX "$d"
    run chmod g+s "$d"
  fi
  # Only the two download folders themselves, never what is already in them.
  # Group write and setgid let FileBrowser (through PGID) add, rename and
  # delete files there; permissions are only added, never taken away.
  run chown "${PUID}:${PGID}" "$DOWNLOADS" "${DOWNLOADS}/incomplete"
  run chmod ug+rwx "$DOWNLOADS" "${DOWNLOADS}/incomplete"
  run chmod g+s "$DOWNLOADS" "${DOWNLOADS}/incomplete"
}

# stop_for_seeding: qBittorrent writes its settings back when it stops, so a
# running qBittorrent would overwrite a freshly seeded password hash the
# next time it restarts. Stop it first. The compose up that follows starts it
# again; when there is no compose up (a seeding failure, or VPN keys that are
# placeholders again), restart_stopped_apps does.
STOPPED_FOR_SEED=0
stop_for_seeding() {
  local running
  running=$(docker ps -q --filter "label=com.docker.compose.project=${STACK}" \
    --filter "label=com.docker.compose.service=qbittorrent" 2>/dev/null) || running=""
  if [[ -n "$running" && -f "$ENV_FILE" ]]; then
    msg_info "Stopping qBittorrent while its config is seeded"
    run docker compose -p "$STACK" -f "$STACK_DIR/compose.yaml" --env-file "$ENV_FILE" stop qbittorrent
    STOPPED_FOR_SEED=1
  fi
}

# restart_stopped_apps: start qBittorrent again, as it was, if
# stop_for_seeding stopped it. `start` (not `up`) restarts the existing
# container without recreating it, so nothing else changes.
restart_stopped_apps() {
  [[ "$STOPPED_FOR_SEED" == 1 ]] || return 0
  STOPPED_FOR_SEED=0
  msg_info "Starting qBittorrent again"
  if run docker compose -p "$STACK" -f "$STACK_DIR/compose.yaml" --env-file "$ENV_FILE" start qbittorrent; then
    msg_ok "qBittorrent is running again"
  else
    msg_warn "Could not start qBittorrent again. Use Compose Up on the Docker > Compose page."
  fi
}

# seed_configs: run the repository's seeding CLI in a throwaway python
# container. It reads .env and writes qBittorrent's password hash and Jackett
# search plugin, and Jackett's API key, into CONFIG_PATH (see SEED_ONLY).
# Secrets stay in .env; nothing is passed on a command line. The stack folder
# (.env, the scripts) is mounted read-only and only CONFIG_PATH is writable;
# the CLI reads .env as root, then switches to PUID:PGID (--as-user) before
# it writes anything. Nothing is installed in the container, so the only
# download is the Jackett search plugin from GitHub. --jackett-port points
# that plugin at 127.0.0.1:9117 (Jackett inside Gluetun's network), not at
# JACKETT_PORT, which is only the port on the Unraid server.
seed_configs() {
  local mounts=(-v "${STACK_DIR}:${STACK_DIR}:ro" -v "${CONFIG_PATH}:${CONFIG_PATH}")
  msg_info "Seeding the qBittorrent and Jackett configs (${SEED_IMAGE%%@*})"
  [[ "$DRY_RUN" == 1 ]] || docker rm -f "${STACK}-seed" >/dev/null 2>&1 || true
  if ! run docker run --rm --name "${STACK}-seed" "${mounts[@]}" --entrypoint python3 "$SEED_IMAGE" \
    -I "${STACK_DIR}/scripts/env-editor/seed_configs.py" --env "${STACK_DIR}/.env" \
    --config-root "$CONFIG_PATH" --only "$SEED_ONLY" --as-user "${PUID}:${PGID}" \
    --jackett-port "$JACKETT_INNER_PORT" 2>&1 | sed 's/^/         /'; then
    restart_stopped_apps
    die "Seeding failed (see above). The container needs internet access to download the Jackett search plugin from GitHub."
  fi
  fix_ownership
  msg_ok "Seeded the qBittorrent and Jackett configs"
}

# ---------------------------------------------------------------------------
# Compose Manager
# ---------------------------------------------------------------------------

# check_conflicts: refuse to take over somebody else's stack.
check_conflicts() {
  local other target
  # Compose Manager's entry for this stack (<Projects Folder>/torrent-stack)
  # must be a folder of its own. If the Projects Folder is the appdata share,
  # the entry would be the stack folder itself, and Compose Manager's Delete
  # Stack (like --uninstall) removes the entry folder: .env, the VPN keys and
  # every app config would go with it.
  if paths_overlap "$CM_STACK_DIR" "$STACK_DIR"; then
    die "Compose Manager keeps its entry for this stack in ${CM_STACK_DIR} (Settings > Compose > Projects Folder is ${CM_ROOT}), and that is the stack folder ${STACK_DIR}, or overlaps it. Deleting the stack in Compose Manager would then delete your .env and configs. Either set the Projects Folder back to its default, ${CM_DEFAULT_ROOT} (or any folder of its own), or put the stack in another appdata folder, for example TS_APPDATA=${APPDATA:-/mnt/user/appdata}/stacks."
  fi
  if [[ -d "$CM_STACK_DIR" ]]; then
    target=$(existing_stack_dir)
    if [[ "$target" != "$STACK_DIR" ]]; then
      local what="has its own compose file"
      [[ -n "$target" ]] && what="points at ${target}"
      if [[ "$TS_FORCE" != 1 ]]; then
        die "A Compose Manager stack '${STACK}' already exists and ${what}. Remove it in Compose Manager (or move it), or re-run with TS_FORCE=1 to repoint it at ${STACK_DIR}."
      fi
      msg_warn "Repointing the existing Compose Manager stack '${STACK}' at ${STACK_DIR} (TS_FORCE=1)."
    fi
  fi
  # Another Compose Manager stack already pointing at our folder?
  for other in "$CM_ROOT"/*/indirect; do
    [[ -f "$other" ]] || continue
    [[ "$(dirname "$other")" == "$CM_STACK_DIR" ]] && continue
    if [[ "$(cat "$other")" == "$STACK_DIR" ]]; then
      die "The Compose Manager stack '$(basename "$(dirname "$other")")' already uses ${STACK_DIR}. Remove that entry first."
    fi
  done
  # Containers of project torrent-stack started from another compose file
  # (for example a manual install elsewhere) would clash on names and ports.
  # The label lists every compose file; the first one is the main file (an
  # override added in Compose Manager's Web UI tab comes after it).
  local files
  files=$(docker ps -a --filter "label=com.docker.compose.project=${STACK}" \
    --format '{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | sed 's/,.*//' | sort -u) || files=""
  if [[ -n "$files" ]] && grep -qvxF "${STACK_DIR}/compose.yaml" <<<"$files"; then
    die "Containers of a '${STACK}' project from another folder exist (${files//$'\n'/, }). Stop them first, for example: docker compose -p ${STACK} down"
  fi
}

# register_stack: create or update the Compose Manager entry. These are the
# files Compose Manager Plus writes itself for an indirect stack ("Add Stack"
# with an indirect path): the compose file and .env stay in STACK_DIR, the
# entry under CM_ROOT holds only metadata.
register_stack() {
  local autostart=$1 port
  port=$(env_get "$ENV_FILE" QBIT_WEBUI_PORT)
  [[ -n "$port" ]] || port="${SETTINGS[QBIT_WEBUI_PORT]:-8090}"
  run mkdir -p "$CM_STACK_DIR"
  write_file "$CM_STACK_DIR/name" "$STACK"
  write_file "$CM_STACK_DIR/project_name" "$STACK"
  write_file "$CM_STACK_DIR/indirect" "$STACK_DIR"
  write_file "$CM_STACK_DIR/indirect_mode" "folder"
  write_file "$CM_STACK_DIR/description" "Gluetun VPN + qBittorrent + Jackett + FlareSolverr + FileBrowser (qbittorrent-vpn-docker)"
  write_file "$CM_STACK_DIR/webui_url" "http://[IP]:${port}/"
  write_file "$CM_STACK_DIR/autostart" "$autostart"
  msg_ok "Compose Manager stack '${STACK}' registered (autostart: ${autostart})"
}

# cm_compose ACTION: run up/down/update/stop exactly as Compose Manager Plus
# does from its UI and at array start: ask the plugin's compose_args.php for
# the stack's arguments, then call the plugin's compose.sh wrapper. The
# wrapper takes the plugin's per-stack lock and records the result, so the
# Compose page shows the same state as for a stack started there.
cm_compose() {
  local action=$1
  local args_php="$CM_EMHTTP/scripts/compose_args.php" wrapper="$CM_EMHTTP/scripts/compose.sh"
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would run: bash ${wrapper} -c ${action} -p ${STACK} -f ${STACK_DIR}/compose.yaml -e ${ENV_FILE} -s ${CM_STACK_DIR}  (arguments from ${args_php})"
    return 0
  fi
  local out key value result="" message="" project="" stack_path="" project_dir="" default_discovery=false env_path=""
  local -a files=() profiles=()
  # compose_args.php reads its options with PHP getopt(), where --stack-path
  # takes an optional value: that only works as --stack-path=VALUE, and a
  # separate word would end option parsing (and lose --format).
  out=$(php "$args_php" --compose-root "$CM_ROOT" --project "$STACK" --action "$action" \
    --format tsv "--stack-path=${CM_STACK_DIR}" 2>&1) || true
  while IFS=$'\t' read -r key value; do
    case "$key" in
      result) result=$value ;;
      message) message=$value ;;
      projectName) project=$value ;;
      stackPath) stack_path=$value ;;
      projectDirectory) project_dir=$value ;;
      useDefaultFileDiscovery) default_discovery=$value ;;
      envFilePath) env_path=$value ;;
      composeFile) files+=("$value") ;;
      profile) profiles+=("$value") ;;
    esac
  done <<<"$out"
  [[ "$result" == success ]] || die "Compose Manager could not resolve the stack: ${message:-$out}"
  [[ "$project" == "$STACK" ]] || die "Compose Manager would run this stack as project '${project}', not '${STACK}'. Check ${CM_STACK_DIR}/project_name."
  local -a cmd=(bash "$wrapper" -c "$action" -p "$project")
  if [[ "$default_discovery" == true && -n "$project_dir" ]]; then
    cmd+=(-w "$project_dir")
  else
    local f
    for f in "${files[@]}"; do cmd+=(-f "$f"); done
  fi
  [[ -n "$env_path" ]] && cmd+=(-e "$env_path")
  local p
  for p in ${profiles[@]+"${profiles[@]}"}; do cmd+=(-g "$p"); done
  cmd+=(-s "${stack_path:-$CM_STACK_DIR}")
  "${cmd[@]}"
}

# vpn_ready_from_env: are the VPN keys in .env real (not .env.example's)?
vpn_ready_from_env() {
  local type
  type=$(env_get "$ENV_FILE" VPN_TYPE)
  if [[ "$type" == openvpn ]]; then
    ! is_unset OPENVPN_USER "$(env_get "$ENV_FILE" OPENVPN_USER)" &&
      ! is_unset OPENVPN_PASSWORD "$(env_get "$ENV_FILE" OPENVPN_PASSWORD)"
  else
    ! is_unset WIREGUARD_PRIVATE_KEY "$(env_get "$ENV_FILE" WIREGUARD_PRIVATE_KEY)" &&
      ! is_unset WIREGUARD_ADDRESSES "$(env_get "$ENV_FILE" WIREGUARD_ADDRESSES)"
  fi
}

# Load paths and ids from an installed .env (for --apply, --update, --uninstall).
load_installed() {
  local dir
  dir=$(existing_stack_dir)
  [[ -n "$dir" ]] || dir="${TS_APPDATA:+${TS_APPDATA%/}/${STACK}}"
  [[ -n "$dir" ]] || dir="/mnt/user/appdata/${STACK}"
  set_stack_dir "$dir"
  [[ -f "$ENV_FILE" && -f "$STACK_DIR/compose.yaml" ]] ||
    die "No installed stack found at ${STACK_DIR} (no compose.yaml/.env). Run the installer without options first."
  SRC_DIR="$STACK_DIR"
  [[ -n "$TS_SOURCE_DIR" ]] && SRC_DIR="${TS_SOURCE_DIR%/}"
  PUID=$(env_get "$ENV_FILE" PUID)
  PGID=$(env_get "$ENV_FILE" PGID)
  CONFIG_PATH=$(env_get "$ENV_FILE" CONFIG_PATH)
  DOWNLOADS=$(env_get "$ENV_FILE" DOWNLOADS_PATH)
  local p
  for p in CONFIG_PATH DOWNLOADS; do
    [[ "${!p}" == /* ]] || die "${p/DOWNLOADS/DOWNLOADS_PATH} in ${ENV_FILE} must be an absolute path on Unraid (got '${!p}')."
  done
  [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ && "$PUID" != 0 && "$PGID" != 0 ]] ||
    die "PUID/PGID in ${ENV_FILE} must be non-zero numbers (Unraid: 99/100)."
  local inc
  inc=$(env_get "$ENV_FILE" INCOMPLETE_DOWNLOADS)
  [[ "$inc" == "${DOWNLOADS}/incomplete" ]] || msg_warn "INCOMPLETE_DOWNLOADS is '${inc}', not '${DOWNLOADS}/incomplete'; only the latter is created and owned by ${PUID}:${PGID} here."
  # .env may have been edited in the ENV tab since the install.
  check_downloads_location "$DOWNLOADS" "$inc"
}

# download_paths_in_env: DOWNLOADS_PATH and INCOMPLETE_DOWNLOADS from .env,
# one per line, as absolute paths (a relative one is relative to the stack
# folder, as docker compose reads it).
download_paths_in_env() {
  local key p
  for key in DOWNLOADS_PATH INCOMPLETE_DOWNLOADS; do
    p=$(env_get "$ENV_FILE" "$key")
    [[ -n "$p" ]] || continue
    [[ "$p" == /* ]] || p="${STACK_DIR}/${p#./}"
    printf '%s\n' "${p%/}"
  done
}

print_access() {
  local ip qport jport fport
  ip=$(host_ip)
  qport=$(env_get "$ENV_FILE" QBIT_WEBUI_PORT)
  jport=$(env_get "$ENV_FILE" JACKETT_PORT)
  fport=$(env_get "$ENV_FILE" FILEBROWSER_PORT)
  echo
  echo "  ${BOLD}Web UIs${CL}"
  show "qBittorrent" "http://${ip}:${qport}"
  show "Jackett" "http://${ip}:${jport}"
  show "FileBrowser" "http://${ip}:${fport}"
  show "qBittorrent login" "$(env_get "$ENV_FILE" QBITTORRENT_USER) / the password in ${ENV_FILE}"
  if [[ -n "$QBIT_PW_GENERATED" ]]; then
    show "Generated password" "$QBIT_PW_GENERATED"
  fi
  show "FileBrowser login" "admin / the same password as qBittorrent"
  echo "         (FileBrowser sets it again from .env each time it starts, so change"
  echo "         it in .env, not in FileBrowser.)"
  show "Compose Manager" "Docker tab > Compose > ${STACK}"
}

print_env_editor_hint() {
  echo
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
    echo "  Optional: the repository's web .env editor works here too (Python 3 found):"
    echo "    bash ${STACK_DIR}/scripts/setup.sh     then open http://$(host_ip):${ENV_EDITOR_PORT}"
  else
    echo "  .env changes: Compose Manager > ${STACK} > Edit Stack > ENV, then:"
    echo "    bash ${STACK_DIR}/platforms/unraid/install.sh --apply"
  fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_install() {
  # First guess for the stack folder, so a re-run reads the existing .env:
  # the Compose Manager entry, else TS_APPDATA, else Unraid's default appdata.
  local guess
  guess=$(existing_stack_dir)
  [[ -n "$guess" ]] || guess="${TS_APPDATA:-/mnt/user/appdata}"
  [[ "$guess" == */"$STACK" ]] || guess="${guess%/}/${STACK}"
  set_stack_dir "$guess"

  # .env.example (the placeholders) comes from the source we will install.
  prepare_source keep
  wizard
  # The answer may be another folder than the guess: an existing stack there
  # keeps its own files, a new one gets a fresh download.
  if [[ -z "$TS_SOURCE_DIR" ]]; then
    if [[ -f "$STACK_DIR/compose.yaml" ]]; then
      SRC_DIR="$STACK_DIR"
    elif [[ "$SRC_DIR" != "$TEMP_DIR/src" ]]; then
      download_source
    fi
  fi
  if [[ -e "$STACK_DIR" && ! -f "$STACK_DIR/compose.yaml" && -n "$(ls -A "$STACK_DIR" 2>/dev/null)" ]]; then
    die "${STACK_DIR} exists and is not empty, but holds no compose.yaml. Pick another appdata folder or empty it."
  fi
  check_conflicts
  show_summary
  if [[ "$INTERACTIVE" == 1 && "$DRY_RUN" != 1 ]]; then
    ask_yes_no "Go ahead?" y || {
      echo "  Nothing was changed."
      exit 0
    }
  fi

  install_source keep
  write_env
  prepare_folders
  # From here on the stack's own files are the source.
  [[ "$DRY_RUN" == 1 ]] || SRC_DIR="$STACK_DIR"
  stop_for_seeding
  seed_configs

  if [[ "$VPN_READY" == 1 ]]; then
    register_stack true
    msg_info "Starting the stack through Compose Manager (Gluetun connects first; this can take a minute)"
    cm_compose up || die "The stack did not start. See the output above, or the Compose page in the Unraid UI."
    msg_ok "Stack '${STACK}' is up"
    [[ "$DRY_RUN" == 1 ]] || print_access
  else
    register_stack false
    # A stack that was already running (with the keys it was started with)
    # gets qBittorrent back as it was; nothing is recreated.
    restart_stopped_apps
    echo
    msg_warn "Not started: the VPN keys are not set yet."
    echo "  1. Docker tab > Compose > ${STACK} > Edit Stack > ENV: fill in the VPN lines."
    echo "  2. Then run: bash ${STACK_DIR}/platforms/unraid/install.sh --apply"
  fi
  print_env_editor_hint
  echo
}

do_apply() {
  load_installed
  check_conflicts
  docker compose -p "$STACK" -f "$STACK_DIR/compose.yaml" --env-file "$ENV_FILE" config -q ||
    die "docker compose rejected ${ENV_FILE} (see above). Fix it in Compose Manager > Edit Stack > ENV."
  if ! vpn_ready_from_env; then
    register_stack false
    die "The VPN keys in ${ENV_FILE} are still the .env.example placeholders. Fill them in (Edit Stack > ENV), then run --apply again."
  fi
  local qbit_user qbit_pw
  qbit_user=$(env_get "$ENV_FILE" QBITTORRENT_USER)
  qbit_pw=$(env_get "$ENV_FILE" QBITTORRENT_PASSWORD)
  if is_unset QBITTORRENT_USER "$qbit_user" || is_unset QBITTORRENT_PASSWORD "$qbit_pw"; then
    die "QBITTORRENT_USER/QBITTORRENT_PASSWORD in ${ENV_FILE} are still placeholders."
  fi
  check_qbit_password "$qbit_pw"
  check_ports "$(env_get "$ENV_FILE" QBIT_WEBUI_PORT)" "$(env_get "$ENV_FILE" JACKETT_PORT)" \
    "$(env_get "$ENV_FILE" FLARESOLVERR_PORT)" "$(env_get "$ENV_FILE" FILEBROWSER_PORT)"
  prepare_folders
  stop_for_seeding
  seed_configs
  register_stack true
  msg_info "Starting the stack through Compose Manager"
  cm_compose up || die "The stack did not start. See the output above."
  msg_ok "Stack '${STACK}' is up"
  [[ "$DRY_RUN" == 1 ]] || print_access
  echo
}

do_update() {
  load_installed
  check_conflicts
  prepare_source update
  install_source update
  [[ "$DRY_RUN" == 1 ]] || SRC_DIR="$STACK_DIR"
  docker compose -p "$STACK" -f "$STACK_DIR/compose.yaml" --env-file "$ENV_FILE" config -q ||
    die "The updated compose.yaml does not work with your .env (see above). Nothing was restarted."
  # The folders as this version of compose.yaml needs them, before anything
  # is recreated. An install made before FileBrowser kept its database in
  # appdata/filebrowser has that folder writable for its owner only, and the
  # new FileBrowser container (uid 1000, through PGID) would not start.
  prepare_folders
  if vpn_ready_from_env; then
    register_stack true
    msg_info "Pulling new images and recreating containers (Compose Manager 'Update Stack')"
    cm_compose update || die "The update did not finish. See the output above."
    msg_ok "Stack '${STACK}' updated"
  else
    register_stack false
    msg_warn "Files updated; the stack was not started because the VPN keys are not set yet."
  fi
  echo
}

# remove_cm_entry: delete Compose Manager's entry for this stack the way its
# own "Delete Stack" does (it removes the entry folder), but only when the
# entry holds nothing but metadata. It is never removed as a whole when it is
# (or overlaps) the stack folder or a downloads folder, or holds a compose
# file or .env of its own.
remove_cm_entry() {
  [[ -d "$CM_STACK_DIR" ]] || return 0
  if [[ "$(existing_stack_dir)" != "$STACK_DIR" && "$TS_FORCE" != 1 ]]; then
    msg_warn "Left ${CM_STACK_DIR} alone: it does not point at ${STACK_DIR}."
    return 0
  fi
  local f p
  if paths_overlap "$CM_STACK_DIR" "$STACK_DIR"; then
    # Only the metadata files this installer and Compose Manager write; the
    # repository has no files with these names.
    for f in name project_name indirect indirect_mode description webui_url autostart \
      last_result.json started_at running_profiles profiles default_profile envpath icon_url autoupdate.json; do
      [[ -f "$CM_STACK_DIR/$f" ]] && run rm -f "$CM_STACK_DIR/$f"
    done
    msg_warn "Removed only the Compose Manager metadata files from ${CM_STACK_DIR}: that folder is the stack folder, so it stays. Compose Manager may still list it, because its Projects Folder (${CM_ROOT}) holds the stack folder."
    return 0
  fi
  while IFS= read -r p; do
    if paths_overlap "$CM_STACK_DIR" "$p"; then
      msg_warn "Left ${CM_STACK_DIR} alone: it overlaps the downloads folder ${p}. Delete the stack in Compose Manager instead."
      return 0
    fi
  done < <(download_paths_in_env)
  for f in compose.yaml compose.yml docker-compose.yaml docker-compose.yml .env; do
    if [[ -e "$CM_STACK_DIR/$f" ]]; then
      msg_warn "Left ${CM_STACK_DIR} alone: it holds a ${f} of its own, so it is not just this installer's entry."
      return 0
    fi
  done
  run rm -rf "$CM_STACK_DIR"
  msg_ok "Removed the Compose Manager entry ${CM_STACK_DIR}"
}

# check_purge_is_safe: --purge deletes the stack folder. Refuse, before
# anything is stopped or removed, when that could take downloads with it.
check_purge_is_safe() {
  local p
  case "$STACK_DIR" in
    /mnt/*/*/"$STACK") ;;
    *) die "Not purging ${STACK_DIR}: it does not look like <share>/${STACK}. Nothing was changed." ;;
  esac
  while IFS= read -r p; do
    if paths_overlap "$p" "$STACK_DIR"; then
      die "Not purging: the downloads folder ${p} (from ${ENV_FILE}) is inside ${STACK_DIR}, or holds it, so deleting ${STACK_DIR} would delete downloads. Nothing was changed. Move the downloads out first (and change DOWNLOADS_PATH and INCOMPLETE_DOWNLOADS to match), or run --uninstall without --purge."
    fi
  done < <(download_paths_in_env)
  # Without a .env the download paths are unknown; compose.yaml's defaults
  # (./downloads, ./incomplete) would be inside the stack folder.
  if [[ ! -f "$ENV_FILE" ]]; then
    for p in downloads incomplete; do
      [[ -e "$STACK_DIR/$p" ]] && die "Not purging: ${STACK_DIR} has no .env but holds a ${p}/ folder that may hold downloads. Nothing was changed. Move it out, or delete ${STACK_DIR} by hand."
    done
  fi
  return 0
}

do_uninstall() {
  local dir
  dir=$(existing_stack_dir)
  [[ -n "$dir" ]] || dir="${TS_APPDATA:+${TS_APPDATA%/}/${STACK}}"
  [[ -n "$dir" ]] || dir="/mnt/user/appdata/${STACK}"
  set_stack_dir "$dir"
  [[ "$PURGE" == 1 ]] && check_purge_is_safe
  local downloads config
  downloads=$(env_get "$ENV_FILE" DOWNLOADS_PATH)
  config=$(env_get "$ENV_FILE" CONFIG_PATH)
  echo
  echo "  This stops and removes the ${STACK} containers and its Compose Manager entry."
  if [[ "$PURGE" == 1 ]]; then
    echo "  It also ${BOLD}deletes ${STACK_DIR}${CL} (.env, the app settings, the repository files)."
    echo "  Your downloads${downloads:+ (${downloads})} are outside it and are kept."
  else
    echo "  ${STACK_DIR} (.env, app settings) and your downloads are kept."
  fi
  if [[ "$DRY_RUN" != 1 ]]; then
    if [[ "$INTERACTIVE" == 1 ]]; then
      ask_yes_no "Continue?" n || {
        echo "  Nothing was changed."
        exit 0
      }
    elif [[ "$UNATTENDED" != 1 ]]; then
      die "No terminal to confirm on; add --unattended to uninstall without asking."
    fi
  fi
  if [[ -f "$STACK_DIR/compose.yaml" ]]; then
    msg_info "Stopping and removing the containers"
    # In a subshell, so that a Compose Manager entry it cannot use (cm_compose
    # stops with an error then) falls back to plain docker compose.
    if ! { [[ -d "$CM_STACK_DIR" ]] && (cm_compose down); }; then
      local env_args=()
      [[ -f "$ENV_FILE" ]] && env_args=(--env-file "$ENV_FILE")
      run docker compose -p "$STACK" -f "$STACK_DIR/compose.yaml" ${env_args[@]+"${env_args[@]}"} --profile '*' down --remove-orphans ||
        msg_warn "docker compose down failed; remove leftover containers on the Docker tab."
    fi
  fi
  remove_cm_entry
  if [[ "$PURGE" == 1 ]]; then
    run rm -rf "$STACK_DIR"
    msg_ok "Deleted ${STACK_DIR}"
    if [[ -n "$config" && "$config" == /* ]] && ! paths_overlap "$config" "$STACK_DIR"; then
      msg_warn "CONFIG_PATH ${config} is outside ${STACK_DIR} and was kept; delete it by hand if you no longer need it."
    fi
  fi
  msg_ok "Uninstalled. Your downloads${downloads:+ (${downloads})} were not touched."
  echo
}

main() {
  header_info
  [[ "$DRY_RUN" == 1 ]] && msg_warn "Dry run: nothing will be changed."
  check_root
  check_unraid
  check_docker
  check_compose_manager
  check_compose_cli
  [[ "$ACTION" == uninstall ]] || check_tun
  TEMP_DIR=$(mktemp -d /tmp/torrent-stack-unraid.XXXXXX)
  case "$ACTION" in
    install) do_install ;;
    apply) do_apply ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
  esac
}

main
