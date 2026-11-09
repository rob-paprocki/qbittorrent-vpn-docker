#!/usr/bin/env bash
#
# platforms/truenas/tests/run-tests.sh
#
# Purpose: test platforms/truenas/install.sh without a TrueNAS machine.
# midclt, TrueNAS's Python API client, ss and whiptail are replaced by
# stand-ins (tests/shims, tests/pylib) backed by tests/lib/fake_middleware.py,
# which checks every API call against the TrueNAS 25.10 API documentation
# (parameters, and whether the method is a job) and validates the app YAML
# with `docker compose config` as middlewared does. The scenarios run the
# real installer against the real repository (TS_SOURCE_DIR), with real
# seeding, inside a private mount namespace whose /mnt and /dev/shm are
# empty tmpfs, so pool paths are the real /mnt/<pool> and nothing on the
# host changes.
#
# Usage (as root): platforms/truenas/tests/run-tests.sh
#   TS_TEST_WORK=dir       keep the work files there (default: a temp dir)
#
# Needs: bash, python3 with PyYAML, docker with the compose plugin (only
# `docker compose config` is used), unshare, rsync, setpriv, network access
# to raw.githubusercontent.com (the qBittorrent search plugin download in
# the seeding CLI).
#
# License: MIT (see LICENSE in the repository root).

set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(dirname "$HERE")"
REPO_DIR="$(cd "$PLATFORM_DIR/../.." && pwd)"
INSTALLER="$PLATFORM_DIR/install.sh"

if [[ -z "${TS_TEST_IN_NS:-}" ]]; then
  [[ "$(id -u)" -eq 0 ]] || {
    echo "run as root (needs a private mount namespace)" >&2
    exit 1
  }
  exec unshare --mount --propagation private --fork env TS_TEST_IN_NS=1 bash "$0" "$@"
fi

mount -t tmpfs -o mode=0755 tmpfs /mnt
mount -t tmpfs -o mode=1777 tmpfs /dev/shm

WORK="${TS_TEST_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
export TN_SHIM_STATE="$WORK/state"
export PATH="$HERE/shims:$PATH"
export PYTHONPATH="$HERE/pylib"
export TS_SOURCE_DIR="$REPO_DIR"
unset TS_UNATTENDED TS_INTERACTIVE TS_UI

PASS=0
FAIL=0
FAILED=()
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  FAILED+=("$CURRENT: $1")
  printf '  FAIL  %s\n' "$1"
}
check() { # description command...
  local desc=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$desc"; else bad "$desc"; fi
}

# q EXPR: evaluate a Python expression over the recorded calls (`calls`),
# the fake middleware's state (`st`) and helpers; print the result.
q() {
  python3 - "$1" <<'PY'
import json, os, sys
d = os.environ["TN_SHIM_STATE"]
calls = []
if os.path.exists(f"{d}/calls.jsonl"):
    calls = [json.loads(l) for l in open(f"{d}/calls.jsonl")]
st = json.load(open(f"{d}/state.json"))
methods = [c["method"] for c in calls]
mutating = [c["method"] for c in calls if c["method"] in (
    "pool.dataset.create", "filesystem.chown", "filesystem.setperm", "app.image.pull",
    "app.create", "app.update", "app.delete", "app.start", "app.stop")]
def first(m):
    return next(c for c in calls if c["method"] == m)
r = eval(sys.argv[1])
print(json.dumps(r) if not isinstance(r, str) else r)
PY
}
qtrue() { [[ "$(q "$1")" == true ]]; }
# Some checks run q inside `bash -c`.
export -f q

new_state() { # [version] [docker status]
  rm -rf "$TN_SHIM_STATE"
  mkdir -p "$TN_SHIM_STATE"
  find /mnt -mindepth 1 -delete
  mkdir -p /mnt/tank /mnt/media /mnt/.ix-apps
  python3 - "$TN_SHIM_STATE/state.json" "${1:-TrueNAS-25.10.1}" "${2:-RUNNING}" <<'PY'
import json, sys
def ds(name, mount):
    return {"id": name, "name": name, "pool": name.split("/")[0], "type": "FILESYSTEM",
            "mountpoint": mount, "locked": False, "encrypted": False, "share_type": "GENERIC"}
state = {
    "version": sys.argv[2], "docker_status": sys.argv[3], "apps_pool": "tank",
    "timezone": "Europe/Berlin",
    "pools": [{"name": "tank", "path": "/mnt/tank"}, {"name": "media", "path": "/mnt/media"}],
    "datasets": {"tank": ds("tank", "/mnt/tank"), "media": ds("media", "/mnt/media"),
                 "tank/ix-apps": ds("tank/ix-apps", "/mnt/.ix-apps")},
    "apps": {}, "other_app_ports": [30000], "listening": [22, 80, 443, 445],
}
json.dump(state, open(sys.argv[1], "w"), indent=1)
PY
}

clear_calls() { rm -f "$TN_SHIM_STATE/calls.jsonl"; }

state_set() { # python statement on `st`
  python3 - "$TN_SHIM_STATE/state.json" "$1" <<'PY'
import json, sys
p = sys.argv[1]
st = json.load(open(p))
exec(sys.argv[2])
json.dump(st, open(p, "w"), indent=1)
PY
}

# run [args...]: run the installer unattended; output in $OUT / $ERR.
OUT="$WORK/out.txt"
ERR="$WORK/err.txt"
RC=0
run() {
  RC=0
  env TS_UNATTENDED="${TS_UNATTENDED:-1}" bash "$INSTALLER" "$@" >"$OUT" 2>"$ERR" </dev/null || RC=$?
}
show_logs() {
  echo "  --- stdout"
  tail -n 30 "$OUT" | sed 's/^/  | /'
  echo "  --- stderr"
  tail -n 30 "$ERR" | sed 's/^/  | /'
}

no_schema_errors() { [[ "$(q 'sum(1 for c in calls if "schema_error" in c)')" == 0 ]]; }
# A secret must not be on any midclt command line (passed via env, not argv).
secret_not_in_argv() {
  SECRET="$1" python3 - "$TN_SHIM_STATE/calls.jsonl" <<'PY'
import json, os, sys
s = os.environ["SECRET"]
bad = [c for c in map(json.loads, open(sys.argv[1])) if any(s in a for a in c.get("argv", []))]
sys.exit(1 if bad else 0)
PY
}
shm_clean() { [[ -z "$(find /dev/shm -mindepth 1 -maxdepth 1 -name 'torrent-stack.*' -print -quit)" ]]; }
app_yaml() { q "st['apps']['${1:-torrent-stack}']['yaml']"; }
compose_ok() { # yaml-file
  docker compose -p ix-test -f "$1" config -q
}
# same_as_compose APP: the services in the app's stored YAML are exactly
# what `docker compose config` makes of the repository's compose.yaml with
# the same settings (read back from that YAML), apart from the differences
# the README lists: no watchtower, update-qbittorrent.sh mounted from the
# dataset copy. So the installer adds no FileBrowser or port overrides of
# its own. Compose runs with an empty environment, so nothing from this
# shell (TZ, ...) can replace a value from the .env file.
same_as_compose() {
  local d="$WORK/same" hp="$PLATFORM_DIR/truenas_app.py"
  rm -rf "$d"
  mkdir -p "$d"
  chmod 700 "$d"
  (umask 077 && q "st['apps']['${1:-torrent-stack}']['config']" >"$d/current.json" &&
    q "st['apps']['${1:-torrent-stack}']['yaml']" >"$d/app.yaml")
  python3 "$hp" extract --repo "$REPO_DIR" --config "$d/current.json" --out "$d/layer" --meta "$d/meta" &&
    python3 "$hp" merge --repo "$REPO_DIR" --layer "$d/layer" --out "$d/values.json" &&
    python3 "$hp" envfile --repo "$REPO_DIR" --values "$d/values.json" --out "$d/stack.env" &&
    env -i PATH="$PATH" HOME="$HOME" docker compose -p ix-test --project-directory "$REPO_DIR" \
      -f "$REPO_DIR/compose.yaml" --env-file "$d/stack.env" config --format json >"$d/repo.json" &&
    env -i PATH="$PATH" HOME="$HOME" docker compose -p ix-test -f "$d/app.yaml" config --format json >"$d/app.json" &&
    python3 - "$d/repo.json" "$d/app.json" <<'PY'
import json, sys
repo = json.load(open(sys.argv[1]))["services"]
app = json.load(open(sys.argv[2]))["services"]
repo.pop("watchtower", None)
for services in (repo, app):
    vols = services["gluetun"]["volumes"]
    services["gluetun"]["volumes"] = [v for v in vols if v.get("target") != "/gluetun/update-qbittorrent.sh"]
diff = sorted(k for k in set(repo) | set(app) if repo.get(k) != app.get(k))
if diff:
    print("services that differ from compose.yaml:", diff, file=sys.stderr)
sys.exit(1 if diff else 0)
PY
}
services_started_by_default() { # yaml-file -> service list
  docker compose -p ix-test -f "$1" config --services | sort | tr '\n' ' '
}
owner() { stat -c '%u:%g' "$1"; }
mode() { stat -c '%a' "$1"; }

