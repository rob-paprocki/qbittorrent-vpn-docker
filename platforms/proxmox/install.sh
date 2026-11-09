#!/usr/bin/env bash
#
# platforms/proxmox/install.sh
#
# Purpose: run as root on a Proxmox VE 8.x or 9.x host. Creates an
# unprivileged Debian 13 LXC container, passes /dev/net/tun into it, copies
# or clones this repository to /opt/torrent-stack inside it, and hands off to
# native/install.sh, which installs Gluetun, qBittorrent, Jackett,
# FlareSolverr, FileBrowser and the env-editor as systemd services in that
# one container. Afterwards it prints the env-editor URL and the first-run
# login the installer printed.
#
#   New container (wizard):
#     bash -c "$(curl -fsSL https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh)"
#   Update an existing one from the host ("install.sh" is only the name bash
#   gives the script; the arguments follow it):
#     bash -c "$(curl -fsSL .../platforms/proxmox/install.sh)" install.sh --update 105
#   Update from inside the container:
#     bash /opt/torrent-stack/platforms/proxmox/install.sh --update
#
# Run with --help for every option and environment variable.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# Adapted from community-scripts/ProxmoxVE and community-scripts/core
# (https://github.com/community-scripts/ProxmoxVE,
# https://github.com/community-scripts/core), Copyright (c) 2021-2026
# community-scripts ORG, MIT License: the whiptail Default/Advanced flow and
# msg_* helpers (build.func), the ID, hostname, IPv4 and time zone checks
# (ui/validate.func), the Debian release probe and the /dev/net/tun lines for
# older Proxmox VE (pve/backend.func). Nothing from that project is
# downloaded or sourced at run time, and this script sends no telemetry.

