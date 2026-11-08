#!/usr/bin/env bash
#
# platforms/synology/install.sh
#
# Purpose: run as root over SSH on a Synology NAS with DSM 7.2 or later
# (log in with an administrator account, then `sudo -i`). Installs this
# repository's Docker Compose stack (Gluetun, qBittorrent, Jackett,
# FlareSolverr, FileBrowser) as a Container Manager project:
#
#   * the repository (compose.yaml, .env, update-qbittorrent.sh, scripts)
#     goes to a project folder, by default /volume1/docker/torrent-stack;
#   * .env gets absolute paths, the PUID of the DSM user you choose, PGID 100
#     (the DSM "users" group), your time zone, and the VPN and qBittorrent
#     settings you enter;
#   * qBittorrent (password, Jackett search plugin) and Jackett (API key)
#     are seeded with the repository's own seeding CLI, run by DSM's python3
#     (or a throwaway python container if that fails). FileBrowser makes its
#     own first-run password, which is read from its log and printed;
#   * the folder is registered as the Container Manager project
#     "torrent-stack", so Container Manager > Project shows and manages it;
#   * /dev/net/tun is loaded now, and a Task Scheduler boot-up task
#     ("Torrent stack boot") loads it at every boot and restarts the stack if
#     Container Manager's own boot start left it half up. The task only runs
#     boot.sh while root owns it and no one else can change it.
#
#   Install (wizard):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh)"
#   After editing .env, re-seed and restart:
#     bash /volume1/docker/torrent-stack/platforms/synology/install.sh --apply
#   Update the scripts and the images:
#     bash /volume1/docker/torrent-stack/platforms/synology/install.sh --update
#
# Run with --help for every option and environment variable. --dry-run shows
# every file, command and Container Manager / Task Scheduler request without
# changing anything.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# The msg_info / msg_ok / msg_error output style follows community-scripts/
# ProxmoxVE (https://github.com/community-scripts/ProxmoxVE, MIT), and the
# .env and repository helpers are shared with platforms/unraid/install.sh in
# this repository. The Container Manager (SYNO.Docker.Project) and Task
# Scheduler (SYNO.Core.EventScheduler) requests are the ones DSM's own web UI
# sends, called locally with Synology's synowebapi tool; README.md lists where
# each one is documented. Nothing is downloaded or sourced at run time apart
# from this repository, the Jackett search plugin the seeding CLI fetches,
# and the pinned python image (no pip packages), and this script sends no
# telemetry.

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# The stack name is also the Compose project name and the Container Manager
# project name. It must match `name: torrent-stack` in compose.yaml, so that
# Container Manager (which runs compose with its project name) and plain
# `docker compose` work on the same containers.
readonly STACK="torrent-stack"
REPO_URL="${TS_REPO_URL:-https://github.com/rob-paprocki/qbittorrent-vpn-docker}"
REPO_URL="${REPO_URL%.git}"
readonly REPO_URL
readonly RAW_URL="https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/synology/install.sh"
TS_REF="${TS_REF:-main}"
TS_SOURCE_DIR="${TS_SOURCE_DIR:-}"

# DSM locations. See platforms/synology/README.md (References).
readonly DSM_VERSION_FILE="/etc.defaults/VERSION"
readonly SYNOWEBAPI="/usr/syno/bin/synowebapi"
readonly SYNOPKG="/usr/syno/bin/synopkg"
readonly CM_PACKAGE="ContainerManager"
readonly MIN_DSM="7.2"

# Task Scheduler boot-up task and its log (written by boot.sh). DSM allows
# only English letters, digits and spaces in task names.
readonly BOOT_TASK="Torrent stack boot"
readonly BOOT_LOG="/var/log/torrent-stack-boot.log"

# Throwaway container for the folder write check, and for the seeding CLI
# (scripts/env-editor/seed_configs.py) when DSM's own python3 cannot run it.
# Pinned by tag and by digest (the digest is what docker actually pulls),
# bumped by hand; the same image as Unraid's and CasaOS's. Nothing is
# pip-installed into it: the qBittorrent and Jackett seeders only need
# Python's standard library.
readonly SEED_IMAGE="python:3.14.9-slim-trixie@sha256:35caba83af2fe6da9a5d922f9b0156f21d1246a48278c58a08bd253303ba42e8"
# The seeders to run. The CLI's third one, filebrowser, is left out: the
# current FileBrowser image never reads the file it writes (README.md,
# "FileBrowser"), and it is the only one that needs the bcrypt module.
readonly SEEDERS="jackett,qbit"

# DSM puts every local user in the "users" group (gid 100).
readonly DEFAULT_PGID=100
readonly ENV_EDITOR_PORT=9191
# Apps that share gluetun's network (network_mode: service:gluetun).
readonly APPS_IN_GLUETUN=(qbittorrent jackett flaresolverr)

# The two config seeds tracked in git (copied into CONFIG_PATH when missing).
readonly TRACKED_SEEDS=(
  "jackett/Jackett/ServerConfig.json"
  "qbittorrent/qBittorrent/qBittorrent.conf"
)
# .env keys that hold secrets: never printed in full.
readonly SECRET_KEYS=" WIREGUARD_PRIVATE_KEY OPENVPN_PASSWORD QBITTORRENT_PASSWORD SCRIPT_NOTIFY_URL WATCHTOWER_NOTIFICATION_URL "

# `sudo -i` gives root DSM's full PATH; add the Synology folders in case this
# runs from somewhere with a shorter one.
export PATH="${PATH:-/usr/bin:/bin}:/usr/local/bin:/usr/syno/bin:/usr/syno/sbin"

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
     Gluetun + qBittorrent + Jackett + FlareSolverr  (Synology DSM)

EOF
}

usage() {
  cat <<EOF
One-liner (over SSH, after 'sudo -i'):
  bash -c "\$(curl -fsSL ${RAW_URL})"
  Options go after it as: bash -c "\$(curl -fsSL ...)" install.sh --dry-run

Usage (as root on the NAS):
  install.sh                 Install, or re-run to change the answers. Asks
                             for the DSM user, the project and downloads
                             folders, the VPN and the qBittorrent login.
                             Safe to re-run.
  install.sh --apply         After editing .env by hand: check it, re-seed
                             qBittorrent and Jackett, and start or restart
                             the stack.
  install.sh --update        Update this repository's files (a fresh
                             download copied over them; .env and configs/
                             are kept), then pull new images and recreate
                             the containers.
  install.sh --uninstall     Stop and remove the containers. Keeps the project
                             folder (configs, .env) and your downloads.
  install.sh --uninstall --purge
                             Also remove the Container Manager project and the
                             boot task, and delete the project folder.
                             Downloads are never deleted.
Options:
  --dry-run                  Print every file, command and DSM request,
                             change nothing.
  --unattended, -y           No questions: take answers from TS_* variables,
                             the existing .env, or the defaults.
  --help

Environment variables (all optional; they also pre-fill the questions):
  TS_STACK_DIR=/volume1/docker/torrent-stack   Project folder.
  TS_DOWNLOADS=/volume1/downloads              Downloads folder (incomplete/ is
                             created inside). Must be inside a shared folder,
                             and not inside the project folder (or around it).
  Folder paths may only use letters, digits, . _ - and /.
  TS_USER=<dsm user>         DSM user the apps run as (sets PUID).
  TS_PUID, TS_PGID (100), TS_TZ
  TS_VPN_PROVIDER (protonvpn), TS_VPN_TYPE (wireguard|openvpn),
  TS_WIREGUARD_ADDRESSES, TS_OPENVPN_USER, TS_SERVER_COUNTRIES,
  TS_QBITTORRENT_USER (admin)
  TS_QBIT_WEBUI_PORT, TS_FILEBROWSER_PORT (JACKETT_PORT and FLARESOLVERR_PORT
                             must stay 9117 and 8191: see the README)
  Secrets are read from files, never from the command line:
  TS_WIREGUARD_PRIVATE_KEY_FILE, TS_OPENVPN_PASSWORD_FILE,
  TS_QBITTORRENT_PASSWORD_FILE  (first line of the file; chmod 600 it)
  TS_SCRIPT_NOTIFY_URL_FILE     Discord webhook for port-forward messages
                                (same format; default: none)
  TS_SOURCE_DIR=/path        Copy this local checkout instead of downloading.
  TS_REF=main                Branch or tag to download.  TS_REPO_URL  for a fork.
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
  die "No terminal to ask questions on. Run this in an SSH session, or add --unattended (answers from TS_* variables and defaults)."
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

