#!/usr/bin/env bash
#
# platforms/synology/tests/run-tests.sh
#
# Purpose: test platforms/synology/install.sh and boot.sh on a Linux machine
# that is not a Synology NAS. Run as root on a host with Incus:
#   bash platforms/synology/tests/run-tests.sh [--no-real-docker]
#
# How: a throwaway privileged Debian 13 Incus container (synology-t1) is
# shaped like DSM 7.2: /etc.defaults/VERSION, the shared folders
# /volume1/docker and /volume1/downloads, a DSM user (uid 1026, group users
# 100), /lib/modules/tun.ko, and shims in DSM's own locations for
# synowebapi and synopkg (/usr/syno/bin), docker and docker-compose
# (/usr/local/bin) and insmod/modprobe (/usr/local/sbin). The shims are in
# tests/shims; the docker shim runs the real docker-compose for every
# compose call it validates, and runs containers as real processes in real
# network namespaces. The container is deleted at the end.
# Then, unless --no-real-docker, the two throwaway containers install.sh
# starts (seeding and the write check) are run with the host's real Docker
# and the pinned image.
#
# Needs: root, incus (with images:debian/13), curl, tar, git, sha256sum,
# docker (for the real-docker part), internet access (Debian packages, the
# pinned docker-compose releases, the Jackett search plugin and PyPI).
# What this cannot test is listed in platforms/synology/README.md.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"

CT="${TS_TEST_CT:-synology-t1}" # test container name (TS_TEST_CT overrides)
CACHE="${TS_TEST_CACHE:-${TMPDIR:-/tmp}/torrent-stack-synology-tests}"
# docker-compose releases DSM's Container Manager has shipped (v2.9.0 in
# older 20.10.23 builds, v2.20.1 in 24.0.2), pinned by checksum.
COMPOSE_OLD_VER="v2.9.0"
COMPOSE_OLD_SHA="3be9ce88ecba41b734e3fc8e59a9b11531133761414a78827d1615aadb5ef1f5"
COMPOSE_DSM_VER="v2.20.1"
COMPOSE_DSM_SHA="804aa825c58b375901ba9dc9d0aa1648ce305d903a58f2a5c42bb5c6873b02bf"

PASS=0
FAIL=0
FAILED=()
ok() {
  PASS=$((PASS + 1))
  printf '  ok   %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
  printf '  FAIL %s\n' "$1"
}
check() { # check "description" command...
  local d=$1
  shift
  if "$@"; then ok "$d"; else bad "$d"; fi
}
has() { grep -qF -- "$2" "$1"; }
not() { ! "$@"; }
hasnt() { ! grep -qF -- "$2" "$1"; }
summary() {
  echo
  echo "  $1: ${PASS} passed, ${FAIL} failed"
  if ((FAIL)); then
    printf '    failed: %s\n' "${FAILED[@]}"
    return 1
  fi
}