set -Eeuo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------
# TS_REPO_URL lets a fork install from its own repository.
readonly DEFAULT_REPO_URL="https://github.com/rob-paprocki/qbittorrent-vpn-docker"
REPO_URL="${TS_REPO_URL:-$DEFAULT_REPO_URL}"
readonly RAW_URL="https://raw.githubusercontent.com/rob-paprocki/qbittorrent-vpn-docker/main/platforms/proxmox/install.sh"
readonly GUEST_DIR="/opt/torrent-stack"
# Initial .env values for native/install.sh, kept in the guest so that
# --resume can re-run the install with the same answers. Not secret.
readonly GUEST_SETTINGS="/root/.torrent-stack-proxmox.env"
readonly GUEST_DOWNLOADS="/mnt/downloads"
readonly ENV_EDITOR_PORT=9191
readonly CT_TAGS="torrent-stack;vpn;qbittorrent"
readonly BACKTITLE="qbittorrent-vpn-docker for Proxmox VE"
# An unprivileged Proxmox container sees the host's uid/gid 100000+N as its
# own N (Proxmox's fixed default mapping, 65536 ids from 100000).
readonly PVE_ID_OFFSET=100000

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
  [[ "$INTERACTIVE" == 1 && -t 1 ]] && clear
  cat <<'EOF'

  _____                         _       ____  _             _
 |_   _|__  _ __ _ __ ___ _ __ | |_    / ___|| |_ __ _  ___| | __
   | |/ _ \| '__| '__/ _ \ '_ \| __|___\___ \| __/ _` |/ __| |/ /
   | | (_) | |  | | |  __/ | | | ||_____|__) | || (_| | (__|   <
   |_|\___/|_|  |_|  \___|_| |_|\__|   |____/ \__\__,_|\___|_|\_\
        Gluetun + qBittorrent + Jackett + FlareSolverr  (LXC)

EOF
}

usage() {
  cat <<EOF
Usage (as root on the Proxmox VE host):
  install.sh                    Create a new container and install the stack.
  install.sh --update [CTID]    Update the stack in an existing container: runs
                                native/install.sh self-update in it (new
                                repository version with the live app configs
                                kept, Debian package upgrades, then only the
                                changed parts).
  install.sh --resume CTID      Re-run the in-container install on a container
                                this script created (after a failed run). Reuses
                                the answers kept in
                                /root/torrent-stack-CTID-settings.env.
  install.sh --unattended       No wizard: take settings from TS_* variables.
  install.sh --help

Inside the container:
  bash ${GUEST_DIR}/platforms/proxmox/install.sh --update

Uninstall: pct stop CTID && pct destroy CTID --purge 1
(a bind-mounted downloads folder on the host is not touched).

Environment variables (all optional; they also pre-fill the wizard):
  TS_SOURCE_DIR=/path   Copy this local checkout into the container instead of
                        cloning from GitHub (used for testing).
  TS_REF=main           Branch or tag to clone (default main).
  TS_REPO_URL           Repository to clone (default: this project on GitHub).
  TS_CTID               Container ID (default: next free ID).
  TS_HOSTNAME           Hostname (default torrent-stack).
  TS_CORES / TS_RAM / TS_SWAP / TS_DISK
                        CPU cores (2), RAM MiB (4096), swap MiB (512), disk GiB (16).
  TS_ROOTFS_STORAGE / TS_TEMPLATE_STORAGE
                        Storage for the root disk / for the Debian template.
  TS_BRIDGE (vmbr0)  TS_VLAN  TS_IP (dhcp or a.b.c.d/nn)  TS_GATEWAY  TS_DNS
  TS_ROOT_PASSWORD_FILE File holding the container's root password (chmod 600).
  TS_SSH_KEY_FILE       File with SSH public keys for root.
  TS_TZ                 Time zone (default: the host's).
  TS_PUID / TS_PGID     uid/gid the apps run as inside the container (1000).
  TS_DOWNLOADS_HOST_PATH  Host folder bind-mounted at ${GUEST_DOWNLOADS}.
  TS_DOWNLOADS_MAPPING  shift (default) or idmap; see platforms/proxmox/README.md.
  TS_ONBOOT=1           Start the container when the host boots.
  TS_HOST_WIREGUARD=1   Load the host's wireguard module at boot (0 to skip).
  TS_GUEST_PROXY=url    HTTP(S) proxy for downloads inside the container.
  TS_UNATTENDED=1       Same as --unattended.  TS_FORCE=1  skip the
                        "container is not tagged torrent-stack" safety check.
EOF
}

# ---------------------------------------------------------------------------
# Error handling and cleanup
# ---------------------------------------------------------------------------
TEMP_DIR=""
INSTALL_LOG=""
CTID=""
CREATED_CTID=""   # set once this run has created a container
UNFINISHED_CTID="" # set while an install (new or --resume) is unfinished
KEEP_LOG=0

# The wizard's answers for one container, kept on this host (root-only)
# until its install has finished, so that --resume can carry on with the
# same answers even when the first run stopped before it could copy them
# into the container (for example because the container did not start).
# Not secret: the root password is never written to it.
host_state_file() { printf '/root/torrent-stack-%s-settings.env' "$1"; }

# The command that re-runs this script: the local file when it was started
# from one, else the one-liner. Non-default TS_REF / TS_SOURCE_DIR /
# TS_REPO_URL are put in front, so a copied hint uses the same source.
SELF_PATH=""
if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
  SELF_PATH=$(realpath -- "${BASH_SOURCE[0]}" 2>/dev/null || true)
fi
rerun_cmd() {
  local p=""
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

# On any failed exit while an install is unfinished: say how to retry or
# remove the container (and, for a container this run created, offer to
# remove it in the wizard), and keep the install log.
on_exit() {
  local rc=$?
  trap - ERR
  if [[ "$rc" != 0 && -n "$UNFINISHED_CTID" ]]; then
    KEEP_LOG=1
    echo
    echo "  Container ${UNFINISHED_CTID} exists but the install did not finish."
    echo "  Retry the install:  $(rerun_cmd) --resume ${UNFINISHED_CTID}"
    echo "  Or remove it:       pct stop ${UNFINISHED_CTID}; pct destroy ${UNFINISHED_CTID} --purge 1"
    [[ -e "$(host_state_file "$UNFINISHED_CTID")" ]] &&
      echo "  Your answers are kept in $(host_state_file "$UNFINISHED_CTID") for --resume."
    if [[ "$INTERACTIVE" == 1 && -n "$CREATED_CTID" ]] &&
      whiptail --backtitle "$BACKTITLE" --title "INSTALL FAILED" --defaultno --yesno \
        "The install failed. Remove the unfinished container ${CREATED_CTID} now?\n\nChoose No to keep it and retry with --resume." 12 70; then
      pct stop "$CREATED_CTID" >/dev/null 2>&1 || true
      if pct destroy "$CREATED_CTID" --purge 1 >/dev/null 2>&1; then
        msg_ok "Removed container ${CREATED_CTID}"
        rm -f "$(host_state_file "$CREATED_CTID")"
        KEEP_LOG=0
      fi
    fi
  fi
  if [[ -n "$TEMP_DIR" && -d "$TEMP_DIR" ]]; then
    # The install log can contain the env-editor's first-run password. Keep
    # it (root-only) only when the install failed, so it can be read.
    if [[ "$KEEP_LOG" == 1 && -s "$INSTALL_LOG" ]]; then
      local kept="/root/torrent-stack-${CTID:-unknown}-install.log"
      install -m 600 "$INSTALL_LOG" "$kept" 2>/dev/null && echo "  Install log kept at $kept (root-only)."
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
  [[ "$INTERACTIVE" == 1 && -t 1 ]] && clear
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
    value=$(wt --title "$title" --cancel-button Exit-Script --inputbox "$text" 12 76 "$value") || return 1
    value=$(trim "$value")
    if "$check" "$value"; then
      printf '%s' "$value"
      return 0
    fi
    wt --title "$title" --msgbox "$err" 10 76 || true
  done
}

is_uint() { [[ "$1" =~ ^[0-9]+$ ]]; }
in_range() { is_uint "$1" && ((10#$1 >= $2 && 10#$1 <= $3)); }
# has_line LINE TEXT: TEXT contains LINE exactly. (A here-string instead of
# `cmd | grep -q`, which can fail under pipefail when grep exits early.)
has_line() { grep -qxF -- "$1" <<<"$2"; }
ct_running() { [[ "$(pct status "$CTID" 2>/dev/null)" == *"status: running"* ]]; }

# Run a command inside the container with a clean, known environment.
# `pct exec` hands the host's environment to the guest by default (keep-env,
# planned to change in a later Proxmox release), which leaks host variables
# and locales the template does not have. env -i makes both behave the same.
GUEST_ENV=(PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8 TERM=dumb DEBIAN_FRONTEND=noninteractive)
# The host's own proxy variables are deliberately not copied in: a proxy on
# the host's 127.0.0.1 is unreachable from the container. Behind a LAN proxy,
# set TS_GUEST_PROXY=http://proxy:3128 for apt, git and the installer.
# The value goes on the `pct exec` command line, which every user of this
# host can read in the process list, so a proxy password is refused.
if [[ -n "${TS_GUEST_PROXY:-}" ]]; then
  [[ "$TS_GUEST_PROXY" =~ ^[A-Za-z][A-Za-z0-9+.-]*://[^/]*@ ]] &&
    die "TS_GUEST_PROXY must not contain a user name or password (it would be visible in this host's process list). Use a proxy that needs no login from the container, for example by allowing the container's address on the proxy."
  GUEST_ENV+=("http_proxy=${TS_GUEST_PROXY}" "https_proxy=${TS_GUEST_PROXY}")
fi
guest() { pct exec "$CTID" -- env -i "${GUEST_ENV[@]}" "$@"; }
# guest_bash SCRIPT [ARGS...]: run a bash snippet in the guest. ARGS arrive
# as $1, $2, ... so nothing from the host is pasted into the script text.
guest_bash() {
  local script=$1
  shift
  guest bash -c "$script" bash "$@"
}

# ---------------------------------------------------------------------------
# Validation (adapted from community-scripts ui/validate.func)
# ---------------------------------------------------------------------------
# Words are split with `read -a`, never with an unquoted $var: an unquoted
# expansion would also expand * or ? against the files in the current
# folder, so "*" could pass as a list of harmless file names.
valid_hostname() {
  local h=$1 label labels=()
  [[ -n "$h" && ${#h} -le 63 && "$h" =~ ^[a-z0-9.-]+$ ]] || return 1
  [[ "$h" != .* && "$h" != *. && "$h" != *..* ]] || return 1
  IFS=. read -r -a labels <<<"$h"
  for label in "${labels[@]}"; do
    [[ "$label" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] || return 1
  done
}

valid_ipv4() {
  local ip=$1 o
  [[ "$ip" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  for o in "${BASH_REMATCH[@]:1}"; do ((10#$o <= 255)) || return 1; done
}

# Proxmox accepts dhcp, manual or IPv4/CIDR with a prefix of 8 to 32.
valid_ipv4_cidr() {
  [[ "$1" == */* ]] || return 1
  valid_ipv4 "${1%/*}" && in_range "${1#*/}" 8 32
}
valid_ip_setting() { [[ "$1" == dhcp ]] || valid_ipv4_cidr "$1"; }
valid_gateway_or_empty() { [[ -z "$1" ]] || valid_ipv4 "$1"; }

ip_to_int() {
  local IFS=. a b c d
  read -r a b c d <<<"$1"
  echo $(((10#$a << 24) + (10#$b << 16) + (10#$c << 8) + 10#$d))
}
# gateway_in_subnet a.b.c.d/nn gateway: is the gateway inside that subnet?
gateway_in_subnet() {
  local cidr=${1#*/} mask ip gw
  ((cidr >= 31)) && return 0
  mask=$(((0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF))
  ip=$(ip_to_int "${1%/*}")
  gw=$(ip_to_int "$2")
  (((ip & mask) == (gw & mask)))
}

valid_dns_or_empty() {
  local s=$1 n parts=()
  [[ -z "$s" ]] && return 0
  read -r -a parts <<<"${s//,/ }"
  ((${#parts[@]})) || return 1
  for n in "${parts[@]}"; do
    valid_ipv4 "$n" || [[ "$n" =~ ^[0-9a-fA-F:]+$ && "$n" == *:* ]] || return 1
  done
}
valid_vlan_or_empty() { [[ -z "$1" ]] || in_range "$1" 1 4094; }
valid_cores() { in_range "$1" 1 8192; }
valid_ram() { in_range "$1" 1024 1048576; }
valid_swap() { in_range "$1" 0 1048576; }
valid_disk() { in_range "$1" 8 65536; }
# 1..65533 keeps every mapping range below non-empty and inside the 65536
# ids a Proxmox container has. 0 would run the apps as root.
valid_id() { in_range "$1" 1 65533; }

valid_bridge() { [[ -n "$1" && "$1" =~ ^[-_.[:alnum:]]+$ && -e "/sys/class/net/$1" ]]; }

# canon_path PATH: the real path, the way chown and the bind mount will see
# it: symlinks resolved and //, /./ and /../ folded (realpath -m also works
# for a folder that does not exist yet).
canon_path() { realpath -m -- "$1" 2>/dev/null; }

# A host folder to bind-mount, owned by the container's app user and
# writable from inside the container. A system folder there would let a
# compromised app change the host, so the check runs on the real path
# (canon_path) and refuses:
#  - anything under /etc, /usr, /boot, /dev, /proc, /sys, /run, /bin, /sbin,
#    /lib*, and /var (except a folder of your own under /var/lib/vz, the
#    "local" storage, outside the folders Proxmox manages there);
#  - /, /root, /home, /opt, /srv, /mnt, /media, /tmp, /var/lib/vz and a
#    storage's own mount point /mnt/pve/<storage> (folders below them are fine);
#  - another guest's disk (subvol-101-disk-0, images/101, private/101, ...).
# Names may only use letters, digits and . _ - + @ (a comma, '=' or ':'
# would be read as part of Proxmox's mount point settings).
valid_host_path_or_empty() {
  local p=$1
  [[ -z "$p" ]] && return 0
  [[ "$p" == /* ]] || return 1
  p=$(canon_path "$p") || return 1
  [[ "$p" =~ ^(/[A-Za-z0-9._+@-]+)+$ ]] || return 1
  case "$p" in
  /root | /home | /opt | /srv | /mnt | /media | /tmp | /mnt/pve | /var/lib/vz) return 1 ;;
  /etc | /etc/* | /usr | /usr/* | /boot | /boot/* | /dev | /dev/* | /proc | /proc/* | /sys | /sys/*) return 1 ;;
  /run | /run/* | /bin | /bin/* | /sbin | /sbin/* | /lib | /lib/* | /lib32 | /lib32/* | /lib64 | /lib64/* | /libx32 | /libx32/*) return 1 ;;
  /var/lib/vz/template | /var/lib/vz/template/* | /var/lib/vz/images | /var/lib/vz/images/* | /var/lib/vz/private | /var/lib/vz/private/*) return 1 ;;
  /var/lib/vz/dump | /var/lib/vz/dump/* | /var/lib/vz/snippets | /var/lib/vz/snippets/* | /var/lib/vz/import | /var/lib/vz/import/*) return 1 ;;
  /var/lib/vz/*) ;;
  /var | /var/*) return 1 ;;
  /mnt/pve/*/*) ;;
  /mnt/pve/*) return 1 ;;
  esac
  [[ "$p" =~ /(subvol|basevol|vm|base)-[0-9]+-disk-[0-9]+(/|$) || "$p" =~ /(images|private)/[0-9]+(/|$) ]] && return 1
  return 0
}

valid_ssh_key_line() {
  [[ "$1" =~ ^(ssh-ed25519|ssh-rsa|ecdsa-sha2-nistp(256|384|521)|sk-ssh-ed25519@openssh\.com|sk-ecdsa-sha2-nistp256@openssh\.com)\ [A-Za-z0-9+/]+={0,3}(\ .*)?$ ]]
}

# Container ID free on this node and in the cluster? pvesh's nextid endpoint
# answers for the whole cluster when given a VMID ("assert that it is free").
# Leftover disks of a removed guest with the same ID make pct create fail, so
# check LVM too.
ctid_free() {
  local id=$1
  in_range "$id" 100 999999999 || return 1
  [[ -e "/etc/pve/lxc/${id}.conf" || -e "/etc/pve/qemu-server/${id}.conf" ]] && return 1
  compgen -G "/etc/pve/nodes/*/lxc/${id}.conf" >/dev/null && return 1
  compgen -G "/etc/pve/nodes/*/qemu-server/${id}.conf" >/dev/null && return 1
  pvesh get /cluster/nextid --vmid "$id" >/dev/null 2>&1 || return 1
  if command -v lvs >/dev/null 2>&1 &&
    lvs --noheadings -o lv_name 2>/dev/null | grep -qE "(^|[-_])${id}($|[-_])"; then
    return 1
  fi
  return 0
}

next_free_ctid() {
  local id tries=0
  id=$(pvesh get /cluster/nextid 2>/dev/null | tr -dc '0-9')
  [[ -n "$id" ]] || id=100
  until ctid_free "$id"; do
    id=$((id + 1))
    tries=$((tries + 1))
    ((tries < 1000)) || die "Could not find a free container ID."
  done
  echo "$id"
}

# Print a time zone the way pct --timezone takes it: UTC or a zone.tab name.
# Aliases (US/Eastern) resolve to their zone; prints nothing for a zone pct
# rejects (the container then keeps the template's UTC).
pct_timezone() {
  local tz=$1 real
  in_zone_tab() { awk -F'\t' -v z="$1" '!/^#/ && $3 == z {f = 1} END {exit !f}' /usr/share/zoneinfo/zone.tab 2>/dev/null; }
  case "$tz" in
  "") return 0 ;;
  UTC | Etc/UTC | Etc/UCT | Etc/Universal | Etc/Zulu | Universal | Zulu | UCT)
    echo UTC
    return 0
    ;;
  esac
  if in_zone_tab "$tz"; then
    echo "$tz"
    return 0
  fi
  real=$(readlink -f "/usr/share/zoneinfo/$tz" 2>/dev/null || true)
  real="${real#/usr/share/zoneinfo/}"
  if [[ -n "$real" && "$real" != "$tz" ]] && in_zone_tab "$real"; then echo "$real"; fi
  return 0
}

host_timezone() {
  local tz=""
  tz=$(timedatectl show -p Timezone --value 2>/dev/null | tr -d '[:space:]') || true
  [[ -n "$tz" ]] || tz=$(tr -d '[:space:]' </etc/timezone 2>/dev/null) || true
  if [[ -z "$tz" ]]; then
    tz=$(readlink -f /etc/localtime 2>/dev/null || true)
    tz="${tz#/usr/share/zoneinfo/}"
  fi
  [[ "$tz" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ ]] || tz="Etc/UTC"
  echo "$tz"
}

# ---------------------------------------------------------------------------
# Host checks
# ---------------------------------------------------------------------------
PVE_MAJOR=0
PVE_MINOR=0

check_root() {
  [[ "$(id -u)" -eq 0 ]] || die "Run this script as root on the Proxmox VE host (not with sudo from another user)."
}

check_pve_version() {
  local ver
  command -v pveversion >/dev/null 2>&1 || die "pveversion not found: this is not a Proxmox VE host."
  ver=$(pveversion 2>/dev/null | sed -nE 's|^pve-manager/([0-9]+)\.([0-9]+).*|\1 \2|p' | head -n1)
  read -r PVE_MAJOR PVE_MINOR <<<"${ver:-0 0}"
  case "$PVE_MAJOR" in
  8 | 9) ;;
  *) die "Proxmox VE ${PVE_MAJOR}.${PVE_MINOR} is not supported; this script needs 8.x or 9.x." ;;
  esac
}

check_arch() {
  # Proxmox VE is only released for amd64, and the Debian 13 container
  # template this script downloads is the amd64 one. (The stack itself also
  # runs on arm64; see the Incus installer.)
  [[ "$(dpkg --print-architecture 2>/dev/null)" == amd64 ]] ||
    die "This host is $(dpkg --print-architecture 2>/dev/null || uname -m). Proxmox VE is only released for amd64 (x86-64), and this script only handles that."
}

check_whiptail() {
  command -v whiptail >/dev/null 2>&1 ||
    die "whiptail is missing (apt install whiptail), or run unattended with TS_UNATTENDED=1."
}

# Ask this host's pve-container whether it can set up Debian 13, the same way
# pct create will (adapted from community-scripts lxc_os_supported). Every
# current debian-13-standard template is a point release (13.1 or later),
# and pve-container before 5.3.1 (Proxmox VE 8) or 6.0.10 (9.0) refuses
# those ("unsupported debian version '13.1'": its check was <= 13 on the
# X.Y version). So a host that was not updated since early September 2025
# fails here, with advice, instead of in the middle of pct create.
check_debian13_support() {
  local dir rc=0
  command -v perl >/dev/null 2>&1 || return 0
  dir=$(mktemp -d)
  mkdir -p "$dir/etc"
  echo "13.1" >"$dir/etc/debian_version"
  perl -e '
    my ($root) = @ARGV;
    eval { require PVE::LXC::Setup::Debian; 1 } or exit 2;
    exit 0 if eval { PVE::LXC::Setup::Debian->new({}, $root, undef, sub {}); 1 };
    exit($@ =~ /unsupported|too old/i ? 1 : 2);
  ' "$dir" 2>/dev/null || rc=$?
  rm -rf "$dir"
  if [[ "$rc" == 1 ]]; then
    die "This host's pve-container cannot create Debian 13 containers yet. Update the host first: apt update && apt dist-upgrade"
  fi
}

check_tun() {
  [[ -c /dev/net/tun ]] || modprobe tun 2>/dev/null || true
  [[ -c /dev/net/tun ]] || die "/dev/net/tun does not exist on this host (modprobe tun failed)."
  # Proxmox VE 8.0 bind-mounts the host's node as is; the container's root
  # can only open it with the usual mode 0666 (set by udev).
  if ((PVE_MAJOR == 8 && PVE_MINOR == 0)) && [[ "$(stat -c %a /dev/net/tun)" != 666 ]]; then
    msg_warn "/dev/net/tun on this host is mode $(stat -c %a /dev/net/tun), not 666; the container may not be able to open it (chmod 666 /dev/net/tun, or update to Proxmox VE 8.1+)."
  fi
}

# Gluetun uses the kernel's WireGuard when the host has the module loaded and
# falls back to a slower userspace implementation otherwise. A container
# cannot load kernel modules itself, so load it on the host and keep it
# loaded across reboots.
setup_host_wireguard() {
  [[ "${TS_HOST_WIREGUARD:-1}" == 1 ]] || return 0
  if [[ -d /sys/module/wireguard ]]; then
    :
  elif modinfo wireguard >/dev/null 2>&1 && modprobe wireguard 2>/dev/null; then
    msg_ok "Loaded the host's wireguard kernel module"
  else
    msg_warn "No wireguard kernel module on this host; Gluetun will use userspace WireGuard."
    return 0
  fi
  if [[ ! -e /etc/modules-load.d/torrent-stack-wireguard.conf ]]; then
    mkdir -p /etc/modules-load.d
    printf '# Added by qbittorrent-vpn-docker platforms/proxmox/install.sh: lets\n# Gluetun in the container use kernel WireGuard.\nwireguard\n' \
      >/etc/modules-load.d/torrent-stack-wireguard.conf
  fi
}

# ---------------------------------------------------------------------------
# Settings
# ---------------------------------------------------------------------------
INTERACTIVE=0
CT_HOSTNAME="${TS_HOSTNAME:-torrent-stack}"
CORES="${TS_CORES:-2}"
RAM_MB="${TS_RAM:-4096}"
SWAP_MB="${TS_SWAP:-512}"
DISK_GB="${TS_DISK:-16}"
ROOTFS_STORAGE="${TS_ROOTFS_STORAGE:-}"
TEMPLATE_STORAGE="${TS_TEMPLATE_STORAGE:-}"
BRIDGE="${TS_BRIDGE:-vmbr0}"
VLAN="${TS_VLAN:-}"
IPV4="${TS_IP:-dhcp}"
GATEWAY="${TS_GATEWAY:-}"
DNS="${TS_DNS:-}"
PUID="${TS_PUID:-1000}"
PGID="${TS_PGID:-1000}"
DL_HOST_PATH="${TS_DOWNLOADS_HOST_PATH:-}"
DL_MAPPING="${TS_DOWNLOADS_MAPPING:-shift}"
ONBOOT="${TS_ONBOOT:-1}"
ROOT_PW=""
ROOT_PW_FROM_FILE=0 # 1: ROOT_PW came from TS_ROOT_PASSWORD_FILE, never asked
SSH_KEYS=""
SSH_KEY_ANSWER="${TS_SSH_KEY_FILE:-}" # what was typed in the SSH key box
TZ_NAME=""
TZ_PCT=""
TEMPLATE=""

load_secret_files() {
  if [[ -n "${TS_ROOT_PASSWORD_FILE:-}" ]]; then
    [[ -r "$TS_ROOT_PASSWORD_FILE" ]] || die "TS_ROOT_PASSWORD_FILE '$TS_ROOT_PASSWORD_FILE' is not readable."
    IFS= read -r ROOT_PW <"$TS_ROOT_PASSWORD_FILE" || true
    [[ -n "$ROOT_PW" ]] || die "TS_ROOT_PASSWORD_FILE is empty."
    ROOT_PW_FROM_FILE=1
  fi
  if [[ -n "${TS_SSH_KEY_FILE:-}" ]]; then
    [[ -r "$TS_SSH_KEY_FILE" ]] || die "TS_SSH_KEY_FILE '$TS_SSH_KEY_FILE' is not readable."
    read_ssh_keys "$TS_SSH_KEY_FILE" || die "TS_SSH_KEY_FILE has no valid OpenSSH public key."
  fi
}

# read_ssh_keys FILE: keep the valid public-key lines, drop comments/blanks.
read_ssh_keys() {
  local line keys=""
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim "${line//$'\r'/}")
    [[ -z "$line" || "$line" == \#* ]] && continue
    valid_ssh_key_line "$line" && keys+="$line"$'\n'
  done <"$1"
  [[ -n "$keys" ]] || return 1
  SSH_KEYS="$keys"
}

validate_settings() {
  local bad=()
  # From here on the downloads folder is its real path (see canon_path).
  if [[ "$DL_HOST_PATH" == /* ]]; then DL_HOST_PATH=$(canon_path "$DL_HOST_PATH"); fi
  valid_hostname "$CT_HOSTNAME" || bad+=("hostname '$CT_HOSTNAME' (lowercase letters, digits and '-')")
  valid_cores "$CORES" || bad+=("cores '$CORES'")
  valid_ram "$RAM_MB" || bad+=("RAM '$RAM_MB' MiB (at least 1024)")
  valid_swap "$SWAP_MB" || bad+=("swap '$SWAP_MB' MiB")
  valid_disk "$DISK_GB" || bad+=("disk '$DISK_GB' GiB (at least 8)")
  valid_bridge "$BRIDGE" || bad+=("bridge '$BRIDGE' (no such interface on this host)")
  valid_vlan_or_empty "$VLAN" || bad+=("VLAN tag '$VLAN' (1-4094)")
  valid_ip_setting "$IPV4" || bad+=("IPv4 '$IPV4' (dhcp or a.b.c.d/nn)")
  if [[ "$IPV4" == dhcp ]]; then
    GATEWAY=""
  else
    valid_gateway_or_empty "$GATEWAY" && [[ -n "$GATEWAY" ]] || bad+=("gateway '$GATEWAY' (needed with a static IP)")
    if valid_ipv4_cidr "$IPV4" && valid_ipv4 "$GATEWAY" && ! gateway_in_subnet "$IPV4" "$GATEWAY"; then
      bad+=("gateway '$GATEWAY' is not in ${IPV4}")
    fi
  fi
  valid_dns_or_empty "$DNS" || bad+=("DNS '$DNS'")
  valid_id "$PUID" || bad+=("PUID '$PUID' (1-65533)")
  valid_id "$PGID" || bad+=("PGID '$PGID' (1-65533)")
  valid_host_path_or_empty "$DL_HOST_PATH" || bad+=("downloads folder '$DL_HOST_PATH'")
  [[ "$DL_MAPPING" == shift || "$DL_MAPPING" == idmap ]] || bad+=("downloads mapping '$DL_MAPPING' (shift or idmap)")
  [[ "$ONBOOT" == 0 || "$ONBOOT" == 1 ]] || bad+=("TS_ONBOOT '$ONBOOT' (0 or 1)")
  if [[ -n "$CTID" ]] && ! ctid_free "$CTID"; then bad+=("container ID '$CTID' (in use or out of range)"); fi
  if ((${#bad[@]})); then
    local b
    for b in "${bad[@]}"; do msg_error "Invalid setting: $b"; done
    exit 1
  fi
}

root_login_text() {
  if [[ -n "$ROOT_PW" && -n "$SSH_KEYS" ]]; then
    echo "password + SSH key"
  elif [[ -n "$ROOT_PW" ]]; then
    echo "password"
  elif [[ -n "$SSH_KEYS" ]]; then
    echo "SSH key"
  else
    echo "only via 'pct enter' on this host"
  fi
}

# Short plain-text summary for the confirmation box.
settings_summary() {
  printf 'ID %s, hostname %s\n' "$CTID" "$CT_HOSTNAME"
  printf '%s cores, %s MiB RAM, %s MiB swap, %s GiB disk\n' "$CORES" "$RAM_MB" "$SWAP_MB" "$DISK_GB"
  printf 'Bridge %s%s, IPv4 %s%s\n' "$BRIDGE" "${VLAN:+ VLAN $VLAN}" "$IPV4" "${GATEWAY:+ via $GATEWAY}"
  printf 'DNS: %s\n' "${DNS:-same as the host}"
  printf 'Apps run as %s:%s, time zone %s\n' "$PUID" "$PGID" "$TZ_NAME"
  if [[ -n "$DL_HOST_PATH" ]]; then
    printf 'Downloads: %s (%s)\n' "$DL_HOST_PATH" "$DL_MAPPING"
  else
    printf 'Downloads: on the container disk\n'
  fi
  printf 'Root login: %s; start on boot: %s\n' "$(root_login_text)" "$([[ "$ONBOOT" == 1 ]] && echo yes || echo no)"
}

show_settings() {
  show "Container ID" "$CTID"
  show "Hostname" "$CT_HOSTNAME"
  show "CPU cores / RAM / swap" "${CORES} / ${RAM_MB} MiB / ${SWAP_MB} MiB"
  show "Disk" "${DISK_GB} GiB"
  show "Network" "bridge ${BRIDGE}${VLAN:+, VLAN ${VLAN}}, IPv4 ${IPV4}${GATEWAY:+ via ${GATEWAY}}"
  show "DNS" "${DNS:-same as the host}"
  show "Time zone" "${TZ_NAME}"
  show "Apps run as uid/gid" "${PUID}/${PGID}"
  if [[ -n "$DL_HOST_PATH" ]]; then
    show "Downloads" "${DL_HOST_PATH} -> ${GUEST_DOWNLOADS} (${DL_MAPPING} mapping)"
  else
    show "Downloads" "inside the container disk (${GUEST_DIR}/downloads)"
  fi
  show "Start on boot" "$([[ "$ONBOOT" == 1 ]] && echo yes || echo no)"
  show "Root login" "$(root_login_text)"
}

ask_root_password() {
  # $1 = 1 when an empty password is allowed (Advanced: key-only or
  # pct-enter-only access).
  local allow_empty=$1 pw pw2 text="Root password for the container (8+ characters)."
  [[ "$ROOT_PW_FROM_FILE" == 1 ]] && return 0 # read from TS_ROOT_PASSWORD_FILE
  # A Do-Over in the Advanced wizard: the password typed in the first pass
  # can be kept, or changed/cleared by answering No.
  if [[ -n "$ROOT_PW" ]]; then
    wt --title "KEEP ROOT PASSWORD" --yesno "Keep the root password you typed before?\n\nChoose No to type a new one (or none)." 10 66 && return 0
    ROOT_PW=""
  fi
  [[ "$allow_empty" == 1 ]] && text+="\nLeave empty for no password (log in with an SSH key or 'pct enter')."
  while true; do
    pw=$(wt --title "ROOT PASSWORD" --cancel-button Exit-Script --passwordbox "$text" 12 72) || exit_script
    if [[ -z "$pw" && "$allow_empty" == 1 ]]; then
      ROOT_PW=""
      return 0
    fi
    if ((${#pw} < 8)); then
      wt --title "ROOT PASSWORD" --msgbox "The password needs at least 8 characters." 8 60 || true
      continue
    fi
    pw2=$(wt --title "ROOT PASSWORD" --cancel-button Exit-Script --passwordbox "Type the password again." 10 72) || exit_script
    if [[ "$pw" == "$pw2" ]]; then
      ROOT_PW=$pw
      return 0
    fi
    wt --title "ROOT PASSWORD" --msgbox "The passwords do not match. Try again." 8 60 || true
  done
}

# The box shows the previous answer (on a Do-Over) or TS_SSH_KEY_FILE.
# Leaving it empty means no key, also on a Do-Over.
ask_ssh_keys() {
  local key
  while true; do
    key=$(wt --title "SSH PUBLIC KEY" --cancel-button Exit-Script --inputbox \
      "Paste an SSH public key for root, or the path of a file with keys (optional).\nExample: ssh-ed25519 AAAA... you@laptop" 12 78 "$SSH_KEY_ANSWER") || exit_script
    key=$(trim "${key//$'\r'/}")
    if [[ -z "$key" ]]; then
      SSH_KEYS=""
      SSH_KEY_ANSWER=""
      return 0
    fi
    if [[ "$key" == /* && -r "$key" ]] && read_ssh_keys "$key"; then
      SSH_KEY_ANSWER=$key
      return 0
    fi
    if valid_ssh_key_line "$key"; then
      SSH_KEYS="$key"$'\n'
      SSH_KEY_ANSWER=$key
      return 0
    fi
    wt --title "SSH PUBLIC KEY" --msgbox "That is not an OpenSSH public key (ssh-ed25519 AAAA..., ssh-rsa ..., ecdsa-...) or a readable file of them." 10 72 || true
  done
}

advanced_settings() {
  local v
  CTID=$(ask "CONTAINER ID" "Container ID" "$CTID" ctid_free "That ID is in use or out of range (100 and up).") || exit_script
  CT_HOSTNAME=$(ask "HOSTNAME" "Hostname (lowercase letters, digits and '-')" "$CT_HOSTNAME" valid_hostname "Not a valid hostname.") || exit_script
  CORES=$(ask "CPU CORES" "CPU cores" "$CORES" valid_cores "Enter a number from 1 up.") || exit_script
  RAM_MB=$(ask "RAM" "RAM in MiB (FlareSolverr's Chromium and the Gluetun build want 2048+; 4096 is comfortable)" "$RAM_MB" valid_ram "Enter at least 1024.") || exit_script
  SWAP_MB=$(ask "SWAP" "Swap in MiB" "$SWAP_MB" valid_swap "Enter a number, 0 for none.") || exit_script
  DISK_GB=$(ask "DISK SIZE" "Root disk in GiB. Without a downloads folder from the host (asked below), downloads are stored on this disk too." "$DISK_GB" valid_disk "Enter at least 8.") || exit_script
  local bridges
  bridges=$(cd /sys/class/net 2>/dev/null && for b in */bridge; do [[ -d "$b" ]] && printf '%s ' "${b%/bridge}"; done) || true
  BRIDGE=$(ask "BRIDGE" "Network bridge${bridges:+ (found: ${bridges% })}" "$BRIDGE" valid_bridge "No interface with that name on this host.") || exit_script
  VLAN=$(ask "VLAN TAG" "VLAN tag (leave empty for none)" "$VLAN" valid_vlan_or_empty "Enter 1-4094, or leave empty.") || exit_script
  IPV4=$(ask "IPV4 ADDRESS" "IPv4: 'dhcp', or a static address with prefix, e.g. 192.168.1.50/24" "$IPV4" valid_ip_setting "Enter dhcp or an address like 192.168.1.50/24.") || exit_script
  if [[ "$IPV4" != dhcp ]]; then
    while true; do
      GATEWAY=$(ask "GATEWAY" "IPv4 gateway, e.g. 192.168.1.1" "$GATEWAY" valid_ipv4 "Enter an IPv4 address.") || exit_script
      gateway_in_subnet "$IPV4" "$GATEWAY" && break
      wt --title "GATEWAY" --msgbox "${GATEWAY} is not inside ${IPV4}." 8 60 || true
    done
  else
    GATEWAY=""
  fi
  DNS=$(ask "DNS SERVERS" "DNS servers, space separated (leave empty to use the host's)" "$DNS" valid_dns_or_empty "Enter IP addresses separated by spaces.") || exit_script
  ask_root_password 1
  ask_ssh_keys
  PUID=$(ask "PUID" "User ID the apps run as inside the container (owner of downloaded files)" "$PUID" valid_id "Enter 1-65533.") || exit_script
  PGID=$(ask "PGID" "Group ID the apps run as inside the container" "$PGID" valid_id "Enter 1-65533.") || exit_script
  DL_HOST_PATH=$(ask "DOWNLOADS FOLDER" "Optional: a folder on this Proxmox host to keep downloads in, mounted at ${GUEST_DOWNLOADS} in the container (e.g. /tank/downloads). Leave empty to keep downloads on the container disk." "$DL_HOST_PATH" valid_host_path_or_empty "Enter an absolute path that is not a system folder or another guest's disk (letters, digits and . _ - + @ only), or leave empty.") || exit_script
  if [[ -n "$DL_HOST_PATH" ]]; then
    DL_HOST_PATH=$(canon_path "$DL_HOST_PATH")
    local shift_on=ON idmap_on=OFF
    [[ "$DL_MAPPING" == idmap ]] && shift_on=OFF idmap_on=ON
    v=$(wt --title "DOWNLOADS OWNERSHIP" --cancel-button Exit-Script --radiolist \
      "The container's uid ${PUID} is uid $((PVE_ID_OFFSET + PUID)) on this host. How should ${DL_HOST_PATH} be owned?" 14 78 2 \
      "shift" "Own it as $((PVE_ID_OFFSET + PUID)):$((PVE_ID_OFFSET + PGID)) on the host (simple)" "$shift_on" \
      "idmap" "Keep ${PUID}:${PGID} on the host (maps that id through)" "$idmap_on") || exit_script
    DL_MAPPING=$v
  fi
  if wt --title "START ON BOOT" --yesno "Start the container when the Proxmox host boots?" 8 60; then ONBOOT=1; else ONBOOT=0; fi
  if [[ -z "$ROOT_PW" && -z "$SSH_KEYS" ]] &&
    ! wt --title "ROOT LOGIN" --yesno "No password and no SSH key: you can only get a shell with 'pct enter ${CTID}' on this host. Continue?" 10 70; then
    advanced_settings
    return
  fi
}

choose_settings() {
  [[ -n "$CTID" ]] || CTID=$(next_free_ctid)
  if [[ "$INTERACTIVE" != 1 ]]; then
    validate_settings
    return
  fi
  wt --title "TORRENT STACK LXC" --yesno "This creates a new Debian 13 container running Gluetun (VPN), qBittorrent, Jackett, FlareSolverr, FileBrowser and the env-editor. Proceed?" 11 70 || exit_script
  if wt --title "SETTINGS" --yes-button Default --no-button Advanced --yesno "Use default settings?" 10 60; then
    header_info
    echo "  ${BOLD}Using default settings${CL}"
    ask_root_password 0
  else
    header_info
    echo "  ${BOLD}Using advanced settings${CL}"
    while true; do
      advanced_settings
      wt --title "SETTINGS" --yes-button Create --no-button Do-Over --yesno \
        "Create the container with these settings?\n\n$(settings_summary)" 18 76 && break
      header_info
      echo "  ${BOLD}Using advanced settings${CL}"
    done
  fi
  validate_settings
}

# pick_storage CONTENT PREFERRED: print an active storage that holds CONTENT
# (rootdir = container disks, vztmpl = templates). Asks when there is a
# choice in the wizard; otherwise the preferred one, else the roomiest.
storage_lines() { pvesm status --content "$1" 2>/dev/null | awk 'NR > 1 && $3 == "active" {print $1, $2, $6}' || true; }

pick_storage() {
  local content=$1 preferred=$2 lines name type free menu=() n=0 default=""
  lines=$(storage_lines "$content")
  [[ -n "$lines" ]] || return 2
  while read -r name type free; do
    n=$((n + 1))
    menu+=("$name" "$(printf '%-10s %9s free' "$type" "$(numfmt --from-unit=1024 --to=iec --format %.1f "$free" 2>/dev/null || echo "${free}K")")")
    if [[ "$name" == "$preferred" ]]; then default=$name; fi
  done <<<"$lines"
  [[ -n "$default" ]] || default=$(sort -k3,3n <<<"$lines" | tail -n1 | awk '{print $1}')
  if ((n > 1)) && [[ "$INTERACTIVE" == 1 ]]; then
    local i radio=()
    for ((i = 0; i < ${#menu[@]}; i += 2)); do
      radio+=("${menu[i]}" "${menu[i + 1]}" "$([[ "${menu[i]}" == "$default" ]] && echo ON || echo OFF)")
    done
    wt --title "STORAGE" --cancel-button Exit-Script --radiolist \
      "Storage for $([[ "$content" == rootdir ]] && echo "the container's disk" || echo "the Debian template"):" 16 72 6 "${radio[@]}" || return 1
  else
    echo "$default"
  fi
}

# choose_storage VAR CONTENT PREFERRED LABEL
choose_storage() {
  local var=$1 content=$2 preferred=$3 label=$4 value=${!1} rc=0
  if [[ -n "$value" ]]; then
    awk -v s="$value" '$1 == s {f = 1} END {exit !f}' <<<"$(storage_lines "$content")" ||
      die "Storage '$value' is not active or cannot hold ${label} (${content} content)."
  else
    value=$(pick_storage "$content" "$preferred") || rc=$?
    case "$rc" in
    0) ;;
    2) die "No active storage on this host can hold ${label} (${content} content)." ;;
    *) exit_script ;;
    esac
  fi
  printf -v "$var" '%s' "$value"
}

choose_storages() {
  choose_storage ROOTFS_STORAGE rootdir local-lvm "container disks"
  choose_storage TEMPLATE_STORAGE vztmpl local "container templates"
  # Free space in KiB (column 6 of pvesm status).
  local free
  free=$(pvesm status --storage "$ROOTFS_STORAGE" 2>/dev/null | awk 'NR == 2 {print $6}')
  if is_uint "${free:-x}" && ((free < DISK_GB * 1024 * 1024)); then
    die "Storage '$ROOTFS_STORAGE' has $((free / 1024 / 1024)) GiB free; the container disk needs ${DISK_GB} GiB."
  fi
  show "Container disk storage" "$ROOTFS_STORAGE"
  show "Template storage" "$TEMPLATE_STORAGE"
}

# ---------------------------------------------------------------------------
# Template
# ---------------------------------------------------------------------------
# Newest debian-13-standard template: from the Proxmox index (pveam update),
# plus whatever is already on the template storage (works offline).
resolve_template() {
  local pattern='^debian-13-standard_[0-9][0-9.]*-[0-9]+_amd64\.tar\.(zst|xz|gz)$' candidates
  msg_info "Updating the container template list"
  if pveam update >/dev/null 2>&1; then
    msg_ok "Updated the container template list"
  else
    msg_warn "pveam update failed (offline?); using the templates Proxmox already knows"
  fi
  candidates=$({
    pveam available --section system 2>/dev/null | awk '{print $2}'
    pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR > 1 {sub(/^[^\/]*\//, "", $1); print $1}'
  } | grep -E "$pattern" | sort -u -V) || true
  TEMPLATE=$(tail -n1 <<<"$candidates")
  [[ -n "$TEMPLATE" ]] || die "No debian-13-standard template is available (check the host's internet access and 'pveam available')."
  if has_line "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR > 1 {print $1}')"; then
    msg_ok "Template ${TEMPLATE} is already on ${TEMPLATE_STORAGE}"
    return 0
  fi
  local try
  for try in 1 2 3; do
    msg_info "Downloading ${TEMPLATE} to ${TEMPLATE_STORAGE} (attempt ${try}/3)"
    if pveam download "$TEMPLATE_STORAGE" "$TEMPLATE" >"$TEMP_DIR/pveam.log" 2>&1; then
      msg_ok "Downloaded ${TEMPLATE}"
      return 0
    fi
    ((try < 3)) && sleep $((try * 5))
  done
  # Offline, but an older Debian 13 template is already on the storage:
  # use that (the in-container apt full-upgrade brings it up to date).
  local local_tpl
  local_tpl=$(pveam list "$TEMPLATE_STORAGE" 2>/dev/null | awk 'NR > 1 {sub(/^[^\/]*\//, "", $1); print $1}' |
    grep -E "$pattern" | sort -V | tail -n1) || true
  if [[ -n "$local_tpl" ]]; then
    msg_warn "Could not download ${TEMPLATE}; using the newest one already on ${TEMPLATE_STORAGE}: ${local_tpl}"
    TEMPLATE=$local_tpl
    return 0
  fi
  tail -n 5 "$TEMP_DIR/pveam.log" >&2 || true
  die "Could not download ${TEMPLATE}."
}

# ---------------------------------------------------------------------------
# Downloads bind mount: who owns the host folder
# ---------------------------------------------------------------------------
# In an unprivileged container, ids are shifted: container uid N is host uid
# 100000+N. The apps run as PUID inside, so they can only write to a host
# folder owned by host uid 100000+PUID ("shift", the default), unless the
# container's id map passes PUID through unchanged ("idmap"), so that the
# folder can stay owned by PUID on the host, e.g. to share it with a NAS
# share or other containers that use the same uid. Only the top folder and
# its incomplete/ subfolder are chowned; existing files are left alone.
prepare_downloads_dir() {
  [[ -n "$DL_HOST_PATH" ]] || return 0
  local uid gid
  if [[ "$DL_MAPPING" == idmap ]]; then
    uid=$PUID gid=$PGID
  else
    uid=$((PVE_ID_OFFSET + PUID)) gid=$((PVE_ID_OFFSET + PGID))
  fi
  # The folder may already be shared with a container, whose apps could
  # have swapped incomplete/ for a symlink to, say, /etc: chown and chmod
  # would then change the host's /etc. So symlinks are refused here (the
  # folder itself is already its real path, see canon_path).
  local d
  for d in "$DL_HOST_PATH" "$DL_HOST_PATH/incomplete"; do
    [[ -L "$d" ]] && die "${d} is a symbolic link; use a real folder for the downloads."
    [[ -e "$d" && ! -d "$d" ]] && die "${d} exists but is not a folder."
  done
  msg_info "Preparing ${DL_HOST_PATH} for the container (owner ${uid}:${gid})"
  mkdir -p "$DL_HOST_PATH/incomplete"
  chown -h "${uid}:${gid}" "$DL_HOST_PATH" "$DL_HOST_PATH/incomplete" ||
    die "Could not chown ${DL_HOST_PATH} to ${uid}:${gid} (a network share that squashes root? See the README)."
  chmod u+rwx,g+rwx "$DL_HOST_PATH" "$DL_HOST_PATH/incomplete"
  msg_ok "Prepared ${DL_HOST_PATH} (owner ${uid}:${gid} on the host = ${PUID}:${PGID} in the container)"
  if [[ "$DL_MAPPING" == idmap ]]; then
    # Allow root (which starts the container) to map that one host id.
    grep -qxF "root:${PUID}:1" /etc/subuid 2>/dev/null || echo "root:${PUID}:1" >>/etc/subuid
    grep -qxF "root:${PGID}:1" /etc/subgid 2>/dev/null || echo "root:${PGID}:1" >>/etc/subgid
  fi
}

# lxc.idmap lines: container ids 0..N-1 -> host 100000.., N -> host N,
# N+1..65535 -> host 100000+N+1.. (Proxmox wiki, Unprivileged LXC containers).
idmap_lines() {
  local kind=$1 id=$2
  printf 'lxc.idmap: %s 0 %d %d\n' "$kind" "$PVE_ID_OFFSET" "$id"
  printf 'lxc.idmap: %s %d %d 1\n' "$kind" "$id" "$id"
  printf 'lxc.idmap: %s %d %d %d\n' "$kind" "$((id + 1))" "$((PVE_ID_OFFSET + id + 1))" "$((65536 - id - 1))"
}

# ---------------------------------------------------------------------------
# Create and start the container
# ---------------------------------------------------------------------------
create_container() {
  local net="name=eth0,bridge=${BRIDGE},ip=${IPV4}"
  [[ -n "$GATEWAY" ]] && net+=",gw=${GATEWAY}"
  [[ -n "$VLAN" ]] && net+=",tag=${VLAN}"
  local args=(
    --arch amd64
    --ostype debian
    --hostname "$CT_HOSTNAME"
    --cores "$CORES"
    --memory "$RAM_MB"
    --swap "$SWAP_MB"
    --rootfs "${ROOTFS_STORAGE}:${DISK_GB}"
    --net0 "$net"
    # Unprivileged: root in the container is an ordinary high uid on the host.
    --unprivileged 1
    # nesting=1 is required for Debian 13: its systemd (257) sandboxes
    # services in their own namespaces, which an unprivileged container may
    # only do with nesting. Without it services and the console fail (pct
    # docs: "required by systemd to isolate services"; Proxmox VE 9.1
    # documents it, 9.2 warns when it is off).
    # No Docker runs here, so keyctl is not needed.
    --features nesting=1
    --onboot "$ONBOOT"
    --tags "$CT_TAGS"
    --description "qbittorrent-vpn-docker (native install). Created by platforms/proxmox/install.sh."
  )
  [[ -n "$TZ_PCT" ]] && args+=(--timezone "$TZ_PCT")
  [[ -n "$DNS" ]] && args+=(--nameserver "$DNS")
  # /dev/net/tun for Gluetun. Proxmox VE 8.1+ passes devices natively (dev0);
  # 8.0 needs the raw LXC lines added after creation.
  if ((PVE_MAJOR > 8 || PVE_MINOR >= 1)); then
    args+=(--dev0 /dev/net/tun)
  fi
  [[ -n "$DL_HOST_PATH" ]] && args+=(--mp0 "${DL_HOST_PATH},mp=${GUEST_DOWNLOADS}")
  if [[ -n "$SSH_KEYS" ]]; then
    printf '%s' "$SSH_KEYS" >"$TEMP_DIR/authorized_keys"
    args+=(--ssh-public-keys "$TEMP_DIR/authorized_keys")
  fi
  # The root password is NOT passed here: --password would put it on the
  # command line, visible in the process list. It is set after start, on
  # chpasswd's stdin.

  msg_info "Creating container ${CTID}"
  # pct extracts the template under the caller's umask; keep the usual 022
  # so a hardened umask does not leave the guest's /etc unreadable.
  if ! (umask 022 && pct create "$CTID" "${TEMPLATE_STORAGE}:vztmpl/${TEMPLATE}" "${args[@]}") >"$TEMP_DIR/pct-create.log" 2>&1; then
    tail -n 15 "$TEMP_DIR/pct-create.log" >&2 || true
    die "pct create failed."
  fi
  CREATED_CTID=$CTID
  UNFINISHED_CTID=$CTID
  msg_ok "Created container ${CTID} (${CT_HOSTNAME})"

  local conf="/etc/pve/lxc/${CTID}.conf"
  if ((PVE_MAJOR == 8 && PVE_MINOR == 0)); then
    # Same lines community-scripts uses: allow the tun char device (10:200)
    # and bind it in from the host.
    printf '%s\n' 'lxc.cgroup2.devices.allow: c 10:200 rwm' \
      'lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file' >>"$conf"
  fi
  if [[ -n "$DL_HOST_PATH" && "$DL_MAPPING" == idmap ]]; then
    {
      idmap_lines u "$PUID"
      idmap_lines g "$PGID"
    } >>"$conf"
  fi
}

start_container() {
  ct_running && return 0
  msg_info "Starting container ${CTID}"
  pct start "$CTID" >"$TEMP_DIR/pct-start.log" 2>&1 || {
    tail -n 15 "$TEMP_DIR/pct-start.log" >&2 || true
    die "pct start ${CTID} failed."
  }
  local i
  for i in $(seq 1 30); do
    ct_running && break
    sleep 1
  done
  ct_running || die "Container ${CTID} did not start."
  msg_ok "Started container ${CTID}"
}

# Let systemd finish booting (networking.service brings up eth0). Only a
# running container is needed for the steps that follow (password, settings
# file); the network can still be missing, which wait_for_network reports.
wait_for_boot() {
  msg_info "Waiting for container ${CTID} to boot"
  timeout 150 pct exec "$CTID" -- systemctl is-system-running --wait </dev/null >/dev/null 2>&1 || true
  msg_ok "Container ${CTID} has booted"
}

CT_IP=""
wait_for_network() {
  local i
  msg_info "Waiting for the container's network"
  for i in $(seq 1 60); do
    CT_IP=$(guest hostname -I </dev/null 2>/dev/null | tr ' ' '\n' | grep -E '^[0-9]+(\.[0-9]+){3}$' | head -n1) || true
    [[ -n "$CT_IP" ]] && break
    sleep 2
  done
  [[ -n "$CT_IP" ]] || die "The container got no IPv4 address. Check the bridge/VLAN/DHCP settings (pct enter ${CTID}; ip addr)."
  for i in $(seq 1 30); do
    guest getent ahostsv4 deb.debian.org </dev/null >/dev/null 2>&1 && {
      msg_ok "Network is up (${CT_IP})"
      return 0
    }
    sleep 2
  done
  die "The container (${CT_IP}) cannot resolve deb.debian.org. Check its gateway and DNS."
}

set_root_password() {
  [[ -n "$ROOT_PW" ]] || return 0
  msg_info "Setting the root password"
  # printf is a shell builtin, so the password never appears in a process
  # list; chpasswd reads it from stdin inside the container.
  printf 'root:%s\n' "$ROOT_PW" | pct exec "$CTID" -- chpasswd
  msg_ok "Set the root password"
  ROOT_PW_PENDING=0
  if [[ -e "$(host_state_file "$CTID")" ]]; then save_host_state; fi
}

# ---------------------------------------------------------------------------
# Answers kept on the host until the install has finished (host_state_file)
# ---------------------------------------------------------------------------
ROOT_PW_PENDING=0 # 1: a root password was chosen but is not set yet

save_host_state() {
  local f
  f=$(host_state_file "$CTID")
  (
    umask 077
    {
      echo "# Written by platforms/proxmox/install.sh for container ${CTID}: your"
      echo "# answers, used by --resume if the install stops early. Deleted once the"
      echo "# install has finished. No passwords are stored here."
      printf 'S_PUID=%q\nS_PGID=%q\nS_TZ=%q\n' "$PUID" "$PGID" "$TZ_NAME"
      printf 'S_DL_PATH=%q\nS_DL_MAPPING=%q\n' "$DL_HOST_PATH" "$DL_MAPPING"
      printf 'S_REF=%q\nS_REF_SET=%q\n' "$TS_REF" "$TS_REF_SET"
      printf 'S_SOURCE_DIR=%q\nS_REPO_URL=%q\n' "$TS_SOURCE_DIR" "$REPO_URL"
      printf 'S_ROOT_PW_PENDING=%q\n' "$ROOT_PW_PENDING"
    } >"$f.tmp"
  )
  mv -f "$f.tmp" "$f"
}

# load_host_state: read the saved answers for $CTID. Values given now as
# TS_* variables win over saved ones. Returns 1 when there is no usable file.
load_host_state() {
  local f
  f=$(host_state_file "$CTID")
  # Only a root-owned regular file that nobody else can write is read.
  [[ -f "$f" && ! -L "$f" && "$(stat -c %u "$f")" == 0 ]] || return 1
  (((8#$(stat -c %a "$f") & 8#022) == 0)) || return 1
  local S_PUID="" S_PGID="" S_TZ="" S_DL_PATH="" S_DL_MAPPING="" S_REF="" S_REF_SET=0
  local S_SOURCE_DIR="" S_REPO_URL="" S_ROOT_PW_PENDING=0
  # shellcheck disable=SC1090  # written by save_host_state above
  source "$f"
  [[ -n "${TS_PUID:-}" ]] || PUID=$S_PUID
  [[ -n "${TS_PGID:-}" ]] || PGID=$S_PGID
  [[ -n "${TS_TZ:-}" ]] || TZ_NAME=$S_TZ
  [[ -n "${TS_DOWNLOADS_HOST_PATH:-}" ]] || DL_HOST_PATH=$S_DL_PATH
  [[ -n "${TS_DOWNLOADS_MAPPING:-}" ]] || DL_MAPPING=$S_DL_MAPPING
  if [[ "$TS_REF_SET" != 1 ]]; then TS_REF=${S_REF:-main} TS_REF_SET=$S_REF_SET; fi
  [[ -n "$TS_SOURCE_DIR" ]] || TS_SOURCE_DIR=$S_SOURCE_DIR
  [[ -n "${TS_REPO_URL:-}" ]] || REPO_URL=${S_REPO_URL:-$DEFAULT_REPO_URL}
  ROOT_PW_PENDING=$S_ROOT_PW_PENDING
  # Same checks as for a new install, so a damaged file cannot slip
  # anything odd into the container.
  valid_id "$PUID" && valid_id "$PGID" && valid_host_path_or_empty "$DL_HOST_PATH" &&
    [[ "$TZ_NAME" =~ ^[A-Za-z0-9_+-]+(/[A-Za-z0-9_+-]+)*$ && "$DL_MAPPING" =~ ^(shift|idmap)$ ]] ||
    die "${f} has invalid values; fix or delete it and run --resume again."
  return 0
}

# No saved answers (and none in the container): work out what the first run
# chose from the container's config: lxc.idmap lines (idmap mode), else the
# owner of the bind-mounted downloads folder (shift mode), and the time zone.
guess_settings_from_config() {
  local cfg tz id
  cfg=$(pct config "$CTID" 2>/dev/null) || true
  if [[ -z "${TS_TZ:-}" ]]; then
    tz=$(awk '$1 == "timezone:" {print $2}' <<<"$cfg")
    [[ -n "$tz" && "$tz" != host ]] && TZ_NAME=$(pct_timezone "$tz")
    [[ -n "$TZ_NAME" ]] || TZ_NAME=$(host_timezone)
  fi
  DL_HOST_PATH=$(sed -nE "s|^mp[0-9]+: ([^,]+),(.*,)?mp=${GUEST_DOWNLOADS}(,.*)?$|\1|p" <<<"$cfg" | head -n1)
  if [[ -z "${TS_PUID:-}" ]]; then
    id=$(sed -nE 's/^lxc\.idmap: u ([0-9]+) \1 1$/\1/p' <<<"$cfg" | head -n1)
    if [[ -z "$id" && -d "$DL_HOST_PATH" ]]; then id=$(($(stat -c %u "$DL_HOST_PATH") - PVE_ID_OFFSET)); fi
    valid_id "${id:-x}" && PUID=$id
  fi
  if [[ -z "${TS_PGID:-}" ]]; then
    id=$(sed -nE 's/^lxc\.idmap: g ([0-9]+) \1 1$/\1/p' <<<"$cfg" | head -n1)
    if [[ -z "$id" && -d "$DL_HOST_PATH" ]]; then id=$(($(stat -c %g "$DL_HOST_PATH") - PVE_ID_OFFSET)); fi
    valid_id "${id:-x}" && PGID=$id
  fi
  msg_warn "No saved answers for container ${CTID}: using PUID/PGID ${PUID}/${PGID}, time zone ${TZ_NAME}${DL_HOST_PATH:+, downloads ${DL_HOST_PATH}} (worked out from its config)."
  msg_warn "If that is wrong, run --resume again with TS_PUID / TS_PGID / TS_TZ set."
}

write_guest_settings() {
  local f="$TEMP_DIR/settings.env"
  {
    echo "# Written by platforms/proxmox/install.sh on the Proxmox host."
    echo "# Initial .env values for native/install.sh, used only while"
    echo "# ${GUEST_DIR}/.env does not exist yet. Change settings in the env-editor."
    printf 'TZ=%q\n' "$TZ_NAME"
    printf 'PUID=%q\nPGID=%q\n' "$PUID" "$PGID"
    if [[ -n "$DL_HOST_PATH" ]]; then
      printf 'DOWNLOADS_PATH=%q\n' "$GUEST_DOWNLOADS"
      printf 'INCOMPLETE_DOWNLOADS=%q\n' "$GUEST_DOWNLOADS/incomplete"
    fi
  } >"$f"
  pct push "$CTID" "$f" "$GUEST_SETTINGS" --perms 0600
}

# ---------------------------------------------------------------------------
# Guest-side steps (bash snippets; arguments arrive as $1, $2, ...)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2016  # these run in the guest's bash, not here
GUEST_APT='set -Eeuo pipefail
# --error-on=any: plain apt-get update exits 0 even when it fetched nothing.
apt-get update -q --error-on=any
apt-get -y -q -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade
if [ "$1" = 1 ]; then apt-get -y -q install git ca-certificates curl; fi'

# shellcheck disable=SC2016
GUEST_UNPACK='set -Eeuo pipefail
mkdir -p "$2"
tar -xzf "$1" -C "$2" --no-same-owner
rm -f "$1"'

# Install: clone the repository if the container has no checkout yet. An
# existing checkout is left as it is: updates go through
# `native/install.sh self-update` (see do_update), which keeps the live app
# configs under configs/ and never writes into the apps' folders. Same as
# the Incus installer.
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

# Once the stack runs, Gluetun's firewall lets even root in the container
# reach the internet only through the VPN (see native/README.md).
gluetun_hint() {
  if guest systemctl is-active --quiet torrent-gluetun </dev/null 2>/dev/null; then
    echo "  Gluetun is running, so the container reaches the internet only through the VPN. If the VPN is not"
    echo "  connected, stop Gluetun and run this again: pct exec ${CTID} -- systemctl stop torrent-gluetun"
  fi
  return 0
}

prepare_guest_os() {
  local need_git=$1
  msg_info "Updating Debian packages in the container"
  if ! guest_bash "$GUEST_APT" "$need_git" </dev/null >"$TEMP_DIR/apt.log" 2>&1; then
    tail -n 20 "$TEMP_DIR/apt.log" >&2 || true
    die "apt-get failed in the container.
$(gluetun_hint)"
  fi
  msg_ok "Updated Debian packages in the container"
}

# Copy a local checkout in, without git metadata, runtime state or secrets.
push_source_dir() {
  [[ -f "$TS_SOURCE_DIR/native/install.sh" ]] || die "TS_SOURCE_DIR '$TS_SOURCE_DIR' has no native/install.sh."
  msg_info "Copying ${TS_SOURCE_DIR} into the container"
  local tarball="$TEMP_DIR/torrent-stack-src.tar.gz" ex=() f
  # .env.* are secrets too (backups of .env), except the tracked example.
  for f in "$TS_SOURCE_DIR"/.env.*; do
    [[ -e "$f" && "${f##*/}" != .env.example ]] && ex+=("--exclude=./${f##*/}")
  done
  tar -C "$TS_SOURCE_DIR" --owner=0 --group=0 --numeric-owner \
    --no-anchored --exclude=__pycache__ --exclude='*.pyc' \
    --anchored --exclude=./.git --exclude=./configs --exclude=./downloads \
    --exclude=./incomplete --exclude=./.env --exclude=./scripts/env-editor/.venv \
    ${ex[@]+"${ex[@]}"} -czf "$tarball" .
  pct push "$CTID" "$tarball" /root/torrent-stack-src.tar.gz --perms 0600
  guest_bash "$GUEST_UNPACK" /root/torrent-stack-src.tar.gz "$GUEST_DIR" </dev/null
  msg_ok "Copied ${TS_SOURCE_DIR} to ${GUEST_DIR}"
}

sync_source() {
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    push_source_dir
  else
    msg_info "Getting ${REPO_URL} (${TS_REF}) in the container"
    if ! guest_bash "$GUEST_CLONE" "$GUEST_DIR" "$REPO_URL" "$TS_REF" </dev/null >"$TEMP_DIR/git.log" 2>&1; then
      cat "$TEMP_DIR/git.log" >&2 || true
      die "Could not get the repository into ${GUEST_DIR}.
$(gluetun_hint)"
    fi
    msg_ok "$(grep -E '^Source' "$TEMP_DIR/git.log" | tail -n1 || echo "Repository ready in ${GUEST_DIR}")"
  fi
}

# run_native COMMAND [ARGS...]: stream the in-container installer's output
# to the terminal and keep a private copy to find the login in. sed -u
# (unbuffered), not tr: tr holds its output back in 4 KiB blocks when it
# writes to a pipe, so a long install's progress would only show at the end.
run_native() {
  local cmd=$1
  echo
  echo "  ${BOLD}Running native/install.sh $* in container ${CTID}${CL}"
  echo "  ----------------------------------------------------------------"
  if ! guest_bash "$GUEST_NATIVE" "$GUEST_DIR" "$GUEST_SETTINGS" "$@" </dev/null 2>&1 |
    sed -u 's/\r//g' | tee -a "$INSTALL_LOG"; then
    echo "  ----------------------------------------------------------------"
    # Only an install's output can hold the first-run password worth keeping.
    [[ "$cmd" == install ]] && KEEP_LOG=1
    die "native/install.sh ${cmd} failed in container ${CTID}."
  fi
  echo "  ----------------------------------------------------------------"
}

# Best effort: one line per service from native/install.sh status.
show_native_status() {
  echo "  ${BOLD}Service status:${CL}"
  guest_bash "$GUEST_NATIVE" "$GUEST_DIR" "$GUEST_SETTINGS" status </dev/null 2>&1 | sed -u 's/\r//g; s/^/    /' || true
}

# The env-editor login is generated once, on the first install. native/
# install.sh saves it in a root-only file in the guest; repeat that here, or
# else the login/user/password lines of the installer's output.
readonly GUEST_CREDS="/root/torrent-stack.creds"
print_login() {
  local lines="" l from=""
  if guest test -s "$GUEST_CREDS" </dev/null 2>/dev/null; then
    lines=$(guest cat "$GUEST_CREDS" </dev/null 2>/dev/null | grep -v '^[[:space:]]*#') || true
    [[ -n "$lines" ]] && from=" (saved in ${GUEST_CREDS} in the container; delete it once noted)"
  fi
  if [[ -z "$lines" ]]; then
    lines=$(sed -E 's/\x1b\[[0-9;]*[A-Za-z]//g' "$INSTALL_LOG" |
      grep -aiE '(login|user(name)?|password)[[:space:]]*[:=]' | tail -n 4) || true
  fi
  if [[ -n "$lines" ]]; then
    echo "  ${BOLD}First-run login, keep it safe${from}:${CL}"
    while IFS= read -r l; do echo "    $(trim "$l")"; done <<<"$lines"
  else
    echo "  The env-editor login was printed above by the installer (only on its first run)."
    echo "  Lost it? pct exec ${CTID} -- bash ${GUEST_DIR}/native/install.sh reset-login"
  fi
}

set_description() {
  local d
  d="<div align='center'><h3>qbittorrent-vpn-docker</h3>"
  d+="<p>env-editor: <a href='http://${CT_IP}:${ENV_EDITOR_PORT}' target='_blank'>http://${CT_IP}:${ENV_EDITOR_PORT}</a></p>"
  d+="<p>Update: <code>bash ${GUEST_DIR}/native/install.sh self-update</code> inside the container</p></div>"
  pct set "$CTID" --description "$d" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Modes
# ---------------------------------------------------------------------------
do_create() {
  check_root
  check_pve_version
  check_arch
  check_debian13_support
  check_tun
  if [[ "$INTERACTIVE" == 1 ]]; then check_whiptail; fi
  header_info
  load_secret_files
  TZ_NAME="${TS_TZ:-$(host_timezone)}"
  TZ_PCT=$(pct_timezone "$TZ_NAME")
  [[ -n "$TZ_PCT" ]] && TZ_NAME=$TZ_PCT
  [[ -n "$TS_SOURCE_DIR" ]] && { [[ -f "$TS_SOURCE_DIR/native/install.sh" ]] || die "TS_SOURCE_DIR '$TS_SOURCE_DIR' has no native/install.sh."; }
  CTID="${TS_CTID:-}"
  choose_settings
  show_settings
  choose_storages
  resolve_template
  setup_host_wireguard
  prepare_downloads_dir
  create_container
  [[ -n "$ROOT_PW" ]] && ROOT_PW_PENDING=1
  save_host_state
  start_container
  wait_for_boot
  # Password and answers go in as soon as the container runs, before the
  # network wait (the likeliest place for a first run to stop), so that a
  # --resume never has to guess them.
  set_root_password
  write_guest_settings
  wait_for_network
  prepare_guest_os "$([[ -z "$TS_SOURCE_DIR" ]] && echo 1 || echo 0)"
  sync_source
  run_native install
  set_description
  finish
}

finish() {
  KEEP_LOG=0
  UNFINISHED_CTID=""
  # The install is done: the answers kept for --resume are not needed now,
  # and neither is a log an earlier failed run kept (it can hold the
  # first-run password).
  rm -f "$(host_state_file "$CTID")"
  local old_log="/root/torrent-stack-${CTID}-install.log"
  if [[ -f "$old_log" ]]; then
    rm -f -- "$old_log"
    msg_ok "Removed the install log the failed run had kept (${old_log})"
  fi
  echo
  msg_ok "Completed: container ${CTID} (${CT_HOSTNAME:-}) at ${CT_IP}"
  echo
  echo "  ${BOLD}env-editor:${CL} ${BL}http://${CT_IP}:${ENV_EDITOR_PORT}${CL}"
  print_login
  echo
  echo "  Next: open the env-editor, enter your VPN provider details, then Preview and Apply."
  echo "  The VPN apps start once real VPN settings are saved."
  echo "  Update later (on this host): bash -c \"\$(curl -fsSL ${RAW_URL})\" install.sh --update ${CTID}"
  echo "  Remove:                      pct stop ${CTID}; pct destroy ${CTID} --purge 1"
  echo
}

# find_ctid: the container to work on (argument, or the one tagged torrent-stack)
has_stack_tag() {
  grep -qE '^tags:(.*[ ;,])?torrent-stack([ ;,].*)?$' <<<"$(pct config "$1" 2>/dev/null)"
}

find_ctid() {
  if [[ -n "$CTID" ]]; then
    pct status "$CTID" >/dev/null 2>&1 || die "Container ${CTID} does not exist on this node."
  else
    local ids=() id
    while read -r id; do
      if [[ -n "$id" ]] && has_stack_tag "$id"; then ids+=("$id"); fi
    done <<<"$(pct list 2>/dev/null | awk 'NR > 1 {print $1}')"
    case ${#ids[@]} in
    0) die "No container tagged torrent-stack found; pass the container ID: --update CTID" ;;
    1) CTID=${ids[0]} ;;
    *) die "Several containers are tagged torrent-stack (${ids[*]}); pass one: --update CTID" ;;
    esac
  fi
  if ! has_stack_tag "$CTID"; then
    if [[ "${TS_FORCE:-0}" != 1 ]]; then
      if [[ "$INTERACTIVE" == 1 ]]; then
        wt --title "NOT A TORRENT-STACK CONTAINER?" --defaultno --yesno "Container ${CTID} is not tagged torrent-stack. Continue anyway?" 9 70 || exit_script
      else
        die "Container ${CTID} is not tagged torrent-stack (set TS_FORCE=1 to continue anyway)."
      fi
    fi
  fi
  CT_HOSTNAME=$(pct config "$CTID" 2>/dev/null | awk '/^hostname:/ {print $2}')
}

do_update() {
  check_root
  check_pve_version
  find_ctid
  msg_ok "Updating container ${CTID} (${CT_HOSTNAME})"
  start_container
  wait_for_boot
  wait_for_network
  # native/install.sh self-update does the rest, the same way as on Incus
  # and as when run by hand in the container: the new repository version
  # (from git; a TS_SOURCE_DIR copy is pushed first), Debian package
  # upgrades, then the component update.
  local args=()
  if [[ -n "$TS_SOURCE_DIR" ]]; then
    push_source_dir
  else
    guest test -d "$GUEST_DIR/.git" </dev/null 2>/dev/null ||
      die "${GUEST_DIR} in container ${CTID} is a copy (installed with TS_SOURCE_DIR), not a git checkout. Update it with TS_SOURCE_DIR again."
    msg_info "Updating ${GUEST_DIR} from $(guest git -C "$GUEST_DIR" remote get-url origin </dev/null 2>/dev/null || echo '?') in the container"
    [[ "$TS_REF_SET" == 1 ]] && args=(--ref "$TS_REF")
  fi
  run_native self-update ${args[@]+"${args[@]}"}
  show_native_status
  set_description
  msg_ok "Updated container ${CTID}. env-editor: http://${CT_IP}:${ENV_EDITOR_PORT}"
}

do_resume() {
  check_root
  check_pve_version
  [[ -n "$CTID" ]] || die "--resume needs the container ID."
  find_ctid
  msg_ok "Resuming the install in container ${CTID} (${CT_HOSTNAME})"
  UNFINISHED_CTID=$CTID
  # The first run's answers (PUID/PGID, time zone, downloads folder, source
  # and branch) from the host-side file; TS_* variables given now win.
  local have_state=0
  if [[ -n "${TS_TZ:-}" ]]; then
    TZ_NAME=$(pct_timezone "$TS_TZ")
    [[ -n "$TZ_NAME" ]] || TZ_NAME=$TS_TZ
  fi
  if load_host_state; then
    have_state=1
    msg_ok "Using the answers saved in $(host_state_file "$CTID")"
  fi
  start_container
  wait_for_boot
  # Root password: set it now if the first run did not get that far.
  load_secret_files
  if [[ -n "$ROOT_PW" ]]; then
    set_root_password
  elif [[ "$ROOT_PW_PENDING" == 1 && "$INTERACTIVE" == 1 ]]; then
    wt --title "ROOT PASSWORD" --msgbox "The first run stopped before it could set the container's root password. Please type it again." 9 70 || true
    ask_root_password 1
    set_root_password
  elif [[ "$ROOT_PW_PENDING" == 1 ]]; then
    msg_warn "The root password you chose was never set (the first run stopped first)."
    msg_warn "Set it with: pct exec ${CTID} -- passwd   (or pass TS_ROOT_PASSWORD_FILE to --resume)"
    ROOT_PW_PENDING=0
    if ((have_state)); then save_host_state; fi
  fi
  if ! guest test -f "$GUEST_SETTINGS" </dev/null; then
    # The first run stopped before copying its answers into the container.
    ((have_state)) || guess_settings_from_config
    write_guest_settings
  fi
  wait_for_network
  prepare_guest_os "$([[ -z "$TS_SOURCE_DIR" ]] && echo 1 || echo 0)"
  sync_source
  run_native install
  set_description
  finish
}

# Inside the container (no pct): the same update, by native/install.sh.
do_guest_update() {
  check_root
  local args=()
  [[ "$TS_REF_SET" == 1 ]] && args=(--ref "$TS_REF")
  bash "$GUEST_DIR/native/install.sh" self-update ${args[@]+"${args[@]}"}
  bash "$GUEST_DIR/native/install.sh" status || true
}

main() {
  local mode=create unattended="${TS_UNATTENDED:-0}"
  while (($#)); do
    case "$1" in
    --update)
      mode=update
      if [[ "${2:-}" =~ ^[0-9]+$ ]]; then
        CTID=$2
        shift
      fi
      ;;
    --resume)
      mode=resume
      [[ "${2:-}" =~ ^[0-9]+$ ]] || die "--resume needs a container ID."
      CTID=$2
      shift
      ;;
    --unattended | -y) unattended=1 ;;
    -h | --help)
      usage
      exit 0
      ;;
    *) die "Unknown argument '$1' (see --help)." ;;
    esac
    shift
  done

  # The wizard needs a terminal (whiptail reads stdin and, through wt(),
  # draws on stderr). Without one the script runs unattended on TS_*
  # settings. TS_INTERACTIVE=1 forces the wizard (tests use a whiptail
  # stand-in).
  if [[ "$unattended" != 1 && -t 0 && -t 2 ]]; then
    if command -v whiptail >/dev/null 2>&1; then
      INTERACTIVE=1
    elif [[ "$mode" == create ]]; then
      check_whiptail
    fi
  fi
  [[ "${TS_INTERACTIVE:-0}" == 1 ]] && INTERACTIVE=1

  TEMP_DIR=$(mktemp -d)
  INSTALL_LOG="$TEMP_DIR/install.log"
  (umask 077 && : >"$INSTALL_LOG")

  if ! command -v pct >/dev/null 2>&1 && [[ -f "$GUEST_DIR/native/install.sh" ]]; then
    [[ "$mode" == update ]] || die "This looks like the container, not the Proxmox host. Inside the container only --update works."
    do_guest_update
    return
  fi
  case "$mode" in
  create) do_create ;;
  update) do_update ;;
  resume) do_resume ;;
  esac
}

# Run unless sourced (the tests source this file to call single functions).
if ! (return 0 2>/dev/null); then
  main "$@"
fi