# version_ge A B: true when dotted version A >= B (numbers only; anything
# after a '-' is ignored, so 24.0.2-1543 compares as 24.0.2).
version_ge() {
  local IFS=. i
  local -a a b
  read -r -a a <<<"${1%%-*}"
  read -r -a b <<<"${2%%-*}"
  for ((i = 0; i < ${#a[@]} || i < ${#b[@]}; i++)); do
    local x="${a[i]:-0}" y="${b[i]:-0}"
    x="${x%%[!0-9]*}" y="${y%%[!0-9]*}"
    ((10#${x:-0} > 10#${y:-0})) && return 0
    ((10#${x:-0} < 10#${y:-0})) && return 1
  done
  return 0
}

is_secret_key() { [[ "$SECRET_KEYS" == *" $1 "* ]]; }

random_password() {
  # 20 letters and digits. head reads a fixed amount, so nothing in the
  # pipeline is cut off early (that would trip pipefail).
  head -c 96 /dev/urandom | base64 | tr -dc 'A-Za-z0-9' | cut -c1-20
}

# files_equal A B: same content. DSM does not always have cmp.
files_equal() {
  [[ -f "$1" && -f "$2" ]] || return 1
  if command -v cmp >/dev/null 2>&1; then
    cmp -s "$1" "$2"
  else
    [[ "$(sha256sum <"$1")" == "$(sha256sum <"$2")" ]]
  fi
}

# read_file VAR PATH: put the file's content into VAR exactly, trailing
# newline included (a plain $(cat) would drop it).
read_file() {
  local __t
  __t=$(
    cat -- "$2"
    printf x
  )
  printf -v "$1" '%s' "${__t%x}"
}

# The NAS's LAN address, for the URLs printed at the end.
host_ip() {
  local ip=""
  ip=$(ip -4 -o route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1) || true
  [[ -n "$ip" ]] || ip=$(hostname -i 2>/dev/null | awk '{print $1}') || true
  echo "${ip:-<nas-ip>}"
}

# ---------------------------------------------------------------------------
# .env reading and writing, in plain bash so secrets never appear in a
# process list. Values are written so that docker compose (and Container
# Manager, which runs it) reads them back exactly as entered.
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
# Also reads DSM's KEY="value" files such as /etc.defaults/VERSION.
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

# ---------------------------------------------------------------------------
# JSON, for DSM's web API. synowebapi takes every parameter as a JSON value
# (a string is "quoted") and answers in JSON, read with jq (part of DSM 7) or
# DSM's python3.
# ---------------------------------------------------------------------------

# json_str TEXT: TEXT as a JSON string.
json_str() {
  local s=$1
  # Control characters other than tab, CR and LF never occur in our values.
  if [[ "$(printf '%s' "$s" | LC_ALL=C tr -cd '\001-\010\013\014\016-\037' | wc -c)" -ne 0 ]]; then
    return 1
  fi
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '"%s"' "$s"
}

JSON_TOOL=""
pick_json_tool() {
  if command -v jq >/dev/null 2>&1; then
    JSON_TOOL=jq
  elif command -v python3 >/dev/null 2>&1; then
    JSON_TOOL=python3
  else
    JSON_TOOL=""
    return 1
  fi
}

# The python3 version of the queries in json_q.
# shellcheck disable=SC2016  # python, not shell
readonly PY_JSON='
import json, sys
query, path = sys.argv[1], sys.argv[2]
with open(path, encoding="utf-8") as fh:
    doc = json.load(fh)
data = doc.get("data") if isinstance(doc, dict) else None
if query == "ok":
    print("true" if isinstance(doc, dict) and doc.get("success") is True else "false")
elif query == "error":
    err = doc.get("error") if isinstance(doc, dict) else None
    print(err.get("code", "") if isinstance(err, dict) else "")
elif query == "projects":
    items = data.values() if isinstance(data, dict) else (data or [])
    for p in items:
        if isinstance(p, dict):
            print("\t".join(str(p.get(k, "")) for k in ("id", "name", "path", "status")))
elif query in ("content", "operation"):
    value = data.get(query, "") if isinstance(data, dict) else ""
    sys.stdout.write(value if isinstance(value, str) else "")
'

# json_q QUERY FILE: one of
#   ok         "true" when the reply says success
#   error      the error code of a failed reply
#   projects   one line per Container Manager project: id, name, path, status
#   content    .data.content (a project's compose file), exactly
#   operation  .data.operation (a Task Scheduler task's command)
json_q() {
  local q=$1 f=$2
  if [[ "$JSON_TOOL" == jq ]]; then
    case "$q" in
      ok) jq -r 'if (type == "object" and .success == true) then "true" else "false" end' "$f" ;;
      error) jq -r '(.error.code // "") | tostring' "$f" ;;
      projects) jq -r '(.data // {}) | (if type == "object" then [.[]] else . end) | .[] | select(type == "object") | [(.id // ""), (.name // ""), (.path // ""), (.status // "")] | map(tostring) | @tsv' "$f" ;;
      content) jq -j '(.data.content // "") | if type == "string" then . else "" end' "$f" ;;
      operation) jq -j '(.data.operation // "") | if type == "string" then . else "" end' "$f" ;;
      *) return 2 ;;
    esac
  else
    python3 -I -c "$PY_JSON" "$q" "$f"
  fi
}

# syno_call OUT API METHOD PARAM...: call DSM's web API locally as root and
# save the JSON reply in OUT. True when the reply says success.
syno_call() {
  local out=$1 api=$2 method=$3
  shift 3
  "$SYNOWEBAPI" --exec "api=${api}" "method=${method}" version=1 "$@" >"$out" 2>"${out}.err" || true
  [[ "$(json_q ok "$out" 2>/dev/null)" == true ]]
}

# syno_reason OUT: a short description of why a call failed.
syno_reason() {
  local code
  code=$(json_q error "$1" 2>/dev/null) || code=""
  if [[ -n "$code" ]]; then
    echo "DSM error code ${code}"
  else
    head -c 200 "$1" "${1}.err" 2>/dev/null | tr '\n' ' '
  fi
}

# print_syno_call API METHOD PARAM...: the request, for --dry-run. A param
# given as NAME@FILE is shown as a summary of FILE instead of its content.
print_syno_call() {
  local api=$1 method=$2 p
  shift 2
  msg_dry "would call: ${SYNOWEBAPI} --exec api=${api} method=${method} version=1"
  for p in "$@"; do
    if [[ "$p" == *@/* && "$p" != *=* ]]; then
      local name="${p%%@*}" file="${p#*@}"
      printf '         %s=<the content of %s as a JSON string, %s bytes, sha256 %s>\n' \
        "$name" "$file" "$(wc -c <"$file" | tr -d ' ')" "$(sha256sum <"$file" | cut -c1-16)"
    else
      printf '         %s\n' "$p"
    fi
  done
}

# ---------------------------------------------------------------------------
# DSM and Container Manager checks
# ---------------------------------------------------------------------------
DSM_VERSION=""
CM_VERSION=""
COMPOSE=()

check_root() {
  [[ "$(id -u)" == 0 ]] || die "Run this as root: log in over SSH with an administrator account, run 'sudo -i', then run the command again."
}

check_dsm() {
  [[ -f "$DSM_VERSION_FILE" ]] || die "This is not a Synology DSM system (no ${DSM_VERSION_FILE}). For other platforms see platforms/ in the repository."
  local major minor product build
  major=$(env_get "$DSM_VERSION_FILE" majorversion)
  minor=$(env_get "$DSM_VERSION_FILE" minorversion)
  product=$(env_get "$DSM_VERSION_FILE" productversion)
  build=$(env_get "$DSM_VERSION_FILE" buildnumber)
  [[ "$major" =~ ^[0-9]+$ && "$minor" =~ ^[0-9]+$ ]] || die "Could not read the DSM version from ${DSM_VERSION_FILE}."
  DSM_VERSION="${product:-${major}.${minor}}"
  version_ge "${major}.${minor}" "$MIN_DSM" ||
    die "DSM ${DSM_VERSION} is too old: Container Manager needs DSM ${MIN_DSM} or later (Control Panel > Update & Restore)."
  msg_ok "DSM ${DSM_VERSION}${build:+ (build ${build})}"
  local arch
  arch=$(uname -m)
  case "$arch" in
    x86_64 | aarch64) ;;
    *) msg_warn "CPU architecture ${arch}: the stack's images are built for x86_64 and arm64 only; some may not run here." ;;
  esac
}

explain_container_manager() {
  cat <<'EOF'

  This installer needs Synology's Container Manager package (Docker for DSM):

    1. Open Package Center in DSM, search for "Container Manager" and click
       Install. It creates the "docker" shared folder.
    2. Run this installer again.

  Container Manager is only offered for models that support it; see
  Synology's "Which Synology NAS models support Container Manager?" article.

EOF
}

# pick_compose: `docker compose` (Container Manager 24.0.2-1543 and later),
# else the standalone docker-compose older versions ship.
pick_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1 && docker-compose version >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    return 1
  fi
}

check_container_manager() {
  local code=0 out
  if [[ -x "$SYNOPKG" ]]; then
    "$SYNOPKG" status "$CM_PACKAGE" >/dev/null 2>&1 || code=$?
    # synopkg status on DSM 7.2: 0 started, 17 stopped, 255 not installed,
    # 150 broken.
    case "$code" in
      0) ;;
      17 | 3) die "Container Manager is installed but stopped. Start it in Package Center (Installed > Container Manager > Run), then run this again." ;;
      150) die "Package Center reports Container Manager as broken. Repair it in Package Center, then run this again." ;;
      *)
        msg_error "Container Manager is not installed."
        explain_container_manager
        exit 1
        ;;
    esac
    out=$("$SYNOPKG" version "$CM_PACKAGE" 2>/dev/null) || out=""
    CM_VERSION="${out%%$'\n'*}"
  fi
  command -v docker >/dev/null 2>&1 || die "The docker command is missing. Is Container Manager installed (Package Center)?"
  docker info >/dev/null 2>&1 || die "Docker is not answering. Check in Package Center that Container Manager is running."
  pick_compose || die "Neither 'docker compose' nor 'docker-compose' works. Update Container Manager in Package Center."
  local cv
  cv=$("${COMPOSE[@]}" version --short 2>/dev/null) || cv=""
  cv="${cv#v}"
  if [[ "$cv" == 1.* ]]; then
    die "Docker Compose ${cv} is too old (this stack needs Compose v2). Update Container Manager in Package Center."
  fi
  msg_ok "Container Manager ${CM_VERSION:-(version unknown)}: Docker $(docker version -f '{{.Server.Version}}' 2>/dev/null || echo '?'), Compose ${cv:-?} (${COMPOSE[*]})"
}

# ---------------------------------------------------------------------------
# Folders. On DSM every shared folder is /volumeN/<name> (USB disks:
# /volumeUSBN/<name>). This installer never creates a shared folder (that is
# done in Control Panel > Shared Folder), only folders inside one.
# ---------------------------------------------------------------------------
STACK_DIR=""   # the project folder: repository checkout, compose.yaml, .env
ENV_FILE=""
SRC_DIR=""     # where the repository files come from this run

set_stack_dir() {
  STACK_DIR="${1%/}"
  ENV_FILE="${STACK_DIR}/.env"
}

# The "docker" shared folder Container Manager creates, on whichever volume.
docker_share() {
  local d
  for d in /volume[0-9]*/docker; do
    [[ -d "$d" ]] && {
      echo "$d"
      return 0
    }
  done
  return 1
}

# share_root PATH: the shared folder PATH is in (/volumeN/<share>).
share_root() {
  local rest=${1#/} vol share
  vol=${rest%%/*}
  rest=${rest#"$vol"}
  rest=${rest#/}
  share=${rest%%/*}
  echo "/${vol}/${share}"
}

# share_path_of PATH: PATH as Container Manager names it, from the shared
# folder down (/volume1/docker/torrent-stack -> /docker/torrent-stack).
share_path_of() {
  local p=${1#/}
  echo "/${p#*/}"
}

# check_dsm_path LABEL PATH [subfolder]: an absolute path inside an existing
# shared folder. With "subfolder", PATH must be below the shared folder.
check_dsm_path() {
  local label=$1 p=$2 need_sub=${3:-}
  [[ "$p" =~ ^/volume(USB)?[0-9]+/[^/]+(/.*)?$ ]] ||
    die "${label} must be a folder inside a shared folder, like /volume1/<shared folder>/..., not '${p}'."
  # The project folder ends up in the command Task Scheduler runs as root at
  # boot, and both folders in .env: plain names keep those safe to run.
  [[ "$p" =~ ^[A-Za-z0-9._/-]+$ ]] ||
    die "${label} '${p}' may only contain letters (a-z, A-Z), digits, '.', '_', '-' and '/' (no spaces, brackets, quotes or other signs). Please pick or rename a folder."
  [[ "$p" != *..* && "$p" != *//* && "$p" != */./* && "$p" != */. ]] ||
    die "${label} '${p}' must be a plain path, without '..', '//' or '/./'."
  local root
  root=$(share_root "$p")
  if [[ -n "$need_sub" && "${p%/}" == "$root" ]]; then
    die "${label} must be a folder inside the shared folder ${root}, for example ${root}/${STACK}."
  fi
  if [[ ! -d "$root" ]]; then
    die "${label}: there is no shared folder '${root##*/}' on ${root%/*}. Create it in Control Panel > Shared Folder (or pick an existing one), then run this again."
  fi
}

# canon PATH: PATH with symlinks resolved as far as it exists (realpath -m
# when DSM has it, else readlink -f), so two spellings of one folder compare
# equal.
canon() {
  local p=""
  p=$(realpath -m -- "$1" 2>/dev/null) || p=""
  [[ -n "$p" ]] || p=$(readlink -f -- "$1" 2>/dev/null) || p=""
  [[ -n "$p" ]] || p="$1"
  [[ "$p" == / ]] || p="${p%/}"
  printf '%s' "$p"
}

# overlap A B: true when A and B are the same folder, or one is inside the
# other. The trailing / keeps /volume1/dl from matching /volume1/dl2.
overlap() {
  local a b
  a="$(canon "$1")/"
  b="$(canon "$2")/"
  [[ "$a" == "$b"* || "$b" == "$a"* ]]
}

# check_folders_apart STACK_DIR CONFIG_PATH DOWNLOAD_FOLDER...: the download
# folders must be apart from the project folder and the configs. Two
# reasons: --purge deletes the project folder, and the downloads folder is
# writable by the apps' user and shown in FileBrowser, while the project
# folder holds .env (the VPN key) and the boot script DSM runs as root.
check_folders_apart() {
  local stack=$1 configs=$2 d
  shift 2
  for d in "$@"; do
    [[ -n "$d" ]] || continue
    if overlap "$stack" "$d"; then
      die "The downloads folder (${d}) and the project folder (${stack}) must be separate: neither may be inside the other. Use for example /volume1/downloads for the downloads."
    fi
    if [[ -n "$configs" ]] && overlap "$configs" "$d"; then
      die "The downloads folder (${d}) and the configs folder (${configs}) must be separate: neither may be inside the other."
    fi
  done
}

# is_this_stack DIR: DIR holds this repository's stack (a compose.yaml that
# names the project torrent-stack, next to the repository's own files), not
# another application's compose project.
is_this_stack() {
  local d=$1
  [[ -f "$d/compose.yaml" && -f "$d/update-qbittorrent.sh" && -f "$d/.env.example" ]] &&
    grep -qx "name: ${STACK}" "$d/compose.yaml"
}

# has_synology_files DIR: DIR also has this installer's scripts (an older
# checkout of the repository does not).
has_synology_files() {
  [[ -f "$1/platforms/synology/install.sh" && -f "$1/platforms/synology/boot.sh" ]]
}

# root_only FILE: owned by root and not writable by its group or others.
# The boot task runs boot.sh as root only when this is true; boot.sh checks
# compose.yaml and .env the same way. Same test as in boot_command.
root_only() {
  case "$(stat -c '%u %A' "$1" 2>/dev/null)" in
    '0 '?????w* | '0 '????????w*) return 1 ;;
    '0 '*) return 0 ;;
    *) return 1 ;;
  esac
}

# group_exists GID / user_exists UID: a local DSM group or user with that id.
group_exists() { awk -F: -v g="$1" '$3 == g { f = 1 } END { exit !f }' /etc/group 2>/dev/null; }
user_exists() { awk -F: -v u="$1" '$3 == u { f = 1 } END { exit !f }' /etc/passwd 2>/dev/null; }

# ---------------------------------------------------------------------------
# Getting the repository
# ---------------------------------------------------------------------------

# Copy SRC into DEST without git metadata, secrets or runtime state. Used for
# TS_SOURCE_DIR and for every download (git clone or tarball). The project
# folder is never a git checkout made by this installer: configs/ holds two
# files git tracks, which the seeding and the apps rewrite, and that would
# make every later `git pull` fail. --update downloads afresh instead.
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
  tar -C "$src" --no-anchored --exclude=__pycache__ --exclude='*.pyc' \
    --anchored --exclude=./.git --exclude=./.env --exclude=./configs \
    --exclude=./downloads --exclude=./incomplete --exclude=./scripts/env-editor/.venv \
    ${ex[@]+"${ex[@]}"} -cf - . | tar -C "$dest" --no-same-owner -xf -
}

# Download the repository into TEMP_DIR/src: git when DSM has it (the Git
# Server package installs it), otherwise a tarball from GitHub with curl.
# Either way only the files are copied into the project folder (copy_tree).
download_source() {
  local dest="$TEMP_DIR/src"
  rm -rf "$dest"
  if command -v git >/dev/null 2>&1; then
    msg_info "Cloning ${REPO_URL} (${TS_REF})"
    git clone -q --depth 1 --branch "$TS_REF" "${REPO_URL}.git" "$dest" ||
      die "git clone of ${REPO_URL} (${TS_REF}) failed."
  else
    local url="${REPO_URL}/archive/${TS_REF}.tar.gz"
    msg_info "Downloading ${url}"
    mkdir -p "$dest"
    curl -fsSL --retry 3 "$url" -o "$TEMP_DIR/src.tar.gz" || die "Download of ${url} failed."
    tar -xzf "$TEMP_DIR/src.tar.gz" -C "$dest" --strip-components=1 --no-same-owner ||
      die "Could not unpack ${url}."
  fi
  [[ -f "$dest/compose.yaml" && -f "$dest/.env.example" && -f "$dest/platforms/synology/boot.sh" ]] ||
    die "The download has no compose.yaml/.env.example/platforms/synology; is TS_REF='${TS_REF}' right?"
  SRC_DIR="$dest"
  msg_ok "Got the repository (${TS_REF})"
}

# prepare_source update|keep: decide where the repository files come from.
# keep: the project folder's own files when it already holds them; update:
# always new files (TS_SOURCE_DIR or a download).
prepare_source() {
  local mode=$1
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    TS_SOURCE_DIR="${TS_SOURCE_DIR%/}"
    [[ -f "$TS_SOURCE_DIR/compose.yaml" && -f "$TS_SOURCE_DIR/platforms/synology/install.sh" ]] ||
      die "TS_SOURCE_DIR '${TS_SOURCE_DIR}' is not a checkout of this repository."
    SRC_DIR="$TS_SOURCE_DIR"
    return 0
  fi
  if [[ "$mode" == keep ]] && is_this_stack "$STACK_DIR" && has_synology_files "$STACK_DIR"; then
    SRC_DIR="$STACK_DIR"
    return 0
  fi
  download_source
}

# install_source: put the repository files into STACK_DIR. .env, .env.bak,
# configs/ and downloads/ there are never touched (copy_tree leaves them out).
install_source() {
  [[ "$SRC_DIR" == "$STACK_DIR" ]] && return 0
  if [[ -d "$STACK_DIR/.git" ]]; then
    msg_warn "${STACK_DIR} is a git checkout. Its files are replaced with the new ones (.env and configs/ are kept), so 'git status' will list them as changed; that is expected. Keep using this installer (--update) to update it, not git pull."
  fi
  msg_info "Copying ${SRC_DIR} to ${STACK_DIR}"
  copy_tree "$SRC_DIR" "$STACK_DIR"
  msg_ok "Repository files are in ${STACK_DIR}"
}

# secure_repo_files: the project folder's scripts and compose.yaml are run as
# root (by Task Scheduler, Container Manager and Docker), so root owns them
# and only root may change them. configs/ belongs to the apps' user instead.
secure_repo_files() {
  local p top=() tree=()
  for p in "$STACK_DIR" "$STACK_DIR/compose.yaml" "$STACK_DIR/update-qbittorrent.sh" "$STACK_DIR/.env.example"; do
    [[ -e "$p" || "$DRY_RUN" == 1 ]] && top+=("$p")
  done
  for p in "$STACK_DIR/platforms" "$STACK_DIR/scripts"; do
    [[ -e "$p" || "$DRY_RUN" == 1 ]] && tree+=("$p")
  done
  if ! { run chown root:root "${top[@]}" && run chmod go-w "${top[@]}" &&
    { ((${#tree[@]} == 0)) || { run chown -R root:root "${tree[@]}" && run chmod -R go-w "${tree[@]}"; }; }; }; then
    msg_warn "Could not make the repository files in ${STACK_DIR} root-only (see above)."
  fi
}

# check_root_only: warn when a file root runs is still changeable by others
# (for example through shared-folder ACLs, which ownership does not cover).
check_root_only() {
  [[ "$DRY_RUN" == 1 ]] && return 0
  local f bad=()
  for f in "$STACK_DIR/platforms/synology/boot.sh" "$STACK_DIR/compose.yaml" "$ENV_FILE" "$STACK_DIR/update-qbittorrent.sh"; do
    [[ -e "$f" ]] && ! root_only "$f" && bad+=("$f")
  done
  ((${#bad[@]} == 0)) && return 0
  msg_warn "These files are not root-only (owned by root, not writable by others): ${bad[*]}"
  echo "  The boot task then only loads tun and does not run boot.sh or restart the"
  echo "  stack. Check: ls -l ${STACK_DIR} ${STACK_DIR}/platforms/synology"
}

# ---------------------------------------------------------------------------
# The wizard
# ---------------------------------------------------------------------------
DSM_USER="" PUID="" PGID="" TZ_VALUE="" DOWNLOADS="" CONFIG_PATH=""
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

# user_of_uid UID: the local DSM user with that id.
user_of_uid() {
  awk -F: -v u="$1" '$3 == u { print $1; exit }' /etc/passwd 2>/dev/null || true
}

detect_tz() {
  # DSM stores its own zone names; /etc/localtime usually points into
  # zoneinfo, which gives the IANA name Docker images expect.
  local tz=""
  if [[ -L /etc/localtime ]]; then
    tz=$(readlink -f /etc/localtime 2>/dev/null) || tz=""
    tz="${tz#*/zoneinfo/}"
    [[ "$tz" == /* ]] && tz=""
  fi
  if [[ -z "$tz" && -f /etc/timezone ]]; then
    tz=$(head -n1 /etc/timezone 2>/dev/null) || tz=""
  fi
  echo "$tz"
}

default_downloads() {
  local v vol d
  v=$(env_get "$ENV_FILE" DOWNLOADS_PATH)
  if [[ "$v" == /volume* ]]; then
    echo "$v"
    return 0
  fi
  vol=$(share_root "$STACK_DIR")
  vol=${vol%/*}
  # A "downloads" share, else TRaSH's /volume1/data/torrents layout.
  for d in "${vol}/downloads" "${vol}/data/torrents"; do
    if [[ -d "$(share_root "$d")" ]]; then
      echo "$d"
      return 0
    fi
  done
  echo "${vol}/downloads"
}

wizard() {
  local tz_default pf vpn_provider vpn_type wg_key wg_addr ovpn_user ovpn_pw countries qbit_user qbit_pw answer
  echo
  echo "  ${BOLD}Folders${CL}"
  ask answer "Project folder (Container Manager's project path)" "$STACK_DIR"
  answer="${answer%/}"
  check_dsm_path "Project folder" "$answer" subfolder
  set_stack_dir "$answer"
  if [[ -f "$STACK_DIR/compose.yaml" ]] && ! is_this_stack "$STACK_DIR"; then
    die "${STACK_DIR} holds another application's compose.yaml (not this stack's). Pick another folder; nothing was changed."
  fi
  if [[ -e "$STACK_DIR" && ! -f "$STACK_DIR/compose.yaml" && -n "$(ls -A "$STACK_DIR" 2>/dev/null)" ]]; then
    die "${STACK_DIR} exists and is not empty, but holds no compose.yaml. Pick another folder or empty it."
  fi

  ask DOWNLOADS "Downloads folder (inside a shared folder, not in the project folder)" "${TS_DOWNLOADS:-$(default_downloads)}"
  DOWNLOADS="${DOWNLOADS%/}"
  check_dsm_path "Downloads folder" "$DOWNLOADS"
  CONFIG_PATH="${STACK_DIR}/configs"
  check_folders_apart "$STACK_DIR" "$CONFIG_PATH" "$DOWNLOADS" "${DOWNLOADS}/incomplete"

  echo
  echo "  ${BOLD}DSM user${CL}: the apps run as this user and own what they download."
  echo "  A dedicated user with Read/Write on the downloads shared folder is best."
  if [[ -n "${TS_PUID:-}" ]]; then
    PUID="$TS_PUID"
    DSM_USER=$(user_of_uid "$PUID")
    [[ -n "$DSM_USER" ]] || msg_warn "There is no local DSM user with uid ${PUID} (TS_PUID). The apps will run as that uid anyway; check it with: id <user>"
  else
    local user_default="${TS_USER:-}" cur
    if [[ -z "$user_default" ]]; then
      cur=$(env_get "$ENV_FILE" PUID)
      [[ -n "$cur" ]] && user_default=$(user_of_uid "$cur")
    fi
    [[ -n "$user_default" ]] || user_default="${SUDO_USER:-}"
    [[ "$user_default" == root ]] && user_default=""
    ask DSM_USER "DSM user name" "$user_default"
    [[ -n "$DSM_USER" ]] || die "Please give a DSM user name (or set TS_USER / TS_PUID)."
    PUID=$(id -u "$DSM_USER" 2>/dev/null) || die "There is no DSM user '${DSM_USER}'. Create one in Control Panel > User & Group, or give an existing one."
  fi
  # PGID: TS_PGID, else the existing .env's when that group exists on this
  # NAS, else 100 (users). An .env copied from .env.example (PGID=1000, the
  # first group on Debian or Ubuntu) has a group DSM users are not in.
  if [[ -n "${TS_PGID:-}" ]]; then
    PGID="$TS_PGID"
    group_exists "$PGID" || msg_warn "There is no group with gid ${PGID} (TS_PGID) on this NAS; DSM's users group is ${DEFAULT_PGID}."
  else
    PGID=$(env_get "$ENV_FILE" PGID)
    if [[ -z "$PGID" ]]; then
      PGID="$DEFAULT_PGID"
    elif [[ "$PGID" != "$DEFAULT_PGID" ]] && ! group_exists "$PGID"; then
      msg_warn "PGID ${PGID} in ${ENV_FILE} is not a group on this NAS; using ${DEFAULT_PGID} (users) instead."
      PGID="$DEFAULT_PGID"
    fi
  fi
  [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ ]] || die "PUID/PGID must be numbers (got ${PUID}/${PGID})."
  [[ "$PUID" != 0 && "$PGID" != 0 ]] || die "PUID/PGID 0 would run qBittorrent and Jackett as root; pick a normal DSM user."

  tz_default=$(current TZ "")
  if [[ -z "${TS_TZ:-}" && (-z "$tz_default" || ! -f "$ENV_FILE") ]]; then
    tz_default=$(detect_tz)
    tz_default="${tz_default:-$(placeholder TZ)}"
  fi
  ask TZ_VALUE "Time zone (IANA name, e.g. Europe/Berlin)" "$tz_default"
  [[ -f "/usr/share/zoneinfo/${TZ_VALUE}" || ! -d /usr/share/zoneinfo ]] ||
    msg_warn "'${TZ_VALUE}' is not a known time zone name; check it (for example Europe/Berlin)."

  echo
  echo "  ${BOLD}VPN${CL} (Gluetun). Leave the keys empty to fill them in later in .env;"
  echo "  the stack does not start until they are set."
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
  echo "  ${BOLD}qBittorrent login${CL} (FileBrowser makes its own admin password; it is shown at the end)."
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
  [[ ${#qbit_pw} -ge 8 ]] || die "The qBittorrent password must be at least 8 characters."
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

  # Paths, ids, time zone. Watchtower stays as it was (off for a new
  # install): see "Updates" in README.md.
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
  check_ports "${SETTINGS[QBIT_WEBUI_PORT]}" "${SETTINGS[JACKETT_PORT]}" "${SETTINGS[FLARESOLVERR_PORT]}"
  if [[ ! -f "$ENV_FILE" ]]; then
    set_setting COMPOSE_PROFILES ""
  fi
}

# check_ports QBIT JACKETT FLARESOLVERR: refuse ports this stack cannot use.
# The repository's compose.yaml publishes each app port as HOST:SAME on the
# gluetun container, but Jackett and FlareSolverr always listen on 9117 and
# 8191 inside it, so any other JACKETT_PORT or FLARESOLVERR_PORT would
# publish a port nothing answers on (and point qBittorrent's search plugin
# at it). qBittorrent shares that network with Jackett, FlareSolverr and
# Gluetun's own control (8000) and health (9999) servers, so its port must
# not be one of those.
check_ports() {
  [[ "$2" == 9117 ]] || die "JACKETT_PORT must be 9117 (got $2): Jackett listens on 9117 inside its container, and this stack publishes the same port number on the host. Set it back to 9117."
  [[ "$3" == 8191 ]] || die "FLARESOLVERR_PORT must be 8191 (got $3): FlareSolverr listens on 8191 inside its container, and this stack publishes the same port number on the host. Set it back to 8191."
  case "$1" in
  8000 | 8191 | 9117 | 9999) die "QBIT_WEBUI_PORT cannot be $1: qBittorrent shares Gluetun's network with Jackett (9117), FlareSolverr (8191) and Gluetun's own servers (8000, 9999). Pick another port, such as 8090." ;;
  esac
  return 0
}

show_summary() {
  echo
  echo "  ${BOLD}Summary${CL}"
  show "Project folder" "$STACK_DIR"
  show "Configs" "$CONFIG_PATH"
  show "Downloads" "$DOWNLOADS (incomplete: ${DOWNLOADS}/incomplete)"
  show "Runs as" "${DSM_USER:-uid ${PUID}} (PUID ${PUID}, PGID ${PGID})"
  show "Time zone" "$TZ_VALUE"
  show "VPN" "${SETTINGS[VPN_PROVIDER]} / ${SETTINGS[VPN_TYPE]} ($([[ "$VPN_READY" == 1 ]] && echo "keys set" || echo "keys not set yet: the stack will not start"))"
  show "qBittorrent user" "${SETTINGS[QBITTORRENT_USER]}"
  show "Container Manager" "project ${STACK} ($(share_path_of "$STACK_DIR"))"
  show "Boot task" "Task Scheduler: ${BOOT_TASK}"
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
  "${COMPOSE[@]}" -p "$STACK" -f "$SRC_DIR/compose.yaml" --env-file "$staged" config -q ||
    die "docker compose rejected the new .env (see above). Nothing was changed."
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would write ${ENV_FILE} (mode 600):"
    print_env_masked "$staged"
    return 0
  fi
  if [[ -f "$ENV_FILE" ]] && files_equal "$staged" "$ENV_FILE"; then
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
  msg_ok "Folders ready (owned by ${PUID}:${PGID})"
}

fix_ownership() {
  local d
  # Gluetun runs as root and keeps its own folder root-owned.
  for d in qbittorrent jackett flaresolverr filebrowser; do
    [[ -d "${CONFIG_PATH}/${d}" || "$DRY_RUN" == 1 ]] && run chown -R "${PUID}:${PGID}" "${CONFIG_PATH}/${d}"
  done
  # Only the two download folders themselves, never what is already in them.
  run chown "${PUID}:${PGID}" "$DOWNLOADS" "${DOWNLOADS}/incomplete"
}

# check_write_access: DSM shared folders carry their own permissions (ACLs)
# on top of file ownership. Try writing as PUID:PGID, exactly as the apps
# will, so a missing shared-folder permission shows up now and not as a
# silent qBittorrent error later. Only warns.
check_write_access() {
  local dirs=("${CONFIG_PATH}/qbittorrent" "$DOWNLOADS" "${DOWNLOADS}/incomplete")
  if [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would check that ${PUID}:${PGID} can write to ${dirs[*]} (throwaway ${SEED_IMAGE%%@*} container, no network)"
    return 0
  fi
  local mounts=() d out
  for d in "${dirs[@]}"; do mounts+=(-v "${d}:${d}"); done
  if ! docker image inspect "$SEED_IMAGE" >/dev/null 2>&1 &&
    ! docker pull -q "$SEED_IMAGE" >"$TEMP_DIR/write-check.err" 2>&1; then
    msg_warn "Could not pull ${SEED_IMAGE%%@*} for the write check: $(tr '\n' ' ' <"$TEMP_DIR/write-check.err")"
    return 0
  fi
  # $@ is expanded by the container's shell. Only the folders that failed
  # are printed on stdout.
  # shellcheck disable=SC2016
  if ! out=$(docker run --rm --network none --user "${PUID}:${PGID}" "${mounts[@]}" --entrypoint /bin/sh "$SEED_IMAGE" \
    -c 'for d in "$@"; do t="$d/.torrent-stack-write-test"; if touch "$t" 2>/dev/null; then rm -f "$t"; else echo "$d"; fi; done' \
    check "${dirs[@]}" 2>"$TEMP_DIR/write-check.err"); then
    msg_warn "Could not run the write check: $(tr '\n' ' ' <"$TEMP_DIR/write-check.err")"
    return 0
  fi
  if [[ -z "$out" ]]; then
    msg_ok "${DSM_USER:-uid ${PUID}} can write to the config and download folders"
    return 0
  fi
  msg_warn "${DSM_USER:-uid ${PUID}} (PUID ${PUID}) cannot write to:"
  local shares=""
  while IFS= read -r d; do
    printf '         %s\n' "$d"
    d=$(share_root "$d")
    [[ " $shares " == *" ${d##*/} "* ]] || shares="${shares:+$shares }${d##*/}"
  done <<<"$out"
  cat <<EOF
  Give that user Read/Write on the shared folder(s): ${shares}
    Control Panel > Shared Folder > select the folder > Edit > Permissions >
    Local users > ${DSM_USER:-the user} > Read/Write > Save.
  Then run: bash ${STACK_DIR}/platforms/synology/install.sh --apply
EOF
}

# stop_for_seeding: qBittorrent writes its settings back when it stops, so a
# running qBittorrent would overwrite a freshly seeded password hash the
# next time it restarts. Stop it first; the compose up that follows starts
# it again.
stop_for_seeding() {
  local running
  running=$(docker ps -q --filter "label=com.docker.compose.project=${STACK}" \
    --filter "label=com.docker.compose.service=qbittorrent" 2>/dev/null) || running=""
  if [[ -n "$running" && -f "$ENV_FILE" ]]; then
    msg_info "Stopping qBittorrent while its config is seeded"
    run compose stop qbittorrent
  fi
}

# seed_configs: run the repository's seeding CLI. It reads .env and writes
# qBittorrent's password hash and Jackett search plugin, and Jackett's API
# key, into CONFIG_PATH. Secrets stay in .env; nothing is passed on a command
# line. DSM 7 comes with python3 (no pip), which is all these two seeders
# need. If it cannot run them, the pinned python image does, with the stack
# folder (.env, the scripts) mounted read-only, only CONFIG_PATH writable,
# and nothing installed into it.
# Either way the CLI reads .env as root, then switches to PUID:PGID
# (--as-user) before it writes anything: the config folders belong to the
# apps, so a compromised app could have planted a symlink there (say
# qBittorrent.conf -> /etc/passwd), and root must never write through it.
seed_configs() {
  local cli="${STACK_DIR}/scripts/env-editor/seed_configs.py"
  if command -v python3 >/dev/null 2>&1; then
    msg_info "Seeding qBittorrent and Jackett (DSM's python3)"
    if run python3 -I "$cli" --env "$ENV_FILE" --only "$SEEDERS" --as-user "${PUID}:${PGID}"; then
      fix_ownership
      msg_ok "Seeded qBittorrent and Jackett"
      return 0
    fi
    msg_warn "DSM's python3 could not run the seeding CLI (see above); trying the throwaway ${SEED_IMAGE%%@*} container."
  fi
  local mounts=(-v "${STACK_DIR}:${STACK_DIR}:ro" -v "${ENV_FILE}:${ENV_FILE}:ro" -v "${CONFIG_PATH}:${CONFIG_PATH}")
  msg_info "Seeding qBittorrent and Jackett (throwaway ${SEED_IMAGE%%@*} container)"
  [[ "$DRY_RUN" == 1 ]] || docker rm -f "${STACK}-seed" >/dev/null 2>&1 || true
  run docker run --rm --name "${STACK}-seed" "${mounts[@]}" --entrypoint python3 "$SEED_IMAGE" \
    -I "$cli" --env "$ENV_FILE" --only "$SEEDERS" --as-user "${PUID}:${PGID}" ||
    die "Seeding failed (see above). It needs internet access for the Jackett search plugin (raw.githubusercontent.com)."
  fix_ownership
  msg_ok "Seeded qBittorrent and Jackett"
}

# ---------------------------------------------------------------------------
# Docker Compose
# ---------------------------------------------------------------------------

# compose ARGS...: docker compose for this stack, with its own files.
compose() {
  "${COMPOSE[@]}" -p "$STACK" -f "${STACK_DIR}/compose.yaml" --env-file "$ENV_FILE" "$@"
}

# container_of SERVICE: id of the stack's container for SERVICE.
container_of() {
  local ids
  ids=$(docker ps -aq --filter "label=com.docker.compose.project=${STACK}" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null) || ids=""
  printf '%s' "${ids%%$'\n'*}"
}

# netns_of ID: the network namespace of a running container.
netns_of() {
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  readlink "/proc/${pid}/ns/net" 2>/dev/null
}

# stale_apps: running apps that are not inside gluetun's current network
# (gluetun was recreated or restarted after they joined it). They have no
# network at all until they are recreated.
stale_apps() {
  local gl ns svc id app_ns outside=()
  gl=$(container_of gluetun)
  [[ -n "$gl" ]] || return 0
  ns=$(netns_of "$gl") || return 0
  for svc in "${APPS_IN_GLUETUN[@]}"; do
    id=$(container_of "$svc")
    [[ -n "$id" ]] || continue
    app_ns=$(netns_of "$id") || continue
    [[ "$app_ns" == "$ns" ]] || outside+=("$svc")
  done
  echo "${outside[*]}"
}

# converge: start or update the stack, then make sure the apps really are
# inside gluetun's network.
converge() {
  msg_info "Starting the stack (Gluetun connects to the VPN first; this can take a minute or two)"
  run compose up -d || return 1
  [[ "$DRY_RUN" == 1 ]] && return 0
  local stale
  stale=$(stale_apps)
  if [[ -n "$stale" ]]; then
    msg_info "Recreating ${stale} inside gluetun's network"
    # shellcheck disable=SC2086  # a list of service names
    run compose up -d --no-deps --force-recreate $stale || return 1
  fi
  return 0
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

# check_conflicts: containers of project torrent-stack started from another
# folder (a manual install elsewhere) would clash on names and ports. The
# label lists the compose files; the first one's folder is the project's.
check_conflicts() {
  local files dirs
  files=$(docker ps -a --filter "label=com.docker.compose.project=${STACK}" \
    --format '{{.Label "com.docker.compose.project.config_files"}}' 2>/dev/null | sed 's/,.*//' | sort -u) || files=""
  [[ -n "$files" ]] || return 0
  dirs=$(while IFS= read -r f; do [[ -n "$f" ]] && dirname "$f"; done <<<"$files" | sort -u)
  if grep -qvxF "$STACK_DIR" <<<"$dirs"; then
    die "Containers of a '${STACK}' project from another folder exist (${dirs//$'\n'/, }). Stop and remove them first, for example in Container Manager > Project > Action > Clean, or: docker compose -p ${STACK} down"
  fi
}

# ---------------------------------------------------------------------------
# Container Manager project
# ---------------------------------------------------------------------------
CM_ID="" CM_PATH="" CM_OTHER=""
CM_REGISTERED=0

# cm_lookup: find the project named torrent-stack (CM_ID, CM_PATH) and any
# other project that uses STACK_DIR (CM_OTHER). False when Container
# Manager's API cannot be used here.
cm_lookup() {
  CM_ID="" CM_PATH="" CM_OTHER=""
  [[ -x "$SYNOWEBAPI" ]] || return 1
  pick_json_tool || return 1
  local out="$TEMP_DIR/cm-list.json" id name path _status
  syno_call "$out" SYNO.Docker.Project list || return 1
  while IFS=$'\t' read -r id name path _status; do
    [[ -n "$id" ]] || continue
    if [[ "$name" == "$STACK" ]]; then
      CM_ID="$id"
      CM_PATH="${path%/}"
    elif [[ -n "$STACK_DIR" && "${path%/}" == "$STACK_DIR" ]]; then
      CM_OTHER="$name"
    fi
  done < <(json_q projects "$out")
  return 0
}

cm_manual_steps() {
  cat <<EOF

  Add the project to Container Manager by hand (once):
    1. Container Manager > Project > Create.
    2. Project name: ${STACK}   (exactly this name: it is the Compose project
       name in compose.yaml; another name would start a second copy).
    3. Path: Set Path > $(share_path_of "$STACK_DIR" | sed 's#^/##; s#/# > #g')
    4. Source: when Container Manager finds the existing compose.yaml, choose
       to use it.
    5. Next, leave the web portal off, Next, Done. (Starting it there is fine:
       it is the same stack this installer runs.)

EOF
}

# cm_after_check BEFORE: Container Manager writes the project's compose file
# itself. If what it wrote differs from ours, put ours back.
cm_after_check() {
  local before=$1
  # Keep the file Container Manager just wrote root-only: boot.sh will not
  # run compose as root on a compose.yaml others can change.
  chown root:root "${STACK_DIR}/compose.yaml" 2>/dev/null || true
  chmod go-w "${STACK_DIR}/compose.yaml" 2>/dev/null || true
  if ! files_equal "${STACK_DIR}/compose.yaml" "$before"; then
    install -m 644 "$before" "${STACK_DIR}/compose.yaml"
    msg_warn "Container Manager rewrote compose.yaml differently; restored the repository's version."
    return 1
  fi
  if [[ -f "${STACK_DIR}/docker-compose.yml" ]] && ! files_equal "${STACK_DIR}/docker-compose.yml" "$before"; then
    msg_warn "Container Manager wrote ${STACK_DIR}/docker-compose.yml with different content; delete it so only compose.yaml is used."
    return 1
  fi
  return 0
}

# cm_register: create the Container Manager project for STACK_DIR, or bring
# its compose content up to date. Re-running does not create a second one.
cm_register() {
  local share_path compose_file="${STACK_DIR}/compose.yaml" content before tmp="$TEMP_DIR/cm"
  # In --dry-run nothing was copied yet: compare with, and show, the file
  # that would be installed.
  if [[ "$DRY_RUN" == 1 && -f "${SRC_DIR}/compose.yaml" ]] && [[ ! -f "$compose_file" || "$SRC_DIR" != "$STACK_DIR" ]]; then
    compose_file="${SRC_DIR}/compose.yaml"
  fi
  share_path=$(share_path_of "$STACK_DIR")
  if ! cm_lookup; then
    if [[ ! -x "$SYNOWEBAPI" ]]; then
      msg_warn "${SYNOWEBAPI} is missing, so the project cannot be added to Container Manager automatically."
    elif [[ -z "$JSON_TOOL" ]]; then
      msg_warn "Neither jq nor python3 is available to read Container Manager's answers."
    else
      msg_warn "Container Manager did not list its projects ($(syno_reason "$TEMP_DIR/cm-list.json"))."
    fi
    cm_manual_steps
    return 0
  fi
  if [[ -n "$CM_OTHER" ]]; then
    die "The Container Manager project '${CM_OTHER}' already uses ${STACK_DIR}. Delete that project entry in Container Manager first (Project > ${CM_OTHER} > Action > Delete; copy configs/ and .env elsewhere before, in case it removes the folder), or pick another folder."
  fi
  if [[ -n "$CM_ID" && "$CM_PATH" != "$STACK_DIR" ]]; then
    die "A Container Manager project named '${STACK}' already exists for ${CM_PATH}. Use that folder (TS_STACK_DIR=${CM_PATH}), or delete that project entry in Container Manager first."
  fi
  read_file content "$compose_file"
  local content_json
  content_json=$(json_str "$content") || die "compose.yaml contains control characters; Container Manager cannot take it."
  if [[ -n "$CM_ID" ]]; then
    if syno_call "$tmp-get.json" SYNO.Docker.Project get "id=$(json_str "$CM_ID")" &&
      json_q content "$tmp-get.json" >"$tmp-content" && files_equal "$tmp-content" "$compose_file"; then
      msg_ok "Container Manager project '${STACK}' is registered and up to date"
      CM_REGISTERED=1
      return 0
    fi
    if [[ "$DRY_RUN" == 1 ]]; then
      print_syno_call SYNO.Docker.Project update "id=$(json_str "$CM_ID")" "content@${compose_file}"
      CM_REGISTERED=1
      return 0
    fi
    before="$tmp-before.yaml"
    cp -p "$compose_file" "$before"
    msg_info "Updating the Container Manager project '${STACK}'"
    if syno_call "$tmp-update.json" SYNO.Docker.Project update "id=$(json_str "$CM_ID")" "content=${content_json}" &&
      cm_after_check "$before"; then
      msg_ok "Container Manager project '${STACK}' updated"
      CM_REGISTERED=1
    else
      cm_after_check "$before" || true
      msg_warn "Container Manager did not take the update ($(syno_reason "$tmp-update.json")). The stack still runs from ${compose_file}."
    fi
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    print_syno_call SYNO.Docker.Project create "name=$(json_str "$STACK")" "share_path=$(json_str "$share_path")" \
      "content@${compose_file}" "enable_service_portal=false"
    CM_REGISTERED=1
    return 0
  fi
  before="$tmp-before.yaml"
  cp -p "$compose_file" "$before"
  msg_info "Adding the project '${STACK}' to Container Manager (${share_path})"
  if syno_call "$tmp-create.json" SYNO.Docker.Project create "name=$(json_str "$STACK")" \
    "share_path=$(json_str "$share_path")" "content=${content_json}" "enable_service_portal=false"; then
    if ! cm_after_check "$before"; then
      cm_manual_steps
      return 0
    fi
    if cm_lookup && [[ -n "$CM_ID" && "$CM_PATH" == "$STACK_DIR" ]]; then
      msg_ok "Container Manager project '${STACK}' added (Container Manager > Project)"
      CM_REGISTERED=1
      return 0
    fi
    msg_warn "Container Manager accepted the project but does not list it at ${STACK_DIR}."
  else
    cm_after_check "$before" || true
    msg_warn "Container Manager did not create the project ($(syno_reason "$tmp-create.json"))."
  fi
  cm_manual_steps
}

# ---------------------------------------------------------------------------
# tun device and the Task Scheduler boot-up task
# ---------------------------------------------------------------------------
BOOT_REGISTERED=0

boot_sh_path() { echo "${STACK_DIR}/platforms/synology/boot.sh"; }

# boot_command: the script the Task Scheduler task runs as root at boot. DSM
# stores it in its own settings (root-only, kept across DSM updates). It
# loads tun itself, so that much works whatever happens to the project
# folder, and it runs boot.sh only while root owns it and no one else can
# change it: anyone who can write to the docker shared folder could
# otherwise put their own script there (after --purge, or by renaming the
# folder) and have it run as root at the next boot. STACK_DIR holds only
# letters, digits and . _ - / (check_dsm_path), so it needs no quoting.
#
# It is one line of plain sh, so it can be pasted into Task Scheduler's
# "User-defined script" box as it is. In words: load tun if /dev/net/tun is
# missing; then look at boot.sh's owner and permissions ("0 -rwxr-xr-x");
# if root owns it and neither the group (6th letter) nor others (9th) may
# write to it, run it; otherwise write one line to the boot log and stop.
boot_command() {
  printf '%s' \
    "[ -c /dev/net/tun ] || insmod /lib/modules/tun.ko; " \
    "f=$(boot_sh_path); " \
    "case \"\$(stat -c '%u %A' \"\$f\" 2>/dev/null)\" in '0 '?????w* | '0 '????????w*) ;; '0 '*) exec /bin/bash \"\$f\" ;; esac; " \
    "echo \"\$(date '+%Y-%m-%d %H:%M:%S') boot task: \$f is missing, not owned by root, or writable by others; only loaded tun\" >>${BOOT_LOG}"
}

# squash TEXT: TEXT with runs of blanks and line breaks as one space, for
# comparing a task's script with ours (one pasted by hand may differ in
# spacing or be split over lines).
squash() { printf '%s' "$1" | tr -s ' \t\n' '   ' | sed 's/^ //; s/ $//'; }

# boot_script: the copy of boot.sh to run now. In --dry-run nothing was
# copied yet, so it is the one that would be installed.
boot_script() {
  local s
  s=$(boot_sh_path)
  if [[ "$DRY_RUN" == 1 && -f "${SRC_DIR}/platforms/synology/boot.sh" ]] && [[ ! -f "$s" || "$SRC_DIR" != "$STACK_DIR" ]]; then
    s="${SRC_DIR}/platforms/synology/boot.sh"
  fi
  echo "$s"
}

# ensure_tun_now: load the tun module right away, with the same code the
# boot task runs.
ensure_tun_now() {
  local args=(--tun-only) script
  [[ "$DRY_RUN" == 1 ]] && args+=(--dry-run)
  script=$(boot_script)
  [[ -f "$script" ]] ||
    die "${script} is missing, so tun cannot be loaded. The project folder's files are incomplete: run 'install.sh --update' (or the installer again)."
  if bash "$script" "${args[@]}" >"$TEMP_DIR/tun.log" 2>&1; then
    if [[ -c /dev/net/tun ]]; then
      msg_ok "/dev/net/tun is available"
    else
      msg_dry "/dev/net/tun is missing; would load the tun module now: $(tr '\n' ' ' <"$TEMP_DIR/tun.log")"
    fi
  else
    sed 's/^/         /' "$TEMP_DIR/tun.log" >&2
    die "/dev/net/tun could not be created. Gluetun cannot run without it."
  fi
}

boot_task_manual_steps() {
  cat <<EOF

  Create the boot task by hand (once):
    1. Control Panel > Task Scheduler > Create > Triggered Task >
       User-defined script.
    2. General: Task: ${BOOT_TASK}   User: root   Event: Boot-up   Enabled: ticked.
    3. Task Settings > Run command > User-defined script: paste this one
       line (between the ----- lines) exactly:
  -----
$(boot_command)
  -----
    4. OK, and confirm DSM's warning about running it as root.

EOF
}

# boot_task_register: the Task Scheduler boot-up task that runs boot.sh as
# root. DSM keeps its tasks across updates, and boot.sh lives on the data
# volume, which DSM updates do not touch.
boot_task_register() {
  local op tmp="$TEMP_DIR/task"
  op=$(boot_command)
  if [[ ! -x "$SYNOWEBAPI" ]] || ! pick_json_tool; then
    msg_warn "The boot task cannot be created automatically here (no ${SYNOWEBAPI}, jq or python3)."
    boot_task_manual_steps
    return 0
  fi
  if syno_call "$tmp-get.json" SYNO.Core.EventScheduler get "task_name=$(json_str "$BOOT_TASK")"; then
    local existing
    existing=$(json_q operation "$tmp-get.json") || existing=""
    if [[ -z "$existing" || "$(squash "$existing")" == "$(squash "$op")" ]]; then
      msg_ok "Task Scheduler boot task '${BOOT_TASK}' is in place"
      BOOT_REGISTERED=1
    else
      msg_warn "The Task Scheduler task '${BOOT_TASK}' runs something else than this installer's boot script:"
      printf '%s\n' "$existing" | sed 's/^/         | /'
      echo "  Replace its script with the one below: Control Panel > Task Scheduler >"
      echo "  select it > Edit > Task Settings > Run command."
      echo "  -----"
      printf '%s\n' "$op"
      echo "  -----"
    fi
    return 0
  fi
  # The parameters DSM's Task Scheduler dialog sends for a triggered
  # user-defined script (see README.md, References).
  local params=(
    "task_name=$(json_str "$BOOT_TASK")"
    'owner={"0":"root"}'
    'event="bootup"'
    'enable=true'
    'depend_on_task=""'
    'notify_enable=false'
    'notify_mail=""'
    'notify_if_error=false'
    'operation_type="script"'
    "operation=$(json_str "$op")"
  )
  if [[ "$DRY_RUN" == 1 ]]; then
    print_syno_call SYNO.Core.EventScheduler create "${params[@]}"
    BOOT_REGISTERED=1
    return 0
  fi
  msg_info "Creating the Task Scheduler boot task '${BOOT_TASK}'"
  if syno_call "$tmp-create.json" SYNO.Core.EventScheduler create "${params[@]}" &&
    syno_call "$tmp-get2.json" SYNO.Core.EventScheduler get "task_name=$(json_str "$BOOT_TASK")"; then
    msg_ok "Task Scheduler boot task '${BOOT_TASK}' created (Control Panel > Task Scheduler)"
    BOOT_REGISTERED=1
    return 0
  fi
  msg_warn "DSM did not create the boot task ($(syno_reason "$tmp-create.json"))."
  boot_task_manual_steps
}

# boot_task_delete: for --purge. Removes the boot task, but only when it
# runs this project folder's boot.sh. (Its guard already refuses a boot.sh
# that someone else put there later; this removes the task as well.)
boot_task_delete() {
  local tmp="$TEMP_DIR/task-del" existing
  local manual="Control Panel > Task Scheduler > select '${BOOT_TASK}' > Action > Delete"
  if [[ ! -x "$SYNOWEBAPI" ]] || ! pick_json_tool; then
    echo "  Delete the Task Scheduler task '${BOOT_TASK}' yourself: ${manual}."
    return 0
  fi
  if ! syno_call "$tmp-get.json" SYNO.Core.EventScheduler get "task_name=$(json_str "$BOOT_TASK")"; then
    echo "  No Task Scheduler task '${BOOT_TASK}' was found. If Task Scheduler still lists it: ${manual}."
    return 0
  fi
  existing=$(json_q operation "$tmp-get.json") || existing=""
  if [[ "$existing" != *"$(boot_sh_path)"* ]]; then
    msg_warn "The Task Scheduler task '${BOOT_TASK}' does not run $(boot_sh_path); left in place."
    return 0
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    print_syno_call SYNO.Core.EventScheduler delete "task_name=$(json_str "$BOOT_TASK")"
    return 0
  fi
  if syno_call "$tmp-delete.json" SYNO.Core.EventScheduler delete "task_name=$(json_str "$BOOT_TASK")"; then
    msg_ok "Removed the Task Scheduler task '${BOOT_TASK}'"
  else
    msg_warn "DSM did not remove the Task Scheduler task '${BOOT_TASK}' ($(syno_reason "$tmp-delete.json")). Delete it yourself: ${manual}."
  fi
}

# ---------------------------------------------------------------------------
# Loading an installed stack (for --apply, --update, --uninstall)
# ---------------------------------------------------------------------------

# guess_stack_dir: TS_STACK_DIR, else the folder of Container Manager's
# torrent-stack project, else <docker shared folder>/torrent-stack.
guess_stack_dir() {
  local share
  if [[ -n "${TS_STACK_DIR:-}" ]]; then
    echo "${TS_STACK_DIR%/}"
    return 0
  fi
  if cm_lookup && [[ -n "$CM_PATH" ]]; then
    echo "$CM_PATH"
    return 0
  fi
  share=$(docker_share) || share="/volume1/docker"
  echo "${share}/${STACK}"
}

load_installed() {
  set_stack_dir "$(guess_stack_dir)"
  [[ -f "$ENV_FILE" && -f "$STACK_DIR/compose.yaml" ]] ||
    die "No installed stack found at ${STACK_DIR} (no compose.yaml/.env). Run the installer without options first, or set TS_STACK_DIR."
  is_this_stack "$STACK_DIR" ||
    die "${STACK_DIR} holds another application's compose.yaml, not this stack's. Check TS_STACK_DIR."
  # The folder goes into the boot task's command (boot_task_register).
  check_dsm_path "Project folder" "$STACK_DIR" subfolder
  SRC_DIR="$STACK_DIR"
  [[ -n "$TS_SOURCE_DIR" ]] && SRC_DIR="${TS_SOURCE_DIR%/}"
  PUID=$(env_get "$ENV_FILE" PUID)
  PGID=$(env_get "$ENV_FILE" PGID)
  DSM_USER=$(user_of_uid "$PUID")
  CONFIG_PATH=$(env_get "$ENV_FILE" CONFIG_PATH)
  DOWNLOADS=$(env_get "$ENV_FILE" DOWNLOADS_PATH)
  local p
  for p in CONFIG_PATH DOWNLOADS; do
    [[ "${!p}" == /* ]] || die "${p/DOWNLOADS/DOWNLOADS_PATH} in ${ENV_FILE} must be an absolute path (got '${!p}')."
  done
  [[ "$PUID" =~ ^[0-9]+$ && "$PGID" =~ ^[0-9]+$ && "$PUID" != 0 && "$PGID" != 0 ]] ||
    die "PUID/PGID in ${ENV_FILE} must be non-zero numbers (the DSM user's id and 100)."
  local inc
  inc=$(env_get "$ENV_FILE" INCOMPLETE_DOWNLOADS)
  [[ -z "$inc" || "$inc" == /* ]] || inc="${STACK_DIR}/${inc#./}"
  [[ "$inc" == "${DOWNLOADS}/incomplete" ]] || msg_warn "INCOMPLETE_DOWNLOADS is '${inc}', not '${DOWNLOADS}/incomplete'; only the latter is created and owned by ${PUID}:${PGID} here."
  check_folders_apart "$STACK_DIR" "$CONFIG_PATH" "$DOWNLOADS" "$inc"
}

# download_folders_of_env: the download folders the project's .env names,
# absolute (relative ones are relative to the project folder, as Compose
# reads them). With no .env, the repository default ./downloads.
download_folders_of_env() {
  local key v
  if [[ ! -f "$ENV_FILE" ]]; then
    echo "${STACK_DIR}/downloads"
    return 0
  fi
  for key in DOWNLOADS_PATH INCOMPLETE_DOWNLOADS; do
    v=$(env_get "$ENV_FILE" "$key")
    [[ -n "$v" ]] || continue
    [[ "$v" == /* ]] || v="${STACK_DIR}/${v#./}"
    echo "$v"
  done
}

# ---------------------------------------------------------------------------
# What to tell the user at the end
# ---------------------------------------------------------------------------
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
  show "qBittorrent login" "$(env_get "$ENV_FILE" QBITTORRENT_USER) / QBITTORRENT_PASSWORD in ${ENV_FILE}"
  if [[ -n "$QBIT_PW_GENERATED" ]]; then
    show "Generated password" "$QBIT_PW_GENERATED"
  fi
  filebrowser_login
}

# filebrowser_password: the first-run admin password FileBrowser printed in
# its log (empty when it has not, or is not running). The current FileBrowser
# image keeps its settings and users in /home/filebrowser/data inside the
# container, not in the configs folder, so it makes this password itself on
# the first start of every new container; the seeding CLI's FileBrowser file
# is never read (README.md, "FileBrowser").
filebrowser_password() {
  local id
  id=$(container_of filebrowser)
  [[ -n "$id" ]] || return 0
  docker logs "$id" 2>&1 |
    sed -n 's/.*[Gg]enerated initial admin password for user "admin"[^:]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' |
    tail -n 1 || true
}

filebrowser_login() {
  local pw="" i
  if [[ "$DRY_RUN" != 1 && -n "$(container_of filebrowser)" ]]; then
    # It logs the password a second or two after it starts.
    for i in 1 2 3 4 5 6 7 8 9 10; do
      pw=$(filebrowser_password)
      [[ -n "$pw" || "$i" == 10 ]] && break
      sleep 2
    done
  fi
  if [[ -n "$pw" ]]; then
    show "FileBrowser login" "admin / ${pw}  (first-run password; FileBrowser asks you to change it)"
  else
    show "FileBrowser login" "admin / the first-run password in its log, once it runs:"
    echo "                         Container Manager > Container > ${STACK}-filebrowser-1 > Details > Log"
    echo "                         (the line 'Generated initial admin password')"
  fi
  echo "  FileBrowser keeps its users inside its container: when the container is"
  echo "  recreated (--update, or Clean and Build in Container Manager) it starts"
  echo "  over with a new first-run password, shown in its log the same way. It can"
  echo "  show your downloads but not change them (see README.md, FileBrowser)."
}

print_manage() {
  echo
  echo "  ${BOLD}Managing it in DSM${CL}"
  if [[ "$CM_REGISTERED" == 1 ]]; then
    echo "  * Container Manager > Project > ${STACK}: containers, logs, Start/Stop."
  else
    echo "  * Container Manager > Container shows the containers; add the project"
    echo "    (steps above) to manage them together under Project."
  fi
  echo "  * Start, stop and restart the whole project (Action menu), never gluetun,"
  echo "    qbittorrent, jackett or flaresolverr one by one: the apps live inside"
  echo "    gluetun's network and lose it when gluetun restarts alone."
  echo "  * Settings live in ${ENV_FILE}."
  echo "    Re-run this installer to change them, or edit .env and run:"
  echo "      bash ${STACK_DIR}/platforms/synology/install.sh --apply"
  echo "  * Updates:"
  echo "      bash ${STACK_DIR}/platforms/synology/install.sh --update"
  if [[ "$BOOT_REGISTERED" == 1 ]]; then
    echo "  * At boot, Task Scheduler's '${BOOT_TASK}' loads tun and restarts the stack"
    echo "    if needed. Its log: ${BOOT_LOG}"
  else
    echo "  * Create the Task Scheduler boot task (steps above), or Gluetun may not"
    echo "    start after a reboot."
  fi
  print_env_editor_hint
}

# The repository's web .env editor (scripts/setup.sh) needs a Python with
# the venv and ensurepip modules, which DSM's built-in python3 does not have.
print_env_editor_hint() {
  if command -v python3 >/dev/null 2>&1 && python3 -c 'import venv, ensurepip' >/dev/null 2>&1; then
    echo "  * Optional: the repository's web .env editor works here (Python with venv found):"
    echo "      bash ${STACK_DIR}/scripts/setup.sh   then open http://$(host_ip):${ENV_EDITOR_PORT}"
  fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
do_install() {
  # First guess for the project folder, so a re-run reads the existing .env.
  set_stack_dir "$(guess_stack_dir)"
  # .env.example (the placeholders) comes from the source we will install.
  prepare_source keep
  wizard
  # The answer may be another folder than the guess: an installed stack there
  # keeps its own files; a new folder, or an older checkout of this
  # repository that lacks platforms/synology (for example one made by
  # following the main README), gets the files of a fresh download. Nothing
  # is written before the summary below.
  if [[ -z "$TS_SOURCE_DIR" ]]; then
    if is_this_stack "$STACK_DIR" && has_synology_files "$STACK_DIR"; then
      SRC_DIR="$STACK_DIR"
    else
      if [[ -f "$STACK_DIR/compose.yaml" ]]; then
        msg_warn "${STACK_DIR} is an older copy of this repository (no platforms/synology). Its repository files will be replaced by a fresh download; .env and configs/ are kept."
      fi
      [[ "$SRC_DIR" == "$TEMP_DIR/src" ]] || download_source
    fi
  fi
  check_conflicts
  # Read-only lookups for the summary; the checks repeat in cm_register.
  cm_lookup || true
  if [[ -n "$CM_OTHER" ]]; then
    die "The Container Manager project '${CM_OTHER}' already uses ${STACK_DIR}. Delete that project entry in Container Manager first, or pick another folder."
  fi
  if [[ -n "$CM_ID" && "$CM_PATH" != "$STACK_DIR" ]]; then
    die "A Container Manager project named '${STACK}' already exists for ${CM_PATH}. Use that folder, or delete that project entry first."
  fi
  show_summary
  if [[ "$INTERACTIVE" == 1 && "$DRY_RUN" != 1 ]]; then
    ask_yes_no "Go ahead?" y || {
      echo "  Nothing was changed."
      exit 0
    }
  fi

  install_source
  # Before anything runs a repository file as root (the seeding CLI next).
  secure_repo_files
  write_env
  prepare_folders
  # From here on the stack's own files are the source.
  [[ "$DRY_RUN" == 1 ]] || SRC_DIR="$STACK_DIR"
  stop_for_seeding
  seed_configs
  check_write_access
  cm_register
  check_root_only
  ensure_tun_now
  boot_task_register

  if [[ "$VPN_READY" == 1 ]]; then
    converge || die "The stack did not start. See the output above, and the gluetun log (Container Manager > Container > ${STACK}-gluetun-1 > Details > Log)."
    msg_ok "Stack '${STACK}' is up"
    [[ "$DRY_RUN" == 1 ]] || print_access
  else
    echo
    msg_warn "Not started: the VPN keys are not set yet."
    echo "  1. Re-run this installer and enter them, or put them in .env yourself"
    echo "     (as root over SSH): vi ${ENV_FILE}"
    echo "  2. After editing .env, run:"
    echo "     bash ${STACK_DIR}/platforms/synology/install.sh --apply"
    [[ "$DRY_RUN" == 1 ]] || print_access
  fi
  print_manage
  echo
}

do_apply() {
  load_installed
  check_conflicts
  compose config -q || die "docker compose rejected ${ENV_FILE} (see above). Fix it, then run --apply again."
  if ! vpn_ready_from_env; then
    die "The VPN keys in ${ENV_FILE} are still the .env.example placeholders. Fill them in, then run --apply again."
  fi
  local qbit_user qbit_pw
  qbit_user=$(env_get "$ENV_FILE" QBITTORRENT_USER)
  qbit_pw=$(env_get "$ENV_FILE" QBITTORRENT_PASSWORD)
  if is_unset QBITTORRENT_USER "$qbit_user" || is_unset QBITTORRENT_PASSWORD "$qbit_pw"; then
    die "QBITTORRENT_USER/QBITTORRENT_PASSWORD in ${ENV_FILE} are still placeholders."
  fi
  check_ports "$(env_get "$ENV_FILE" QBIT_WEBUI_PORT)" "$(env_get "$ENV_FILE" JACKETT_PORT)" "$(env_get "$ENV_FILE" FLARESOLVERR_PORT)"
  # Before anything runs a repository file as root (the seeding CLI next).
  secure_repo_files
  prepare_folders
  stop_for_seeding
  seed_configs
  cm_register
  check_root_only
  ensure_tun_now
  boot_task_register
  converge || die "The stack did not start. See the output above."
  msg_ok "Stack '${STACK}' is up"
  [[ "$DRY_RUN" == 1 ]] || print_access
  print_manage
  echo
}

do_update() {
  load_installed
  check_conflicts
  prepare_source update
  install_source
  secure_repo_files
  run chmod 755 "${STACK_DIR}/update-qbittorrent.sh"
  if [[ "$DRY_RUN" == 1 ]]; then
    # Nothing was copied: check the compose.yaml that would be installed.
    "${COMPOSE[@]}" -p "$STACK" -f "${SRC_DIR}/compose.yaml" --env-file "$ENV_FILE" config -q ||
      die "The new compose.yaml does not work with your .env (see above)."
  else
    SRC_DIR="$STACK_DIR"
    compose config -q || die "The updated compose.yaml does not work with your .env (see above). Nothing was restarted."
  fi
  cm_register
  check_root_only
  boot_task_register
  if vpn_ready_from_env; then
    ensure_tun_now
    msg_info "Pulling new images"
    run compose pull || die "Pulling the images failed (see above). Nothing was restarted."
    converge || die "The update did not finish. See the output above."
    if [[ "$DRY_RUN" == 1 ]]; then
      msg_dry "would update the stack '${STACK}' as shown above"
    else
      msg_ok "Stack '${STACK}' updated"
      filebrowser_login
    fi
  elif [[ "$DRY_RUN" == 1 ]]; then
    msg_dry "would update the files; the stack would not be started, because the VPN keys are not set yet"
  else
    msg_warn "Files updated; the stack was not started because the VPN keys are not set yet."
  fi
  echo
}

do_uninstall() {
  set_stack_dir "$(guess_stack_dir)"
  if [[ -f "$STACK_DIR/compose.yaml" ]] && ! is_this_stack "$STACK_DIR"; then
    die "${STACK_DIR} holds another application's compose.yaml, not this stack's. Nothing was changed; check TS_STACK_DIR."
  fi
  # --purge deletes the project folder, so never while a download folder is
  # inside it (or it is inside one).
  local keep_for="" d downloads=()
  while IFS= read -r d; do
    [[ -n "$d" ]] && downloads+=("$d")
  done < <(download_folders_of_env)
  if [[ "$PURGE" == 1 ]]; then
    for d in ${downloads[@]+"${downloads[@]}"}; do
      if [[ -e "$d" ]] && overlap "$STACK_DIR" "$d"; then
        keep_for="$d"
        break
      fi
    done
  fi
  echo
  echo "  This stops and removes the ${STACK} containers."
  if [[ "$PURGE" == 1 && -z "$keep_for" ]]; then
    echo "  It also removes the Container Manager project and the boot task, and"
    echo "  ${BOLD}deletes ${STACK_DIR}${CL} (configs, .env, qBittorrent state). Downloads are kept."
  elif [[ "$PURGE" == 1 ]]; then
    echo "  ${BOLD}${STACK_DIR} is not deleted${CL}: your downloads folder ${keep_for} is inside it"
    echo "  (or contains it). The Container Manager project and the boot task are kept too."
  else
    echo "  ${STACK_DIR} (configs, .env) and your downloads are kept."
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
    local env_args=()
    [[ -f "$ENV_FILE" ]] && env_args=(--env-file "$ENV_FILE")
    # --profile watchtower also removes the optional Watchtower container.
    run "${COMPOSE[@]}" -p "$STACK" -f "$STACK_DIR/compose.yaml" ${env_args[@]+"${env_args[@]}"} \
      --profile watchtower down --remove-orphans ||
      msg_warn "docker compose down failed; remove leftover containers in Container Manager > Container."
  fi
  cm_lookup || true
  if [[ "$PURGE" == 1 && -n "$keep_for" ]]; then
    msg_warn "Not deleting ${STACK_DIR}: the downloads folder ${keep_for} is inside it (or contains it)."
    echo "  Move your downloads somewhere else first (and point DOWNLOADS_PATH and"
    echo "  INCOMPLETE_DOWNLOADS in .env there), then run --uninstall --purge again."
  elif [[ "$PURGE" == 1 ]]; then
    # Decide before Container Manager deletes anything: only a folder that
    # holds this stack (or no longer exists) is ever deleted.
    local deletable=0
    if [[ ! -e "$STACK_DIR" ]] || is_this_stack "$STACK_DIR"; then deletable=1; fi
    case "$STACK_DIR" in
      /volume*/*/*) ;;
      *) deletable=0 ;;
    esac
    if [[ "$deletable" == 1 && -n "$CM_ID" && "$CM_PATH" == "$STACK_DIR" ]]; then
      if [[ "$DRY_RUN" == 1 ]]; then
        print_syno_call SYNO.Docker.Project delete "id=$(json_str "$CM_ID")" "preserve_content=false"
      elif syno_call "$TEMP_DIR/cm-delete.json" SYNO.Docker.Project delete "id=$(json_str "$CM_ID")" "preserve_content=false"; then
        msg_ok "Removed the Container Manager project '${STACK}'"
      else
        msg_warn "Container Manager did not remove the project ($(syno_reason "$TEMP_DIR/cm-delete.json")); delete it in Container Manager > Project."
      fi
    fi
    if [[ "$deletable" == 1 ]]; then
      run rm -rf "$STACK_DIR"
      msg_ok "Deleted ${STACK_DIR}"
      boot_task_delete
    else
      msg_warn "Not deleting ${STACK_DIR}: it does not hold this stack (no compose.yaml naming ${STACK}), or does not look like /volumeN/<shared folder>/<folder>."
    fi
  elif [[ -n "$CM_ID" ]]; then
    echo
    echo "  Container Manager still lists the project '${STACK}' (without containers)."
    echo "  Re-running the installer uses it again. To remove the entry:"
    echo "  Container Manager > Project > ${STACK} > Action > Delete. It may delete"
    echo "  the project folder's files too, so copy configs/ and .env first."
  fi
  if [[ "$PURGE" != 1 ]]; then
    echo
    echo "  The Task Scheduler task '${BOOT_TASK}' is left in place (with no containers"
    echo "  it only loads tun). To remove it: Control Panel > Task Scheduler > select"
    echo "  it > Action > Delete."
  fi
  echo
  if ((${#downloads[@]})) && [[ -e "${downloads[0]}" ]]; then
    msg_ok "Uninstalled. Your downloads (${downloads[0]}) were not touched."
  else
    msg_ok "Uninstalled. Your downloads were not touched."
  fi
  echo
}

main() {
  header_info
  [[ "$DRY_RUN" == 1 ]] && msg_warn "Dry run: nothing will be changed."
  check_root
  check_dsm
  check_container_manager
  TEMP_DIR=$(mktemp -d /tmp/torrent-stack-synology.XXXXXX)
  case "$ACTION" in
    install) do_install ;;
    apply) do_apply ;;
    update) do_update ;;
    uninstall) do_uninstall ;;
  esac
}

main