# ===========================================================================
# Inside the test container
# ===========================================================================
inside() {
  local SRC=/root/src
  local INSTALLER="$SRC/platforms/synology/install.sh"
  local STACK_DIR=/volume1/docker/torrent-stack
  local FD=/var/lib/fake-docker FS=/var/lib/fake-syno LOGS=/root/logs
  local BOOT_LOG=/var/log/torrent-stack-boot.log
  # The system python3 has no bcrypt and no pip, like DSM's.
  export FAKE_DOCKER_DIR=$FD FAKE_SYNO_DIR=$FS REAL_COMPOSE=/opt/real-compose/docker-compose
  mkdir -p "$LOGS" /root/secrets /root/badpy
  # A python3 that always fails, put first in PATH to make the installer fall
  # back to the seeding container (the shims call /usr/bin/python3 directly).
  printf '#!/bin/sh\necho "python3: test stand-in that always fails" >&2\nexit 1\n' >/root/badpy/python3
  chmod 755 /root/badpy/python3

  # --- A DSM-shaped system -------------------------------------------------
  mkdir -p /etc.defaults /usr/syno/bin /usr/local/bin /usr/local/sbin /lib/modules
  dsm_version() { # MAJOR MINOR MICRO BUILD
    cat >/etc.defaults/VERSION <<EOF
majorversion="$1"
minorversion="$2"
major="$1"
minor="$2"
micro="$3"
buildphase="GM"
buildnumber="$4"
smallfixnumber="3"
nano="3"
base="$4"
productversion="$1.$2.$3"
os_name="DSM"
EOF
  }
  dsm_version 7 2 2 72806
  install -m 755 "$SRC/platforms/synology/tests/shims/synowebapi" /usr/syno/bin/synowebapi
  install -m 755 "$SRC/platforms/synology/tests/shims/synopkg" /usr/syno/bin/synopkg
  install -m 755 "$SRC/platforms/synology/tests/shims/docker" /usr/local/bin/docker
  ln -sf docker /usr/local/bin/docker-compose
  install -m 755 "$SRC/platforms/synology/tests/shims/insmod" /usr/local/sbin/insmod
  install -m 755 "$SRC/platforms/synology/tests/shims/modprobe" /usr/local/sbin/modprobe
  : >/lib/modules/tun.ko
  id alice >/dev/null 2>&1 || useradd -u 1026 -g 100 -M -s /sbin/nologin alice

  reset_all() {
    docker __fake kill-all >/dev/null 2>&1 || true
    rm -rf "$FD" "$FS" "$STACK_DIR" /volume1/docker/other /volume1/docker/immich /volume1/downloads "$BOOT_LOG" /root/pwned
    mkdir -p "$FD" "$FS" /volume1/docker /volume1/downloads
    tun_on
  }
  tun_on() { [[ -c /dev/net/tun ]] || { mkdir -p /dev/net && mknod -m 666 /dev/net/tun c 10 200; }; }
  # Incus bind-mounts the host's /dev/net/tun into the container.
  tun_off() {
    umount /dev/net/tun 2>/dev/null || true
    rm -f /dev/net/tun
  }

  # inst NAME [VAR=value...] -- ARGS...: run the installer, output in
  # $LOGS/NAME.log, exit code in RC.
  RC=0
  inst() {
    local name=$1
    shift
    local -a envs=()
    while [[ $# -gt 0 && "$1" != -- ]]; do
      envs+=("$1")
      shift
    done
    shift
    RC=0
    env TS_SOURCE_DIR="$SRC" TS_USER=alice TS_DOWNLOADS=/volume1/downloads "${envs[@]}" \
      bash "$INSTALLER" "$@" </dev/null >"$LOGS/$name.log" 2>&1 || RC=$?
  }
  boot() { # boot NAME ARGS...
    local name=$1
    shift
    RC=0
    bash "$STACK_DIR/platforms/synology/boot.sh" "$@" </dev/null >"$LOGS/$name.log" 2>&1 || RC=$?
  }
  calls_since() { tail -n +"$(($1 + 1))" "$FD/calls.log" 2>/dev/null || true; }
  ncalls() { if [[ -f "$FD/calls.log" ]]; then wc -l <"$FD/calls.log"; else echo 0; fi; }
  syno_count() { # API METHOD
    jq -s --arg a "$1" --arg m "$2" '[.[] | select(.api == $a and .method == $m)] | length' "$FS/calls.jsonl" 2>/dev/null || echo 0
  }
  running_count() {
    docker ps -q >/dev/null
    jq '[.containers[] | select(.running)] | length' "$FD/state.json"
  }
  pid_of() { jq -r --arg s "$1" '.containers[] | select(.service == $s) | .pid' "$FD/state.json"; }
  netns_ok() {
    docker ps -q >/dev/null
    local g s
    g=$(readlink "/proc/$(pid_of gluetun)/ns/net") || return 1
    for s in qbittorrent jackett flaresolverr; do
      [[ "$(readlink "/proc/$(pid_of "$s")/ns/net")" == "$g" ]] || return 1
    done
  }
  envv() { # KEY: the value docker compose reads from the project's .env
    # (`config` prints a literal $ as $$ so its output stays loadable.)
    (cd "$STACK_DIR" && /opt/real-compose/docker-compose config --format json 2>/dev/null) |
      jq -r --arg k "$1" '.services.gluetun.environment[$k] // empty | gsub("\\$\\$"; "$")'
  }
  pbkdf2_ok() { # PASSWORD: qBittorrent.conf's hash matches it
    python3 -I - "$1" "$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf" <<'PY'
import base64, hashlib, re, sys
pw, conf = sys.argv[1], open(sys.argv[2], encoding="utf-8").read()
m = re.search(r'WebUI\\Password_PBKDF2="@ByteArray\(([^:]+):([^)]+)\)"', conf)
salt, want = base64.b64decode(m.group(1)), base64.b64decode(m.group(2))
sys.exit(0 if hashlib.pbkdf2_hmac("sha512", pw.encode(), salt, 100000) == want else 1)
PY
  }
  root_only() { # FILE...: owned by root, not writable by group or others
    local f m
    for f in "$@"; do
      m=$(stat -c '%u %A' "$f") || return 1
      [[ "$m" == "0 "* && "${m:7:1}" != w && "${m:10:1}" != w ]] || return 1
    done
  }
  task_op() { jq -r '.tasks["Torrent stack boot"].operation // empty' "$FS/state.json"; }
  op_has() { [[ "$(task_op)" == *"$1"* ]]; }
  mode_is() { [[ "$(stat -c %a "$1")" == "$2" ]]; }
  owner_is() { [[ "$(stat -c %u:%g "$1")" == "$2" ]]; }
  envfile_has() { grep -qxF -- "$1" "$STACK_DIR/.env"; }

  echo "== preflight checks"
  reset_all
  mv /etc.defaults/VERSION /etc.defaults/VERSION.off
  inst pre-notdsm -- --unattended
  mv /etc.defaults/VERSION.off /etc.defaults/VERSION
  check "not DSM: refuses" test "$RC" -ne 0
  check "not DSM: says so" has "$LOGS/pre-notdsm.log" "This is not a Synology DSM system"
  dsm_version 7 1 1 42962
  inst pre-old -- --unattended
  dsm_version 7 2 2 72806
  check "DSM 7.1: refuses as too old" has "$LOGS/pre-old.log" "DSM 7.1.1 is too old"
  echo 255 >"$FS/cm-status"
  inst pre-nocm -- --unattended
  check "no Container Manager: explains how to install it" has "$LOGS/pre-nocm.log" 'search for "Container Manager"'
  echo 17 >"$FS/cm-status"
  inst pre-cmstopped -- --unattended
  check "Container Manager stopped: says start it" has "$LOGS/pre-cmstopped.log" "installed but stopped"
  rm -f "$FS/cm-status"
  touch "$FD/daemon-down"
  inst pre-nodaemon -- --unattended
  rm -f "$FD/daemon-down"
  check "docker daemon down: refuses" has "$LOGS/pre-nodaemon.log" "Docker is not answering"
  inst pre-nouser TS_USER=nobody-here -- --unattended
  check "unknown DSM user: refuses" has "$LOGS/pre-nouser.log" "There is no DSM user 'nobody-here'"
  inst pre-noshare TS_DOWNLOADS=/volume1/nosuchshare/torrents -- --unattended
  check "downloads in a missing shared folder: refuses" has "$LOGS/pre-noshare.log" "there is no shared folder 'nosuchshare'"
  inst pre-notshare TS_DOWNLOADS=/tmp/downloads -- --unattended
  check "downloads outside /volumeN: refuses" has "$LOGS/pre-notshare.log" "must be a folder inside a shared folder"
  inst pre-shareroot TS_STACK_DIR=/volume1/docker -- --unattended
  check "project folder = shared folder itself: refuses" has "$LOGS/pre-shareroot.log" "must be a folder inside the shared folder /volume1/docker"
  check "no files were created by the refused runs" test ! -e "$STACK_DIR"

  echo "== dry run"
  reset_all
  local n0
  n0=$(ncalls)
  inst dry -- --unattended --dry-run
  check "dry run: exit 0" test "$RC" -eq 0
  check "dry run: shows the Container Manager create request" has "$LOGS/dry.log" "would call: /usr/syno/bin/synowebapi --exec api=SYNO.Docker.Project method=create version=1"
  check "dry run: share_path is the shared-folder path" has "$LOGS/dry.log" 'share_path="/docker/torrent-stack"'
  check "dry run: shows the boot task request" has "$LOGS/dry.log" "api=SYNO.Core.EventScheduler method=create"
  check "dry run: boot task runs the project folder's boot.sh" has "$LOGS/dry.log" 'f=/volume1/docker/torrent-stack/platforms/synology/boot.sh'
  check "dry run: masks secrets in the .env preview" has "$LOGS/dry.log" "QBITTORRENT_PASSWORD=********"
  check "dry run: created no project folder" test ! -e "$STACK_DIR"
  check "dry run: no DSM write requests" test "$(($(syno_count SYNO.Docker.Project create) + $(syno_count SYNO.Core.EventScheduler create)))" -eq 0
  check "dry run: no containers started or run" bash -c "! tail -n +$((n0 + 1)) $FD/calls.log | grep -E ' up | run '"

  echo "== fresh install, VPN keys not set"
  reset_all
  inst fresh -- --unattended
  check "fresh: exit 0" test "$RC" -eq 0
  check "fresh: compose.yaml in the project folder" cmp -s "$SRC/compose.yaml" "$STACK_DIR/compose.yaml"
  check "fresh: .env is mode 600" mode_is "$STACK_DIR/.env" 600
  check "fresh: CONFIG_PATH absolute" envfile_has "CONFIG_PATH=/volume1/docker/torrent-stack/configs"
  check "fresh: DOWNLOADS_PATH" envfile_has "DOWNLOADS_PATH=/volume1/downloads"
  check "fresh: INCOMPLETE_DOWNLOADS" envfile_has "INCOMPLETE_DOWNLOADS=/volume1/downloads/incomplete"
  check "fresh: PUID of the DSM user" envfile_has "PUID=1026"
  check "fresh: PGID 100 (users)" envfile_has "PGID=100"
  check "fresh: time zone detected from /etc/localtime" envfile_has "TZ=Etc/UTC"
  check "fresh: Watchtower off" envfile_has "COMPOSE_PROFILES="
  check "fresh: no Discord webhook (not the .env.example placeholder)" envfile_has "SCRIPT_NOTIFY_URL="
  check "fresh: qBittorrent password seeded (PBKDF2)" pbkdf2_ok "$(envv QBITTORRENT_PASSWORD)"
  check "fresh: seeded with DSM's python3" has "$LOGS/fresh.log" "Seeding qBittorrent and Jackett (DSM's python3)"
  check "fresh: no seeding container was run" bash -c "! grep -q 'torrent-stack-seed' $FD/calls.log"
  check "fresh: no FileBrowser settings.yaml (the image never reads it)" test ! -e "$STACK_DIR/configs/filebrowser/settings.yaml"
  check "fresh: Jackett API key" bash -c "jq -e '.APIKey | length == 32' $STACK_DIR/configs/jackett/Jackett/ServerConfig.json >/dev/null"
  check "fresh: Jackett search plugin installed" test -s "$STACK_DIR/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
  check "fresh: qBittorrent config owned 1026:100" owner_is "$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf" 1026:100
  check "fresh: gluetun config stays root" owner_is "$STACK_DIR/configs/gluetun" 0:0
  check "fresh: downloads owned 1026:100" owner_is /volume1/downloads/incomplete 1026:100
  check "fresh: write check passed" has "$LOGS/fresh.log" "alice can write to the config and download folders"
  check "fresh: Container Manager project created once" test "$(syno_count SYNO.Docker.Project create)" -eq 1
  check "fresh: project listed with the right path" bash -c "jq -e '[.projects[] | select(.name == \"torrent-stack\" and .path == \"$STACK_DIR\")] | length == 1' $FS/state.json >/dev/null"
  check "fresh: content sent = compose.yaml" bash -c "jq -s -r '[.[] | select(.method == \"create\" and .api == \"SYNO.Docker.Project\")][0].content' $FS/calls.jsonl | cmp -s - <(cat $SRC/compose.yaml; echo)"
  check "fresh: boot task created (boot-up, as root)" bash -c "jq -e '.tasks[\"Torrent stack boot\"] | .event == \"bootup\" and .owner == {\"0\": \"root\"}' $FS/state.json >/dev/null"
  check "fresh: boot task is one line (pasteable into the UI)" test "$(task_op | wc -l)" -eq 1
  check "fresh: boot task loads tun itself" op_has "[ -c /dev/net/tun ] || insmod /lib/modules/tun.ko; "
  check "fresh: boot task names the project folder's boot.sh" op_has "f=$STACK_DIR/platforms/synology/boot.sh; "
  check "fresh: boot task runs boot.sh only from the root-only case" op_has "'0 '?????w* | '0 '????????w*) ;; '0 '*) exec /bin/bash \"\$f\" ;; esac"
  check "fresh: boot task is valid sh" sh -n -c "$(task_op)"
  check "fresh: repository files are root-only" root_only "$STACK_DIR" "$STACK_DIR/compose.yaml" "$STACK_DIR/.env" "$STACK_DIR/update-qbittorrent.sh" "$STACK_DIR/platforms/synology/boot.sh"
  check "fresh: no 'not root-only' warning" hasnt "$LOGS/fresh.log" "not root-only"
  check "fresh: not started without VPN keys" bash -c "! grep -q ' up ' $FD/calls.log"
  check "fresh: says so" has "$LOGS/fresh.log" "Not started: the VPN keys are not set yet"
  check "fresh: prints the generated password" has "$LOGS/fresh.log" "Generated password"
  check "fresh: says where FileBrowser's first-run password will be" has "$LOGS/fresh.log" "the first-run password in its log, once it runs"
  check "fresh: explains Container Manager" has "$LOGS/fresh.log" "Container Manager > Project > torrent-stack"

  echo "== re-run with VPN keys and a password with special characters"
  local WG="aW5zdGFsbC1zeW5vbG9neS10ZXN0LWtleS0xMjM0NTY=" QPW='sp ace "q" \b$x'
  (
    umask 077
    printf '%s\n' "$WG" >/root/secrets/wg
    printf '%s\n' "$QPW" >/root/secrets/qpw
  )
  n0=$(ncalls)
  inst keys TS_WIREGUARD_PRIVATE_KEY_FILE=/root/secrets/wg TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
    TS_QBITTORRENT_PASSWORD_FILE=/root/secrets/qpw -- --unattended
  check "keys: exit 0" test "$RC" -eq 0
  check "keys: compose reads the WireGuard key back exactly" test "$(envv WIREGUARD_PRIVATE_KEY)" == "$WG"
  check "keys: compose reads the password back exactly" test "$(envv QBITTORRENT_PASSWORD)" == "$QPW"
  check "keys: qBittorrent hash matches the new password" pbkdf2_ok "$QPW"
  check "keys: prints FileBrowser's first-run password from its log" has "$LOGS/keys.log" "admin / fb-first-run-pw  (first-run password"
  check "keys: qBittorrent login line" has "$LOGS/keys.log" "admin / QBITTORRENT_PASSWORD in /volume1/docker/torrent-stack/.env"
  check "keys: no 'Login (both)' claim" hasnt "$LOGS/keys.log" "Login (both)"
  check "keys: previous .env kept as .env.bak (600)" mode_is "$STACK_DIR/.env.bak" 600
  check "keys: no second Container Manager project" test "$(syno_count SYNO.Docker.Project create)" -eq 1
  check "keys: project reported up to date" has "$LOGS/keys.log" "registered and up to date"
  check "keys: no second boot task" test "$(syno_count SYNO.Core.EventScheduler create)" -eq 1
  check "keys: boot task reported in place" has "$LOGS/keys.log" "boot task 'Torrent stack boot' is in place"
  check "keys: started with docker compose up -d" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q -- '-p torrent-stack -f $STACK_DIR/compose.yaml --env-file $STACK_DIR/.env up -d'"
  check "keys: all five services running" test "$(running_count)" -eq 5
  check "keys: apps are inside gluetun's network namespace" netns_ok
  check "keys: no secret on any docker command line" bash -c "! grep -qF -e '$WG' -e 'sp ace' $FD/calls.log"
  check "keys: no secret in any DSM API request" bash -c "! grep -qF -e '$WG' -e 'sp ace' $FS/calls.jsonl"

  echo "== compose versions DSM ships"
  local cv
  for cv in /opt/compose-2.9.0/docker-compose /opt/real-compose/docker-compose /opt/compose-host/docker-compose; do
    check "config -q with $("$cv" version --short) (implicit .env, as Container Manager runs it)" bash -c "cd $STACK_DIR && $cv config -q"
    check "project name and services with $("$cv" version --short)" bash -c "cd $STACK_DIR && test \"\$($cv config --services | sort | tr '\n' ' ')\" == 'filebrowser flaresolverr gluetun jackett qbittorrent ' && $cv config | grep -qx 'name: torrent-stack'"
  done

  echo "== --apply after editing .env"
  sed -i 's/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD='"'"'An0ther "pw" here'"'"'/' "$STACK_DIR/.env"
  n0=$(ncalls)
  inst apply -- --apply
  check "apply: exit 0" test "$RC" -eq 0
  check "apply: stopped qBittorrent before seeding" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q 'stop qbittorrent$'"
  check "apply: re-seeded the edited password" pbkdf2_ok 'An0ther "pw" here'
  check "apply: all five services running" test "$(running_count)" -eq 5
  check "apply: apps inside gluetun's network" netns_ok

  echo "== apps left outside gluetun's network"
  docker __fake restart-gluetun
  check "setup: gluetun restarted alone leaves the apps outside" not netns_ok
  n0=$(ncalls)
  inst stale -- --apply
  # --apply stops qBittorrent for seeding, so `up -d` starts it inside the
  # current gluetun network; Jackett and FlareSolverr need recreating.
  check "stale: --apply recreates the apps still outside" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q 'up -d --no-deps --force-recreate jackett flaresolverr$'"
  check "stale: apps back inside gluetun's network" netns_ok

  echo "== boot.sh"
  tun_off
  touch "$FS/insmod-creates-node"
  boot boot-tun-udev --tun-only
  rm -f "$FS/insmod-creates-node"
  check "boot: loads /lib/modules/tun.ko when tun is missing" has "$FS/insmod.calls" "insmod /lib/modules/tun.ko"
  check "boot: /dev/net/tun is back (module + udev)" test -c /dev/net/tun
  tun_off
  boot boot-tun-mknod --tun-only
  check "boot: creates the device node when the module gives none" has "$LOGS/boot-tun-mknod.log" "creating the device node /dev/net/tun"
  check "boot: /dev/net/tun is char 10:200" test "$(stat -c '%F %t:%T' /dev/net/tun)" == "character special file a:c8"
  check "boot: wrote its log" has "$BOOT_LOG" "tun: /dev/net/tun is ready"
  tun_on

  n0=$(ncalls)
  boot boot-ok --now
  check "boot: all running: nothing to do" has "$LOGS/boot-ok.log" "stack: all services are running"
  check "boot: all running: no compose up" bash -c "! tail -n +$((n0 + 1)) $FD/calls.log | grep -q ' up '"

  docker __fake fail-apps
  n0=$(ncalls)
  boot boot-dry --now --dry-run
  check "boot dry run: would run compose up -d" has "$LOGS/boot-dry.log" "dry-run: would run: compose up -d"
  check "boot dry run: started nothing" test "$(running_count)" -eq 2
  boot boot-heal --now
  check "boot: apps failed at boot: exit 0" test "$RC" -eq 0
  check "boot: apps failed at boot: ran compose up -d" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q ' up -d$'"
  check "boot: apps failed at boot: all running again" test "$(running_count)" -eq 5
  check "boot: apps failed at boot: inside gluetun's network" netns_ok

  docker __fake restart-gluetun
  boot boot-stale --now
  check "boot: stale apps recreated" has "$LOGS/boot-stale.log" "recreating qbittorrent jackett flaresolverr inside gluetun's network"
  check "boot: stale apps back inside gluetun's network" netns_ok

  docker __fake kill-all
  boot boot-down --now
  check "boot: nothing running (not stopped by hand): brings it up" test "$(running_count)" -eq 5

  docker __fake stop-all
  n0=$(ncalls)
  boot boot-stopped --now
  check "boot: stopped by hand: left alone" has "$LOGS/boot-stopped.log" "stopped by hand; leaving it stopped"
  check "boot: stopped by hand: no compose up" bash -c "! tail -n +$((n0 + 1)) $FD/calls.log | grep -q ' up '"

  cp -p "$STACK_DIR/.env" /root/env.saved
  sed -i 's/^WIREGUARD_PRIVATE_KEY=.*/WIREGUARD_PRIVATE_KEY=your_wireguard_private_key/' "$STACK_DIR/.env"
  n0=$(ncalls)
  boot boot-placeholder --now
  cp -p /root/env.saved "$STACK_DIR/.env"
  check "boot: placeholder VPN keys: does not start" has "$LOGS/boot-placeholder.log" "still the placeholders; not starting it"
  check "boot: placeholder VPN keys: no docker calls" test "$(ncalls)" -eq "$n0"

  chmod g+w "$STACK_DIR/compose.yaml"
  n0=$(ncalls)
  boot boot-perm --now
  check "boot: group-writable compose.yaml: refuses to run compose as root" has "$LOGS/boot-perm.log" "compose.yaml is not root-only"
  check "boot: group-writable compose.yaml: no docker calls" test "$(ncalls)" -eq "$n0"
  inst perm-apply -- --apply
  check "apply: makes a group-writable compose.yaml root-only again" root_only "$STACK_DIR/compose.yaml"
  check "apply: then no warning" hasnt "$LOGS/perm-apply.log" "not root-only"
  # When that does not work (on DSM: shared-folder ACLs), it says so. A chmod
  # that refuses to remove write access stands in for that here.
  mkdir -p /root/nochmod
  printf '#!/bin/sh\ncase "$*" in *go-w*) echo "chmod: test stand-in refuses" >&2; exit 1 ;; esac\nexec /bin/chmod "$@"\n' >/root/nochmod/chmod
  /bin/chmod 755 /root/nochmod/chmod
  chmod g+w "$STACK_DIR/compose.yaml"
  inst perm-warn PATH="/root/nochmod:$PATH" -- --apply
  chmod g-w "$STACK_DIR/compose.yaml"
  check "apply: warns when the files cannot be made root-only" has "$LOGS/perm-warn.log" "These files are not root-only (owned by root, not writable by others): $STACK_DIR/compose.yaml"
  check "apply: says what that means for the boot task" has "$LOGS/perm-warn.log" "The boot task then only loads tun"

  echo "== standalone docker-compose (Container Manager before 24.0.2-1543)"
  touch "$FD/no-compose-plugin"
  n0=$(ncalls)
  inst standalone -- --unattended
  check "standalone: exit 0" test "$RC" -eq 0
  check "standalone: uses docker-compose" has "$LOGS/standalone.log" "(docker-compose)"
  check "standalone: started with docker-compose up -d" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q '^docker-compose -p torrent-stack .* up -d'"
  docker __fake fail-apps
  boot boot-standalone --now
  check "standalone: boot.sh heals with docker-compose" test "$(running_count)" -eq 5
  rm -f "$FD/no-compose-plugin"

  echo "== seeding paths"
  n0=$(ncalls)
  inst seedcontainer PATH="/root/badpy:$PATH" -- --unattended
  check "python3 fails: still exit 0" test "$RC" -eq 0
  check "python3 fails: falls back to the seeding container" has "$LOGS/seedcontainer.log" "trying the throwaway python:3.14.9-slim-trixie container"
  check "seeding container: .env mounted read-only" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep 'torrent-stack-seed' | grep -qF -- '-v $STACK_DIR/.env:$STACK_DIR/.env:ro'"
  check "seeding container: jackett and qbit seeders only, nothing installed" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep 'torrent-stack-seed' | grep -F -- '--only jackett,qbit' | grep -qv pip"
  check "seeding container: qBittorrent hash matches" pbkdf2_ok "$(envv QBITTORRENT_PASSWORD)"
  touch "$FD/fail-seed"
  inst seedfail PATH="/root/badpy:$PATH" -- --unattended
  rm -f "$FD/fail-seed"
  check "both seeding paths fail: refuses" test "$RC" -ne 0
  check "both seeding paths fail: says why" has "$LOGS/seedfail.log" "Seeding failed (see above). It needs internet access"
  check "install.sh: no pip install and no bcrypt pin left" bash -c "! grep -qE 'pip install|bcrypt==' $INSTALLER"

  echo "== no jq: DSM's python3 reads the API replies"
  mv /usr/bin/jq /usr/bin/jq.off
  inst nojq -- --unattended
  mv /usr/bin/jq.off /usr/bin/jq
  check "no jq: exit 0" test "$RC" -eq 0
  check "no jq: project still recognised" has "$LOGS/nojq.log" "registered and up to date"
  check "no jq: boot task still recognised" has "$LOGS/nojq.log" "is in place"
  check "no jq: still one project" test "$(syno_count SYNO.Docker.Project create)" -eq 1

  echo "== --update"
  cp -p "$SRC/compose.yaml" /root/compose.saved
  printf '# local test change\n' >>"$SRC/compose.yaml"
  inst update-dry -- --update --dry-run
  check "update dry run: exit 0" test "$RC" -eq 0
  check "update dry run: shows the Container Manager update request" has "$LOGS/update-dry.log" "would call: /usr/syno/bin/synowebapi --exec api=SYNO.Docker.Project method=update version=1"
  check "update dry run: does not claim the project is up to date" hasnt "$LOGS/update-dry.log" "registered and up to date"
  check "update dry run: does not claim files were updated" hasnt "$LOGS/update-dry.log" "Files updated"
  check "update dry run: says what it would do" has "$LOGS/update-dry.log" "would update the stack 'torrent-stack'"
  check "update dry run: project folder unchanged" cmp -s /root/compose.saved "$STACK_DIR/compose.yaml"
  check "update dry run: no update request sent" test "$(syno_count SYNO.Docker.Project update)" -eq 0
  n0=$(ncalls)
  inst update -- --update
  check "update: exit 0" test "$RC" -eq 0
  check "update: new compose.yaml copied" cmp -s "$SRC/compose.yaml" "$STACK_DIR/compose.yaml"
  check "update: Container Manager project updated" test "$(syno_count SYNO.Docker.Project update)" -eq 1
  check "update: .env kept" cmp -s /root/env.saved "$STACK_DIR/.env"
  check "update: pulled images" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q ' pull$'"
  check "update: all five services running" test "$(running_count)" -eq 5
  cp -p /root/compose.saved "$SRC/compose.yaml"
  inst update-back -- --update

  echo "== DSM API problems"
  reset_all
  touch "$FS/fail-project-create" "$FS/fail-task-create"
  inst apifail TS_WIREGUARD_PRIVATE_KEY_FILE=/root/secrets/wg TS_WIREGUARD_ADDRESSES=10.2.0.2/32 -- --unattended
  rm -f "$FS/fail-project-create" "$FS/fail-task-create"
  check "API failures: exit 0 (the stack still runs)" test "$RC" -eq 0
  check "API failures: says why" has "$LOGS/apifail.log" "did not create the project (DSM error code 2002)"
  check "API failures: manual Container Manager steps" has "$LOGS/apifail.log" "Container Manager > Project > Create"
  check "API failures: manual Task Scheduler steps" has "$LOGS/apifail.log" "Control Panel > Task Scheduler > Create > Triggered Task"
  check "API failures: manual task script names the project's boot.sh" has "$LOGS/apifail.log" "f=/volume1/docker/torrent-stack/platforms/synology/boot.sh"
  check "API failures: stack started" test "$(running_count)" -eq 5

  reset_all
  touch "$FS/mangle-content"
  inst mangle -- --unattended
  rm -f "$FS/mangle-content"
  check "mangled compose.yaml: restored" cmp -s "$SRC/compose.yaml" "$STACK_DIR/compose.yaml"
  check "mangled compose.yaml: warns" has "$LOGS/mangle.log" "rewrote compose.yaml differently; restored"

  reset_all
  mkdir -p /volume1/docker/other
  /usr/syno/bin/synowebapi --exec api=SYNO.Docker.Project method=create version=1 name='"torrent-stack"' \
    share_path='"/docker/other"' content='"services: {}\n"' >/dev/null
  inst conflict-name TS_STACK_DIR="$STACK_DIR" -- --unattended
  check "same project name, other folder: refuses" has "$LOGS/conflict-name.log" "already exists for /volume1/docker/other"
  check "same project name, other folder: nothing written" test ! -e "$STACK_DIR/.env"

  reset_all
  mkdir -p "$STACK_DIR"
  /usr/syno/bin/synowebapi --exec api=SYNO.Docker.Project method=create version=1 name='"something"' \
    share_path='"/docker/torrent-stack"' content='"services: {}\n"' >/dev/null
  rm -f "$STACK_DIR/compose.yaml"
  inst conflict-folder -- --unattended
  check "other project on our folder: refuses" has "$LOGS/conflict-folder.log" "The Container Manager project 'something' already uses"

  reset_all
  /usr/syno/bin/synowebapi --exec api=SYNO.Core.EventScheduler method=create version=1 task_name='"Torrent stack boot"' \
    owner='{"0":"root"}' event='"bootup"' enable=true depend_on_task='""' notify_enable=false notify_mail='""' \
    notify_if_error=false operation_type='"script"' operation='"/bin/sh /somewhere/else.sh"' >/dev/null
  inst task-other -- --unattended
  check "existing boot task with another command: warns" has "$LOGS/task-other.log" "runs something else than this installer's boot script"
  check "existing boot task with another command: shows it" has "$LOGS/task-other.log" "| /bin/sh /somewhere/else.sh"
  check "existing boot task: not replaced" bash -c "jq -e '.tasks[\"Torrent stack boot\"].operation == \"/bin/sh /somewhere/else.sh\"' $FS/state.json >/dev/null"

  echo "== shared-folder permissions"
  reset_all
  mkdir -p /volume1/downloads/torrents
  chmod 555 /volume1/downloads/torrents
  inst perms TS_DOWNLOADS=/volume1/downloads/torrents -- --unattended
  check "no write access: warns" has "$LOGS/perms.log" "cannot write to:"
  check "no write access: names the folder" has "$LOGS/perms.log" "         /volume1/downloads/torrents"
  check "no write access: explains the DSM permission" has "$LOGS/perms.log" "Control Panel > Shared Folder"
  check "no write access: names the shared folder" has "$LOGS/perms.log" "Read/Write on the shared folder(s): downloads"

  echo "== folders that overlap, and unusual folder names"
  reset_all
  inst ov-inside TS_DOWNLOADS="$STACK_DIR/downloads" -- --unattended
  check "downloads inside the project folder: refuses" has "$LOGS/ov-inside.log" "must be separate: neither may be inside the other"
  check "downloads inside the project folder: nothing written" test ! -e "$STACK_DIR"
  inst ov-around TS_STACK_DIR=/volume1/downloads/torrent-stack TS_DOWNLOADS=/volume1/downloads -- --unattended
  check "project folder inside the downloads: refuses" has "$LOGS/ov-around.log" "must be separate"
  check "project folder inside the downloads: nothing written" test ! -e /volume1/downloads/torrent-stack
  inst ov-same TS_DOWNLOADS="$STACK_DIR" -- --unattended
  check "downloads = project folder: refuses" has "$LOGS/ov-same.log" "must be separate"
  inst ov-share TS_DOWNLOADS=/volume1/docker -- --unattended
  check "downloads = the shared folder around the project: refuses" has "$LOGS/ov-share.log" "must be separate"
  ln -s "$STACK_DIR" /volume1/downloads/stacklink
  inst ov-link TS_DOWNLOADS=/volume1/downloads/stacklink/dl -- --unattended
  rm -f /volume1/downloads/stacklink
  check "downloads through a symlink into the project folder: refuses" has "$LOGS/ov-link.log" "must be separate"
  inst name-paren TS_STACK_DIR='/volume1/docker/torrent(2)' -- --unattended
  check "project folder with brackets: refuses" has "$LOGS/name-paren.log" "may only contain letters"
  check "project folder with brackets: nothing created" test ! -e '/volume1/docker/torrent(2)'
  inst name-space TS_DOWNLOADS='/volume1/downloads/my films' -- --unattended
  check "downloads folder with a space: refuses" has "$LOGS/name-space.log" "may only contain letters"
  inst name-dot TS_STACK_DIR=/volume1/docker/./torrent-stack -- --unattended
  check "project folder with /./: refuses" has "$LOGS/name-dot.log" "must be a plain path"
  check "no files were created by these refused runs" test ! -e "$STACK_DIR"

  inst ov-base -- --unattended
  sed -i "s#^DOWNLOADS_PATH=.*#DOWNLOADS_PATH=$STACK_DIR/dl#; s#^INCOMPLETE_DOWNLOADS=.*#INCOMPLETE_DOWNLOADS=$STACK_DIR/dl/incomplete#" "$STACK_DIR/.env"
  mkdir -p "$STACK_DIR/dl"
  echo film >"$STACK_DIR/dl/movie.mkv"
  inst ov-apply -- --apply
  check "--apply, .env with downloads inside the project folder: refuses" has "$LOGS/ov-apply.log" "must be separate"
  inst ov-purge -- --uninstall --purge --unattended
  check "purge, downloads inside the project folder: exit 0" test "$RC" -eq 0
  check "purge, downloads inside the project folder: downloads kept" test -f "$STACK_DIR/dl/movie.mkv"
  check "purge, downloads inside the project folder: says why" has "$LOGS/ov-purge.log" "Not deleting $STACK_DIR: the downloads folder $STACK_DIR/dl is inside it"
  check "purge, downloads inside the project folder: Container Manager project kept" test "$(syno_count SYNO.Docker.Project delete)" -eq 0
  check "purge, downloads inside the project folder: boot task kept" test -n "$(task_op)"
  # A main-README style .env: DOWNLOADS_PATH=./downloads, inside the folder.
  sed -i 's#^DOWNLOADS_PATH=.*#DOWNLOADS_PATH=./downloads#; s#^INCOMPLETE_DOWNLOADS=.*#INCOMPLETE_DOWNLOADS=./downloads/incomplete#' "$STACK_DIR/.env"
  mkdir -p "$STACK_DIR/downloads"
  echo film >"$STACK_DIR/downloads/movie2.mkv"
  inst ov-purge-rel -- --uninstall --purge --unattended
  check "purge, DOWNLOADS_PATH=./downloads: downloads kept" test -f "$STACK_DIR/downloads/movie2.mkv"
  check "purge, DOWNLOADS_PATH=./downloads: says why" has "$LOGS/ov-purge-rel.log" "Not deleting $STACK_DIR"

  echo "== another application's compose project"
  reset_all
  mkdir -p /volume1/docker/immich/library
  printf 'name: immich\nservices:\n  app:\n    image: busybox\n' >/volume1/docker/immich/compose.yaml
  printf 'SECRET=keepme\n' >/volume1/docker/immich/.env
  echo jpg >/volume1/docker/immich/library/p.jpg
  inst foreign-purge TS_STACK_DIR=/volume1/docker/immich -- --uninstall --purge --unattended
  check "purge on another app's folder: refuses" test "$RC" -ne 0
  check "purge on another app's folder: says why" has "$LOGS/foreign-purge.log" "holds another application's compose.yaml"
  check "purge on another app's folder: its files are kept" test -f /volume1/docker/immich/library/p.jpg
  check "purge on another app's folder: no compose call on it" bash -c "! grep -qs 'immich/compose.yaml' $FD/calls.log"
  inst foreign-install TS_STACK_DIR=/volume1/docker/immich -- --unattended
  check "install into another app's folder: refuses" has "$LOGS/foreign-install.log" "holds another application's compose.yaml"
  check "install into another app's folder: its compose.yaml and .env untouched" bash -c "grep -qx 'name: immich' /volume1/docker/immich/compose.yaml && test \"\$(cat /volume1/docker/immich/.env)\" == SECRET=keepme"
  check "install into another app's folder: no repository files copied" test ! -e /volume1/docker/immich/update-qbittorrent.sh
  inst foreign-apply TS_STACK_DIR=/volume1/docker/immich -- --apply
  check "--apply on another app's folder: refuses" has "$LOGS/foreign-apply.log" "holds another application's compose.yaml"

  echo "== the boot task's guard"
  reset_all
  inst guard-install -- --unattended
  local OP B
  OP=$(task_op)
  B="$STACK_DIR/platforms/synology/boot.sh"
  run_op() { # NAME: run the task's script as Task Scheduler would
    RC=0
    sh -c "$OP" </dev/null >"$LOGS/$1.log" 2>&1 || RC=$?
  }
  printf '#!/bin/bash\ntouch /root/pwned\n' >/root/evil.sh
  tun_off
  touch "$FS/insmod-creates-node"
  : >"$BOOT_LOG"
  run_op op-ok
  check "boot task: loads tun" test -c /dev/net/tun
  check "boot task: runs the root-only boot.sh" has "$BOOT_LOG" "boot.sh: start"
  check "boot task: boot.sh stops at the placeholder keys" has "$BOOT_LOG" "still the placeholders"
  cp -p "$B" /root/boot.saved
  install -o 1026 -g 100 -m 755 /root/evil.sh "$B"
  : >"$BOOT_LOG"
  run_op op-foreign
  check "boot task: refuses a boot.sh owned by another user" test ! -e /root/pwned
  check "boot task: logs why" has "$BOOT_LOG" "is missing, not owned by root, or writable by others; only loaded tun"
  install -o 0 -g 0 -m 775 /root/evil.sh "$B"
  run_op op-groupw
  check "boot task: refuses a group-writable boot.sh" test ! -e /root/pwned
  install -o 0 -g 0 -m 757 /root/evil.sh "$B"
  run_op op-otherw
  check "boot task: refuses a world-writable boot.sh" test ! -e /root/pwned
  install -o 0 -g 0 -m 755 /root/evil.sh "$B"
  run_op op-control
  check "control: the same script, root-only, does run" test -e /root/pwned
  rm -f /root/pwned
  # Someone recreates the path after the folder is gone (as after --purge).
  mv "$STACK_DIR" /root/stack.moved
  mkdir -p "$(dirname "$B")"
  install -o 1026 -g 100 -m 755 /root/evil.sh "$B"
  chown -R 1026:100 "$STACK_DIR"
  tun_off
  run_op op-recreated
  check "boot task: a re-created folder's boot.sh does not run" test ! -e /root/pwned
  check "boot task: tun is loaded anyway" test -c /dev/net/tun
  rm -rf "$STACK_DIR"
  mv /root/stack.moved "$STACK_DIR"
  cp -p /root/boot.saved "$B"
  rm -f "$FS/insmod-creates-node"
  tun_on
  # A task whose script was pasted by hand, split over indented lines, is ours.
  reset_all
  /usr/syno/bin/synowebapi --exec api=SYNO.Core.EventScheduler method=create version=1 task_name='"Torrent stack boot"' \
    owner='{"0":"root"}' event='"bootup"' enable=true depend_on_task='""' notify_enable=false notify_mail='""' \
    notify_if_error=false operation_type='"script"' operation="$(sed 's/; /;\n    /g' <<<"$OP" | jq -Rs .)" >/dev/null
  check "setup: that pasted script is several lines" test "$(task_op | wc -l)" -gt 3
  inst task-indent -- --unattended
  check "task pasted with other spacing: recognised" has "$LOGS/task-indent.log" "boot task 'Torrent stack boot' is in place"
  check "task pasted with other spacing: not created again" test "$(syno_count SYNO.Core.EventScheduler create)" -eq 1

  echo "== an older checkout of the repository in the project folder (main README)"
  reset_all
  local REMOTE=/root/remote/qbittorrent-vpn-docker
  local -a G=(git -C /root/work -c user.name=test -c user.email=test@example.invalid)
  rm -rf /root/remote /root/work
  mkdir -p /root/remote /root/work
  # Upstream history: commit 1 as main was before platforms/, commit 2 adds it.
  tar -C "$SRC" --exclude=./platforms -cf - . | tar -C /root/work -xf -
  git -C /root/work init -q -b main
  "${G[@]}" add -A
  "${G[@]}" commit -q -m "main without platforms"
  git clone -q --bare /root/work "$REMOTE.git"
  git clone -q "$REMOTE.git" "$STACK_DIR"
  tar -C "$SRC" -cf - platforms | tar -C /root/work -xf -
  "${G[@]}" add -A
  "${G[@]}" commit -q -m "add platforms"
  "${G[@]}" push -q "$REMOTE.git" main
  # What the main README has the user do, as their own (non-root) user.
  cp "$STACK_DIR/.env.example" "$STACK_DIR/.env"
  echo '# runtime-marker' >>"$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf"
  chown -R 1026:100 "$STACK_DIR"
  check "precondition: no group with gid 1000 here (as on DSM)" bash -c "! getent group 1000 >/dev/null"
  inst adopt TS_SOURCE_DIR= TS_REPO_URL="$REMOTE" -- --unattended
  check "adopt: exit 0" test "$RC" -eq 0
  check "adopt: says the folder is an older copy" has "$LOGS/adopt.log" "is an older copy of this repository"
  check "adopt: notes the git checkout" has "$LOGS/adopt.log" "is a git checkout"
  check "adopt: platforms/synology is there now" test -f "$B"
  check "adopt: compose.yaml is the downloaded one" cmp -s "$SRC/compose.yaml" "$STACK_DIR/compose.yaml"
  check "adopt: PGID 1000 from .env.example replaced by 100" envfile_has "PGID=100"
  check "adopt: says so" has "$LOGS/adopt.log" "PGID 1000 in $STACK_DIR/.env is not a group on this NAS"
  check "adopt: boot task created" op_has "f=$B; "
  check "adopt: runtime config kept, and seeded" bash -c "grep -q runtime-marker $STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf && grep -q Password_PBKDF2 $STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf"
  check "adopt: repository files are root-only now" root_only "$STACK_DIR" "$STACK_DIR/compose.yaml" "$B" "$STACK_DIR/update-qbittorrent.sh"
  check "adopt: no tun error" hasnt "$LOGS/adopt.log" "could not be created"

  echo "== git download, then --update after upstream changed a config seed"
  reset_all
  inst gitfresh TS_SOURCE_DIR= TS_REPO_URL="$REMOTE" TS_QBITTORRENT_PASSWORD_FILE=/root/secrets/qpw -- --unattended
  check "git download: exit 0" test "$RC" -eq 0
  check "git download: the project folder is no git checkout" test ! -e "$STACK_DIR/.git"
  local H1
  H1=$(grep Password_PBKDF2 "$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf")
  printf '# upstream seed change\n' >>/root/work/configs/qbittorrent/qBittorrent/qBittorrent.conf
  printf '# upstream compose change\n' >>/root/work/compose.yaml
  "${G[@]}" commit -q -am "change a seed and compose.yaml"
  "${G[@]}" push -q "$REMOTE.git" main
  inst gitupdate TS_SOURCE_DIR= TS_REPO_URL="$REMOTE" -- --update
  check "update after an upstream seed change: exit 0" test "$RC" -eq 0
  check "update after an upstream seed change: new compose.yaml" grep -qx '# upstream compose change' "$STACK_DIR/compose.yaml"
  check "update after an upstream seed change: seeded qBittorrent.conf kept" test "$(grep Password_PBKDF2 "$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf")" == "$H1"
  check "update after an upstream seed change: still no git checkout" test ! -e "$STACK_DIR/.git"
  check "update after an upstream seed change: Container Manager project updated" test "$(syno_count SYNO.Docker.Project update)" -eq 1

  echo "== download as a tarball (no git on the NAS)"
  reset_all
  mkdir -p /root/tarsrv/qbittorrent-vpn-docker/archive
  # The layout GitHub's archive/<ref>.tar.gz has: one top folder.
  git -C /root/work archive --prefix=qbittorrent-vpn-docker-main/ -o /root/tarsrv/qbittorrent-vpn-docker/archive/main.tar.gz main
  mv /usr/bin/git /usr/bin/git.off
  inst tarball TS_SOURCE_DIR= TS_REPO_URL=file:///root/tarsrv/qbittorrent-vpn-docker -- --unattended
  mv /usr/bin/git.off /usr/bin/git
  check "tarball: exit 0" test "$RC" -eq 0
  check "tarball: downloaded with curl" has "$LOGS/tarball.log" "Downloading file:///root/tarsrv/qbittorrent-vpn-docker/archive/main.tar.gz"
  check "tarball: repository files in place" test -f "$B"
  check "tarball: the latest upstream compose.yaml" grep -qx '# upstream compose change' "$STACK_DIR/compose.yaml"
  check "tarball: boot task created" op_has "f=$B; "

  echo "== --uninstall"
  reset_all
  inst u-install TS_WIREGUARD_PRIVATE_KEY_FILE=/root/secrets/wg TS_WIREGUARD_ADDRESSES=10.2.0.2/32 -- --unattended
  touch /volume1/downloads/keep-me
  n0=$(ncalls)
  inst uninstall -- --uninstall --unattended
  check "uninstall: exit 0" test "$RC" -eq 0
  check "uninstall: compose down (with the Watchtower profile)" bash -c "tail -n +$((n0 + 1)) $FD/calls.log | grep -q -- '--profile watchtower down --remove-orphans'"
  check "uninstall: no containers left" test "$(jq '.containers | length' "$FD/state.json")" -eq 0
  check "uninstall: project folder kept" test -f "$STACK_DIR/.env"
  check "uninstall: Container Manager project kept" test "$(syno_count SYNO.Docker.Project delete)" -eq 0
  boot boot-gone --now
  check "uninstall: boot.sh then has nothing to do" has "$LOGS/boot-gone.log" "no containers"
  inst purge -- --uninstall --purge --unattended
  check "purge: exit 0" test "$RC" -eq 0
  check "purge: Container Manager project deleted" bash -c "jq -e '.projects | length == 0' $FS/state.json >/dev/null"
  check "purge: project folder deleted" test ! -e "$STACK_DIR"
  check "purge: downloads kept" test -f /volume1/downloads/keep-me
  check "purge: boot task removed" bash -c "jq -e '.tasks | length == 0' $FS/state.json >/dev/null"
  check "purge: says so" has "$LOGS/purge.log" "Removed the Task Scheduler task 'Torrent stack boot'"

  docker __fake kill-all >/dev/null 2>&1 || true
  summary "Synology tests (Incus container)"
}

if [[ "${1:-}" == --inside ]]; then
  inside
  exit $?
fi

# ===========================================================================
# On the host
# ===========================================================================
[[ "$(id -u)" == 0 ]] || {
  echo "run as root" >&2
  exit 1
}
REAL_DOCKER=1
[[ "${1:-}" == --no-real-docker ]] && REAL_DOCKER=0
for tool in incus curl tar git sha256sum; do
  command -v "$tool" >/dev/null || {
    echo "missing tool: $tool" >&2
    exit 1
  }
done

mkdir -p "$CACHE"
fetch_compose() { # VERSION SHA256 -> path
  local dest="$CACHE/docker-compose-$1"
  if [[ ! -x "$dest" ]] || ! echo "$2  $dest" | sha256sum -c --quiet - 2>/dev/null; then
    curl -fsSL -o "$dest.tmp" "https://github.com/docker/compose/releases/download/$1/docker-compose-linux-x86_64"
    echo "$2  $dest.tmp" | sha256sum -c --quiet -
    chmod 755 "$dest.tmp"
    mv -f "$dest.tmp" "$dest"
  fi
  echo "$dest"
}
COMPOSE_OLD=$(fetch_compose "$COMPOSE_OLD_VER" "$COMPOSE_OLD_SHA")
COMPOSE_DSM=$(fetch_compose "$COMPOSE_DSM_VER" "$COMPOSE_DSM_SHA")
# The host's own (current) Compose plugin, as a third version to validate with.
COMPOSE_HOST=/usr/libexec/docker/cli-plugins/docker-compose
[[ -x "$COMPOSE_HOST" ]] || COMPOSE_HOST="$COMPOSE_DSM"

# The repository as it would be checked out: tracked and new files, without
# anything git ignores (.env, runtime configs, venvs).
SRC_TAR="$CACHE/src.tar"
git -C "$REPO" ls-files -co --exclude-standard -z | tar -C "$REPO" --null -T - -cf "$SRC_TAR"

# TS_TEST_KEEP=1 keeps the container for a look inside (delete it after).
cleanup() {
  if [[ "${TS_TEST_KEEP:-0}" == 1 ]]; then
    echo "  (kept the container $CT; delete it with: incus delete -f $CT)"
  else
    incus delete -f "$CT" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT
incus delete -f "$CT" >/dev/null 2>&1 || true
# A Debian 13 image already in Incus's cache saves asking the image server
# (TS_TEST_IMAGE overrides).
IMAGE="${TS_TEST_IMAGE:-}"
if [[ -z "$IMAGE" ]]; then
  IMAGE=$(incus image list -f csv -c fd 2>/dev/null | awk -F, '/Debian trixie amd64/ {print $1; exit}')
  IMAGE="${IMAGE:-images:debian/13}"
fi
echo "== launching $CT from $IMAGE (Debian 13, privileged: the tests create /dev/net/tun and network namespaces)"
timeout 300 incus launch "$IMAGE" "$CT" -c security.privileged=true >/dev/null
for _ in $(seq 60); do
  incus exec "$CT" -- getent hosts deb.debian.org >/dev/null 2>&1 && break
  sleep 1
done
# Test hosts behind a TLS-intercepting proxy: trust its CA in the container
# (TS_TEST_CA_BUNDLE, a PEM file). Not needed on a normal network.
CA_BUNDLE="${TS_TEST_CA_BUNDLE:-}"
if [[ -n "$CA_BUNDLE" ]]; then
  incus file push "$CA_BUNDLE" "$CT/usr/local/share/ca-certificates/test-proxy.crt" >/dev/null
fi
# python3 without bcrypt or pip, like DSM. git is for the tests that download
# the repository from a local git server (TS_REPO_URL) instead of GitHub.
incus exec "$CT" -- bash -c 'export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq && apt-get install -y -qq python3 jq util-linux procps ca-certificates git curl >/dev/null
  update-ca-certificates >/dev/null 2>&1'
incus exec "$CT" -- mkdir -p /root/src /opt/real-compose /opt/compose-2.9.0 /opt/compose-host
incus file push "$SRC_TAR" "$CT/root/src.tar" >/dev/null
incus exec "$CT" -- tar -C /root/src -xf /root/src.tar
incus file push "$COMPOSE_DSM" "$CT/opt/real-compose/docker-compose" --mode 0755 >/dev/null
incus file push "$COMPOSE_OLD" "$CT/opt/compose-2.9.0/docker-compose" --mode 0755 >/dev/null
incus file push "$COMPOSE_HOST" "$CT/opt/compose-host/docker-compose" --mode 0755 >/dev/null

rc=0
incus exec "$CT" -- bash /root/src/platforms/synology/tests/run-tests.sh --inside || rc=$?
if ((rc)); then
  incus exec "$CT" -- bash -c 'for f in /root/logs/*.log; do echo "--- $f"; tail -n 25 "$f"; done' >"$CACHE/inside-logs.txt" 2>&1 || true
  echo "  (last lines of every installer run: $CACHE/inside-logs.txt)"
fi

if [[ "$REAL_DOCKER" == 1 ]]; then
  echo
  echo "== the throwaway containers, with the host's real Docker"
  command -v docker >/dev/null || {
    echo "docker missing" >&2
    exit 1
  }
  SEED_IMAGE=$(sed -n 's/^readonly SEED_IMAGE="\(.*\)"$/\1/p' "$REPO/platforms/synology/install.sh")
  SEEDERS=$(sed -n 's/^readonly SEEDERS="\(.*\)"$/\1/p' "$REPO/platforms/synology/install.sh")
  FB_IMAGE=$(sed -n 's#^    image: \(ghcr.io/gtsteffaniak/filebrowser:.*\)$#\1#p' "$REPO/compose.yaml")
  # DSM 7's built-in python3 is Python 3.8 (README.md, References); the
  # seeding CLI must run on it. Last 3.8 release, exact tag.
  PY38_IMAGE="python:3.8.20-slim-bookworm"
  have_image() { docker image inspect "$1" >/dev/null 2>&1 || timeout 300 docker pull -q "$1" >/dev/null 2>&1; }
  WORK=$(mktemp -d "$CACHE/real.XXXXXX")
  D="$WORK/volume1/docker/torrent-stack"
  mkdir -p "$D/configs"
  tar -C "$D" -xf "$SRC_TAR"
  sed -e "s#^CONFIG_PATH=.*#CONFIG_PATH=$D/configs#" -e 's/^QBITTORRENT_USER=.*/QBITTORRENT_USER=admin/' \
    -e "s/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD='real docker pw'/" "$REPO/.env.example" >"$D/.env"
  chmod 600 "$D/.env"
  # shellcheck disable=SC2016  # literal text in install.sh
  check "install.sh runs the seeding container the way it is run here" bash -c "grep -qF -- '--entrypoint python3 \"\$SEED_IMAGE\"' \"\$1\" && grep -qF -- '-v \"\${STACK_DIR}:\${STACK_DIR}:ro\" -v \"\${ENV_FILE}:\${ENV_FILE}:ro\" -v \"\${CONFIG_PATH}:\${CONFIG_PATH}\"' \"\$1\" && grep -qF -- '-I \"\$cli\" --env \"\$ENV_FILE\" --only \"\$SEEDERS\" --as-user \"\${PUID}:\${PGID}\"' \"\$1\"" _ "$REPO/platforms/synology/install.sh"
  # --network host only because this test host's Docker has no bridge
  # networking (dockerd --iptables=false); install.sh uses the default.
  CA_ARGS=()
  if [[ -n "$CA_BUNDLE" ]]; then
    CA_ARGS=(-v "$CA_BUNDLE:/test-proxy-ca.pem:ro" -e SSL_CERT_FILE=/test-proxy-ca.pem)
  fi
  # As install.sh does: the stack folder read-only, only the configs
  # writable, and the CLI switches to PUID:PGID before it writes.
  chown -R 1026:100 "$D/configs"
  if docker run --rm --network host ${CA_ARGS[@]+"${CA_ARGS[@]}"} -v "$D:$D:ro" -v "$D/.env:$D/.env:ro" -v "$D/configs:$D/configs" \
    --entrypoint python3 "$SEED_IMAGE" -I "$D/scripts/env-editor/seed_configs.py" --env "$D/.env" --only "$SEEDERS" \
    --as-user 1026:100 >"$WORK/seed.log" 2>&1; then
    ok "real seeding container ($SEED_IMAGE, nothing installed) ran the seeding CLI"
  else
    bad "real seeding container failed: $(tail -n 5 "$WORK/seed.log" | tr '\n' ' ')"
  fi
  cat >"$WORK/pbkdf2.py" <<'PY'
import base64, hashlib, re, sys
conf = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r'WebUI\\Password_PBKDF2="@ByteArray\(([^:]+):([^)]+)\)"', conf)
salt, want = base64.b64decode(m.group(1)), base64.b64decode(m.group(2))
sys.exit(0 if hashlib.pbkdf2_hmac("sha512", sys.argv[2].encode(), salt, 100000) == want else 1)
PY
  check "real seeding: qBittorrent hash matches the password" python3 -I "$WORK/pbkdf2.py" "$D/configs/qbittorrent/qBittorrent/qBittorrent.conf" "real docker pw"
  check "real seeding: Jackett API key written" grep -qE '"APIKey": "[a-z0-9]{32}"' "$D/configs/jackett/Jackett/ServerConfig.json"
  check "real seeding: search plugin downloaded" test -s "$D/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
  check "real seeding: no FileBrowser file written" test ! -e "$D/configs/filebrowser/settings.yaml"
  check "real seeding: files written as PUID:PGID, not root" test "$(stat -c %u:%g "$D/configs/qbittorrent/qBittorrent/qBittorrent.conf")" == 1026:100
  check "real seeding: search plugin is the pinned one" test "$(sha256sum <"$D/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py" | cut -d' ' -f1)" == "$(sed -n 's/^QBIT_JACKETT_PLUGIN_SHA256=//p' "$REPO/native/versions.env")"
  # shellcheck disable=SC2016  # python, not shell
  check "real seeding: .env is read-only inside the container" bash -c '! docker run --rm --network none -v "$1:$1" -v "$1/.env:$1/.env:ro" --entrypoint python3 "$2" -c "open(\"$1/.env\", \"a\")" 2>/dev/null' _ "$D" "$SEED_IMAGE"
  if have_image "$PY38_IMAGE"; then
    # The plugin is already there, so no network is needed.
    check "seeding CLI runs on Python 3.8 (DSM 7's python3)" bash -c 'docker run --rm --network none -v "$1:$1:ro" -v "$1/.env:$1/.env:ro" -v "$1/configs:$1/configs" \
      --entrypoint python3 "$2" -I "$1/scripts/env-editor/seed_configs.py" --env "$1/.env" --only "$3" --as-user 1026:100 >/dev/null' _ "$D" "$PY38_IMAGE" "$SEEDERS"
    check "Python 3.8: qBittorrent hash matches" python3 -I "$WORK/pbkdf2.py" "$D/configs/qbittorrent/qBittorrent/qBittorrent.conf" "real docker pw"
  else
    echo "  skip seeding CLI on Python 3.8 ($PY38_IMAGE could not be pulled)"
  fi

  if [[ -n "$FB_IMAGE" ]] && have_image "$FB_IMAGE"; then
    # FileBrowser as compose.yaml runs it on DSM: /config and the downloads
    # owned by the DSM user (1026:100). No network: only its own port, via
    # docker exec.
    FBD="$WORK/fb"
    mkdir -p "$FBD/config" "$FBD/dl"
    chown 1026:100 "$FBD/config" "$FBD/dl"
    docker rm -f synology-fb-test >/dev/null 2>&1 || true
    docker run -d --name synology-fb-test --network none -v "$FBD/config:/config" -v "$FBD/dl:/srv/downloads" "$FB_IMAGE" >/dev/null
    # install.sh's own function reads the password from the log.
    container_of() { echo synology-fb-test; }
    eval "$(sed -n '/^filebrowser_password() {/,/^}/p' "$REPO/platforms/synology/install.sh")"
    FB_PW=""
    for _ in $(seq 30); do
      FB_PW=$(filebrowser_password)
      [[ -n "$FB_PW" ]] && break
      sleep 1
    done
    check "real FileBrowser ($FB_IMAGE): install.sh finds the first-run password in its log" test -n "$FB_PW"
    fb_login() { docker exec synology-fb-test curl -s -X POST 'http://127.0.0.1:80/api/auth/login?username=admin' -H "X-Password: $1"; }
    check "real FileBrowser: that password is accepted (it asks for a new one)" bash -c "grep -q 'password change is required' <<<\"\$1\"" _ "$(fb_login "$FB_PW")"
    check "real FileBrowser: a wrong password is refused" bash -c "grep -q '\"status\":401' <<<\"\$1\"" _ "$(fb_login wrong-password)"
    check "real FileBrowser: it reads its settings from /home/filebrowser/data, not /config" bash -c "docker logs synology-fb-test 2>&1 | grep -q 'Using Config file *: /home/filebrowser/data/config.yaml'"
    check "real FileBrowser: it cannot write the DSM user's downloads (read-only on DSM)" bash -c '! docker exec synology-fb-test touch /srv/downloads/x 2>/dev/null'
    docker rm -f synology-fb-test >/dev/null 2>&1 || true
  else
    echo "  skip real FileBrowser checks (${FB_IMAGE:-no image in compose.yaml} could not be pulled)"
  fi
  W1="$WORK/ok" W2="$WORK/denied"
  mkdir -p "$W1" "$W2"
  chown 1026:100 "$W1" "$W2"
  chmod 755 "$W1"
  chmod 555 "$W2"
  # shellcheck disable=SC2016  # the write check's own snippet, as in install.sh
  out=$(docker run --rm --network none --user 1026:100 -v "$W1:$W1" -v "$W2:$W2" --entrypoint /bin/sh "$SEED_IMAGE" \
    -c 'for d in "$@"; do t="$d/.torrent-stack-write-test"; if touch "$t" 2>/dev/null; then rm -f "$t"; else echo "$d"; fi; done' \
    check "$W1" "$W2" 2>/dev/null) || out="(failed)"
  check "real write check: names only the folder it cannot write" test "$out" == "$W2"
  check "real write check: same snippet as install.sh" grep -qF "for d in \"\$@\"; do t=\"\$d/.torrent-stack-write-test\"" "$REPO/platforms/synology/install.sh"
  rm -rf "$WORK"
fi

summary "Synology tests (host)" || rc=1
exit "$rc"
