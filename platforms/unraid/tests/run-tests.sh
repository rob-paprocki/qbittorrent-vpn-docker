#!/usr/bin/env bash
#
# platforms/unraid/tests/run-tests.sh
#
# Purpose: test platforms/unraid/install.sh on a Linux machine that is not
# Unraid. Run as root:  bash platforms/unraid/tests/run-tests.sh
#
# How: the script re-runs itself in a private mount namespace (unshare -m)
# and builds a fake Unraid root there, so nothing on the host changes:
#   /etc/unraid-version      an overlay on /etc adds it
#   /boot, /mnt, /var/local, /usr/local
#                            bind mounts of a throwaway folder
#   Compose Manager Plus     the real plugin files (mstrhakr/compose_plugin,
#                            pinned commit) in /usr/local/emhttp/plugins,
#                            with Unraid's real Wrappers.php (unraid/webgui,
#                            pinned commit), so the installer talks to the
#                            plugin's own compose_args.php and compose.sh
# Shims (tests/shims) stand in for docker (records up/down/stop/pull; runs
# compose config and the seeding container for real), modprobe and logger.
# Needs: root, unshare, php-cli, docker with the compose plugin, git, curl,
# internet access (fixtures, the seeding container's pip and the Jackett
# search plugin). What this cannot test is listed in platforms/unraid/README.md.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
INSTALLER="$REPO/platforms/unraid/install.sh"

# Fixtures, pinned. Compose Manager Plus "Release v2026.10.27" (plg version
# 2026.10.27) and Unraid's webgui master at the time of writing.
CM_PLUS_URL="https://github.com/mstrhakr/compose_plugin"
CM_PLUS_COMMIT="5e9227530b204ca668f1f0b9b22e940a99c6975f"
WEBGUI_COMMIT="b135287c706a30da44f71cc7820615209e83e9a0"
WRAPPERS_URL="https://raw.githubusercontent.com/unraid/webgui/${WEBGUI_COMMIT}/emhttp/plugins/dynamix/include/Wrappers.php"
CACHE="${TS_TEST_CACHE:-${TMPDIR:-/tmp}/torrent-stack-unraid-tests}"

STACK_DIR="/mnt/user/appdata/torrent-stack"
CM_ROOT="/boot/config/plugins/compose.manager/projects"
CM_STACK="$CM_ROOT/torrent-stack"

# ---------------------------------------------------------------------------
# Outside the namespace: fetch fixtures, then re-run inside it.
# ---------------------------------------------------------------------------
if [[ "${1:-}" != --inside ]]; then
  [[ "$(id -u)" == 0 ]] || {
    echo "run as root" >&2
    exit 1
  }
  for tool in unshare php docker git curl script; do
    command -v "$tool" >/dev/null || {
      echo "missing tool: $tool" >&2
      exit 1
    }
  done
  mkdir -p "$CACHE"
  if [[ "$(git -C "$CACHE/compose_plugin" rev-parse HEAD 2>/dev/null || true)" != "$CM_PLUS_COMMIT" ]]; then
    rm -rf "$CACHE/compose_plugin"
    git init -q "$CACHE/compose_plugin"
    git -C "$CACHE/compose_plugin" fetch -q --depth 1 "$CM_PLUS_URL" "$CM_PLUS_COMMIT"
    git -C "$CACHE/compose_plugin" checkout -q FETCH_HEAD
  fi
  if [[ ! -s "$CACHE/Wrappers-${WEBGUI_COMMIT}.php" ]]; then
    curl -fsSL "$WRAPPERS_URL" -o "$CACHE/Wrappers-${WEBGUI_COMMIT}.php"
  fi
  FAKE=$(mktemp -d "$CACHE/root.XXXXXX")
  rc=0
  unshare -m --propagation private bash "$0" --inside "$FAKE" || rc=$?
  rm -rf "$FAKE"
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# Inside the namespace
# ---------------------------------------------------------------------------
FAKE="$2"
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
hasnt() { ! grep -qF -- "$2" "$1"; }
has_line() { grep -qxF -- "$2" "$1"; }
file_is() { [[ -f "$1" && "$(cat "$1")" == "$2" ]]; }
mode_is() { [[ "$(stat -c %a "$1")" == "$2" ]]; }
owner_is() { [[ "$(stat -c %u:%g "$1")" == "$2" ]]; }

mkdir -p "$FAKE"/{mnt,boot,varlocal,varlog,usrlocal,etc-up,etc-work,devnet,secrets,logs}
mount --bind "$FAKE/mnt" /mnt
mount --bind "$FAKE/boot" /boot
mount --bind "$FAKE/varlocal" /var/local
mount --bind "$FAKE/usrlocal" /usr/local
# Compose Manager's autostart hook logs to /var/log/compose.manager.log.
mount --bind "$FAKE/varlog" /var/log
mount -t overlay overlay -o "lowerdir=/etc,upperdir=$FAKE/etc-up,workdir=$FAKE/etc-work" /etc
# Unraid's PHP allows short open tags (its Wrappers.php starts with "<?");
# stock distribution PHP does not.
php_scan_dir=$(php --ini | sed -n 's/^Scan for additional .ini files in: //p')
if [[ -n "$php_scan_dir" && "$php_scan_dir" != "(none)" ]]; then
  printf 'short_open_tag = On\n' >"$php_scan_dir/99-unraid-test.ini"
fi
# /dev/net becomes a throwaway folder; the host's tun device (if any) is kept
# aside so tests can make /dev/net/tun appear and disappear. mknod is not
# allowed in unprivileged containers, so "creating" it is a bind mount.
REAL_TUN=""
if [[ -c /dev/net/tun ]]; then
  touch "$FAKE/real-tun"
  mount --bind /dev/net/tun "$FAKE/real-tun"
  REAL_TUN="$FAKE/real-tun"
fi
mount --bind "$FAKE/devnet" /dev/net
export SHIM_TUN_SOURCE="$REAL_TUN"
tun_present() {
  [[ -c /dev/net/tun ]] && return 0
  [[ -n "$REAL_TUN" ]] || return 0
  touch /dev/net/tun
  mount --bind "$REAL_TUN" /dev/net/tun
}
tun_absent() {
  umount /dev/net/tun 2>/dev/null || true
  rm -f /dev/net/tun
}

# Keep the logs on any exit when asked (KEEP=1), also when a test aborts.
trap 'if [[ "${KEEP:-0}" == 1 ]]; then rm -rf "$CACHE/last-logs"; cp -a "$FAKE/logs" "$CACHE/last-logs"; fi' EXIT
export SHIM_LOG="$FAKE/logs/calls.log"
export SHIM_SYSLOG="$FAKE/logs/syslog"
export SHIM_FAKE_ROOT="$FAKE"
export COMPOSE_LOCK_DIR="$FAKE/logs/locks"
export PATH="$HERE/shims:$PATH"
chmod +x "$HERE/shims/"*
# /usr/local is replaced by the fake Unraid tree above, so a compose plugin
# installed under /usr/local/lib/docker/cli-plugins is gone in here.
if ! "${SHIM_REAL_DOCKER:-/usr/bin/docker}" compose version >/dev/null 2>&1; then
  echo "docker compose does not work inside the test's mount namespace. Install the compose plugin outside /usr/local (for example /usr/lib/docker/cli-plugins/docker-compose)." >&2
  exit 1
fi

