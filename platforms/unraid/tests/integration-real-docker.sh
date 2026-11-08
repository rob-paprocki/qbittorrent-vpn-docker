#!/usr/bin/env bash
#
# platforms/unraid/tests/integration-real-docker.sh
#
# Purpose: an opt-in check with the real docker engine and the real Compose
# Manager Plus wrapper, for a DISPOSABLE Linux machine or container only (it
# writes /etc/unraid-version, /boot, /mnt/user, /var/local/emhttp and
# /usr/local/emhttp the way an Unraid server has them). It installs the stack
# with platforms/unraid/install.sh and fake VPN keys, then checks:
#   - Compose Manager's compose.sh created the containers as project
#     torrent-stack from <appdata>/torrent-stack/compose.yaml;
#   - qBittorrent, Jackett and FlareSolverr use Gluetun's network namespace
#     (no network of their own);
#   - Gluetun sees /gluetun/update-qbittorrent.sh as executable;
#   - an env-editor style `docker compose -f compose.yaml up -d filebrowser`
#     from the stack folder leaves the running container alone (same project
#     and config hash as Compose Manager's call);
#   - the real seeding container wrote the qBittorrent and Jackett configs
#     into <stack>/appdata as PUID 99;
#   - what the README says about FileBrowser: it logs a generated admin
#     password, makes a new one when its container is recreated, and cannot
#     write in the 99:100 downloads folder (it runs as uid 1000).
# Gluetun cannot connect with fake keys, so Compose Manager's "up" fails once
# Gluetun turns unhealthy (about 6 minutes), or at once on a kernel without
# IPv6 (compose.yaml sets an IPv6 sysctl); that failure is expected here.
#
#   TS_TEST_DISPOSABLE=1 bash platforms/unraid/tests/integration-real-docker.sh
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail

[[ "${TS_TEST_DISPOSABLE:-0}" == 1 ]] || {
  echo "Refusing to run: this writes Unraid paths on this machine. Set TS_TEST_DISPOSABLE=1 on a throwaway machine." >&2
  exit 2
}
[[ "$(id -u)" == 0 ]] || {
  echo "run as root" >&2
  exit 1
}

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
CM_PLUS_URL="https://github.com/mstrhakr/compose_plugin"
CM_PLUS_COMMIT="5e9227530b204ca668f1f0b9b22e940a99c6975f"
WEBGUI_COMMIT="b135287c706a30da44f71cc7820615209e83e9a0"
CACHE="${TS_TEST_CACHE:-${TMPDIR:-/tmp}/torrent-stack-unraid-tests}"
STACK_DIR="/mnt/user/appdata/torrent-stack"
CM_ROOT="/boot/config/plugins/compose.manager/projects"
LOGS="$CACHE/integration-logs"

PASS=0
FAIL=0
check() {
  local d=$1
  shift
  if "$@"; then
    PASS=$((PASS + 1))
    echo "  ok   $d"
  else
    FAIL=$((FAIL + 1))
    echo "  FAIL $d"
  fi
}

mkdir -p "$CACHE" "$LOGS"
if [[ "$(git -C "$CACHE/compose_plugin" rev-parse HEAD 2>/dev/null || true)" != "$CM_PLUS_COMMIT" ]]; then
  rm -rf "$CACHE/compose_plugin"
  git init -q "$CACHE/compose_plugin"
  git -C "$CACHE/compose_plugin" fetch -q --depth 1 "$CM_PLUS_URL" "$CM_PLUS_COMMIT"
  git -C "$CACHE/compose_plugin" checkout -q FETCH_HEAD
fi
[[ -s "$CACHE/Wrappers-${WEBGUI_COMMIT}.php" ]] ||
  curl -fsSL "https://raw.githubusercontent.com/unraid/webgui/${WEBGUI_COMMIT}/emhttp/plugins/dynamix/include/Wrappers.php" \
    -o "$CACHE/Wrappers-${WEBGUI_COMMIT}.php"

# --- An Unraid-shaped machine ---
printf 'version="7.2.1"\n' >/etc/unraid-version
mkdir -p /var/local/emhttp /boot/config/plugins/compose.manager "$CM_ROOT" /mnt/user/appdata /mnt/user/downloads \
  /usr/local/emhttp/plugins/dynamix/include
printf 'mdState="STARTED"\ntimeZone="Etc/UTC"\n' >/var/local/emhttp/var.ini
rm -rf /usr/local/emhttp/plugins/compose.manager
cp -RT "$CACHE/compose_plugin/source/compose.manager" /usr/local/emhttp/plugins/compose.manager
chmod -R +x /usr/local/emhttp/plugins/compose.manager/scripts /usr/local/emhttp/plugins/compose.manager/event
cp "$CACHE/Wrappers-${WEBGUI_COMMIT}.php" /usr/local/emhttp/plugins/dynamix/include/Wrappers.php
cp "$CACHE/compose_plugin/compose.manager.plg" /boot/config/plugins/compose.manager.plg
printf 'PROJECTS_FOLDER="%s"\n' "$CM_ROOT" >/boot/config/plugins/compose.manager/compose.manager.cfg
php_scan_dir=$(php --ini | sed -n 's/^Scan for additional .ini files in: //p')
[[ -n "$php_scan_dir" && "$php_scan_dir" != "(none)" ]] && printf 'short_open_tag = On\n' >"$php_scan_dir/99-unraid-test.ini"

umask 077
head -c 32 /dev/urandom | base64 >"$CACHE/wg.key"
printf 'integration-test-pw\n' >"$CACHE/qbit.pw"
umask 022

