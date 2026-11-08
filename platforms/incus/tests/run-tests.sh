#!/usr/bin/env bash
#
# platforms/incus/tests/run-tests.sh
#
# Purpose: end-to-end tests for platforms/incus/install.sh against a real,
# local Incus daemon. Each test creates its own "in-*" container from
# images:debian/13, with TS_SOURCE_DIR pointing at a temporary copy of this
# repository whose native/install.sh is tests/stub-native-install.sh (so no
# real stack is built), checks the result and deletes the container again.
# At most two test containers exist at a time.
#
#   sudo bash platforms/incus/tests/run-tests.sh [--with-lan] [TEST...]
#
# Tests: validation proxy none existing git project restricted setupfail
# wizard failure lan-bridge lan-static lan-macvlan (default: all but the
# lan-* ones). The tests put /etc/subuid and /etc/subgid back as they were
# (the idmap mapping adds lines to them). --with-lan adds the lan-* tests,
# which change this machine's networking while they run: they create the
# interfaces inlan0, inveth0/inveth1 and inmvh, an nftables table
# "in_test_nat" (NAT for those test LANs) and dnsmasq DHCP servers on them,
# and remove all of it afterwards. Only run that on a test machine.
#
# Host proxy-device ports are offset by 20000 (TS_TEST_PORT_OFFSET) so the
# tests do not collide with services on the usual ports.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
INSTALLER="$REPO/platforms/incus/install.sh"
WORK="${TS_TEST_WORK:-$(mktemp -d /tmp/incus-installer-test.XXXXXX)}"
OFFSET="${TS_TEST_PORT_OFFSET:-20000}"
PASS=0
FAIL=0
FAILED=()
WITH_LAN=0
DNSMASQ_PIDS=()
BLOCKERS=() # port-blocking helper processes, killed on exit
GIT_DAEMON_PID=""

log() { printf '\n### %s\n' "$*"; }
ok() {
  PASS=$((PASS + 1))
  printf '  PASS  %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  FAILED+=("$1")
  printf '  FAIL  %s\n' "$1"
}
# check DESCRIPTION COMMAND...: pass when the command succeeds.
check() {
  local d=$1 out
  shift
  if out=$("$@" 2>&1); then ok "$d"; else
    bad "$d"
    printf '        output: %s\n' "$(tail -n 8 <<<"$out")"
  fi
}
# check_out DESCRIPTION EXPECTED COMMAND...: pass when the output contains EXPECTED.
check_out() {
  local d=$1 want=$2 out
  shift 2
  out=$("$@" 2>&1 || true)
  if [[ "$out" == *"$want"* ]]; then ok "$d"; else
    bad "$d"
    printf '        wanted: %s\n        got:    %s\n' "$want" "${out:0:400}"
  fi
}

gexec() { incus exec "$1" -- "${@:2}"; }
cleanup_instance() { incus delete --force "$1" >/dev/null 2>&1 || true; }

# Run the installer the way a user would, unattended, with test defaults.
run_installer() {
  local log=$1
  shift
  env TS_SOURCE_DIR="$WORK/src" TS_PROXY_PORT_OFFSET="$OFFSET" TS_MEMORY=1GiB TS_UNATTENDED=1 \
    "$@" bash "$INSTALLER" >"$log" 2>&1
}

prepare_source() {
  rm -rf "$WORK/src"
  mkdir -p "$WORK/src"
  tar -C "$REPO" --exclude=./.git -cf - . | tar -C "$WORK/src" -xf -
  # The stub's self-update sources the real installer for its git step.
  cp "$REPO/native/install.sh" "$WORK/src/native/install.real.sh"
  cp "$HERE/stub-native-install.sh" "$WORK/src/native/install.sh"
  echo 1 >"$WORK/src/native/STUB_VERSION"
  # Things that must never be copied into the container.
  echo "SECRET_FROM_HOST=1" >"$WORK/src/.env"
  echo "SECRET_BACKUP=1" >"$WORK/src/.env.bak"
  mkdir -p "$WORK/src/configs/should-not-be-copied" "$WORK/src/downloads"
  echo x >"$WORK/src/downloads/should-not-be-copied"
}

# ---------------------------------------------------------------------------
t_validation() {
  log "validation: bad settings are refused before anything is created"
  local before after
  before=$(incus list --format csv -c n | sort)
  run_installer "$WORK/v1.log" TS_NAME=1bad || true
  check_out "bad name refused" "Invalid setting: name" cat "$WORK/v1.log"
  run_installer "$WORK/v2.log" TS_NAME=in-val TS_IP=192.168.1.5/24 TS_GATEWAY=192.168.1.1 || true
  check_out "static IP needs lan mode" "static IPv4 needs TS_NETWORK_MODE=lan" cat "$WORK/v2.log"
  run_installer "$WORK/v3.log" TS_NAME=in-val TS_NETWORK_MODE=lan || true
  check_out "lan mode needs a parent" "LAN mode needs TS_LAN_PARENT" cat "$WORK/v3.log"
  run_installer "$WORK/v4.log" TS_NAME=in-val TS_NETWORK_MODE=lan TS_LAN_PARENT=nosuchnic0 || true
  check_out "unknown LAN parent refused" "no interface called 'nosuchnic0'" cat "$WORK/v4.log"
  run_installer "$WORK/v5.log" TS_NAME=in-val TS_NETWORK_MODE=lan TS_LAN_PARENT=incusbr0 || true
  check_out "managed bridge refused in lan mode" "Incus-managed bridge" cat "$WORK/v5.log"
  run_installer "$WORK/v6.log" TS_NAME=in-val TS_PROFILE=nosuchprofile || true
  check_out "unknown profile refused" "no profile 'nosuchprofile'" cat "$WORK/v6.log"
  run_installer "$WORK/v7.log" TS_NAME=in-val TS_DOWNLOADS_HOST_PATH=/etc || true
  check_out "system folder refused for downloads" "Invalid setting: downloads folder" cat "$WORK/v7.log"
  # Whole system trees and bare top folders, not just a few exact paths.
  local p i=0
  for p in /root/.ssh /usr/local/bin /usr/bin /boot/efi /var/log /var/lib/docker /lib/modules /srv /mnt/ "/home//"; do
    i=$((i + 1))
    run_installer "$WORK/v7-$i.log" TS_NAME=in-val TS_DOWNLOADS_HOST_PATH="$p" || true
    check_out "downloads folder $p refused" "Invalid setting: downloads folder" cat "$WORK/v7-$i.log"
  done
  # A symlink to a system folder is followed and refused (chown would
  # follow it too).
  mkdir -p "$WORK/links"
  ln -sfn /etc "$WORK/links/to-etc"
  run_installer "$WORK/v7-link.log" TS_NAME=in-val TS_DOWNLOADS_HOST_PATH="$WORK/links/to-etc/sub" || true
  check_out "symlink into /etc refused" "which is a system folder" cat "$WORK/v7-link.log"
  # A proxy URL with a password would be visible in the process list.
  run_installer "$WORK/v10.log" TS_NAME=in-val TS_GUEST_PROXY="http://user:s3cret@proxy.invalid:3128" || true
  check_out "proxy URL with credentials refused" "must not contain a user name or password" cat "$WORK/v10.log"
  check "refused proxy password not echoed" bash -c "! grep -q s3cret '$WORK/v10.log'"
  run_installer "$WORK/v8.log" TS_NAME=in-val TS_IMAGE=images:no/such-image || true
  check_out "missing image refused" "Cannot find or reach the image" cat "$WORK/v8.log"
  run_installer "$WORK/v9.log" TS_NAME=in-val TS_MEMORY=lots || true
  check_out "bad memory refused" "Invalid setting: memory limit" cat "$WORK/v9.log"
  check_out "--update of a missing instance refused" "no instance called 'in-none'" bash "$INSTALLER" --update in-none
  after=$(incus list --format csv -c n | sort)
  check "no instance was created by the refused runs" test "$before" == "$after"
}