SECRET_DIR="$WORK/secrets"
mkdir -p "$SECRET_DIR"
chmod 700 "$SECRET_DIR"
WG_KEY='yAnz5TF+lXXJte14tji3zlMNq+hd2rYUIgJBgB3fBmk='
printf '%s\n' "$WG_KEY" >"$SECRET_DIR/wg.key"
chmod 600 "$SECRET_DIR/wg.key"

echo "Static checks"
CURRENT=static
SC=$(command -v shellcheck || find /tmp -path '*/scratchpad/tools/*' -name shellcheck -type f -perm -u+x 2>/dev/null | head -1 || true)
for f in "$INSTALLER" "$HERE/run-tests.sh" "$HERE/runtime-images.sh" "$HERE/shims/ss" "$HERE/shims/whiptail"; do
  check "bash -n $(basename "$f")" bash -n "$f"
  if [[ -n "$SC" ]]; then check "shellcheck -S warning $(basename "$f")" "$SC" -S warning "$f"; fi
done
check "python3 compiles truenas_app.py and the shims" python3 -m py_compile \
  "$PLATFORM_DIR/truenas_app.py" "$HERE/lib/fake_middleware.py" "$HERE/shims/midclt" \
  "$HERE/pylib/truenas_api_client/__init__.py"
find "$PLATFORM_DIR" -name __pycache__ -type d -prune -exec rm -rf {} +

# ---------------------------------------------------------------------------
echo "A: fresh install, unattended, no VPN settings (gated)"
CURRENT=A
new_state
run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "every call matches the 25.10 API docs" no_schema_errors
check "datasets created: tank/torrent-stack GENERIC, configs APPS, downloads APPS" qtrue \
  "[[c['params'][0]['name'], c['params'][0]['share_type']] for c in calls if c['method']=='pool.dataset.create'] == [['tank/torrent-stack','GENERIC'],['tank/torrent-stack/configs','APPS'],['tank/torrent-stack/downloads','APPS']]"
check "app.create was called once through the API client (not midclt)" qtrue \
  "[c['via'] for c in calls if c['method']=='app.create'] == ['client']"
check "all five images pre-pulled before app.create" qtrue \
  "methods.index('app.create') > max(i for i,m in enumerate(methods) if m=='app.image.pull') and len(st['pulled'])==5"
app_yaml >"$WORK/A.yaml"
check "stored YAML passes docker compose config" compose_ok "$WORK/A.yaml"
check "while gated only filebrowser starts" test "$(services_started_by_default "$WORK/A.yaml")" == "filebrowser "
check "no watchtower in the YAML" bash -c "! grep -q watchtower: '$WORK/A.yaml'"
check "no \${VAR} left in the YAML" bash -c "! grep -q '\${' '$WORK/A.yaml'"
check "gluetun has NET_ADMIN and /dev/net/tun" qtrue \
  "'NET_ADMIN' in st['apps']['torrent-stack']['config']['services']['gluetun']['cap_add'] and '/dev/net/tun:/dev/net/tun' in st['apps']['torrent-stack']['config']['services']['gluetun']['devices']"
check "qbittorrent/jackett/flaresolverr are in gluetun's network namespace" qtrue \
  "all(st['apps']['torrent-stack']['config']['services'][s]['network_mode']=='service:gluetun' for s in ('qbittorrent','jackett','flaresolverr'))"
check "PUID/PGID default to TrueNAS's apps user 568" qtrue \
  "st['apps']['torrent-stack']['config']['services']['qbittorrent']['environment']['PUID']=='568'"
check "TZ comes from system.general.config" qtrue \
  "st['apps']['torrent-stack']['config']['services']['gluetun']['environment']['TZ']=='Europe/Berlin'"
check "filebrowser gets group_add PGID" qtrue \
  "st['apps']['torrent-stack']['config']['services']['filebrowser']['group_add']==['568']"
check "update-qbittorrent.sh mounted from the dataset copy" qtrue \
  "'/mnt/tank/torrent-stack/source/update-qbittorrent.sh:/gluetun/update-qbittorrent.sh:ro' in st['apps']['torrent-stack']['config']['services']['gluetun']['volumes']"
QPW=$(q "st['apps']['torrent-stack']['config']['services']['gluetun']['environment']['QBITTORRENT_PASSWORD']")
check "a qBittorrent password was generated (24 chars)" test "${#QPW}" -eq 24
check "the generated password is printed once in the summary" grep -q "admin / $QPW" "$OUT"
check "the password is not on any midclt command line" secret_not_in_argv "$QPW"
C=/mnt/tank/torrent-stack/configs
check "qBittorrent.conf seeded with a PBKDF2 hash" grep -q 'WebUI\\Password_PBKDF2="@ByteArray(' "$C/qbittorrent/qBittorrent/qBittorrent.conf"
check "Jackett API key seeded" python3 -c "import json,sys; sys.exit(0 if json.load(open('$C/jackett/Jackett/ServerConfig.json'))['APIKey'] else 1)"
check "qBittorrent search plugin wired to Jackett" test -s "$C/qbittorrent/qBittorrent/nova3/engines/jackett.json"
QCONF="$C/qbittorrent/qBittorrent/qBittorrent.conf"
check "qBittorrent.conf has the image defaults: SavePath /downloads/" grep -qx 'Downloads\\SavePath=/downloads/' "$QCONF"
check "  ... TempPath /downloads/incomplete/, UPnP off, legal notice accepted" bash -c \
  "grep -qx 'Downloads\\\\TempPath=/downloads/incomplete/' '$QCONF' && grep -qx 'Connection\\\\UPnP=false' '$QCONF' && grep -qx 'Accepted=true' '$QCONF'"
PLUGIN_SHA=$(sed -n 's/^QBIT_JACKETT_PLUGIN_SHA256=//p' "$REPO_DIR/native/versions.env")
check "Jackett search plugin is the pinned one (sha256 from native/versions.env)" test \
  "$(sha256sum "$C/qbittorrent/qBittorrent/nova3/engines/jackett.py" | cut -d' ' -f1)" == "$PLUGIN_SHA"
check "search plugin URL is Jackett inside the VPN namespace (127.0.0.1:9117)" python3 -c \
  "import json,sys; sys.exit(0 if json.load(open('$C/qbittorrent/qBittorrent/nova3/engines/jackett.json'))['url']=='http://127.0.0.1:9117' else 1)"
check "FileBrowser keeps its database in its config folder (compose.yaml's FILEBROWSER_DATABASE_PATH)" qtrue \
  "(lambda f: f['environment']['FILEBROWSER_DATABASE_PATH']=='/config/database.sqlite' and '$C/filebrowser:/config' in f['volumes'])(st['apps']['torrent-stack']['config']['services']['filebrowser'])"
check "FileBrowser's admin password is the qBittorrent password (compose.yaml's FILEBROWSER_ADMIN_PASSWORD)" qtrue \
  "st['apps']['torrent-stack']['config']['services']['filebrowser']['environment']['FILEBROWSER_ADMIN_PASSWORD']=='$QPW'"
check "summary names the FileBrowser login" grep -q 'FileBrowser login: admin, with the qBittorrent password' "$OUT"
check "no unused FileBrowser settings.yaml written" test ! -e "$C/filebrowser/settings.yaml"
check "gluetun publishes 8090:8090, and Jackett/FlareSolverr to 9117/8191 inside (as compose.yaml does)" qtrue \
  "(lambda p: '9117:9117/tcp' in p and '8191:8191/tcp' in p and '8090:8090/tcp' in p)(st['apps']['torrent-stack']['config']['services']['gluetun']['ports'])"
check "repository copy carries the installer's marker for this app" grep -qx 'app=torrent-stack' /mnt/tank/torrent-stack/source/.torrent-stack-source
check "summary shows the app state" grep -q 'State:.*RUNNING' "$OUT"
check "no stop marker left behind" test ! -e "$C/.torrent-stack-stopped"
check "config folders owned by 568:568" test "$(owner "$C/qbittorrent/qBittorrent/qBittorrent.conf")" == 568:568
check "FileBrowser's config folder: 1000:568, mode 2770 (group-writable, setgid, closed to others)" \
  test "$(owner "$C/filebrowser") $(mode "$C/filebrowser")" == "1000:568 2770"
