#!/usr/bin/env bash
#
# platforms/casaos/tests/run-tests.sh
#
# Purpose: test platforms/casaos/install.sh without a CasaOS or ZimaOS host.
# CasaOS's app-management API is replaced by tests/lib/fake_casaos.py (built
# from CasaOS-AppManagement's source and checked against a real CasaOS
# 0.4.15), the docker CLI by tests/shims/docker, and `casaos -v` /
# `zimaos -v` by tiny shims, and what the apps do (qBittorrent's settings
# migration and login, which port answers, network namespaces) by
# tests/lib/fake_apps.py behind the curl and docker shims. The rendered app is
# checked three ways:
# `docker compose config -q`, tests/lib/casaos_schema.py (CasaOS / AppStore
# rules), and tests/lib/compare_compose.py (still the same stack as
# compose.yaml). With CASAOS_APPSTORE_DIR=<checkout of IceWhaleTech/
# CasaOS-AppStore> it also runs the AppStore's own validator.
#
# Needs: bash, python3 (3.8 or later) with PyYAML, docker compose (for
# `config` only, no daemon calls; tested with 5.6.1), and script(1) for the
# wizard tests. The seeding CLI needs only the standard library, and the
# tests put a stub search plugin in place first, so it downloads nothing.
# CASAOS_TEST_PYTHON=/path/to/python3 picks the python3 that install.sh
# finds "on the box" (default: the python3 on PATH). Optional: busybox (or
# CASAOS_TEST_BUSYBOX=/path/to/busybox) to run two updates with busybox's
# tar, cp, mkdir and rm, as on a host whose tools are busybox's; and
# setpriv (util-linux) for the checks run as another user. Run as root
# (install.sh requires it, except for --print-yaml), from anywhere:
#   bash platforms/casaos/tests/run-tests.sh
#
# License: MIT (see LICENSE in the repository root).

set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
INSTALL="$REPO/platforms/casaos/install.sh"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/casaos-tests.XXXXXX")
# Traversable like a real /DATA: the seeding CLI writes as PUID, not root.
chmod 711 "$WORK"
OUT="$WORK/out"
STATE="$WORK/state"
mkdir -p "$OUT" "$STATE"

PASS=0
FAIL=0
SKIP=0
FAILED=()
SERVER_PID=""

cleanup() {
  [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null || true
  if [[ "${CASAOS_TEST_KEEP:-0}" == 1 || $FAIL -gt 0 ]]; then
    echo "Work folder kept: $WORK"
  else
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); FAILED+=("$1"); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '        %s\n' "$2"; return 0; }
skip() { SKIP=$((SKIP + 1)); printf '  SKIP  %s (%s)\n' "$1" "$2"; }
check() { # NAME CMD...
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$name"; else bad "$name" "command: $*"; fi
}
check_not() { # NAME CMD...  (passes when CMD fails)
  local name=$1
  shift
  if "$@" >/dev/null 2>&1; then bad "$name" "unexpectedly succeeded: $*"; else ok "$name"; fi
}
has() { grep -q -F -- "$2" "$1"; }      # FILE TEXT
lacks() { ! grep -q -F -- "$2" "$1"; }  # FILE TEXT
section() { printf '\n== %s\n' "$1"; }

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------
WG_KEY="oK7tzJ0kZ9Y0bq3PLyLbbm1yN6dZ8tVH2KsQ6hHv6Ws="
QB_PASS="Shim-Test-Pass-1"
QB_PASS2="Shim-Test-Pass-2"
OVPN_PASS="Ovpn-Test-Pass-9"
(
  umask 077
  printf '%s\n' "$WG_KEY" >"$WORK/wg.key"
  printf '%s\n' "$QB_PASS" >"$WORK/qb.pass"
  # Passwords FileBrowser cannot use as its admin password.
  printf '%s\n' admin >"$WORK/qb-admin.pass"
  printf '%s\n' abcd >"$WORK/qb-short.pass"
  # 2 letters but 4 bytes: FileBrowser counts bytes.
  printf '%s\n' 'éé' >"$WORK/qb-accents.pass"
  printf '%s\n' "$(printf 'x%.0s' $(seq 1 73))" >"$WORK/qb-long.pass"
)

# A copy of the working tree as TS_SOURCE_DIR (no .git, .env or runtime
# state), so the tests do not depend on what is committed.
SRC="$WORK/src"
mkdir -p "$SRC"
tar -C "$REPO" --exclude=./.git --exclude=./.env --exclude=./configs/env-editor \
  --exclude=./scripts/env-editor/.venv --exclude='*/__pycache__' -cf - . | tar -C "$SRC" -xf -

# The python3 the seeding CLI runs on, on "the box" and in the seeding
# container stand-in. `--only jackett,qbit` needs only the standard library
# (FileBrowser is not seeded), so any python3 3.8+ will do.
PY_HOST="${CASAOS_TEST_PYTHON:-$(command -v python3)}"
[[ -x "$PY_HOST" ]] || {
  echo "No python3 found (set CASAOS_TEST_PYTHON=/path/to/python3)." >&2
  exit 1
}
# A PATH entry with that python3: install.sh then seeds on the host. (A
# wrapper, not a symlink: a venv's python must be run by its own path to
# find its packages.)
mkdir -p "$WORK/hostpy"
printf '#!/bin/sh\nexec %q "$@"\n' "$PY_HOST" >"$WORK/hostpy/python3"
chmod +x "$WORK/hostpy/python3"

# The fake app-management.
APPS_DIR="$WORK/var/lib/casaos/apps"
python3 -I "$HERE/lib/fake_casaos.py" --state "$STATE" --port-file "$WORK/port" --apps-dir "$APPS_DIR" \
  >"$OUT/fake.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$WORK/port" ]] && break; sleep 0.1; done
[[ -s "$WORK/port" ]] || { echo "fake CasaOS did not start" >&2; exit 1; }
API="http://127.0.0.1:$(cat "$WORK/port")"

set_config() { printf '%s\n' "$1" >"$STATE/config.json"; }
set_config '{}'

APPDATA="$WORK/DATA/AppData"
DOWNLOADS="$WORK/DATA/Downloads"
STACK="$APPDATA/torrent-stack"
mkdir -p "$APPDATA" "$DOWNLOADS"
# By default the box's python3 fails install.sh's probe (as if it were too
# old, or missing as on ZimaOS), so seeding runs in the pinned container;
# runs with $WORK/hostpy first in PATH seed on the host. Everything else
# (the python shims here) still gets the real python3.
mkdir -p "$WORK/nopy"
# shellcheck disable=SC2016  # written into the stand-in
printf '#!/bin/sh\ncase "$*" in *sys.version_info*) exit 1 ;; esac\nexec /usr/bin/python3 "$@"\n' >"$WORK/nopy/python3"
chmod +x "$WORK/nopy/python3"
SHIM_PATH="$HERE/shims:$HERE/shims/casaos-bin:$WORK/nopy:$PATH"
# A fake /proc for the network-namespace check (filled by the docker shim).
PROC="$WORK/proc"
mkdir -p "$PROC"
# The kernel here may have no IPv6 at all; install.sh then leaves out
# gluetun's IPv6 sysctl (auto). The drift check is told the same.
IPV6_FLAG=()
[[ -e /proc/sys/net/ipv6/conf/all/disable_ipv6 ]] || IPV6_FLAG=(--no-ipv6-sysctl)

# run_inst NAME [VAR=value ...] -- ARGS...: run install.sh; sets RC and LOG.
RC=0
LOG=""
run_inst() {
  local name=$1
  shift
  local envs=()
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  LOG="$OUT/$name.log"
  set +e
  env PATH="$SHIM_PATH" CASAOS_SHIM_STATE="$STATE" CASAOS_SHIM_PYTHON="$PY_HOST" \
    CASAOS_SHIM_PROC="$PROC" TS_PROC_DIR="$PROC" TS_UI_WAIT=3 \
    TS_CASAOS_API="$API" TS_CASAOS_APPS_DIR="$APPS_DIR" TS_APPDATA="$APPDATA" \
    TS_DOWNLOADS="$DOWNLOADS" TS_SOURCE_DIR="$SRC" TS_WAIT=20 TS_POLL_INTERVAL=0 TS_UI=plain \
    "${envs[@]}" bash "${RUN_SCRIPT:-$INSTALL}" "$@" </dev/null >"$LOG" 2>&1
  RC=$?
  set -e
  return 0
}