# --- Install (real docker; the shim only adds a test CA/proxy to the seeding container) ---
export SHIM_LOG="$LOGS/calls.log" SHIM_REAL_DOCKER_ALL=1 PATH="$HERE/shims:$PATH"
chmod +x "$HERE/shims/"*
: >"$SHIM_LOG"
rc=0
TS_SOURCE_DIR="$REPO" TS_WIREGUARD_PRIVATE_KEY_FILE="$CACHE/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$CACHE/qbit.pw" \
  timeout 1500 bash "$REPO/platforms/unraid/install.sh" --unattended </dev/null >"$LOGS/install.out" 2>&1 || rc=$?
echo "installer exit: $rc (non-zero expected: Gluetun cannot connect with fake keys)"

project_of() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project"}}' "$1" 2>/dev/null; }
file_of() { docker inspect -f '{{index .Config.Labels "com.docker.compose.project.config_files"}}' "$1" 2>/dev/null; }
id_of() { docker ps -aq --filter "label=com.docker.compose.project=torrent-stack" --filter "label=com.docker.compose.service=$1" | head -n1; }

g=$(id_of gluetun)
f=$(id_of filebrowser)
q=$(id_of qbittorrent)
check "Compose Manager's compose.sh ran 'up' (wrapper log)" grep -q -- '-p torrent-stack up' "$SHIM_LOG"
check "gluetun container exists in project torrent-stack" test "$(project_of "$g")" == torrent-stack
check "containers come from the stack folder's compose.yaml" test "$(file_of "$g")" == "$STACK_DIR/compose.yaml"
check "qBittorrent uses Gluetun's network namespace" test "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$q")" == "container:$(docker inspect -f '{{.Id}}' "$g")"
for svc in jackett flaresolverr; do
  c=$(id_of "$svc")
  check "$svc uses Gluetun's network namespace" test "$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$c")" == "container:$(docker inspect -f '{{.Id}}' "$g")"
done
if [[ "$(docker inspect -f '{{.State.Running}}' "$g")" == true ]]; then
  check "update-qbittorrent.sh is executable inside Gluetun" docker exec "$g" test -x /gluetun/update-qbittorrent.sh
else
  # Gluetun did not start (for example on a kernel booted with
  # ipv6.disable=1, where compose's IPv6 sysctl cannot be set). Check the
  # same read-only bind mount in a throwaway container instead.
  echo "  note gluetun is not running: $(docker inspect -f '{{.State.Error}}' "$g" | cut -c1-160)"
  check "update-qbittorrent.sh is executable through a read-only bind mount (as in Gluetun)" \
    docker run --rm --network none -v "$STACK_DIR/update-qbittorrent.sh:/gluetun/update-qbittorrent.sh:ro" \
    --entrypoint /bin/sh python:3.14.9-slim-trixie -c 'test -x /gluetun/update-qbittorrent.sh'
fi
check "FileBrowser is running" test "$(docker inspect -f '{{.State.Running}}' "$f")" == true
before=$(docker inspect -f '{{.Id}}' "$f")
(cd "$STACK_DIR" && docker compose -f "$STACK_DIR/compose.yaml" up -d --no-deps filebrowser) >"$LOGS/editor-up.out" 2>&1 || true
after=$(docker inspect -f '{{.Id}}' "$(id_of filebrowser)")
check "env-editor style 'docker compose up -d filebrowser' does not recreate it" test "$before" == "$after"

# The real seeding container (python image by digest, no pip, as 99:100).
check "seeded qBittorrent password hash in appdata/" grep -q 'WebUI\\Password_PBKDF2="@ByteArray(' "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf"
check "seeded Jackett API key in appdata/" grep -q '"APIKey": *"[a-z0-9]\{32\}"' "$STACK_DIR/appdata/jackett/Jackett/ServerConfig.json"
check "Jackett search plugin downloaded by the seeding container" test -s "$STACK_DIR/appdata/qbittorrent/qBittorrent/nova3/engines/jackett.py"
check "seeded files written as PUID 99 (the CLI dropped root)" test "$(stat -c %u "$STACK_DIR/appdata/qbittorrent/qBittorrent/nova3/engines/jackett.py")" == 99
# (This install copies TS_SOURCE_DIR, so there is no git checkout to ask;
# run-tests.sh checks `git status` on a git clone install.)
check "nothing seeded into the repository's configs/ folders" \
  bash -c "! grep -rqs 'Password_PBKDF2\|APIKey' '$STACK_DIR/configs' '$REPO/configs'"

# What the README says about FileBrowser (limitations of the current image).
fb_pw() { docker logs "$1" 2>&1 | grep -i 'initial admin password' | tail -n1 | sed 's/.*: //'; }
sleep 5
pw1=$(fb_pw "$(id_of filebrowser)")
check "FileBrowser logs a generated admin password (docker logs ... | grep -i 'initial admin password')" test -n "$pw1"
check "FileBrowser runs as uid 1000 and cannot write in the 99:100 downloads folder" \
  bash -c "[[ \$(docker exec '$(id_of filebrowser)' id -u) == 1000 ]] && ! docker exec '$(id_of filebrowser)' touch /srv/downloads/incomplete/fb-write-test 2>/dev/null"
docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" up -d --no-deps --force-recreate filebrowser >"$LOGS/fb-recreate.out" 2>&1 || true
sleep 8
pw2=$(fb_pw "$(id_of filebrowser)")
check "a recreated FileBrowser container makes a new admin password" test -n "$pw2" -a "$pw1" != "$pw2"

docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" down >"$LOGS/down.out" 2>&1 || true
echo "passed: $PASS  failed: $FAIL  (logs: $LOGS)"
[[ "$FAIL" == 0 ]]