check "downloads dataset: 568:568, mode 2775 (group-writable, setgid)" \
  test "$(owner /mnt/tank/torrent-stack/downloads) $(mode /mnt/tank/torrent-stack/downloads)" == "568:568 2775"
check "incomplete folder created: 568:568, mode 2775" \
  test "$(owner /mnt/tank/torrent-stack/downloads/incomplete) $(mode /mnt/tank/torrent-stack/downloads/incomplete)" == "568:568 2775"
# FileBrowser's user in the container: uid 1000, gid 1000, plus PGID from
# compose.yaml's group_add (checked with the real image in runtime-images.sh).
as_filebrowser() { setpriv --reuid=1000 --regid=1000 --groups="$1" -- "${@:2}"; }
check "uid 1000 with group 568 (FileBrowser) can write to the downloads, incomplete/ and its config folder" bash -c \
  "$(declare -f as_filebrowser); as_filebrowser 568 test -w /mnt/tank/torrent-stack/downloads && as_filebrowser 568 test -w /mnt/tank/torrent-stack/downloads/incomplete && as_filebrowser 568 test -w '$C/filebrowser'"
check "  ... but not without group 568 (the access is through the group)" bash -c \
  "$(declare -f as_filebrowser); ! as_filebrowser 1000 test -w /mnt/tank/torrent-stack/downloads"
check "no FileBrowser write warning for a downloads dataset the installer made" bash -c "! grep -q 'FileBrowser (user 1000' '$OUT'"
check "seeded secrets are not world-readable" test "$(mode "$C/qbittorrent/qBittorrent/qBittorrent.conf")" == 600
check "repository copy is root-owned" test "$(owner /mnt/tank/torrent-stack/source/compose.yaml)" == 0:0
check "repository copy not writable by group/others" bash -c "[[ -z \$(find /mnt/tank/torrent-stack/source -perm /022 -print -quit) ]]"
check "update-qbittorrent.sh is 0755" test "$(mode /mnt/tank/torrent-stack/source/update-qbittorrent.sh)" == 755
check "setperm stripped ACLs on the copy" qtrue \
  "any(p['method']=='filesystem.setperm' and p['path']=='/mnt/tank/torrent-stack/source' and p['options']['stripacl'] for p in st['perm_calls'])"
check "no .git or .env copied" bash -c "[[ ! -e /mnt/tank/torrent-stack/source/.git && ! -e /mnt/tank/torrent-stack/source/.env ]]"
check "summary explains how to finish the VPN setup" grep -q 'VPN settings are not filled in' "$OUT"
check "work folder in /dev/shm removed" shm_clean
CONF_HASH=$(sha256sum "$C/qbittorrent/qBittorrent/qBittorrent.conf")

# ---------------------------------------------------------------------------
echo "B: re-run with VPN settings (update, gate lifted, password kept)"
CURRENT=B
clear_calls
TS_VPN_PROVIDER=protonvpn TS_WIREGUARD_PRIVATE_KEY_FILE="$SECRET_DIR/wg.key" TS_WIREGUARD_ADDRESSES=10.2.0.2/32 \
  TS_SERVER_COUNTRIES=Switzerland run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "every call matches the 25.10 API docs" no_schema_errors
check "app.update (not app.create), no datasets created" qtrue \
  "'app.update' in methods and 'app.create' not in methods and 'pool.dataset.create' not in methods"
app_yaml >"$WORK/B.yaml"
check "YAML passes docker compose config" compose_ok "$WORK/B.yaml"
check "gate lifted: all five services start" test "$(services_started_by_default "$WORK/B.yaml")" == "filebrowser flaresolverr gluetun jackett qbittorrent "
check "the app's services are compose.yaml's as docker compose renders them (no TrueNAS overrides)" same_as_compose
check "WireGuard key from the _FILE variable is in the YAML" qtrue \
  "st['apps']['torrent-stack']['config']['services']['gluetun']['environment']['WIREGUARD_PRIVATE_KEY']=='$WG_KEY'"
check "the WireGuard key is not on any midclt command line" secret_not_in_argv "$WG_KEY"
check "qBittorrent password kept from the app's YAML" qtrue \
  "st['apps']['torrent-stack']['config']['services']['gluetun']['environment']['QBITTORRENT_PASSWORD']=='$QPW'"
check "no reseed (qBittorrent.conf unchanged, app not stopped)" bash -c \
  "[[ '$(sha256sum "$C/qbittorrent/qBittorrent/qBittorrent.conf")' == '$CONF_HASH' ]] && ! grep -q 'app.stop' '$TN_SHIM_STATE/calls.jsonl'"
check "password not shown again" bash -c "! grep -q '$QPW' '$OUT'"
check "diff lists the changed VPN settings" grep -q 'changed: services.gluetun.environment.WIREGUARD_PRIVATE_KEY' "$OUT"
check "diff says the gated services start now" grep -q 'starts now (VPN settings filled in): gluetun' "$OUT"
check "lifting the gate is not reported as a lost hand edit" bash -c "! grep -q 'removed:' '$OUT'"

# ---------------------------------------------------------------------------
echo "C: re-run with nothing changed (idempotent)"
CURRENT=C
clear_calls
# As the installer before this change left it: FileBrowser's folder 0755.
chmod 0755 "$C/filebrowser"
run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "no app.update, app.create or dataset creation" qtrue \
  "not ({'app.update','app.create','pool.dataset.create','app.stop'} & set(methods))"
check "says the YAML is up to date" grep -q 'already up to date' "$OUT"
check "an older install's FileBrowser folder (0755) becomes 2770" test "$(mode "$C/filebrowser")" == 2770

# ---------------------------------------------------------------------------
echo "D: an edit made in the web UI's YAML is kept; a hand-added key is reported"
CURRENT=D
clear_calls
state_set "e = st['apps']['torrent-stack']['config']['services']['gluetun']['environment']; e['SERVER_COUNTRIES'] = 'Netherlands'; e['MY_EXTRA'] = 'x'; st['apps']['torrent-stack']['config']['services']['qbittorrent']['environment']['PUID'] = 1000; st['apps']['torrent-stack']['config']['services']['filebrowser']['environment']['FILEBROWSER_ADMIN_PASSWORD'] = 'hand-edited-pw'"
run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "SERVER_COUNTRIES edited in the UI is kept" qtrue \
  "st['apps']['torrent-stack']['config']['services']['gluetun']['environment']['SERVER_COUNTRIES']=='Netherlands'"
# compose.yaml now uses ${QBITTORRENT_PASSWORD} twice (gluetun and
# FileBrowser); the one read back is gluetun's, so a FileBrowser-only edit
# goes back to the qBittorrent password and changes no login.
check "FILEBROWSER_ADMIN_PASSWORD edited alone goes back to the qBittorrent password" qtrue \
  "(lambda s: s['filebrowser']['environment']['FILEBROWSER_ADMIN_PASSWORD']=='$QPW' and s['gluetun']['environment']['QBITTORRENT_PASSWORD']=='$QPW')(st['apps']['torrent-stack']['config']['services'])"
check "  ... reported as changed, and no re-seed (no app.stop)" bash -c \
  "grep -q 'changed: services.filebrowser.environment.FILEBROWSER_ADMIN_PASSWORD' '$OUT' && ! grep -q '\"app.stop\"' '$TN_SHIM_STATE/calls.jsonl'"
check "an unquoted number typed in the UI (PUID: 1000) is read back" qtrue \
  "st['apps']['torrent-stack']['config']['services']['jackett']['environment']['PUID']=='1000'"
check "the hand-added MY_EXTRA is reported as removed" grep -q 'removed: services.gluetun.environment.MY_EXTRA' "$OUT"
check "PUID edited in the YAML re-owns the config folders" test "$(owner "$C/jackett")" == 1000:568
check "every call matches the 25.10 API docs" no_schema_errors
clear_calls
TS_PGID=1000 run
if ((RC == 0)); then ok "TS_PGID=1000 re-run exits 0"; else bad "TS_PGID=1000 re-run exits 0 (rc=$RC)"; show_logs; fi
check "PGID change: summary warns that the downloads were not re-owned" grep -q 'PUID/PGID changed' "$OUT"
check "PGID change: app updated, filebrowser group_add follows" qtrue \
  "'app.update' in methods and st['apps']['torrent-stack']['config']['services']['filebrowser']['group_add']==['1000']"

