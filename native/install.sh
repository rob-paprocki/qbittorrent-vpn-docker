#!/usr/bin/env bash
#
# native/install.sh: install and manage the torrent stack natively (systemd
# services, no Docker) inside a Debian 13 system container: a Proxmox VE LXC
# or an Incus container. The Proxmox and Incus host scripts in platforms/
# create the container, copy this repo to /opt/torrent-stack and run
#
#     bash /opt/torrent-stack/native/install.sh install
#
# Subcommands (see `install.sh help` and native/README.md):
#   install                 set everything up (safe to re-run)
#   update                  install components whose pin in versions.env changed
#   self-update [--ref REF] get the new repository version, upgrade Debian
#                           packages, then run `update`
#   apply [service...]      re-render configs from .env, restart services
#   status                  one line per service
#   reset-login             new env-editor password (lost login)
#   uninstall [--purge]     remove services, kill switch and programs
#
# Copyright (c) 2025-2026 Rob Paprocki. MIT License (see LICENSE).
# Install steps adapted from community-scripts/ProxmoxVE (MIT,
# https://github.com/community-scripts/ProxmoxVE): install/gluetun-install.sh,
# install/qbittorrent-install.sh, install/jackett-install.sh,
# install/flaresolverr-install.sh and tools/addon/filebrowser-quantum.sh.
# Differences: nothing is sourced or downloaded unpinned at run time, every
# download is checked against native/versions.env, the apps run as an
# unprivileged user behind an nftables kill switch, and FlareSolverr uses
# Debian's chromium instead of Google Chrome.

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TS_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSIONS_FILE="$SCRIPT_DIR/versions.env"
RENDER="$SCRIPT_DIR/lib/render.py"

# These must match native/lib/render.py.
LIB=/usr/local/lib/torrent-stack      # installed programs
ETC=/etc/torrent-stack                # files rendered from .env
STATE=/var/lib/torrent-stack          # what is installed (version stamps)
UNIT_DIR=/etc/systemd/system
KILLSWITCH_TABLE=torrent_killswitch
TORRENT_USER=torrent
GLUETUN_USER=gluetun
ENV_EDITOR_PORT=9191
CREDS_FILE=/root/torrent-stack.creds
RUN_DIR=/run/torrent-stack            # root-only runtime files (lock, snapshots)
LOCK_FILE=$RUN_DIR/install.lock
TMPFILES_CONF=/etc/tmpfiles.d/torrent-stack.conf
# Hash-pinned Python packages (see native/locks/*.txt).
LOCKS="$SCRIPT_DIR/locks"
EE_VENV="$TS_ROOT/scripts/env-editor/.venv"
# pip: give up quickly instead of retrying for many minutes without internet.
PIP_OPTS=(-q --no-cache-dir --disable-pip-version-check --timeout 20 --retries 2 --require-hashes --no-deps)

# Service names match compose.yaml and scripts/env-editor/restart_map.py.
STACK=(gluetun qbittorrent jackett flaresolverr filebrowser)
GATED=(gluetun qbittorrent jackett flaresolverr)
TORRENT_UNITS=(qbittorrent jackett flaresolverr filebrowser)
COMPONENTS=(gluetun qbittorrent vuetorrent jackett flaresolverr filebrowser env-editor)

# Bump a recipe number when the way a component is installed changes, so
# `update` reinstalls it even though its version pin did not change.
declare -A RECIPE=([gluetun]=1 [qbittorrent]=1 [vuetorrent]=1 [jackett]=1
                   [flaresolverr]=2 [filebrowser]=1 [env-editor]=2)

# Debian packages. --no-install-recommends keeps chromium lean, as in
# FlareSolverr's own Docker image.
PACKAGES=(
    ca-certificates curl git wget unzip tzdata procps iproute2  # basics; wget is used by update-qbittorrent.sh
    nftables                     # kill switch
    iptables openvpn             # Gluetun's firewall and OpenVPN
    python3 python3-venv         # env-editor and FlareSolverr
    libicu76                     # Jackett (.NET) needs ICU
    chromium chromium-common chromium-driver xvfb xauth  # FlareSolverr
)

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    C_OK=$'\e[1;92m' C_WARN=$'\e[33m' C_ERR=$'\e[01;31m' C_INFO=$'\e[36m' C_OFF=$'\e[m'
else
    C_OK="" C_WARN="" C_ERR="" C_INFO="" C_OFF=""
fi
msg_info() { printf '%s==>%s %s\n' "$C_INFO" "$C_OFF" "$*"; }
msg_ok()   { printf '%s ok%s %s\n' "$C_OK" "$C_OFF" "$*"; }
msg_warn() { printf '%swarn%s %s\n' "$C_WARN" "$C_OFF" "$*" >&2; }
die()      { printf '%serror%s %s\n' "$C_ERR" "$C_OFF" "$*" >&2; exit 1; }

on_err() {
    printf '%serror%s line %s: %s (exit %s)\n' "$C_ERR" "$C_OFF" "$1" "$2" "$3" >&2
}
trap 'on_err "$LINENO" "$BASH_COMMAND" "$?"' ERR

usage() {
    cat <<EOF
Usage: bash $TS_ROOT/native/install.sh <command>

  install                 Set up or repair everything. Safe to re-run.
  self-update [--ref REF] The way to update: get the new version of this
                          repository (keeping your live app configs), upgrade
                          the container's Debian packages, then run 'update'.
                          --ref switches to another branch or tag;
                          --no-os-upgrade skips the Debian package upgrade.
  update                  Install components whose version in
                          native/versions.env changed and restart only those
                          (self-update runs this for you).
  apply [options] [service...]
                          Re-render configs from .env and restart the named
                          services (default: ${STACK[*]}).
                          Also accepts env-editor.
      --seed=qbit         also re-seed qBittorrent's login from .env
      --no-restart        re-render only
  status                  One line per service: state and version.
  reset-login             Lost the env-editor login: make a new password,
                          print it once and save it in $CREDS_FILE.
  uninstall [--purge]     Remove services, kill switch and programs. Keeps
                          .env, configs/ and downloads unless --purge
                          (--purge never deletes anything outside $TS_ROOT).
  pins                    Maintainers: print sha256 values for versions.env.

Any .env key given as an environment variable on the first install
(for example TZ=Europe/Berlin PUID=1000) is written into the new .env.
EOF
}

# ---------------------------------------------------------------------------
# Basics
# ---------------------------------------------------------------------------
need_root() { [[ "$(id -u)" -eq 0 ]] || die "run as root (inside the container)"; }

check_platform() {
    [[ -d /run/systemd/system ]] || die "systemd is not running here; this installer needs a systemd system container"
    if [[ -r /etc/os-release ]]; then
        local id="" codename=""
        id="$(. /etc/os-release && echo "${ID:-}")"
        codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
        [[ "$id" == debian ]] || die "Debian 13 (trixie) is required, found ID=$id"
        [[ "$codename" == trixie ]] || msg_warn "built for Debian 13 (trixie), found $codename"
    fi
    ARCH="$(dpkg --print-architecture)"
    case "$ARCH" in
        amd64|arm64) ;;
        *) die "unsupported architecture $ARCH (amd64 and arm64 only)" ;;
    esac
    if [[ ! -c /dev/net/tun ]]; then
        msg_warn "/dev/net/tun is missing: Gluetun cannot create the VPN tunnel. Pass the tun device into the container (the platform host scripts do this)."
    elif ! { exec 3<>/dev/net/tun; } 2>/dev/null; then
        # The device node exists but root here cannot open it, for example
        # an Incus unix-char device left as nobody:nogroup, mode 0600.
        msg_warn "/dev/net/tun exists but cannot be opened ($(stat -c '%U:%G %a' /dev/net/tun 2>/dev/null)): Gluetun cannot create the VPN tunnel. Pass it in with root ownership and mode 0666 (the platform host scripts do this)."
    else
        exec 3>&-
    fi
    [[ "$TS_ROOT" == /opt/torrent-stack ]] || msg_warn "repo is at $TS_ROOT, not /opt/torrent-stack; continuing with $TS_ROOT"
}

take_lock() {
    # One installer run at a time (the env-editor calls `apply`). The lock
    # lives in a root-only folder: in a world-writable one such as
    # /run/lock, another user could plant a file or symlink there first.
    # Called from the env-editor (TS_MODE=native), wait at most 5 minutes,
    # less than the env-editor's own 10-minute limit.
    local wait=900
    [[ "${TS_MODE:-}" == native ]] && wait=300
    install -d -m 0700 "$RUN_DIR"
    exec 9>"$LOCK_FILE"
    flock -w "$wait" 9 || die "another native/install.sh run (an update?) holds $LOCK_FILE; try again when it has finished"
}

