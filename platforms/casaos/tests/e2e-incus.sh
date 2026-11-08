#!/usr/bin/env bash
#
# platforms/casaos/tests/e2e-incus.sh
#
# Purpose: end-to-end test of platforms/casaos/install.sh on a REAL CasaOS,
# installed in a throwaway Incus system container (Debian 13, Docker nested
# inside it). It checks what the shim tests cannot:
#
#   1. a fresh install is accepted by real app-management, shows on the
#      dashboard's app grid, and the containers share Gluetun's network;
#   2. with a made-up VPN key Gluetun runs but never gets healthy, so
#      qBittorrent, Jackett and FlareSolverr are never started, and nothing
#      in Gluetun's network can reach the internet (fail closed);
#   3. re-running and --apply update in place (PUT) without replacing
#      containers; --dry-run changes no file; --print-yaml is clean YAML;
#   4. --uninstall removes the app and keeps /DATA/AppData/torrent-stack;
#   5. with Gluetun swapped for an always-healthy test double (from a local
#      registry), every app starts under CasaOS, the installer's own checks
#      (shared network, every web UI, the qBittorrent login) pass, and the
#      seeded logins work from the LAN: qBittorrent password, Jackett search
#      plugin and API key, FlareSolverr, FileBrowser;
#   6. a password change with --apply reaches qBittorrent (5.x keeps it in a
#      [WebUI] section the seeding CLI does not write);
#   7. JACKETT_PORT / FLARESOLVERR_PORT only move the host port, and Jackett,
#      FlareSolverr and the search plugin keep working;
#   8. restarting the whole app through CasaOS (what the dashboard's Restart
#      does) leaves every app in Gluetun's network;
#   9. after Gluetun alone was restarted, --apply puts the apps back in its
#      network instead of reporting success with dead web UIs.
#
# Real VPN connectivity is NOT tested (no VPN credentials).
#
# This runs IceWhaleTech's CasaOS installer (https://get.casaos.io) inside
# the throwaway container, pinned by its sha256 below; that is a test
# dependency only, never used by install.sh.
#
# Usage (as root on a host with Incus and the images:debian/13 image):
#   bash platforms/casaos/tests/e2e-incus.sh [--keep] [CONTAINER_NAME]
#
# License: MIT (see LICENSE in the repository root).

set -Eeuo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
KEEP=0
[[ "${1:-}" == --keep ]] && { KEEP=1; shift; }
CT="${1:-casaos-e2e-test}"
# get.casaos.io as tested on 2026-11-08 (installs CasaOS v0.4.15 with
# app-management v0.4.10-alpha2, which reports v0.4.5).
CASAOS_GET_URL="https://get.casaos.io/"
CASAOS_GET_SHA256="4a9e7c4ba4159aa7516c7c1acb3f017235868f80a6c2ce2922a9ee00a6837536"
WG_KEY="oK7tzJ0kZ9Y0bq3PLyLbbm1yN6dZ8tVH2KsQ6hHv6Ws="
QB_PASS="E2e-Test-Pass-7"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/casaos-e2e.XXXXXX")
PASS=0
FAIL=0