# ---------------------------------------------------------------------------
echo "E: new qBittorrent password -> stop, reseed, update, start"
CURRENT=E
clear_calls
# What qBittorrent 5.3 does to the file on its first start (settings
# migration 11 in src/app/upgrade.cpp, checked with the real image in
# tests/runtime-images.sh): [Preferences] WebUI\X -> [WebUI] X, plus
# Meta\MigrationVersion.
python3 - "$QCONF" <<'PY'
import re, sys
p = sys.argv[1]
out, webui, sec = [], [], None
for line in open(p).read().splitlines():
    m = re.match(r"^\[([^\]]+)\]$", line)
    if m:
        sec = m.group(1)
    elif sec == "Preferences" and line.startswith("WebUI\\"):
        webui.append(line[len("WebUI\\"):])
        continue
    out.append(line)
out += ["", "[Meta]", "MigrationVersion=12", "", "[WebUI]"] + webui
open(p, "w").write("\n".join(out) + "\n")
PY
# qbit_pw_ok FILE PASSWORD: the [WebUI] Password_PBKDF2 hash (where 5.3 reads
# it) is that password, and [Preferences] has no WebUI\ keys left.
qbit_pw_ok() {
  python3 - "$1" "$2" <<'PY'
import base64, hashlib, re, sys
text, pw = open(sys.argv[1]).read(), sys.argv[2]
sec, found, stale = None, None, False
for line in text.splitlines():
    m = re.match(r"^\[([^\]]+)\]$", line)
    if m:
        sec = m.group(1)
    elif sec == "WebUI" and line.startswith("Password_PBKDF2="):
        found = line.split("=", 1)[1]
    elif sec == "Preferences" and line.startswith("WebUI\\"):
        stale = True
m = re.fullmatch(r'"@ByteArray\(([^:]+):([^)]+)\)"', found or "")
ok = bool(m) and not stale and hashlib.pbkdf2_hmac(
    "sha512", pw.encode(), base64.b64decode(m.group(1)), 100000) == base64.b64decode(m.group(2))
sys.exit(0 if ok else 1)
PY
}
check "simulated first start: [WebUI] holds the first password" qbit_pw_ok "$QCONF" "$QPW"
CONF_HASH=$(sha256sum "$QCONF")
printf '%s' 'n3w-Pass$word"x' >"$SECRET_DIR/qbit.pw"
chmod 600 "$SECRET_DIR/qbit.pw"
TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/qbit.pw" run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "order: app.stop, then app.update, then app.start" qtrue \
  "[m for m in methods if m in ('app.stop','app.update','app.start')] == ['app.stop','app.update','app.start']"
check "qBittorrent.conf re-seeded" bash -c "[[ '$(sha256sum "$C/qbittorrent/qBittorrent/qBittorrent.conf" 2>/dev/null)' != '$CONF_HASH' ]]"
check "the new password is in [WebUI], where qBittorrent 5.3 reads it" qbit_pw_ok "$QCONF" "$(cat "$SECRET_DIR/qbit.pw")"
# (The stored YAML has every $ doubled; see the next checks.)
check "FileBrowser's admin password follows the new qBittorrent password" qtrue \
  "st['apps']['torrent-stack']['config']['services']['filebrowser']['environment']['FILEBROWSER_ADMIN_PASSWORD']==open('$SECRET_DIR/qbit.pw').read().replace('\$', '\$\$')"
check "app RUNNING again, stop marker removed" bash -c \
  "[[ \$(q \"st['apps']['torrent-stack']['state']\") == RUNNING && ! -e '$C/.torrent-stack-stopped' ]]"
app_yaml >"$WORK/E.yaml"
check "a \$ in the password is written as \$\$ in the YAML" grep -q 'n3w-Pass\$\$word' "$WORK/E.yaml"
check "docker compose sees no unset variable in the YAML (\$word was not expanded)" bash -c \
  "! docker compose -p ix-test -f '$WORK/E.yaml' config -q 2>&1 | grep -q 'variable is not set'"
# Proof with a real container: the value the YAML gives a container's
# environment is the password exactly as typed.
TEST_IMAGE="${TS_TEST_IMAGE:-nginx:alpine}"
if docker image inspect "$TEST_IMAGE" >/dev/null 2>&1; then
  python3 - "$WORK/E.yaml" "$WORK/E-env.yaml" "$TEST_IMAGE" <<'PY'
import sys, yaml
src = yaml.safe_load(open(sys.argv[1]))
pw = src["services"]["gluetun"]["environment"]["QBITTORRENT_PASSWORD"]
yaml.safe_dump({"services": {"t": {"image": sys.argv[3], "network_mode": "none",
                                   "environment": {"P": pw}}}}, open(sys.argv[2], "w"))
PY
  GOT=$(docker compose -p tstest-env -f "$WORK/E-env.yaml" run --rm -T --entrypoint printenv t P 2>/dev/null || true)
  docker compose -p tstest-env -f "$WORK/E-env.yaml" down >/dev/null 2>&1 || true
  check "a container started from that YAML gets the password exactly as typed" test "$GOT" == "$(cat "$SECRET_DIR/qbit.pw")"
else
  echo "  (image $TEST_IMAGE not present locally: the container check is skipped)"
fi
check "the new password is not on any midclt command line" secret_not_in_argv 'n3w-Pass$word'
check "every call matches the 25.10 API docs" no_schema_errors

# ---------------------------------------------------------------------------
echo "F: --dry-run on the existing app changes nothing and masks secrets"
CURRENT=F
clear_calls
cp "$TN_SHIM_STATE/state.json" "$WORK/state.before.json"
TS_SERVER_COUNTRIES=Sweden run --dry-run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "no changing calls" qtrue "mutating == []"
check "state unchanged" cmp -s "$TN_SHIM_STATE/state.json" "$WORK/state.before.json"
check "payload printed with app.update shape" grep -q '"custom_compose_config_string"' "$OUT"
check "secrets masked" bash -c "grep -q REDACTED-WIREGUARD_PRIVATE_KEY '$OUT' && ! grep -qF '$WG_KEY' '$OUT' && ! grep -qF 'n3w-Pass' '$OUT'"

# ---------------------------------------------------------------------------
echo "G: --print-yaml prints the real YAML on stdout only"
CURRENT=G
clear_calls
run --print-yaml
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "stdout is YAML that passes docker compose config" compose_ok "$OUT"
check "stdout holds the real key (for Install via YAML)" grep -qF "$WG_KEY" "$OUT"
check "messages went to stderr" grep -q 'Keep it private' "$ERR"
check "no changing calls" qtrue "mutating == []"

# ---------------------------------------------------------------------------
echo "H: --uninstall (25.10 and 27.0 schemas)"
CURRENT=H
clear_calls
TN_SHIM_API=27.0 run --uninstall
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "app.delete with {remove_images: false}, valid for 27.0" qtrue \
  "[c['params'] for c in calls if c['method']=='app.delete'] == [['torrent-stack', {'remove_images': False}]] and not any('schema_error' in c for c in calls)"
check "app gone, datasets and configs kept" qtrue \
  "st['apps'] == {} and 'tank/torrent-stack/configs' in st['datasets']"
check "configs still on disk" test -f "$C/qbittorrent/qBittorrent/qBittorrent.conf"
check "says what was kept" grep -q 'Kept:' "$OUT"
clear_calls
run --uninstall
check "uninstall again: nothing to do, exit 0" bash -c "(( $RC == 0 )) && grep -q 'Nothing to do' '$OUT'"

# ---------------------------------------------------------------------------
echo "I: reinstall onto existing datasets; existing downloads dataset elsewhere; PUID 1000; OpenVPN"
CURRENT=I
clear_calls
state_set "st['datasets']['media/downloads'] = {'id':'media/downloads','name':'media/downloads','pool':'media','type':'FILESYSTEM','mountpoint':'/mnt/media/downloads','locked':False,'encrypted':False,'share_type':'SMB'}"
mkdir -p /mnt/media/downloads
chown 3000:3000 /mnt/media/downloads
printf '%s' 'openvpn-secret-pw' >"$SECRET_DIR/ovpn.pw"
chmod 600 "$SECRET_DIR/ovpn.pw"
# TrueNAS's Apps preset lets only root, the owner and uid 568 into the
# configs dataset; with PUID 1000 the seeding must not need to pass it.
chmod 0700 /mnt/tank/torrent-stack/configs
I_CONF_HASH=$(sha256sum "$QCONF")
TS_DOWNLOADS_DATASET=media/downloads TS_PUID=1000 TS_PGID=1000 \
  TS_VPN_TYPE=openvpn TS_VPN_PROVIDER='private internet access' TS_OPENVPN_USER=p1234567 \
  TS_OPENVPN_PASSWORD_FILE="$SECRET_DIR/ovpn.pw" TS_QBIT_WEBUI_PORT=8095 run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "every call matches the 25.10 API docs" no_schema_errors
check "only the missing downloads dataset is not created (it exists)" qtrue \
  "[c['params'][0]['name'] for c in calls if c['method']=='pool.dataset.create'] == []"