# versions.env is data, not code: parse KEY=VALUE lines instead of sourcing.
declare -A PIN=()
read_versions() {
    local line key value
    [[ -f "$VERSIONS_FILE" ]] || die "missing $VERSIONS_FILE"
    while IFS= read -r line || [[ -n "$line" ]]; do
        [[ "$line" =~ ^[[:space:]]*(#|$) ]] && continue
        if [[ "$line" =~ ^([A-Z0-9_]+)=([A-Za-z0-9._+-]+)$ ]]; then
            key="${BASH_REMATCH[1]}"; value="${BASH_REMATCH[2]}"
            PIN[$key]="$value"
        else
            die "versions.env: cannot read line: $line"
        fi
    done < "$VERSIONS_FILE"
}
pin() { [[ -n "${PIN[$1]:-}" ]] || die "versions.env has no $1"; printf '%s' "${PIN[$1]}"; }
pin_arch() {  # pin_arch NAME -> value of NAME_AMD64 or NAME_ARM64
    pin "$1_${ARCH^^}"
}

# fetch URL DEST SHA256: download over HTTPS, refuse a checksum mismatch.
fetch() {
    local url="$1" dest="$2" want="$3" got
    curl -fsSL --proto '=https' --tlsv1.2 --retry 3 --retry-delay 2 \
        --connect-timeout 20 -o "$dest" "$url" || die "download failed: $url"
    got="$(sha256sum "$dest" | cut -d' ' -f1)"
    if [[ "$got" != "$want" ]]; then
        rm -f "$dest"
        die "checksum mismatch for $url
    expected $want
    got      $got
Refusing to install it. If you bumped versions.env, update the sha256 too."
    fi
}

# git_fetch REPO TAG COMMIT DEST: shallow clone of a tag, refuse if the
# tag does not point at the pinned commit.
git_fetch() {
    local repo="$1" tag="$2" commit="$3" dest="$4" head
    git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$tag" "$repo" "$dest" \
        || die "git clone failed: $repo $tag"
    head="$(git -C "$dest" rev-parse HEAD)"
    [[ "$head" == "$commit" ]] || die "$repo tag $tag is $head, versions.env pins $commit; refusing to build it"
}

# replace_exact FILE OLD NEW COUNT: literal text replacement that must hit
# exactly COUNT times, so a changed upstream file stops the install loudly.
replace_exact() {
    python3 -I - "$@" <<'PY'
import sys
path, old, new, count = sys.argv[1], sys.argv[2], sys.argv[3], int(sys.argv[4])
text = open(path, encoding="utf-8").read()
found = text.count(old)
if found != count:
    sys.exit(f"{path}: expected {count} x {old!r}, found {found}; upstream changed, update native/install.sh")
open(path, "w", encoding="utf-8").write(text.replace(old, new))
PY
}

sha() { sha256sum "$1" | cut -c1-16; }

# Run a command as the torrent user. Used for everything inside the app
# config folders, which that user owns: if an exploited app planted a
# symlink there, the command could still only reach what the app itself can.
as_torrent() {
    setpriv --reuid="${S[puid]}" --regid="${S[pgid]}" --clear-groups -- "$@"
}

primary_ip() {
    # The container's LAN address: skip Gluetun's tunnel, which also has a
    # "global" address once Gluetun runs.
    ip -4 -o addr show scope global 2>/dev/null | awk '$2 != "tun0" {split($4, a, "/"); print a[1]; exit}'
}

# ---------------------------------------------------------------------------
# .env and the resolved settings
# ---------------------------------------------------------------------------
create_env() {
    [[ -f "$TS_ROOT/.env" ]] && return 0
    msg_info "Creating .env from .env.example"
    # Any .env key present in this script's environment wins (the host
    # scripts pass TZ, PUID, PGID, DOWNLOADS_PATH this way).
    python3 -I - "$TS_ROOT" <<'PY'
import os, sys
from pathlib import Path
root = Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts" / "env-editor"))
import env_io
example = env_io.parse_env(root / ".env.example")
values = {}
for key in example:
    if key in os.environ:
        values[key] = os.environ[key]
        print(f"    {key} set from the environment")
env_io.write_env(root / ".env", root / ".env.example", values)
PY
    chmod 0600 "$TS_ROOT/.env"
}

# Fill S[...] from `render.py info` (which also validates .env).
declare -A S=()
load_settings() {
    local json line
    json="$(python3 -I "$RENDER" --root "$TS_ROOT" info)" || die "fix .env and try again"
    S=()
    while IFS='=' read -r key value; do
        S[$key]="$value"
    done < <(printf '%s' "$json" | python3 -I -c '
import json, sys
d = json.load(sys.stdin)
for k in ("puid", "pgid", "tz", "config_root", "downloads_root", "incomplete_root"):
    print(f"{k}={d[k]}")
for k, v in d["ports"].items():
    print(f"port_{k}={v}")
print("vpn_configured=" + ("yes" if d["vpn_configured"] else "no"))
print("vpn_missing=" + " ".join(d["vpn_missing"]))
print("qbit_configured=" + ("yes" if d["qbit_configured"] else "no"))
')
    [[ -n "${S[puid]:-}" ]] || die "could not read settings from .env"
}

# ---------------------------------------------------------------------------
# Packages, users, folders, host networking bits
# ---------------------------------------------------------------------------
ensure_packages() {
    local missing=() p
    for p in "${PACKAGES[@]}"; do
        dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null | grep -qx installed || missing+=("$p")
    done
    [[ ${#missing[@]} -eq 0 ]] && return 0
    msg_info "Installing packages: ${missing[*]}"
    export DEBIAN_FRONTEND=noninteractive
    # --error-on=any: plain `apt-get update` exits 0 even when it could not
    # fetch a single package list (no network, or Gluetun's firewall).
    if ! apt-get update -qq --error-on=any; then
        if systemctl is-active --quiet torrent-gluetun; then
            die "apt-get update failed. While Gluetun runs, this container only reaches the internet through the VPN, and it may not be connected.
Stop it first:  systemctl stop torrent-gluetun   then re-run this command."
        fi
        die "apt-get update failed (is the network up?)"
    fi
    apt-get install -y -qq --no-install-recommends -o Dpkg::Options::=--force-confold "${missing[@]}" >/dev/null \
        || die "apt-get install failed"
    # Remember what this installer added, so `uninstall` can tell you.
    install -d -m 0700 "$STATE"
    printf '%s\n' "${missing[@]}" >> "$STATE/packages-added"
    msg_ok "Packages installed"
}

# Sets IDS_CHANGED=1 when the torrent user's uid or gid had to change.
IDS_CHANGED=""
ensure_users() {
    local puid="${S[puid]}" pgid="${S[pgid]}" changed="" cur owner
    # Group torrent with gid PGID.
    if cur="$(getent group "$TORRENT_USER" | cut -d: -f3)" && [[ -n "$cur" ]]; then
        if [[ "$cur" != "$pgid" ]]; then
            owner="$(getent group "$pgid" | cut -d: -f1 || true)"
            [[ -z "$owner" ]] || die "PGID $pgid already belongs to group '$owner'; choose another PGID"
            groupmod -g "$pgid" "$TORRENT_USER"; changed=1
        fi
    else
        owner="$(getent group "$pgid" | cut -d: -f1 || true)"
        [[ -z "$owner" ]] || die "PGID $pgid already belongs to group '$owner'; choose another PGID or remove that group"
        groupadd -g "$pgid" "$TORRENT_USER"
    fi
    # User torrent with uid PUID. No login, no home: each service sets HOME.
    if cur="$(id -u "$TORRENT_USER" 2>/dev/null)"; then
        if [[ "$cur" != "$puid" ]]; then
            owner="$(getent passwd "$puid" | cut -d: -f1 || true)"
            [[ -z "$owner" ]] || die "PUID $puid already belongs to user '$owner'; choose another PUID"
            usermod -u "$puid" "$TORRENT_USER"; changed=1
        fi
        if [[ "$(id -g "$TORRENT_USER")" != "$pgid" ]]; then
            usermod -g "$TORRENT_USER" "$TORRENT_USER"
        fi
    else
        owner="$(getent passwd "$puid" | cut -d: -f1 || true)"
        [[ -z "$owner" ]] || die "PUID $puid already belongs to user '$owner'; choose another PUID or remove that user"
        useradd -u "$puid" -g "$TORRENT_USER" -M -d /nonexistent -s /usr/sbin/nologin \
            -c "torrent-stack apps" "$TORRENT_USER"
    fi
    # Gluetun's OpenVPN drops to this user. It must differ from the torrent
    # user, or the kill switch would block the VPN connection itself.
    if ! id -u "$GLUETUN_USER" >/dev/null 2>&1; then
        useradd --system --user-group -M -d /nonexistent -s /usr/sbin/nologin \
            -c "torrent-stack Gluetun/OpenVPN" "$GLUETUN_USER"
    fi
    [[ "$(id -u "$GLUETUN_USER")" != "$puid" ]] || die "PUID $puid is the gluetun system user's uid; choose another PUID"
    [[ "$(id -g "$GLUETUN_USER")" != "$pgid" ]] || die "PGID $pgid is the gluetun system group's gid; choose another PGID"
    IDS_CHANGED="$changed"
}

# usermod refuses to renumber a user whose processes are running, so stop
# the apps first when PUID/PGID in .env no longer match the torrent user.
stop_if_ids_change() {
    local uid gid
    uid="$(id -u "$TORRENT_USER" 2>/dev/null || true)"
    gid="$(getent group "$TORRENT_USER" | cut -d: -f3 || true)"
    if [[ -n "$uid" && ( "$uid" != "${S[puid]}" || "$gid" != "${S[pgid]}" ) ]]; then
        stop_units "${TORRENT_UNITS[@]}"
    fi
    ensure_users
}

ensure_dirs() {
    local cfg="${S[config_root]}" app
    install -d -m 0755 "$LIB" "$ETC" "$cfg"
    install -d -m 0700 "$STATE" "$STATE/components" "$cfg/gluetun" "$TS_ROOT/configs/env-editor" "$RUN_DIR"
    # One folder per app, directly in CONFIG_PATH. render.py has checked that
    # only root can change CONFIG_PATH and the folders above it, so these
    # paths cannot have been swapped for symlinks by the app user.
    for app in qbittorrent jackett flaresolverr filebrowser; do
        [[ ! -L "$cfg/$app" ]] || die "$cfg/$app is a symlink; replace it with a real folder"
        install -d -m 0750 -o "$TORRENT_USER" -g "$TORRENT_USER" "$cfg/$app"
    done
    # Everything below those belongs to the app user, so it is created as
    # that user (root never follows a path the app user controls).
    as_torrent mkdir -p "$cfg/qbittorrent/qBittorrent" "$cfg/jackett/Jackett"
    fix_ownership
    ensure_data_dir "${S[downloads_root]}"
    ensure_data_dir "${S[incomplete_root]}"
}

# ensure_data_dir DIR: make sure a downloads folder exists and belongs to
# the torrent user. When the folder it sits in belongs to the torrent user
# (as ./downloads/incomplete does), the work is done as that user; otherwise
# root creates it and hands it over. Never recursive: a downloads folder can
# be huge, or a mount.
ensure_data_dir() {
    local d="$1" parent
    parent="$d"
    while [[ ! -e "$parent" && ! -L "$parent" ]]; do parent="$(dirname "$parent")"; done
    if [[ "$parent" != "$d" ]]; then
        # Missing: create it.
        if as_torrent test -w "$parent"; then
            as_torrent mkdir -p -m 0775 "$d" || msg_warn "could not create $d"
        else
            install -d -m 0775 -o "$TORRENT_USER" -g "$TORRENT_USER" "$d" || msg_warn "could not create $d"
        fi
        return 0
    fi
    [[ "$(stat -L -c %u "$d" 2>/dev/null)" == "${S[puid]}" ]] && return 0
    if as_torrent test -w "$(dirname "$d")"; then
        # The app user could swap this path for a symlink; leave it alone.
        msg_warn "$d is not owned by uid ${S[puid]}; qBittorrent may not be able to write there"
    else
        chown "$TORRENT_USER:$TORRENT_USER" "$d" 2>/dev/null \
            || msg_warn "$d is not owned by uid ${S[puid]} and chown failed; qBittorrent may not be able to write there"
    fi
}

# The apps' config folders belong to the torrent user. Anything inside that
# is not (left from an earlier PUID/PGID, or copied in by hand) is handed
# over. chown -h changes a symlink itself, never what it points to, and
# files with more than one hard link are skipped: such a link could point
# at someone else's file.
fix_ownership() {
    local cfg="${S[config_root]}" app
    for app in qbittorrent jackett flaresolverr filebrowser; do
        [[ -d "$cfg/$app" && ! -L "$cfg/$app" ]] || continue
        find "$cfg/$app" \( ! -user "${S[puid]}" -o ! -group "${S[pgid]}" \) \
            \( -type d -o -type l -o -links 1 \) -exec chown -h "${S[puid]}:${S[pgid]}" {} +
        if [[ -n "$(find "$cfg/$app" -type f -links +1 \( ! -user "${S[puid]}" -o ! -group "${S[pgid]}" \) -print -quit)" ]]; then
            msg_warn "left hard-linked files in $cfg/$app that the torrent user does not own alone"
        fi
    done
}

# Gluetun's DNS server listens on port 53 of every address. On images that
# use systemd-resolved (Incus' Debian images do) the resolved stub listener
# on 127.0.0.53:53 blocks that, so turn the stub off and point
# /etc/resolv.conf at resolved's list of real upstream servers. The
# container keeps resolving through resolved's upstreams; only the
# 127.0.0.53 shortcut goes away. Undone by `uninstall`.
configure_resolver() {
    local dropin=/etc/systemd/resolved.conf.d/90-torrent-stack.conf link
    if systemctl is-active --quiet systemd-resolved; then
        if [[ ! -f "$dropin" ]]; then
            msg_info "Turning off systemd-resolved's stub listener (frees port 53 for Gluetun's DNS)"
            install -d -m 0755 /etc/systemd/resolved.conf.d
            printf '# Added by torrent-stack native/install.sh: Gluetun needs port 53.\n[Resolve]\nDNSStubListener=no\n' > "$dropin"
            systemctl restart systemd-resolved
        fi
        link="$(readlink /etc/resolv.conf || true)"
        if [[ "$link" == *stub-resolv.conf ]]; then
            printf '%s\n' "$link" > "$STATE/resolv.conf.link"
            ln -sfn /run/systemd/resolve/resolv.conf /etc/resolv.conf
        fi
    fi
    if ss -Hlnu 'sport = :53' 2>/dev/null | awk '{print $4}' | grep -Eq '^(0\.0\.0\.0|127\.0\.0\.1|\*|\[::\]):53$'; then
        msg_warn "something already listens on port 53: Gluetun's DNS server will fail. Check: ss -lnup 'sport = :53'"
    fi
}

# compose.yaml disables IPv6 in Gluetun's network namespace. Here the whole
# container is that namespace, so disable it for the container. The kill
# switch blocks the torrent user's IPv6 outside the tunnel regardless.
configure_ipv6() {
    local f=/etc/sysctl.d/90-torrent-stack.conf
    if [[ ! -f "$f" ]]; then
        printf '# Added by torrent-stack native/install.sh (same as compose.yaml).\nnet.ipv6.conf.all.disable_ipv6 = 1\nnet.ipv6.conf.default.disable_ipv6 = 1\n' > "$f"
    fi
    if [[ -d /proc/sys/net/ipv6 ]]; then
        sysctl -q -p "$f" || msg_warn "could not disable IPv6 (the kill switch still blocks the torrent user's IPv6 outside the VPN)"
    fi
}

# ---------------------------------------------------------------------------
# Components: fingerprints, staging, swapping
# ---------------------------------------------------------------------------
fingerprint() {
    local c="$1" r="r${RECIPE[$1]}"
    case "$c" in
        gluetun)      echo "$(pin GLUETUN_VERSION) $(pin GLUETUN_COMMIT) go$(pin GO_VERSION) $ARCH $r" ;;
        qbittorrent)  echo "$(pin QBITTORRENT_RELEASE) $(pin_arch QBITTORRENT_SHA256) $r" ;;
        vuetorrent)   echo "$(pin VUETORRENT_VERSION) $(pin VUETORRENT_SHA256) $r" ;;
        jackett)      echo "$(pin JACKETT_VERSION) $(pin_arch JACKETT_SHA256) $r" ;;
        flaresolverr) echo "$(pin FLARESOLVERR_VERSION) $(pin FLARESOLVERR_COMMIT) lock-$(sha "$LOCKS/flaresolverr.txt")-$(sha "$LOCKS/build-tools.txt") $r" ;;
        filebrowser)  echo "$(pin FILEBROWSER_VERSION) $(pin_arch FILEBROWSER_SHA256) $r" ;;
        env-editor)
            # The env-editor ships with this repo: its "version" is a hash of
            # its code, so `update` after a git pull restarts it when needed.
            echo "local-$(cd "$TS_ROOT/scripts/env-editor" && find . -path ./.venv -prune -o -path ./.venv.new -prune -o -path ./__pycache__ -prune -o -type f -print | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -c1-16) lock-$(sha "$LOCKS/env-editor.txt") $r" ;;
    esac
}
installed_fingerprint() { cat "$STATE/components/$1" 2>/dev/null || true; }
component_present() {
    case "$1" in
        gluetun)      [[ -x "$LIB/gluetun/gluetun" && -f "$LIB/gluetun/image-defaults.env" ]] ;;
        qbittorrent)  [[ -x "$LIB/qbittorrent/qbittorrent-nox" ]] ;;
        vuetorrent)   [[ -f "$LIB/vuetorrent/public/index.html" ]] ;;
        jackett)      [[ -x "$LIB/jackett/jackett" ]] ;;
        flaresolverr) [[ -x "$LIB/flaresolverr/venv/bin/python" && -f "$LIB/flaresolverr/src/flaresolverr.py" ]] ;;
        filebrowser)  [[ -x "$LIB/filebrowser/filebrowser" ]] ;;
        env-editor)   ! venv_needs_build ;;
    esac
}
# The env-editor venv is (re)built when it is missing or was built from
# another lock file. The stamp is written only after pip succeeded.
venv_needs_build() {
    [[ -x "$EE_VENV/bin/python" && "$(cat "$EE_VENV/.torrent-stack-lock" 2>/dev/null)" == "$(sha "$LOCKS/env-editor.txt")" ]] && return 1
    return 0
}
needs_install() {
    [[ "$(fingerprint "$1")" != "$(installed_fingerprint "$1")" ]] || ! component_present "$1"
}
# The service to restart when a component changes ("" = none needed).
service_of() {
    case "$1" in
        vuetorrent) echo "" ;;   # static files, served fresh on each request
        *) echo "$1" ;;
    esac
}