# run_tty NAME INPUT_FILE [VAR=value ...] -- ARGS...: like run_inst, on a
# pseudo-terminal (script(1)) with INPUT_FILE typed in, for the wizard.
run_tty() {
  local name=$1 input=$2
  shift 2
  local envs=() cmd
  while [[ $# -gt 0 && "$1" != -- ]]; do envs+=("$1"); shift; done
  shift
  LOG="$OUT/$name.log"
  cmd=$(printf '%q ' env PATH="$SHIM_PATH" CASAOS_SHIM_STATE="$STATE" CASAOS_SHIM_PYTHON="$PY_HOST" \
    CASAOS_SHIM_PROC="$PROC" TS_PROC_DIR="$PROC" TS_UI_WAIT=3 \
    TS_CASAOS_API="$API" TS_CASAOS_APPS_DIR="$APPS_DIR" TS_APPDATA="$APPDATA" \
    TS_DOWNLOADS="$DOWNLOADS" TS_SOURCE_DIR="$SRC" TS_WAIT=20 TS_POLL_INTERVAL=0 \
    "${envs[@]}" bash "$INSTALL" "$@")
  set +e
  script -q -e -c "$cmd" /dev/null <"$input" >"$LOG" 2>&1
  RC=$?
  set -e
  return 0
}

# Requests the fake saw since mark_requests, as "METHOD path?query" lines.
mark_requests() { MARK=$(wc -l <"$STATE/requests.jsonl" 2>/dev/null || echo 0); }
requests_since() {
  tail -n +"$((MARK + 1))" "$STATE/requests.jsonl" 2>/dev/null |
    python3 -I -c 'import json,sys
for l in sys.stdin:
    r = json.loads(l)
    q = "&".join(f"{k}={v}" for k, v in sorted(r["query"].items()))
    print(r["method"], r["path"] + ("?" + q if q else ""))'
}
MARK=0
container_ids() { python3 -I -c 'import json,sys; print(" ".join(f"{c["service"]}={c["id"]}" for c in json.load(open(sys.argv[1]))))' "$STATE/containers.json" 2>/dev/null || true; }
id_of() { python3 -I -c 'import json,sys; print(next((c["id"] for c in json.load(open(sys.argv[1])) if c["service"]==sys.argv[2]), ""))' "$STATE/containers.json" "$1" 2>/dev/null || true; }
no_secrets_in() { # FILE: none of the test secrets appear in it
  local f=$1
  [[ ! -e "$f" ]] && return 0
  ! grep -q -F -e "$WG_KEY" -e "$QB_PASS" -e "$QB_PASS2" -e "$OVPN_PASS" "$f"
}
mode_of() { stat -c '%a' "$1"; }
# Fields of the container of SERVICE in the docker shim's state.
field_of() { python3 -I -c 'import json,sys; print(next((str(c.get(sys.argv[3], "")) for c in json.load(open(sys.argv[1])) if c["service"]==sys.argv[2]), ""))' "$STATE/containers.json" "$1" "$2" 2>/dev/null || true; }
# set_field SERVICE KEY VALUE: change the docker shim's state, as if Docker did it.
set_field() { python3 -I -c 'import json,sys; p=sys.argv[1]; rows=json.load(open(p)); [c.update({sys.argv[3]: sys.argv[4]}) for c in rows if c["service"]==sys.argv[2]]; json.dump(rows, open(p,"w"))' "$STATE/containers.json" "$1" "$2" "$3"; }
# Does fake qBittorrent accept USER PASSWORD with the conf in CONF?
qbit_accepts() { python3 -I -c 'import sys; sys.dont_write_bytecode=True; sys.path.insert(0, sys.argv[1]); import fake_apps; from pathlib import Path; sys.exit(0 if fake_apps.qbit_login_ok(Path(sys.argv[2]), sys.argv[3], sys.argv[4]) else 1)' "$HERE/lib" "$1" "$2" "$3"; }
# The revision label each service has in a rendered app FILE, as "svc=rev ...".
revs_in() { python3 -I -c 'import sys,yaml; d=yaml.safe_load(open(sys.argv[1])); print(" ".join(f"{n}={s["labels"]["io.github.rob-paprocki.torrent-stack.rev"]}" for n,s in sorted(d["services"].items())))' "$1"; }
container_revs() { python3 -I -c 'import json,sys; print(" ".join(f"{c["service"]}={c.get("labels",{}).get("io.github.rob-paprocki.torrent-stack.rev","")}" for c in sorted(json.load(open(sys.argv[1])), key=lambda c: c["service"])))' "$STATE/containers.json"; }
# Are Gluetun, qBittorrent, Jackett and FlareSolverr in one namespace?
one_netns() { python3 -I -c 'import json,sys; rows=json.load(open(sys.argv[1])); sys.exit(len({c["netns"] for c in rows if c["service"] in ("gluetun","qbittorrent","jackett","flaresolverr")}) != 1)' "$STATE/containers.json"; }
owner_of() { stat -c '%u:%g' "$1"; }
owner_mode_of() { stat -c '%u:%g %a' "$1"; }
# fb_rendered FILE PASSWORD PGID CONFIG_DIR: FileBrowser's part of a rendered
# app is what compose.yaml asks for: its database in its config folder, the
# qBittorrent password for "admin", and PGID as an extra group.
fb_rendered() { python3 -I -c 'import sys,yaml
f, pw, pgid, cfg = sys.argv[1:5]
s = yaml.safe_load(open(f))["services"]["filebrowser"]
env = s["environment"]
assert env["FILEBROWSER_DATABASE_PATH"] == "/config/database.sqlite", env
assert env["FILEBROWSER_ADMIN_PASSWORD"] == pw, "admin password"
assert s["group_add"] == [pgid], s.get("group_add")
binds = {v["target"]: v["source"] for v in s["volumes"]}
assert binds["/config"] == cfg, binds' "$@"; }

# ---------------------------------------------------------------------------
section "Static checks"
check "bash -n install.sh" bash -n "$INSTALL"
SC=$(command -v shellcheck || true)
[[ -z "$SC" && -n "${SHELLCHECK:-}" ]] && SC=$SHELLCHECK
if [[ -n "$SC" ]]; then
  check "shellcheck -S warning (install.sh, tests, shims)" "$SC" -S warning "$INSTALL" "$HERE/run-tests.sh" \
    "$HERE/e2e-incus.sh" "$HERE/shims/curl" "$HERE/shims/whiptail" "$HERE/shims/casaos-bin/casaos" \
    "$HERE/shims/zimaos-bin/zimaos"
else
  skip "shellcheck" "not installed (set SHELLCHECK=/path)"
fi
# Parse only (py_compile would leave __pycache__ folders in the repository).
check "python helpers parse" python3 -I -c 'import ast, sys
for f in sys.argv[1:]:
    ast.parse(open(f).read(), f)' "$HERE/lib/casaos_schema.py" \
  "$HERE/lib/compare_compose.py" "$HERE/lib/fake_casaos.py" "$HERE/lib/fake_apps.py" "$HERE/shims/docker"
check "embedded icon is a valid SVG data URI" python3 -I -c '
import base64, re, sys, xml.dom.minidom
s = open(sys.argv[1]).read()
uri = re.search(r"ICON_DATA_URI=\"data:image/svg\+xml;base64,([A-Za-z0-9+/=]+)\"", s).group(1)
xml.dom.minidom.parseString(base64.b64decode(uri))' "$INSTALL"
check "the host python3 probe runs isolated (-I)" grep -q "python3 -I -c 'import sys; sys.exit" "$INSTALL"
check "seeding runs as PUID:PGID (--as-user), qBittorrent and Jackett only" grep -qF -- '--only "$SEEDERS" --as-user "${E[PUID]}:${E[PGID]}"' "$INSTALL"
check "no GNU-only tar options (busybox tar on ZimaOS)" bash -c "! grep -n -E 'tar .*(--no-anchored|--anchored|--no-same-owner)' '$INSTALL'"

section "Refusals before anything changes"
run_inst help -- --help
check "--help exits 0 and lists --print-yaml" test "$RC" == 0 -a -n "$(grep -- --print-yaml "$LOG")"
run_inst notcasa PATH="$HERE/shims:$PATH" -- -y
check "not CasaOS/ZimaOS: refused" test "$RC" != 0 -a -n "$(grep 'does not look like a CasaOS' "$LOG")"
run_inst oldcasa CASAOS_SHIM_VERSION=0.4.3 -- -y
check "CasaOS 0.4.3: refused as too old" test "$RC" != 0 -a -n "$(grep 'too old' "$LOG")"
run_inst notty --
check "no terminal and no --unattended: refused" test "$RC" != 0 -a -n "$(grep 'No terminal' "$LOG")"
set_config '{"require_auth": true}'
run_inst auth -- -y --dry-run
check "app-management wants a login: refused with advice" test "$RC" != 0 -a -n "$(grep 'asked for a login' "$LOG")"
set_config '{}'
run_inst baddl TS_DOWNLOADS="$WORK/DATA/torrent-stack-dl" -- -y --dry-run
check "downloads path containing the app name: refused" test "$RC" != 0 -a -n "$(grep "must not contain 'torrent-stack'" "$LOG")"
run_inst dl-parent TS_DOWNLOADS="$WORK/DATA" -- -y --dry-run
check "downloads folder that contains the stack folder (/DATA): refused" test "$RC" != 0 -a -n "$(grep "contains $APPDATA" "$LOG")"
run_inst dl-top TS_DOWNLOADS=/srv -- -y --dry-run
check "a top-level downloads folder: refused" test "$RC" != 0 -a -n "$(grep "is a top-level folder" "$LOG")"
run_inst dl-disk TS_DOWNLOADS=/media/usbdisk -- -y --dry-run
check "a whole disk (/media/<disk>) as downloads folder: refused" test "$RC" != 0 -a -n "$(grep "is a whole disk" "$LOG")"
run_inst qbport TS_QBIT_WEBUI_PORT=9117 TS_JACKETT_PORT=9118 TS_WIREGUARD_PRIVATE_KEY_FILE="$WORK/wg.key" \
  TS_WIREGUARD_ADDRESSES=10.2.0.2/32 TS_QBITTORRENT_PASSWORD_FILE="$WORK/qb.pass" -- -y --dry-run
check "QBIT_WEBUI_PORT on a port used inside Gluetun's network: refused" test "$RC" != 0 -a -n "$(grep "taken inside Gluetun's network" "$LOG")"
for pw in admin:"ignores the password 'admin'" short:"needs at least 5 bytes" accents:"needs at least 5 bytes" long:"takes at most 72 bytes"; do
  run_inst "fbpass-${pw%%:*}" TS_WIREGUARD_PRIVATE_KEY_FILE="$WORK/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
    TS_QBITTORRENT_PASSWORD_FILE="$WORK/qb-${pw%%:*}.pass" -- -y --dry-run
  check "a qBittorrent password FileBrowser cannot use (${pw%%:*}): refused" test "$RC" != 0 -a -n "$(grep -F "${pw#*:}" "$LOG")"
done

section "Dry run (fresh)"
mark_requests
run_inst dry TS_WIREGUARD_PRIVATE_KEY_FILE="$WORK/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$WORK/qb.pass" -- -y --dry-run
check "dry run exits 0" test "$RC" == 0
check "dry run creates no stack folder" test ! -e "$STACK"
requests_since >"$OUT/dry.requests"
check "dry run only reads, plus CasaOS's own dry_run validation" diff -u \
  <(printf '%s\n' "GET /v2/app_management/compose" "GET /v2/app_management/compose/torrent-stack" \
    "POST /v2/app_management/compose?dry_run=true") "$OUT/dry.requests"
check "dry run prints no secrets" no_secrets_in "$LOG"
check "dry run shows the masked YAML" has "$LOG" "WIREGUARD_PRIVATE_KEY: '********'"
check "dry run pulls nothing" lacks "$STATE/docker.log" '"pull"'

section "Fresh install (unattended, seeding in a container)"
# Keep the seeding offline: the Jackett search plugin is already there.
mkdir -p "$STACK/configs/qbittorrent/qBittorrent/nova3/engines"
echo "# test stub" >"$STACK/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
mark_requests
run_inst fresh TS_WIREGUARD_PRIVATE_KEY_FILE="$WORK/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$WORK/qb.pass" TS_TZ=Europe/Berlin -- -y
check "install exits 0" test "$RC" == 0
requests_since >"$OUT/fresh.requests"
check "API: probe, lookup, validate, install (POST)" diff -u \
  <(printf '%s\n' "GET /v2/app_management/compose" "GET /v2/app_management/compose/torrent-stack" \
    "POST /v2/app_management/compose?dry_run=true" "POST /v2/app_management/compose") "$OUT/fresh.requests"
check "API calls carry no Authorization header and send YAML" python3 -I -c '
import json, sys
rows = [json.loads(l) for l in open(sys.argv[1])]
posts = [r for r in rows if r["method"] in ("POST", "PUT")]
assert posts and all(r["content_type"] == "application/yaml" for r in posts)
assert not any(r["authorization"] for r in rows)' "$STATE/requests.jsonl"
check ".env is 0600" test "$(mode_of "$STACK/.env")" == 600
check ".env has the key, address, TZ and absolute paths" bash -c "grep -qx 'WIREGUARD_PRIVATE_KEY=$WG_KEY' '$STACK/.env' &&
  grep -qx 'WIREGUARD_ADDRESSES=10.2.0.2/32' '$STACK/.env' && grep -qx 'TZ=Europe/Berlin' '$STACK/.env' &&
  grep -qx 'CONFIG_PATH=$STACK/configs' '$STACK/.env' && grep -qx 'DOWNLOADS_PATH=$DOWNLOADS' '$STACK/.env' &&
  grep -qx 'PUID=1000' '$STACK/.env' && grep -qx 'COMPOSE_PROFILES=' '$STACK/.env' && grep -qx 'SCRIPT_NOTIFY_URL=' '$STACK/.env'"
check "casaos-app.yml kept next to .env, 0600" test "$(mode_of "$STACK/casaos-app.yml")" == 600
check "the app CasaOS stored is casaos-app.yml" cmp -s "$STACK/casaos-app.yml" "$STATE/apps/torrent-stack.yml"
check "rendered app passes docker compose config -q" docker compose -f "$STACK/casaos-app.yml" config -q
if python3 -I "$HERE/lib/casaos_schema.py" "$STACK/casaos-app.yml" >"$OUT/schema.txt" 2>&1; then
  ok "rendered app passes the CasaOS/AppStore schema checks"
else
  bad "rendered app passes the CasaOS/AppStore schema checks" "$(head -3 "$OUT/schema.txt")"
fi
if python3 -I "$HERE/lib/compare_compose.py" "$STACK/casaos-app.yml" "$SRC/compose.yaml" "$STACK/.env" "$STACK" \
  ${IPV6_FLAG[@]+"${IPV6_FLAG[@]}"} >"$OUT/drift.txt" 2>&1; then
  ok "rendered services match compose.yaml (docker compose config)"
else
  bad "rendered services match compose.yaml (docker compose config)" "$(head -3 "$OUT/drift.txt")"
fi
check "repository files copied, port script executable" test -x "$STACK/update-qbittorrent.sh" -a -f "$STACK/compose.yaml"
check "tracked seeds copied" test -f "$STACK/configs/jackett/Jackett/ServerConfig.json"
check "seeding ran in the pinned python container (tag and digest)" grep -qE "^container python:3\.14\.9-slim-trixie@sha256:[0-9a-f]{64} $STACK\$" "$STATE/seed-runs.log"
check "fake qBittorrent migrated its settings on first start ([WebUI], MigrationVersion=12)" bash -c "grep -qx 'MigrationVersion=12' '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf' && grep -qx '\[WebUI\]' '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf'"
check "the apps behind Gluetun restart with it (depends_on restart: true)" test "$(grep -c '^        restart: true$' "$STACK/casaos-app.yml")" == 3
check "Jackett and FlareSolverr keep their own ports inside (9117, 8191)" bash -c "grep -A1 -x '      - target: 9117' '$STACK/casaos-app.yml' | grep -q \"published: '9117'\" && grep -A1 -x '      - target: 8191' '$STACK/casaos-app.yml' | grep -q \"published: '8191'\""
check "FileBrowser: database in its config folder, qBittorrent password for admin, PGID as extra group" \
  fb_rendered "$STACK/casaos-app.yml" "$QB_PASS" 1000 "$STACK/configs/filebrowser"
check "every container carries its service's revision label" test "$(revs_in "$STACK/casaos-app.yml")" == "$(container_revs)"
check "after the wait: shared network checked, every web UI and the login checked" bash -c "grep -q \"share Gluetun's network\" '$LOG' && grep -q 'qBittorrent accepts the login in .env' '$LOG'"
check "qBittorrent seeded (PBKDF2 + search on)" bash -c "grep -q 'Password_PBKDF2=' '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf' &&
  grep -q 'Search\\\\SearchEnabled=true' '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf'"
check "Jackett API key and search plugin wiring" bash -c "grep -q '\"APIKey\"' '$STACK/configs/jackett/Jackett/ServerConfig.json' &&
  grep -q 'http://127.0.0.1:9117' '$STACK/configs/qbittorrent/qBittorrent/nova3/engines/jackett.json'"
check "no FileBrowser seed file (compose.yaml sets its password; nothing needs bcrypt)" test ! -e "$STACK/configs/filebrowser/settings.yaml"
check "seeded files belong to PUID:PGID" test "$(owner_of "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf")" == 1000:1000
check "configs owned by PUID:PGID" test "$(owner_of "$STACK/configs/qbittorrent")" == 1000:1000
check "incomplete folder created: PUID:PGID, 2775 (group-writable, setgid)" test "$(owner_mode_of "$DOWNLOADS/incomplete")" == "1000:1000 2775"
check "FileBrowser's config folder: PUID:PGID, 2775 (FileBrowser writes as uid 1000 + PGID)" test "$(owner_mode_of "$STACK/configs/filebrowser")" == "1000:1000 2775"
check "an existing downloads folder keeps its owner and mode (root, 755 here), with a warning naming FileBrowser" \
  bash -c "test \"\$(stat -c '%u %a' '$DOWNLOADS')\" == '0 755' && grep -q 'FileBrowser (uid 1000, group 1000) may not be able to write there' '$LOG'"
check "all five images pulled first" test "$(grep -c '"pull"' "$STATE/docker.log")" == 5
check "waited for the app and printed the URLs" bash -c "grep -q 'All containers are running' '$LOG' && grep -q 'qBittorrent:.*:8090' '$LOG'"
check "summary: FileBrowser login is admin with the qBittorrent password; no container log read" \
  bash -c "grep -q 'FileBrowser login: *user admin, the qBittorrent password' '$LOG' && ! grep -qi 'initial admin password' '$LOG' && ! grep -q '\"logs\"' '$STATE/docker.log'"
check "no secret on any docker command line" no_secrets_in "$STATE/docker.log"
check "no secret on any curl command line" no_secrets_in "$STATE/curl.log"
check "no secret in the installer output" no_secrets_in "$LOG"

if [[ -n "${CASAOS_APPSTORE_DIR:-}" && -f "$CASAOS_APPSTORE_DIR/.github/actions/validate-compose/scripts/validate_compose.py" ]]; then
  mkdir -p "$WORK/appstore/Apps/TorrentStack"
  cp "$STACK/casaos-app.yml" "$WORK/appstore/Apps/TorrentStack/docker-compose.yml"
  if (cd "$WORK/appstore" && python3 -I "$CASAOS_APPSTORE_DIR/.github/actions/validate-compose/scripts/validate_compose.py" \
    --report-json "$WORK/appstore/report.json") >"$OUT/appstore-validator.txt" 2>&1; then
    ok "IceWhaleTech CasaOS-AppStore validate_compose.py accepts the app"
  else
    bad "IceWhaleTech CasaOS-AppStore validate_compose.py accepts the app" "$(tail -3 "$OUT/appstore-validator.txt")"
  fi
else
  skip "CasaOS-AppStore validate_compose.py" "set CASAOS_APPSTORE_DIR to a checkout of IceWhaleTech/CasaOS-AppStore"
fi

section "Re-run (idempotent)"
before=$(container_ids)
seeds_before=$(wc -l <"$STATE/seed-runs.log")
stops_before=$(grep -c '"stop"' "$STATE/docker.log" || true)
mark_requests
run_inst rerun -- -y
check "re-run exits 0" test "$RC" == 0
check ".env unchanged" has "$LOG" ".env unchanged"
requests_since >"$OUT/rerun.requests"
check "re-run updates (PUT), never installs twice" diff -u \
  <(printf '%s\n' "GET /v2/app_management/compose" "GET /v2/app_management/compose/torrent-stack" \
    "PUT /v2/app_management/compose/torrent-stack?dry_run=true" "PUT /v2/app_management/compose/torrent-stack") \
  "$OUT/rerun.requests"
check "no container replaced" test "$before" == "$(container_ids)"
check "no re-seeding, nothing stopped" test "$seeds_before" == "$(wc -l <"$STATE/seed-runs.log")" \
  -a "$stops_before" == "$(grep -c '"stop"' "$STATE/docker.log" || true)"

section "--apply after editing .env"
gl=$(id_of gluetun)
fb=$(id_of filebrowser)
sed -i 's/^FILEBROWSER_PORT=.*/FILEBROWSER_PORT=8082/' "$STACK/.env"
run_inst apply-port -- --apply
check "--apply exits 0" test "$RC" == 0
check "FileBrowser recreated on the new port, Gluetun left alone" test "$(id_of filebrowser)" != "$fb" -a "$(id_of gluetun)" == "$gl"
check "new port in the stored app" grep -q "published: '8082'" "$STATE/apps/torrent-stack.yml"

qb=$(id_of qbittorrent)
fb=$(id_of filebrowser)
conf_before=$(sha256sum "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf")
sed -i "s/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD=$QB_PASS2/" "$STACK/.env"
seeds_before=$(wc -l <"$STATE/seed-runs.log")
run_inst apply-pass PATH="$WORK/hostpy:$SHIM_PATH" -- --apply
check "--apply with a new password exits 0" test "$RC" == 0
check "seeded on the host's python3" bash -c "grep -q 'host python3' '$LOG' && test $seeds_before == \$(wc -l <'$STATE/seed-runs.log')"
check "qBittorrent stopped before seeding (FileBrowser is not seeded)" bash -c "grep '\"stop\"' '$STATE/docker.log' | tail -n1 | grep -q '$qb' && ! grep '\"stop\"' '$STATE/docker.log' | tail -n1 | grep -q '$fb'"
check "qBittorrent.conf re-seeded" test "$conf_before" != "$(sha256sum "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf")"
check "the new login is in [WebUI] too (qBittorrent 5.x reads only that)" bash -c "sed -n '/^\[WebUI\]/,/^\[/p' '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf' | grep -q '^Password_PBKDF2='"
check "seeded files belong to PUID, not root" test "$(stat -c %u "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf")" != 0
check "FileBrowser gets the new password too (recreated with it)" test "$fb" != "$(id_of filebrowser)"
check "...in the stored app" fb_rendered "$STATE/apps/torrent-stack.yml" "$QB_PASS2" 1000 "$STACK/configs/filebrowser"
check "fake qBittorrent accepts the new password and refuses the old one" bash -c "$(declare -f qbit_accepts); HERE='$HERE'; qbit_accepts '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf' admin '$QB_PASS2' && ! qbit_accepts '$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf' admin '$QB_PASS'"
check "no secret on any command line after re-seeding" no_secrets_in "$STATE/docker.log"
check "no secret on any curl command line (login check sends files)" no_secrets_in "$STATE/curl.log"
# The seeding CLI alone on a migrated conf: it now writes [WebUI] itself
# (before, the installer had to copy the login there; this caught that bug).
cp "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf" "$WORK/migrated.conf"
mkdir -p "$WORK/legacy/qbittorrent/qBittorrent/nova3/engines"
cp "$WORK/migrated.conf" "$WORK/legacy/qbittorrent/qBittorrent/qBittorrent.conf"
echo stub >"$WORK/legacy/qbittorrent/qBittorrent/nova3/engines/jackett.py"
"$PY_HOST" -I -c 'import sys; sys.dont_write_bytecode=True; sys.path.insert(0, sys.argv[1]); import seed_configs; from pathlib import Path; seed_configs.seed_qbittorrent(Path(sys.argv[2]), "admin", sys.argv[3])' \
  "$REPO/scripts/env-editor" "$WORK/legacy" "Legacy-Only-Pass-4"
check "the seeding CLI alone on a migrated conf: fake qBittorrent accepts the new login" \
  qbit_accepts "$WORK/legacy/qbittorrent/qBittorrent/qBittorrent.conf" admin "Legacy-Only-Pass-4"

section "--apply: host-side Jackett/FlareSolverr ports"
# The search plugin was seeded with Jackett's own port (--jackett-port 9117);
# a host-side port change must not move it.
sed -i -e 's/^JACKETT_PORT=.*/JACKETT_PORT=9118/' -e 's/^FLARESOLVERR_PORT=.*/FLARESOLVERR_PORT=8192/' "$STACK/.env"
qb=$(id_of qbittorrent)
run_inst apply-jport -- --apply
check "--apply with JACKETT_PORT=9118, FLARESOLVERR_PORT=8192 exits 0 (both answer)" test "$RC" == 0
check "only the host port changes: 9118 -> 9117, 8192 -> 8191" bash -c "grep -A1 -x '      - target: 9117' '$STATE/apps/torrent-stack.yml' | grep -q \"published: '9118'\" && grep -A1 -x '      - target: 8191' '$STATE/apps/torrent-stack.yml' | grep -q \"published: '8192'\""
check "search plugin points at Jackett's own port 9117" has "$STACK/configs/qbittorrent/qBittorrent/nova3/engines/jackett.json" '"url": "http://127.0.0.1:9117"'
check "no re-seeding (qBittorrent not stopped) for a port change" bash -c "! grep -q 'Stopping qBittorrent' '$LOG'"
check "the probes went to the new host ports" bash -c "grep -q '^9118 /UI/Dashboard 302' '$STATE/app-requests.log' && grep -q '^8192 / 200' '$STATE/app-requests.log'"
if python3 -I "$HERE/lib/compare_compose.py" "$STACK/casaos-app.yml" "$SRC/compose.yaml" "$STACK/.env" "$STACK" \
  ${IPV6_FLAG[@]+"${IPV6_FLAG[@]}"} >"$OUT/drift-ports.txt" 2>&1; then
  ok "with JACKETT_PORT=9118, FLARESOLVERR_PORT=8192 the services match compose.yaml (JACKETT_PORT:9117 there too)"
else
  bad "with JACKETT_PORT=9118, FLARESOLVERR_PORT=8192 the services match compose.yaml (JACKETT_PORT:9117 there too)" "$(head -3 "$OUT/drift-ports.txt")"
fi
sed -i -e 's/^JACKETT_PORT=.*/JACKETT_PORT=9117/' -e 's/^FLARESOLVERR_PORT=.*/FLARESOLVERR_PORT=8191/' "$STACK/.env"
run_inst apply-jport-back -- --apply
check "ports back to 9117/8191" test "$RC" == 0

section "--apply: a web UI that does not answer, a refused login"
cp "$STACK/configs/jackett/Jackett/ServerConfig.json" "$WORK/sc.good"
sed -i 's/"Port": 9117/"Port": 9200/' "$STACK/configs/jackett/Jackett/ServerConfig.json"
run_inst deadui -- --apply
check "Jackett listening elsewhere inside: exit 3, Jackett named" test "$RC" == 3 -a -n "$(grep 'jackett does not answer on port 9117' "$LOG")"
check "...and success is not claimed" lacks "$LOG" "Every web UI answers"
cp "$WORK/sc.good" "$STACK/configs/jackett/Jackett/ServerConfig.json"
cp "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf" "$WORK/qb.good"
python3 -I -c 'import re,sys; p=sys.argv[1]; t=open(p).read(); open(p,"w").write(re.sub(r"(?m)^Password_PBKDF2=.*$", "Password_PBKDF2=\"@ByteArray(AAAA:BBBB)\"", t))' \
  "$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf"
run_inst badlogin -- --apply
check "qBittorrent refusing the .env login: exit 3 with the TS_RESEED remedy" test "$RC" == 3 -a -n "$(grep 'TS_RESEED=1' "$LOG")"
run_inst reseed TS_RESEED=1 -- --apply
check "TS_RESEED=1 --apply seeds again and the login works" test "$RC" == 0 -a -n "$(grep 'qBittorrent accepts the login' "$LOG")"

section "--apply: an app left outside Gluetun's network"
set_field gluetun netns "net:[4026599999]"
run_inst netns -- --apply
check "Gluetun restarted alone: the apps are restarted into its network, exit 0" test "$RC" == 0 -a -n "$(grep "lost Gluetun's network" "$LOG")"
check "qBittorrent, Jackett, FlareSolverr now in Gluetun's namespace" one_netns
set_config '{"restart_keeps_netns": true}'
set_field gluetun netns "net:[4026588888]"
run_inst netns-stuck -- --apply
check "when restarting does not help: exit 3 with Stop-then-Start advice" test "$RC" == 3 -a -n "$(grep 'Stop the Torrent Stack app, then Start it' "$LOG")"
set_config '{}'
run_inst netns-fixed -- --apply
check "fixed by the next --apply" test "$RC" == 0

section "--apply: CasaOS rolls the change back in the background"
set_config '{"rollback": true}'
sed -i 's/^TZ=.*/TZ=Europe\/Madrid/' "$STACK/.env"
run_inst rollback TS_WAIT=2 -- --apply
check "old definition still running: exit 1, explained, success not claimed" test "$RC" == 1 -a -n "$(grep 'did not switch the app to the new settings' "$LOG")" -a -z "$(grep 'Every web UI answers' "$LOG")"
set_config '{}'
run_inst rollback-retry -- --apply
check "--apply again once CasaOS can apply it" test "$RC" == 0 -a -n "$(grep -c "Europe/Madrid" "$STATE/apps/torrent-stack.yml")"

section "--apply: a new update-qbittorrent.sh recreates Gluetun"
gl=$(id_of gluetun)
echo "# changed by the test" >>"$STACK/update-qbittorrent.sh"
run_inst newscript -- --apply
check "Gluetun recreated (Docker keeps the old file mounted otherwise)" test "$RC" == 0 -a "$(id_of gluetun)" != "$gl"
gl=$(id_of gluetun)
run_inst newscript-again -- --apply
check "...and not again on the next --apply" test "$RC" == 0 -a "$(id_of gluetun)" == "$gl"

section "Duplicate keys in .env"
cp "$STACK/.env" "$WORK/env.nodup"
echo "QBITTORRENT_PASSWORD=Appended-New-Pass-3" >>"$STACK/.env"
mark_requests
run_inst dupkey -- --apply
check "a key set twice: refused, with both line numbers" test "$RC" != 0 -a -n "$(grep -E 'QBITTORRENT_PASSWORD \(lines [0-9]+, [0-9]+\)' "$LOG")"
check "nothing sent to CasaOS after the duplicate refusal" test -z "$(requests_since | grep -E '^(PUT|POST)')"
run_inst dupkey-rerun -- -y
check "re-running the installer keeps one line (the last value, as compose reads it)" bash -c "test \$(grep -c '^QBITTORRENT_PASSWORD=' '$STACK/.env') == 1 && grep -qx 'QBITTORRENT_PASSWORD=Appended-New-Pass-3' '$STACK/.env' && grep -q 'Removed a second QBITTORRENT_PASSWORD line' '$LOG' && test $RC == 0"
cp "$WORK/env.nodup" "$STACK/.env"
run_inst dupkey-restore -- --apply
check "back to the test password" test "$RC" == 0

section "CasaOS's validation comes before anything is stopped or seeded"
stops_before=$(grep -c '"stop"' "$STATE/docker.log" || true)
conf_before=$(sha256sum <"$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf")
cp "$STACK/.env" "$WORK/env.good"
sed -i -e 's/^FILEBROWSER_PORT=.*/FILEBROWSER_PORT=8085/' -e "s/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD=Another-Pass-6/" "$STACK/.env"
set_config '{"ports_in_use": [8085]}'
run_inst validate-first -- --apply
set_config '{}'
check "ports in use: refused" test "$RC" == 1 -a -n "$(grep 'TCP:8085' "$LOG")"
check "...with qBittorrent still running and its config untouched" test "$stops_before" == "$(grep -c '"stop"' "$STATE/docker.log" || true)" -a "$conf_before" == "$(sha256sum <"$STACK/configs/qbittorrent/qBittorrent/qBittorrent.conf")"
cp "$WORK/env.good" "$STACK/.env"

section "Finding the stack without TS_APPDATA"
RUN_SCRIPT="$STACK/platforms/casaos/install.sh" run_inst ownloc TS_APPDATA= -- --print-yaml
check "the stack's own install.sh finds its stack (--print-yaml)" test "$RC" == 0 -a -n "$(grep -c 'name: torrent-stack' "$LOG")"
run_inst adopt TS_APPDATA= -- --apply
check "without TS_APPDATA, the installed app's folder is used" test "$RC" == 0 -a -n "$(grep "The installed app uses $STACK; working there" "$LOG")"
mkdir -p "$WORK/OTHER/AppData"
run_inst adopt-other TS_APPDATA="$WORK/OTHER/AppData" -- --apply
check "an explicit TS_APPDATA that is not the installed one: refused" test "$RC" != 0 -a -n "$(grep "Run this again with TS_APPDATA=$APPDATA" "$LOG")"
cp "$STACK/.env" "$WORK/env.good"
sed -i "s#^CONFIG_PATH=.*#CONFIG_PATH=$WORK/DATA/cfg-moved#" "$STACK/.env"
run_inst keepcfg -- -y --dry-run
check "an absolute CONFIG_PATH in .env is kept by the wizard" has "$LOG" "CONFIG_PATH=$WORK/DATA/cfg-moved"
cp "$WORK/env.good" "$STACK/.env"
sed -i "s#^DOWNLOADS_PATH=.*#DOWNLOADS_PATH=$WORK/DATA#" "$STACK/.env"
run_inst envdl -- --apply
check "DOWNLOADS_PATH in .env that contains the stack: refused by --apply" test "$RC" != 0 -a -n "$(grep "contains $APPDATA" "$LOG")"
cp "$WORK/env.good" "$STACK/.env"

cp "$STACK/.env" "$WORK/env.good"
sed -i "s/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD=abcd/" "$STACK/.env"
mark_requests
run_inst apply-shortpass -- --apply
check "a 4-character QBITTORRENT_PASSWORD in .env: refused (FileBrowser's admin password)" test "$RC" != 0 -a -n "$(grep "is also FileBrowser's admin password, and FileBrowser needs at least 5 bytes" "$LOG")"
check "nothing sent to CasaOS after that refusal" test -z "$(requests_since | grep -E '^(PUT|POST)')"
cp "$WORK/env.good" "$STACK/.env"
sed -i "s/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD='pa\$\$word'/" "$STACK/.env"
mark_requests
run_inst apply-dollar -- --apply
check "a '\$' in a value is refused with an explanation" test "$RC" != 0 -a -n "$(grep "contains a '\\$'" "$LOG")"
if requests_since | grep -q -E '^(PUT|POST)'; then
  bad "nothing sent to CasaOS after the '\$' refusal"
else
  ok "nothing sent to CasaOS after the '\$' refusal"
fi
cp "$WORK/env.good" "$STACK/.env"

section "--print-yaml"
run_inst printyaml -- --print-yaml
check "--print-yaml exits 0" test "$RC" == 0
set +e
env PATH="$SHIM_PATH" TS_APPDATA="$APPDATA" bash "$INSTALL" --print-yaml >"$OUT/print.yml" 2>"$OUT/print.err"
set -e
check "stdout is only the YAML (schema checks pass)" python3 -I "$HERE/lib/casaos_schema.py" "$OUT/print.yml"
check "stderr warns that it holds secrets" has "$OUT/print.err" "contains your VPN key and passwords"
check "it holds the real key (it is for Import)" has "$OUT/print.yml" "$WG_KEY"
TS_IPV6_SYSCTL=on PATH="$SHIM_PATH" TS_APPDATA="$APPDATA" bash "$INSTALL" --print-yaml >"$OUT/print-v6.yml" 2>/dev/null
if python3 -I "$HERE/lib/compare_compose.py" "$OUT/print-v6.yml" "$SRC/compose.yaml" "$STACK/.env" "$STACK" >"$OUT/drift-v6.txt" 2>&1; then
  ok "with the IPv6 sysctl (TS_IPV6_SYSCTL=on) the services match compose.yaml exactly"
else
  bad "with the IPv6 sysctl (TS_IPV6_SYSCTL=on) the services match compose.yaml exactly" "$(head -3 "$OUT/drift-v6.txt")"
fi
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=watchtower/' "$STACK/.env"
TS_IPV6_SYSCTL=on PATH="$SHIM_PATH" TS_APPDATA="$APPDATA" bash "$INSTALL" --print-yaml >"$OUT/print-wt.yml" 2>/dev/null
if python3 -I "$HERE/lib/compare_compose.py" "$OUT/print-wt.yml" "$SRC/compose.yaml" "$STACK/.env" "$STACK" \
  --profile watchtower >"$OUT/drift-wt.txt" 2>&1; then
  ok "with Watchtower on, the services (watchtower included) match compose.yaml"
else
  bad "with Watchtower on, the services (watchtower included) match compose.yaml" "$(head -3 "$OUT/drift-wt.txt")"
fi
check "Watchtower rendering passes the schema checks" python3 -I "$HERE/lib/casaos_schema.py" "$OUT/print-wt.yml"
sed -i 's/^COMPOSE_PROFILES=.*/COMPOSE_PROFILES=/' "$STACK/.env"

section "--print-yaml without root; everything else needs root"
if command -v setpriv >/dev/null 2>&1; then
  # As uid 65534 (nobody), as in CI: --print-yaml only reads .env,
  # compose.yaml and update-qbittorrent.sh, and writes only stdout and its
  # own temporary folder.
  as_nobody() { setpriv --reuid=65534 --regid=65534 --clear-groups -- env HOME=/nonexistent TMPDIR=/tmp "$@"; }
  NR="$WORK/DATA-nr/AppData"
  mkdir -p "$NR/torrent-stack"
  cp "$STACK/.env" "$NR/torrent-stack/.env"
  chown -R 65534:65534 "$WORK/DATA-nr"
  TS_IPV6_SYSCTL=on PATH="$SHIM_PATH" TS_APPDATA="$NR" TS_SOURCE_DIR="$SRC" bash "$INSTALL" --print-yaml >"$OUT/print-root.yml" 2>/dev/null
  set +e
  as_nobody TS_IPV6_SYSCTL=on PATH="$SHIM_PATH" TS_APPDATA="$NR" TS_SOURCE_DIR="$SRC" bash "$INSTALL" --print-yaml \
    >"$OUT/print-nobody.yml" 2>"$OUT/print-nobody.err"
  rc=$?
  set -e
  check "--print-yaml as a user other than root, with a .env it may read: exit 0" test "$rc" == 0
  check "...prints the same YAML as for root" cmp "$OUT/print-root.yml" "$OUT/print-nobody.yml"
  check "...which passes the schema checks" python3 -I "$HERE/lib/casaos_schema.py" "$OUT/print-nobody.yml"
  check "...and writes nothing into the stack folder" test "$(cd "$NR" && find . | sort | tr '\n' ' ')" == ". ./torrent-stack ./torrent-stack/.env "
  set +e
  as_nobody PATH="$SHIM_PATH" TS_APPDATA="$APPDATA" TS_SOURCE_DIR="$SRC" bash "$INSTALL" --print-yaml \
    >"$OUT/print-noread.yml" 2>"$OUT/print-noread.err"
  rc=$?
  set -e
  check "--print-yaml when .env is root's (0600): exit 1, says to run it as root, prints nothing" \
    test "$rc" == 1 -a ! -s "$OUT/print-noread.yml" -a -n "$(grep 'as nobody. It holds the VPN key, so on an installed stack only root may read it: run this as root' "$OUT/print-noread.err")"
  # Every other action stops at the root check, before it talks to CasaOS
  # or changes a file.
  listing() { find "$STACK" "$DOWNLOADS" -printf '%p %s %T@ %m %u:%g\n' | sort; }
  before=$(listing)
  mark_requests
  refused=""
  for args in "-y" "--apply" "--update -y" "--uninstall -y" "--uninstall --purge -y" "-y --dry-run" "-y --no-register"; do
    set +e
    # shellcheck disable=SC2086  # $args is several words on purpose
    as_nobody PATH="$SHIM_PATH" CASAOS_SHIM_STATE="$STATE" TS_CASAOS_API="$API" TS_CASAOS_APPS_DIR="$APPS_DIR" \
      TS_APPDATA="$APPDATA" TS_SOURCE_DIR="$SRC" TS_WAIT=2 TS_POLL_INTERVAL=0 TS_UI=plain \
      bash "$INSTALL" $args </dev/null >"$OUT/nobody.log" 2>&1
    rc=$?
    set -e
    if [[ "$rc" != 1 ]] || ! grep -q 'Run this as root' "$OUT/nobody.log"; then refused+=" [$args: exit $rc]"; fi
  done
  check "as a user other than root, install, --apply, --update, --uninstall (--purge), --dry-run and --no-register are refused (exit 1, 'Run this as root')" test -z "$refused"
  check "...before anything is sent to CasaOS" test -z "$(requests_since)"
  check "...or changed in the stack and downloads folders" test "$before" == "$(listing)"
else
  skip "--print-yaml without root" "setpriv (util-linux) is not installed"
fi

section "--update (new image)"
set_config '{"new_images": ["lscr.io/linuxserver/jackett:latest"]}'
before=$(container_ids)
mark_requests
run_inst update -- --update
set_config '{}'
check "--update exits 0" test "$RC" == 0
requests_since >"$OUT/update.requests"
check "--update applies with PUT" grep -q '^PUT /v2/app_management/compose/torrent-stack$' "$OUT/update.requests"
check "a new image means CasaOS replaced the containers (and the wait saw it)" test "$before" != "$(container_ids)"
check "repository files refreshed (source recorded)" grep -q "^source=$SRC" "$STACK/.casaos-state"
check "--update applies with the freshly copied installer" has "$LOG" "Applying with the updated installer"

# path_without DIR NAME...: fill DIR with links to every command in the
# usual bin folders except NAME..., for a PATH without those commands.
path_without() {
  local dir=$1 d f n
  shift
  mkdir -p "$dir"
  for d in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
    [[ -d "$d" ]] || continue
    for f in "$d"/*; do
      n=${f##*/}
      [[ -e "$dir/$n" || ! -x "$f" || " $* " == *" $n "* ]] && continue
      ln -s "$f" "$dir/$n"
    done
  done
}
path_without "$WORK/nogit" git
path_without "$WORK/notar" tar
path_without "$WORK/nogit-notar" git tar
# busybox (CASAOS_TEST_BUSYBOX, or the one on PATH): its tar (every call
# logged), cp, mkdir and rm, as on a host whose tools are busybox's.
BB="${CASAOS_TEST_BUSYBOX:-$(command -v busybox || true)}"
BB_NAME="" BB_TOOLS="" BB_COPY=""
mkdir -p "$WORK/bbtools"
if [[ -n "$BB" ]]; then
  # (Whole outputs, not a pipe into head or grep -q: busybox would get
  # SIGPIPE, and pipefail would stop the suite.)
  bb_help=$("$BB" 2>&1 || true)
  bb_help=${bb_help%%$'\n'*}
  bb_help=${bb_help#BusyBox }
  BB_NAME="busybox ${bb_help%% *}"
  BB_TOOLS="; ${BB_NAME} tar, cp, mkdir and rm"
  BB_COPY="; ${BB_NAME} cp, mkdir and rm"
  bb_help=$("$BB" tar --help 2>&1 || true)
  if [[ "$bb_help" == *--exclude* ]]; then
    BB_TOOLS+=" (its tar has --exclude)"
  else
    BB_TOOLS+=" (its tar has no --exclude)"
  fi
  printf '#!/bin/sh\necho "$*" >>%q\nexec %q tar "$@"\n' "$STATE/bbtar.log" "$BB" >"$WORK/bbtools/tar"
  chmod +x "$WORK/bbtools/tar"
  for n in cp mkdir rm; do ln -s "$BB" "$WORK/bbtools/$n"; done
fi

section "--update from a tarball (no git${BB_TOOLS})"
# A GitHub-like archive of the working tree, at a tag, whose install.sh
# renders a different app version (to see that the NEW script applied it).
GH="$WORK/gh/rob-paprocki/qbittorrent-vpn-docker"
mkdir -p "$GH/archive" "$WORK/tarsrc"
cp -a "$SRC" "$WORK/tarsrc/qbittorrent-vpn-docker-v9.9.9"
sed -i 's/^readonly RENDER_VERSION="[^"]*"/readonly RENDER_VERSION="9.9.9"/' "$WORK/tarsrc/qbittorrent-vpn-docker-v9.9.9/platforms/casaos/install.sh"
tar -C "$WORK/tarsrc" -czf "$GH/archive/v9.9.9.tar.gz" qbittorrent-vpn-docker-v9.9.9
NOGIT_PATH="$HERE/shims:$HERE/shims/casaos-bin:$WORK/bbtools:$WORK/nogit"
run_inst update-tar PATH="$NOGIT_PATH" TS_SOURCE_DIR= TS_REPO_URL="file://$GH" TS_REF=v9.9.9 -- --update -y
check "--update without git downloads the tarball and exits 0" test "$RC" == 0 -a -n "$(grep "Downloading file://$GH/archive/v9.9.9.tar.gz (git is not installed)" "$LOG")"
check "the new installer did the apply (app version 9.9.9)" grep -q "^  version: '9.9.9'$" "$STATE/apps/torrent-stack.yml"
check "fork and tag remembered for the next --update" bash -c "grep -qx 'ref=v9.9.9' '$STACK/.casaos-state' && grep -qx 'repo_url=file://$GH' '$STACK/.casaos-state'"
run_inst update-tar-again PATH="$NOGIT_PATH" TS_SOURCE_DIR= -- --update -y
check "a plain --update -y (as from cron) keeps that tag and fork" test "$RC" == 0 -a -n "$(grep "Downloading file://$GH/archive/v9.9.9.tar.gz" "$LOG")"
if [[ -n "$BB" ]]; then
  # Its tar only unpacked the download; copying the files needs no tar.
  check "${BB_NAME}: its tar unpacked the tarball, its cp copied the files" bash -c "grep -q -- '^-x -z -o -f ' '$STATE/bbtar.log' && ! grep -v -- '^-x -z -o -f ' '$STATE/bbtar.log' && grep -q 'Repository files are in' '$LOG'"
else
  skip "busybox tar and cp" "no busybox here (set CASAOS_TEST_BUSYBOX)"
fi
mark_requests
run_inst nogit-notar PATH="$HERE/shims:$HERE/shims/casaos-bin:$WORK/nogit-notar" TS_SOURCE_DIR= -- --update -y
check "neither git nor tar: refused with advice (TS_SOURCE_DIR)" test "$RC" == 1 -a -n "$(grep 'Neither git nor tar is installed' "$LOG")"
check "...before anything was sent to CasaOS" test -z "$(requests_since | grep -E '^(PUT|POST|DELETE)')"
# Back to the working tree's own files for the tests below.
run_inst update-back -- --update -y
check "back on the working tree's files" test "$RC" == 0

section "Copying the repository files (no tar${BB_COPY})"
# A source with everything the copy must leave out (each marked DECOY or
# Decoy), names that need care, a symlink and a FIFO, owned by another user
# as a checkout given as TS_SOURCE_DIR may be. In the stack folder,
# symlinks where the copy puts a file and a folder; they must be replaced,
# never written through. Run with umask 077, as the README's cron line does.
CRAFT="$WORK/craft"
cp -a "$SRC" "$CRAFT"
mkdir -p "$CRAFT/.git" "$CRAFT/downloads" "$CRAFT/incomplete" "$CRAFT/scripts/env-editor/.venv/bin" \
  "$CRAFT/scripts/env-editor/__pycache__" "$CRAFT/new folder"
for f in .git/DECOY configs/DECOY downloads/DECOY incomplete/DECOY scripts/env-editor/.venv/bin/DECOY \
  scripts/env-editor/__pycache__/DECOY.cpython-314.pyc scripts/env-editor/DECOY.pyc; do
  echo decoy >"$CRAFT/$f"
done
printf 'QBITTORRENT_PASSWORD=Decoy-Pass-0\n' >"$CRAFT/.env"
printf 'QBITTORRENT_PASSWORD=Decoy-Pass-0\n' >"$CRAFT/.env.local"
echo 'source=Decoy' >"$CRAFT/.casaos-state"
echo 'name: Decoy' >"$CRAFT/casaos-app.yml"
echo dash >"$CRAFT/new folder/-dash file"
echo shared >"$CRAFT/new folder/group-writable"
chmod 664 "$CRAFT/new folder/group-writable"
echo private >"$CRAFT/new folder/private"
chmod 600 "$CRAFT/new folder/private"
chmod 775 "$CRAFT/new folder"
ln -s README.md "$CRAFT/readme-link"
mkfifo "$CRAFT/fifo"
chown -R 1000:1000 "$CRAFT"
echo canary >"$WORK/canary"
mkdir -p "$WORK/canary-dir"
# plant_links: the stack folder as described above, before each copy (and
# ENV_SUM: its .env as it was then).
plant_links() {
  rm -rf "$STACK/README.md" "$STACK/native" "$STACK/new folder" "$STACK/readme-link"
  ln -s "$WORK/canary" "$STACK/README.md"
  ln -s "$WORK/canary-dir" "$STACK/native"
  ENV_SUM=$(sha256sum <"$STACK/.env")
}
# copy_checks WHAT: the stack folder after an --update from $CRAFT.
copy_checks() {
  local what=$1
  check "$what: --update copied the files and exits 0" test "$RC" == 0 -a -n "$(grep 'Repository files are in' "$LOG")"
  check "$what: the source's .git, .env, .env.local, configs/, downloads/, incomplete/, .venv, __pycache__, *.pyc, .casaos-state, casaos-app.yml are left out" \
    bash -c "test -z \"\$(find '$STACK' -name 'DECOY*' -print)\" && test ! -e '$STACK/.env.local' &&
      ! grep -rqs -e Decoy '$STACK/.env' '$STACK/.casaos-state' '$STACK/casaos-app.yml'"
  check "$what: the stack's own .env is kept as it was" test "$ENV_SUM" == "$(sha256sum <"$STACK/.env")"
  check "$what: a name starting with '-', a folder with a space, a symlink kept as a symlink; the FIFO left out" \
    bash -c "test -f '$STACK/new folder/-dash file' -a -L '$STACK/readme-link' -a ! -e '$STACK/fifo' && test \"\$(readlink '$STACK/readme-link')\" == README.md"
  check "$what: copies belong to root, with the source's mode minus group/other write (umask 077 or not)" \
    test "$(owner_mode_of "$STACK/new folder/group-writable") $(owner_mode_of "$STACK/new folder/private") $(owner_mode_of "$STACK/new folder") $(owner_mode_of "$STACK/platforms/casaos/install.sh")" \
    == "0:0 644 0:0 600 0:0 755 0:0 755"
  check "$what: symlinks in the stack folder are replaced, not written through" \
    bash -c "test ! -L '$STACK/README.md' -a ! -L '$STACK/native' -a -d '$STACK/native' && cmp -s '$CRAFT/README.md' '$STACK/README.md' &&
      test \"\$(cat '$WORK/canary')\" == canary -a -z \"\$(ls -A '$WORK/canary-dir')\""
  check "$what: the updated installer applied it" has "$LOG" "Applying with the updated installer"
}
plant_links
old_umask=$(umask)
umask 077
run_inst copy-notar PATH="$HERE/shims:$HERE/shims/casaos-bin:$WORK/nopy:$WORK/notar" TS_SOURCE_DIR="$CRAFT" -- --update -y
umask "$old_umask"
copy_checks "no tar"
if [[ -n "$BB" ]]; then
  plant_links
  : >"$STATE/bbtar.log"
  umask 077
  run_inst copy-busybox PATH="$HERE/shims:$HERE/shims/casaos-bin:$WORK/nopy:$WORK/bbtools:$WORK/notar" TS_SOURCE_DIR="$CRAFT" -- --update -y
  umask "$old_umask"
  copy_checks "$BB_NAME"
  check "$BB_NAME: its tar was not used for the copy" test ! -s "$STATE/bbtar.log"
else
  skip "copying with busybox's cp, mkdir and rm" "no busybox here (set CASAOS_TEST_BUSYBOX)"
fi
rm -rf "$STACK/new folder" "$STACK/readme-link"
run_inst copy-back -- --update -y
check "back on the working tree's files" test "$RC" == 0
# TS_SOURCE_DIR naming the stack folder itself another way: there is
# nothing to copy. (copy_tree removes each file before it copies, so a copy
# of the folder onto itself would delete the repository files.)
ln -sfn "$STACK" "$WORK/stack-link"
pushd "$STACK" >/dev/null
for how in dot:. link:"$WORK/stack-link" slashes:"$STACK//"; do
  run_inst "self-${how%%:*}" TS_SOURCE_DIR="${how#*:}" -- --update -y
  check "TS_SOURCE_DIR=${how#*:} (the stack folder): --update copies nothing, keeps the files and exits 0" \
    bash -c "test '$RC' == 0 && ! grep -q 'Copying the repository files' '$LOG' && grep -q 'Applying with the updated installer' '$LOG' &&
      cmp -s '$SRC/compose.yaml' '$STACK/compose.yaml' && cmp -s '$SRC/platforms/casaos/install.sh' '$STACK/platforms/casaos/install.sh'"
done
popd >/dev/null
rm -f "$WORK/stack-link"

section "Waiting and failure reports"
set_config '{"gluetun_status": "Up 3 minutes (unhealthy)"}'
sed -i 's/^TZ=.*/TZ=Europe\/Paris/' "$STACK/.env"
run_inst unhealthy TS_WAIT=2 -- --apply
check "VPN not connecting: exit 2 with a report" test "$RC" == 2 -a -n "$(grep 'did not come up within 2 s' "$LOG")"
check "the report points at Gluetun's log" has "$LOG" "docker logs --tail 40 torrent-stack-gluetun-1"
set_config '{}'
run_inst healthy-again -- --apply
check "healthy again after --apply" test "$RC" == 0

section "Someone else's app or containers"
sed -i 's/^  id: io.github.rob-paprocki.torrent-stack$/  id: org.example.other/' "$STATE/apps/torrent-stack.yml"
run_inst other -- -y
check "a CasaOS app named torrent-stack that is not ours: refused" test "$RC" != 0 -a -n "$(grep 'not installed by this script' "$LOG")"
run_inst other-force TS_FORCE=1 -- -y
check "TS_FORCE=1 takes it over" test "$RC" == 0 -a -n "$(grep 'TS_FORCE=1' "$LOG")"
cp "$STATE/containers.json" "$WORK/containers.good"
python3 -I -c 'import json,sys; p=sys.argv[1]; rows=json.load(open(p)); [c.update(config_files="/opt/stacks/torrent-stack/compose.yaml") for c in rows]; json.dump(rows, open(p,"w"))' "$STATE/containers.json"
run_inst foreign -- --apply
check "containers from a plain docker compose setup: refused" test "$RC" != 0 -a -n "$(grep 'not by CasaOS' "$LOG")"
cp "$WORK/containers.good" "$STATE/containers.json"

section "Uninstall (keeps data)"
mark_requests
run_inst uninstall -- --uninstall -y
check "--uninstall exits 0" test "$RC" == 0
requests_since >"$OUT/uninstall.requests"
check "DELETE asks CasaOS to keep the app folder" grep -q '^DELETE /v2/app_management/compose/torrent-stack?delete_config_folder=false$' "$OUT/uninstall.requests"
check "stack folder and .env kept" test -f "$STACK/.env"
check "containers gone" test "$(container_ids)" == ""
check "CasaOS's own copy of the app is gone too when --uninstall returns" test ! -e "$APPS_DIR/torrent-stack"

section "Ports already in use"
set_config '{"ports_in_use": [9117]}'
mark_requests
run_inst ports -- -y
check "refused with the port named" test "$RC" == 1 -a -n "$(grep 'ports already in use by something else (TCP:9117' "$LOG")"
check "only CasaOS's validation was sent" test -z "$(requests_since | grep -x 'POST /v2/app_management/compose')"
set_config '{}'

section "Placeholder VPN settings (startup gating)"
APPDATA2="$WORK/DATA2/AppData"
mkdir -p "$APPDATA2"
mark_requests
run_inst gating TS_APPDATA="$APPDATA2" -- -y
check "exits 0 with everything prepared" test "$RC" == 0 -a -f "$APPDATA2/torrent-stack/.env"
check "explains the placeholders and --apply" has "$LOG" "still the .env.example placeholders"
check "Gluetun is not started: no install sent" test -z "$(requests_since | grep -E '^(POST|PUT)')"
check "the generated password is not printed into a log (no terminal); .env named" bash -c "grep -q 'generated: QBITTORRENT_PASSWORD in' '$LOG' && ! grep -q -F \"\$(sed -n 's/^QBITTORRENT_PASSWORD=//p' '$APPDATA2/torrent-stack/.env')\" '$LOG'"

section "--no-register (manual Import)"
APPDATA3="$WORK/DATA3/AppData"
mkdir -p "$APPDATA3/torrent-stack/configs/qbittorrent/qBittorrent/nova3/engines"
echo "# test stub" >"$APPDATA3/torrent-stack/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
mark_requests
run_inst noreg TS_APPDATA="$APPDATA3" TS_WIREGUARD_PRIVATE_KEY_FILE="$WORK/wg.key" \
  TS_WIREGUARD_ADDRESSES=10.2.0.2/32 TS_QBITTORRENT_PASSWORD_FILE="$WORK/qb.pass" -- -y --no-register
check "--no-register exits 0" test "$RC" == 0
check "CasaOS is not contacted at all" test -z "$(requests_since)"
check "the YAML to import is ready (0600) with the Import steps" bash -c "test -f '$APPDATA3/torrent-stack/casaos-app.yml' && grep -q 'Install a customized app > Import' '$LOG'"

section "PUID/PGID other than 1000 (FileBrowser still runs as uid 1000)"
# FileBrowser's image always runs as uid 1000; compose.yaml adds PGID as an
# extra group. With PUID 1001 / PGID 1002 it must still be able to write its
# database and the downloads, through the group.
APPDATA6="$WORK/DATA6/AppData"
DL6="$WORK/DATA6/Media/Downloads"
S6="$APPDATA6/torrent-stack"
mkdir -p "$S6/configs/qbittorrent/qBittorrent/nova3/engines" "$S6/configs/filebrowser"
echo "# test stub" >"$S6/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
# What FileBrowser wrote on an earlier start: its files belong to uid 1000.
printf 'db' >"$S6/configs/filebrowser/database.sqlite"
chown 1000:1000 "$S6/configs/filebrowser/database.sqlite"
chmod 644 "$S6/configs/filebrowser/database.sqlite"
run_inst pgid TS_APPDATA="$APPDATA6" TS_DOWNLOADS="$DL6" TS_PUID=1001 TS_PGID=1002 \
  TS_WIREGUARD_PRIVATE_KEY_FILE="$WORK/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_QBITTORRENT_PASSWORD_FILE="$WORK/qb.pass" -- -y --no-register
check "PUID 1001 / PGID 1002 (--no-register) exits 0" test "$RC" == 0
check "FileBrowser gets 1002 as extra group in the rendered app" fb_rendered "$S6/casaos-app.yml" "$QB_PASS" 1002 "$S6/configs/filebrowser"
if python3 -I "$HERE/lib/compare_compose.py" "$S6/casaos-app.yml" "$SRC/compose.yaml" "$S6/.env" "$S6" \
  ${IPV6_FLAG[@]+"${IPV6_FLAG[@]}"} >"$OUT/drift-pgid.txt" 2>&1; then
  ok "with PUID 1001 / PGID 1002 the services match compose.yaml"
else
  bad "with PUID 1001 / PGID 1002 the services match compose.yaml" "$(head -3 "$OUT/drift-pgid.txt")"
fi
check "new downloads folder and its incomplete folder: 1001:1002, 2775" \
  test "$(owner_mode_of "$DL6") $(owner_mode_of "$DL6/incomplete")" == "1001:1002 2775 1001:1002 2775"
check "FileBrowser's config folder: 1001:1002, 2775" test "$(owner_mode_of "$S6/configs/filebrowser")" == "1001:1002 2775"
check "its database from an earlier start: 1001:1002 and group-writable (664)" test "$(owner_mode_of "$S6/configs/filebrowser/database.sqlite")" == "1001:1002 664"
check "qBittorrent's config folder: 1001:1002, not group-writable (only PUID writes there)" test "$(owner_mode_of "$S6/configs/qbittorrent")" == "1001:1002 755"
check "no warning about the downloads folder (made by the installer)" lacks "$LOG" "may not be able to write there"
# The kernel's verdict: a process as uid 1000 with the extra group 1002 (what
# Docker gives FileBrowser for group_add) can write there; without it, not.
if command -v setpriv >/dev/null 2>&1; then
  as_fb() { setpriv --reuid=1000 --regid=1000 --groups="$1" -- "${@:2}"; }
  check "as uid 1000 + group 1002: write the database, create files in its folder and the downloads" \
    as_fb 1000,1002 sh -c "printf x >>'$S6/configs/filebrowser/database.sqlite' && : >'$S6/configs/filebrowser/database.sqlite-wal' && mkdir '$DL6/from-filebrowser' && : >'$DL6/incomplete/x'"
  check "...the files it creates there get group 1002 (setgid)" \
    test "$(stat -c %g "$S6/configs/filebrowser/database.sqlite-wal") $(stat -c %g "$DL6/from-filebrowser")" == "1002 1002"
  check_not "control: as uid 1000 without group 1002, its database is read-only" \
    as_fb 1000 sh -c "printf x >>'$S6/configs/filebrowser/database.sqlite'"
  rm -f "$S6/configs/filebrowser/database.sqlite-wal"
  run_inst pgid-again TS_APPDATA="$APPDATA6" TS_DOWNLOADS="$DL6" -- -y --no-register
  check "a re-run keeps it so (database group-writable, folder setgid)" \
    test "$RC $(owner_mode_of "$S6/configs/filebrowser/database.sqlite") $(owner_mode_of "$S6/configs/filebrowser")" == "0 1001:1002 664 1001:1002 2775"
else
  skip "write checks as uid 1000 + group 1002" "setpriv (util-linux) is not installed"
fi

section "ZimaOS"
run_inst zima PATH="$HERE/shims:$HERE/shims/zimaos-bin:$PATH" TS_APPDATA="$APPDATA3" -- -y --dry-run
check "ZimaOS detected from 'zimaos -v'" test "$RC" == 0 -a -n "$(grep 'ZimaOS 1.8.0' "$LOG")"

section "Wizard (whiptail)"
APPDATA4="$WORK/DATA4/AppData"
mkdir -p "$APPDATA4/torrent-stack/configs/qbittorrent/qBittorrent/nova3/engines"
echo "# test stub" >"$APPDATA4/torrent-stack/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
: >"$WORK/empty-input"
rm -f "$STATE"/whiptail.*
run_tty wizard-wt "$WORK/empty-input" TS_UI=whiptail TS_APPDATA="$APPDATA4" \
  WT_DOWNLOADS_FOLDER="$WORK/DATA4/Media/Downloads" WT_TIME_ZONE=Europe/Oslo \
  "WT_VPN_PROVIDER=private internet access" WT_VPN_PROTOCOL=openvpn WT_OPENVPN_USERNAME=p1234567 \
  WT_OPENVPN_PASSWORD="$OVPN_PASS" WT_OPENVPN_TRANSPORT=tcp "WT_SERVER_COUNTRIES=Netherlands,Switzerland" \
  WT_QBITTORRENT_USER=rob WT_QBITTORRENT_PASSWORD= WT_WEB_UI_PORTS=yes WT_QBITTORRENT_PORT=8095 \
  WT_AUTOMATIC_UPDATES=yes WT_READY=yes --
E4="$APPDATA4/torrent-stack/.env"
check "wizard install exits 0" test "$RC" == 0
check "answers written to .env" bash -c "grep -qx \"VPN_PROVIDER='private internet access'\" '$E4' && grep -qx 'VPN_TYPE=openvpn' '$E4' &&
  grep -qx 'OPENVPN_USER=p1234567' '$E4' && grep -qx 'OPENVPN_PROTOCOL=tcp' '$E4' && grep -qx 'QBIT_WEBUI_PORT=8095' '$E4' &&
  grep -qx 'QBITTORRENT_USER=rob' '$E4' && grep -qx 'COMPOSE_PROFILES=watchtower' '$E4' && grep -qx 'TZ=Europe/Oslo' '$E4' &&
  grep -qx \"SERVER_COUNTRIES=Netherlands,Switzerland\" '$E4'"
check "OpenVPN password stored, never shown" bash -c "grep -qx 'OPENVPN_PASSWORD=$OVPN_PASS' '$E4' && ! grep -q -F '$OVPN_PASS' '$STATE/whiptail.log' '$LOG'"
check "an empty qBittorrent password is generated and shown once" bash -c "pw=\$(sed -n 's/^QBITTORRENT_PASSWORD=//p' '$E4'); test \${#pw} -eq 20 && grep -q -F \"\$pw\" '$LOG'"
check "Watchtower included and started" grep -q '^  watchtower:$' "$APPDATA4/torrent-stack/casaos-app.yml"
check "dashboard opens qBittorrent on the chosen port" grep -q "^  port_map: '8095'$" "$APPDATA4/torrent-stack/casaos-app.yml"
run_inst wizard-wt-uninstall TS_APPDATA="$APPDATA4" -- --uninstall --purge -y
check "--uninstall --purge removes the stack folder, keeps downloads" test "$RC" == 0 -a ! -e "$APPDATA4/torrent-stack" -a -d "$WORK/DATA4/Media/Downloads/incomplete"

section "Wizard (plain prompts, as without whiptail)"
APPDATA5="$WORK/DATA5/AppData"
mkdir -p "$APPDATA5"
# downloads, tz, provider, protocol, key, address, countries, user,
# password, webhook, change ports?, watchtower?, ready?
printf '%s\n' "" "" "1" "1" "$WG_KEY" "10.2.0.2/32" "" "" "" "" "n" "n" "y" >"$WORK/plain-input"
run_tty wizard-plain "$WORK/plain-input" TS_UI=plain TS_APPDATA="$APPDATA5" -- --dry-run
check "plain wizard (dry run) exits 0" test "$RC" == 0
check "plain wizard reached the summary and the .env preview" bash -c "grep -q 'would write $APPDATA5/torrent-stack/.env' '$LOG' && grep -q 'WIREGUARD_ADDRESSES=10.2.0.2/32' '$LOG'"
# (The key typed in is echoed by script(1)'s pseudo-terminal before read -s
# turns echo off, so only the .env preview is checked here.)
check "plain wizard masks the key in the .env preview" has "$LOG" "WIREGUARD_PRIVATE_KEY=********"

# ---------------------------------------------------------------------------
printf '\n%d passed, %d failed, %d skipped\n' "$PASS" "$FAIL" "$SKIP"
if ((FAIL > 0)); then
  printf 'Failed:\n'
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