check "existing downloads dataset left alone (owner 3000, mode 755)" \
  test "$(owner /mnt/media/downloads) $(mode /mnt/media/downloads)" == "3000:3000 755"
check "warns that PUID cannot write to it" grep -q 'cannot write to /mnt/media/downloads' "$OUT"
check "warns that FileBrowser cannot write to it either, with the fix" \
  grep -q 'FileBrowser (user 1000, extra group 1000) cannot write to /mnt/media/downloads.*chmod g+rwxs /mnt/media/downloads' "$OUT"
check "YAML points downloads at /mnt/media/downloads" qtrue \
  "'/mnt/media/downloads:/downloads' in st['apps']['torrent-stack']['config']['services']['qbittorrent']['volumes']"
check "OpenVPN password not on any midclt command line" secret_not_in_argv 'openvpn-secret-pw'
check "VPN not gated (OpenVPN credentials given)" qtrue \
  "'profiles' not in st['apps']['torrent-stack']['config']['services']['gluetun']"
check "port 8095 published" qtrue "'8095:8095/tcp' in st['apps']['torrent-stack']['config']['services']['gluetun']['ports']"
check "configs dataset still 0700 root (as the Apps preset is for uid 1000)" test "$(mode /mnt/tank/torrent-stack/configs)" == 700
check "seeding as PUID 1000 worked although it cannot enter the configs dataset" test "$(sha256sum "$QCONF")" != "$I_CONF_HASH"
check "  ... no bind mount left behind" bash -c "! grep -q 'torrent-stack.seed' /proc/self/mountinfo"
check "FileBrowser config folder (database) owned by its fixed uid 1000" test "$(owner "$C/filebrowser")" == 1000:1000
check "seeded files written as the apps' user 1000 (qBittorrent.conf owner)" test "$(owner "$QCONF")" == 1000:1000

# ---------------------------------------------------------------------------
echo "J: refusals"
CURRENT=J
new_state
state_set "st['listening'].append(8081)"
run
check "port conflict stops before any change" bash -c "(( $RC != 0 )) && grep -q 'FILEBROWSER_PORT=8081 is already in use' '$ERR'"
check "  ... and nothing was created" qtrue "mutating == []"
new_state
clear_calls
state_set "st['other_app_ports'].append(9117)"
run
check "port used by another app is refused" bash -c "(( $RC != 0 )) && grep -q 'JACKETT_PORT=9117 is used by another app' '$ERR'"
new_state
TS_QBIT_WEBUI_PORT=8000 run
check "port 8000 (Gluetun's control server) is refused" bash -c "(( $RC != 0 )) && grep -q \"Gluetun's control server\" '$ERR'"
new_state TrueNAS-SCALE-24.04.2
run
check "TrueNAS 24.04 is refused" bash -c "(( $RC != 0 )) && grep -q 'too old' '$ERR'"
new_state TrueNAS-25.10.1 UNCONFIGURED
run
check "Apps not configured is refused with guidance" bash -c "(( $RC != 0 )) && grep -q 'Choose Pool' '$ERR'"
new_state
TS_DATASET='tank/ix-apps/x' run
check "a dataset inside ix-apps is refused" bash -c "(( $RC != 0 )) && grep -q 'Invalid parent dataset' '$ERR'"
new_state
TS_CONFIG_PATH=/mnt/tank/x run
check "TS_CONFIG_PATH is refused (paths come from datasets)" bash -c "(( $RC != 0 )) && grep -q 'not used here' '$ERR'"
new_state
state_set "st['fail_pull'] = ['qmcgaw/gluetun:latest']"
run
check "a failed image pull stops before app.create" bash -c "(( $RC != 0 )) && grep -q 'Could not pull qmcgaw/gluetun:latest' '$ERR'"
check "  ... and app.create was not called" qtrue "'app.create' not in methods"
new_state
state_set "st['apps']['plex'] = {'name':'plex','custom_app':True,'state':'RUNNING','config':{'services':{'plex':{'image':'plex'}}},'yaml':''}"
TS_APP_NAME=plex run
check "a custom app that is not this stack is not overwritten" bash -c "(( $RC != 0 )) && grep -q 'does not look like this stack' '$ERR'"
new_state
run --update
check "--update without an app is refused" bash -c "(( $RC != 0 )) && grep -q 'no app named' '$ERR'"
new_state
RC=0
setpriv --reuid=65534 --regid=65534 --clear-groups env PATH="$PATH" PYTHONPATH="$PYTHONPATH" \
  TN_SHIM_STATE="$TN_SHIM_STATE" TS_UNATTENDED=1 bash "$INSTALLER" >"$OUT" 2>"$ERR" </dev/null || RC=$?
check "non-root is refused" bash -c "(( $RC != 0 )) && grep -q 'Run this as root' '$ERR'"
check "the helper refuses a payload file other users can read" bash -c \
  "f=\$(mktemp); chmod 644 \$f; echo '[]' >\$f; ! python3 '$PLATFORM_DIR/truenas_app.py' call app.query --params \$f 2>&1 | grep -q never; python3 '$PLATFORM_DIR/truenas_app.py' call app.query --params \$f 2>&1 | grep -q 'must not be readable'; rc=\$?; rm -f \$f; exit \$rc"

# ---------------------------------------------------------------------------
echo "K: wizard with plain prompts (no whiptail), app named 'true', TrueNAS 27.0"
CURRENT=K
new_state TrueNAS-27.0.0
# Answers, one per line: app name, pool (2 = media), parent dataset, downloads
# dataset, PUID, PGID, enter VPN now, provider (1 = protonvpn), protocol (1),
# WireGuard key, address, countries, change ports (n), qBit user, qBit
# password (empty = generated), Discord webhook (empty), final confirm.
printf '%s\n' "" true 2 "" "" "" "" y 1 1 "$WG_KEY" 10.2.0.2/32 Germany n qbadmin "" "" y >"$WORK/answers.txt"
RC=0
TN_SHIM_API=27.0 TS_INTERACTIVE=1 TS_UI=plain bash "$INSTALLER" >"$OUT" 2>"$ERR" <"$WORK/answers.txt" || RC=$?
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "warns that it was written against 25.10" grep -q 'written against the TrueNAS 25.10 API' "$OUT"
check "app 'true' created (name sent as a string)" qtrue "'true' in st['apps'] and first('app.create')['params'][0]['app_name']=='true'"
check "datasets on the chosen pool media" qtrue \
  "[c['params'][0]['name'] for c in calls if c['method']=='pool.dataset.create'] == ['media/torrent-stack','media/torrent-stack/configs','media/torrent-stack/downloads']"
check "wizard answers in the YAML (user, key, countries)" qtrue \
  "(lambda e: e['QBITTORRENT_USER']=='qbadmin' and e['WIREGUARD_PRIVATE_KEY']=='$WG_KEY' and e['SERVER_COUNTRIES']=='Germany')(st['apps']['true']['config']['services']['gluetun']['environment'])"
check "every call matches the 27.0 API docs" no_schema_errors
clear_calls
TN_SHIM_API=27.0 TS_UNATTENDED=1 TS_APP_NAME=true run --update
check "update of app 'true': app.config got the name as a string" qtrue \
  "first('app.config')['params'] == ['true'] and not any('schema_error' in c for c in calls)"

# ---------------------------------------------------------------------------
echo "L: wizard through whiptail (stand-in): answers are captured, password box has no initial text"
CURRENT=L
new_state
RC=0
WT_APP_NAME=wt-stack WT_VPN_SETTINGS_1=no WT_PORTS=yes WT_QBITTORRENT_WEB_UI_PORT=8099 \
  WT_QBITTORRENT_PASSWORD='wt-pass-123' WT_READY=yes \
  TS_INTERACTIVE=1 TS_UI=whiptail bash "$INSTALLER" >"$OUT" 2>"$ERR" </dev/null || RC=$?
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "app wt-stack created, gated (VPN skipped)" qtrue \
  "'wt-stack' in st['apps'] and st['apps']['wt-stack']['config']['services']['gluetun']['profiles']==['vpn-not-configured']"
check "qBittorrent port and password from the wizard" qtrue \
  "(lambda s: '8099:8099/tcp' in s['gluetun']['ports'] and s['gluetun']['environment']['QBITTORRENT_PASSWORD']=='wt-pass-123')(st['apps']['wt-stack']['config']['services'])"
check "typed password is not printed" bash -c "! grep -q 'wt-pass-123' '$OUT' '$ERR' '$TN_SHIM_STATE/whiptail.log'"
check "every call matches the 25.10 API docs" no_schema_errors
check "work folder in /dev/shm removed after all runs" shm_clean