STAGE="$LIB/.staging"
BUILD=""
cleanup_build() { [[ -n "$BUILD" && -d "$BUILD" ]] && rm -rf "$BUILD"; BUILD=""; }

stage_gluetun() {
    local v c go_url out="$STAGE/gluetun"
    v="$(pin GLUETUN_VERSION)"; c="$(pin GLUETUN_COMMIT)"
    BUILD="$(mktemp -d /var/tmp/torrent-stack-build.XXXXXX)"
    msg_info "Building Gluetun $v from source with Go $(pin GO_VERSION) (takes a minute or two)"
    go_url="https://go.dev/dl/go$(pin GO_VERSION).linux-$ARCH.tar.gz"
    fetch "$go_url" "$BUILD/go.tar.gz" "$(pin_arch GO_SHA256)"
    tar -C "$BUILD" -xzf "$BUILD/go.tar.gz"
    git_fetch https://github.com/qdm12/gluetun "$v" "$c" "$BUILD/src"
    # Gluetun prints the Alpine version at startup and exits if
    # /etc/alpine-release is missing. Creating that file on Debian would make
    # other tools think this is Alpine (community-scripts does that), so the
    # binary is pointed at its own file instead.
    replace_exact "$BUILD/src/internal/alpine/alpine.go" \
        '"/etc/alpine-release"' "\"$LIB/gluetun/alpine-release\"" 1
    mkdir -p "$out/bin"
    (
        cd "$BUILD/src"
        export PATH="$BUILD/go/bin:$PATH" GOTOOLCHAIN=local CGO_ENABLED=0 \
               GOFLAGS=-mod=readonly GOPATH="$BUILD/gopath" \
               GOMODCACHE="$BUILD/gomodcache" GOCACHE="$BUILD/gocache"
        # Same flags as Gluetun's Dockerfile. Modules are checked against
        # go.sum and the Go checksum database.
        go build -trimpath \
            -ldflags="-s -w -X 'main.version=$v' -X 'main.commit=$c' -X 'main.created=$(git log -1 --format=%cI)'" \
            -o "$out/gluetun" ./cmd/gluetun/ > "$BUILD/build.log" 2>&1
    ) || { tail -n 30 "$BUILD/build.log" >&2; die "Gluetun build failed (last lines above)"; }
    # Gluetun's defaults live in its Dockerfile's ENV block; without them
    # it crashes outside Docker. Extract them for this exact version.
    python3 -I "$SCRIPT_DIR/lib/dockerfile_env.py" "$BUILD/src/Dockerfile" > "$out/image-defaults.env" \
        || die "could not read Gluetun's defaults from its Dockerfile"
    printf 'not Alpine: Debian %s (torrent-stack native build)\n' "$(cat /etc/debian_version)" > "$out/alpine-release"
    # Gluetun runs OpenVPN as "openvpn2.6"; Debian 13 ships OpenVPN 2.6.
    ln -s /usr/sbin/openvpn "$out/bin/openvpn2.6"
    cleanup_build
}