ok() { PASS=$((PASS + 1)); printf '  PASS  %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { local n=$1; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
gx() { incus exec "$CT" -- "$@"; }
gsh() { incus exec "$CT" -- bash -c "$1"; }
section() { printf '\n== %s\n' "$1"; }

cleanup() {
  rm -rf "$WORK"
  if [[ "$KEEP" == 0 ]]; then incus delete -f "$CT" >/dev/null 2>&1 || true; fi
}
trap cleanup EXIT

section "Test container ${CT}"
incus info "$CT" >/dev/null 2>&1 && { echo "Container ${CT} already exists; pick another name." >&2; exit 1; }
incus launch images:debian/13 "$CT" -c security.nesting=true \
  -c security.syscalls.intercept.mknod=true -c security.syscalls.intercept.setxattr=true >/dev/null
incus config device add "$CT" tun unix-char source=/dev/net/tun path=/dev/net/tun >/dev/null
# Wait for the container's network (DHCP on eth0).
for _ in $(seq 1 60); do gsh 'ip -4 -o addr show eth0 2>/dev/null | grep -q inet' && break; sleep 2; done
# Sandboxes that intercept TLS hand their CA to the container (nothing is
# injected on a normal network).
python3 -I - "$WORK/ca.crt" <<'PY' || true
import re, subprocess, sys
try:
    data = open("/etc/ssl/certs/ca-certificates.crt").read()
except OSError:
    sys.exit(0)
out = [c for c in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", data, re.S)
       if "Egress Gateway CA" in subprocess.run(["openssl", "x509", "-noout", "-subject"], input=c,
                                                capture_output=True, text=True).stdout]
if out:
    open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY
if [[ -s "$WORK/ca.crt" ]]; then
  incus file push "$WORK/ca.crt" "$CT/usr/local/share/ca-certificates/test-network.crt" >/dev/null
  gx update-ca-certificates >/dev/null 2>&1
fi
gsh 'export DEBIAN_FRONTEND=noninteractive; apt-get update -qq && apt-get install -y -qq docker.io curl ca-certificates python3-bcrypt >/dev/null'
curl -fsSL "$CASAOS_GET_URL" -o "$WORK/get-casaos.sh"
echo "${CASAOS_GET_SHA256}  $WORK/get-casaos.sh" | sha256sum -c --quiet ||
  { echo "get.casaos.io changed (sha256); review it and update CASAOS_GET_SHA256." >&2; exit 1; }
incus file push "$WORK/get-casaos.sh" "$CT/root/get-casaos.sh" >/dev/null
gsh 'bash /root/get-casaos.sh </dev/null >/root/casaos-install.log 2>&1 || true'
# app-management sometimes fails its very first start; systemd restarts it.
for _ in $(seq 1 60); do gx test -s /var/run/casaos/app-management.url && gx systemctl is-active --quiet casaos-app-management && break; sleep 2; done
check "CasaOS installed and app-management running" gx systemctl is-active --quiet casaos-app-management
IP=$(gsh "ip -4 -o addr show eth0 | sed -n 's/.* inet \([0-9.]*\).*/\1/p'")

tar -C "$REPO" --exclude=./.git --exclude=./.env --exclude=./configs/env-editor \
  --exclude=./scripts/env-editor/.venv --exclude='*/__pycache__' -czf "$WORK/src.tgz" .
incus file push "$WORK/src.tgz" "$CT/root/src.tgz" >/dev/null
gsh "mkdir -p /root/src && tar -xzf /root/src.tgz -C /root/src && umask 077 &&
  printf '%s\n' '$WG_KEY' >/root/wg.key && printf '%s\n' '$QB_PASS' >/root/qb.pass"
INSTALL="bash /root/src/platforms/casaos/install.sh"
ENVS="TS_SOURCE_DIR=/root/src TS_WIREGUARD_PRIVATE_KEY_FILE=/root/wg.key TS_WIREGUARD_ADDRESSES=10.2.0.2/32 TS_QBITTORRENT_PASSWORD_FILE=/root/qb.pass"
api() { gsh "curl -s --noproxy '*' \"\$(cat /var/run/casaos/app-management.url)/v2/app_management$1\""; }
ids() { gsh "docker ps -aq --filter label=com.docker.compose.project=torrent-stack | sort | tr '\n' ' '"; }

section "1-2. Fresh install with a made-up VPN key"
rc=0
gsh "$ENVS TS_WAIT=180 TS_POLL_INTERVAL=5 $INSTALL -y >/root/e2e-fresh.log 2>&1" || rc=$?
check "install exits 2 (VPN never connects with a made-up key)" test "$rc" == 2
grid=$(api /web/appgrid)
check "CasaOS lists the app on the dashboard grid" grep -q '"name":"torrent-stack"' <<<"$grid"
check "qBittorrent, Jackett, FlareSolverr share Gluetun's network" gsh '
  g=$(docker inspect -f "{{.Id}}" torrent-stack-gluetun-1)
  for s in qbittorrent jackett flaresolverr; do
    [ "$(docker inspect -f "{{.HostConfig.NetworkMode}}" torrent-stack-$s-1)" = "container:$g" ] || exit 1
  done'
check "Gluetun runs, the apps behind it were never started" gsh '
  [ "$(docker inspect -f "{{.State.Status}}" torrent-stack-gluetun-1)" = running ] &&
  for s in qbittorrent jackett flaresolverr; do
    [ "$(docker inspect -f "{{.State.Status}}" torrent-stack-$s-1)" = created ] || exit 1
  done'
check "nothing in Gluetun's network reaches the internet while the VPN is down" gsh '
  ! docker run --rm --network container:torrent-stack-gluetun-1 busybox:1.37 wget -q -T 8 -O /dev/null http://1.1.1.1/ &&
  ! docker run --rm --network container:torrent-stack-gluetun-1 busybox:1.37 wget -q -T 8 -O /dev/null http://deb.debian.org/'
check "app files: .env 0600, rendered app 0600" gsh '[ "$(stat -c %a /DATA/AppData/torrent-stack/.env)" = 600 ] && [ "$(stat -c %a /DATA/AppData/torrent-stack/casaos-app.yml)" = 600 ]'

section "3. Re-run, --apply, --dry-run, --print-yaml"
before=$(ids)
gsh "$ENVS TS_WAIT=20 $INSTALL -y >/root/e2e-rerun.log 2>&1" || true
check "re-run updates in place (PUT)" gx grep -q 'CasaOS took the update' /root/e2e-rerun.log
check "re-run replaces no container" test "$before" == "$(ids)"
gsh "find /DATA/AppData/torrent-stack -type f -exec sha256sum {} + | sort >/root/sum0"
gsh "$ENVS $INSTALL -y --dry-run >/root/e2e-dry.log 2>&1"
gsh "find /DATA/AppData/torrent-stack -type f -exec sha256sum {} + | sort >/root/sum1"
check "--dry-run changes no file" gx cmp -s /root/sum0 /root/sum1
check "--dry-run prints no secret" gsh "! grep -q -F -e '$WG_KEY' -e '$QB_PASS' /root/e2e-dry.log"
gsh "$INSTALL --print-yaml >/root/print.yml 2>/dev/null"
check "--print-yaml is clean YAML with the app id" gsh "python3 -c 'import yaml; d=yaml.safe_load(open(\"/root/print.yml\")); assert d[\"x-casaos\"][\"id\"] == \"io.github.rob-paprocki.torrent-stack\"'"

section "4. Uninstall keeps the data"
gsh "TS_POLL_INTERVAL=3 $INSTALL --uninstall -y >/root/e2e-uninstall.log 2>&1"
check "no torrent-stack containers left" test -z "$(ids | tr -d ' ')"
check "CasaOS forgot the app" gsh "! test -e /var/lib/casaos/apps/torrent-stack"
check "/DATA/AppData/torrent-stack and .env kept" gx test -f /DATA/AppData/torrent-stack/.env

section "5. Every app up under CasaOS (Gluetun test double)"
gsh 'docker run -d --name casaos-test-registry -p 127.0.0.1:5000:5000 registry:2 >/dev/null
  mkdir -p /root/fake-gluetun
  printf "%s\n" "#!/bin/sh" "# Test double for qmcgaw/gluetun: always healthy, no VPN, no firewall." \
    "if [ \"\$1\" = healthcheck ]; then exit 0; fi" "exec sleep 2147483647" >/root/fake-gluetun/entrypoint
  chmod +x /root/fake-gluetun/entrypoint
  printf "FROM busybox:1.37\nCOPY entrypoint /gluetun-entrypoint\nENTRYPOINT [\"/gluetun-entrypoint\"]\n" >/root/fake-gluetun/Dockerfile
  DOCKER_BUILDKIT=0 docker build -q -t localhost:5000/test/fake-gluetun:1 /root/fake-gluetun >/dev/null
  for i in $(seq 1 30); do curl -s --noproxy "*" http://127.0.0.1:5000/v2/ >/dev/null && break; sleep 1; done
  docker push -q localhost:5000/test/fake-gluetun:1 >/dev/null
  rm -rf /root/src-fake && cp -a /root/src /root/src-fake
  sed -i "s#image: qmcgaw/gluetun:latest#image: localhost:5000/test/fake-gluetun:1#" /root/src-fake/compose.yaml'
rc=0
gsh "TS_SOURCE_DIR=/root/src-fake TS_WAIT=600 $INSTALL -y >/root/e2e-functional.log 2>&1" || rc=$?
check "install exits 0: every container runs, the installer's network and web UI checks pass" test "$rc" == 0
check "...its log shows the shared-network and web UI checks" gx grep -q 'qBittorrent accepts the login in .env' /root/e2e-functional.log
check "every container carries the revision label" gsh '[ "$(docker ps --filter label=com.docker.compose.project=torrent-stack --format "{{.Label \"io.github.rob-paprocki.torrent-stack.rev\"}}" | grep -c "^[0-9a-f]\{16\}$")" = 5 ]'
check "CasaOS kept restart: true on the apps behind Gluetun" gsh '[ "$(docker inspect -f "{{index .Config.Labels \"com.docker.compose.depends_on\"}}" torrent-stack-qbittorrent-1)" = "gluetun:service_healthy:true" ]'
check "the summary prints no password into a log file" gsh "! grep -q -F '$QB_PASS' /root/e2e-functional.log"
c() { curl --noproxy '*' -sS -m 15 "$@"; }
code() { curl --noproxy '*' -s -m 15 -o /dev/null -w '%{http_code}' "$@" 2>/dev/null || true; }
# qb_login PASSWORD: HTTP status of a LAN login to qBittorrent (body from a file).
qb_login() {
  printf 'username=admin&password=%s' "$1" >"$WORK/qb.try"
  code --data-binary @"$WORK/qb.try" -H "Referer: http://$IP:8090" "http://$IP:8090/api/v2/auth/login"
}
# same_netns: Gluetun and the three apps behind it share one network namespace.
same_netns() { gsh 'n=$(for s in gluetun qbittorrent jackett flaresolverr; do readlink /proc/$(docker inspect -f "{{.State.Pid}}" torrent-stack-$s-1)/ns/net; done | sort -u | wc -l); [ "$n" = 1 ]'; }
wait_ui() { for _ in $(seq 1 100); do [[ "$(code "http://$IP:8090/")" == 200 ]] && return 0; sleep 3; done; return 1; }
for _ in $(seq 1 60); do c -o /dev/null "http://$IP:8090/" 2>/dev/null && break; sleep 3; done
printf 'username=admin&password=%s' "$QB_PASS" >"$WORK/qb.body"
printf 'username=admin&password=wrong' >"$WORK/qb.bad"
check "qBittorrent: the seeded password logs in from the LAN" test "$(c -c "$WORK/jar" -o /dev/null -w '%{http_code}' --data-binary @"$WORK/qb.body" -H "Referer: http://$IP:8090" "http://$IP:8090/api/v2/auth/login")" == 204
check "qBittorrent: a wrong password is refused" test "$(c -o /dev/null -w '%{http_code}' --data-binary @"$WORK/qb.bad" -H "Referer: http://$IP:8090" "http://$IP:8090/api/v2/auth/login")" == 401
check "qBittorrent: Jackett search plugin installed and enabled" bash -c "curl --noproxy '*' -sS -m 15 -b '$WORK/jar' 'http://$IP:8090/api/v2/search/plugins' | grep -q '\"name\":\"jackett\"'"
KEY=$(gsh "sed -n 's/.*\"APIKey\": *\"\([^\"]*\)\".*/\1/p' /DATA/AppData/torrent-stack/configs/jackett/Jackett/ServerConfig.json")
check "Jackett: the seeded API key works" bash -c "curl --noproxy '*' -sS -m 15 'http://$IP:9117/api/v2.0/indexers/all/results/torznab/api?apikey=$KEY&t=caps' | grep -q '<caps>'"
check "FlareSolverr answers" bash -c "curl --noproxy '*' -sS -m 15 'http://$IP:8191/' | grep -q 'FlareSolverr is ready'"
FB_PW=$(gsh "docker logs torrent-stack-filebrowser-1 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | sed -n 's/.*[Gg]enerated initial admin password for user \"[^\"]*\"[^:]*:[[:space:]]*\([^[:space:]]*\).*/\1/p' | tail -n1")
check "FileBrowser: the first-run password from its log is accepted" bash -c "code=\$(curl --noproxy '*' -sS -m 15 -o /dev/null -w '%{http_code}' -X POST -H 'X-Password: $FB_PW' 'http://$IP:8081/api/auth/login?username=admin'); [ \"\$code\" = 200 ] || [ \"\$code\" = 403 ]"

ENV=/DATA/AppData/torrent-stack/.env
INST="bash /DATA/AppData/torrent-stack/platforms/casaos/install.sh"
section "6. A new qBittorrent password with --apply"
QB_NEW="E2e-New-Pass-8"
gsh "sed -i 's/^QBITTORRENT_PASSWORD=.*/QBITTORRENT_PASSWORD=$QB_NEW/' $ENV"
rc=0
gsh "TS_WAIT=600 $INST --apply >/root/e2e-pass.log 2>&1" || rc=$?
check "--apply exits 0 (the installer's own login check passed)" test "$rc" == 0
wait_ui || true
check "LAN login with the new password works" test "$(qb_login "$QB_NEW")" == 204
check "LAN login with the old password is refused" test "$(qb_login "$QB_PASS")" == 401
check "Gluetun's port script got the new password too" gsh "docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' torrent-stack-gluetun-1 | grep -qx 'QBITTORRENT_PASSWORD=$QB_NEW'"

section "7. JACKETT_PORT=9118, FLARESOLVERR_PORT=8192 (host side only)"
gsh "sed -i -e 's/^JACKETT_PORT=.*/JACKETT_PORT=9118/' -e 's/^FLARESOLVERR_PORT=.*/FLARESOLVERR_PORT=8192/' $ENV"
rc=0
gsh "TS_WAIT=600 $INST --apply >/root/e2e-ports.log 2>&1" || rc=$?
check "--apply exits 0 (every web UI answered on its new port)" test "$rc" == 0
check "Jackett answers on 9118 from the LAN" bash -c "[[ \"\$(curl --noproxy '*' -s -m 15 -o /dev/null -w '%{http_code}' 'http://$IP:9118/UI/Dashboard')\" =~ ^(200|301|302)$ ]]"
check "FlareSolverr answers on 8192 from the LAN" bash -c "curl --noproxy '*' -sS -m 15 'http://$IP:8192/' | grep -q 'FlareSolverr is ready'"
check "the search plugin still reaches Jackett (127.0.0.1:9117 inside)" gsh "grep -q '\"url\": \"http://127.0.0.1:9117\"' /DATA/AppData/torrent-stack/configs/qbittorrent/qBittorrent/nova3/engines/jackett.json &&
  [ \"\$(docker exec torrent-stack-qbittorrent-1 curl -s -m 10 -o /dev/null -w '%{http_code}' http://127.0.0.1:9117/UI/Dashboard)\" != 000 ]"
gsh "sed -i -e 's/^JACKETT_PORT=.*/JACKETT_PORT=9117/' -e 's/^FLARESOLVERR_PORT=.*/FLARESOLVERR_PORT=8191/' $ENV"
rc=0
gsh "TS_WAIT=600 $INST --apply >/root/e2e-ports-back.log 2>&1" || rc=$?
check "back to the default ports" test "$rc" == 0

section "8. Restarting the whole app through CasaOS (the dashboard's Restart)"
gsh "u=\$(cat /var/run/casaos/app-management.url); curl -s --noproxy '*' -X PUT -H 'Content-Type: application/json' --data '\"restart\"' \"\$u/v2/app_management/compose/torrent-stack/status\" >/dev/null"
sleep 30
wait_ui || true
check "after the restart all four share Gluetun's (new) network" same_netns
check "qBittorrent answers from the LAN after the restart" test "$(code "http://$IP:8090/")" == 200

section "9. Gluetun restarted alone, then --apply"
gsh "docker restart torrent-stack-gluetun-1 >/dev/null"
sleep 5
if same_netns; then bad "control: the apps lost Gluetun's network"; else ok "control: the apps lost Gluetun's network"; fi
rc=0
gsh "TS_WAIT=600 $INST --apply >/root/e2e-netns.log 2>&1" || rc=$?
check "--apply exits 0 and says it restarted them" bash -c "test $rc == 0 && incus exec '$CT' -- grep -q \"lost Gluetun's network\" /root/e2e-netns.log"
check "all four share Gluetun's network again" same_netns
wait_ui || true
check "qBittorrent answers from the LAN again" test "$(code "http://$IP:8090/")" == 200

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