unraid_base() {
  printf 'version="7.2.1"\n' >/etc/unraid-version
  mkdir -p /var/local/emhttp /boot/config/plugins/compose.manager /mnt/user/appdata /mnt/user/downloads
  printf 'mdState="STARTED"\ntimeZone="Europe/Berlin"\n' >/var/local/emhttp/var.ini
  printf 'timeZone="Europe/Berlin"\n' >/boot/config/ident.cfg
  tun_present
}
install_plus() {
  mkdir -p /usr/local/emhttp/plugins/dynamix/include
  rm -rf /usr/local/emhttp/plugins/compose.manager
  cp -RT "$CACHE/compose_plugin/source/compose.manager" /usr/local/emhttp/plugins/compose.manager
  chmod -R +x /usr/local/emhttp/plugins/compose.manager/scripts /usr/local/emhttp/plugins/compose.manager/event
  cp "$CACHE/Wrappers-${WEBGUI_COMMIT}.php" /usr/local/emhttp/plugins/dynamix/include/Wrappers.php
  cp "$CACHE/compose_plugin/compose.manager.plg" /boot/config/plugins/compose.manager.plg
  printf 'PROJECTS_FOLDER="%s"\n' "$CM_ROOT" >/boot/config/plugins/compose.manager/compose.manager.cfg
  mkdir -p "$CM_ROOT"
}
reset_all() {
  rm -rf /mnt/user/appdata/* /mnt/user/downloads /mnt/cache "$CM_ROOT" "$COMPOSE_LOCK_DIR"
  rm -f /boot/config/plugins/compose.manager.plg
  : >"$SHIM_LOG"
  unset SHIM_PS_CONFIG_FILES SHIM_QBIT_RUNNING SHIM_DOCKER_DOWN SHIM_SEED_FAIL SHIM_TUN_FAILS SHIM_NO_COMPOSE
  unraid_base
  install_plus
}

# Secrets for unattended runs, in 0600 files.
WG_KEY="$(head -c 32 /dev/urandom | base64)"
QBIT_PW='Pa ss$w0rd"x\y#z'   # space, $, ", \ and # must survive the .env round trip
OVPN_PW="it's-a-pass"         # a single quote (and no $)
printf '%s\n' "$WG_KEY" >"$FAKE/secrets/wg"
printf '%s\n' "$QBIT_PW" >"$FAKE/secrets/qbit"
printf '%s\n' "$OVPN_PW" >"$FAKE/secrets/ovpn"
chmod 600 "$FAKE/secrets/"*

# run_installer LOGNAME [VAR=value...] -- [installer args...]
run_installer() {
  local name=$1
  shift
  local envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  [[ "${1:-}" == -- ]] && shift
  local rc=0
  env TS_SOURCE_DIR="$REPO" ${envs[@]+"${envs[@]}"} bash "$INSTALLER" "$@" \
    </dev/null >"$FAKE/logs/$name.out" 2>&1 || rc=$?
  echo "$rc" >"$FAKE/logs/$name.rc"
  return 0
}
rc_is() { [[ "$(cat "$FAKE/logs/$1.rc")" == "$2" ]]; }
# Compose Manager's array-start hook, run in the foreground (it normally
# detaches itself); it starts every stack whose autostart file says true.
run_autostart() {
  : >"$SHIM_LOG"
  COMPOSE_MANAGER_AUTOSTART_CHILD=1 bash /usr/local/emhttp/plugins/compose.manager/event/docker_started \
    >"$FAKE/logs/autostart.out" 2>&1 || true
}

out() { echo "$FAKE/logs/$1.out"; }

# compose_summary NAME: what docker compose makes of the installed stack, one
# fact per line, in logs/NAME.compose: Gluetun's published ports
# (server:inside/protocol) and FileBrowser's environment, extra groups and
# folders. Compose prints a literal $ as $$; it is turned back into $ here.
# A failure leaves the file empty, so the checks on it fail (not the suite).
compose_summary() {
  : >"$FAKE/logs/$1.compose"
  docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" config --format json |
    python3 -c '
import json, sys
s = json.load(sys.stdin)["services"]
for p in s["gluetun"]["ports"]:
    print("port %s:%s/%s" % (p["published"], p["target"], p["protocol"]))
fb = s["filebrowser"]
for k, v in sorted(fb["environment"].items()):
    print("fb-env %s=%s" % (k, v.replace("$$", "$")))
for g in fb.get("group_add", []):
    print("fb-group_add %s" % g)
for v in fb["volumes"]:
    print("fb-volume %s:%s" % (v["source"], v["target"]))
' >"$FAKE/logs/$1.compose" || true
}
summary() { echo "$FAKE/logs/$1.compose"; }

echo "Unraid installer tests (fake root: $FAKE)"

# ---------------------------------------------------------------------------
echo "* prerequisites"
reset_all
rm -f /boot/config/plugins/compose.manager.plg
run_installer no-plugin -- --unattended
check "no Compose Manager: exits 1" rc_is no-plugin 1
check "no Compose Manager: explains Apps > Compose Manager Plus" has "$(out no-plugin)" 'Search for "Compose Manager Plus"'
check "no Compose Manager: wrote nothing" test ! -e "$STACK_DIR"
# Stock Unraid: no plugin and therefore no `docker compose` either. The
# Apps-tab steps must still come first.
reset_all
rm -f /boot/config/plugins/compose.manager.plg
run_installer no-plugin-no-compose SHIM_NO_COMPOSE=1 -- --unattended
check "no Compose Manager and no docker compose (stock Unraid): Apps-tab steps" \
  bash -c "[[ \$(cat '$FAKE/logs/no-plugin-no-compose.rc') == 1 ]] && grep -qF 'Search for \"Compose Manager Plus\"' '$(out no-plugin-no-compose)' && ! grep -q 'reinstall the plugin' '$(out no-plugin-no-compose)'"
reset_all
run_installer plugin-no-compose SHIM_NO_COMPOSE=1 -- --unattended
check "plugin present but docker compose missing: reinstall hint" has "$(out plugin-no-compose)" "'docker compose' is missing"

reset_all
sed -i 's/<!ENTITY author "mstrhakr">/<!ENTITY author "dcflachs">/' /boot/config/plugins/compose.manager.plg
run_installer old-plugin -- --unattended
check "original Compose Manager: exits 1 with migration steps" \
  bash -c "[[ \$(cat '$FAKE/logs/old-plugin.rc') == 1 ]] && grep -q 'torrent_stack' '$(out old-plugin)'"

reset_all
sed -i 's/<!ENTITY version     "[^"]*">/<!ENTITY version     "2026.05.14">/' /boot/config/plugins/compose.manager.plg
run_installer old-plus -- --unattended
check "Compose Manager Plus older than 2026.09.03: exits 1" has "$(out old-plus)" "too old (need 2026.09.03"

reset_all
printf 'version="6.11.5"\n' >/etc/unraid-version
run_installer old-unraid -- --unattended
check "Unraid 6.11: refused" has "$(out old-unraid)" "too old"

reset_all
rm /etc/unraid-version
run_installer not-unraid -- --unattended
check "not Unraid: refused" has "$(out not-unraid)" "not an Unraid server"

reset_all
printf 'mdState="STOPPED"\n' >/var/local/emhttp/var.ini
run_installer array-stopped -- --unattended
check "array stopped: refused" has "$(out array-stopped)" "array is not started"

reset_all
run_installer docker-down SHIM_DOCKER_DOWN=1 -- --unattended
check "Docker disabled: refused with Settings > Docker hint" has "$(out docker-down)" "Settings > Docker"

reset_all
run_installer no-tty --
check "no terminal and no --unattended: refused" has "$(out no-tty)" "No terminal to ask questions on"

reset_all
tun_absent
run_installer tun-missing SHIM_TUN_FAILS=1 -- --unattended
check "/dev/net/tun missing and modprobe fails: refused" has "$(out tun-missing)" "/dev/net/tun is still missing"
reset_all
tun_absent
run_installer tun-load TS_APPDATA=/mnt/user/appdata -- --unattended --dry-run
check "/dev/net/tun missing, dry run: shows modprobe tun" has "$(out tun-load)" "would run: modprobe tun"

# ---------------------------------------------------------------------------
echo "* dry run"
reset_all
run_installer dry TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended --dry-run
check "dry run: exit 0" rc_is dry 0
check "dry run: no stack folder" test ! -e "$STACK_DIR"
check "dry run: no Compose Manager entry" test ! -e "$CM_STACK"
check "dry run: no downloads folder" test ! -e /mnt/user/downloads/incomplete
check "dry run: shows the .env it would write" has "$(out dry)" "CONFIG_PATH=/mnt/user/appdata/torrent-stack/appdata"
check "dry run: hides the WireGuard key" hasnt "$(out dry)" "$WG_KEY"
check "dry run: hides the qBittorrent password" hasnt "$(out dry)" "w0rd"
check "dry run: shows the compose.sh call" has "$(out dry)" "compose.sh -c up -p torrent-stack"
check "dry run: no compose up recorded" hasnt "$SHIM_LOG" " up "
check "dry run: no seeding container started" hasnt "$SHIM_LOG" "docker run"
check "dry run: shows the downloads made group-writable with setgid" has "$(out dry)" "would run: chmod g+s /mnt/user/downloads /mnt/user/downloads/incomplete"
check "dry run: shows FileBrowser's folder made group-writable" has "$(out dry)" "would run: chmod -R g+rwX /mnt/user/appdata/torrent-stack/appdata/filebrowser"
check "dry run: shows the search plugin seeded for 127.0.0.1:9117" has "$(out dry)" "--jackett-port 9117"
check "dry run: summary names FileBrowser's login" has "$(out dry)" "admin (with the qBittorrent password)"

# ---------------------------------------------------------------------------
echo "* install without VPN keys (startup gating)"
reset_all
tun_absent
run_installer gated TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "gated install: exit 0" rc_is gated 0
if [[ -n "$REAL_TUN" ]]; then
  check "gated install: loaded tun when /dev/net/tun was missing" bash -c "grep -q '^modprobe tun' '$SHIM_LOG' && test -c /dev/net/tun"
fi
check "gated install: repository copied" test -f "$STACK_DIR/compose.yaml" -a -f "$STACK_DIR/platforms/unraid/install.sh"
check "gated install: no .git, no dev .env copied" test ! -e "$STACK_DIR/.git"
check "gated install: .env is mode 600" mode_is "$STACK_DIR/.env" 600
check "gated install: CONFIG_PATH is <stack>/appdata, outside the git-tracked configs/" has "$STACK_DIR/.env" "CONFIG_PATH=/mnt/user/appdata/torrent-stack/appdata"
check "gated install: absolute DOWNLOADS_PATH" has "$STACK_DIR/.env" "DOWNLOADS_PATH=/mnt/user/downloads"
check "gated install: INCOMPLETE_DOWNLOADS" has "$STACK_DIR/.env" "INCOMPLETE_DOWNLOADS=/mnt/user/downloads/incomplete"
check "gated install: PUID 99 / PGID 100" bash -c "grep -qx 'PUID=99' '$STACK_DIR/.env' && grep -qx 'PGID=100' '$STACK_DIR/.env'"
check "gated install: Unraid time zone" has "$STACK_DIR/.env" "TZ=Europe/Berlin"
check "gated install: Watchtower off" bash -c "grep -qx 'COMPOSE_PROFILES=' '$STACK_DIR/.env'"
check "gated install: no Discord webhook (not the .env.example placeholder)" bash -c "grep -qx 'SCRIPT_NOTIFY_URL=' '$STACK_DIR/.env'"
check "gated install: VPN key left as the placeholder" has "$STACK_DIR/.env" "WIREGUARD_PRIVATE_KEY=your_wireguard_private_key"
check "gated install: docker compose config -q passes" \
  docker compose -p torrent-stack -f "$STACK_DIR/compose.yaml" --env-file "$STACK_DIR/.env" config -q
check "gated install: Compose Manager entry name" file_is "$CM_STACK/name" "torrent-stack"
check "gated install: Compose Manager project_name" file_is "$CM_STACK/project_name" "torrent-stack"
check "gated install: Compose Manager indirect path" file_is "$CM_STACK/indirect" "$STACK_DIR"
check "gated install: autostart off" file_is "$CM_STACK/autostart" "false"
check "gated install: stack not started" hasnt "$SHIM_LOG" " up -d"
check "gated install: seeding container ran" has "$SHIM_LOG" "docker run --rm --name torrent-stack-seed"
APPCFG="$STACK_DIR/appdata"
check "gated install: qBittorrent PBKDF2 seeded" has "$APPCFG/qbittorrent/qBittorrent/qBittorrent.conf" 'WebUI\Password_PBKDF2="@ByteArray('
check "gated install: tracked qBittorrent seed kept (save path)" has "$APPCFG/qbittorrent/qBittorrent/qBittorrent.conf" 'Session\DefaultSavePath=/downloads'
check "gated install: Jackett search plugin installed" test -s "$APPCFG/qbittorrent/qBittorrent/nova3/engines/jackett.py"
check "gated install: Jackett API key" has "$APPCFG/jackett/Jackett/ServerConfig.json" '"APIKey"'
check "gated install: nothing seeded into the repository's configs/ folder" \
  bash -c "! grep -rqs 'Password_PBKDF2\|APIKey' '$STACK_DIR/configs' '$REPO/configs'"
check "gated install: no FileBrowser seed (compose.yaml sets its admin password)" test ! -e "$APPCFG/filebrowser/settings.yaml"
check "gated install: search plugin seeded with --jackett-port 9117" has "$SHIM_LOG" "--jackett-port 9117"
check "gated install: search plugin points at Jackett inside Gluetun's network (127.0.0.1:9117)" \
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["url"] == "http://127.0.0.1:9117" else 1)' \
  "$APPCFG/qbittorrent/qBittorrent/nova3/engines/jackett.json"
# FileBrowser runs as uid 1000 with PGID (100) as an extra group: its config
# folder and the downloads must be writable for group 100, with setgid.
check "gated install: FileBrowser's config folder is 99:100" owner_is "$APPCFG/filebrowser" "99:100"
check "gated install: FileBrowser's config folder is 2775 (group write, setgid)" mode_is "$APPCFG/filebrowser" 2775
check "gated install: downloads folder is 99:100, 2775" bash -c "[[ \$(stat -c %u:%g:%a /mnt/user/downloads) == 99:100:2775 ]]"
check "gated install: incomplete folder is 99:100, 2775" bash -c "[[ \$(stat -c %u:%g:%a /mnt/user/downloads/incomplete) == 99:100:2775 ]]"
check "gated install: qBittorrent's config folder is not opened up to the group (755)" mode_is "$APPCFG/qbittorrent" 755
compose_summary gated
check "compose: qBittorrent published on 8090 (same port inside)" has_line "$(summary gated)" "port 8090:8090/tcp"
check "compose: Jackett published 9117 -> 9117" has_line "$(summary gated)" "port 9117:9117/tcp"
check "compose: FlareSolverr published 8191 -> 8191" has_line "$(summary gated)" "port 8191:8191/tcp"
check "compose: FileBrowser database in its config folder" has_line "$(summary gated)" "fb-env FILEBROWSER_DATABASE_PATH=/config/database.sqlite"
check "compose: FileBrowser admin password is the qBittorrent password, exactly" has_line "$(summary gated)" "fb-env FILEBROWSER_ADMIN_PASSWORD=${QBIT_PW}"
check "compose: FileBrowser gets PGID 100 as an extra group" has_line "$(summary gated)" "fb-group_add 100"
check "compose: FileBrowser's /config is appdata/filebrowser" has_line "$(summary gated)" "fb-volume $APPCFG/filebrowser:/config"
check "compose: FileBrowser serves the downloads folder" has_line "$(summary gated)" "fb-volume /mnt/user/downloads:/srv/downloads"
check "gated install: seeding installs nothing from PyPI" hasnt "$SHIM_LOG" "pip install"
check "gated install: seeding image pinned by digest" has "$SHIM_LOG" "python:3.14.9-slim-trixie@sha256:"
check "gated install: seeding mounts the stack folder read-only" has "$SHIM_LOG" "-v $STACK_DIR:$STACK_DIR:ro"
check "gated install: seeding drops root (--as-user 99:100)" has "$SHIM_LOG" "--as-user 99:100"
check "gated install: seeded files belong to 99:100" bash -c "[[ -z \$(find '$APPCFG/qbittorrent' '$APPCFG/jackett' ! -user 99 -print -quit) ]]"
check "gated install: qBittorrent config owned by 99:100" owner_is "$APPCFG/qbittorrent/qBittorrent/qBittorrent.conf" "99:100"
check "gated install: downloads owned by 99:100" owner_is /mnt/user/downloads/incomplete "99:100"
check "gated install: update-qbittorrent.sh executable" test -x "$STACK_DIR/update-qbittorrent.sh"
check "gated install: secrets not in the call log" hasnt "$SHIM_LOG" "w0rd"
check "gated install: prints the --apply next step" has "$(out gated)" "install.sh --apply"
check "gated install: Compose page lists the stack (plugin's ComposeList.php)" \
  bash -c "php -r '\$_GET[\"mode\"]=\"list\"; include \"/usr/local/emhttp/plugins/compose.manager/include/ComposeList.php\";' 2>&1 | grep -qF '\"projects\":[\"torrent-stack\"]'"
run_autostart
check "gated install: array-start autostart does not start it" hasnt "$SHIM_LOG" " up -d"

# The values written to .env read back exactly, through the same parser the
# env-editor and the seeding CLI use.
check "gated install: qBittorrent password round-trips (env_io.parse_env_literal)" \
  python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import env_io, pathlib
v = env_io.parse_env_literal(pathlib.Path(sys.argv[2]))["QBITTORRENT_PASSWORD"]
sys.exit(0 if v == sys.argv[3] else 1)' "$REPO/scripts/env-editor" "$STACK_DIR/.env" "$QBIT_PW"
# ... and through docker compose itself (no $-interpolation, no lost quotes).
check "gated install: qBittorrent password round-trips (docker compose)" bash -c "
  got=\$(docker compose -p torrent-stack -f '$STACK_DIR/compose.yaml' --env-file '$STACK_DIR/.env' config --format json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)[\"services\"][\"gluetun\"][\"environment\"][\"QBITTORRENT_PASSWORD\"], end=\"\")')
  [[ \"\$got\" == \"\$1\" ]]" _ "${QBIT_PW//\$/\$\$}"   # compose prints a literal $ as $$

# ---------------------------------------------------------------------------
echo "* --apply after filling in the VPN keys (as the ENV tab would)"
: >"$SHIM_LOG"
sed -i "s|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=${WG_KEY}|; s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=10.2.0.2/32|" "$STACK_DIR/.env"
# The database FileBrowser makes (as uid 1000, umask 022) in its config folder.
for f in database.sqlite database.sqlite-wal; do
  printf 'fb-db\n' >"$APPCFG/filebrowser/$f"
  chown 1000:1000 "$APPCFG/filebrowser/$f"
  chmod 644 "$APPCFG/filebrowser/$f"
done
run_installer apply SHIM_QBIT_RUNNING=1 -- --apply
check "apply: exit 0" rc_is apply 0
check "apply: FileBrowser's database keeps its owner (uid 1000)" bash -c "[[ \$(stat -c %u '$APPCFG/filebrowser/database.sqlite') == 1000 ]]"
check "apply: FileBrowser's database and WAL file are group 100, group-writable (664)" \
  bash -c "[[ \$(stat -c %g:%a '$APPCFG/filebrowser/database.sqlite') == 100:664 && \$(stat -c %g:%a '$APPCFG/filebrowser/database.sqlite-wal') == 100:664 ]]"
check "apply: FileBrowser's database content untouched" bash -c "[[ \$(cat '$APPCFG/filebrowser/database.sqlite') == fb-db ]]"
check "apply: FileBrowser's config folder still 99:100, 2775" bash -c "[[ \$(stat -c %u:%g:%a '$APPCFG/filebrowser') == 99:100:2775 ]]"
check "apply: prints FileBrowser's login (admin + the qBittorrent password)" has "$(out apply)" "admin / the same password as qBittorrent"
check "apply: no longer sends people to FileBrowser's log for a password" hasnt "$(out apply)" "initial admin password"
check "apply: prints Jackett on JACKETT_PORT" grep -qE 'Jackett: +http://[^ ]+:9117' "$(out apply)"
check "apply: autostart on" file_is "$CM_STACK/autostart" "true"
check "apply: stops qBittorrent before seeding" has "$SHIM_LOG" "stop qbittorrent"
check "apply: started through Compose Manager's compose.sh" \
  has "$SHIM_LOG" "docker compose --env-file $STACK_DIR/.env -f $STACK_DIR/compose.yaml -p torrent-stack up -d"
check "apply: compose.sh recorded success" has "$CM_STACK/last_result.json" '"result":"success"'
check "apply: compose.sh recorded started_at" test -s "$CM_STACK/started_at"
check "apply: webui_url" file_is "$CM_STACK/webui_url" "http://[IP]:8090/"

# What the plugin itself resolves for this stack (UI and autostart use this).
php /usr/local/emhttp/plugins/compose.manager/scripts/compose_args.php --compose-root "$CM_ROOT" \
  --project torrent-stack --action up --format tsv "--stack-path=$CM_STACK" >"$FAKE/logs/args.tsv" 2>&1 || true
check "plugin: project name torrent-stack" grep -qxP 'projectName\ttorrent-stack' "$FAKE/logs/args.tsv"
check "plugin: compose file is the repo's compose.yaml" grep -qxP "composeFile\t$STACK_DIR/compose.yaml" "$FAKE/logs/args.tsv"
check "plugin: env file is the stack's .env" grep -qxP "envFilePath\t$STACK_DIR/.env" "$FAKE/logs/args.tsv"
check "plugin: no profile forced (Watchtower stays off)" bash -c "! grep -q '^profile' '$FAKE/logs/args.tsv'"
php -r 'require "/usr/local/emhttp/plugins/compose.manager/include/Defines.php";
  require "/usr/local/emhttp/plugins/compose.manager/include/Util.php";
  $s = StackInfo::fromProject($argv[1], "torrent-stack");
  echo json_encode(["name" => $s->getDisplayName(), "autostart" => $s->getAutostart(),
    "webui" => $s->getWebUIUrl(), "source" => $s->composeSource]), "\n";' "$CM_ROOT" >"$FAKE/logs/stackinfo.json" 2>&1 || true
check "plugin: StackInfo reads name, autostart, web UI and source" \
  python3 -c 'import json,sys; d=json.loads(open(sys.argv[1]).read().strip().splitlines()[-1]); sys.exit(0 if d=={"name":"torrent-stack","autostart":True,"webui":"http://[IP]:8090/","source":sys.argv[2]} else 1)' \
  "$FAKE/logs/stackinfo.json" "$STACK_DIR"
run_autostart
check "plugin: array-start autostart starts it as torrent-stack" \
  has "$SHIM_LOG" "docker compose --env-file $STACK_DIR/.env -f $STACK_DIR/compose.yaml -p torrent-stack up -d"

# Compose Manager's call (explicit -p and --env-file) and the env-editor's
# (docker compose -f compose.yaml from the stack folder) must produce the same
# per-service config hashes, or each would recreate the other's containers.
cm_hash=$(docker compose --env-file "$STACK_DIR/.env" -f "$STACK_DIR/compose.yaml" -p torrent-stack config --hash '*')
ed_hash=$(cd "$STACK_DIR" && docker compose -f "$STACK_DIR/compose.yaml" config --hash '*')
ed_name=$(cd "$STACK_DIR" && docker compose -f "$STACK_DIR/compose.yaml" config --format json | python3 -c 'import json,sys; print(json.load(sys.stdin)["name"])')
check "parity: same project name for the env-editor (torrent-stack)" test "$ed_name" == torrent-stack
check "parity: same service config hashes as the env-editor's docker compose" test "$cm_hash" == "$ed_hash"
printf '%s\n' "$cm_hash" >"$FAKE/logs/hashes.txt"

# ---------------------------------------------------------------------------
echo "* re-run install (idempotent)"
cp "$STACK_DIR/.env" "$FAKE/env.before"
stat -c %Y "$CM_STACK/name" >"$FAKE/name.mtime"
ls "$CM_ROOT" >"$FAKE/stacks.before"
sleep 1
: >"$SHIM_LOG"
run_installer rerun -- --unattended
check "re-run: exit 0" rc_is rerun 0
check "re-run: .env unchanged" cmp -s "$FAKE/env.before" "$STACK_DIR/.env"
check "re-run: no .env.bak when unchanged" test ! -e "$STACK_DIR/.env.bak"
check "re-run: one Compose Manager stack, same folder" bash -c "[[ \"\$(ls '$CM_ROOT')\" == \"\$(cat '$FAKE/stacks.before')\" ]]"
check "re-run: metadata files not rewritten" test "$(stat -c %Y "$CM_STACK/name")" == "$(cat "$FAKE/name.mtime")"
check "re-run: stack brought up again (VPN keys are set)" has "$SHIM_LOG" "-p torrent-stack up -d"
check "re-run: keeps the existing qBittorrent password" bash -c "grep -F 'QBITTORRENT_PASSWORD=' '$STACK_DIR/.env' | grep -qF 'w0rd'"
: >"$SHIM_LOG"
run_installer rerun-running SHIM_QBIT_RUNNING=1 TS_APPDATA=/mnt/user/appdata/torrent-stack -- --unattended
check "re-run while running: exit 0 (appdata given as the stack folder)" rc_is rerun-running 0
check "re-run while running: no nested torrent-stack/torrent-stack" test ! -e "$STACK_DIR/torrent-stack"
check "re-run while running: stops qBittorrent before seeding" bash -c "
  stop=\$(grep -n 'stop qbittorrent' '$SHIM_LOG' | head -1 | cut -d: -f1)
  seed=\$(grep -n 'docker run --rm --name torrent-stack-seed' '$SHIM_LOG' | head -1 | cut -d: -f1)
  [[ -n \$stop && -n \$seed && \$stop -lt \$seed ]]"

# ---------------------------------------------------------------------------
echo "* interactive wizard (pseudo-terminal)"
reset_all
# Answers: appdata, downloads, time zone, provider, protocol, WireGuard key,
# address, countries, qBittorrent user, password (empty = generate), go ahead.
answers=("/mnt/user/appdata/torrent-stack/" "/mnt/user/downloads/torrents" "" "" "" "$WG_KEY" "10.2.0.9/32" "Switzerland,Netherlands" "" "" "y")
# One answer at a time, as a person types after each prompt (all at once
# would be echoed by the terminal before a hidden prompt turns echo off).
feed() {
  local a
  sleep 2
  for a in "${answers[@]}"; do
    printf '%s\n' "$a"
    sleep 0.7
  done
}
rc=0
feed | TS_SOURCE_DIR="$REPO" script -qefc "bash '$INSTALLER'" /dev/null >"$FAKE/logs/wizard.out" 2>&1 || rc=$?
echo "$rc" >"$FAKE/logs/wizard.rc"
check "wizard: exit 0" rc_is wizard 0
check "wizard: appdata answer naming the stack folder is not nested" bash -c "test -f '$STACK_DIR/compose.yaml' && test ! -e '$STACK_DIR/torrent-stack'"
check "wizard: downloads answer used" has "$STACK_DIR/.env" "DOWNLOADS_PATH=/mnt/user/downloads/torrents"
check "wizard: countries with a comma stored" has "$STACK_DIR/.env" "SERVER_COUNTRIES=Switzerland,Netherlands"
check "wizard: WireGuard key stored" has "$STACK_DIR/.env" "WIREGUARD_PRIVATE_KEY=${WG_KEY}"
check "wizard: WireGuard key not echoed" hasnt "$FAKE/logs/wizard.out" "$WG_KEY"
check "wizard: password generated and shown once" grep -q "Generated password" "$FAKE/logs/wizard.out"
check "wizard: started with autostart on" file_is "$CM_STACK/autostart" "true"
check "wizard: subfolder share path created" test -d /mnt/user/downloads/torrents/incomplete

# ---------------------------------------------------------------------------
echo "* OpenVPN, unattended"
reset_all
run_installer ovpn TS_VPN_TYPE=openvpn TS_OPENVPN_USER='user+pmp' TS_OPENVPN_PASSWORD_FILE="$FAKE/secrets/ovpn" \
  TS_SERVER_COUNTRIES="United States" TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "openvpn: exit 0" rc_is ovpn 0
check "openvpn: user stored" has "$STACK_DIR/.env" "OPENVPN_USER=user+pmp"
check "openvpn: password with a single quote round-trips" \
  python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import env_io, pathlib
v = env_io.parse_env_literal(pathlib.Path(sys.argv[2]))["OPENVPN_PASSWORD"]
sys.exit(0 if v == sys.argv[3] else 1)' "$REPO/scripts/env-editor" "$STACK_DIR/.env" "$OVPN_PW"
check "openvpn: country with a space quoted" has "$STACK_DIR/.env" "SERVER_COUNTRIES='United States'"
check "openvpn: started" has "$SHIM_LOG" "-p torrent-stack up -d"

# ---------------------------------------------------------------------------
echo "* ports: Jackett and FlareSolverr on any free server port"
reset_all
run_installer ports TS_JACKETT_PORT=19117 TS_FLARESOLVERR_PORT=18191 TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" \
  TS_WIREGUARD_ADDRESSES=10.2.0.2/32 TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "ports 19117/18191: exit 0 (no longer refused)" rc_is ports 0
check "ports 19117/18191: stored in .env" bash -c "grep -qx 'JACKETT_PORT=19117' '$STACK_DIR/.env' && grep -qx 'FLARESOLVERR_PORT=18191' '$STACK_DIR/.env'"
compose_summary ports
check "ports 19117/18191: compose publishes 19117 -> Jackett's 9117" has_line "$(summary ports)" "port 19117:9117/tcp"
check "ports 19117/18191: compose publishes 18191 -> FlareSolverr's 8191" has_line "$(summary ports)" "port 18191:8191/tcp"
check "ports 19117/18191: search plugin still points at 127.0.0.1:9117" \
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["url"] == "http://127.0.0.1:9117" else 1)' \
  "$STACK_DIR/appdata/qbittorrent/qBittorrent/nova3/engines/jackett.json"
check "ports 19117/18191: Jackett's own port stays 9117" \
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["Port"] == 9117 else 1)' "$STACK_DIR/appdata/jackett/Jackett/ServerConfig.json"
check "ports 19117/18191: prints Jackett on the server port" grep -qE 'Jackett: +http://[^ ]+:19117' "$(out ports)"
sed -i 's/^JACKETT_PORT=.*/JACKETT_PORT=29117/' "$STACK_DIR/.env"
run_installer ports-apply -- --apply
check "--apply after JACKETT_PORT changed in the ENV tab: exit 0" rc_is ports-apply 0
compose_summary ports-apply
check "--apply: compose publishes 29117 -> 9117" has_line "$(summary ports-apply)" "port 29117:9117/tcp"
check "--apply: search plugin still points at 127.0.0.1:9117" \
  python3 -c 'import json,sys; sys.exit(0 if json.load(open(sys.argv[1]))["url"] == "http://127.0.0.1:9117" else 1)' \
  "$STACK_DIR/appdata/qbittorrent/qBittorrent/nova3/engines/jackett.json"
sed -i 's/^FLARESOLVERR_PORT=.*/FLARESOLVERR_PORT=8090/' "$STACK_DIR/.env"
run_installer ports-apply-dup -- --apply
check "--apply with FLARESOLVERR_PORT = QBIT_WEBUI_PORT: refused" \
  bash -c "[[ \$(cat '$FAKE/logs/ports-apply-dup.rc') == 1 ]] && grep -qF 'QBIT_WEBUI_PORT and FLARESOLVERR_PORT are both 8090' '$(out ports-apply-dup)'"
reset_all
run_installer port-dup TS_FILEBROWSER_PORT=8090 TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "FILEBROWSER_PORT = QBIT_WEBUI_PORT: refused" has "$(out port-dup)" "QBIT_WEBUI_PORT and FILEBROWSER_PORT are both 8090"
check "duplicate ports: nothing written" test ! -e "$STACK_DIR/.env"
run_installer port-inner TS_QBIT_WEBUI_PORT=9117 TS_JACKETT_PORT=19117 TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "QBIT_WEBUI_PORT 9117 (Jackett's port inside Gluetun's network): refused" has "$(out port-inner)" "QBIT_WEBUI_PORT cannot be 9117"

echo "* the qBittorrent password is also FileBrowser's (bcrypt: at most 72 bytes)"
reset_all
printf '%s\n' "$(printf 'a%.0s' {1..73})" >"$FAKE/secrets/long"
run_installer pw-long TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/long" -- --unattended
check "73-byte password: refused" has "$(out pw-long)" "is 73 bytes long; at most 72 work"
check "73-byte password: nothing written" test ! -e "$STACK_DIR/.env"
check "73-byte password: not printed" hasnt "$(out pw-long)" "aaaaaaaaaa"
# 37 characters, but 74 bytes (é is 2 bytes in UTF-8): bytes are what count.
printf '%s\n' "$(printf '\xc3\xa9%.0s' {1..37})" >"$FAKE/secrets/long-utf8"
run_installer pw-long-utf8 TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/long-utf8" -- --unattended
check "37 characters / 74 bytes: refused" has "$(out pw-long-utf8)" "is 74 bytes long"
printf '%s\n' "$(printf 'b%.0s' {1..72})" >"$FAKE/secrets/max"
run_installer pw-max TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/max" -- --unattended
check "72-byte password: accepted" rc_is pw-max 0
sed -i "s|^QBITTORRENT_PASSWORD=.*|QBITTORRENT_PASSWORD=$(printf 'c%.0s' {1..80})|; s|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=${WG_KEY}|; s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=10.2.0.2/32|" "$STACK_DIR/.env"
: >"$SHIM_LOG"
run_installer pw-apply -- --apply
check "--apply with an 80-byte password from the ENV tab: refused before anything starts" \
  bash -c "[[ \$(cat '$FAKE/logs/pw-apply.rc') == 1 ]] && grep -qF 'is 80 bytes long' '$(out pw-apply)' && ! grep -q ' up -d' '$SHIM_LOG'"

# ---------------------------------------------------------------------------
echo "* conflicts"
reset_all
mkdir -p "$CM_ROOT/torrent-stack"
printf 'services:\n' >"$CM_ROOT/torrent-stack/compose.yaml"
run_installer conflict-local -- --unattended
check "existing local stack named torrent-stack: refused" has "$(out conflict-local)" "has its own compose file"
check "existing local stack: left alone" file_is "$CM_ROOT/torrent-stack/compose.yaml" "services:"
reset_all
mkdir -p "$CM_ROOT/my-torrents"
printf '%s' "$STACK_DIR" >"$CM_ROOT/my-torrents/indirect"
run_installer conflict-indirect -- --unattended
check "another stack already points at the folder: refused" has "$(out conflict-indirect)" "already uses $STACK_DIR"
reset_all
run_installer conflict-running SHIM_PS_CONFIG_FILES=/opt/stacks/torrent-stack/compose.yaml -- --unattended
check "torrent-stack running from another folder: refused" has "$(out conflict-running)" "from another folder exist"
reset_all
run_installer override-ok SHIM_PS_CONFIG_FILES="$STACK_DIR/compose.yaml,$CM_STACK/compose.override.yaml" \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "our stack with a Compose Manager override: not a conflict" rc_is override-ok 0
reset_all
run_installer bad-share TS_DOWNLOADS=/mnt/user/nosuchshare/dl -- --unattended
check "missing share: refused with Shares tab hint" has "$(out bad-share)" "Create it on the Shares tab"
run_installer bad-path TS_DOWNLOADS=/tmp/dl -- --unattended
check "path outside /mnt: refused" has "$(out bad-path)" "must be a share, or a folder in one"
run_installer seed-fails SHIM_SEED_FAIL=1 -- --unattended
check "seeding failure: stops with a clear message" has "$(out seed-fails)" "Seeding failed"
check "seeding failure: not registered" test ! -e "$CM_STACK/autostart"

# ---------------------------------------------------------------------------
echo "* folder checks: whole pools and overlaps with the stack folder"
reset_all
mkdir -p /mnt/cache/appdata
for c in "inside:$STACK_DIR/downloads" "same:$STACK_DIR" "holds:/mnt/user/appdata" "alias:/mnt/cache/appdata/torrent-stack/dl"; do
  n=${c%%:*}
  run_installer "dl-$n" TS_DOWNLOADS="${c#*:}" TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
  check "downloads $n the stack folder (${c#*:}): refused" \
    bash -c "[[ \$(cat '$FAKE/logs/dl-$n.rc') == 1 ]] && grep -q 'overlap' '$(out "dl-$n")'"
done
check "overlapping downloads: nothing written" test ! -e "$STACK_DIR/.env"
run_installer appdata-root TS_APPDATA=/mnt/user -- --unattended --dry-run
check "appdata /mnt/user (the whole array): refused" has "$(out appdata-root)" "must be a share, or a folder in one"
check "appdata /mnt/user: no new share planned" hasnt "$(out appdata-root)" "mkdir -p /mnt/user/torrent-stack"
run_installer dl-pool TS_DOWNLOADS=/mnt/cache -- --unattended --dry-run
check "downloads /mnt/cache (a whole pool): refused" has "$(out dl-pool)" "must be a share, or a folder in one"
run_installer dl-colon TS_DOWNLOADS=/mnt/user/downloads/a:b -- --unattended --dry-run
check "downloads path with ':' (breaks compose volumes): refused" has "$(out dl-colon)" "contains one of"

echo "* downloads moved into the stack folder later (ENV tab)"
reset_all
run_installer mv-setup TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
sed -i "s|^DOWNLOADS_PATH=.*|DOWNLOADS_PATH=$STACK_DIR/downloads|; s|^INCOMPLETE_DOWNLOADS=.*|INCOMPLETE_DOWNLOADS=$STACK_DIR/downloads/incomplete|" "$STACK_DIR/.env"
mkdir -p "$STACK_DIR/downloads"
touch "$STACK_DIR/downloads/finished-movie.mkv"
run_installer mv-apply -- --apply
check "--apply with downloads inside the stack folder: refused" \
  bash -c "[[ \$(cat '$FAKE/logs/mv-apply.rc') == 1 ]] && grep -q 'overlap' '$(out mv-apply)'"
: >"$SHIM_LOG"
run_installer mv-purge -- --uninstall --purge --unattended
check "--purge with downloads inside the stack folder: refused (exit 1)" rc_is mv-purge 1
check "--purge refused: the download is still there" test -f "$STACK_DIR/downloads/finished-movie.mkv"
check "--purge refused: nothing was stopped" hasnt "$SHIM_LOG" "-p torrent-stack down"
check "--purge refused: Compose Manager entry kept" file_is "$CM_STACK/indirect" "$STACK_DIR"
check "--purge refused: does not claim the downloads were untouched" hasnt "$(out mv-purge)" "were not touched"
sed -i "s|^DOWNLOADS_PATH=.*|DOWNLOADS_PATH=./downloads|" "$STACK_DIR/.env"
run_installer mv-purge-rel -- --uninstall --purge --unattended
check "--purge with DOWNLOADS_PATH=./downloads (relative): refused" rc_is mv-purge-rel 1
check "--purge refused (relative): the download is still there" test -f "$STACK_DIR/downloads/finished-movie.mkv"

echo "* Compose Manager's Projects Folder overlaps the stack folder"
reset_all
printf 'PROJECTS_FOLDER="/mnt/user/appdata"\n' >/boot/config/plugins/compose.manager/compose.manager.cfg
run_installer cm-same TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "Projects Folder = the appdata share: refused" \
  bash -c "[[ \$(cat '$FAKE/logs/cm-same.rc') == 1 ]] && grep -q 'Projects Folder' '$(out cm-same)'"
check "Projects Folder = the appdata share: nothing written" test ! -e "$STACK_DIR"
reset_all
mkdir -p /mnt/cache/appdata
printf 'PROJECTS_FOLDER="/mnt/cache/appdata"\n' >/boot/config/plugins/compose.manager/compose.manager.cfg
run_installer cm-alias TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "Projects Folder = /mnt/cache/appdata, stack in /mnt/user/appdata (same files): refused" \
  bash -c "[[ \$(cat '$FAKE/logs/cm-alias.rc') == 1 ]] && grep -q 'Projects Folder' '$(out cm-alias)'"
# An entry that is the stack folder (made before this check existed, or by
# hand): --uninstall must remove only the metadata files, never the folder.
reset_all
run_installer cm-old-setup TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
for f in name project_name indirect indirect_mode description webui_url autostart; do cp "$CM_STACK/$f" "$STACK_DIR/$f"; done
printf 'PROJECTS_FOLDER="/mnt/user/appdata"\n' >/boot/config/plugins/compose.manager/compose.manager.cfg
run_installer cm-old-uninstall -- --uninstall --unattended
check "entry = stack folder: --uninstall exits 0" rc_is cm-old-uninstall 0
check "entry = stack folder: .env kept" test -f "$STACK_DIR/.env"
check "entry = stack folder: app settings kept" test -f "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf"
check "entry = stack folder: repository files kept" test -f "$STACK_DIR/compose.yaml"
check "entry = stack folder: only the metadata files removed" \
  bash -c "test ! -e '$STACK_DIR/indirect' && test ! -e '$STACK_DIR/project_name' && test ! -e '$STACK_DIR/autostart'"
check "entry = stack folder: says why the folder stays" has "$(out cm-old-uninstall)" "that folder is the stack folder"

echo "* qBittorrent is started again when nothing else starts it"
reset_all
run_installer rs-setup TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
stop_then_start() {
  local stop start
  stop=$(grep -n -- '--env-file .* stop qbittorrent' "$SHIM_LOG" | head -1 | cut -d: -f1)
  start=$(grep -n -- '--env-file .* start qbittorrent' "$SHIM_LOG" | head -1 | cut -d: -f1)
  [[ -n "$stop" && -n "$start" && "$stop" -lt "$start" ]]
}
: >"$SHIM_LOG"
run_installer rs-seedfail SHIM_QBIT_RUNNING=1 SHIM_SEED_FAIL=1 -- --apply
check "--apply, seeding fails while qBittorrent runs: exit 1" rc_is rs-seedfail 1
check "--apply, seeding fails: qBittorrent stopped, then started again" stop_then_start
check "--apply, seeding fails: stack not recreated" hasnt "$SHIM_LOG" " up -d"
: >"$SHIM_LOG"
sed -i 's|^WIREGUARD_PRIVATE_KEY=.*|WIREGUARD_PRIVATE_KEY=your_wireguard_private_key|' "$STACK_DIR/.env"
run_installer rs-gated SHIM_QBIT_RUNNING=1 -- --unattended
check "re-run with placeholder keys while running: exit 0" rc_is rs-gated 0
check "re-run with placeholder keys: qBittorrent stopped, then started again" stop_then_start
check "re-run with placeholder keys: not brought up (gated)" hasnt "$SHIM_LOG" " up -d"
check "re-run with placeholder keys: autostart off" file_is "$CM_STACK/autostart" "false"

echo "* inline comments in .env (docker compose allows them)"
reset_all
run_installer ic-setup TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
sed -i "s|^QBIT_WEBUI_PORT=.*|QBIT_WEBUI_PORT=8090 # web UI|; s|^WIREGUARD_ADDRESSES=.*|WIREGUARD_ADDRESSES=10.2.0.2/32 # from the .conf|; s|^TZ=.*|TZ='Europe/Berlin' # zone|" "$STACK_DIR/.env"
check "inline comments: docker compose reads QBIT_WEBUI_PORT as 8090" bash -c "
  docker compose -p torrent-stack -f '$STACK_DIR/compose.yaml' --env-file '$STACK_DIR/.env' config --format json |
    python3 -c 'import json,sys; e=json.load(sys.stdin)[\"services\"][\"gluetun\"][\"environment\"]; sys.exit(0 if (e[\"QBIT_WEBUI_PORT\"], e[\"TZ\"]) == (\"8090\", \"Europe/Berlin\") else 1)'"
rm -f "$CM_STACK/webui_url"
run_installer ic-apply -- --apply
check "inline comments: --apply exit 0" rc_is ic-apply 0
check "inline comments: --apply reads the port as 8090" file_is "$CM_STACK/webui_url" "http://[IP]:8090/"
run_installer ic-rerun -- --unattended
check "inline comments: re-run exit 0" rc_is ic-rerun 0
check "inline comments: re-run keeps QBIT_WEBUI_PORT 8090" grep -qx 'QBIT_WEBUI_PORT=8090' "$STACK_DIR/.env"
check "inline comments: re-run keeps the time zone" grep -qx 'TZ=Europe/Berlin' "$STACK_DIR/.env"
check "inline comments: re-run keeps the WireGuard address" grep -qx 'WIREGUARD_ADDRESSES=10.2.0.2/32' "$STACK_DIR/.env"

echo "* git clone install: --update after the repository changed a seed file"
reset_all
UP="$FAKE/upstream.git"
rm -rf "$UP"
mkdir -p "$UP"
tar -C "$REPO" --anchored --exclude=./.git --exclude=./.env -cf - . | tar -C "$UP" -xf -
git -C "$UP" init -q -b main
git -C "$UP" add -A
git -C "$UP" -c user.name=test -c user.email=test@example.invalid commit -qm "test upstream"
G=(TS_SOURCE_DIR= TS_REPO_URL="file://$FAKE/upstream")
run_installer git-install "${G[@]}" TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
check "git install: exit 0" rc_is git-install 0
check "git install: the stack folder is a git checkout" test -d "$STACK_DIR/.git"
check "git install: seeded into appdata/" has "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf" 'WebUI\Password_PBKDF2'
check "git install: git status is clean (app settings are not in git's way)" \
  bash -c "[[ -z \$(git -C '$STACK_DIR' status --porcelain) ]]"
cp "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf" "$FAKE/live-qbit.before"
cp "$STACK_DIR/appdata/jackett/Jackett/ServerConfig.json" "$FAKE/live-jackett.before"
printf '\n[Test]\nUpstreamChange=1\n' >>"$UP/configs/qbittorrent/qBittorrent/qBittorrent.conf"
sed -i 's/"FlareSolverrUrl"/"FlareSolverrUrl" /' "$UP/configs/jackett/Jackett/ServerConfig.json"
git -C "$UP" -c user.name=test -c user.email=test@example.invalid commit -qam "change both seeds"
: >"$SHIM_LOG"
run_installer git-update TS_SOURCE_DIR= -- --update
check "git --update after both seeds changed upstream: exit 0" rc_is git-update 0
check "git --update: the checkout has the new seed" has "$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf" "UpstreamChange=1"
check "git --update: live qBittorrent settings kept" cmp -s "$FAKE/live-qbit.before" "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf"
check "git --update: live Jackett settings kept" cmp -s "$FAKE/live-jackett.before" "$STACK_DIR/appdata/jackett/Jackett/ServerConfig.json"
check "git --update: images pulled through compose.sh" has "$SHIM_LOG" "-p torrent-stack pull"
printf 'UpstreamChange=2\n' >>"$UP/configs/qbittorrent/qBittorrent/qBittorrent.conf"
git -C "$UP" -c user.name=test -c user.email=test@example.invalid commit -qam "change the seed again"
run_installer git-update-ref TS_SOURCE_DIR= TS_REF=main -- --update
check "git --update with TS_REF=main: exit 0" rc_is git-update-ref 0
check "git --update with TS_REF=main: the checkout has the newest seed" has "$STACK_DIR/configs/qbittorrent/qBittorrent/qBittorrent.conf" "UpstreamChange=2"
# A file changed by hand still blocks the pull, with a message that says so.
printf '# my edit\n' >>"$STACK_DIR/compose.yaml"
printf '# upstream edit\n' >>"$UP/compose.yaml"
git -C "$UP" -c user.name=test -c user.email=test@example.invalid commit -qam "change compose.yaml"
run_installer git-update-blocked TS_SOURCE_DIR= -- --update
check "git --update with compose.yaml edited by hand: refused with steps" \
  bash -c "[[ \$(cat '$FAKE/logs/git-update-blocked.rc') == 1 ]] && grep -q 'checkout -- FILE' '$(out git-update-blocked)'"

# ---------------------------------------------------------------------------
echo "* --update"
reset_all
run_installer upd-install TS_WIREGUARD_PRIVATE_KEY_FILE="$FAKE/secrets/wg" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$FAKE/secrets/qbit" -- --unattended
echo "stale" >"$STACK_DIR/compose.yaml.orig-test"
sed -i 's/^PUID=99$/PUID=99/' "$STACK_DIR/.env"
cp "$STACK_DIR/.env" "$FAKE/env.before"
cp "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf" "$FAKE/qbit.before"
# The folders as an install from before this compose.yaml left them: owned
# 99:100 but writable for the owner only. The new FileBrowser container
# (uid 1000, group 100) could not create its database there.
chmod 755 "$STACK_DIR/appdata/filebrowser" /mnt/user/downloads /mnt/user/downloads/incomplete
: >"$SHIM_LOG"
run_installer update -- --update
check "update: exit 0" rc_is update 0
check "update: FileBrowser's config folder made 99:100, 2775 for the new compose.yaml" \
  bash -c "[[ \$(stat -c %u:%g:%a '$STACK_DIR/appdata/filebrowser') == 99:100:2775 ]]"
check "update: downloads folders made 2775" \
  bash -c "[[ \$(stat -c %a /mnt/user/downloads) == 2775 && \$(stat -c %a /mnt/user/downloads/incomplete) == 2775 ]]"
check "update: folders fixed before the containers are recreated" bash -c "
  ready=\$(grep -n 'Folders ready' '$(out update)' | head -1 | cut -d: -f1)
  pull=\$(grep -n 'Pulling new images' '$(out update)' | head -1 | cut -d: -f1)
  [[ -n \$ready && -n \$pull && \$ready -lt \$pull ]]"
check "update: .env kept" cmp -s "$FAKE/env.before" "$STACK_DIR/.env"
check "update: qBittorrent config kept" cmp -s "$FAKE/qbit.before" "$STACK_DIR/appdata/qbittorrent/qBittorrent/qBittorrent.conf"
check "update: images pulled through compose.sh" has "$SHIM_LOG" "-p torrent-stack pull"
check "update: containers recreated through compose.sh" has "$SHIM_LOG" "-p torrent-stack up -d"
check "update: compose.sh recorded the update" has "$CM_STACK/last_result.json" '"operation":"update"'
chmod 777 /mnt/user/downloads
# As the old installer left it, if --update ran with that old installer.
chmod 755 "$STACK_DIR/appdata/filebrowser"
run_installer apply-777 -- --apply
check "--apply: a downloads folder open to everyone (777) keeps that, only setgid is added (2777)" \
  bash -c "[[ \$(cat '$FAKE/logs/apply-777.rc') == 0 && \$(stat -c %a /mnt/user/downloads) == 2777 ]]"
check "--apply: an old install's 755 FileBrowser folder becomes 2775" mode_is "$STACK_DIR/appdata/filebrowser" 2775

# ---------------------------------------------------------------------------
echo "* --uninstall"
: >"$SHIM_LOG"
touch /mnt/user/downloads/keep-me.mkv
run_installer uninstall-noconfirm -- --uninstall
check "uninstall without a terminal or --unattended: refused" has "$(out uninstall-noconfirm)" "No terminal to confirm on"
run_installer uninstall -- --uninstall --unattended
check "uninstall: exit 0" rc_is uninstall 0
check "uninstall: compose down through compose.sh" has "$SHIM_LOG" "-p torrent-stack down"
check "uninstall: Compose Manager entry removed" test ! -e "$CM_STACK"
check "uninstall: stack folder kept" test -f "$STACK_DIR/.env"
check "uninstall: downloads kept" test -f /mnt/user/downloads/keep-me.mkv
run_installer purge -- --uninstall --purge --unattended
check "purge: stack folder deleted" test ! -e "$STACK_DIR"
check "purge: downloads kept" test -f /mnt/user/downloads/keep-me.mkv

# ---------------------------------------------------------------------------
echo "* downloads from GitHub (dry run, no TS_SOURCE_DIR)"
reset_all
rc=0
env -u TS_SOURCE_DIR TS_REF=main bash "$INSTALLER" --unattended --dry-run </dev/null >"$FAKE/logs/git-dry.out" 2>&1 || rc=$?
check "git clone path: dry run renders .env from the clone" bash -c "[[ $rc == 0 ]] && grep -q 'Got the repository (main)' '$FAKE/logs/git-dry.out' && grep -q 'CONFIG_PATH=/mnt/user/appdata' '$FAKE/logs/git-dry.out'"
# No git: a PATH without it, to take the curl + tarball path.
mkdir -p "$FAKE/nogit"
for f in /usr/bin/* /bin/*; do
  b=${f##*/}
  [[ "$b" == git || -e "$FAKE/nogit/$b" ]] || ln -s "$f" "$FAKE/nogit/$b"
done
rc=0
env -u TS_SOURCE_DIR TS_REF=main PATH="$HERE/shims:$FAKE/nogit" bash "$INSTALLER" --unattended --dry-run </dev/null >"$FAKE/logs/tar-dry.out" 2>&1 || rc=$?
check "tarball path (no git): dry run downloads and renders .env" bash -c "[[ $rc == 0 ]] && grep -q 'archive/main.tar.gz (git is not installed)' '$FAKE/logs/tar-dry.out' && grep -q 'CONFIG_PATH=/mnt/user/appdata' '$FAKE/logs/tar-dry.out'"

# ---------------------------------------------------------------------------
echo
echo "passed: $PASS  failed: $FAIL"
if [[ "$FAIL" -gt 0 ]]; then
  printf '  - %s\n' "${FAILED[@]}"
  echo "logs: $FAKE/logs (deleted on exit; set KEEP=1 to keep a copy in $CACHE/last-logs)"
fi
[[ "$FAIL" == 0 ]]
