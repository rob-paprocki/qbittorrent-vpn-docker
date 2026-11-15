#!/usr/bin/env bash
#
# platforms/truenas/tests/runtime-images.sh
#
# Purpose: check two things against the real container images, which the
# shim-based run-tests.sh cannot:
#   1. qBittorrent (lscr.io/linuxserver/qbittorrent): the configs the
#      TrueNAS installer seeds on a fresh install keep the image's defaults
#      (downloads to /downloads, UPnP off) and log in with the seeded
#      password; and a re-seeded password still works after qBittorrent has
#      started once (5.3 moves its login to a [WebUI] section), both with
#      and without truenas_app.py's qbit-webui-fix (the seeding CLI now
#      writes [WebUI] itself once the file has been migrated).
#   2. FileBrowser (ghcr.io/gtsteffaniak/filebrowser:stable), started from
#      the filebrowser service of a YAML rendered by truenas_app.py (that
#      is compose.yaml's service), on folders with the owners and modes
#      install.sh gives them: the admin login is the qBittorrent password,
#      its database survives `up --force-recreate` (what TrueNAS runs on
#      every app update), and it can create files in the downloads (owned
#      by 568:568) through the PGID group, not without that group's access.
# The containers get no network (--network none / network_mode: none); the
# checks run curl inside them. Images that are not present locally are
# skipped (pull them first: docker pull IMAGE). Nothing is pulled here.
#
# Usage (as root, outside run-tests.sh): platforms/truenas/tests/runtime-images.sh
#   TS_TEST_WORK=dir   keep the work files there (default: a temp dir)
# Needs: docker with the compose plugin, python3 with PyYAML, network access to raw.githubusercontent.com (the pinned search plugin).
#
# License: MIT (see LICENSE in the repository root).

set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
H="$REPO/platforms/truenas/truenas_app.py"
QBIT_IMAGE=lscr.io/linuxserver/qbittorrent:latest
FB_IMAGE=ghcr.io/gtsteffaniak/filebrowser:stable
[[ "$(id -u)" -eq 0 ]] || {
  echo "run as root" >&2
  exit 1
}
WORK="${TS_TEST_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
chmod 755 "$WORK"
umask 077
PASS=0 FAIL=0 SKIP=0
ok() { PASS=$((PASS + 1)) && printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)) && printf '  FAIL  %s\n' "$1"; }
skip() { SKIP=$((SKIP + 1)) && printf '  skip  %s\n' "$1"; }
expect() { # description expected actual
  if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}