# ---------------------------------------------------------------------------
echo "M: the repository copy's folder is only replaced when the installer made it"
CURRENT=M
add_dataset() { # name mountpoint
  state_set "st['datasets']['$1'] = {'id':'$1','name':'$1','pool':'${1%%/*}','type':'FILESYSTEM','mountpoint':'$2','locked':False,'encrypted':False,'share_type':'GENERIC'}"
  mkdir -p "$2"
}
gluetun_script_mount() { # host-path: edit the update-qbittorrent.sh mount in the stored YAML
  state_set "v = st['apps']['torrent-stack']['config']['services']['gluetun']['volumes']; i = [k for k, x in enumerate(v) if x.endswith(':/gluetun/update-qbittorrent.sh:ro')][0]; v[i] = '$1:/gluetun/update-qbittorrent.sh:ro'"
}
new_state
add_dataset tank/projects /mnt/tank/projects
mkdir -p /mnt/tank/projects/source/myapp
echo 'int main(void) { return 0; }' >/mnt/tank/projects/source/myapp/main.c
TS_DATASET=tank/projects run --dry-run
check "dry run: a 'source' folder holding someone else's files is refused" bash -c \
  "(( $RC != 0 )) && grep -q 'already holds files that this installer did not put there' '$ERR'"
clear_calls
TS_DATASET=tank/projects run
check "install: refused, with the reason" bash -c "(( $RC != 0 )) && grep -q 'Not using /mnt/tank/projects/source' '$ERR'"
check "  ... before any dataset, permission or app call" qtrue "mutating == []"
check "  ... and the file is still there" test -f /mnt/tank/projects/source/myapp/main.c

new_state
run
if ((RC == 0)); then ok "normal install for the next checks"; else bad "normal install (rc=$RC)"; show_logs; fi
mkdir -p /mnt/media/family/photos /mnt/media/family/docs
echo img >/mnt/media/family/photos/img1.jpg
echo tax >/mnt/media/family/docs/tax.pdf
chown -R 3000:3000 /mnt/media/family
gluetun_script_mount /mnt/media/family/update-qbittorrent.sh
clear_calls
run --update
if ((RC == 0)); then ok "update with the script mount edited to another folder exits 0"; else bad "update exits 0 (rc=$RC)"; show_logs; fi
check "  ... warns that the edited mount is not the installer's copy" grep -q 'which is not this installer' "$OUT"
check "  ... that folder is untouched (files and owner)" bash -c \
  "[[ -f /mnt/media/family/photos/img1.jpg && -f /mnt/media/family/docs/tax.pdf && \$(stat -c %u:%g /mnt/media/family) == 3000:3000 ]]"
check "  ... no permission call outside the stack's folders" qtrue \
  "not any(p['path'].startswith('/mnt/media') for p in st.get('perm_calls', []))"
check "  ... the mount points at the installer's copy again" qtrue \
  "'/mnt/tank/torrent-stack/source/update-qbittorrent.sh:/gluetun/update-qbittorrent.sh:ro' in st['apps']['torrent-stack']['config']['services']['gluetun']['volumes']"
gluetun_script_mount /mnt/media/update-qbittorrent.sh
clear_calls
run --update
check "script mount edited to a pool's top folder: /mnt/media left alone" bash -c \
  "(( $RC == 0 )) && [[ -f /mnt/media/family/photos/img1.jpg ]]"
check "  ... no permission call on /mnt/media" qtrue \
  "not any(p['path'].startswith('/mnt/media') for p in st.get('perm_calls', []))"
check "dry run on the installer's own copy says it replaces its contents" bash -c \
  "TS_UNATTENDED=1 bash '$INSTALLER' --dry-run </dev/null 2>&1 | grep -q 'replace the contents of /mnt/tank/torrent-stack/source'"

# Another dataset mounted inside the copy (here a tmpfs) is not entered.
mkdir -p /mnt/tank/torrent-stack/source/extra
mount -t tmpfs -o mode=0755 tmpfs /mnt/tank/torrent-stack/source/extra
echo keep >/mnt/tank/torrent-stack/source/extra/keep.txt
chmod 0666 /mnt/tank/torrent-stack/source/extra/keep.txt
clear_calls
run --update
echo "  (update with a file system mounted inside the copy: exit $RC)"
check "a file system mounted inside the copy is not emptied (rsync --one-file-system)" \
  test -f /mnt/tank/torrent-stack/source/extra/keep.txt
check "  ... nor its files' modes changed (find -xdev)" test "$(mode /mnt/tank/torrent-stack/source/extra/keep.txt)" == 666
umount /mnt/tank/torrent-stack/source/extra
rmdir /mnt/tank/torrent-stack/source/extra 2>/dev/null || true

clear_calls
TS_APP_NAME=second TS_QBIT_WEBUI_PORT=8190 TS_JACKETT_PORT=9118 TS_FLARESOLVERR_PORT=8192 TS_FILEBROWSER_PORT=8082 run
check "a second app on the same parent dataset is refused (the copy belongs to a live app)" bash -c \
  "(( $RC != 0 )) && grep -q 'repository copy of the app torrent-stack, which still exists' '$ERR'"
check "  ... before any change" qtrue "mutating == []"

new_state
add_dataset tank/shared /mnt/tank/shared
chmod 0777 /mnt/tank/shared
TS_DATASET=tank/shared run
check "a parent dataset the apps user can write to is refused" bash -c \
  "(( $RC != 0 )) && grep -q 'can be written to by 568:568' '$ERR'"
check "  ... before any change" qtrue "mutating == []"

H="$PLATFORM_DIR/truenas_app.py"
check "source-check refuses a pool's top folder" bash -c \
  "! python3 '$H' source-check --source-dir /mnt/tank --allowed-root /mnt/tank 2>/dev/null"
check "source-check refuses a folder that holds the configs" bash -c \
  "! python3 '$H' source-check --source-dir /mnt/tank/shared --allowed-root /mnt/tank --protect /mnt/tank/shared/configs 2>/dev/null"
ln -s /etc /mnt/tank/linkdir
check "source-check refuses a path through a symbolic link" bash -c \
  "! python3 '$H' source-check --source-dir /mnt/tank/linkdir/source --allowed-root /mnt/tank 2>/dev/null"
check "source-check accepts a new folder in a pool" bash -c \
  "python3 '$H' source-check --source-dir /mnt/tank/new/source --allowed-root /mnt/tank | grep -qx STATE=new"

# ---------------------------------------------------------------------------
echo "N: Jackett/FlareSolverr ports: only the host side moves (compose.yaml publishes PORT:9117 and PORT:8191)"
CURRENT=N
new_state
TS_JACKETT_PORT=9118 TS_FLARESOLVERR_PORT=8192 run
if ((RC == 0)); then ok "installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "published as 9118:9117 and 8192:8191" qtrue \
  "(lambda p: '9118:9117/tcp' in p and '8192:8191/tcp' in p)(st['apps']['torrent-stack']['config']['services']['gluetun']['ports'])"
check "YAML passes docker compose config" bash -c "q \"st['apps']['torrent-stack']['yaml']\" >'$WORK/N.yaml' && docker compose -p ix-test -f '$WORK/N.yaml' config -q"
check "search plugin still talks to Jackett at 127.0.0.1:9117" python3 -c \
  "import json,sys; sys.exit(0 if json.load(open('$C/qbittorrent/qBittorrent/nova3/engines/jackett.json'))['url']=='http://127.0.0.1:9117' else 1)"
check "Jackett keeps Port 9117 and FlareSolverr at 127.0.0.1:8191" python3 -c \
  "import json,sys; d=json.load(open('$C/jackett/Jackett/ServerConfig.json')); sys.exit(0 if d['Port']==9117 and d['FlareSolverrUrl']=='http://127.0.0.1:8191' else 1)"
check "summary shows the host ports" bash -c "grep -q 'Jackett:.*:9118' '$OUT' && grep -q 'FlareSolverr:.*:8192' '$OUT'"
clear_calls
run
check "re-run reads 9118/8192 back from the YAML: nothing to change" bash -c \
  "(( $RC == 0 )) && grep -q 'already up to date' '$OUT'"
check "  ... no app.update" qtrue "'app.update' not in methods"
new_state
TS_QBIT_WEBUI_PORT=9117 TS_JACKETT_PORT=9118 run
check "qBittorrent on 9117 (Jackett's port inside the VPN container) is refused" bash -c \
  "(( $RC != 0 )) && grep -q 'QBIT_WEBUI_PORT=9117 is taken by Jackett' '$ERR'"

