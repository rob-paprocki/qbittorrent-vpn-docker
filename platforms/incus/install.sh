#!/usr/bin/env bash
#
# platforms/incus/install.sh
#
# Purpose: run on a machine with the `incus` command (the Incus host itself,
# or any computer whose incus client is set up for a remote Incus server).
# Creates an unprivileged Debian 13 system container, passes /dev/net/tun
# into it, optionally mounts a downloads folder from the host, copies or
# clones this repository to /opt/torrent-stack inside it and hands off to
# native/install.sh, which installs Gluetun, qBittorrent, Jackett,
# FlareSolverr, FileBrowser and the env-editor as systemd services in that
# one container. The web UIs are reached either through Incus proxy devices
# on the host's own address, or on the container's own LAN address.
#
#   New container (wizard on a terminal, environment variables otherwise):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh)"
#   Update, re-publish ports, remove ("install.sh" is only the name bash
#   gives the script; the arguments follow it):
#     bash -c "$(curl -fsSL .../platforms/incus/install.sh)" install.sh --update torrent-stack
#     bash -c "$(curl -fsSL .../platforms/incus/install.sh)" install.sh --sync-ports torrent-stack
#     bash -c "$(curl -fsSL .../platforms/incus/install.sh)" install.sh --uninstall torrent-stack
#
# Run with --help for every option and environment variable, and see
# platforms/incus/README.md.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# The whiptail Default/Advanced flow and the msg_* helpers follow
# community-scripts/ProxmoxVE (https://github.com/community-scripts/ProxmoxVE,
# Copyright (c) 2021-2026 community-scripts ORG, MIT License), by way of this
# repository's platforms/proxmox/install.sh. The Incus device setup (tun
# unix-char device, proxy devices, idmapped downloads mount) is written for
# this project from the Incus documentation. Nothing is downloaded or
# sourced from community-scripts at run time, and this script sends no
# telemetry.

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# TS_REPO_URL lets a fork install from its own repository.
readonly DEFAULT_REPO_URL="https://github.com/rob-paprocki/qbittorrent-vpn-docker"
REPO_URL="${TS_REPO_URL:-$DEFAULT_REPO_URL}"
readonly RAW_URL="https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/incus/install.sh"
readonly GUEST_DIR="/opt/torrent-stack"
# Initial .env values for native/install.sh, kept in the guest so that
# --resume re-runs the install with the same answers. Not secret.
readonly GUEST_SETTINGS="/root/.torrent-stack-incus.env"
# native/install.sh writes the first-run logins here.
readonly GUEST_CREDS="/root/torrent-stack.creds"
readonly GUEST_DOWNLOADS="/mnt/downloads"
# A static LAN address goes in its own systemd-networkd file. It sorts
# before the image's eth0.network, so networkd uses it instead.
readonly GUEST_NETWORKD="/etc/systemd/network/05-torrent-stack-eth0.network"
readonly ENV_EDITOR_PORT=9191
readonly BACKTITLE="qbittorrent-vpn-docker for Incus"
# Instance config keys this script uses to recognise its own containers
# (user.* keys are free-form in Incus).
readonly KEY_MARK="user.torrent-stack.installer"
readonly MARK_VALUE="platforms/incus"
readonly KEY_MODE="user.torrent-stack.network-mode"
readonly KEY_PADDR="user.torrent-stack.proxy-address"
readonly KEY_POFFSET="user.torrent-stack.proxy-port-offset"
readonly KEY_DLMAP="user.torrent-stack.downloads-mapping"
# How far the install got: "setup" while the container and its devices are
# being set up, "install" once native/install.sh has been handed the
# container, "done" when it finished. --resume can only finish an install
# that got past "setup" (see on_exit and action_resume).
readonly KEY_STAGE="user.torrent-stack.stage"
# Web UIs published by proxy devices: service -> .env key holding its port
# (the env-editor's port is fixed). Device names are proxy-<service>.
readonly PROXY_SERVICES=(env-editor qbittorrent jackett flaresolverr filebrowser)
declare -A PORT_KEY=([env-editor]="" [qbittorrent]=QBIT_WEBUI_PORT [jackett]=JACKETT_PORT
  [flaresolverr]=FLARESOLVERR_PORT [filebrowser]=FILEBROWSER_PORT)
declare -A UI_LABEL=([env-editor]="env-editor (settings)" [qbittorrent]="qBittorrent (VueTorrent)"
  [jackett]="Jackett" [flaresolverr]="FlareSolverr" [filebrowser]="FileBrowser")

TS_REF_SET=0
[[ -n "${TS_REF:-}" ]] && TS_REF_SET=1
TS_REF="${TS_REF:-main}"
TS_SOURCE_DIR="${TS_SOURCE_DIR:-}"

# ---------------------------------------------------------------------------
# Output helpers (community-scripts style: msg_info / msg_ok / msg_error)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
  YW=$'\033[33m' BL=$'\033[36m' RD=$'\033[01;31m' GN=$'\033[1;92m'
  DGN=$'\033[32m' BOLD=$'\033[1m' CL=$'\033[m' BFR=$'\r\033[K'
else
  YW="" BL="" RD="" GN="" DGN="" BOLD="" CL="" BFR=""
fi

msg_info() {
  # On a terminal the line is replaced by the msg_ok/msg_error that follows.
  if [[ -t 1 ]]; then printf '  %s... %s%s' "$YW" "$1" "$CL"; else printf '  ... %s\n' "$1"; fi
}
msg_ok() { printf '%s  [ OK ] %s%s%s\n' "$BFR" "$GN" "$1" "$CL"; }
msg_warn() { printf '%s  [WARN] %s%s%s\n' "$BFR" "$YW" "$1" "$CL"; }
msg_error() { printf '%s  [FAIL] %s%s%s\n' "$BFR" "$RD" "$1" "$CL" >&2; }
show() { printf '  %s%s:%s %s%s%s\n' "$BOLD$DGN" "$1" "$CL" "$BL" "$2" "$CL"; }
die() {
  msg_error "$1"
  exit "${2:-1}"
}