# ---------------------------------------------------------------------------
t_proxy() {
  log "proxy mode: managed bridge + proxy devices, downloads folder (auto mapping), update, resume, uninstall"
  local n=in-proxy dl="$WORK/dl-proxy" hostip blocker=""
  cleanup_instance "$n"
  rm -rf "$dl"
  # Occupy one host port so the "port busy" path is exercised: Jackett's
  # host port is 9117 + OFFSET.
  python3 -c 'import socket, sys, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(1); time.sleep(600)' "$((9117 + OFFSET))" >/dev/null 2>&1 &
  blocker=$!
  BLOCKERS+=("$blocker")
  sleep 1
  if run_installer "$WORK/proxy.log" TS_NAME="$n" TS_DOWNLOADS_HOST_PATH="$dl" TS_TZ=Europe/Berlin TS_PUID=1000 TS_PGID=1000; then
    ok "install finished (exit 0)"
  else
    bad "install finished (exit 0)"
    tail -n 30 "$WORK/proxy.log"
  fi
  check_out "busy host port reported" "Could not publish jackett on host port $((9117 + OFFSET))" cat "$WORK/proxy.log"
  check_out "busy port marked in the summary" "not published (host port $((9117 + OFFSET))" cat "$WORK/proxy.log"
  check_out "credentials printed" "password stub-password-123" cat "$WORK/proxy.log"
  check_out "native install ran with TZ" "env TZ=Europe/Berlin" gexec "$n" cat /root/stub-calls.log
  check_out "native install got PUID" "env PUID=1000" gexec "$n" cat /root/stub-calls.log
  check_out "native install got DOWNLOADS_PATH" "env DOWNLOADS_PATH=/mnt/downloads" gexec "$n" cat /root/stub-calls.log
  check_out "native install got INCOMPLETE_DOWNLOADS" "env INCOMPLETE_DOWNLOADS=/mnt/downloads/incomplete" gexec "$n" cat /root/stub-calls.log
  check_out "/dev/net/tun usable in the container" "tun open-ok" gexec "$n" cat /root/stub-calls.log
  check_out "tun is a unix-char device" "unix-char" incus config device get "$n" tun type
  check_out "limits.cpu set" "2" incus config get "$n" limits.cpu
  check_out "limits.memory set" "1GiB" incus config get "$n" limits.memory
  check_out "boot.autostart set" "true" incus config get "$n" boot.autostart
  check "no security.privileged=true" test "$(incus config get "$n" security.privileged --expanded)" != true
  check "nesting not enabled" test "$(incus config get "$n" security.nesting --expanded)" != true
  check "container time zone" test "$(gexec "$n" readlink /etc/localtime)" == /usr/share/zoneinfo/Europe/Berlin
  check ".env from the host not copied" bash -c "! incus exec $n -- grep -q SECRET_FROM_HOST /opt/torrent-stack/.env"
  check ".env.bak not copied" bash -c "! incus exec $n -- test -e /opt/torrent-stack/.env.bak"
  check "configs/ not copied" bash -c "! incus exec $n -- test -e /opt/torrent-stack/configs/should-not-be-copied"
  check "downloads/ not copied" bash -c "! incus exec $n -- test -e /opt/torrent-stack/downloads/should-not-be-copied"
  check "settings file is 0600" test "$(gexec "$n" stat -c %a /root/.torrent-stack-incus.env)" == 600
  # Downloads mapping: whatever "auto" picked must give PUID:PGID inside and
  # on the host.
  # auto tries idmap first (container root stays an ordinary high uid).
  check_out "auto mapping picked idmap" "idmap" incus config get "$n" user.torrent-stack.downloads-mapping
  check_out "raw.idmap maps only PUID/PGID" "uid 1000 1000" incus config get "$n" raw.idmap
  check "no shift=true on the downloads disk" test -z "$(incus config device get "$n" downloads shift 2>/dev/null)"
  check_out "stage recorded as done" "done" incus config get "$n" user.torrent-stack.stage
  check_out "update hint keeps TS_SOURCE_DIR and the local script" "TS_SOURCE_DIR=$WORK/src bash $INSTALLER --update $n" cat "$WORK/proxy.log"
  check "downloads owned by 1000:1000 inside" test "$(gexec "$n" stat -c %u:%g /mnt/downloads)" == 1000:1000
  gexec "$n" setpriv --reuid=1000 --regid=1000 --clear-groups sh -c 'echo data >/mnt/downloads/written-in-container'
  check "file written as 1000 in the container is 1000:1000 on the host" test "$(stat -c %u:%g "$dl/written-in-container")" == 1000:1000
  # Proxy devices forward into the container.
  hostip=$(ip -4 route get 1.1.1.1 | sed -n 's/.* src \([0-9.]*\).*/\1/p')
  check_out "env-editor via host loopback" "stub env-editor on 9191 from 127.0.0.1" curl -s --max-time 5 "http://127.0.0.1:$((9191 + OFFSET))/"
  check_out "env-editor via host LAN address" "stub env-editor on 9191" curl -s --max-time 5 "http://${hostip}:$((9191 + OFFSET))/"
  # qBittorrent refuses requests whose Host port differs from its own, so
  # with an offset its port inside moves too: QBIT_WEBUI_PORT = 8090+OFFSET.
  check_out "qBittorrent's port inside moved by the offset (first install)" "QBIT_WEBUI_PORT=$((8090 + OFFSET))" gexec "$n" grep '^QBIT_WEBUI_PORT=' /opt/torrent-stack/.env
  check_out "qBittorrent forwarded, same port on both sides" "stub qbittorrent on $((8090 + OFFSET))" curl -s --max-time 5 "http://${hostip}:$((8090 + OFFSET))/"
  check_out "qBittorrent device: host port = container port" "tcp:127.0.0.1:$((8090 + OFFSET))" incus config device get "$n" proxy-qbittorrent connect
  check_out "FlareSolverr forwarded" "stub flaresolverr on 8191" curl -s --max-time 5 "http://${hostip}:$((8191 + OFFSET))/"
  check_out "FileBrowser forwarded" "stub filebrowser on 8081" curl -s --max-time 5 "http://${hostip}:$((8081 + OFFSET))/"
  check_out "printed URL uses the host address" "http://${hostip}:$((9191 + OFFSET))" cat "$WORK/proxy.log"
  # Free the port and re-publish.
  kill "$blocker" 2>/dev/null || true
  wait "$blocker" 2>/dev/null || true
  check "sync-ports exits 0 once the port is free" bash "$INSTALLER" --sync-ports "$n"
  check_out "Jackett forwarded after sync-ports" "stub jackett on 9117" curl -s --max-time 5 "http://127.0.0.1:$((9117 + OFFSET))/"
  # Port change in .env -> sync-ports follows it.
  gexec "$n" bash -c 'sed -i "s/^QBIT_WEBUI_PORT=.*/QBIT_WEBUI_PORT=8099/" /opt/torrent-stack/.env && bash /opt/torrent-stack/native/install.sh apply' >/dev/null
  bash "$INSTALLER" --sync-ports "$n" >"$WORK/proxy-sync.log" 2>&1 || true
  check_out "new qBittorrent port forwarded on the same host port" "stub qbittorrent on 8099" curl -s --max-time 5 "http://127.0.0.1:8099/"
  check "old qBittorrent host port closed" bash -c "! curl -s --max-time 3 http://127.0.0.1:$((8090 + OFFSET))/"
  # An override appended at the end of .env (the last line wins). The last
  # *_PORT line is then not FILEBROWSER_PORT, which used to make
  # --sync-ports and --update stop with "'IFS= read -r line' failed".
  gexec "$n" bash -c 'echo QBIT_WEBUI_PORT=8097 >>/opt/torrent-stack/.env && bash /opt/torrent-stack/native/install.sh apply' >/dev/null
  check "sync-ports with an appended port override exits 0" bash "$INSTALLER" --sync-ports "$n"
  check_out "appended qBittorrent port forwarded" "stub qbittorrent on 8097" curl -s --max-time 5 "http://127.0.0.1:8097/"
  # Back to the first install's ports for the checks below.
  gexec "$n" bash -c "sed -i '/^QBIT_WEBUI_PORT=8097\$/d; s/^QBIT_WEBUI_PORT=.*/QBIT_WEBUI_PORT=$((8090 + OFFSET))/' /opt/torrent-stack/.env && bash /opt/torrent-stack/native/install.sh apply" >/dev/null
  check "sync-ports back to 8090+OFFSET" bash "$INSTALLER" --sync-ports "$n"
  # A new host port offset and listen address, given on --sync-ports.
  local off2=$((OFFSET + 1000))
  bash -c "TS_PROXY_PORT_OFFSET=$off2 bash '$INSTALLER' --sync-ports '$n'" >"$WORK/proxy-offset.log" 2>&1 || true
  check_out "offset change applied" "tcp:0.0.0.0:$((9191 + off2))" incus config device get "$n" proxy-env-editor listen
  check_out "offset stored on the container" "$off2" incus config get "$n" user.torrent-stack.proxy-port-offset
  check_out "env-editor on the new host port" "stub env-editor on 9191" curl -s --max-time 5 "http://127.0.0.1:$((9191 + off2))/"
  check_out "qBittorrent stays on its own port (warned)" "qBittorrent stays on host port $((8090 + OFFSET))" cat "$WORK/proxy-offset.log"
  check_out "  and is still published there" "tcp:0.0.0.0:$((8090 + OFFSET))" incus config device get "$n" proxy-qbittorrent listen
  # (With +1000 the old env-editor port 9191+OFFSET is now FlareSolverr's
  # 8191+OFFSET+1000, so "closed" means "not the env-editor any more".)
  check "env-editor gone from its old host port" bash -c "! curl -s --max-time 3 http://127.0.0.1:$((9191 + OFFSET))/ | grep -q 'env-editor'"
  check "plain sync-ports keeps the new offset" bash -c "bash '$INSTALLER' --sync-ports '$n' | grep -q 'already match'"
  # Back to OFFSET and onto 127.0.0.1 in one go. The env-editor's new port
  # 9191+OFFSET is FlareSolverr's current one: moving the devices one at a
  # time used to fail here ("Device doesn't exist" afterwards).
  if TS_PROXY_ADDRESS=127.0.0.1 TS_PROXY_PORT_OFFSET="$OFFSET" bash "$INSTALLER" --sync-ports "$n" >"$WORK/proxy-addr.log" 2>&1; then
    ok "move onto another UI's old port exits 0"
  else
    bad "move onto another UI's old port exits 0"
    tail -n 12 "$WORK/proxy-addr.log"
  fi
  check_out "listen address change applied" "tcp:127.0.0.1:$((9191 + OFFSET))" incus config device get "$n" proxy-env-editor listen
  check_out "FlareSolverr moved too" "tcp:127.0.0.1:$((8191 + OFFSET))" incus config device get "$n" proxy-flaresolverr listen
  check_out "reachable on loopback" "stub env-editor on 9191" curl -s --max-time 5 "http://127.0.0.1:$((9191 + OFFSET))/"
  check "not reachable on the LAN address" bash -c "! curl -s --max-time 3 http://${hostip}:$((9191 + OFFSET))/"
  TS_PROXY_ADDRESS=0.0.0.0 bash "$INSTALLER" --sync-ports "$n" >/dev/null 2>&1 || true
  check_out "listen address back to 0.0.0.0" "tcp:0.0.0.0:$((9191 + OFFSET))" incus config device get "$n" proxy-env-editor listen
  check_out "bad offset refused" "Invalid TS_PROXY_PORT_OFFSET" env TS_PROXY_PORT_OFFSET=99999 bash "$INSTALLER" --sync-ports "$n"
  # A host port taken while the container is stopped used to keep it from
  # starting at all, and --sync-ports could not recover.
  incus stop "$n"
  python3 -c 'import socket, sys, time; s = socket.socket(); s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1); s.bind(("0.0.0.0", int(sys.argv[1]))); s.listen(1); time.sleep(600)' "$((9117 + OFFSET))" >/dev/null 2>&1 &
  blocker=$!
  BLOCKERS+=("$blocker")
  sleep 1
  check "plain incus start fails with the busy port (precondition)" bash -c "! incus start '$n' 2>/dev/null"
  if bash "$INSTALLER" --sync-ports "$n" >"$WORK/proxy-busy.log" 2>&1; then bad "sync-ports exits 1 while a port is busy"; else ok "sync-ports exits 1 while a port is busy"; fi
  check_out "container started anyway" "RUNNING" incus list "$n" -f csv -c s
  check_out "busy port explained" "A host port of the web UIs is in use" cat "$WORK/proxy-busy.log"
  check_out "busy UI marked not published" "not published (host port $((9117 + OFFSET))" cat "$WORK/proxy-busy.log"
  # The stub's web servers are transient units, gone after the restart
  # (the real services are enabled units and come back by themselves).
  gexec "$n" bash /opt/torrent-stack/native/install.sh apply >/dev/null 2>&1 || true
  check_out "other UIs re-published" "stub env-editor on 9191" curl -s --max-time 5 "http://127.0.0.1:$((9191 + OFFSET))/"
  kill "$blocker" 2>/dev/null || true
  wait "$blocker" 2>/dev/null || true
  check "sync-ports exits 0 once the port is free again" bash "$INSTALLER" --sync-ports "$n"
  check_out "Jackett forwarded again" "stub jackett on 9117" curl -s --max-time 5 "http://127.0.0.1:$((9117 + OFFSET))/"
  # Update: new files in the source reach the container, native update runs.
  echo 2 >"$WORK/src/native/STUB_VERSION"
  if env TS_SOURCE_DIR="$WORK/src" bash "$INSTALLER" --update "$n" >"$WORK/proxy-update.log" 2>&1; then ok "update exit 0"; else bad "update exit 0"; fi
  check_out "native update ran with the new source" "source version 2" cat "$WORK/proxy-update.log"
  check_out "native update was called" "args: update" gexec "$n" cat /root/stub-calls.log
  check_out "update re-checked the proxies" "Proxy devices already match" cat "$WORK/proxy-update.log"
  # Resume (idempotent re-run of the in-container install).
  if env TS_SOURCE_DIR="$WORK/src" bash "$INSTALLER" --resume "$n" >"$WORK/proxy-resume.log" 2>&1; then ok "resume exit 0"; else bad "resume exit 0"; fi
  check_out "resume passed the saved TZ again" "2" bash -c "incus exec $n -- grep -c 'env TZ=Europe/Berlin' /root/stub-calls.log"
  # Uninstall needs confirmation.
  check_out "uninstall refuses without --yes" "without confirmation" bash "$INSTALLER" --uninstall "$n" </dev/null
  check "instance still there" incus info "$n"
  check "uninstall --yes" bash "$INSTALLER" --uninstall "$n" --yes
  check "instance gone" bash -c "! incus info $n"
  check "host downloads kept" test -f "$dl/written-in-container"
  check "proxy ports closed after uninstall" bash -c "! curl -s --max-time 3 http://127.0.0.1:$((9191 + OFFSET))/"
}