stage_qbittorrent() {
    local name out="$STAGE/qbittorrent"
    case "$ARCH" in amd64) name=x86_64-qbittorrent-nox ;; arm64) name=aarch64-qbittorrent-nox ;; esac
    msg_info "Downloading qBittorrent-nox $(pin QBITTORRENT_RELEASE)"
    mkdir -p "$out"
    fetch "https://github.com/userdocs/qbittorrent-nox-static/releases/download/$(pin QBITTORRENT_RELEASE)/$name" \
        "$out/qbittorrent-nox" "$(pin_arch QBITTORRENT_SHA256)"
    chmod 0755 "$out/qbittorrent-nox"
}

stage_vuetorrent() {
    local tmp
    msg_info "Downloading VueTorrent $(pin VUETORRENT_VERSION)"
    tmp="$(mktemp -d "$STAGE/tmp.XXXXXX")"
    fetch "https://github.com/VueTorrent/VueTorrent/releases/download/$(pin VUETORRENT_VERSION)/vuetorrent.zip" \
        "$tmp/vuetorrent.zip" "$(pin VUETORRENT_SHA256)"
    unzip -q "$tmp/vuetorrent.zip" -d "$tmp/x"
    [[ -f "$tmp/x/vuetorrent/public/index.html" ]] || die "unexpected VueTorrent archive layout"
    mv "$tmp/x/vuetorrent" "$STAGE/vuetorrent"
    chmod -R u=rwX,go=rX "$STAGE/vuetorrent"
    rm -rf "$tmp"
}

stage_jackett() {
    local name tmp
    case "$ARCH" in amd64) name=Jackett.Binaries.LinuxAMDx64.tar.gz ;; arm64) name=Jackett.Binaries.LinuxARM64.tar.gz ;; esac
    msg_info "Downloading Jackett $(pin JACKETT_VERSION)"
    tmp="$(mktemp -d "$STAGE/tmp.XXXXXX")"
    fetch "https://github.com/Jackett/Jackett/releases/download/$(pin JACKETT_VERSION)/$name" \
        "$tmp/jackett.tar.gz" "$(pin_arch JACKETT_SHA256)"
    tar -C "$tmp" -xzf "$tmp/jackett.tar.gz"
    [[ -x "$tmp/Jackett/jackett" ]] || die "unexpected Jackett archive layout"
    mv "$tmp/Jackett" "$STAGE/jackett"
    chown -R root:root "$STAGE/jackett"
    rm -rf "$tmp"
}

stage_flaresolverr() {
    local out="$STAGE/flaresolverr"
    BUILD="$(mktemp -d /var/tmp/torrent-stack-build.XXXXXX)"
    msg_info "Installing FlareSolverr $(pin FLARESOLVERR_VERSION) from source (Python packages from its requirements.txt)"
    git_fetch https://github.com/FlareSolverr/FlareSolverr "$(pin FLARESOLVERR_VERSION)" \
        "$(pin FLARESOLVERR_COMMIT)" "$BUILD/src"
    # FlareSolverr looks for its patchable chromedriver at /app/chromedriver
    # (its Docker image's path). Point it at a folder this install owns
    # rather than creating /app; lib/flaresolverr-prestart.sh fills it.
    replace_exact "$BUILD/src/src/utils.py" '"/app/chromedriver"' \
        "\"$LIB/flaresolverr/chromedriver\"" 2
    check_lock_covers "$BUILD/src/requirements.txt" "$LOCKS/flaresolverr.txt"
    mkdir -p "$out"
    cp -a "$BUILD/src/src" "$out/src"
    cp "$BUILD/src/package.json" "$BUILD/src/requirements.txt" "$out/"
    python3 -m venv "$out/venv"
    # Every package, dependencies included, comes from the lock file and is
    # checked against its sha256. One of them (func-timeout) exists only as
    # source; it is built with the pinned setuptools instead of one pip would
    # fetch unchecked.
    "$out/venv/bin/python" -m pip install "${PIP_OPTS[@]}" --only-binary=:all: \
        -r "$LOCKS/build-tools.txt" || die "pip install of setuptools (for FlareSolverr) failed"
    "$out/venv/bin/python" -m pip install "${PIP_OPTS[@]}" --no-build-isolation \
        -r "$LOCKS/flaresolverr.txt" || die "pip install for FlareSolverr failed"
    chown -R root:root "$out"
    cleanup_build
}

stage_filebrowser() {
    local name out="$STAGE/filebrowser"
    case "$ARCH" in amd64) name=linux-amd64-filebrowser ;; arm64) name=linux-arm64-filebrowser ;; esac
    msg_info "Downloading FileBrowser Quantum $(pin FILEBROWSER_VERSION)"
    mkdir -p "$out"
    fetch "https://github.com/gtsteffaniak/filebrowser/releases/download/$(pin FILEBROWSER_VERSION)/$name" \
        "$out/filebrowser" "$(pin_arch FILEBROWSER_SHA256)"
    chmod 0755 "$out/filebrowser"
}

# check_lock_covers REQUIREMENTS LOCK: every name==version pinned in
# FlareSolverr's own requirements.txt must be pinned the same in our lock
# file. Catches a FlareSolverr bump without a regenerated lock file.
check_lock_covers() {
    python3 -I - "$1" "$2" <<'PY' || die "native/locks/flaresolverr.txt does not match FlareSolverr $(pin FLARESOLVERR_VERSION)'s requirements.txt; regenerate it (native/README.md, 'How update works')"
import re, sys
def pins(path):
    out = {}
    for line in open(path, encoding="utf-8"):
        line = line.split("#", 1)[0].strip()
        if 'platform_system == "Windows"' in line:
            continue  # FlareSolverr's Windows-only packages
        m = re.match(r"([A-Za-z0-9_.-]+)==([^\s;\\]+)", line)
        if m:
            out[re.sub(r"[-_.]+", "-", m.group(1)).lower()] = m.group(2)
    return out
want, have = pins(sys.argv[1]), pins(sys.argv[2])
bad = [f"{k}=={v} (lock: {have.get(k, 'missing')})" for k, v in want.items() if have.get(k) != v]
if bad:
    sys.exit("not in the lock file: " + ", ".join(bad))
PY
}

# The env-editor's venv: built next to the old one and swapped in only once
# pip has succeeded, so a failed build (no internet, say) leaves the
# working venv in place. Packages come from native/locks/env-editor.txt.
build_env_editor_venv() {
    local new="$EE_VENV.new"
    rm -rf "$new" "$EE_VENV.old"
    python3 -m venv "$new" || die "could not create a Python venv (is python3-venv installed?)"
    if ! "$new/bin/python" -m pip install "${PIP_OPTS[@]}" --only-binary=:all: -r "$LOCKS/env-editor.txt"; then
        rm -rf "$new"
        die "env-editor venv build failed; the old venv (if any) is unchanged"
    fi
    sha "$LOCKS/env-editor.txt" > "$new/.torrent-stack-lock"
    # scripts/setup.sh's own stamp, so a Docker-style run of setup.sh in
    # this checkout sees a finished venv too.
    sha256sum "$TS_ROOT/scripts/env-editor/requirements.txt" | cut -d' ' -f1 > "$new/.requirements.sha256"
    if [[ -e "$EE_VENV" ]]; then mv "$EE_VENV" "$EE_VENV.old"; fi
    mv "$new" "$EE_VENV"
    rm -rf "$EE_VENV.old"
}

swap_in() {  # move a staged component into place
    local c="$1"
    rm -rf "${LIB:?}/$c.old"
    if [[ -e "$LIB/$c" ]]; then mv "$LIB/$c" "$LIB/$c.old"; fi
    mv "$STAGE/$c" "$LIB/$c"
    rm -rf "${LIB:?}/$c.old"
}

