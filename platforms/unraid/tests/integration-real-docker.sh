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
#     into <stack>/appdata as PUID 99, with the search plugin pointing at
#     127.0.0.1:9117;
#   - a non-default JACKETT_PORT / FLARESOLVERR_PORT is published by Gluetun
#     to Jackett's 9117 and FlareSolverr's 8191;
#   - what the README says about FileBrowser: user "admin" logs in with the
#     qBittorrent password (one with a space, $, ", \ and #); it keeps its
#     database in <stack>/appdata/filebrowser across container recreates and
#     --apply; it runs as uid 1000 with group 100 and can upload and delete
#     in the 99:100 downloads folder; a new QBITTORRENT_PASSWORD reaches it
#     through --apply; and after an old install's folder modes (755, no
#     database) make it fail, --apply gets it running again.
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
# A space, $, ", \ and # must reach FileBrowser exactly (through .env and
# compose's ${QBITTORRENT_PASSWORD}).
QBIT_PW='int Pa$s"w\d#1x'
printf '%s\n' "$QBIT_PW" >"$CACHE/qbit.pw"
umask 022

# --- Install (real docker; the shim only adds a test CA/proxy to the seeding container) ---
export SHIM_LOG="$LOGS/calls.log" SHIM_REAL_DOCKER_ALL=1 PATH="$HERE/shims:$PATH"
chmod +x "$HERE/shims/"*
: >"$SHIM_LOG"
rc=0
TS_SOURCE_DIR="$REPO" TS_WIREGUARD_PRIVATE_KEY_FILE="$CACHE/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$CACHE/qbit.pw" TS_JACKETT_PORT=19117 TS_FLARESOLVERR_PORT=18191 \
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
binding() { docker inspect -f "{{range \$p, \$b := .HostConfig.PortBindings}}{{if eq \$p \"$2\"}}{{range \$b}}{{.HostPort}}{{end}}{{end}}{{end}}" "$1"; }
check "Gluetun publishes server port 19117 to Jackett's 9117" test "$(binding "$g" 9117/tcp)" == 19117
check "Gluetun publishes server port 18191 to FlareSolverr's 8191" test "$(binding "$g" 8191/tcp)" == 18191
check "Gluetun publishes qBittorrent's 8090 as 8090" test "$(binding "$g" 8090/tcp)" == 8090
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
check "search plugin points at Jackett inside Gluetun's network (127.0.0.1:9117)" \
  grep -q '"url": "http://127.0.0.1:9117"' "$STACK_DIR/appdata/qbittorrent/qBittorrent/nova3/engines/jackett.json"
check "seeded files written as PUID 99 (the CLI dropped root)" test "$(stat -c %u "$STACK_DIR/appdata/qbittorrent/qBittorrent/nova3/engines/jackett.py")" == 99
# (This install copies TS_SOURCE_DIR, so there is no git checkout to ask;
# run-tests.sh checks `git status` on a git clone install.)
check "nothing seeded into the repository's configs/ folders" \
  bash -c "! grep -rqs 'Password_PBKDF2\|APIKey' '$STACK_DIR/configs' '$REPO/configs'"