# ---------------------------------------------------------------------------
echo "O: ':' in a dataset name or path is refused before anything is created"
CURRENT=O
new_state
TS_DATASET='tank/my:data' run
check "TS_DATASET=tank/my:data is refused" bash -c "(( $RC != 0 )) && grep -q 'Invalid parent dataset' '$ERR'"
check "  ... before any change, no stray folder" bash -c "[[ \$(q 'mutating') == '[]' && ! -e /mnt/tank/my ]]"
OD="$WORK/O"
mkdir -p "$OD"
chmod 700 "$OD"
printf '%s\0' CONFIG_PATH=/mnt/tank/c DOWNLOADS_PATH=/mnt/tank/a:b INCOMPLETE_DOWNLOADS=/mnt/tank/a:b/incomplete \
  QBITTORRENT_USER=admin QBITTORRENT_PASSWORD=secret-123 PUID=568 PGID=568 >"$OD/layer"
chmod 600 "$OD/layer"
python3 "$H" merge --repo "$REPO_DIR" --layer "$OD/layer" --out "$OD/values.json" --need-paths >/dev/null 2>&1 || true
check "render refuses a host path with ':' (as read back from an edited YAML)" bash -c \
  "! python3 '$H' render --repo '$REPO_DIR' --values '$OD/values.json' --app-name x --source-dir /mnt/tank/s --allowed-root /mnt/tank --out-yaml '$OD/y' 2>'$OD/err' && grep -q \"DOWNLOADS_PATH must not contain ':'\" '$OD/err'"
# A compose.yaml whose FileBrowser database is not in a mounted folder (the
# image's own default): every TrueNAS update would empty it, so no YAML.
printf '%s\0' CONFIG_PATH=/mnt/tank/c DOWNLOADS_PATH=/mnt/tank/d INCOMPLETE_DOWNLOADS=/mnt/tank/d/incomplete \
  QBITTORRENT_USER=admin QBITTORRENT_PASSWORD=secret-123 PUID=568 PGID=568 >"$OD/layer2"
chmod 600 "$OD/layer2"
python3 "$H" merge --repo "$REPO_DIR" --layer "$OD/layer2" --out "$OD/values2.json" --need-paths >/dev/null 2>&1 || true
mkdir -p "$OD/repo"
rsync -a --exclude=.git --exclude=/configs --exclude=/downloads "$REPO_DIR/" "$OD/repo/"
sed -i 's|FILEBROWSER_DATABASE_PATH: /config/database.sqlite|FILEBROWSER_DATABASE_PATH: /home/filebrowser/data/database.sqlite|' "$OD/repo/compose.yaml"
check "render refuses a compose.yaml that keeps FileBrowser's database outside the configs dataset" bash -c \
  "grep -q 'FILEBROWSER_DATABASE_PATH: /home/filebrowser' '$OD/repo/compose.yaml' && ! python3 '$H' render --repo '$OD/repo' --values '$OD/values2.json' --app-name x --source-dir /mnt/tank/s --allowed-root /mnt/tank --out-yaml '$OD/y2' 2>'$OD/err2' && grep -q 'would lose its users' '$OD/err2'"
check "  ... and renders the repository's own compose.yaml with the same settings" \
  python3 "$H" render --repo "$REPO_DIR" --values "$OD/values2.json" --app-name x --source-dir /mnt/tank/s --allowed-root /mnt/tank --out-yaml "$OD/y3"

# ---------------------------------------------------------------------------
echo "P: PUID/PGID with leading zeros"
CURRENT=P
new_state
TS_PUID=01000 TS_PGID=01000 run
if ((RC == 0)); then ok "TS_PUID=01000 TS_PGID=01000: installer exits 0"; else bad "installer exits 0 (rc=$RC)"; show_logs; fi
check "stored as 1000 in the YAML" qtrue \
  "st['apps']['torrent-stack']['config']['services']['qbittorrent']['environment']['PUID']=='1000'"
check "filesystem.chown got the number 1000" qtrue \
  "all(c['params'][0]['uid'] in (1000,) for c in calls if c['method']=='filesystem.chown' and not c['params'][0]['path'].endswith('/filebrowser'))"
check "downloads dataset owned by 1000:1000" test "$(owner /mnt/tank/torrent-stack/downloads)" == 1000:1000
check "every call matches the 25.10 API docs" no_schema_errors

# ---------------------------------------------------------------------------
echo "Q: recovery after a failed start"
CURRENT=Q
new_state
run
if ((RC == 0)); then ok "normal install for the next checks"; else bad "normal install (rc=$RC)"; show_logs; fi
state_set "st['fail_up'] = True"
clear_calls
TS_SERVER_COUNTRIES=Sweden run
check "failed app.update: exits non-zero and says the app is CRASHED" bash -c \
  "(( $RC != 0 )) && grep -q 'The app is CRASHED now' '$ERR'"
check "  ... and does not claim nothing is half-done" bash -c "! grep -q 'half-done in' '$ERR'"
state_set "st['fail_up'] = False"
clear_calls
TS_SERVER_COUNTRIES=Sweden run
check "same command again: YAML already saved, the crashed app is started" bash -c \
  "(( $RC == 0 )) && grep -q 'already up to date' '$OUT' && grep -q 'State:.*RUNNING' '$OUT'"
check "  ... with app.start and no second app.update" qtrue \
  "'app.start' in methods and 'app.update' not in methods and st['apps']['torrent-stack']['state']=='RUNNING'"
printf '%s' 'recovery-Pw-123' >"$SECRET_DIR/qbit2.pw"
chmod 600 "$SECRET_DIR/qbit2.pw"
state_set "st['fail_up'] = True"
clear_calls
TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/qbit2.pw" run
check "re-seed where app.start fails: exits non-zero, stop marker left" bash -c \
  "(( $RC != 0 )) && [[ -e /mnt/tank/torrent-stack/configs/.torrent-stack-stopped ]]"
check "  ... after app.stop and app.update" qtrue \
  "[m for m in methods if m in ('app.stop','app.update','app.start')] == ['app.stop','app.update','app.start']"
state_set "st['fail_up'] = False"
clear_calls
TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/qbit2.pw" run
check "same command again: starts the app the installer stopped" bash -c \
  "(( $RC == 0 )) && grep -q 'an earlier run of this installer stopped it' '$OUT'"
check "  ... RUNNING, marker removed, no second app.update" bash -c \
  "[[ \$(q \"st['apps']['torrent-stack']['state']\") == RUNNING && ! -e /mnt/tank/torrent-stack/configs/.torrent-stack-stopped && \$(q \"'app.update' in methods\") == false ]]"
printf 'x\n' >/mnt/tank/torrent-stack/configs/.torrent-stack-stopped
clear_calls
run
check "stop marker left but the app was started by hand since: marker dropped, no app.start" bash -c \
  "(( $RC == 0 )) && [[ ! -e /mnt/tank/torrent-stack/configs/.torrent-stack-stopped && \$(q \"'app.start' in methods\") == false ]]"
state_set "st['apps']['torrent-stack']['state'] = 'STOPPED'"
clear_calls
run
check "an app the user stopped stays stopped (unattended); the summary says so" bash -c \
  "(( $RC == 0 )) && grep -q 'The app is STOPPED, not running' '$OUT' && [[ \$(q \"'app.start' in methods\") == false ]]"

# ---------------------------------------------------------------------------
echo "R: config files are written as the apps' user, not root"
CURRENT=R
new_state
run
if ((RC == 0)); then ok "normal install for the next check"; else bad "normal install (rc=$RC)"; show_logs; fi
echo precious >/mnt/tank/victim
chmod 0644 /mnt/tank/victim
rm -f "$QCONF"
ln -s /mnt/tank/victim "$QCONF"
printf '%s' 'another-Pw-123' >"$SECRET_DIR/qbit3.pw"
chmod 600 "$SECRET_DIR/qbit3.pw"
TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/qbit3.pw" run
echo "  (re-seed through a planted link: exit $RC)"
check "a link left in a config folder cannot make the installer change a root-owned file" \
  test "$(cat /mnt/tank/victim)" == precious
check "  ... nor its owner" test "$(owner /mnt/tank/victim)" == 0:0