header_info() {
  [[ "$INTERACTIVE" == 1 ]] && clear
  cat <<'EOF'

  _____                         _       ____  _             _
 |_   _|__  _ __ _ __ ___ _ __ | |_    / ___|| |_ __ _  ___| | __
   | |/ _ \| '__| '__/ _ \ '_ \| __|___\___ \| __/ _` |/ __| |/ /
   | | (_) | |  | | |  __/ | | | ||_____|__) | || (_| | (__|   <
   |_|\___/|_|  |_|  \___|_| |_|\__|   |____/ \__\__,_|\___|_|\_\
        Gluetun + qBittorrent + Jackett + FlareSolverr  (Incus)

EOF
}

usage() {
  cat <<EOF
Usage (wherever the incus command can manage the Incus server):
  install.sh                       Create a new container and install the stack.
  install.sh --update [NAME]       Run native/install.sh self-update in an existing
                                   container (new repository version with the live
                                   app configs kept, Debian package upgrades, then
                                   only the changed parts), then re-publish the
                                   web UI ports.
  install.sh --sync-ports [NAME]   Re-publish the web UI ports after changing them
                                   in the env-editor (proxy network mode only).
  install.sh --resume NAME         Re-run the in-container install on a container
                                   this script created (after a failed run).
  install.sh --uninstall [NAME]    Delete the container (asks first; --yes skips
                                   the question). A downloads folder mounted from
                                   the host is never touched.
  install.sh --unattended          No wizard: take settings from TS_* variables.
  install.sh --help
NAME defaults to \$TS_NAME, else torrent-stack. Options and NAME can come in
any order: --uninstall NAME --yes and --uninstall --yes NAME do the same.

Environment variables (all optional; they also pre-fill the wizard):
  TS_SOURCE_DIR=/path   Copy this local checkout into the container instead of
                        cloning from GitHub (used for testing).
  TS_REF=main           Branch or tag to clone (default main).
  TS_REPO_URL           Repository to clone (default: this project on GitHub).
  TS_REMOTE             Incus remote to use (default: the client's default remote).
  TS_PROJECT            Incus project (default: the remote's current project).
  TS_NAME               Container name (default torrent-stack).
  TS_IMAGE              Image (default images:debian/13).
  TS_PROFILE            Profile(s), comma separated (default: default).
  TS_STORAGE            Storage pool for the root disk (default: the profile's).
  TS_DISK_SIZE          Root disk size, e.g. 16GiB (default: the pool's default).
  TS_CPU / TS_MEMORY    CPU limit (2) and memory limit (4GiB).
  TS_NETWORK_MODE       proxy (default): Incus's own bridge plus proxy devices that
                        publish the web UIs on the host's address.
                        lan: attach to a LAN bridge or NIC (macvlan) so the
                        container gets its own address on your network.
  TS_NETWORK            proxy mode: managed bridge to use (default: the profile's,
                        else incusbr0).
  TS_PROXY_ADDRESS      proxy mode: host address to listen on (default 0.0.0.0).
  TS_PROXY_PORT_OFFSET  proxy mode: add this to every host-side port (default 0).
                        Both can be changed later: set them on --sync-ports or
                        --update and the proxy devices move.
  TS_LAN_PARENT         lan mode: host bridge (e.g. br0) or NIC (e.g. enp3s0).
  TS_LAN_NICTYPE        lan mode: auto (default), bridged or macvlan.
  TS_VLAN               lan mode: VLAN ID (optional).
  TS_IP                 lan mode: dhcp (default) or a static a.b.c.d/nn.
  TS_GATEWAY / TS_DNS   lan mode with a static IP: gateway, DNS servers.
  TS_TZ                 Time zone (default: this machine's).
  TS_PUID / TS_PGID     uid/gid the apps run as inside the container (1000).
  TS_DOWNLOADS_HOST_PATH  Folder on the Incus host mounted at ${GUEST_DOWNLOADS}.
  TS_DOWNLOADS_MAPPING  auto (default: idmap, falling back to shift, then none),
                        idmap, shift or none; see platforms/incus/README.md.
  TS_AUTOSTART=1        Start the container when the Incus server starts.
  TS_HOST_WIREGUARD=1   Ask Incus to load the host's wireguard module (0 to skip).
  TS_NESTING=0          Set security.nesting=true (not needed by the stack).
  TS_GUEST_PROXY=url    HTTP(S) proxy for downloads inside the container
                        (without a user name or password).
  TS_UNATTENDED=1       Same as --unattended.   TS_YES=1  same as --yes.
  TS_FORCE=1            Skip the "not created by this script" safety check.
EOF
}

# ---------------------------------------------------------------------------
# Error handling and cleanup
# ---------------------------------------------------------------------------
TEMP_DIR=""
INSTALL_LOG=""
CREATED=0     # set once this run has created the container
UNFINISHED="" # "setup" or "install" while an install is unfinished
KEEP_LOG=0
INTERACTIVE=0
INST=""

# The command that re-runs this script: the local file when it was started
# from one, else the one-liner. Settings that decide where the container is
# and where the source comes from are put in front, so a copied hint works.
SELF_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SELF_PATH=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || true)
fi
rerun_cmd() {
  local p="" r
  r=$(incus remote get-default 2>/dev/null || true)
  [[ -n "$REMOTE" && "$REMOTE" != "$r" ]] && p+="TS_REMOTE=$(printf '%q' "$REMOTE") "
  [[ -n "$PROJECT" ]] && p+="TS_PROJECT=$(printf '%q' "$PROJECT") "
  [[ "$TS_REF_SET" == 1 ]] && p+="TS_REF=$(printf '%q' "$TS_REF") "
  [[ -n "$TS_SOURCE_DIR" ]] && p+="TS_SOURCE_DIR=$(printf '%q' "$TS_SOURCE_DIR") "
  [[ "$REPO_URL" != "$DEFAULT_REPO_URL" ]] && p+="TS_REPO_URL=$(printf '%q' "$REPO_URL") "
  if [[ -n "$SELF_PATH" ]]; then
    printf '%sbash %q' "$p" "$SELF_PATH"
  else
    # shellcheck disable=SC2016  # a literal $(...) for the user to paste
    printf '%sbash -c "$(curl -fsSL %s)" install.sh' "$p" "$RAW_URL"
  fi
}

# On a failed exit while an install is unfinished: say how to retry or
# remove the container (and offer removal in the wizard), and keep the
# install log.
on_exit() {
  local rc=$?
  trap - ERR
  if [[ "$rc" != 0 && -n "$UNFINISHED" ]]; then
    KEEP_LOG=1
    echo
    if [[ "$UNFINISHED" == setup ]]; then
      # Nothing is installed yet, and the same settings would fail again,
      # so a fresh run (with the setting fixed) is the way forward.
      echo "  Container ${NAME} was created, but setting it up failed before anything was"
      echo "  installed in it. Fix the problem above, remove the container and run the"
      echo "  installer again (with the corrected TS_* settings):"
      echo "    incus delete --force $(shown_inst)"
    else
      echo "  Container ${NAME} exists but the install did not finish."
      echo "  Retry the install:  $(rerun_cmd) --resume ${NAME}"
      echo "  Or remove it:       incus delete --force $(shown_inst)"
    fi
    local later="retry with --resume"
    [[ "$UNFINISHED" == setup ]] && later="look at it (incus info --show-log), then remove it yourself"
    if [[ "$INTERACTIVE" == 1 && "$CREATED" == 1 ]] &&
      whiptail --backtitle "$BACKTITLE" --title "INSTALL FAILED" --defaultno --yesno \
        "The install failed. Remove the unfinished container ${NAME} now?\n\nChoose No to keep it and ${later}." 12 70; then
      if inc delete --force "$INST" >/dev/null 2>&1; then
        msg_ok "Removed container ${NAME}"
        KEEP_LOG=0
      fi
    fi
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    # The install log can contain the env-editor's first-run password. Keep
    # it (owner-only) only when the install failed, so it can be read.
    if [[ "$KEEP_LOG" == 1 && -s "$INSTALL_LOG" ]]; then
      local kept="${HOME:-/root}/torrent-stack-${NAME:-unknown}-install.log"
      install -m 600 "$INSTALL_LOG" "$kept" 2>/dev/null && echo "  Install log kept at $kept (readable only by you)."
    fi
    rm -rf "$TEMP_DIR"
  fi
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

exit_script() {
  [[ "$INTERACTIVE" == 1 ]] && clear
  printf '\n  %sUser exited script%s\n\n' "$RD" "$CL"
  exit 0
}

# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------
trim() {
  local s=$1
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

# whiptail with its answer on stdout (it writes the answer to stderr).
wt() { whiptail --backtitle "$BACKTITLE" "$@" 3>&1 1>&2 2>&3; }

# ask TITLE TEXT DEFAULT CHECK ERROR: input box that repeats until CHECK
# accepts the answer. Prints the answer; returns 1 if the user cancels.
ask() {
  local title=$1 text=$2 value=$3 check=$4 err=$5
  while true; do
    value=$(wt --title "$title" --cancel-button Exit-Script --inputbox "$text" 14 78 "$value") || return 1
    value=$(trim "$value")
    if "$check" "$value"; then
      printf '%s' "$value"
      return 0
    fi
    wt --title "$title" --msgbox "$err" 10 76 || true
  done
}

# pick TITLE TEXT DEFAULT ITEM DESCRIPTION...: radio list; prints the choice.
pick() {
  local title=$1 text=$2 default=$3 radio=() n=0
  shift 3
  while (($# >= 2)); do
    radio+=("$1" "$2" "$([[ "$1" == "$default" ]] && echo ON || echo OFF)")
    n=$((n + 1))
    shift 2
  done
  wt --title "$title" --cancel-button Exit-Script --radiolist "$text" 18 78 "$((n < 8 ? n : 8))" "${radio[@]}"
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
in_range() { is_uint "$1" && ((10#$1 >= $2 && 10#$1 <= $3)); }
yes_no() { [[ "$1" == 1 ]] && echo yes || echo no; }

# The incus command, with the chosen project. --project goes first so it can
# never end up after the `--` of an `incus exec`.
PROJ=()
inc() { incus "${PROJ[@]}" "$@"; }

# Run a command in the guest. `incus exec` starts commands with a small,
# fixed environment (PATH, HOME, LANG); nothing from this machine leaks in.
GUEST_ENV=(--env DEBIAN_FRONTEND=noninteractive --env TERM=dumb)
# The host's own proxy variables are deliberately not copied in: a proxy on
# the host's 127.0.0.1 is unreachable from the container. Behind a LAN proxy,
# set TS_GUEST_PROXY=http://proxy:3128 for apt, git and the installer.
# The value goes on the `incus exec` command line, which every user of this
# machine can read in the process list, so a proxy password is refused.
if [[ -n "${TS_GUEST_PROXY:-}" ]]; then
  [[ "$TS_GUEST_PROXY" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]] &&
    die "TS_GUEST_PROXY must not contain a user name or password (it would be visible in this machine's process list). Use a proxy that needs no login from the container, for example by allowing the container's address on the proxy."
  GUEST_ENV+=(--env "http_proxy=${TS_GUEST_PROXY}" --env "https_proxy=${TS_GUEST_PROXY}")
fi
guest() { inc exec "$INST" --force-noninteractive "${GUEST_ENV[@]}" -- "$@"; }
# guest_bash SCRIPT [ARGS...]: run a bash snippet in the guest. ARGS arrive
# as $1, $2, ... so nothing from this machine is pasted into the script text.
guest_bash() {
  local script=$1
  shift
  guest bash -c "$script" bash "$@"
}

# How to name the container in commands printed for the user: plain NAME
# on the default remote, REMOTE:NAME otherwise, plus --project if needed.
shown_inst() {
  local r
  r=$(incus remote get-default 2>/dev/null || true)
  if [[ "$REMOTE" == "$r" ]]; then printf '%s' "$NAME"; else printf '%s' "$INST"; fi
  [[ -n "$PROJECT" ]] && printf ' --project %s' "$PROJECT"
  return 0
}

# yaml_value KEY TEXT: value of the first "  KEY: value" line (incus info).
yaml_value() { sed -n "s/^ *$1: *//p" <<<"$2" | head -n1 | tr -d '"'; }

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------
# Incus instance names: 1-63 letters, digits and dashes; not starting with a
# digit or dash, not ending with a dash (they become the container hostname).
valid_name() { [[ "$1" =~ ^[A-Za-z]([A-Za-z0-9-]{0,61}[A-Za-z0-9])?$ ]]; }
valid_image() { [[ -n "$1" && "$1" =~ ^[A-Za-z0-9._:/-]+$ ]]; }
valid_profiles() { [[ "$1" =~ ^[A-Za-z0-9._-]+([,\ ]+[A-Za-z0-9._-]+)*$ ]]; }
valid_pool_or_empty() { [[ -z "$1" || "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
# limits.cpu: a CPU count, or a list/range of CPUs to pin to (0-3,6).
valid_cpu() { in_range "$1" 1 4096 || [[ "$1" =~ ^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$ && "$1" == *[,-]* ]]; }
valid_memory() { [[ "$1" =~ ^[0-9]+(MiB|GiB|MB|GB)$ || "$1" =~ ^[1-9][0-9]?%$ ]]; }
valid_size_or_empty() { [[ -z "$1" || "$1" =~ ^[0-9]+(MiB|GiB|TiB|MB|GB|TB)$ ]]; }
# 1..65533, as on Proxmox. 0 would run the apps as root.
valid_id() { in_range "$1" 1 65533; }
valid_tz() { [[ "$1" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]]; }
valid_ifname() { [[ "$1" =~ ^[A-Za-z0-9._-]{1,15}$ ]]; }
valid_vlan_or_empty() { [[ -z "$1" ]] || in_range "$1" 1 4094; }

valid_ipv4() {
  local ip=$1 o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}
valid_ipv4_cidr() {
  [[ "$1" == */* ]] || return 1
  valid_ipv4 "${1%/*}" && in_range "${1#*/}" 8 32
}
valid_ip_setting() { [[ "$1" == dhcp ]] || valid_ipv4_cidr "$1"; }
valid_dns_or_empty() {
  local n
  [[ -z "$1" ]] && return 0
  for n in ${1//,/ }; do valid_ipv4 "$n" || return 1; done
}
valid_offset() { in_range "$1" 0 50000; }

# A host folder to mount. Absolute, no '..', and never a system folder: as
# root the script makes the folder belong to the apps' user, so a typo here
# must not be able to hand /usr/bin or /root/.ssh to uid 1000. Whole system
# trees are refused, and so are the common top folders themselves (/mnt,
# /srv, /home, ...): use a folder below them, e.g. /srv/downloads.
valid_host_path_or_empty() {
  local p=$1
  [[ -z "$p" ]] && return 0
  [[ "$p" == /* && "$p" != *"/../"* && "$p" != *"/.." && "$p" != *"/./"* && "$p" != *"/." && "$p" != *" "* && "$p" != *","* ]] || return 1
  while [[ "$p" == */ && "$p" != / ]]; do p="${p%/}"; done
  while [[ "$p" == *//* ]]; do p="${p//\/\//\/}"; done
  case "$p" in
  / | /home | /mnt | /media | /srv | /opt | /tmp | /data) return 1 ;;
  /bin | /bin/* | /boot | /boot/* | /dev | /dev/* | /etc | /etc/* | /proc | /proc/* | /root | /root/* | \
    /run | /run/* | /sbin | /sbin/* | /sys | /sys/* | /usr | /usr/* | /var | /var/* | \
    /lib | /lib/* | /lib32 | /lib32/* | /lib64 | /lib64/* | /libx32 | /libx32/* | /snap | /snap/*) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Settings (environment first; the wizard can change them)
# ---------------------------------------------------------------------------
NAME="${TS_NAME:-torrent-stack}"
IMAGE="${TS_IMAGE:-images:debian/13}"
PROJECT="${TS_PROJECT:-}"
PROFILES="${TS_PROFILE:-default}"
STORAGE="${TS_STORAGE:-}"
DISK_SIZE="${TS_DISK_SIZE:-}"
CPU="${TS_CPU:-2}"
MEMORY="${TS_MEMORY:-4GiB}"
NET_MODE="${TS_NETWORK_MODE:-proxy}"
NETWORK="${TS_NETWORK:-}"
PROXY_ADDR="${TS_PROXY_ADDRESS:-0.0.0.0}"
PORT_OFFSET="${TS_PROXY_PORT_OFFSET:-0}"
LAN_PARENT="${TS_LAN_PARENT:-}"
LAN_NICTYPE="${TS_LAN_NICTYPE:-auto}"
VLAN="${TS_VLAN:-}"
IPV4="${TS_IP:-dhcp}"
GATEWAY="${TS_GATEWAY:-}"
DNS="${TS_DNS:-}"
TZ_NAME="${TS_TZ:-}"
PUID="${TS_PUID:-1000}"
PGID="${TS_PGID:-1000}"
DL_HOST_PATH="${TS_DOWNLOADS_HOST_PATH:-}"
DL_MAPPING="${TS_DOWNLOADS_MAPPING:-auto}"
AUTOSTART="${TS_AUTOSTART:-1}"
HOST_WIREGUARD="${TS_HOST_WIREGUARD:-1}"
NESTING="${TS_NESTING:-0}"
UNATTENDED="${TS_UNATTENDED:-0}"
ASSUME_YES="${TS_YES:-0}"
FORCE="${TS_FORCE:-0}"

REMOTE=""
IS_LOCAL=0     # 1 when the Incus server is this machine (unix socket)
SERVER_HOST="" # how to reach the server from the LAN (for printed URLs)
NIC_DEV="eth0" # instance device name of the container's NIC
NIC_ARGS=()    # its options (network=... or nictype=... parent=...)
NIC_TEXT=""    # human description of the network setup
DL_USED=""     # mapping actually used for the downloads folder

host_timezone() {
  local tz=""
  tz=$(timedatectl show -p Timezone --value 2>/dev/null | tr -d '[:space:]') || true
  [[ -n "$tz" ]] || tz=$(tr -d '[:space:]' </etc/timezone 2>/dev/null) || true
  if [[ -z "$tz" ]]; then
    tz=$(readlink -f /etc/localtime 2>/dev/null || true)
    tz="${tz#/usr/share/zoneinfo/}"
  fi
  valid_tz "$tz" || tz="Etc/UTC"
  echo "$tz"
}

# One profile name per line ("default,vpn" or "default vpn").
profile_list() {
  local p
  for p in ${PROFILES//,/ }; do echo "$p"; done
}

# ---------------------------------------------------------------------------
# Checks: incus client, server, containers, images
# ---------------------------------------------------------------------------
remote_url() {
  # incus remote list prints "name,url,..." with " (current)" after the
  # default remote's name.
  incus remote list --format csv 2>/dev/null |
    awk -F, -v r="$1" '{n = $1; sub(/ \(current\)$/, "", n); if (n == r) {print $2; exit}}'
}

check_incus() {
  command -v incus >/dev/null 2>&1 ||
    die "The incus command was not found. Run this on the Incus host, or on a computer whose incus client is set up for your Incus server."
  REMOTE="${TS_REMOTE:-$(incus remote get-default 2>/dev/null || true)}"
  REMOTE="${REMOTE:-local}"
  local url out
  url=$(remote_url "$REMOTE")
  [[ -n "$url" ]] || die "There is no Incus remote called '${REMOTE}' (see: incus remote list)."
  if [[ "$url" == unix://* ]]; then
    IS_LOCAL=1
  else
    # https://host:8443 -> host, for the printed URLs.
    SERVER_HOST="${url#*://}"
    SERVER_HOST="${SERVER_HOST%%/*}"
    [[ "$SERVER_HOST" == \[* ]] && SERVER_HOST="${SERVER_HOST%%]*}]" || SERVER_HOST="${SERVER_HOST%:*}"
  fi
  if ! out=$(incus info "${REMOTE}:" 2>&1); then
    die "Cannot talk to the Incus server '${REMOTE}': ${out}
  Is the daemon running, and are you allowed to use it (root, or a member of the incus-admin group)?"
  fi
  local driver arch version
  driver=$(yaml_value driver "$out")
  arch=$(yaml_value kernel_architecture "$out")
  version=$(yaml_value server_version "$out")
  [[ "$driver" == *lxc* ]] ||
    die "The Incus server '${REMOTE}' cannot run containers (instance drivers: ${driver:-none}). This stack needs a system container."
  case "$arch" in
  x86_64 | aarch64) ;;
  *) die "The Incus server is ${arch:-unknown}; the stack needs an x86_64 (amd64) or aarch64 (arm64) server." ;;
  esac
  show "Incus server" "${REMOTE} (Incus ${version:-?}, ${arch}$([[ "$IS_LOCAL" == 1 ]] && echo ", this machine"))"
  if [[ -n "$PROJECT" ]]; then
    incus project show "${REMOTE}:${PROJECT}" >/dev/null 2>&1 || die "There is no project '${PROJECT}' on '${REMOTE}' (see: incus project list ${REMOTE}:)."
    PROJ=(--project "$PROJECT")
  fi
}

# Restricted projects (for example the per-user projects of the "incus"
# group) block unix-char, disk and proxy devices by default.
check_project_restrictions() {
  local p="${PROJECT:-}" r
  [[ -n "$p" ]] || p=$(incus project list "${REMOTE}:" --format csv 2>/dev/null | awk -F, '$1 ~ / \(current\)$/ {sub(/ \(current\)$/, "", $1); print $1; exit}')
  [[ -n "$p" ]] || return 0
  r=$(incus project get "${REMOTE}:${p}" restricted 2>/dev/null || true)
  if [[ "$r" == true ]]; then
    msg_warn "Project '${p}' is restricted. It must allow unix-char and proxy devices (plus host-path disk devices for a downloads folder, and unmanaged NICs for lan mode), or setting up the container fails. Low-level options are usually blocked there too: kernel WireGuard (linux.kernel_modules) is then skipped, and raw.idmap for a downloads folder only works within restricted.idmap.uid/gid. See the README."
  fi
}

check_image() {
  [[ "$IMAGE" == *:* ]] || IMAGE="${REMOTE}:${IMAGE}"
  msg_info "Checking that the image ${IMAGE} can be found"
  local out
  if ! out=$(incus image info "$IMAGE" 2>&1); then
    msg_error "Cannot find or reach the image ${IMAGE}"
    die "${out}
  Check this machine's internet access (images: is https://images.linuxcontainers.org), or set TS_IMAGE."
  fi
  if [[ "$(sed -n 's/^Type: *//p' <<<"$out" | head -n1)" == virtual-machine ]]; then
    die "${IMAGE} is a virtual-machine image; this stack needs a container image (for example images:debian/13)."
  fi
  msg_ok "Image ${IMAGE} is available"
}

check_whiptail() {
  if [[ "$UNATTENDED" != 1 && -t 0 && -t 1 ]]; then
    if command -v whiptail >/dev/null 2>&1; then
      INTERACTIVE=1
    else
      msg_warn "whiptail is not installed, so there is no wizard: using TS_* variables and defaults (install whiptail, or newt on some distributions, for the wizard)."
    fi
  fi
}

instance_exists() { inc info "$INST" >/dev/null 2>&1; }
instance_state() { inc info "$INST" 2>/dev/null | sed -n 's/^Status: *//p' | head -n1; }

# ---------------------------------------------------------------------------
# Networking choices
# ---------------------------------------------------------------------------
NETWORK_ROWS=""
load_networks() {
  # name,type,managed,... for every network Incus knows about (managed ones
  # and the host's own interfaces). Incus 6.0 has no --columns here.
  NETWORK_ROWS=$(inc network list "${REMOTE}:" --format csv 2>/dev/null || true)
}
net_field() { awk -F, -v n="$1" -v f="$2" '$1 == n {print $f; exit}' <<<"$NETWORK_ROWS"; }
managed_bridges() { awk -F, '$2 == "bridge" && $3 == "YES" {print $1}' <<<"$NETWORK_ROWS"; }
lan_candidates() {
  # Unmanaged bridges and physical NICs, plus managed macvlan networks.
  awk -F, '($3 == "NO" && ($2 == "bridge" || $2 == "physical" || $2 == "bond" || $2 == "vlan")) || ($3 == "YES" && $2 == "macvlan") {print $1 "," $2}' <<<"$NETWORK_ROWS" |
    grep -vE '^(docker[0-9]*|br-[0-9a-f]{12}|veth[0-9a-f]+|virbr[0-9]+-nic),' || true
}

# The profile NIC to override: the instance gets a device of the same name,
# which replaces the profile's (Incus merges devices by name).
find_profile_nic() {
  local p dev
  NIC_DEV=""
  while read -r p; do
    while read -r dev; do
      [[ -n "$dev" ]] || continue
      if [[ "$(inc profile device get "${REMOTE}:${p}" "$dev" type 2>/dev/null)" == nic ]]; then
        NIC_DEV=$dev
        PROFILE_NIC_NETWORK=$(inc profile device get "${REMOTE}:${p}" "$dev" network 2>/dev/null || true)
      fi
    done < <(inc profile device list "${REMOTE}:${p}" 2>/dev/null)
  done < <(profile_list)
  NIC_DEV="${NIC_DEV:-eth0}"
}
PROFILE_NIC_NETWORK=""

resolve_network() {
  load_networks
  find_profile_nic
  if [[ "$NET_MODE" == proxy ]]; then
    if [[ -z "$NETWORK" ]]; then
      if [[ -n "$PROFILE_NIC_NETWORK" && "$(net_field "$PROFILE_NIC_NETWORK" 2)" == bridge && "$(net_field "$PROFILE_NIC_NETWORK" 3)" == YES ]]; then
        NETWORK=$PROFILE_NIC_NETWORK
      elif grep -qx incusbr0 <<<"$(managed_bridges)"; then
        NETWORK=incusbr0
      else
        NETWORK=$(managed_bridges | head -n1)
      fi
    fi
    [[ -n "$NETWORK" ]] ||
      die "No Incus-managed bridge found for proxy mode. Create one (incus network create incusbr0) or use TS_NETWORK_MODE=lan with TS_LAN_PARENT=<your bridge or NIC>."
    [[ "$(net_field "$NETWORK" 2)" == bridge && "$(net_field "$NETWORK" 3)" == YES ]] ||
      die "'${NETWORK}' is not an Incus-managed bridge (see: incus network list ${REMOTE}:)."
    NIC_ARGS=("network=${NETWORK}")
    NIC_TEXT="Incus bridge ${NETWORK}; web UIs published on ${PROXY_ADDR} (host ports +${PORT_OFFSET})"
    return 0
  fi

  [[ -n "$LAN_PARENT" ]] || die "LAN mode needs TS_LAN_PARENT: a host bridge (e.g. br0) or network card (e.g. enp3s0)."
  valid_ifname "$LAN_PARENT" || die "'${LAN_PARENT}' is not a valid interface name."
  local type managed kind=$LAN_NICTYPE
  type=$(net_field "$LAN_PARENT" 2)
  managed=$(net_field "$LAN_PARENT" 3)
  if [[ "$kind" == auto ]]; then
    if [[ "$managed" == YES ]]; then
      case "$type" in
      macvlan | sriov | physical) kind=network ;;
      bridge) die "'${LAN_PARENT}' is an Incus-managed bridge (Incus's own NAT network, not your LAN). Use TS_NETWORK_MODE=proxy for it, or give the host's LAN bridge or network card." ;;
      *) die "'${LAN_PARENT}' is a managed ${type} network; this script supports managed macvlan, sriov and physical networks." ;;
      esac
    elif [[ "$type" == bridge ]]; then
      kind=bridged
    elif [[ -n "$type" ]]; then
      kind=macvlan
    elif [[ "$IS_LOCAL" == 1 && -e "/sys/class/net/${LAN_PARENT}" ]]; then
      # Not listed by Incus (veth, some virtual NICs) but it exists here.
      if [[ -d "/sys/class/net/${LAN_PARENT}/bridge" ]]; then kind=bridged; else kind=macvlan; fi
    else
      die "The Incus server has no interface called '${LAN_PARENT}' (see: incus network list ${REMOTE}:)."
    fi
  fi
  case "$kind" in
  network)
    [[ -z "$VLAN" ]] || die "TS_VLAN cannot be combined with a managed network; set the VLAN on the network '${LAN_PARENT}' instead."
    NIC_ARGS=("network=${LAN_PARENT}")
    NIC_TEXT="managed network ${LAN_PARENT}"
    ;;
  bridged | macvlan)
    NIC_ARGS=("nictype=${kind}" "parent=${LAN_PARENT}")
    [[ -n "$VLAN" ]] && NIC_ARGS+=("vlan=${VLAN}")
    NIC_TEXT="${kind} on ${LAN_PARENT}${VLAN:+ (VLAN ${VLAN})}"
    ;;
  *) die "TS_LAN_NICTYPE must be auto, bridged or macvlan (got '${kind}')." ;;
  esac
  NIC_TEXT+=", IPv4 ${IPV4}${GATEWAY:+ via ${GATEWAY}}"
}

# ---------------------------------------------------------------------------
# Validate everything before anything is created
# ---------------------------------------------------------------------------
validate_settings() {
  local bad=() p
  INST="${REMOTE}:${NAME}"
  valid_name "$NAME" || bad+=("name '$NAME' (letters, digits and '-', starting with a letter)")
  valid_image "$IMAGE" || bad+=("image '$IMAGE'")
  valid_profiles "$PROFILES" || bad+=("profile(s) '$PROFILES'")
  valid_pool_or_empty "$STORAGE" || bad+=("storage pool '$STORAGE'")
  valid_size_or_empty "$DISK_SIZE" || bad+=("disk size '$DISK_SIZE' (e.g. 16GiB)")
  valid_cpu "$CPU" || bad+=("CPU limit '$CPU' (a count like 2, or CPUs like 0-3)")
  valid_memory "$MEMORY" || bad+=("memory limit '$MEMORY' (e.g. 4GiB or 4096MiB)")
  [[ "$NET_MODE" == proxy || "$NET_MODE" == lan ]] || bad+=("network mode '$NET_MODE' (proxy or lan)")
  valid_ipv4 "$PROXY_ADDR" || bad+=("proxy address '$PROXY_ADDR' (an IPv4 address of the host, or 0.0.0.0)")
  valid_offset "$PORT_OFFSET" || bad+=("proxy port offset '$PORT_OFFSET' (0-50000)")
  valid_vlan_or_empty "$VLAN" || bad+=("VLAN '$VLAN' (1-4094)")
  valid_ip_setting "$IPV4" || bad+=("IPv4 '$IPV4' (dhcp or a.b.c.d/nn)")
  if [[ "$IPV4" != dhcp ]]; then
    [[ "$NET_MODE" == lan ]] || bad+=("a static IPv4 needs TS_NETWORK_MODE=lan (proxy mode uses Incus's DHCP)")
    valid_ipv4 "$GATEWAY" || bad+=("gateway '$GATEWAY' (needed with a static IP)")
  fi
  valid_dns_or_empty "$DNS" || bad+=("DNS '$DNS' (IPv4 addresses)")
  valid_tz "$TZ_NAME" || bad+=("time zone '$TZ_NAME'")
  valid_id "$PUID" || bad+=("PUID '$PUID' (1-65533)")
  valid_id "$PGID" || bad+=("PGID '$PGID' (1-65533)")
  if valid_host_path_or_empty "$DL_HOST_PATH"; then
    resolve_downloads_path || bad+=("downloads folder '$DL_HOST_PATH' (it leads to '${DL_RESOLVED}', which is a system folder)")
  else
    bad+=("downloads folder '$DL_HOST_PATH' (absolute, no spaces or commas, not a system folder, and below a top folder: e.g. /srv/downloads, not /srv)")
  fi
  case "$DL_MAPPING" in auto | shift | idmap | none) ;; *) bad+=("downloads mapping '$DL_MAPPING' (auto, shift, idmap or none)") ;; esac
  [[ "$AUTOSTART" == 0 || "$AUTOSTART" == 1 ]] || bad+=("TS_AUTOSTART '$AUTOSTART' (0 or 1)")
  [[ "$HOST_WIREGUARD" == 0 || "$HOST_WIREGUARD" == 1 ]] || bad+=("TS_HOST_WIREGUARD '$HOST_WIREGUARD' (0 or 1)")
  [[ "$NESTING" == 0 || "$NESTING" == 1 ]] || bad+=("TS_NESTING '$NESTING' (0 or 1)")
  if ((${#bad[@]})); then
    for p in "${bad[@]}"; do msg_error "Invalid setting: $p"; done
    exit 1
  fi
  # Things only the server can answer.
  if instance_exists; then
    if [[ "$(inc config get "$INST" "$KEY_MARK" 2>/dev/null)" == "$MARK_VALUE" &&
      "$(inc config get "$INST" "$KEY_STAGE" 2>/dev/null)" == setup ]]; then
      die "Container '${NAME}' is left over from an install whose setup failed. Remove it first: incus delete --force $(shown_inst)"
    fi
    die "An instance called '${NAME}' already exists${PROJECT:+ in project ${PROJECT}}. Choose another name (TS_NAME), or use --update / --resume ${NAME}."
  fi
  while read -r p; do
    inc profile show "${REMOTE}:${p}" >/dev/null 2>&1 || die "There is no profile '${p}' (see: incus profile list ${REMOTE}:)."
  done < <(profile_list)
  if [[ -n "$STORAGE" ]]; then
    incus storage show "${REMOTE}:${STORAGE}" >/dev/null 2>&1 || die "There is no storage pool '${STORAGE}' (see: incus storage list ${REMOTE}:)."
  elif ! profiles_have_root; then
    die "The profile(s) '${PROFILES}' have no root disk; set TS_STORAGE to a storage pool (see: incus storage list ${REMOTE}:)."
  fi
  resolve_network
  memory_note
}

# On this machine, follow symlinks to the real folder and check that one too
# (chown follows a symlink given on its command line). Without a folder yet,
# the part of the path that exists is resolved. On a remote server the path
# cannot be looked at from here; the syntax check above is all there is.
DL_RESOLVED=""
resolve_downloads_path() {
  [[ -n "$DL_HOST_PATH" && "$IS_LOCAL" == 1 ]] || return 0
  DL_RESOLVED=$(realpath -m -- "$DL_HOST_PATH" 2>/dev/null) || DL_RESOLVED=""
  [[ -n "$DL_RESOLVED" ]] || return 1
  valid_host_path_or_empty "$DL_RESOLVED" || return 1
  if [[ "$DL_RESOLVED" != "${DL_HOST_PATH%/}" ]]; then
    msg_warn "Downloads folder ${DL_HOST_PATH} is really ${DL_RESOLVED}; using that."
    DL_HOST_PATH=$DL_RESOLVED
  fi
}

profiles_have_root() {
  local p
  while read -r p; do
    grep -qE '^ +path: /$' <<<"$(inc profile show "${REMOTE}:${p}" 2>/dev/null || true)" && return 0
  done < <(profile_list)
  return 1
}

memory_note() {
  local mib=0
  case "$MEMORY" in
  *GiB) mib=$((10#${MEMORY%GiB} * 1024)) ;;
  *MiB) mib=$((10#${MEMORY%MiB})) ;;
  *GB) mib=$((10#${MEMORY%GB} * 1000)) ;;
  *MB) mib=$((10#${MEMORY%MB})) ;;
  esac
  if ((mib > 0 && mib < 2048)); then
    msg_warn "Memory limit ${MEMORY} is low: building Gluetun and running FlareSolverr's Chromium want 2GiB or more."
  fi
}

settings_summary() {
  printf 'Name %s%s, image %s\n' "$NAME" "${PROJECT:+ (project $PROJECT)}" "$IMAGE"
  printf 'Profile(s) %s, storage %s%s\n' "$PROFILES" "${STORAGE:-from profile}" "${DISK_SIZE:+, root disk $DISK_SIZE}"
  printf 'CPU %s, memory %s, start with Incus: %s\n' "$CPU" "$MEMORY" "$(yes_no "$AUTOSTART")"
  printf 'Network: %s\n' "$NIC_TEXT"
  printf 'Apps run as %s:%s, time zone %s\n' "$PUID" "$PGID" "$TZ_NAME"
  if [[ -n "$DL_HOST_PATH" ]]; then
    printf 'Downloads: %s on the host (%s mapping)\n' "$DL_HOST_PATH" "$DL_MAPPING"
  else
    printf 'Downloads: on the container disk\n'
  fi
}

show_settings() {
  show "Container" "${NAME}${PROJECT:+ (project ${PROJECT})}, image ${IMAGE}"
  show "Profile(s) / storage" "${PROFILES} / ${STORAGE:-from profile}${DISK_SIZE:+, ${DISK_SIZE}}"
  show "CPU / memory" "${CPU} / ${MEMORY}"
  show "Network" "$NIC_TEXT"
  show "Time zone" "$TZ_NAME"
  show "Apps run as uid/gid" "${PUID}/${PGID}"
  if [[ -n "$DL_HOST_PATH" ]]; then
    show "Downloads" "${DL_HOST_PATH} -> ${GUEST_DOWNLOADS} (${DL_MAPPING} mapping)"
  else
    show "Downloads" "on the container disk (${GUEST_DIR}/downloads)"
  fi
  show "Start with Incus" "$(yes_no "$AUTOSTART")"
}

# ---------------------------------------------------------------------------
# Wizard
# ---------------------------------------------------------------------------
list_first_column() { awk -F, '{n = $1; sub(/ \(current\)$/, "", n); print n}'; }

advanced_settings() {
  local v items=() row n t
  NAME=$(ask "CONTAINER NAME" "Container name (letters, digits and '-'; it is also the hostname)" "$NAME" valid_name "Not a valid name.") || exit_script
  IMAGE=$(ask "IMAGE" "Image to create the container from. Keep the default unless you mirror images yourself." "$IMAGE" valid_image "Enter an image like images:debian/13.") || exit_script

  mapfile -t items < <(incus project list "${REMOTE}:" --format csv 2>/dev/null | list_first_column)
  if ((${#items[@]} > 1)); then
    local args=()
    for n in "${items[@]}"; do args+=("$n" "project"); done
    PROJECT=$(pick "PROJECT" "Incus project for the container" "${PROJECT:-default}" "${args[@]}") || exit_script
    PROJ=(--project "$PROJECT")
  fi

  mapfile -t items < <(inc profile list "${REMOTE}:" --format csv 2>/dev/null | list_first_column)
  PROFILES=$(ask "PROFILES" "Profile(s), comma separated. Found: ${items[*]:-none}" "$PROFILES" valid_profiles "Enter profile names separated by commas.") || exit_script

  mapfile -t items < <(incus storage list "${REMOTE}:" --format csv 2>/dev/null | awk -F, '{print $1 "," $2}')
  if ((${#items[@]} > 1)); then
    local args=("(profile)" "use the profile's root disk")
    for row in "${items[@]}"; do args+=("${row%%,*}" "${row#*,}"); done
    v=$(pick "STORAGE POOL" "Storage pool for the container's root disk" "${STORAGE:-(profile)}" "${args[@]}") || exit_script
    [[ "$v" == "(profile)" ]] && STORAGE="" || STORAGE=$v
  fi
  DISK_SIZE=$(ask "ROOT DISK SIZE" "Root disk size, e.g. 16GiB. Leave empty for the pool's default (some pools, like dir, ignore sizes)." "$DISK_SIZE" valid_size_or_empty "Enter a size like 16GiB, or leave empty.") || exit_script
  CPU=$(ask "CPU LIMIT" "CPU limit: a number of CPUs (2), or the CPUs to pin to (0-3)" "$CPU" valid_cpu "Enter a number like 2, or CPUs like 0-3.") || exit_script
  MEMORY=$(ask "MEMORY LIMIT" "Memory limit (building Gluetun and FlareSolverr's Chromium want 2GiB+; 4GiB is comfortable)" "$MEMORY" valid_memory "Enter a size like 4GiB.") || exit_script

  NET_MODE=$(pick "NETWORK" "How should the web UIs be reached?" "$NET_MODE" \
    proxy "Incus's bridge; UIs on this host's address (proxy devices)" \
    lan "Own address on your LAN (bridge or macvlan)") || exit_script
  load_networks
  if [[ "$NET_MODE" == proxy ]]; then
    mapfile -t items < <(managed_bridges)
    if ((${#items[@]} > 1)); then
      local args=()
      for n in "${items[@]}"; do args+=("$n" "managed bridge"); done
      NETWORK=$(pick "INCUS BRIDGE" "Incus-managed bridge for the container" "${NETWORK:-incusbr0}" "${args[@]}") || exit_script
    fi
    PROXY_ADDR=$(ask "LISTEN ADDRESS" "Host address the web UIs are published on. 0.0.0.0 means every address of the host; enter one of its IPs to limit that." "$PROXY_ADDR" valid_ipv4 "Enter an IPv4 address, or 0.0.0.0.") || exit_script
    PORT_OFFSET=$(ask "PORT OFFSET" "Added to each host-side port, in case the host already uses 8090, 9117, 8191, 8081 or 9191 (e.g. 10000 gives 18090...). 0 keeps the same numbers." "$PORT_OFFSET" valid_offset "Enter 0-50000.") || exit_script
    IPV4=dhcp GATEWAY="" DNS="" VLAN=""
  else
    mapfile -t items < <(lan_candidates)
    if ((${#items[@]})); then
      local args=()
      for row in "${items[@]}"; do
        t=${row#*,}
        case "$t" in bridge) t="bridge: container joins it" ;; macvlan) t="managed macvlan network" ;; *) t="$t NIC: macvlan (host cannot reach it)" ;; esac
        args+=("${row%%,*}" "$t")
      done
      LAN_PARENT=$(pick "LAN INTERFACE" "Host bridge or network card on your LAN. With a bridge the host and container can reach each other; with macvlan on a plain NIC they cannot." "${LAN_PARENT:-${items[0]%%,*}}" "${args[@]}") || exit_script
    else
      LAN_PARENT=$(ask "LAN INTERFACE" "Host bridge (e.g. br0) or network card (e.g. enp3s0) on your LAN" "$LAN_PARENT" valid_ifname "Enter an interface name.") || exit_script
    fi
    VLAN=$(ask "VLAN" "VLAN ID (leave empty for none)" "$VLAN" valid_vlan_or_empty "Enter 1-4094, or leave empty.") || exit_script
    IPV4=$(ask "IPV4 ADDRESS" "'dhcp' (your router assigns it; a DHCP reservation keeps it fixed), or a static address with prefix, e.g. 192.168.1.50/24" "$IPV4" valid_ip_setting "Enter dhcp or an address like 192.168.1.50/24.") || exit_script
    if [[ "$IPV4" != dhcp ]]; then
      GATEWAY=$(ask "GATEWAY" "IPv4 gateway (your router), e.g. 192.168.1.1" "$GATEWAY" valid_ipv4 "Enter an IPv4 address.") || exit_script
      DNS=$(ask "DNS SERVERS" "DNS servers, separated by spaces or commas (leave empty to use the gateway)" "$DNS" valid_dns_or_empty "Enter IPv4 addresses separated by spaces or commas.") || exit_script
    else
      GATEWAY="" DNS=""
    fi
  fi

  TZ_NAME=$(ask "TIME ZONE" "Time zone, e.g. Europe/Berlin" "$TZ_NAME" valid_tz "Enter a time zone like America/New_York.") || exit_script
  PUID=$(ask "PUID" "User ID the apps run as inside the container (owner of downloaded files)" "$PUID" valid_id "Enter 1-65533.") || exit_script
  PGID=$(ask "PGID" "Group ID the apps run as inside the container" "$PGID" valid_id "Enter 1-65533.") || exit_script
  DL_HOST_PATH=$(ask "DOWNLOADS FOLDER" "Optional: a folder on the Incus host to keep downloads in, mounted at ${GUEST_DOWNLOADS} in the container (e.g. /tank/downloads or /srv/downloads). Leave empty to keep downloads on the container disk." "$DL_HOST_PATH" valid_host_path_or_empty "Enter an absolute path below a top folder (e.g. /srv/downloads, not /srv), not a system folder, with no spaces or commas; or leave empty.") || exit_script
  if [[ -n "$DL_HOST_PATH" ]]; then
    DL_MAPPING=$(pick "DOWNLOADS OWNERSHIP" "Files in ${DL_HOST_PATH} should belong to ${PUID}:${PGID} on the host, as in the container. How?" "$DL_MAPPING" \
      auto "idmap, falling back to shift, then none (recommended)" \
      idmap "raw.idmap maps only ${PUID}:${PGID} straight through" \
      shift "idmapped mount (shift=true); container root = host root there" \
      none "no mapping: host folder owned by the shifted uid") || exit_script
  fi
  if wt --title "START WITH INCUS" --yesno "Start the container whenever the Incus server starts (boot.autostart)?" 8 70; then AUTOSTART=1; else AUTOSTART=0; fi
}

choose_settings() {
  [[ -n "$TZ_NAME" ]] || TZ_NAME=$(host_timezone)
  if [[ "$INTERACTIVE" != 1 ]]; then
    validate_settings
    return
  fi
  wt --title "TORRENT STACK (INCUS)" --yesno "This creates a new Debian 13 container on '${REMOTE}' running Gluetun (VPN), qBittorrent, Jackett, FlareSolverr, FileBrowser and the env-editor. Proceed?" 11 72 || exit_script
  if wt --title "SETTINGS" --yes-button Default --no-button Advanced --yesno \
    "Use default settings?\n\nDefault: container '${NAME}', ${CPU} CPUs, ${MEMORY}, Incus's bridge with the web UIs on this host's address, downloads on the container disk." 13 72; then
    header_info
    echo "  ${BOLD}Using default settings${CL}"
    validate_settings
    return
  fi
  while true; do
    header_info
    echo "  ${BOLD}Using advanced settings${CL}"
    advanced_settings
    validate_settings
    wt --title "SETTINGS" --yes-button Create --no-button Do-Over --yesno \
      "Create the container with these settings?\n\n$(settings_summary)" 18 78 && break
  done
}

# ---------------------------------------------------------------------------
# Create and start the container
# ---------------------------------------------------------------------------
create_instance() {
  local args=(init "$IMAGE" "$INST" --quiet) p
  while read -r p; do args+=(--profile "$p"); done < <(profile_list)
  [[ -n "$STORAGE" ]] && args+=(--storage "$STORAGE")
  [[ -n "$DISK_SIZE" ]] && args+=(--device "root,size=${DISK_SIZE}")
  args+=(
    --config "limits.cpu=${CPU}"
    --config "limits.memory=${MEMORY}"
    --config "boot.autostart=$([[ "$AUTOSTART" == 1 ]] && echo true || echo false)"
    --config "${KEY_MARK}=${MARK_VALUE}"
    --config "${KEY_MODE}=${NET_MODE}"
    --config "${KEY_STAGE}=setup"
  )
  if [[ "$NET_MODE" == proxy ]]; then
    args+=(--config "${KEY_PADDR}=${PROXY_ADDR}" --config "${KEY_POFFSET}=${PORT_OFFSET}")
  fi
  # Not needed by the stack (see the README); only on request.
  [[ "$NESTING" == 1 ]] && args+=(--config security.nesting=true)
  msg_info "Creating container ${NAME} from ${IMAGE}"
  local out
  if ! out=$(inc "${args[@]}" 2>&1); then
    msg_error "Could not create the container"
    die "$out"
  fi
  CREATED=1
  UNFINISHED=setup
  msg_ok "Created container ${NAME}"

  # The stack's security model assumes an unprivileged container: root in
  # the container is an ordinary high uid on the host.
  if [[ "$(inc config get "$INST" security.privileged --expanded 2>/dev/null)" == true ]]; then
    die "A profile makes this container privileged (security.privileged=true). Use a profile without it; the stack must run unprivileged."
  fi

  msg_info "Adding the network device"
  inc config device add "$INST" "$NIC_DEV" nic "${NIC_ARGS[@]}" name=eth0 >/dev/null
  msg_ok "Network: ${NIC_TEXT}"

  # Gluetun opens /dev/net/tun to create the VPN interface. A container
  # cannot create device nodes itself, so Incus passes the host's in. Incus
  # makes it root-owned with mode 0660 in the container, which is enough:
  # Gluetun runs as root.
  msg_info "Passing /dev/net/tun into the container"
  inc config device add "$INST" tun unix-char source=/dev/net/tun path=/dev/net/tun >/dev/null
  msg_ok "Passed /dev/net/tun into the container"

  # Gluetun uses kernel WireGuard when the host has the module loaded, and
  # slower userspace WireGuard otherwise. The container cannot load modules,
  # but Incus loads the ones in linux.kernel_modules before each start. A
  # restricted project forbids this low-level key; that is not fatal.
  if [[ "$HOST_WIREGUARD" == 1 ]] && ! out=$(inc config set "$INST" linux.kernel_modules=wireguard 2>&1); then
    msg_warn "Could not ask Incus to load the wireguard module (${out#Error: }), so Gluetun will use userspace WireGuard (slower) unless the module is already loaded on the host."
  fi

  [[ "$IPV4" != dhcp ]] && write_static_ip
  # The initial settings go in before the first boot, so they are in place
  # whatever happens later (--resume reads them).
  push_settings
  return 0
}

# Static LAN address: a systemd-networkd file pushed before the first boot.
write_static_ip() {
  local f="$TEMP_DIR/static.network" d
  if ! inc file pull "$INST/etc/systemd/network/eth0.network" "$TEMP_DIR/eth0.network" >/dev/null 2>&1; then
    die "The image ${IMAGE} does not configure eth0 with systemd-networkd, so this script cannot set a static IP in it. Use DHCP (a reservation on your router keeps the address fixed)."
  fi
  {
    echo "# Written by qbittorrent-vpn-docker platforms/incus/install.sh: static LAN"
    echo "# address. Delete this file to go back to DHCP (eth0.network)."
    echo "[Match]"
    echo "Name=eth0"
    echo
    echo "[Network]"
    echo "Address=${IPV4}"
    echo "Gateway=${GATEWAY}"
    # Spaces or commas between servers, as valid_dns_or_empty accepts.
    for d in ${DNS//,/ }; do echo "DNS=${d}"; done
    [[ -n "${DNS//[ ,]/}" ]] || echo "DNS=${GATEWAY}"
  } >"$f"
  inc file push --uid 0 --gid 0 --mode 0644 "$f" "${INST}${GUEST_NETWORKD}" >/dev/null
  msg_ok "Static IPv4 ${IPV4} via ${GATEWAY} written to ${GUEST_NETWORKD}"
}

# Each fallback below changes the container so that its condition cannot
# come up again, so the loop ends after at most three attempts.
start_instance() {
  local out dev
  msg_info "Starting container ${NAME}"
  while true; do
    if out=$(inc start "$INST" 2>&1); then
      msg_ok "Started container ${NAME}"
      return 0
    fi
    if [[ "$out" == *"kernel module"* && -n "$(inc config get "$INST" linux.kernel_modules 2>/dev/null)" ]]; then
      msg_warn "The server could not load the wireguard kernel module, so Gluetun will use userspace WireGuard (slower). Incus said: ${out%%$'\n'*}"
      inc config unset "$INST" linux.kernel_modules
      continue
    fi
    # A proxy device whose host port is taken (by another program, or a
    # second copy of the stack) stops the whole container from starting.
    # The proxy devices are only host-side forwarding, so drop them, start,
    # and let sync_proxies add them back: it reports a busy port instead.
    # (Every caller of start_instance on an existing container runs
    # sync_proxies afterwards in proxy mode.)
    # ([[ -n $(...) ]], not `proxy_devices | grep -q`: under pipefail an
    # early-exiting grep can make that pipeline fail.)
    if [[ "$out" == *"starting proxy device"* && -n "$(proxy_devices)" ]]; then
      msg_warn "A host port of the web UIs is in use, so Incus could not start the container. Incus said: ${out%%$'\n'*}"
      msg_warn "Removing the proxy devices to start it; they are added back afterwards, except the busy one."
      while read -r dev; do
        inc config device remove "$INST" "$dev" >/dev/null
      done < <(proxy_devices)
      continue
    fi
    break
  done
  msg_error "Could not start container ${NAME}"
  die "${out}
  More detail: incus info --show-log $(shown_inst)"
}

# Names of this container's own proxy devices (not ones from profiles).
proxy_devices() {
  local svc
  for svc in "${PROXY_SERVICES[@]}"; do
    [[ -n "$(inc config device get "$INST" "proxy-${svc}" listen 2>/dev/null || true)" ]] && echo "proxy-${svc}"
  done
  return 0
}

ensure_running() {
  [[ "$(instance_state)" == RUNNING ]] || start_instance
}

# Wait until systemd is up and the container has an address, a default
# route and working DNS (apt, git and the installer need all three).
# shellcheck disable=SC2016  # runs in the guest's bash
GUEST_WAIT='i=0
while [ "$i" -lt "$1" ]; do
  i=$((i + 1))
  s=$(systemctl is-system-running 2>/dev/null || true)
  case "$s" in
  running | degraded) ;;
  *) sleep 2; continue ;;
  esac
  ip -4 -o addr show dev eth0 scope global 2>/dev/null | grep -q inet || { sleep 2; continue; }
  ip -4 route show default 2>/dev/null | grep -q . || { sleep 2; continue; }
  if getent ahostsv4 deb.debian.org >/dev/null 2>&1; then echo ok; exit 0; fi
  sleep 2
done
echo "systemd: $(systemctl is-system-running 2>/dev/null || true)"
echo "address: $(ip -4 -o addr show dev eth0 scope global 2>/dev/null | awk "{print \$4}" | head -n1)"
echo "route:   $(ip -4 route show default 2>/dev/null | head -n1)"
exit 1'

wait_ready() {
  local out
  msg_info "Waiting for the container's network"
  # Up to about 3 minutes: DHCP on a busy LAN can be slow.
  if ! out=$(guest_bash "$GUEST_WAIT" 90 </dev/null 2>&1); then
    msg_error "The container has no working network (DHCP, default route or DNS)"
    die "${out}
  In LAN mode, check that ${LAN_PARENT:-the parent interface} reaches a DHCP server, or set a static TS_IP/TS_GATEWAY/TS_DNS.
$(gluetun_hint)"
  fi
  msg_ok "Container network is up ($(guest_ip || echo "address unknown"))"
}

# Once the stack runs, Gluetun's firewall lets even root in the container
# reach the internet only through the VPN (see native/README.md).
gluetun_hint() {
  if guest systemctl is-active --quiet torrent-gluetun </dev/null 2>/dev/null; then
    echo "  Gluetun is running, so the container reaches the internet only through the VPN. If the VPN is not"
    echo "  connected, stop Gluetun and run this again: incus exec $(shown_inst) -- systemctl stop torrent-gluetun"
  fi
  return 0
}

guest_ip() {
  guest ip -4 -o addr show dev eth0 scope global </dev/null 2>/dev/null | awk '{split($4, a, "/"); print a[1]; exit}'
}

# ---------------------------------------------------------------------------
# Downloads folder from the host
# ---------------------------------------------------------------------------
# An unprivileged container's uid N is a high uid on the host (here
# 1000000+N by default). The apps run as PUID in the container, so the host
# folder is set up one of three ways (see the README for details):
#   idmap  raw.idmap maps just PUID and PGID straight through to the same
#          host ids. Works on any filesystem; the host's /etc/subuid and
#          /etc/subgid should list those ids for root (the Incus docs ask
#          for it), and the container's files are remapped once. Every
#          other container id, root included, stays a high host id.
#   shift  idmapped mount (disk device shift=true): PUID:PGID on the host
#          is PUID:PGID inside, without host changes. But on that folder
#          EVERY container id is the same host id, so root in the container
#          is root there (it could leave setuid-root files). Needs a kernel
#          and filesystem with idmapped mounts (ext4, xfs, btrfs, ZFS 2.2+;
#          not NFS or CIFS).
#   none   no translation: the host folder belongs to the shifted ids.
# auto tries them in that order: idmap keeps the container's root an
# ordinary high uid on the host, which is what the stack's security relies
# on. Only the top folder and its incomplete/ subfolder are created or
# chowned; existing files are left alone, and a folder that already holds
# someone else's files keeps its owner unless TS_FORCE=1.
DL_ORIG_OWNER="" # owner before this run touched it ("" = did not exist)
DL_HAD_FILES=0   # 1 if it already held anything besides incomplete/
prepare_host_downloads() {
  local uid=$1 gid=$2 owner
  [[ "$IS_LOCAL" == 1 ]] || return 0
  if [[ ! -d "$DL_HOST_PATH" ]]; then
    [[ "$(id -u)" == 0 ]] || die "${DL_HOST_PATH} does not exist and only root can create it with the right owner. Create it (owner ${uid}:${gid}) and run again."
    mkdir -p "$DL_HOST_PATH"
  elif [[ -z "$DL_ORIG_OWNER" ]]; then
    DL_ORIG_OWNER=$(stat -c '%u:%g' "$DL_HOST_PATH")
    [[ -n "$(find "$DL_HOST_PATH" -mindepth 1 -maxdepth 1 ! -name incomplete -print -quit 2>/dev/null)" ]] && DL_HAD_FILES=1
  fi
  owner=$(stat -c '%u:%g' "$DL_HOST_PATH")
  if [[ "$DL_HAD_FILES" == 1 && "$DL_ORIG_OWNER" != "${uid}:${gid}" && "$FORCE" != 1 ]]; then
    # Probably the user's existing media folder (or a typo): do not take it
    # over. The apps may then be unable to write; verify_downloads says so.
    msg_warn "${DL_HOST_PATH} already holds files and belongs to ${DL_ORIG_OWNER}, so its owner is left alone. The apps need ${uid}:${gid} on the host: run  mkdir -p ${DL_HOST_PATH}/incomplete && chown ${uid}:${gid} ${DL_HOST_PATH} ${DL_HOST_PATH}/incomplete  (or set TS_FORCE=1)."
    return 0
  fi
  if [[ "$(id -u)" == 0 ]]; then
    mkdir -p "$DL_HOST_PATH/incomplete"
    chown "${uid}:${gid}" "$DL_HOST_PATH" "$DL_HOST_PATH/incomplete" ||
      die "Could not chown ${DL_HOST_PATH} to ${uid}:${gid} (a network share that squashes root?). See the README."
    chmod u+rwx,g+rwx "$DL_HOST_PATH" "$DL_HOST_PATH/incomplete"
    [[ "$owner" == "${uid}:${gid}" ]] || msg_ok "Set the owner of ${DL_HOST_PATH} to ${uid}:${gid} (was ${owner})"
  elif [[ "$owner" != "${uid}:${gid}" ]]; then
    msg_warn "${DL_HOST_PATH} belongs to ${owner}; the apps need ${uid}:${gid} on the host. As root: chown ${uid}:${gid} ${DL_HOST_PATH}"
  fi
}

add_downloads_disk() {
  # Prints only Incus's error message (for the caller to show).
  { inc config device add "$INST" downloads disk source="$DL_HOST_PATH" path="$GUEST_DOWNLOADS" "$@" >/dev/null; } 2>&1
}

# Allow root (which starts containers) to map one host id: "root:ID:1" in
# /etc/subuid or /etc/subgid. newuidmap reads these files on every start.
allow_host_id() {
  local file=$1 id=$2
  grep -qxF "root:${id}:1" "$file" 2>/dev/null && return 0
  echo "root:${id}:1" >>"$file"
  msg_ok "Added root:${id}:1 to ${file} (lets Incus map that id into the container)"
}

use_idmap() {
  # Returns 1 (instead of exiting) when the idmap could not be applied, so
  # the auto mode can fall back to the next mapping.
  local out
  msg_info "Mapping ${PUID}:${PGID} straight through for ${DL_HOST_PATH} (raw.idmap)"
  # A restricted project refuses this low-level key unless its
  # restricted.idmap.uid/gid cover the ids.
  if ! out=$(inc config set "$INST" raw.idmap="uid ${PUID} ${PUID}
gid ${PGID} ${PGID}" 2>&1); then
    msg_warn "Incus refused raw.idmap: ${out#Error: }"
    return 1
  fi
  if [[ "$IS_LOCAL" == 1 && "$(id -u)" == 0 ]]; then
    allow_host_id /etc/subuid "$PUID"
    allow_host_id /etc/subgid "$PGID"
  else
    msg_warn "On the Incus server, /etc/subuid and /etc/subgid should contain root:${PUID}:1 and root:${PGID}:1 for this mapping (this script can only add them when it runs as root on the server)."
  fi
  if ! out=$(add_downloads_disk); then
    inc config unset "$INST" raw.idmap
    msg_warn "Could not add the downloads folder: ${out}"
    return 1
  fi
  # raw.idmap takes effect on the next start; Incus remaps the container's
  # files once (it says "Remapping container filesystem").
  msg_info "Restarting the container to apply the id mapping"
  if ! out=$(inc restart "$INST" 2>&1); then
    msg_warn "The container did not start with the id mapping: ${out%%$'\n'*}"
    inc config device remove "$INST" downloads >/dev/null 2>&1 || true
    inc config unset "$INST" raw.idmap
    start_instance
    return 1
  fi
  msg_ok "Restarted the container with ${PUID}:${PGID} mapped straight through"
  wait_ready
  DL_USED=idmap
}

use_none() {
  # The host ids that the container's PUID/PGID really are, from the
  # container's own id map (columns: inside, host, count).
  local uid gid out
  uid=$(map_id "$PUID" "$(guest cat /proc/self/uid_map </dev/null)")
  gid=$(map_id "$PGID" "$(guest cat /proc/self/gid_map </dev/null)")
  [[ -n "$uid" && -n "$gid" ]] || die "Could not work out the host ids for ${PUID}:${PGID} from the container's id map."
  prepare_host_downloads "$uid" "$gid"
  [[ "$IS_LOCAL" == 1 ]] ||
    msg_warn "On the Incus server, give ${DL_HOST_PATH} the owner ${uid}:${gid} (chown ${uid}:${gid} ${DL_HOST_PATH}); that is ${PUID}:${PGID} in the container."
  if ! out=$(add_downloads_disk); then die "Could not add the downloads folder: ${out}"; fi
  DL_USED=none
}

# map_id ID MAP: host id for container id ID in a /proc/*/[ug]id_map text.
map_id() {
  awk -v id="$1" '$1 <= id && id < $1 + $3 {print $2 + id - $1; exit}' <<<"$2"
}

# Idmapped mount. Added while the container runs, so Incus checks right
# away whether the kernel and filesystem can do one here; SHIFT_ERR keeps
# Incus's message when they cannot.
SHIFT_ERR=""
use_shift() {
  msg_info "Mounting ${DL_HOST_PATH} at ${GUEST_DOWNLOADS} (idmapped mount)"
  if SHIFT_ERR=$(add_downloads_disk shift=true); then
    DL_USED="shift"
    msg_ok "Mounted ${DL_HOST_PATH} at ${GUEST_DOWNLOADS} (idmapped: ${PUID}:${PGID} on the host is ${PUID}:${PGID} inside)"
    return 0
  fi
  return 1
}

attach_downloads() {
  [[ -n "$DL_HOST_PATH" ]] || return 0
  # A failure here leaves a container with nothing installed in it; on_exit
  # then says to remove it and run the installer again.
  local again="Then run the installer again with"
  case "$DL_MAPPING" in
  auto)
    prepare_host_downloads "$PUID" "$PGID"
    if ! use_idmap; then
      msg_warn "raw.idmap could not be used; trying an idmapped mount (shift=true) instead."
      if use_shift; then
        msg_warn "With shift=true, root in the container counts as root on ${DL_HOST_PATH} (see the README, Security notes)."
      # Incus says "Required idmapping abilities not available" when the
      # kernel or filesystem cannot do it, and "The "shift" property cannot
      # be used with a restricted source path" in a restricted project.
      # Anything else (a missing folder, say) is a real error.
      elif [[ "${SHIFT_ERR,,}" == *idmap* || "${SHIFT_ERR,,}" == *shift* ]]; then
        msg_warn "No idmapped mount for ${DL_HOST_PATH} here (${SHIFT_ERR#Error: }); falling back to a plain mount owned by the container's shifted ids."
        use_none
      else
        msg_error "Could not mount ${DL_HOST_PATH}"
        die "${SHIFT_ERR}
  ${again} another folder, or TS_DOWNLOADS_MAPPING=none (see the README)."
      fi
    fi
    ;;
  idmap)
    prepare_host_downloads "$PUID" "$PGID"
    use_idmap || die "The idmap mapping did not work (see above). ${again} TS_DOWNLOADS_MAPPING=shift or none."
    ;;
  shift)
    prepare_host_downloads "$PUID" "$PGID"
    if ! use_shift; then
      msg_error "Could not mount ${DL_HOST_PATH} with shift=true"
      die "${SHIFT_ERR}
  ${again} TS_DOWNLOADS_MAPPING=idmap or none (see the README)."
    fi
    ;;
  none) use_none ;;
  esac
  inc config set "$INST" "${KEY_DLMAP}=${DL_USED}"
  verify_downloads
}

verify_downloads() {
  local owner
  owner=$(guest stat -c '%u:%g' "$GUEST_DOWNLOADS" </dev/null 2>/dev/null || echo "?")
  if [[ "$owner" != "${PUID}:${PGID}" ]]; then
    msg_warn "${GUEST_DOWNLOADS} is owned by ${owner} inside the container, not ${PUID}:${PGID}: the apps may not be able to write downloads. See the README (Downloads folder)."
    return 0
  fi
  if guest setpriv --reuid="$PUID" --regid="$PGID" --clear-groups \
    sh -c 'f="$1/.torrent-stack-write-test"; : >"$f" && rm -f "$f"' sh "$GUEST_DOWNLOADS" </dev/null >/dev/null 2>&1; then
    msg_ok "Downloads folder is writable by ${PUID}:${PGID} in the container (${DL_USED} mapping)"
  else
    msg_warn "${GUEST_DOWNLOADS} is not writable by ${PUID}:${PGID} in the container; check the folder's permissions on the host."
  fi
}

# ---------------------------------------------------------------------------
# Guest-side steps (bash snippets; arguments arrive as $1, $2, ...)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # these run in the guest's bash, not here
GUEST_APT='set -Eeuo pipefail
# --error-on=any: plain apt-get update exits 0 even when it fetched nothing.
apt-get update -q --error-on=any
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
# tzdata for the time zone below; git only when cloning from GitHub.
apt-get -y -q install tzdata
if [ "$1" = 1 ]; then apt-get -y -q install git ca-certificates curl; fi'

# shellcheck disable=SC2016
GUEST_TZ='if [ -e "/usr/share/zoneinfo/$1" ]; then
  ln -sf "/usr/share/zoneinfo/$1" /etc/localtime && echo "$1" >/etc/timezone && echo set
fi'

# shellcheck disable=SC2016
GUEST_UNPACK='set -Eeuo pipefail
mkdir -p "$1"
tar -xf - -C "$1" --no-same-owner'

# Install: clone the repository if the container has no checkout yet. An
# existing checkout is left as it is: updates go through
# `native/install.sh self-update` (see action_update), which keeps the live
# app configs under configs/ and never writes into the apps' folders.
# shellcheck disable=SC2016
GUEST_CLONE='set -Eeuo pipefail
dir=$1 url=$2 ref=$3
if [ -d "$dir/.git" ]; then
  echo "Source: $(git -C "$dir" log -1 --format="%h %s") (existing checkout, kept as it is)"
  exit 0
fi
if [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
  echo "ERROR: $dir exists but is not a git checkout (it was copied in with TS_SOURCE_DIR). Use TS_SOURCE_DIR again." >&2
  exit 3
fi
git clone -q --depth 1 --branch "$ref" "$url" "$dir"
echo "Source: $(git -C "$dir" log -1 --format="%h %s")"'

# shellcheck disable=SC2016
GUEST_NATIVE='set -Eeuo pipefail
dir=$1 settings=$2 cmd=$3
shift 3
if [ ! -f "$dir/native/install.sh" ]; then
  echo "ERROR: $dir/native/install.sh not found. This branch/tag has no native installer." >&2
  exit 4
fi
if [ "$cmd" = install ] && [ -f "$settings" ]; then
  set -a
  . "$settings"
  set +a
fi
cd "$dir"
exec bash native/install.sh "$cmd" "$@"'

# The web UI ports from the guest .env (or .env.example before the first
# install has created .env).
# shellcheck disable=SC2016
# Before that first install, a port in the settings file ($2) wins, as it
# will once native/install.sh has written it into .env.
GUEST_PORTS='keys="^(QBIT_WEBUI_PORT|JACKETT_PORT|FLARESOLVERR_PORT|FILEBROWSER_PORT)="
if [ -f "$1/.env" ]; then grep -E "$keys" "$1/.env" || true; exit 0; fi
[ -f "$1/.env.example" ] && { grep -E "$keys" "$1/.env.example" || true; }
[ -f "$2" ] && { grep -E "$keys" "$2" || true; }
exit 0'

prepare_guest_os() {
  local need_git=$1
  msg_info "Updating Debian packages in the container"
  if ! guest_bash "$GUEST_APT" "$need_git" </dev/null >"$TEMP_DIR/apt.log" 2>&1; then
    tail -n 20 "$TEMP_DIR/apt.log" >&2 || true
    die "apt-get failed in the container.
$(gluetun_hint)"
  fi
  msg_ok "Updated Debian packages in the container"
  if [[ -n "$TZ_NAME" && "$(guest_bash "$GUEST_TZ" "$TZ_NAME" </dev/null 2>/dev/null || true)" == set ]]; then
    msg_ok "Container time zone set to ${TZ_NAME}"
  fi
}

# Copy a local checkout in, without git metadata, runtime state or secrets.
# Streamed as a tar archive through `incus exec` rather than `incus file
# push -r`, whose directory rules changed in Incus 7.0 (cp-like); this way
# the exclusions and the target folder are the same on every version.
push_source_dir() {
  [[ -f "$TS_SOURCE_DIR/native/install.sh" ]] || die "TS_SOURCE_DIR '$TS_SOURCE_DIR' has no native/install.sh."
  msg_info "Copying ${TS_SOURCE_DIR} into the container"
  local ex=() f
  # .env.* are secrets too (backups of .env), except the tracked example.
  for f in "$TS_SOURCE_DIR"/.env.*; do
    [[ -e "$f" && "${f##*/}" != .env.example ]] && ex+=("--exclude=./${f##*/}")
  done
  tar -C "$TS_SOURCE_DIR" --owner=0 --group=0 --numeric-owner \
    --no-anchored --exclude=__pycache__ --exclude='*.pyc' \
    --anchored --exclude=./.git --exclude=./configs --exclude=./downloads \
    --exclude=./incomplete --exclude=./.env --exclude=./scripts/env-editor/.venv \
    ${ex[@]+"${ex[@]}"} -cf - . | guest_bash "$GUEST_UNPACK" "$GUEST_DIR"
  msg_ok "Copied ${TS_SOURCE_DIR} to ${GUEST_DIR}"
}

sync_source() {
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    push_source_dir
    return 0
  fi
  msg_info "Getting ${REPO_URL} (${TS_REF}) in the container"
  if ! guest_bash "$GUEST_CLONE" "$GUEST_DIR" "$REPO_URL" "$TS_REF" </dev/null >"$TEMP_DIR/git.log" 2>&1; then
    msg_error "Could not get the repository into ${GUEST_DIR}"
    cat "$TEMP_DIR/git.log" >&2 || true
    gluetun_hint >&2
    exit 1
  fi
  local src
  src=$(grep -E '^Source' "$TEMP_DIR/git.log" | tail -n1 || true)
  msg_ok "${src:-Repository ready in ${GUEST_DIR}}"
}

# Initial .env values for native/install.sh (any .env key works; see
# DESIGN.md). Written once; --resume reuses them.
push_settings() {
  local f="$TEMP_DIR/settings.env"
  {
    echo "# Initial .env values passed to native/install.sh by platforms/incus/install.sh."
    printf 'TZ=%q\nPUID=%q\nPGID=%q\n' "$TZ_NAME" "$PUID" "$PGID"
    if [[ -n "$DL_HOST_PATH" ]]; then
      printf 'DOWNLOADS_PATH=%q\nINCOMPLETE_DOWNLOADS=%q\n' "$GUEST_DOWNLOADS" "$GUEST_DOWNLOADS/incomplete"
    fi
  } >"$f"
  inc file push --uid 0 --gid 0 --mode 0600 "$f" "${INST}${GUEST_SETTINGS}" >/dev/null
}

# run_native COMMAND [ARGS...]: stream the in-container installer's output
# to the terminal and keep a private copy. sed -u (unbuffered), not tr: tr
# holds its output back in 4 KiB blocks when it writes to a pipe, so the
# progress lines of a long install would only show up at the end.
run_native() {
  local cmd=$1
  echo
  echo "  ${BOLD}Running native/install.sh $* in container ${NAME}${CL}"
  echo "  ----------------------------------------------------------------"
  if ! guest_bash "$GUEST_NATIVE" "$GUEST_DIR" "$GUEST_SETTINGS" "$@" </dev/null 2>&1 |
    sed -u 's/\r//g' | tee -a "$INSTALL_LOG"; then
    echo "  ----------------------------------------------------------------"
    # Only an install's output can hold the first-run password worth keeping.
    [[ "$cmd" == install ]] && KEEP_LOG=1
    die "native/install.sh ${cmd} failed in container ${NAME}."
  fi
  echo "  ----------------------------------------------------------------"
}

show_native_status() {
  echo "  ${BOLD}Service status:${CL}"
  guest_bash "$GUEST_NATIVE" "$GUEST_DIR" "$GUEST_SETTINGS" status </dev/null 2>&1 | sed -u 's/\r//g; s/^/    /' || true
}

# ---------------------------------------------------------------------------
# Proxy devices (network mode "proxy")
# ---------------------------------------------------------------------------
# Each web UI gets a proxy device: Incus listens on the host
# (listen=tcp:ADDRESS:PORT+OFFSET) and opens a connection to the app inside
# the container (connect=tcp:127.0.0.1:PORT) for every client. Inside the
# container those connections come from 127.0.0.1, so they pass the kill
# switch (loopback is always allowed) whether the VPN is up or down.
declare -A GUEST_PORT=()
read_guest_ports() {
  local line key value svc
  GUEST_PORT=([env-editor]="$ENV_EDITOR_PORT")
  while IFS= read -r line; do
    line=${line%$'\r'}
    key=${line%%=*}
    value=$(trim "${line#*=}")
    value=${value//\"/}
    value=${value//\'/}
    in_range "$value" 1 65535 || continue
    # A later line for the same key wins, as in native's .env parser.
    # (if/then, not `[[ ]] && ...`: a non-matching last test would become
    # this function's exit status and stop the script under set -e.)
    for svc in "${PROXY_SERVICES[@]}"; do
      if [[ -n "${PORT_KEY[$svc]}" && "${PORT_KEY[$svc]}" == "$key" ]]; then
        GUEST_PORT[$svc]=$value
      fi
    done
  done < <(guest_bash "$GUEST_PORTS" "$GUEST_DIR" "$GUEST_SETTINGS" </dev/null 2>/dev/null || true)
  return 0
}

# --sync-ports / --update with TS_PROXY_PORT_OFFSET or TS_PROXY_ADDRESS set:
# store the new value on the container (sync_proxies reads it from there),
# so the proxy devices move and later runs keep the new value.
apply_proxy_overrides() {
  local mode
  [[ -n "${TS_PROXY_PORT_OFFSET:-}${TS_PROXY_ADDRESS:-}" ]] || return 0
  mode=$(inc config get "$INST" "$KEY_MODE" 2>/dev/null || true)
  if [[ "$mode" != proxy ]]; then
    msg_warn "TS_PROXY_PORT_OFFSET / TS_PROXY_ADDRESS are ignored: container ${NAME} has its own LAN address (lan mode)."
    return 0
  fi
  if [[ -n "${TS_PROXY_PORT_OFFSET:-}" ]]; then
    valid_offset "$TS_PROXY_PORT_OFFSET" || die "Invalid TS_PROXY_PORT_OFFSET '${TS_PROXY_PORT_OFFSET}' (0-50000)."
    inc config set "$INST" "${KEY_POFFSET}=${TS_PROXY_PORT_OFFSET}"
    msg_ok "Host port offset for ${NAME} is now ${TS_PROXY_PORT_OFFSET}"
    read_guest_ports
    [[ -n "${GUEST_PORT[qbittorrent]:-}" ]] &&
      msg_warn "qBittorrent stays on host port ${GUEST_PORT[qbittorrent]} (its QBIT_WEBUI_PORT): qBittorrent refuses requests whose port differs from its own, so the offset does not apply to it. To move it, change QBIT_WEBUI_PORT in the env-editor, then run --sync-ports."
  fi
  if [[ -n "${TS_PROXY_ADDRESS:-}" ]]; then
    valid_ipv4 "$TS_PROXY_ADDRESS" || die "Invalid TS_PROXY_ADDRESS '${TS_PROXY_ADDRESS}' (an IPv4 address of the host, or 0.0.0.0)."
    inc config set "$INST" "${KEY_PADDR}=${TS_PROXY_ADDRESS}"
    msg_ok "Host listen address for ${NAME} is now ${TS_PROXY_ADDRESS}"
  fi
}

# host_port SERVICE PORT: the host-side port for a web UI. Every UI gets
# PORT + offset, except qBittorrent: its web UI refuses (401) any request
# whose Host header names a port other than its own (WebUI\HostHeaderValidation,
# a DNS-rebinding guard), and the browser sends the host-side port. So
# qBittorrent's host port is always QBIT_WEBUI_PORT itself; with an offset,
# the first install moves QBIT_WEBUI_PORT instead (see offset_qbit_port).
host_port() {
  if [[ "$1" == qbittorrent ]]; then echo "$2"; else echo $(($2 + PORT_OFFSET)); fi
}

# First install in proxy mode with an offset: give qBittorrent the offset
# port inside the container too (QBIT_WEBUI_PORT = .env.example's + offset),
# so all UIs move by the offset as asked, through the settings file
# native/install.sh reads when it creates .env.
offset_qbit_port() {
  local off base new
  [[ "$(inc config get "$INST" "$KEY_MODE" 2>/dev/null)" == proxy ]] || return 0
  off=$(inc config get "$INST" "$KEY_POFFSET" 2>/dev/null || true)
  [[ -n "$off" && "$off" != 0 ]] || return 0
  guest test -f "$GUEST_DIR/.env" </dev/null 2>/dev/null && return 0
  guest grep -q '^QBIT_WEBUI_PORT=' "$GUEST_SETTINGS" </dev/null 2>/dev/null && return 0
  base=$(guest sed -n 's/^QBIT_WEBUI_PORT=//p' "$GUEST_DIR/.env.example" </dev/null 2>/dev/null | head -n1 || true)
  in_range "${base:-x}" 1 65535 || return 0
  new=$((base + off))
  ((new <= 65535)) || return 0 # sync_proxies reports it
  # shellcheck disable=SC2016  # runs in the guest
  guest_bash 'printf "QBIT_WEBUI_PORT=%s\n" "$2" >>"$1"' "$GUEST_SETTINGS" "$new" </dev/null
  msg_ok "qBittorrent's web UI port is ${new} (${base} + offset ${off}) inside the container too: qBittorrent only answers on its own port number"
}

PROXY_FAILED=0
sync_proxies() {
  local svc port hport dev want_l want_c cur_l cur_c out changed=0
  PROXY_ADDR=$(inc config get "$INST" "$KEY_PADDR" 2>/dev/null || true)
  PORT_OFFSET=$(inc config get "$INST" "$KEY_POFFSET" 2>/dev/null || true)
  PROXY_ADDR=${PROXY_ADDR:-0.0.0.0}
  PORT_OFFSET=${PORT_OFFSET:-0}
  read_guest_ports
  PROXY_FAILED=0
  # Two passes: first remove every device that has to change, then add the
  # new ones. Moving them one by one could fail when a UI's new host port is
  # another UI's old one (e.g. going from offset 1000 back to 0: the
  # env-editor's 9191 is still FlareSolverr's 8191+1000).
  local todo=()
  declare -A want_listen=() want_connect=()
  for svc in "${PROXY_SERVICES[@]}"; do
    port=${GUEST_PORT[$svc]:-}
    dev="proxy-${svc}"
    if [[ -z "$port" ]]; then
      msg_warn "No port for ${svc} in ${GUEST_DIR}/.env; not publishing it."
      continue
    fi
    hport=$(host_port "$svc" "$port")
    if ((hport > 65535)); then
      msg_warn "${svc}: host port ${hport} is above 65535; lower TS_PROXY_PORT_OFFSET. Not publishing it."
      PROXY_FAILED=1
      continue
    fi
    want_l="tcp:${PROXY_ADDR}:${hport}"
    want_c="tcp:127.0.0.1:${port}"
    cur_l=$(inc config device get "$INST" "$dev" listen 2>/dev/null || true)
    cur_c=$(inc config device get "$INST" "$dev" connect 2>/dev/null || true)
    [[ "$cur_l" == "$want_l" && "$cur_c" == "$want_c" ]] && continue
    if [[ -n "$cur_l$cur_c" ]]; then
      inc config device remove "$INST" "$dev" >/dev/null
    fi
    todo+=("$svc")
    want_listen[$svc]=$want_l
    want_connect[$svc]=$want_c
  done
  for svc in ${todo[@]+"${todo[@]}"}; do
    # Added to the running container, so a host port that is already in
    # use is reported here instead of stopping the container from booting.
    if out=$(inc config device add "$INST" "proxy-${svc}" proxy listen="${want_listen[$svc]}" connect="${want_connect[$svc]}" bind=host 2>&1); then
      changed=1
    else
      PROXY_FAILED=1
      msg_warn "Could not publish ${svc} on host port ${want_listen[$svc]##*:}: ${out#Error: }"
    fi
  done
  if [[ "$PROXY_FAILED" == 1 ]]; then
    msg_warn "Some web UIs are not published. Free that host port, or pick other ports, then re-publish:"
    msg_warn "  other host ports for all UIs:  TS_PROXY_PORT_OFFSET=10000 $(rerun_cmd) --sync-ports ${NAME}"
    msg_warn "  or change the port in the env-editor, then:  $(rerun_cmd) --sync-ports ${NAME}"
    msg_warn "  (qBittorrent's host port is always its QBIT_WEBUI_PORT: for it, change that port in the env-editor.)"
  elif [[ "$changed" == 1 ]]; then
    msg_ok "Published the web UIs on ${PROXY_ADDR} (proxy devices)"
  else
    msg_ok "Proxy devices already match the ports in .env"
  fi
}

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
host_address() {
  if [[ "$PROXY_ADDR" != 0.0.0.0 ]]; then
    echo "$PROXY_ADDR"
  elif [[ "$IS_LOCAL" == 1 ]]; then
    ip -4 route get 1.1.1.1 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -n1
  else
    echo "$SERVER_HOST"
  fi
}

print_access() {
  local mode base svc port ip
  mode=$(inc config get "$INST" "$KEY_MODE" 2>/dev/null || true)
  [[ ${#GUEST_PORT[@]} -gt 0 ]] || read_guest_ports
  if [[ "$mode" == proxy ]]; then
    base=$(host_address)
    base=${base:-<incus-host>}
    PORT_OFFSET=${PORT_OFFSET:-0}
  else
    ip=$(guest_ip || true)
    base=${ip:-<container-ip>}
    PORT_OFFSET=0
  fi
  echo
  echo "  ${BOLD}Open in a browser$([[ "$mode" == proxy ]] && echo " (through the Incus host)" || echo " (the container's own LAN address)"):${CL}"
  for svc in "${PROXY_SERVICES[@]}"; do
    port=${GUEST_PORT[$svc]:-}
    [[ -n "$port" ]] || continue
    if [[ "$mode" == proxy && -z "$(inc config device get "$INST" "proxy-${svc}" listen 2>/dev/null || true)" ]]; then
      show "$(printf '%-25s' "${UI_LABEL[$svc]}")" "not published (host port $(host_port "$svc" "$port") was busy; see above)"
      continue
    fi
    show "$(printf '%-25s' "${UI_LABEL[$svc]}")" "http://${base}:$(host_port "$svc" "$port")"
  done
  if [[ "$mode" != proxy ]] && ! guest test -e "$GUEST_NETWORKD" </dev/null 2>/dev/null; then
    ip=$(guest cat /sys/class/net/eth0/address </dev/null 2>/dev/null || true)
    [[ -n "$ip" ]] && echo "  (DHCP address. MAC ${ip}: reserve this IP in your router's DHCP settings to keep it.)"
  fi
  return 0
}

print_credentials() {
  local creds l
  creds=$(guest cat "$GUEST_CREDS" </dev/null 2>/dev/null | grep -v '^[[:space:]]*#' || true)
  if [[ -z "$creds" ]]; then
    echo "  env-editor login: as set earlier (first-run logins are only shown once)."
    echo "  Lost it? incus exec $(shown_inst) -- bash ${GUEST_DIR}/native/install.sh reset-login"
    return 0
  fi
  # Every line of the file: the env-editor login, and FileBrowser's (the
  # same password until a real qBittorrent login is set). The URLs in it
  # are the container's own address and ports. In proxy mode those cannot
  # be reached from the LAN (and differ with an offset), so only the login
  # part is shown here; the addresses to open are the ones printed above.
  local mode re='^([^[:space:]]+:)[[:space:]]+https?://[^[:space:]]+[[:space:]]+(.*)$'
  mode=$(inc config get "$INST" "$KEY_MODE" 2>/dev/null || true)
  echo
  echo "  ${BOLD}First-run logins, keep them safe:${CL}"
  while IFS= read -r l; do
    l=$(trim "$l")
    if [[ "$mode" == proxy && "$l" =~ $re ]]; then
      printf '    %-13s%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    else
      echo "    $l"
    fi
  done <<<"$creds"
  echo "  (Saved in ${GUEST_CREDS} inside the container: incus exec $(shown_inst) -- cat ${GUEST_CREDS}"
  if [[ "$mode" == proxy ]]; then
    echo "   That file lists the container's own addresses; from your network, use the"
    echo "   host addresses above. Note the logins somewhere safe, then delete that file.)"
  else
    echo "   Note them somewhere safe, then delete that file.)"
  fi
}

print_next_steps() {
  local cmd
  cmd=$(rerun_cmd)
  echo
  echo "  Next: open the env-editor, enter your VPN details and press Apply. Gluetun,"
  echo "  qBittorrent, Jackett and FlareSolverr start once real VPN settings are saved."
  echo "  Shell in the container:  incus exec $(shown_inst) -- bash"
  echo "  Update later:            ${cmd} --update ${NAME}"
  if [[ "$(inc config get "$INST" "$KEY_MODE" 2>/dev/null)" == proxy ]]; then
    echo "  After changing a port in the env-editor, re-publish it:"
    echo "                           ${cmd} --sync-ports ${NAME}"
    echo "  Proxy mode: every visitor reaches the apps from 127.0.0.1 inside the container, so"
    echo "  5 wrong qBittorrent logins from anyone lock everyone out for an hour (see the README)."
  fi
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------
# Refuse to touch an instance this script did not create, unless forced.
require_ours() {
  instance_exists || die "There is no instance called '${NAME}'${PROJECT:+ in project ${PROJECT}} on '${REMOTE}'."
  [[ "$(inc config get "$INST" "$KEY_MARK" 2>/dev/null)" == "$MARK_VALUE" ]] && return 0
  [[ "$FORCE" == 1 ]] && return 0
  die "Instance '${NAME}' was not created by this script (no ${KEY_MARK}). Set TS_FORCE=1 to use it anyway."
}

finish_install() {
  local need_git=0
  [[ -z "$TS_SOURCE_DIR" ]] && need_git=1
  prepare_guest_os "$need_git"
  sync_source
  offset_qbit_port
  # Proxy devices before the install, so a half-finished install can still
  # be reached; refreshed afterwards from the .env the installer created.
  [[ "$(inc config get "$INST" "$KEY_MODE" 2>/dev/null)" == proxy ]] && sync_proxies
  run_native install
  [[ "$(inc config get "$INST" "$KEY_MODE" 2>/dev/null)" == proxy ]] && sync_proxies
  inc config set "$INST" "${KEY_STAGE}=done"
  CREATED=0 # finished: nothing to clean up any more
  UNFINISHED=""
  # A log kept by an earlier failed run can hold the first-run password.
  local old_log="${HOME:-/root}/torrent-stack-${NAME}-install.log"
  if [[ -f "$old_log" ]]; then
    rm -f -- "$old_log"
    msg_ok "Removed the install log the failed run had kept (${old_log})"
  fi
  echo
  msg_ok "The torrent stack is installed in container ${NAME}."
  print_access
  print_credentials
  print_next_steps
}

action_install() {
  header_info
  check_incus
  check_project_restrictions
  check_whiptail
  INST="${REMOTE}:${NAME}"
  choose_settings
  INST="${REMOTE}:${NAME}"
  check_image
  show_settings
  create_instance
  start_instance
  wait_ready
  attach_downloads
  # The container is fully set up. From here on a failure can be finished
  # with --resume: everything it needs is in the container.
  inc config set "$INST" "${KEY_STAGE}=install"
  UNFINISHED=install
  finish_install
}

# --resume re-runs only the in-container part (finish_install). It refuses a
# container whose own setup (devices, downloads folder, id mapping) did not
# finish: those steps depend on settings that probably need changing, and
# nothing is installed in it yet, so removing it and starting again is
# simpler and cannot leave a half-configured container behind.
action_resume() {
  check_incus
  INST="${REMOTE}:${NAME}"
  require_ours
  if [[ "$(inc config get "$INST" "$KEY_STAGE" 2>/dev/null)" == setup ]]; then
    die "Container ${NAME} was not fully set up (the install stopped before anything was installed in it), so --resume cannot finish it. Remove it and run the installer again with the settings you want: incus delete --force $(shown_inst)"
  fi
  UNFINISHED=install
  ensure_running
  wait_ready
  apply_proxy_overrides
  local saved
  if saved=$(guest cat "$GUEST_SETTINGS" </dev/null 2>/dev/null); then
    # Same time zone as the first run (the file holds plain KEY=value lines).
    TZ_NAME=$(sed -n 's/^TZ=//p' <<<"$saved" | head -n1)
    valid_tz "$TZ_NAME" || TZ_NAME=""
  else
    TZ_NAME=""
    msg_warn "${GUEST_SETTINGS} is missing in the container; the install uses .env.example defaults."
  fi
  finish_install
}

action_update() {
  check_incus
  INST="${REMOTE}:${NAME}"
  require_ours
  ensure_running
  wait_ready
  # native/install.sh self-update does the rest, the same way as on
  # Proxmox and as when run by hand in the container: the new repository
  # version (from git; a TS_SOURCE_DIR copy is pushed first), Debian package
  # upgrades, then the component update.
  local args=()
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    push_source_dir
  else
    guest test -d "$GUEST_DIR/.git" </dev/null 2>/dev/null ||
      die "${GUEST_DIR} in ${NAME} is a copy (it was installed with TS_SOURCE_DIR), not a git checkout. Update it with TS_SOURCE_DIR again."
    # An existing checkout updates from its own origin (perhaps a fork, or
    # a TS_REPO_URL given at install time), whatever REPO_URL says now.
    local origin
    origin=$(guest git -C "$GUEST_DIR" remote get-url origin </dev/null 2>/dev/null || echo '?')
    [[ -n "${TS_REPO_URL:-}" && "$TS_REPO_URL" != "$origin" ]] &&
      msg_warn "TS_REPO_URL is ignored for an existing checkout; it updates from its origin ${origin}."
    msg_info "Updating ${GUEST_DIR} from ${origin} in the container"
    [[ "$TS_REF_SET" == 1 ]] && args=(--ref "$TS_REF")
  fi
  run_native self-update ${args[@]+"${args[@]}"}
  apply_proxy_overrides
  [[ "$(inc config get "$INST" "$KEY_MODE" 2>/dev/null)" == proxy ]] && sync_proxies
  echo
  show_native_status
  msg_ok "Updated container ${NAME}."
  print_access
}

action_sync_ports() {
  check_incus
  INST="${REMOTE}:${NAME}"
  require_ours
  [[ "$(inc config get "$INST" "$KEY_MODE" 2>/dev/null)" == proxy ]] ||
    die "Container ${NAME} has its own LAN address (lan mode); there are no proxy devices to update."
  apply_proxy_overrides
  # A stopped container whose proxy port is now busy cannot start;
  # start_instance then drops the proxy devices and sync_proxies re-adds them.
  ensure_running
  sync_proxies
  print_access
  [[ "$PROXY_FAILED" == 0 ]] || exit 1
}

confirm() {
  local text=$1 answer
  [[ "$ASSUME_YES" == 1 ]] && return 0
  if [[ -t 0 && -t 1 ]] && command -v whiptail >/dev/null 2>&1; then
    whiptail --backtitle "$BACKTITLE" --title "REMOVE CONTAINER" --defaultno --yesno "$text" 16 76
    return
  fi
  if [[ -t 0 ]]; then
    printf '%s\n\nType yes to continue: ' "$text"
    read -r answer
    [[ "$answer" == yes ]]
    return
  fi
  die "Not removing anything without confirmation: run with --yes (or TS_YES=1)."
}

action_uninstall() {
  check_incus
  INST="${REMOTE}:${NAME}"
  require_ours
  local dl idmap
  dl=$(inc config device get "$INST" downloads source 2>/dev/null || true)
  idmap=$(inc config get "$INST" raw.idmap 2>/dev/null || true)
  local text="Delete container '${NAME}'${PROJECT:+ (project ${PROJECT})} on '${REMOTE}', with everything inside it: .env, VPN settings, app configs and any downloads stored on the container disk?"
  if [[ -n "$dl" ]]; then
    text+="

The downloads folder ${dl} on the host is NOT touched."
  fi
  confirm "$text" || exit_script
  msg_info "Deleting container ${NAME}"
  local out
  if ! out=$(inc delete --force "$INST" 2>&1); then
    msg_error "Could not delete container ${NAME}"
    die "$out"
  fi
  msg_ok "Deleted container ${NAME} (its proxy devices went with it)"
  [[ -n "$dl" ]] && msg_ok "Kept the downloads folder ${dl} on the host"
  if [[ -n "$idmap" ]]; then
    echo "  (If this script added root:<id>:1 lines to /etc/subuid and /etc/subgid for the"
    echo "   downloads mapping, they were left in place; remove them if nothing else uses them.)"
  fi
  return 0
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
  local action=install target=""
  # One action flag, the options, and at most one container name, in any
  # order (so "--uninstall --yes NAME" works as well as "--uninstall NAME --yes").
  while (($#)); do
    case "$1" in
    --update | --sync-ports | --uninstall | --resume)
      [[ "$action" == install || "$action" == "${1#--}" ]] ||
        die "Use one of --update, --sync-ports, --resume or --uninstall at a time (got --${action} and $1)."
      action=${1#--}
      ;;
    --unattended) UNATTENDED=1 ;;
    --yes | -y) ASSUME_YES=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*) die "Unknown option '$1' (see --help)." ;;
    "") die "An empty argument was given where a container name was expected." ;;
    *)
      [[ -z "$target" ]] || die "Only one container name, please (got '${target}' and '$1')."
      target=$1
      ;;
    esac
    shift
  done
  if [[ -n "$target" && "$action" == install ]]; then
    die "A new install takes its container name from the wizard or TS_NAME, not from '${target}' (see --help)."
  fi
  [[ "$action" == resume && -z "$target" ]] && die "--resume needs the container name: install.sh --resume NAME"
  [[ -n "$target" ]] && NAME=$target
  if [[ "$action" != install ]]; then
    valid_name "$NAME" || die "'${NAME}' is not a valid container name."
  fi
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    [[ -d "$TS_SOURCE_DIR" ]] || die "TS_SOURCE_DIR '${TS_SOURCE_DIR}' is not a directory."
    TS_SOURCE_DIR=$(cd "$TS_SOURCE_DIR" && pwd)
  fi
  TEMP_DIR=$(mktemp -d)
  chmod 700 "$TEMP_DIR"
  INSTALL_LOG="$TEMP_DIR/install.log"
  : >"$INSTALL_LOG"
  case "$action" in
  install) action_install ;;
  resume) action_resume ;;
  update) action_update ;;
  sync-ports) action_sync_ports ;;
  uninstall) action_uninstall ;;
  esac
}

main "$@"