# What the README says about FileBrowser.
FB_URL="http://127.0.0.1:8081"
FB_DB="$STACK_DIR/appdata/filebrowser/database.sqlite"
urlenc() { python3 -c 'import sys, urllib.parse; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"; }
# fb_login PASSWORD: HTTP status of FileBrowser's login as "admin" (the
# password goes URL-encoded in the X-Password header, as its web UI sends it).
fb_login() {
  curl -s -o "$LOGS/fb-token" -w '%{http_code}' -X POST "$FB_URL/api/auth/login?username=admin" \
    -H "X-Password: $(urlenc "$1")"
}
fb_wait() {
  for _ in $(seq 1 30); do
    curl -s -o /dev/null "$FB_URL/health" && return 0
    sleep 1
  done
  return 1
}
fb_wait || true
fbc=$(id_of filebrowser)
check "FileBrowser runs as uid 1000 with group 100 (users) added" \
  bash -c "[[ \$(docker exec '$fbc' id -u) == 1000 ]] && docker exec '$fbc' id -G | tr ' ' '\n' | grep -qx 100"
check "FileBrowser keeps its database in appdata/filebrowser" test -s "$FB_DB"
check "FileBrowser took the admin password from FILEBROWSER_ADMIN_PASSWORD" \
  bash -c "docker logs '$fbc' 2>&1 | grep -q 'Using admin password from FILEBROWSER_ADMIN_PASSWORD' && ! docker logs '$fbc' 2>&1 | grep -qi 'Generated initial admin password'"
check "FileBrowser login: admin + the qBittorrent password (space, \$, \", \\, #)" test "$(fb_login "$QBIT_PW")" == 200
tok=$(cat "$LOGS/fb-token")
check "FileBrowser login: a wrong password is refused" test "$(fb_login "wrong-$QBIT_PW")" != 200
up=$(curl -s -o /dev/null -w '%{http_code}' -X POST -H "Authorization: Bearer $tok" --data-binary 'hello' \
  "$FB_URL/api/resources?source=srv&path=$(urlenc /downloads/incomplete/fb-upload-test.txt)")
check "FileBrowser can upload into the 99:100 downloads folder (group write)" \
  bash -c "[[ '$up' == 200 && \$(stat -c %u:%g /mnt/user/downloads/incomplete/fb-upload-test.txt) == 1000:100 ]]"
del=$(curl -s -o /dev/null -w '%{http_code}' -X DELETE -H "Authorization: Bearer $tok" \
  "$FB_URL/api/resources?source=srv&path=$(urlenc /downloads/incomplete/fb-upload-test.txt)")
check "FileBrowser can delete there" bash -c "[[ '$del' == 200 && ! -e /mnt/user/downloads/incomplete/fb-upload-test.txt ]]"

# A recreated container keeps the database: FileBrowser logs "quickSetup
# created admin user" only when it makes a new database.
docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" up -d --no-deps --force-recreate filebrowser >"$LOGS/fb-recreate.out" 2>&1 || true
fb_wait || true
fbc2=$(id_of filebrowser)
check "FileBrowser container was recreated" test "$fbc2" != "$fbc"
check "recreated FileBrowser reuses its database (no new admin user made)" \
  bash -c "docker logs '$fbc2' 2>&1 | grep -q 'Resetting admin user' && ! docker logs '$fbc2' 2>&1 | grep -q 'quickSetup created admin user'"
check "recreated FileBrowser: same login" test "$(fb_login "$QBIT_PW")" == 200

# A new password in .env (as the ENV tab writes it), then --apply: it
# re-seeds qBittorrent, fixes the folders while FileBrowser runs (group 100
# on its database), and Compose recreates FileBrowser with the new password.
NEW_PW='second Pa$s"w\d#2y'
python3 - "$STACK_DIR/.env" "$NEW_PW" <<'PY'
import pathlib, re, sys
p = pathlib.Path(sys.argv[1])
p.write_text(re.sub(r"(?m)^QBITTORRENT_PASSWORD=.*$", lambda m: "QBITTORRENT_PASSWORD='%s'" % sys.argv[2], p.read_text()))
PY
rc=0
TS_SOURCE_DIR="$REPO" timeout 900 bash "$REPO/platforms/unraid/install.sh" --apply </dev/null >"$LOGS/apply.out" 2>&1 || rc=$?
echo "--apply exit: $rc (non-zero expected: Gluetun cannot connect)"
fb_wait || true
fbc3=$(id_of filebrowser)
check "--apply: FileBrowser's database is group 100 and group-writable" \
  bash -c "[[ \$(stat -c %g '$FB_DB') == 100 && \$(( 0\$(stat -c %a '$FB_DB') & 060 )) == 48 ]]"
check "--apply: the new qBittorrent password logs in to FileBrowser" test "$(fb_login "$NEW_PW")" == 200
check "--apply: the old password no longer does" test "$(fb_login "$QBIT_PW")" != 200
check "--apply: FileBrowser kept its database (no new admin user made)" \
  bash -c "! docker logs '$fbc3' 2>&1 | grep -q 'quickSetup created admin user'"
check "--apply: FileBrowser logs no database write errors" \
  bash -c "! docker logs '$fbc3' 2>&1 | grep -qi 'readonly database'"

# Upgrade path (README, "Coming from an install made before ..."): the old
# installer left appdata/filebrowser empty (FileBrowser kept its database in
# the container), 99:100 and 755, and its --update recreates FileBrowser with
# the new compose.yaml. FileBrowser then cannot create its database and keeps
# restarting, until the new installer's --apply fixes the folder.
docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" stop filebrowser >/dev/null 2>&1 || true
rm -f "$STACK_DIR/appdata/filebrowser/"database.sqlite*
chown 99:100 "$STACK_DIR/appdata/filebrowser"
chmod 755 "$STACK_DIR/appdata/filebrowser"
docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" up -d --no-deps --force-recreate filebrowser >"$LOGS/fb-old.out" 2>&1 || true
sleep 15
fbc4=$(id_of filebrowser)
check "old folder modes: FileBrowser cannot open its database and restarts (the failure the README describes)" \
  bash -c "docker logs '$fbc4' 2>&1 | grep -qi 'unable to open database file' && [[ \$(docker inspect -f '{{.RestartCount}}' '$fbc4') -ge 1 ]]"
rc=0
TS_SOURCE_DIR="$REPO" timeout 900 bash "$REPO/platforms/unraid/install.sh" --apply </dev/null >"$LOGS/apply-upgrade.out" 2>&1 || rc=$?
echo "--apply (upgrade) exit: $rc (non-zero expected: Gluetun cannot connect)"
for _ in $(seq 1 60); do
  [[ "$(fb_login "$NEW_PW")" == 200 ]] && break
  sleep 2
done
check "after --apply: FileBrowser starts again and the login works" test "$(fb_login "$NEW_PW")" == 200

docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" down >"$LOGS/down.out" 2>&1 || true
echo "passed: $PASS  failed: $FAIL  (logs: $LOGS)"
[[ "$FAIL" == 0 ]]