cleanup() {
  docker rm -f tnrt-qbit >/dev/null 2>&1 || true
  if [[ -f "$WORK/fb/compose.yaml" ]]; then
    docker compose -p tnrt-fb -f "$WORK/fb/compose.yaml" down >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT

# ---------------------------------------------------------------------------
echo "1. qBittorrent: seeded configs with the real image"
if ! docker image inspect "$QBIT_IMAGE" >/dev/null 2>&1; then
  skip "$QBIT_IMAGE is not present locally"
else
  echo "  image: $(docker image inspect "$QBIT_IMAGE" --format '{{index .Config.Labels "build_version"}}')"
  Q="$WORK/qbit"
  rm -rf "$Q"
  mkdir -p "$Q/config/qbittorrent" "$Q/dl/incomplete" "$Q/seed"
  chown -R 568:568 "$Q/config" "$Q/dl" "$Q/seed"
  chmod 755 "$Q"
  CONF="$Q/config/qbittorrent/qBittorrent/qBittorrent.conf"
  # The installer runs these steps as the apps' user (run-tests.sh checks
  # that); here they run as root and the files are handed to 568 after, so
  # the work folder may sit anywhere.
  as568() { "$@"; }
  seed() { # password [--no-fix]: the installer's seed_configs steps
    sed -e 's|^QBITTORRENT_USER=.*|QBITTORRENT_USER=admin|' \
      -e "s|^QBITTORRENT_PASSWORD=.*|QBITTORRENT_PASSWORD=$1|" "$REPO/.env.example" >"$Q/seed/seed.env"
    chown 568:568 "$Q/seed/seed.env"
    as568 python3 -I -B "$H" qbit-defaults --repo "$REPO" --conf "$CONF" >/dev/null
    as568 python3 -I -B "$H" fetch-plugin --repo "$REPO" --dest "$Q/config/qbittorrent/qBittorrent/nova3/engines/jackett.py" >/dev/null
    as568 python3 -I -B "$REPO/scripts/env-editor/seed_configs.py" --env "$Q/seed/seed.env" \
      --config-root "$Q/config" --only jackett,qbit --jackett-port 9117 >/dev/null
    if [[ "${2:-}" != --no-fix ]]; then
      as568 python3 -I -B "$H" qbit-webui-fix --repo "$REPO" --conf "$CONF" >/dev/null
    fi
    chown -R 568:568 "$Q/config"
  }
  start() {
    docker run -d --name tnrt-qbit --network none -e PUID=568 -e PGID=568 -e TZ=UTC -e WEBUI_PORT=8090 \
      -v "$Q/config/qbittorrent:/config" -v "$Q/dl:/downloads" -v "$Q/dl/incomplete:/downloads/incomplete" \
      "$QBIT_IMAGE" >/dev/null
    local _
    for _ in $(seq 1 90); do
      docker exec tnrt-qbit curl -fs -o /dev/null http://127.0.0.1:8090/ 2>/dev/null && return 0
      sleep 1
    done
    docker logs tnrt-qbit 2>&1 | tail -n 20
    return 1
  }
  login() { # password -> HTTP status
    docker exec tnrt-qbit curl -s -o /dev/null -w '%{http_code}' -c /tmp/c \
      --data-urlencode username=admin --data-urlencode "password=$1" http://127.0.0.1:8090/api/v2/auth/login
  }
  stop() { docker stop -t 30 tnrt-qbit >/dev/null && docker rm tnrt-qbit >/dev/null; }

  seed 'first-Pass-1'
  start
  expect "fresh install: seeded password logs in" 204 "$(login 'first-Pass-1')"
  PREFS=$(docker exec tnrt-qbit curl -s -b /tmp/c http://127.0.0.1:8090/api/v2/app/preferences)
  expect "  ... saves to /downloads (the downloads dataset), not /config/Downloads" "/downloads" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["save_path"].rstrip("/"))' "$PREFS")"
  expect "  ... incomplete downloads in /downloads/incomplete" "/downloads/incomplete" \
    "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["temp_path"].rstrip("/"))' "$PREFS")"
  expect "  ... UPnP off" "False" "$(python3 -c 'import json,sys; print(json.loads(sys.argv[1])["upnp"])' "$PREFS")"
  stop
  expect "after the first start qBittorrent keeps its login in [WebUI]" 1 \
    "$(grep -c '^\[WebUI\]' "$CONF")"
  cp -p "$CONF" "$Q/conf.after-first-start"

  seed 'second-Pass-2' --no-fix
  start
  # This used to be refused (401): the seeding CLI only wrote [Preferences].
  # It now also writes [WebUI] in a migrated file (seed_configs.py,
  # _qbit_conf_migrated), so qbit-webui-fix is only a tidy-up.
  expect "re-seed WITHOUT qbit-webui-fix: the seeding CLI's own [WebUI] step makes the new password work" 204 "$(login 'second-Pass-2')"
  stop

  cp -p "$Q/conf.after-first-start" "$CONF"
  seed 'second-Pass-2'
  start
  expect "re-seed WITH qbit-webui-fix: the new password logs in" 204 "$(login 'second-Pass-2')"
  expect "  ... and the old one no longer does" 401 "$(login 'first-Pass-1')"
  stop
fi

# ---------------------------------------------------------------------------
echo "2. FileBrowser: the rendered service with the real image"
if ! docker image inspect "$FB_IMAGE" >/dev/null 2>&1; then
  skip "$FB_IMAGE is not present locally"
else
  echo "  image: $(docker image inspect "$FB_IMAGE" --format '{{index .Config.Labels "org.opencontainers.image.version"}}')"
  F="$WORK/fb"
  rm -rf "$F"
  mkdir -p "$F/mnt/configs/filebrowser" "$F/mnt/downloads"
  chmod 755 "$F" "$F/mnt"
  # As install.sh leaves them (prepare_folders, create_datasets).
  chown 1000:568 "$F/mnt/configs/filebrowser"
  chmod 2770 "$F/mnt/configs/filebrowser"
  chown 568:568 "$F/mnt/downloads"
  chmod 2775 "$F/mnt/downloads"
  # A finished download as qBittorrent (568:568, umask 022) leaves it.
  echo data >"$F/mnt/downloads/done.mkv"
  chown 568:568 "$F/mnt/downloads/done.mkv"
  chmod 644 "$F/mnt/downloads/done.mkv"
  PW='fb-Pa$$word-1'
  printf '%s\0' "CONFIG_PATH=$F/mnt/configs" "DOWNLOADS_PATH=$F/mnt/downloads" \
    "INCOMPLETE_DOWNLOADS=$F/mnt/downloads/incomplete" QBITTORRENT_USER=admin \
    "QBITTORRENT_PASSWORD=$PW" PUID=568 PGID=568 TZ=UTC >"$F/layer"
  python3 -I -B "$H" merge --repo "$REPO" --layer "$F/layer" --out "$F/values.json" --need-paths
  python3 -I -B "$H" render --repo "$REPO" --values "$F/values.json" --app-name tnrt \
    --source-dir "$F/mnt/source" --allowed-root "$F/mnt" --out-yaml "$F/rendered.yaml"
  # Only the filebrowser service, without network and published port.
  python3 - "$F/rendered.yaml" "$F/compose.yaml" <<'PY'
import sys, yaml
c = yaml.safe_load(open(sys.argv[1]))
fb = c["services"]["filebrowser"]
fb.pop("ports", None)
fb["network_mode"] = "none"
yaml.safe_dump({"services": {"filebrowser": fb}}, open(sys.argv[2], "w"))
PY
  chmod 644 "$F/compose.yaml"
  fb_up() { # extra compose up options
    docker compose -p tnrt-fb -f "$F/compose.yaml" up -d "$@" >/dev/null 2>&1
    local _
    for _ in $(seq 1 60); do
      docker compose -p tnrt-fb -f "$F/compose.yaml" exec -T filebrowser curl -fs -o /dev/null http://127.0.0.1:80/health 2>/dev/null && return 0
      sleep 1
    done
    docker compose -p tnrt-fb -f "$F/compose.yaml" logs 2>&1 | tail -n 20
    return 1
  }
  fb_login() { # password -> HTTP status (the session cookie is kept in the container)
    docker compose -p tnrt-fb -f "$F/compose.yaml" exec -T filebrowser curl -s -o /dev/null -w '%{http_code}' \
      -c /tmp/fb.cookies -X POST 'http://127.0.0.1:80/api/auth/login?username=admin' -H "X-Password: $1"
  }
  fb_api() { # method query -> HTTP status, logged in as admin (FileBrowser's only source is /srv, named srv)
    docker compose -p tnrt-fb -f "$F/compose.yaml" exec -T filebrowser curl -s -o /dev/null -w '%{http_code}' \
      -b /tmp/fb.cookies -X "$1" "http://127.0.0.1:80/api/resources?source=srv&$2"
  }
  fb_up
  expect "admin logs in with the qBittorrent password (with a \$ in it)" 200 "$(fb_login "$PW")"
  expect "  ... admin/admin does not" 401 "$(fb_login admin)"
  if [[ -f "$F/mnt/configs/filebrowser/database.sqlite" ]]; then ok "  ... database in the configs dataset"; else bad "  ... database in the configs dataset"; fi
  expect "  ... its container user is uid 1000 with the extra group 568 (compose.yaml's group_add)" \
    "uid=1000 gid=1000 groups=568,1000" \
    "$(docker compose -p tnrt-fb -f "$F/compose.yaml" exec -T filebrowser sh -c 'echo "uid=$(id -u) gid=$(id -g) groups=$(id -G | tr " " "\n" | sort -n | paste -sd, -)"')"
  fb_login "$PW" >/dev/null
  expect "FileBrowser creates a folder in the downloads (568:568, 2775) through group 568" 200 \
    "$(fb_api POST 'path=%2Fdownloads%2Ffrom-filebrowser%2F&isDir=true')"
  expect "  ... which belongs to group 568 (setgid on the downloads)" 568 \
    "$(stat -c %g "$F/mnt/downloads/from-filebrowser" 2>/dev/null || echo missing)"
  expect "  ... and deletes a file qBittorrent saved there (568:568, 644)" 200 \
    "$(fb_api DELETE 'path=%2Fdownloads%2Fdone.mkv')"
  chmod 0755 "$F/mnt/downloads"
  fb_api POST 'path=%2Fdownloads%2Fnot-allowed%2F&isDir=true' >/dev/null || true
  if [[ ! -e "$F/mnt/downloads/not-allowed" ]]; then
    ok "  ... with the downloads at 0755 (no group write) it cannot create a folder there"
  else
    bad "  ... with the downloads at 0755 (no group write) it cannot create a folder there"
  fi
  chmod 2775 "$F/mnt/downloads"
  fb_up --force-recreate
  if docker compose -p tnrt-fb -f "$F/compose.yaml" logs 2>&1 | grep -q 'Using existing database'; then
    ok "after up --force-recreate (a TrueNAS update) the database is kept"
  else
    bad "after up --force-recreate (a TrueNAS update) the database is kept"
  fi
  expect "  ... and the login still works" 200 "$(fb_login "$PW")"
fi

echo
echo "Passed: $PASS  Failed: $FAIL  Skipped: $SKIP"
((FAIL == 0))