# ---------------------------------------------------------------------------
echo "S: the qBittorrent password is also FileBrowser's admin password: not 'admin', 6 characters, 72 bytes"
CURRENT=S
# Letters of 2, 3 and 4 bytes in UTF-8 (e-acute, the euro sign, U+1F600),
# written as bytes so that this file stays ASCII.
B2=$'\xc3\xa9' B3=$'\xe2\x82\xac' B4=$'\xf0\x9f\x98\x80'
rep() { # STRING N: STRING N times
  local s="" i
  for ((i = 0; i < $2; i++)); do s+=$1; done
  printf '%s' "$s"
}
PW72=$(rep "$B2" 36) # 36 letters, 72 bytes
PW73="${PW72}a"      # 37 letters, 73 bytes
# The wizard's check: truenas_app.py password-check, the password on stdin.
pw_accepted() { printf '%s' "$1" | python3 "$PLATFORM_DIR/truenas_app.py" password-check; }
pw_refused() { # PASSWORD TEXT: refused, and the reason says TEXT
  local why
  why=$(printf '%s' "$1" | python3 "$PLATFORM_DIR/truenas_app.py" password-check) && return 1
  [[ "$why" == *"$2"* ]]
}
check "password check: 'admin' is refused (FileBrowser ignores it)" pw_refused admin "cannot be 'admin'"
check "password check: 5 characters are refused" pw_refused abcde "must be at least 6 characters"
check "password check: 6 characters are accepted" pw_accepted abcdef
check "password check: 72 ASCII letters are accepted" pw_accepted "$(rep a 72)"
check "password check: 73 ASCII letters are refused" pw_refused "$(rep a 73)" "is 73 bytes long"
check "password check: 36 two-byte letters (72 bytes) are accepted" pw_accepted "$PW72"
check "password check: 37 letters of 73 bytes are refused (bytes count, not letters)" pw_refused "$PW73" "is 73 bytes long"
check "password check: 24 three-byte letters (72 bytes) are accepted" pw_accepted "$(rep "$B3" 24)"
check "password check: 25 three-byte letters (75 bytes) are refused" pw_refused "$(rep "$B3" 25)" "is 75 bytes long"
check "password check: 18 four-byte letters (72 bytes) are accepted" pw_accepted "$(rep "$B4" 18)"
check "password check: 18 four-byte letters and 'a' (73 bytes) are refused" pw_refused "$(rep "$B4" 18)a" "is 73 bytes long"

# refused_saying TEXT: the last run failed and its stderr says TEXT.
refused_saying() { ((RC != 0)) && grep -qF -- "$1" "$ERR"; }
# qbit_hash_is PASSWORD: every PBKDF2 hash in qBittorrent.conf ([Preferences]
# or [WebUI]) is PASSWORD's (its bytes, whatever the locale).
qbit_hash_is() {
  python3 - "$QCONF" "$1" <<'PY'
import base64, hashlib, os, re, sys
found = re.findall(r'Password_PBKDF2="@ByteArray\(([^:]+):([^)]+)\)"', open(sys.argv[1]).read())
pw = os.fsencode(sys.argv[2])
sys.exit(0 if found and all(hashlib.pbkdf2_hmac("sha512", pw, base64.b64decode(s), 100000)
                            == base64.b64decode(h) for s, h in found) else 1)
PY
}
app_pw_is() { # PYTHON-EXPR: both copies of the password in the app's YAML equal it
  qtrue "(lambda s: s['gluetun']['environment']['QBITTORRENT_PASSWORD'] == s['filebrowser']['environment']['FILEBROWSER_ADMIN_PASSWORD'] == $1)(st['apps']['torrent-stack']['config']['services'])"
}
yaml_pw_set() { # PYTHON-EXPR: edit the password in the app's YAML, as in the web UI
  state_set "st['apps']['torrent-stack']['config']['services']['gluetun']['environment']['QBITTORRENT_PASSWORD'] = $1"
}
install_refused() { # DESCRIPTION PASSWORD TEXT
  printf '%s' "$2" >"$SECRET_DIR/s.pw"
  chmod 600 "$SECRET_DIR/s.pw"
  clear_calls
  TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/s.pw" run
  check "unattended install: $1 refused" refused_saying "$3"
  check "  ... before any dataset, permission or app call" qtrue "mutating == []"
}
new_state
install_refused "'admin' is" admin "QBITTORRENT_PASSWORD cannot be 'admin'"
install_refused "5 characters are" abcde "QBITTORRENT_PASSWORD must be at least 6 characters"
install_refused "37 letters of 73 bytes are" "$PW73" "QBITTORRENT_PASSWORD is 73 bytes long; at most 72 work"
install_refused "25 three-byte letters (75 bytes) are" "$(rep "$B3" 25)" "QBITTORRENT_PASSWORD is 75 bytes long"
printf '%s' "$PW72" >"$SECRET_DIR/s.pw"
TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/s.pw" run
if ((RC == 0)); then ok "unattended install: 36 two-byte letters (72 bytes) are accepted"; else bad "unattended install: 72 bytes accepted (rc=$RC)"; show_logs; fi
check "  ... and are both copies of the password in the app's YAML, exactly" app_pw_is "'\u00e9' * 36"
check "  ... and qBittorrent's seeded hash" qbit_hash_is "$PW72"
check "  ... and are on no midclt command line" secret_not_in_argv "$PW72"

yaml_pw_set "'\u00e9' * 36 + 'a'"
clear_calls
run --update
check "--update: 73 bytes edited into the app's YAML are refused" refused_saying "QBITTORRENT_PASSWORD is 73 bytes long"
check "  ... before anything is stopped or changed" qtrue "mutating == []"
yaml_pw_set "'admin'"
clear_calls
run --update
check "--update: 'admin' edited into the app's YAML is refused" refused_saying "QBITTORRENT_PASSWORD cannot be 'admin'"
check "  ... before anything is stopped or changed" qtrue "mutating == []"
run --print-yaml
check "--print-yaml: refused the same way" refused_saying "QBITTORRENT_PASSWORD cannot be 'admin'"
check "  ... and prints no YAML" bash -c "! grep -q 'services:' '$OUT'"
printf '%s' 'fixed-Pass-1' >"$SECRET_DIR/s.pw"
clear_calls
TS_QBITTORRENT_PASSWORD_FILE="$SECRET_DIR/s.pw" run
if ((RC == 0)); then ok "a password from TS_QBITTORRENT_PASSWORD_FILE replaces the refused one"; else bad "a password from TS_QBITTORRENT_PASSWORD_FILE replaces the refused one (rc=$RC)"; show_logs; fi
check "  ... in both places in the YAML" app_pw_is "'fixed-Pass-1'"
check "  ... and in qBittorrent's hash (re-seeded)" qbit_hash_is fixed-Pass-1

# The wizard asks again until the password works.
new_state
# Answers: continue, app name, pool, parent and downloads datasets, PUID,
# PGID, VPN now (n), ports (n), qBit user, four passwords, webhook, confirm.
printf '%s\n' "" "" "" "" "" "" "" n n qbadmin admin "$PW73" abcde 'wiz-Pass-1' "" y >"$WORK/answers-pw.txt"
RC=0
TS_INTERACTIVE=1 TS_UI=plain bash "$INSTALLER" >"$OUT" 2>"$ERR" <"$WORK/answers-pw.txt" || RC=$?
if ((RC == 0)); then ok "wizard (plain prompts): installer exits 0"; else bad "wizard (plain prompts): installer exits 0 (rc=$RC)"; show_logs; fi
check "  ... 'admin' is refused, and the password asked again" grep -qF "The password cannot be 'admin'" "$ERR"
check "  ... 37 letters of 73 bytes are refused, and asked again" grep -qF "The password is 73 bytes long" "$ERR"
check "  ... 5 characters are refused, and asked again" grep -qF "The password must be at least 6 characters" "$ERR"
check "  ... the fourth answer is the app's password" app_pw_is "'wiz-Pass-1'"
check "  ... no typed password is printed" bash -c "! grep -qF -e 'wiz-Pass-1' -e '$PW73' '$OUT' '$ERR'"
new_state
RC=0
WT_VPN_SETTINGS_1=no WT_QBITTORRENT_PASSWORD_1="$PW73" WT_QBITTORRENT_PASSWORD_2=admin \
  WT_QBITTORRENT_PASSWORD_3="$PW72" WT_READY=yes \
  TS_INTERACTIVE=1 TS_UI=whiptail bash "$INSTALLER" >"$OUT" 2>"$ERR" </dev/null || RC=$?
if ((RC == 0)); then ok "wizard (whiptail): installer exits 0"; else bad "wizard (whiptail): installer exits 0 (rc=$RC)"; show_logs; fi
wt_count() { grep -c "^$1"$'\t'"$2"$'\t' "$TN_SHIM_STATE/whiptail.log"; } # BOX TITLE
check "  ... two 'Password not accepted' notes" test "$(wt_count msgbox 'Password not accepted')" == 2
check "  ... three password boxes" test "$(wt_count passwordbox 'qBittorrent password')" == 3
check "  ... the third answer (72 bytes) is the app's password" app_pw_is "'\u00e9' * 36"
check "every call matches the 25.10 API docs" no_schema_errors
check "work folders in /dev/shm removed after all runs" shm_clean

echo
echo "Passed: $PASS  Failed: $FAIL"
if ((FAIL)); then
  printf '  - %s\n' "${FAILED[@]}"
  exit 1
fi