check_internet() {
    curl -fsS -o /dev/null --max-time 15 https://github.com && return 0
    if systemctl is-active --quiet torrent-gluetun; then
        die "no internet access. While Gluetun runs, this container only reaches the internet through the VPN, and the VPN is not connected.
Stop it first:  systemctl stop torrent-gluetun   then re-run this command."
    fi
    die "no internet access from this container (https://github.com)"
}

# Download/build every component whose pin changed, then stop the affected
# services, swap the new files in, and record what is installed.
# Sets RESTART_AFTER to the services that need (re)starting.
RESTART_AFTER=()
INSTALLED=()
converge_components() {
    local c todo=() svc
    for c in "${COMPONENTS[@]}"; do
        needs_install "$c" && todo+=("$c")
    done
    [[ ${#todo[@]} -eq 0 ]] && { msg_ok "All components match native/versions.env"; return 0; }
    msg_info "To install: ${todo[*]}"
    # Downloads are needed unless the only change is the env-editor's own
    # code (a restart is enough for that).
    if [[ " ${todo[*]} " != " env-editor " ]] || venv_needs_build; then
        check_internet
    fi

    rm -rf "$STAGE"; mkdir -p "$STAGE"
    # A failed download or build leaves the installed version untouched;
    # only the half-finished staging copy is thrown away.
    trap 'cleanup_build; rm -rf "$STAGE"' EXIT
    for c in "${todo[@]}"; do
        [[ "$c" == env-editor ]] && continue
        "stage_${c//-/_}"
    done
    for c in "${todo[@]}"; do
        svc="$(service_of "$c")"
        if [[ "$c" == env-editor ]]; then
            if venv_needs_build; then
                msg_info "Building the env-editor's Python venv (native/locks/env-editor.txt)"
                build_env_editor_venv
            fi
        else
            if [[ -n "$svc" ]] && systemctl is-active --quiet "torrent-$svc"; then
                systemctl stop "torrent-$svc"
            fi
            swap_in "$c"
        fi
        fingerprint "$c" > "$STATE/components/$c"
        msg_ok "Installed $c ($(cut -d' ' -f1 "$STATE/components/$c"))"
        INSTALLED+=("$c")
        [[ -n "$svc" ]] && RESTART_AFTER+=("$svc")
    done
    rm -rf "$STAGE"
    return 0
}

# ---------------------------------------------------------------------------
# Seeding (scripts/env-editor/seed_configs.py) and first-run credentials
# ---------------------------------------------------------------------------
venv_python() { printf '%s' "$TS_ROOT/scripts/env-editor/.venv/bin/python"; }

ensure_search_plugin() {
    # The pinned Jackett search plugin for qBittorrent. Installed only when
    # missing, so the seeder does not fetch the unpinned master copy.
    local dest="${S[config_root]}/qbittorrent/qBittorrent/nova3/engines/jackett.py" tmp
    as_torrent test -e "$dest" && return 0
    tmp="$(mktemp)"
    fetch "https://raw.githubusercontent.com/qbittorrent/search-plugins/$(pin QBIT_SEARCH_PLUGINS_COMMIT)/nova3/engines/jackett.py" \
        "$tmp" "$(pin QBIT_JACKETT_PLUGIN_SHA256)"
    # Written by the torrent user (it owns that folder); root only reads
    # the downloaded file and passes it on stdin.
    # shellcheck disable=SC2016  # expanded by the inner shell
    as_torrent sh -c 'umask 022; mkdir -p "$(dirname "$1")" && cat > "$1.new" && mv -f "$1.new" "$1"' sh "$dest" < "$tmp" \
        || die "could not install the qBittorrent search plugin"
    rm -f "$tmp"
}

run_seeders() {  # run_seeders "" | qbit
    # The seeder reads .env as root, then switches to the torrent user before
    # it touches any config file (--as-user). The time limit guards against
    # a planted FIFO or similar making it hang while holding the lock.
    timeout 300 "$(venv_python)" -I "$TS_ROOT/scripts/env-editor/seed_configs.py" \
        --env "$TS_ROOT/.env" --config-root "${S[config_root]}" --only "$1" \
        --as-user "${S[puid]}:${S[pgid]}" \
        || die "seeding configs failed (see the message above)"
}

qbit_seeded() {
    # qBittorrent before 5.3: [Preferences] WebUI\Password_PBKDF2=...
    # 5.3 and later:          [WebUI] Password_PBKDF2=...
    as_torrent grep -qE '^(WebUI\\)?Password_PBKDF2=' "${S[config_root]}/qbittorrent/qBittorrent/qBittorrent.conf" 2>/dev/null
}

FIRST_RUN_PASSWORD=""
create_editor_credentials() {
    local creds="$TS_ROOT/configs/env-editor/credentials.json" pw tmp
    [[ -f "$creds" ]] && return 0
    # Created here rather than by the env-editor itself so the password is
    # shown once on this terminal and never lands in the systemd journal.
    pw="$(python3 -I -c 'import secrets; print(secrets.token_urlsafe(18))')"
    tmp="$(mktemp)"
    printf '%s' "$pw" | "$(venv_python)" -I -c '
import bcrypt, json, sys
pw = sys.stdin.buffer.read()
print(json.dumps({"username": "admin",
                  "password_hash": bcrypt.hashpw(pw, bcrypt.gensalt()).decode("ascii")}, indent=2))
' > "$tmp"
    install -m 0600 "$tmp" "$creds"
    rm -f "$tmp"
    # FileBrowser uses the same password until real qBittorrent
    # credentials are set (see render.py).
    (umask 077; printf '%s\n' "$pw" > "$ETC/bootstrap-password")
    FIRST_RUN_PASSWORD="$pw"
}

write_creds_file() {
    local ip="$1"
    [[ -n "$FIRST_RUN_PASSWORD" ]] || return 0
    (umask 077; cat > "$CREDS_FILE" <<EOF
# torrent-stack first-run logins, created $(date -u +%Y-%m-%dT%H:%MZ).
# Note them somewhere safe, then delete this file.
env-editor:  http://$ip:$ENV_EDITOR_PORT   user: admin   password: $FIRST_RUN_PASSWORD
FileBrowser: http://$ip:${S[port_filebrowser]}   user: admin   password: $FIRST_RUN_PASSWORD
  (until you set a real qBittorrent login; then admin uses QBITTORRENT_PASSWORD)
EOF
    )
}

# ---------------------------------------------------------------------------
# Rendering and systemd
# ---------------------------------------------------------------------------
# render_changed [--dry-run] -> prints the services whose files changed,
# one per line ("_units" = some unit file changed).
render_changed() {
    python3 -I "$RENDER" --root "$TS_ROOT" write "$@" \
        | python3 -I -c 'import json, sys; print("\n".join(json.load(sys.stdin)["changed"]))' \
        || die "rendering configs failed"
}

unit_active() { systemctl is-active --quiet "torrent-$1"; }

reload_killswitch() {
    if systemctl is-active --quiet torrent-killswitch; then
        systemctl reload torrent-killswitch
    else
        systemctl start torrent-killswitch
    fi
    nft list table inet "$KILLSWITCH_TABLE" >/dev/null 2>&1 \
        || die "the kill switch did not load; not starting any app (journalctl -u torrent-killswitch)"
}

enable_units() {
    systemctl enable -q torrent-killswitch.service torrent-killswitch-check.timer \
        torrent-env-editor.service "${STACK[@]/#/torrent-}"
}

# Start units in dependency order. Gated units are skipped by systemd while
# the VPN settings are placeholders (ConditionPathExists).
start_units() {
    local svc started=()
    for svc in gluetun qbittorrent jackett flaresolverr filebrowser env-editor; do
        [[ " $* " == *" $svc "* ]] || continue
        if systemctl start "torrent-$svc"; then
            started+=("$svc")
        else
            msg_warn "torrent-$svc did not start: journalctl -u torrent-$svc"
            START_FAILED=1
        fi
    done
    [[ ${#started[@]} -gt 0 ]] && verify_running "${started[@]}"
    return 0
}

# `systemctl start` returns as soon as a program is launched, so a service
# that crashes right away (a bad path, a port already in use) would look
# fine. Wait a few seconds and look again. Sets START_FAILED=1 on trouble.
START_FAILED=""
verify_running() {
    local svc state sub cond
    sleep 5
    for svc in "$@"; do
        cond="$(systemctl show -p ConditionResult --value "torrent-$svc" 2>/dev/null || true)"
        [[ "$cond" == no ]] && continue   # skipped by the VPN settings gate
        state="$(systemctl show -p ActiveState --value "torrent-$svc" 2>/dev/null || true)"
        sub="$(systemctl show -p SubState --value "torrent-$svc" 2>/dev/null || true)"
        if [[ "$state" != active || "$sub" != running ]]; then
            msg_warn "torrent-$svc is not running ($state/$sub). See: journalctl -u torrent-$svc -n 30"
            START_FAILED=1
        fi
    done
    return 0
}
# report_started VERB SERVICE...: after start_units, say which services run
# now. Services systemd skipped because the VPN settings are still the
# .env.example placeholders (ConditionResult=no) are not "restarted": they
# are listed separately. Failed ones were already warned about.
report_started() {
    local verb=$1 svc ran=() gated=()
    shift
    for svc in "$@"; do
        if [[ "$(systemctl show -p ConditionResult --value "torrent-$svc" 2>/dev/null || true)" == no ]]; then
            gated+=("$svc")
        elif unit_active "$svc"; then
            ran+=("$svc")
        fi
    done
    [[ ${#ran[@]} -gt 0 ]] && msg_ok "$verb: ${ran[*]}"
    [[ ${#gated[@]} -gt 0 ]] && msg_info "Left stopped until the VPN settings are filled in: ${gated[*]}"
    return 0
}

stop_units() {
    local svc
    for svc in env-editor filebrowser flaresolverr jackett qbittorrent gluetun; do
        [[ " $* " == *" $svc "* ]] || continue
        if unit_active "$svc"; then
            systemctl stop "torrent-$svc" || msg_warn "could not stop torrent-$svc cleanly: journalctl -u torrent-$svc"
        fi
    done
    return 0
}

# Render; stop running services whose files change first (so an app cannot
# overwrite its freshly rendered config while shutting down), write, reload.
# Adds the services that changed to RESTART_AFTER and the ones it stopped
# to STOPPED_BY_RENDER (callers start those again).
STOPPED_BY_RENDER=()
render_and_reload() {
    local changed=() svc
    mapfile -t changed < <(render_changed --dry-run)
    for svc in "${changed[@]}"; do
        case "$svc" in
            _units|killswitch|-|"") continue ;;
        esac
        RESTART_AFTER+=("$svc")
        # Called from the env-editor: never stop the env-editor itself.
        [[ "$svc" == env-editor && -n "${NO_SELF_RESTART:-}" ]] && continue
        if unit_active "$svc"; then STOPPED_BY_RENDER+=("$svc"); fi
    done
    [[ ${#STOPPED_BY_RENDER[@]} -gt 0 ]] && stop_units "${STOPPED_BY_RENDER[@]}"
    mapfile -t changed < <(render_changed)
    if [[ " ${changed[*]} " == *" _units "* ]]; then systemctl daemon-reload; fi
    return 0
}

gate_note() {
    if [[ "${S[vpn_configured]}" != yes ]]; then
        msg_warn "VPN settings are still the .env.example placeholders (${S[vpn_missing]}). Gluetun, qBittorrent, Jackett and FlareSolverr stay stopped until you fill them in at the env-editor and press Apply."
    fi
}

# install_summary IP: the end of `install`, the web addresses and the
# first-run login. A host script that reaches the container through
# forwarded ports or at another address than the container's own (the
# Incus script in proxy mode) sets TS_HOST_SUMMARY=1: the addresses below
# would not work from the LAN, and the host script prints the right ones
# after this, so only the login is printed here.
install_summary() {
    local ip="$1"
    msg_ok "Install finished."
    if [[ "${TS_HOST_SUMMARY:-}" == 1 ]]; then
        if [[ -n "$FIRST_RUN_PASSWORD" ]]; then
            echo "  env-editor first-run login: user admin   password $FIRST_RUN_PASSWORD"
            echo "    (also saved in $CREDS_FILE; delete that file once noted)"
        elif [[ -f "$CREDS_FILE" ]]; then
            echo "  env-editor first-run login is in $CREDS_FILE"
        fi
        echo "  The web UI addresses to open are printed below by the host script."
    else
        echo "  env-editor (settings):  http://$ip:$ENV_EDITOR_PORT"
        if [[ -n "$FIRST_RUN_PASSWORD" ]]; then
            echo "    first-run login:      user admin   password $FIRST_RUN_PASSWORD"
            echo "    (also saved in $CREDS_FILE; delete that file once noted)"
        elif [[ -f "$CREDS_FILE" ]]; then
            echo "    first-run login is in $CREDS_FILE"
        fi
        echo "  FileBrowser:            http://$ip:${S[port_filebrowser]}"
        echo "  qBittorrent (VueTorrent): http://$ip:${S[port_qbittorrent]}"
        echo "  Jackett:                http://$ip:${S[port_jackett]}"
        echo "  FlareSolverr:           http://$ip:${S[port_flaresolverr]}"
    fi
    gate_note
}

# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------
cmd_install() {
    need_root; check_platform; take_lock; read_versions
    msg_info "Installing the torrent stack natively in $TS_ROOT"
    ensure_packages
    create_env
    load_settings
    stop_if_ids_change
    ensure_dirs
    configure_resolver
    configure_ipv6
    converge_components
    create_editor_credentials
    # The env-editor reads its login only when it starts, so a running one
    # (after credentials.json was deleted) must restart to use the new one.
    if [[ -n "$FIRST_RUN_PASSWORD" ]] && unit_active env-editor; then
        RESTART_AFTER+=(env-editor)
    fi
    ensure_search_plugin
    run_seeders ""
    if [[ "${S[qbit_configured]}" == yes ]] && ! qbit_seeded; then
        stop_units qbittorrent
        run_seeders qbit
    fi
    fix_ownership
    render_and_reload
    systemctl daemon-reload
    enable_units
    reload_killswitch
    systemctl start torrent-killswitch-check.timer
    # Restart what changed; start everything that is not running.
    local svc
    for svc in "${RESTART_AFTER[@]}"; do
        stop_units "$svc"
    done
    start_units "${STACK[@]}" env-editor

    local ip; ip="$(primary_ip)"; ip="${ip:-<container-ip>}"
    write_creds_file "$ip"
    echo
    cmd_status_lines
    echo
    install_summary "$ip"
}

cmd_update() {
    need_root; check_platform; take_lock; read_versions
    ensure_packages
    load_settings
    local was_active=() svc
    for svc in "${STACK[@]}" env-editor; do unit_active "$svc" && was_active+=("$svc"); done
    stop_if_ids_change
    [[ -n "$IDS_CHANGED" ]] && RESTART_AFTER+=("${TORRENT_UNITS[@]}")
    converge_components
    ensure_dirs
    fix_ownership
    render_and_reload
    enable_units
    reload_killswitch
    # Restart only what changed, and only if it was running before.
    local restart=()
    for svc in "${RESTART_AFTER[@]}"; do
        [[ " ${was_active[*]} " == *" $svc "* && " ${restart[*]} " != *" $svc "* ]] && restart+=("$svc")
    done
    if [[ ${#restart[@]} -eq 0 ]]; then
        if [[ ${#INSTALLED[@]} -gt 0 ]]; then
            msg_ok "Installed ${INSTALLED[*]}; no service needed a restart."
        else
            msg_ok "Nothing changed; no service restarted."
        fi
    else
        stop_units "${restart[@]}"
        start_units "${restart[@]}"
        report_started Restarted "${restart[@]}"
    fi
    cmd_status_lines
    [[ -z "$START_FAILED" ]] || die "some services are not running (see the warnings above)"
}

cmd_apply() {
    local seed="" do_restart=1 names=() a
    for a in "$@"; do
        case "$a" in
            --seed=qbit) seed=qbit ;;
            --seed=*) die "unknown seeder in $a (only qbit)" ;;
            --no-restart) do_restart=0 ;;
            -*) die "unknown option $a" ;;
            gluetun|qbittorrent|jackett|flaresolverr|filebrowser|env-editor) names+=("$a") ;;
            *) die "unknown service '$a' (services: ${STACK[*]} env-editor)" ;;
        esac
    done
    [[ ${#names[@]} -eq 0 ]] && names=("${STACK[@]}")
    [[ "$do_restart" -eq 0 ]] && names=()
    need_root; check_platform; take_lock; read_versions
    load_settings   # validates .env before anything is stopped

    # When called by the env-editor (its unit sets TS_MODE=native), never
    # stop the env-editor: that would kill the request that called us.
    [[ "${TS_MODE:-}" == native ]] && NO_SELF_RESTART=1

    # If a step below fails, start again what this run stopped, so a failed
    # Apply does not leave the stack down (the old configs are still there).
    APPLY_STOPPED=()
    for a in "${STACK[@]}"; do unit_active "$a" && APPLY_STOPPED+=("$a"); done
    trap 'apply_failed' EXIT

    stop_if_ids_change
    if [[ -n "$IDS_CHANGED" ]]; then
        # PUID/PGID changed: every app must restart under the new ids, and
        # the kill switch must know the new uid before any of them starts.
        msg_info "PUID/PGID changed: restarting every app as the new user"
        for a in "${TORRENT_UNITS[@]}"; do
            [[ " ${names[*]} " == *" $a "* ]] || names+=("$a")
        done
    fi
    stop_units "${names[@]}"
    ensure_dirs
    ensure_search_plugin
    run_seeders "$seed"
    fix_ownership
    render_and_reload
    reload_killswitch
    trap - EXIT
    for a in "${STOPPED_BY_RENDER[@]}"; do
        if [[ " ${names[*]} " != *" $a "* ]]; then
            msg_warn "$a's config changed too, so it was restarted as well"
            names+=("$a")
        fi
    done
    if [[ ${#names[@]} -gt 0 ]]; then
        start_units "${names[@]}"
        report_started Restarted "${names[@]}"
    else
        msg_ok "Configs re-rendered; no service restarted"
    fi
    gate_note
    [[ -z "$START_FAILED" ]] || die "some services are not running (see the warnings above)"
}

# EXIT trap of cmd_apply: on failure, start the services that were running
# when apply began and are not running now.
APPLY_STOPPED=()
apply_failed() {
    local rc=$? svc again=()
    [[ $rc -ne 0 ]] || return 0
    for svc in "${APPLY_STOPPED[@]}"; do unit_active "$svc" || again+=("$svc"); done
    [[ ${#again[@]} -gt 0 ]] || return 0
    msg_warn "apply failed; starting what it had stopped again: ${again[*]}"
    start_units "${again[@]}"
}

cmd_status_lines() {
    local svc state note version
    if nft list table inet "$KILLSWITCH_TABLE" >/dev/null 2>&1; then
        printf '%-13s %-9s %s\n' killswitch loaded "nftables table inet $KILLSWITCH_TABLE"
    else
        printf '%-13s %-9s %s\n' killswitch MISSING "the torrent user is NOT protected; run: systemctl restart torrent-killswitch"
    fi
    for svc in "${STACK[@]}" env-editor; do
        state="$(systemctl is-active "torrent-$svc" 2>/dev/null || true)"
        version="$(cut -d' ' -f1 "$STATE/components/$svc" 2>/dev/null || echo "?")"
        note=""
        if [[ " ${GATED[*]} " == *" $svc "* && ! -e "$ETC/vpn-configured" ]]; then
            note=" (waiting for VPN settings in .env)"
        fi
        if [[ "$svc" == gluetun && "$state" == active ]]; then
            if curl -fsS -o /dev/null --max-time 3 http://127.0.0.1:9999 2>/dev/null; then
                note=" (VPN healthy)"
            else
                note=" (VPN not connected yet)"
            fi
            [[ -s /tmp/gluetun/forwarded_port ]] && note+=" forwarded port $(head -1 /tmp/gluetun/forwarded_port)"
        fi
        if [[ "$svc" == qbittorrent && -f "$STATE/components/vuetorrent" ]]; then
            version+=" + VueTorrent $(cut -d' ' -f1 "$STATE/components/vuetorrent")"
        fi
        printf '%-13s %-9s %s%s\n' "$svc" "$state" "$version" "$note"
    done
    dns_status_line
}

# One line on the apps' private DNS view (see native/README.md, "DNS"):
# every running app must see resolv.conf -> 127.0.0.1 and nsswitch.conf
# "hosts: files dns".
dns_status_line() {
    local svc pid bad=()
    for svc in qbittorrent jackett flaresolverr filebrowser; do
        pid="$(systemctl show -p MainPID --value "torrent-$svc" 2>/dev/null || echo 0)"
        [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || continue
        nsenter -t "$pid" -m -- cmp -s /etc/resolv.conf "$ETC/app-resolve/resolv.conf" \
            && nsenter -t "$pid" -m -- cmp -s /etc/nsswitch.conf "$ETC/nsswitch.conf" \
            || bad+=("$svc")
    done
    if [[ ${#bad[@]} -eq 0 ]]; then
        printf '%-13s %-9s %s\n' app-dns ok "running apps resolve only via 127.0.0.1 (nsswitch hosts: files dns)"
    else
        printf '%-13s %-9s %s\n' app-dns PROBLEM "${bad[*]} lost the private resolv.conf/nsswitch.conf; restart them (the check timer does within a minute)"
    fi
}

cmd_status() {
    [[ -d "$STATE" ]] || die "not installed (no $STATE)"
    cmd_status_lines
}

cmd_uninstall() {
    local purge=0 a
    for a in "$@"; do
        case "$a" in
            --purge) purge=1 ;;
            *) die "unknown option $a" ;;
        esac
    done
    need_root; take_lock
    msg_info "Stopping and removing the torrent-stack services"
    local units=(torrent-killswitch-check.timer torrent-killswitch-check.service
                 torrent-env-editor.service torrent-filebrowser.service
                 torrent-flaresolverr.service torrent-jackett.service
                 torrent-qbittorrent.service torrent-gluetun.service
                 torrent-killswitch.service) u
    for u in "${units[@]}"; do
        systemctl disable --now -q "$u" 2>/dev/null || true
        rm -f "$UNIT_DIR/$u"
    done
    systemctl daemon-reload
    systemctl reset-failed 'torrent-*' 2>/dev/null || true
    # Only now, with every app stopped, remove the kill switch.
    nft delete table inet "$KILLSWITCH_TABLE" 2>/dev/null || true
    bash "$SCRIPT_DIR/lib/gluetun-iptables.sh" restore >/dev/null 2>&1 || true
    msg_ok "Services and kill switch removed"

    [[ -L /gluetun ]] && rm -f /gluetun
    rm -rf "${LIB:?}" /var/tmp/torrent-stack-build.* "${RUN_DIR:?}"
    # Everything in /etc/torrent-stack was rendered from .env, except your
    # own gluetun.local.env, which is kept (removed by --purge).
    if [[ -d "$ETC" ]]; then
        find "$ETC" -mindepth 1 -maxdepth 1 ! -name gluetun.local.env -exec rm -rf {} +
        if [[ "$purge" -eq 1 ]]; then rm -f "$ETC/gluetun.local.env"; fi
        rmdir "$ETC" 2>/dev/null || echo "Kept: $ETC/gluetun.local.env (your own Gluetun settings)"
    fi
    rm -f /etc/sysctl.d/90-torrent-stack.conf "$TMPFILES_CONF"
    if [[ -f /etc/systemd/resolved.conf.d/90-torrent-stack.conf ]]; then
        rm -f /etc/systemd/resolved.conf.d/90-torrent-stack.conf
        if [[ -f "$STATE/resolv.conf.link" ]]; then
            ln -sfn "$(cat "$STATE/resolv.conf.link")" /etc/resolv.conf
        fi
        systemctl restart systemd-resolved 2>/dev/null || true
    fi
    local added=""
    [[ -f "$STATE/packages-added" ]] && added="$(sort -u "$STATE/packages-added" | tr '\n' ' ')"
    rm -rf "${STATE:?}"
    id -u "$GLUETUN_USER" >/dev/null 2>&1 && userdel "$GLUETUN_USER" 2>/dev/null || true
    msg_ok "Programs removed from $LIB"

    if [[ "$purge" -eq 1 ]]; then
        purge_data
    else
        echo "Kept: $TS_ROOT/.env, your configs and downloads, the env-editor venv and the '$TORRENT_USER' user."
        echo "Run with --purge to delete those that are inside $TS_ROOT."
    fi
    if [[ -n "$added" ]]; then
        echo "Debian packages this installer added were left in place: $added"
        echo "Remove the ones nothing else in this container needs with: apt-get purge <names> && apt-get autoremove"
    fi
}

purge_data() {
    # Settings may be unreadable by now; fall back to the default layout.
    local cfg="$TS_ROOT/configs" dl="$TS_ROOT/downloads" inc="" p json
    if [[ -f "$TS_ROOT/.env" ]] && json="$(python3 -I "$RENDER" --root "$TS_ROOT" info 2>/dev/null)"; then
        cfg="$(printf '%s' "$json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["config_root"])')"
        dl="$(printf '%s' "$json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["downloads_root"])')"
        inc="$(printf '%s' "$json" | python3 -I -c 'import json,sys; print(json.load(sys.stdin)["incomplete_root"])')"
    fi
    for p in "$cfg" "$dl" "$inc" "$TS_ROOT/configs" "$TS_ROOT/scripts/env-editor/.venv"; do
        [[ -n "$p" && -e "$p" ]] || continue
        case "$(realpath -m "$p")/" in
            "$TS_ROOT"/?*) rm -rf -- "$p"; echo "deleted $p" ;;
            *) echo "left in place (outside $TS_ROOT): $p" ;;
        esac
    done
    rm -f "$TS_ROOT/.env" "$CREDS_FILE"
    echo "deleted $TS_ROOT/.env"
    id -u "$TORRENT_USER" >/dev/null 2>&1 && userdel "$TORRENT_USER" 2>/dev/null || true
    msg_ok "Purged"
}

cmd_pins() {
    # Maintainer helper: download every pinned file for both architectures
    # and print its sha256, ready to paste into versions.env. Trust on first
    # use: check the release notes before pasting.
    read_versions
    PINS_TMP="$(mktemp -d)"
    trap 'rm -rf "$PINS_TMP"' EXIT
    local tmp="$PINS_TMP"
    _sum() {  # _sum KEY URL
        curl -fsSL --proto '=https' -o "$tmp/f" "$2" || { echo "# $1: download failed: $2"; return; }
        echo "$1=$(sha256sum "$tmp/f" | cut -d' ' -f1)"
    }
    local a
    for a in amd64 arm64; do
        _sum "GO_SHA256_${a^^}" "https://go.dev/dl/go$(pin GO_VERSION).linux-$a.tar.gz"
    done
    _sum QBITTORRENT_SHA256_AMD64 "https://github.com/userdocs/qbittorrent-nox-static/releases/download/$(pin QBITTORRENT_RELEASE)/x86_64-qbittorrent-nox"
    _sum QBITTORRENT_SHA256_ARM64 "https://github.com/userdocs/qbittorrent-nox-static/releases/download/$(pin QBITTORRENT_RELEASE)/aarch64-qbittorrent-nox"
    _sum VUETORRENT_SHA256 "https://github.com/VueTorrent/VueTorrent/releases/download/$(pin VUETORRENT_VERSION)/vuetorrent.zip"
    _sum JACKETT_SHA256_AMD64 "https://github.com/Jackett/Jackett/releases/download/$(pin JACKETT_VERSION)/Jackett.Binaries.LinuxAMDx64.tar.gz"
    _sum JACKETT_SHA256_ARM64 "https://github.com/Jackett/Jackett/releases/download/$(pin JACKETT_VERSION)/Jackett.Binaries.LinuxARM64.tar.gz"
    _sum FILEBROWSER_SHA256_AMD64 "https://github.com/gtsteffaniak/filebrowser/releases/download/$(pin FILEBROWSER_VERSION)/linux-amd64-filebrowser"
    _sum FILEBROWSER_SHA256_ARM64 "https://github.com/gtsteffaniak/filebrowser/releases/download/$(pin FILEBROWSER_VERSION)/linux-arm64-filebrowser"
    _sum QBIT_JACKETT_PLUGIN_SHA256 "https://raw.githubusercontent.com/qbittorrent/search-plugins/$(pin QBIT_SEARCH_PLUGINS_COMMIT)/nova3/engines/jackett.py"
    local repo key tag
    while read -r repo key tag; do
        # The ^{} line (if any) sorts last and is the commit of an annotated tag.
        echo "${key}_COMMIT=$(git ls-remote "https://github.com/$repo" "refs/tags/$tag" "refs/tags/$tag^{}" | awk 'END {print $1}')"
    done <<EOF
qdm12/gluetun GLUETUN $(pin GLUETUN_VERSION)
FlareSolverr/FlareSolverr FLARESOLVERR $(pin FLARESOLVERR_VERSION)
EOF
}

# ---------------------------------------------------------------------------
# self-update: new repository version + Debian packages, then `update`
# ---------------------------------------------------------------------------
# Why not just `git pull`: the repository tracks two seed files under
# configs/ (qBittorrent.conf, Jackett's ServerConfig.json) that the apps
# rewrite in place, so `git pull` refuses as soon as a new commit changes a
# seed. And configs/<app> belongs to the torrent user: root must not write
# there (a compromised app could have planted a symlink). So git updates the
# index and every file OUTSIDE configs/, and never touches configs/. Your
# live configs stay exactly as they are; the seeds only matter on a first
# install anyway.
git_update_checkout() {  # git_update_checkout REF ("" = follow the current branch)
    local ref="$1" g=(git -C "$TS_ROOT") branch old target f
    local changed=() deleted=()
    branch="$("${g[@]}" symbolic-ref -q --short HEAD || true)"
    old="$("${g[@]}" rev-parse HEAD)"
    if [[ -n "$ref" && "$ref" != "$branch" ]]; then
        msg_info "Fetching $ref"
        "${g[@]}" fetch -q --depth 1 origin "$ref" || die "git fetch of '$ref' failed (does that branch or tag exist?)"
        target="$("${g[@]}" rev-parse 'FETCH_HEAD^{commit}')"
    elif [[ -n "$branch" ]]; then
        msg_info "Fetching the latest $branch"
        "${g[@]}" fetch -q || die "git fetch failed"
        # The checkout follows its upstream exactly (it is a shallow clone,
        # where ancestry checks are unreliable; don't commit in it).
        target="$("${g[@]}" rev-parse '@{upstream}')" || die "branch $branch has no upstream to update from"
    else
        msg_ok "Pinned to $("${g[@]}" describe --tags --always): nothing to fetch. Use --ref <tag> to move."
        return 0
    fi
    if [[ "$target" == "$old" ]]; then
        msg_ok "Repository already up to date ($("${g[@]}" log -1 --format='%h %s'))"
        return 0
    fi
    # Files that change outside configs/. Refuse to overwrite your own edits.
    while IFS= read -r -d '' f; do changed+=("$f"); done \
        < <("${g[@]}" diff -z --no-renames --name-only --diff-filter=d "$old" "$target" -- . ':(exclude)configs')
    while IFS= read -r -d '' f; do deleted+=("$f"); done \
        < <("${g[@]}" diff -z --no-renames --name-only --diff-filter=D "$old" "$target" -- . ':(exclude)configs')
    # Like `git merge`, only files the new version changes must be
    # unmodified here (staged or not); other local changes are left alone.
    local -A touched=()
    local mine=()
    for f in ${changed[@]+"${changed[@]}"} ${deleted[@]+"${deleted[@]}"}; do touched[$f]=1; done
    while IFS= read -r -d '' f; do
        [[ -n "${touched[$f]:-}" ]] && mine+=("$f")
    done < <("${g[@]}" diff -z --no-renames --name-only HEAD; "${g[@]}" diff -z --no-renames --cached --name-only HEAD)
    if [[ ${#mine[@]} -gt 0 ]]; then
        die "these files in $TS_ROOT were changed by hand, and the new version changes them too:
$(printf '  %s\n' "${mine[@]}" | sort -u)
Undo or save those changes first (git -C $TS_ROOT diff)."
    fi
    for f in "${changed[@]}"; do
        if ! "${g[@]}" cat-file -e "$old:$f" 2>/dev/null && [[ -e "$TS_ROOT/$f" || -L "$TS_ROOT/$f" ]]; then
            die "the new version adds $f, but a file of that name is already there; move it away first"
        fi
    done
    # 1. Index := new version (work tree untouched; -i skips the work-tree check).
    "${g[@]}" read-tree -m -i "$old" "$target"
    # 2. Remove deleted files, then write the changed ones from the index.
    #    Paths outside configs/ belong to root; git refuses to write through
    #    symlinks in a path.
    for f in "${deleted[@]}"; do rm -f -- "${TS_ROOT:?}/$f"; done
    if [[ ${#changed[@]} -gt 0 ]]; then
        printf '%s\0' "${changed[@]}" | "${g[@]}" checkout-index -f -z --stdin
    fi
    # 3. Move the branch (or, with --ref, a detached HEAD) to the new commit.
    if [[ -n "$ref" && "$ref" != "$branch" ]]; then
        "${g[@]}" update-ref --no-deref -m "native/install.sh self-update --ref $ref" HEAD "$target" "$old"
    else
        "${g[@]}" update-ref -m "native/install.sh self-update" HEAD "$target" "$old"
    fi
    "${g[@]}" update-index -q --refresh >/dev/null || true
    msg_ok "Repository updated: $("${g[@]}" log -1 --format='%h %s')"
    if [[ -n "$("${g[@]}" diff --name-only "$old" "$target" -- configs)" ]]; then
        echo "    (the new version changed a seed under configs/; your live configs were kept)"
    fi
}

cmd_self_update() {
    local ref="" os_upgrade=1
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ref) [[ -n "${2:-}" ]] || die "--ref needs a branch or tag"; ref="$2"; shift ;;
            --ref=*) ref="${1#--ref=}" ;;
            --no-os-upgrade) os_upgrade=0 ;;
            *) die "unknown option $1 (self-update [--ref REF] [--no-os-upgrade])" ;;
        esac
        shift
    done
    [[ -z "$ref" || ( "$ref" =~ ^[A-Za-z0-9._/-]+$ && "$ref" != -* ) ]] || die "invalid --ref '$ref'"
    need_root; check_platform
    [[ "${TS_MODE:-}" != native ]] || die "self-update is run from a shell in the container, not from the env-editor"
    take_lock
    check_internet
    if [[ -d "$TS_ROOT/.git" ]]; then
        git_update_checkout "$ref"
    else
        [[ -z "$ref" ]] || die "$TS_ROOT is a copy (no .git), so --ref cannot switch it. Copy the new files in again (the host scripts' TS_SOURCE_DIR does), then run self-update."
        msg_info "$TS_ROOT is a copy, not a git checkout: not downloading a new version (the host scripts' TS_SOURCE_DIR copy updates it)"
    fi
    if [[ "$os_upgrade" -eq 1 ]]; then
        # Debian's security and point-release updates for the container.
        # --force-confold keeps any config file you changed.
        msg_info "Upgrading the container's Debian packages"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq --error-on=any || die "apt-get update failed (is the network up?)"
        apt-get -y -qq -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade >/dev/null \
            || die "apt-get full-upgrade failed"
        msg_ok "Debian packages are up to date"
    fi
    # Run `update` from the NEW installer: this one may be outdated. The lock
    # is released first; `update` takes it again.
    exec 9>&-
    exec bash "$TS_ROOT/native/install.sh" update
}

# reset-login: a new env-editor password, for when the old one is lost.
cmd_reset_login() {
    [[ $# -eq 0 ]] || die "reset-login takes no arguments"
    need_root; check_platform
    [[ "${TS_MODE:-}" != native ]] || die "reset-login is run from a shell in the container, not from the env-editor"
    take_lock
    [[ -x "$(venv_python)" && -d "$STATE" ]] || die "not installed yet; run: bash $TS_ROOT/native/install.sh install"
    load_settings
    msg_info "Creating a new env-editor login"
    rm -f "$TS_ROOT/configs/env-editor/credentials.json"
    create_editor_credentials
    # Until a real qBittorrent login is set, FileBrowser uses the same
    # first-run password: re-render so it gets the new one too.
    render_and_reload
    [[ ${#STOPPED_BY_RENDER[@]} -gt 0 ]] && start_units "${STOPPED_BY_RENDER[@]}"
    # The env-editor reads its login only when it starts.
    systemctl restart torrent-env-editor || START_FAILED=1
    verify_running env-editor
    local ip; ip="$(primary_ip)"; ip="${ip:-<container-ip>}"
    write_creds_file "$ip"
    msg_ok "New env-editor login:   user admin   password $FIRST_RUN_PASSWORD"
    echo "    (also saved in $CREDS_FILE; delete that file once noted)"
    if [[ "${S[qbit_configured]}" != yes ]]; then
        echo "    FileBrowser (user admin) uses the same password until you set a real qBittorrent login; then QBITTORRENT_PASSWORD."
    fi
    [[ -z "$START_FAILED" ]] || die "the env-editor did not restart (journalctl -u torrent-env-editor)"
}

main() {
    local cmd="${1:-help}"
    [[ $# -gt 0 ]] && shift
    case "$cmd" in
        install)   [[ $# -eq 0 ]] || die "install takes no arguments"; cmd_install ;;
        update)    [[ $# -eq 0 ]] || die "update takes no arguments"; cmd_update ;;
        self-update) cmd_self_update "$@" ;;
        reset-login) cmd_reset_login "$@" ;;
        apply)     cmd_apply "$@" ;;
        status)    cmd_status ;;
        uninstall) cmd_uninstall "$@" ;;
        pins)      cmd_pins ;;
        help|-h|--help) usage ;;
        *) usage >&2; exit 2 ;;
    esac
}

# Run unless sourced (the host scripts' tests source this file to reuse
# git_update_checkout in their stand-in installer).
if ! (return 0 2>/dev/null); then
    main "$@"
fi