# ---------------------------------------------------------------------------
t_none() {
  log "downloads mapping 'none': host folder owned by the container's shifted ids (existing folder, TS_FORCE=1)"
  local n=in-none dl="$WORK/dl-none" huid
  cleanup_instance "$n"
  rm -rf "$dl"
  # An existing folder that already holds someone else's file: only taken
  # over because TS_FORCE=1 (t_existing covers the default).
  mkdir -p "$dl"
  echo old >"$dl/existing-file"
  chown -R 1234:1234 "$dl"
  if run_installer "$WORK/none.log" TS_NAME="$n" TS_DOWNLOADS_HOST_PATH="$dl" TS_DOWNLOADS_MAPPING=none TS_PUID=1001 TS_PGID=1001 TS_AUTOSTART=0 TS_FORCE=1; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/none.log"
  fi
  huid=$(incus exec "$n" -- awk '$1 == 0 {print $2 + 1001}' /proc/self/uid_map)
  check "host folder owned by the shifted uid ($huid)" test "$(stat -c %u "$dl")" == "$huid"
  check "downloads owned by 1001:1001 inside" test "$(gexec "$n" stat -c %u:%g /mnt/downloads)" == 1001:1001
  check_out "mapping recorded as none" "none" incus config get "$n" user.torrent-stack.downloads-mapping
  check "no raw.idmap" test -z "$(incus config get "$n" raw.idmap)"
  check_out "boot.autostart false" "false" incus config get "$n" boot.autostart
  check_out "PUID 1001 passed" "env PUID=1001" gexec "$n" cat /root/stub-calls.log
  check_out "existing files inside the folder left alone" "1234:1234" stat -c %u:%g "$dl/existing-file"
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

# ---------------------------------------------------------------------------
t_existing() {
  log "existing downloads folder with someone else's files: its owner is left alone"
  local n=in-exist dl="$WORK/dl-existing"
  cleanup_instance "$n"
  rm -rf "$dl"
  mkdir -p "$dl"
  echo media >"$dl/movie.mkv"
  chown -R 1234:1234 "$dl"
  if run_installer "$WORK/exist.log" TS_NAME="$n" TS_DOWNLOADS_HOST_PATH="$dl" TS_DOWNLOADS_MAPPING=none TS_AUTOSTART=0; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/exist.log"
  fi
  check_out "warned instead of taking the folder over" "already holds files and belongs to 1234:1234" cat "$WORK/exist.log"
  check_out "folder owner unchanged" "1234:1234" stat -c %u:%g "$dl"
  check_out "file owner unchanged" "1234:1234" stat -c %u:%g "$dl/movie.mkv"
  check "no incomplete/ created in it" test ! -e "$dl/incomplete"
  check_out "says the apps may not be able to write" "inside the container, not 1000:1000" cat "$WORK/exist.log"
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

# ---------------------------------------------------------------------------
# Failures during the container's own setup (before native/install.sh is
# handed the container): no --resume (it could not finish it), a hint to
# remove it and run again, and the settings are already in the container.
t_setupfail() {
  log "setup failure: remove-and-rerun hint, --resume refused, settings kept"
  local n=in-sfail dl="$WORK/dl-sfail" rc=0
  cleanup_instance "$n"
  rm -rf "$dl"
  # 1. A profile that makes the container privileged: refused right after
  # the container is created (deterministic on any server).
  incus profile create in-priv >/dev/null 2>&1 || true
  incus profile set in-priv security.privileged=true
  if run_installer "$WORK/sfail1.log" TS_NAME="$n" TS_PROFILE=default,in-priv; then rc=0; else rc=$?; fi
  check "privileged profile: install fails" test "$rc" != 0
  check_out "privileged profile: refused" "must run unprivileged" cat "$WORK/sfail1.log"
  check_out "privileged profile: remove-and-rerun hint" "remove the container and run the" cat "$WORK/sfail1.log"
  check "privileged profile: no --resume hint" bash -c "! grep -q -- '--resume' '$WORK/sfail1.log'"
  check_out "privileged profile: container never started" "STOPPED" incus list "$n" -f csv -c s
  run_installer "$WORK/sfail1b.log" TS_NAME="$n" || true
  check_out "a fresh install with the same name says to remove it first" "left over from an install whose setup failed" cat "$WORK/sfail1b.log"
  cleanup_instance "$n"
  incus profile delete in-priv >/dev/null 2>&1 || true
  # 2. The reviewer's case: TS_DOWNLOADS_MAPPING=shift where Incus cannot
  # do idmapped mounts (true on the test machine).
  if run_installer "$WORK/sfail2.log" TS_NAME="$n" TS_DOWNLOADS_HOST_PATH="$dl" TS_DOWNLOADS_MAPPING=shift \
    TS_PUID=1001 TS_PGID=1001 TS_TZ=Asia/Tokyo; then rc=0; else rc=$?; fi
  if [[ "$rc" == 0 ]]; then
    printf '        NOTE  shift=true worked on this server, so the shift-failure case was not exercised.\n'
    bash "$INSTALLER" --uninstall "$n" --yes >/dev/null 2>&1 || true
    return 0
  fi
  check_out "shift failure reported" "Could not mount ${dl} with shift=true" cat "$WORK/sfail2.log"
  check_out "suggests another mapping" "TS_DOWNLOADS_MAPPING=idmap or none" cat "$WORK/sfail2.log"
  check_out "remove-and-rerun hint" "incus delete --force ${n}" cat "$WORK/sfail2.log"
  check "no --resume hint" bash -c "! grep -q -- '--resume' '$WORK/sfail2.log'"
  check_out "stage is setup" "setup" incus config get "$n" user.torrent-stack.stage
  check_out "settings already in the container (TZ)" "TZ=Asia/Tokyo" incus file pull "$n/root/.torrent-stack-incus.env" -
  check_out "settings already in the container (PUID)" "PUID=1001" incus file pull "$n/root/.torrent-stack-incus.env" -
  check_out "--resume refused with an explanation" "was not fully set up" bash "$INSTALLER" --resume "$n"
  check "--resume did not run the native install" bash -c "! incus exec $n -- test -e /root/stub-calls.log"
  cleanup_instance "$n"
}

# ---------------------------------------------------------------------------
# A restricted project (as for the "incus" group's personal projects) with
# the devices the stack needs allowed, but low-level options blocked:
# linux.kernel_modules and raw.idmap are refused there.
PROJECT_R=in-rproj
t_restricted() {
  log "restricted project: kernel WireGuard skipped, downloads fall back from idmap"
  local n=in-rst dl="$WORK/dl-restricted" used
  rm -rf "$dl"
  mkdir -p "$dl"
  # Incus requires a restricted project to have its own profiles; its empty
  # default profile has no root disk, hence TS_STORAGE below.
  incus project delete "$PROJECT_R" >/dev/null 2>&1 || true
  if ! incus project create "$PROJECT_R" -c features.images=false -c restricted=true \
    -c restricted.devices.unix-char=allow -c restricted.devices.proxy=allow -c restricted.devices.disk=allow \
    -c restricted.devices.disk.paths="$dl" >"$WORK/rst-project.log" 2>&1; then
    bad "restricted test project created"
    cat "$WORK/rst-project.log"
    return 0
  fi
  local pool
  pool=$(incus storage list -f csv | head -n1 | cut -d, -f1)
  if run_installer "$WORK/rst.log" TS_NAME="$n" TS_PROJECT="$PROJECT_R" TS_STORAGE="$pool" TS_DOWNLOADS_HOST_PATH="$dl"; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/rst.log"
  fi
  check_out "restricted project warned about" "is restricted" cat "$WORK/rst.log"
  check_out "kernel module key refused, not fatal" "Could not ask Incus to load the wireguard module" cat "$WORK/rst.log"
  check "no linux.kernel_modules" test -z "$(incus config get "$n" linux.kernel_modules --project "$PROJECT_R")"
  check_out "raw.idmap refused, not fatal" "Incus refused raw.idmap" cat "$WORK/rst.log"
  check "no raw.idmap" test -z "$(incus config get "$n" raw.idmap --project "$PROJECT_R")"
  used=$(incus config get "$n" user.torrent-stack.downloads-mapping --project "$PROJECT_R" 2>/dev/null || true)
  printf '        fell back to: %s\n' "$used"
  check "mapping fell back to shift or none" bash -c "[[ '$used' == shift || '$used' == none ]]"
  check_out "downloads owned by 1000:1000 inside" "1000:1000" incus exec "$n" --project "$PROJECT_R" -- stat -c %u:%g /mnt/downloads
  check_out "env-editor forwarded" "stub env-editor on 9191" curl -s --max-time 5 "http://127.0.0.1:$((9191 + OFFSET))/"
  check "uninstall" env TS_PROJECT="$PROJECT_R" bash "$INSTALLER" --uninstall "$n" --yes
  incus project delete "$PROJECT_R" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# git mode: a git daemon on the Incus bridge stands in for GitHub.
t_git() {
  log "git mode: clone in the guest, then --update does git pull"
  local n=in-git bare="$WORK/git/stack.git" wt="$WORK/git/wt" gw
  cleanup_instance "$n"
  rm -rf "$WORK/git"
  mkdir -p "$WORK/git"
  git init -q -b main "$wt"
  tar -C "$WORK/src" --exclude=./.env --exclude=./.env.bak --exclude=./configs --exclude=./downloads -cf - . | tar -C "$wt" -xf -
  # The real repository tracks seed files under configs/, which the apps
  # and native/install.sh then rewrite in place: include them, as GitHub has.
  (cd "$REPO" && git ls-files -z configs | xargs -0 tar -cf -) | tar -C "$wt" -xf -
  test -f "$wt/configs/qbittorrent/qBittorrent/qBittorrent.conf" || bad "seed file present in the test repo"
  echo git-1 >"$wt/native/STUB_VERSION"
  git -C "$wt" add -A
  git -C "$wt" -c user.email=t@example.invalid -c user.name=test commit -q -m "stub v1"
  git clone -q --bare "$wt" "$bare"
  touch "$bare/git-daemon-export-ok"
  gw=$(incus network get incusbr0 ipv4.address)
  gw=${gw%/*}
  git daemon --reuseaddr --base-path="$WORK/git" --listen="$gw" --port=9418 --export-all "$WORK/git" &
  GIT_DAEMON_PID=$!
  sleep 1
  if run_installer "$WORK/git.log" TS_SOURCE_DIR="" TS_NAME="$n" TS_REPO_URL="git://${gw}/stack.git" TS_REF=main; then ok "install from git exit 0"; else
    bad "install from git exit 0"
    tail -n 30 "$WORK/git.log"
  fi
  check_out "repo cloned" "stub v1" gexec "$n" git -C /opt/torrent-stack log -1 --format=%s
  check_out "native install ran" "args: install" gexec "$n" cat /root/stub-calls.log
  echo git-2 >"$wt/native/STUB_VERSION"
  git -C "$wt" -c user.email=t@example.invalid -c user.name=test commit -q -am "stub v2"
  git -C "$wt" push -q "$bare" main
  if env -u TS_SOURCE_DIR bash "$INSTALLER" --update "$n" >"$WORK/git-update.log" 2>&1; then ok "update exit 0"; else
    bad "update exit 0"
    tail -n 30 "$WORK/git-update.log"
  fi
  check_out "git pull brought v2" "stub v2" gexec "$n" git -C /opt/torrent-stack log -1 --format=%s
  check_out "native update saw v2" "source version git-2" cat "$WORK/git-update.log"
  check_out "update names the checkout's own origin" "from git://${gw}/stack.git" cat "$WORK/git-update.log"
  # Live config vs seeds: the apps rewrite the tracked qBittorrent.conf in
  # place (simulated here), then upstream changes that seed. A plain
  # `git pull --ff-only` refused this ("Your local changes ... would be
  # overwritten"); the update must go through and keep the live file.
  local seed=configs/qbittorrent/qBittorrent/qBittorrent.conf
  gexec "$n" bash -c "echo 'WebUI\\LiveSetting=kept-by-update' >>/opt/torrent-stack/$seed && chown 1000:1000 /opt/torrent-stack/$seed && chmod 600 /opt/torrent-stack/$seed"
  check_out "seed modified in the guest (precondition)" " M $seed" gexec "$n" git -C /opt/torrent-stack status --porcelain
  echo "# upstream change to the seed" >>"$wt/$seed"
  echo git-3 >"$wt/native/STUB_VERSION"
  git -C "$wt" -c user.email=t@example.invalid -c user.name=test commit -q -am "stub v3 (seed changed)"
  git -C "$wt" push -q "$bare" main
  if env -u TS_SOURCE_DIR bash "$INSTALLER" --update "$n" >"$WORK/git-update3.log" 2>&1; then ok "update with a changed seed exit 0"; else
    bad "update with a changed seed exit 0"
    tail -n 30 "$WORK/git-update3.log"
  fi
  check_out "pull brought v3" "stub v3" gexec "$n" git -C /opt/torrent-stack log -1 --format=%s
  check_out "native update saw v3" "source version git-3" cat "$WORK/git-update3.log"
  check_out "live config kept" "LiveSetting=kept-by-update" gexec "$n" cat "/opt/torrent-stack/$seed"
  check "upstream seed line not forced over the live file" bash -c "! incus exec $n -- grep -q 'upstream change to the seed' /opt/torrent-stack/$seed"
  check_out "live file owner and mode kept" "1000:1000 600" gexec "$n" stat -c '%u:%g %a' "/opt/torrent-stack/$seed"
  check_out "kept files mentioned in the output" "your live configs were kept" cat "$WORK/git-update3.log"
  check_out "update went through native self-update" "args: self-update" gexec "$n" cat /root/stub-calls.log
  check_out "update with nothing new says so" "already up to date" bash -c "env -u TS_SOURCE_DIR bash '$INSTALLER' --update '$n' 2>&1; incus exec '$n' -- true"
  kill "$GIT_DAEMON_PID" 2>/dev/null || true
  wait "$GIT_DAEMON_PID" 2>/dev/null || true
  GIT_DAEMON_PID=""
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

# ---------------------------------------------------------------------------
# A separate Incus project (created for the test, deleted afterwards).
PROJECT_T=in-proj
t_project() {
  log "project: TS_PROJECT puts the container in another Incus project"
  local n=in-prj
  incus project create "$PROJECT_T" -c features.images=false -c features.profiles=false >/dev/null 2>&1 || true
  if run_installer "$WORK/proj.log" TS_NAME="$n" TS_PROJECT="$PROJECT_T"; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/proj.log"
  fi
  check "instance is in project $PROJECT_T" incus info "$n" --project "$PROJECT_T"
  check "instance is not in the default project" bash -c "! incus info $n --project default"
  check_out "native install ran" "args: install" incus exec "$n" --project "$PROJECT_T" -- cat /root/stub-calls.log
  check_out "env-editor forwarded" "stub env-editor on 9191" curl -s --max-time 5 "http://127.0.0.1:$((9191 + OFFSET))/"
  check_out "printed shell command names the project" "incus exec ${n} --project ${PROJECT_T} -- bash" cat "$WORK/proj.log"
  check_out "printed update command sets TS_PROJECT" "TS_PROJECT=${PROJECT_T} TS_SOURCE_DIR=" cat "$WORK/proj.log"
  check "update" env TS_PROJECT="$PROJECT_T" TS_SOURCE_DIR="$WORK/src" bash "$INSTALLER" --update "$n"
  check "sync-ports" env TS_PROJECT="$PROJECT_T" bash "$INSTALLER" --sync-ports "$n"
  check "uninstall" env TS_PROJECT="$PROJECT_T" bash "$INSTALLER" --uninstall "$n" --yes
  check "project empty again" bash -c "[[ -z \"\$(incus list --project $PROJECT_T --format csv -c n)\" ]]"
  incus project delete "$PROJECT_T" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Test LANs (only with --with-lan).
lan_up() {
  lan_down
  # A host bridge with a DHCP server: stands in for a home LAN bridge (br0).
  ip link add inlan0 type bridge
  ip addr add 192.168.77.1/24 dev inlan0
  ip link set inlan0 up
  # A veth pair: inveth0 stands in for a physical NIC (macvlan parent);
  # inmvh is a host-side macvlan on it, which is how a host reaches its own
  # macvlan containers, and carries that LAN's DHCP server.
  ip link add inveth0 type veth peer name inveth1
  ip link set inveth0 up
  ip link set inveth1 up
  ip link add inmvh link inveth0 type macvlan mode bridge
  ip addr add 192.168.78.1/24 dev inmvh
  ip link set inmvh up
  nft -f - <<'EOF'
table ip in_test_nat {
  chain postrouting {
    type nat hook postrouting priority srcnat; policy accept;
    ip saddr { 192.168.77.0/24, 192.168.78.0/24 } ip daddr != { 192.168.77.0/24, 192.168.78.0/24 } masquerade
  }
}
EOF
  local ifc range
  for ifc in inlan0:192.168.77 inmvh:192.168.78; do
    range=${ifc#*:}
    dnsmasq --keep-in-foreground --conf-file=/dev/null --port=0 --bind-interfaces --interface="${ifc%%:*}" \
      --except-interface=lo --dhcp-range="${range}.100,${range}.150,1h" --dhcp-option=3,"${range}.1" \
      --dhcp-option=6,8.8.8.8 --dhcp-leasefile="$WORK/${ifc%%:*}.leases" --pid-file="$WORK/${ifc%%:*}.pid" &
    DNSMASQ_PIDS+=($!)
  done
  sleep 1
}

lan_down() {
  local p
  for p in "${DNSMASQ_PIDS[@]}"; do kill "$p" 2>/dev/null || true; done
  DNSMASQ_PIDS=()
  nft delete table ip in_test_nat 2>/dev/null || true
  ip link del inmvh 2>/dev/null || true
  ip link del inveth0 2>/dev/null || true
  ip link del inlan0 2>/dev/null || true
}

t_lan_bridge() {
  log "lan mode: bridged to a host bridge, address from the LAN's DHCP"
  local n=in-lanbr ip
  cleanup_instance "$n"
  if run_installer "$WORK/lanbr.log" TS_NAME="$n" TS_NETWORK_MODE=lan TS_LAN_PARENT=inlan0; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/lanbr.log"
  fi
  check_out "nictype bridged" "bridged" incus config device get "$n" eth0 nictype
  check_out "parent inlan0" "inlan0" incus config device get "$n" eth0 parent
  ip=$(incus exec "$n" -- ip -4 -o addr show dev eth0 scope global | awk '{split($4, a, "/"); print a[1]}')
  check "DHCP address on the test LAN ($ip)" bash -c "[[ $ip == 192.168.77.* ]]"
  check "no proxy devices" bash -c "! incus config device list $n | grep -q proxy-"
  check_out "printed URL is the container's LAN address" "http://${ip}:9191" cat "$WORK/lanbr.log"
  check_out "MAC/DHCP reservation hint" "reserve this IP" cat "$WORK/lanbr.log"
  check_out "env-editor on the LAN address" "stub env-editor on 9191 from 192.168.77.1" curl -s --max-time 5 "http://${ip}:9191/"
  check_out "qBittorrent on the LAN address" "stub qbittorrent on 8090" curl -s --max-time 5 "http://${ip}:8090/"
  check_out "sync-ports refuses in lan mode" "lan mode" bash "$INSTALLER" --sync-ports "$n"
  check "update in lan mode" env TS_SOURCE_DIR="$WORK/src" bash "$INSTALLER" --update "$n"
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

t_lan_static() {
  log "lan mode: bridged, static IPv4 (systemd-networkd file in the guest)"
  local n=in-lanst
  cleanup_instance "$n"
  if run_installer "$WORK/lanst.log" TS_NAME="$n" TS_NETWORK_MODE=lan TS_LAN_PARENT=inlan0 TS_VLAN="" \
    TS_IP=192.168.77.50/24 TS_GATEWAY=192.168.77.1 TS_DNS="8.8.8.8,8.8.4.4"; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/lanst.log"
  fi
  check_out "static address in use" "192.168.77.50/24" incus exec "$n" -- ip -4 -o addr show dev eth0
  check_out "networkd file written" "Gateway=192.168.77.1" incus exec "$n" -- cat /etc/systemd/network/05-torrent-stack-eth0.network
  # Comma-separated DNS used to be glued into one bad line (DNS=8.8.8.88.8.4.4).
  check_out "first DNS server (comma-separated input)" $'DNS=8.8.8.8\n' incus exec "$n" -- cat /etc/systemd/network/05-torrent-stack-eth0.network
  check_out "second DNS server" "DNS=8.8.4.4" incus exec "$n" -- cat /etc/systemd/network/05-torrent-stack-eth0.network
  check_out "resolved uses both servers" "8.8.4.4" incus exec "$n" -- resolvectl dns eth0
  check "networkd accepted the DNS lines" bash -c "! incus exec $n -- journalctl -b -u systemd-networkd --no-pager | grep -q 'Failed to parse dns'"
  check_out "env-editor on the static address" "stub env-editor on 9191" curl -s --max-time 5 "http://192.168.77.50:9191/"
  check "no DHCP reservation hint with a static IP" bash -c "! grep -q 'reserve this IP' '$WORK/lanst.log'"
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

t_lan_macvlan() {
  log "lan mode: macvlan on a NIC (auto-detected), reached through a host macvlan"
  local n=in-lanmv ip
  cleanup_instance "$n"
  if run_installer "$WORK/lanmv.log" TS_NAME="$n" TS_NETWORK_MODE=lan TS_LAN_PARENT=inveth0; then ok "install exit 0"; else
    bad "install exit 0"
    tail -n 30 "$WORK/lanmv.log"
  fi
  check_out "nictype macvlan" "macvlan" incus config device get "$n" eth0 nictype
  ip=$(incus exec "$n" -- ip -4 -o addr show dev eth0 scope global | awk '{split($4, a, "/"); print a[1]}')
  check "DHCP address on the macvlan LAN ($ip)" bash -c "[[ $ip == 192.168.78.* ]]"
  check_out "env-editor reachable over macvlan" "stub env-editor on 9191 from 192.168.78.1" curl -s --max-time 5 "http://${ip}:9191/"
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

# ---------------------------------------------------------------------------
# Wizard: a whiptail stand-in answers the dialogs from a script and records
# them (a real terminal session cannot be scripted reliably).
t_wizard() {
  log "wizard: Advanced path through a recording whiptail shim"
  local n=in-wiz shim="$WORK/shim"
  cleanup_instance "$n"
  mkdir -p "$shim"
  cat >"$shim/whiptail" <<'EOF'
#!/usr/bin/env bash
# Recording whiptail stand-in: answers by dialog title.
printf '%s\n' "$*" >>"$WHIPTAIL_LOG"
title=""
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do [[ "${args[i]}" == --title ]] && title=${args[i + 1]}; done
answer() { printf '%s' "$1" >&2; exit 0; }
case "$title" in
"TORRENT STACK (INCUS)") exit 0 ;;
SETTINGS) [[ "$*" == *Default* && "$*" == *"Use default"* ]] && exit 1; exit 0 ;; # Advanced, then Create
"CONTAINER NAME") answer in-wiz ;;
IMAGE) answer images:debian/13 ;;
PROFILES) answer default ;;
"ROOT DISK SIZE") answer "" ;;
"CPU LIMIT") answer 1 ;;
"MEMORY LIMIT") answer 1GiB ;;
NETWORK) answer proxy ;;
"LISTEN ADDRESS") answer 0.0.0.0 ;;
"PORT OFFSET") answer 20000 ;;
"TIME ZONE") answer Asia/Tokyo ;;
PUID | PGID) answer 1000 ;;
"DOWNLOADS FOLDER") answer "" ;;
"START WITH INCUS") exit 1 ;;
*) answer "" ;;
esac
EOF
  chmod +x "$shim/whiptail"
  # The wizard only runs on a terminal: `script` provides one.
  if env PATH="$shim:$PATH" WHIPTAIL_LOG="$WORK/whiptail.log" TS_SOURCE_DIR="$WORK/src" \
    script -qec "bash '$INSTALLER'" "$WORK/wizard.log" </dev/null >/dev/null 2>&1; then ok "wizard install exit 0"; else
    bad "wizard install exit 0"
    tail -n 30 "$WORK/wizard.log"
  fi
  check_out "wizard asked for the network mode" "--title NETWORK" cat "$WORK/whiptail.log"
  check_out "settings confirmed" "Create the container with these settings" cat "$WORK/whiptail.log"
  check_out "limits.cpu from the wizard" "1" incus config get "$n" limits.cpu
  check_out "autostart answered no" "false" incus config get "$n" boot.autostart
  check_out "offset from the wizard" "20000" incus config get "$n" user.torrent-stack.proxy-port-offset
  check_out "TZ from the wizard" "env TZ=Asia/Tokyo" gexec "$n" cat /root/stub-calls.log
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

# ---------------------------------------------------------------------------
t_failure() {
  log "failure: native install fails -> retry hint, log kept, --resume finishes"
  local n=in-fail
  cleanup_instance "$n"
  # A source whose native install fails once (marker file in the guest).
  rm -rf "$WORK/src-fail"
  cp -a "$WORK/src" "$WORK/src-fail"
  cat >"$WORK/src-fail/native/install.sh" <<'EOF'
#!/usr/bin/env bash
if [[ "$1" == install && ! -e /root/fail-once-done ]]; then
  touch /root/fail-once-done
  echo "simulated failure"
  exit 1
fi
exec bash "$(dirname "$0")/install-real.sh" "$@"
EOF
  cp "$WORK/src/native/install.sh" "$WORK/src-fail/native/install-real.sh"
  rm -f "$HOME/torrent-stack-${n}-install.log"
  if run_installer "$WORK/fail.log" TS_SOURCE_DIR="$WORK/src-fail" TS_NAME="$n"; then bad "install fails (exit non-zero)"; else ok "install fails (exit non-zero)"; fi
  check_out "retry hint printed" "install.sh --resume ${n}" cat "$WORK/fail.log"
  check_out "retry hint keeps TS_SOURCE_DIR" "TS_SOURCE_DIR=$WORK/src-fail bash $INSTALLER --resume ${n}" cat "$WORK/fail.log"
  check_out "removal hint printed" "incus delete --force" cat "$WORK/fail.log"
  check "install log kept (0600)" test "$(stat -c %a "$HOME/torrent-stack-${n}-install.log" 2>/dev/null)" == 600
  check "container kept for --resume" incus info "$n"
  check_out "stage is install (past the setup)" "install" incus config get "$n" user.torrent-stack.stage
  # Run the printed retry command exactly as printed (it used to lose
  # TS_SOURCE_DIR and then stop at "exists but is not a git checkout").
  local hint
  hint=$(sed -n 's/^  Retry the install:  //p' "$WORK/fail.log" | head -n1)
  printf '        hint: %s\n' "$hint"
  check "printed resume command finishes" env -u TS_SOURCE_DIR bash -c "$hint"
  check_out "stage is done after resume" "done" incus config get "$n" user.torrent-stack.stage
  check_out "native install ran on resume" "args: install" gexec "$n" cat /root/stub-calls.log
  rm -f "$HOME/torrent-stack-${n}-install.log"
  check "uninstall" bash "$INSTALLER" --uninstall "$n" --yes
}

# ---------------------------------------------------------------------------
main() {
  local tests=() t
  while (($#)); do
    case "$1" in
    --with-lan) WITH_LAN=1 ;;
    *) tests+=("$1") ;;
    esac
    shift
  done
  if ((${#tests[@]} == 0)); then
    tests=(validation proxy none existing git project restricted setupfail wizard failure)
    [[ "$WITH_LAN" == 1 ]] && tests+=(lan-bridge lan-static lan-macvlan)
  fi
  [[ "$(id -u)" == 0 ]] || {
    echo "run as root" >&2
    exit 1
  }
  mkdir -p "$WORK"
  echo "Work folder: $WORK"
  # The idmap downloads mapping adds root:<id>:1 lines to these host files;
  # put them back exactly as they were when the tests end.
  local f
  for f in /etc/subuid /etc/subgid; do
    if [[ -e "$f" ]]; then cp -p "$f" "$WORK/$(basename "$f").orig"; else : >"$WORK/$(basename "$f").absent"; fi
  done
  SUBID_SAVED=1
  prepare_source
  # Set up the test LANs once, from scratch (lan_up removes leftovers first).
  if [[ "$WITH_LAN" == 1 && " ${tests[*]}" == *" lan-"* ]]; then lan_up; fi
  for t in "${tests[@]}"; do
    if [[ "$t" == lan-* && "$WITH_LAN" != 1 ]]; then
      echo "skipping $t (needs --with-lan)"
      continue
    fi
    "t_${t//-/_}"
  done
  [[ "$WITH_LAN" == 1 ]] && lan_down
  echo
  echo "passed: $PASS  failed: $FAIL"
  ((FAIL == 0)) || {
    printf '  failed: %s\n' "${FAILED[@]}"
    exit 1
  }
}

SUBID_SAVED=0
cleanup_all() {
  local c f b
  [[ -n "$GIT_DAEMON_PID" ]] && kill "$GIT_DAEMON_PID" 2>/dev/null
  for b in ${BLOCKERS[@]+"${BLOCKERS[@]}"}; do kill "$b" 2>/dev/null || true; done
  [[ "$WITH_LAN" == 1 ]] && lan_down 2>/dev/null
  for c in in-proxy in-none in-exist in-git in-sfail in-lanbr in-lanst in-lanmv in-wiz in-fail; do cleanup_instance "$c"; done
  incus profile delete in-priv >/dev/null 2>&1 || true
  if incus project show "$PROJECT_T" >/dev/null 2>&1; then
    incus delete --force in-prj --project "$PROJECT_T" >/dev/null 2>&1 || true
    incus project delete "$PROJECT_T" >/dev/null 2>&1 || true
  fi
  if incus project show "$PROJECT_R" >/dev/null 2>&1; then
    incus delete --force in-rst --project "$PROJECT_R" >/dev/null 2>&1 || true
    incus project delete "$PROJECT_R" >/dev/null 2>&1 || true
  fi
  if [[ "$SUBID_SAVED" == 1 ]]; then
    for f in /etc/subuid /etc/subgid; do
      b="$WORK/$(basename "$f")"
      if [[ -e "$b.orig" ]]; then cp -p "$b.orig" "$f"; elif [[ -e "$b.absent" ]]; then rm -f "$f"; fi
    done
    echo "Restored /etc/subuid and /etc/subgid."
  fi
  return 0
}
trap cleanup_all EXIT
main "$@"
