#!/usr/bin/env bash
#
# platforms/proxmox/tests/run-tests.sh
#
# Purpose: test platforms/proxmox/install.sh without a Proxmox VE host.
# Stand-ins for pct, pveam, pvesm, pvesh, pveversion and whiptail
# (tests/shims) record every call; `pct create`/`pct set` are checked
# against the official Proxmox VE API schema. Two kinds of scenario:
#   record - no containers; checks the pct arguments, the container config,
#            the host-side changes and the refusals.
#   incus  - `pct` is backed by a real Incus system container (px-<CTID>,
#            Debian 13), so the in-guest hand-off really runs, against a stub
#            native/install.sh that records its arguments and environment.
# Everything runs in a private mount and network namespace: /etc/pve,
# /etc/subuid, /etc/subgid and /etc/modules-load.d are temporary copies,
# and vmbr0/vmbr1 are dummy bridges, so the host is not changed. (An empty
# /etc/pve mount point is created for the run if the host has none, and
# removed afterwards; /root/torrent-stack-*-settings.env files a run leaves
# are removed too.)
#
# Usage (as root): platforms/proxmox/tests/run-tests.sh [record|incus|incus1|incus2|all]
#   TS_TEST_WORK=dir     work directory (default: a new temp dir)
#   TS_TEST_APIDOC=file  Proxmox apidoc.js. Without it the runner uses
#                        TS_TEST_WORK/apidoc.js if that exists, else it
#                        downloads a fresh copy (curl, before it leaves the
#                        host's network) from
#                        https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js
#                        and deletes it again at the end.
#
# License: MIT (see LICENSE in the repository root).

set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="$(dirname "$HERE")"
REPO_DIR="$(cd "$PLATFORM_DIR/../.." && pwd)"
INSTALLER="$PLATFORM_DIR/install.sh"
WHAT="${1:-all}"

if [[ -z "${TS_TEST_IN_NS:-}" ]]; then
  [[ "$(id -u)" -eq 0 ]] || {
    echo "run as root (needs unshare and bind mounts)" >&2
    exit 1
  }
  # The private /etc/pve below needs a folder to mount on. If this host has
  # none, make one for the run and remove it afterwards, so tools that take
  # "/etc/pve exists" to mean "this is Proxmox" are not fooled later.
  MADE_ETC_PVE=0
  APIDOC_TMP=""
  # shellcheck disable=SC2329  # called by the EXIT trap
  outer_cleanup() {
    if ((MADE_ETC_PVE)) && ! rmdir /etc/pve 2>/dev/null; then
      echo "WARNING: could not remove the empty /etc/pve this test run created" >&2
    fi
    [[ -z "$APIDOC_TMP" ]] || rm -f -- "$APIDOC_TMP"
  }
  trap outer_cleanup EXIT
  trap 'exit 130' INT TERM
  # The pct stand-in checks every call against the official API schema.
  # The test namespace below has no network, so fetch it here if needed.
  if [[ -z "${TS_TEST_APIDOC:-}" && ! -s "${TS_TEST_WORK:-/nonexistent}/apidoc.js" ]]; then
    APIDOC_TMP=$(mktemp)
    echo "Downloading the Proxmox VE API schema (apidoc.js) ..."
    if ! curl -fsSL --max-time 300 -o "$APIDOC_TMP" https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js; then
      echo "Could not download apidoc.js. Download it yourself:" >&2
      echo "  curl -fsSLo apidoc.js https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js" >&2
      echo "then run again with TS_TEST_APIDOC=\$PWD/apidoc.js" >&2
      exit 1
    fi
    export TS_TEST_APIDOC="$APIDOC_TMP"
  fi
  if [[ ! -e /etc/pve ]]; then
    mkdir /etc/pve
    MADE_ETC_PVE=1
  fi
  rc=0
  unshare --mount --net --fork env TS_TEST_IN_NS=1 bash "$0" "$@" || rc=$?
  exit "$rc"
fi

# ---------------------------------------------------------------------------
# Namespace setup
# ---------------------------------------------------------------------------
# Whatever happens, remove the test containers and scratch files, including
# the per-container answers files install.sh keeps in /root until an
# install finishes (only those this run created).
PRE_STATE_FILES=$(compgen -G '/root/torrent-stack-*-settings.env' || true)
# Incus name prefix of the test containers (TS_TEST_PREFIX, default px-),
# passed on to the pct stand-in.
PX="${TS_TEST_PREFIX:-px-}"
export PVE_SHIM_PREFIX="$PX"
cleanup_tests() {
  local c f
  for c in "${PX}9301" "${PX}9302"; do incus delete --force "$c" >/dev/null 2>&1 || true; done
  rm -f /root/torrent-stack-930[12]-install.log
  rm -rf /var/tmp/px-shim-tun
  for f in /root/torrent-stack-*-settings.env; do
    [[ -e "$f" ]] || continue
    grep -qxF -- "$f" <<<"$PRE_STATE_FILES" || rm -f -- "$f"
  done
}
trap cleanup_tests EXIT

# Checked before anything is created, so a missing file leaves nothing behind.
APIDOC="${TS_TEST_APIDOC:-${TS_TEST_WORK:-/nonexistent}/apidoc.js}"
if [[ ! -s "$APIDOC" ]]; then
  echo "apidoc.js not found at $APIDOC (see the header of $0)." >&2
  exit 1
fi
APIDOC="$(cd "$(dirname "$APIDOC")" && pwd)/$(basename "$APIDOC")"

WORK="${TS_TEST_WORK:-$(mktemp -d)}"
mkdir -p "$WORK"
WORK="$(cd "$WORK" && pwd)"
STATE="$WORK/state"
BIN="$WORK/bin"

mount --make-rprivate /
mount -t sysfs sysfs /sys
ip link set lo up
ip link add vmbr0 type bridge
ip link add vmbr1 type bridge

mkdir -p "$WORK/etc-pve" "$WORK/modules-load.d"
cp /etc/subuid "$WORK/subuid.orig"
cp /etc/subgid "$WORK/subgid.orig"
cp /etc/subuid "$WORK/subuid"
cp /etc/subgid "$WORK/subgid"
[[ -d /etc/pve ]] || {
  echo "/etc/pve is missing: start run-tests.sh normally, not with TS_TEST_IN_NS set" >&2
  exit 1
}
mount --bind "$WORK/etc-pve" /etc/pve
mount --bind "$WORK/subuid" /etc/subuid
mount --bind "$WORK/subgid" /etc/subgid
mount --bind "$WORK/modules-load.d" /etc/modules-load.d

mkdir -p "$BIN"
for t in pct pveam pvesm pvesh pveversion timedatectl modprobe modinfo dpkg; do
  ln -sf "$HERE/shims/pveshim.py" "$BIN/$t"
done
ln -sf "$HERE/shims/whiptail" "$BIN/whiptail"
mkdir -p "$WORK/bin-nowhiptail"
for t in pct pveam pvesm pvesh pveversion timedatectl modprobe modinfo dpkg; do
  ln -sf "$HERE/shims/pveshim.py" "$WORK/bin-nowhiptail/$t"
done
# Put in front of PATH for runs that wait out a timeout on purpose (a
# container that never gets an IPv4 address): `sleep` returns at once.
FAST="$WORK/bin-fast"
mkdir -p "$FAST"
printf '#!/bin/sh\nexit 0\n' >"$FAST/sleep"
chmod +x "$FAST/sleep"

# Test copy of the repository: the real tree plus decoys that must never
# reach the container, and a stub native/install.sh.
SRC="$WORK/src"
rm -rf "$SRC"
rsync -a --exclude=.git --exclude='__pycache__' --exclude=.venv "$REPO_DIR/" "$SRC/"
mkdir -p "$SRC/.git" "$SRC/configs/qbittorrent" "$SRC/downloads" "$SRC/incomplete" \
  "$SRC/scripts/env-editor/.venv/bin" "$SRC/scripts/env-editor/__pycache__" "$SRC/native"
echo "decoy" >"$SRC/.git/HEAD"
echo "OPENVPN_PASSWORD=decoy-secret" >"$SRC/.env"
echo "OPENVPN_PASSWORD=decoy-secret" >"$SRC/.env.bak"
echo "decoy" >"$SRC/configs/qbittorrent/secret.conf"
echo "decoy" >"$SRC/downloads/movie.mkv"
echo "decoy" >"$SRC/incomplete/part"
echo "decoy" >"$SRC/scripts/env-editor/.venv/bin/python"
echo "decoy" >"$SRC/scripts/env-editor/__pycache__/app.cpython-313.pyc"
# The stub's self-update sources the real installer for its git step.
cp "$REPO_DIR/native/install.sh" "$SRC/native/install.real.sh"
cat >"$SRC/native/install.sh" <<'STUB'
#!/usr/bin/env bash
# Test stub for native/install.sh: records how it was called.
set -euo pipefail
log=/root/native-stub.log
{
  echo "=== args: $*"
  env | sort
} >>"$log"
case "${1:-}" in
install)
  if [ -f /opt/torrent-stack/native/FAIL_ONCE ]; then
    rm -f /opt/torrent-stack/native/FAIL_ONCE
    echo "stub: failing once on purpose" >&2
    exit 1
  fi
  echo "stub: install TZ=${TZ:-} PUID=${PUID:-} PGID=${PGID:-} DOWNLOADS_PATH=${DOWNLOADS_PATH:-}"
  # Same shapes as the real native/install.sh: the login is printed once
  # and saved to a root-only file (unless the NO_CREDS_FILE marker exists).
  if [ ! -f /root/.stub-creds ]; then
    echo "    first-run login:      user admin   password StubPassw0rd-xyz"
    touch /root/.stub-creds
    if [ ! -f /opt/torrent-stack/native/NO_CREDS_FILE ]; then
      (umask 077 && printf '# torrent-stack first-run logins\nenv-editor:  http://x:9191   user: admin   password: StubPassw0rd-xyz\n' >/root/torrent-stack.creds)
    fi
  fi
  ;;
self-update)
  # The real native/install.sh git step (sourced), then the stub's update.
  ref=""
  [ "${2:-}" = --ref ] && ref=${3:-}
  if [ -d /opt/torrent-stack/.git ]; then
    # shellcheck source=/dev/null
    . /opt/torrent-stack/native/install.real.sh
    git_update_checkout "$ref"
  else
    echo "stub: self-update of a copy (not a git checkout): no git step"
  fi
  exec bash /opt/torrent-stack/native/install.sh update
  ;;
update) echo "stub: update" ;;
status)
  echo "gluetun       inactive  (waiting for VPN settings)"
  echo "env-editor    active"
  ;;
*) exit 64 ;;
esac
STUB
chmod +x "$SRC/native/install.sh"
mkdir -p "$WORK/empty-src"

# This sandbox intercepts containers' HTTPS with an "Egress Gateway" CA the
# host trusts; hand it to the shim so guests can reach github.com. On a
# normal network there is no such CA and nothing is injected.
GUEST_CA="$WORK/test-network-ca.crt"
python3 -I - "$GUEST_CA" <<'PY' || true
import re, subprocess, sys
try:
    data = open("/etc/ssl/certs/ca-certificates.crt").read()
except OSError:
    sys.exit(0)
out = []
for c in re.findall(r"-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----", data, re.S):
    s = subprocess.run(["openssl", "x509", "-noout", "-subject"], input=c, capture_output=True, text=True).stdout
    if "Egress Gateway CA" in s:
        out.append(c)
if out:
    open(sys.argv[1], "w").write("\n".join(out) + "\n")
PY
[[ -s "$GUEST_CA" ]] && export PVE_SHIM_GUEST_CA="$GUEST_CA"

PW_FILE="$WORK/rootpw"
(umask 077 && printf '%s\n' 'Corr3ct-Horse-Battery' >"$PW_FILE")
KEY_FILE="$WORK/keys.pub"
printf '%s\n' '# test key' 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDtestkeytestkeytestkeytestkeytestkey0001 tester@laptop' >"$KEY_FILE"

reset_state() {
  rm -rf "$STATE"
  mkdir -p "$STATE"
  find "$WORK/etc-pve" -mindepth 1 -delete
  mkdir -p "$WORK/etc-pve/lxc" "$WORK/etc-pve/qemu-server" "$WORK/etc-pve/nodes/pve"
  cat "$WORK/subuid.orig" >/etc/subuid
  cat "$WORK/subgid.orig" >/etc/subgid
  printf 'local\tdir\tiso,vztmpl,backup\t100597760\t13180768\t82254152\n' >"$STATE/storages.tsv"
  printf 'local-lvm\tlvmthin\trootdir,images\t832888832\t25637183\t807251648\n' >>"$STATE/storages.tsv"
  printf 'tank\tzfspool\trootdir,images\t1932735283\t412316860\t1520418423\n' >>"$STATE/storages.tsv"
  # Real names from download.proxmox.com/images/aplinfo-pve-9.dat plus a
  # made-up 13.10-1 to prove the version sort (13.10 is newer than 13.6).
  printf 'system\t%s\n' debian-12-standard_12.12-1_amd64.tar.zst debian-13-standard_13.6-1_amd64.tar.zst \
    debian-13-standard_13.10-1_amd64.tar.zst debian-13-standard_13.6-1_arm64.tar.zst \
    ubuntu-24.04-standard_24.04-2_amd64.tar.zst >"$STATE/aplinfo.tsv"
  printf 'mail\tproxmox-mail-gateway-9.0-standard_9.0-1_amd64.tar.zst\n' >>"$STATE/aplinfo.tsv"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------
PASS=0 FAILS=0
declare -a FAILED=()
ok() {
  PASS=$((PASS + 1))
  echo "    ok   $1"
}
bad() {
  FAILS=$((FAILS + 1))
  FAILED+=("$CURRENT: $1")
  echo "    FAIL $1"
}
check() { # check DESCRIPTION COMMAND...
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then ok "$d"; else bad "$d"; fi
}
check_not() {
  local d=$1
  shift
  if "$@" >/dev/null 2>&1; then bad "$d"; else ok "$d"; fi
}
eq() { [[ "$1" == "$2" ]] || {
  echo "      expected: $2" >&2
  echo "      got:      $1" >&2
  return 1
}; }
contains() { grep -qF -- "$2" <<<"$1"; }
opt() { python3 -I "$HERE/lib/calls.py" "$STATE" create-opts | awk -v k="$1" 'index($0, k "=") == 1 {sub(/^[^=]*=/, ""); print; exit}'; }
has_opt() { python3 -I "$HERE/lib/calls.py" "$STATE" create-opts | grep -q "^$1="; }
ncalls() { python3 -I "$HERE/lib/calls.py" "$STATE" count "$@"; }

OUT=""
RC=0
# run_installer [ENV=VALUE...] -- [ARGS...]
run_installer() {
  local envs=()
  while (($#)) && [[ "$1" != -- ]]; do
    envs+=("$1")
    shift
  done
  shift || true
  RC=0
  OUT=$(env PATH="$BIN:$PATH" PVE_SHIM_STATE="$STATE" PVE_SHIM_APIDOC="$APIDOC" \
    PVE_SHIM_TZ="${PVE_SHIM_TZ:-America/New_York}" PCT_SHIM_BACKEND="${BACKEND:-record}" \
    ${envs[@]+"${envs[@]}"} bash "$INSTALLER" "$@" </dev/null 2>&1) || RC=$?
  printf '%s\n' "$OUT" >>"$WORK/output-${CURRENT//[^A-Za-z0-9]/_}.log"
}

scenario() {
  CURRENT=$1
  echo
  echo "=== $1"
}

conf() { cat "/etc/pve/lxc/$1.conf"; }
# expect_fail_with TEXT CMD...: CMD fails and its output contains TEXT.
expect_fail_with() {
  local text=$1 out
  shift
  out=$("$@" 2>&1) && return 1
  grep -qF -- "$text" <<<"$out"
}
shim_pct_fails_exists() { expect_fail_with "already exists" shim_pct create 9000 "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst" --rootfs local-lvm:8; }
shim_pct_exec_stopped() { expect_fail_with "not running" shim_pct exec 9000 -- true; }
shim_pct_push_stopped() { expect_fail_with "can only push files to a running CT" shim_pct push 9000 /etc/hostname /root/x; }

# ---------------------------------------------------------------------------
# Record-backend scenarios
# ---------------------------------------------------------------------------
record_tests() {
  BACKEND=record

  reset_state
  scenario "R0 the pct shim rejects what Proxmox VE rejects (validator self-test)"
  mkdir -p "$STATE/storage/local/template/cache"
  : >"$STATE/storage/local/template/cache/debian-13-standard_13.6-1_amd64.tar.zst"
  local T=local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst
  shim_pct() { env PATH="$BIN:$PATH" PVE_SHIM_STATE="$STATE" PVE_SHIM_APIDOC="$APIDOC" PCT_SHIM_BACKEND=record pct "$@"; }
  local -a badcases=(
    "vmid below 100|99 $T --rootfs local-lvm:8"
    "unknown option|9000 $T --rootfs local-lvm:8 --bogus 1"
    "CIDR /33|9000 $T --rootfs local-lvm:8 --net0 name=eth0,bridge=vmbr0,ip=10.0.0.1/33"
    "VLAN 5000|9000 $T --rootfs local-lvm:8 --net0 name=eth0,bridge=vmbr0,ip=dhcp,tag=5000"
    "net0 without name|9000 $T --rootfs local-lvm:8 --net0 bridge=vmbr0,ip=dhcp"
    "unknown net0 key|9000 $T --rootfs local-lvm:8 --net0 name=eth0,vlan=5"
    "features nesting=2|9000 $T --rootfs local-lvm:8 --features nesting=2"
    "boolean onboot maybe|9000 $T --rootfs local-lvm:8 --onboot maybe"
    "tag with a space|9000 $T --rootfs local-lvm:8 --tags bad!tag"
    "dev0 outside /dev|9000 $T --rootfs local-lvm:8 --dev0 /tmp/tun"
    "unknown time zone|9000 $T --rootfs local-lvm:8 --timezone Mars/Olympus_Mons"
    "mp0 without mp=|9000 $T --rootfs local-lvm:8 --mp0 /srv/dl"
    "memory below 16|9000 $T --rootfs local-lvm:8 --memory 8"
    "hostname with underscore|9000 $T --rootfs local-lvm:8 --hostname bad_name"
    "missing template volume|9000 local:vztmpl/nope.tar.zst --rootfs local-lvm:8"
    "rootfs on a storage without rootdir|9000 $T --rootfs local:8"
  )
  local case_ desc args
  for case_ in "${badcases[@]}"; do
    desc=${case_%%|*}
    read -r -a args <<<"${case_#*|}"
    check_not "rejects: $desc" shim_pct create "${args[@]}"
  done
  check "accepts a full valid create" shim_pct create 9000 "$T" --arch amd64 --ostype debian --hostname ok-host \
    --cores 2 --memory 2048 --swap 512 --rootfs local-lvm:8 --net0 name=eth0,bridge=vmbr0,ip=192.168.1.5/24,gw=192.168.1.1,tag=10 \
    --unprivileged 1 --features nesting=1 --onboot 1 --tags "a;b" --timezone Europe/Berlin --dev0 /dev/net/tun \
    --mp0 /srv/dl,mp=/mnt/downloads --nameserver "1.1.1.1 9.9.9.9" --description "x"
  check "rejects a second create with the same ID" shim_pct_fails_exists
  check "exec refuses a stopped container (like pct)" shim_pct_exec_stopped
  check "push refuses a stopped container (like pct)" shim_pct_push_stopped

  reset_state
  scenario "R1 unattended defaults (PVE 9.2, TS_SOURCE_DIR, password file)"
  run_installer PVE_SHIM_VERSION=9.2.13 PVE_SHIM_USED_IDS=100 TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" TS_ROOT_PASSWORD_FILE="$PW_FILE" --
  check "exit 0" eq "$RC" 0
  check "next free ID skips the used 100" eq "$(opt vmid)" 101
  check "newest debian-13 template (13.10 > 13.6)" eq "$(opt ostemplate)" "local:vztmpl/debian-13-standard_13.10-1_amd64.tar.zst"
  check "template downloaded to local" python3 -I "$HERE/lib/calls.py" "$STATE" argv-has pveam debian-13-standard_13.10-1_amd64.tar.zst
  check "arch amd64" eq "$(opt arch)" amd64
  check "ostype debian" eq "$(opt ostype)" debian
  check "hostname torrent-stack" eq "$(opt hostname)" torrent-stack
  check "cores 2" eq "$(opt cores)" 2
  check "memory 4096" eq "$(opt memory)" 4096
  check "swap 512" eq "$(opt swap)" 512
  check "rootfs on local-lvm, 16 GiB" eq "$(opt rootfs)" "local-lvm:16"
  check "net0 DHCP on vmbr0" eq "$(opt net0)" "name=eth0,bridge=vmbr0,ip=dhcp"
  check "unprivileged 1" eq "$(opt unprivileged)" 1
  check "features nesting=1 (systemd in Debian 13)" eq "$(opt features)" "nesting=1"
  check "onboot 1" eq "$(opt onboot)" 1
  check "tags" eq "$(opt tags)" "torrent-stack;vpn;qbittorrent"
  check "timezone from the host" eq "$(opt timezone)" "America/New_York"
  check "native tun passthrough dev0 (PVE >= 8.1)" eq "$(opt dev0)" "/dev/net/tun"
  check_not "no --password on the command line" has_opt password
  check_not "no mp0 without a downloads folder" has_opt mp0
  check_not "no nameserver when DNS is empty" has_opt nameserver
  check "root password went to chpasswd's stdin" contains "$(python3 -I "$HERE/lib/calls.py" "$STATE" stdin-shapes)" "root:<redacted>"
  check_not "password never recorded anywhere" grep -rqF 'Corr3ct-Horse-Battery' "$STATE" "/etc/pve"
  check "chpasswd ran in the container" contains "$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)" "101 -- chpasswd"
  check "guest commands use a clean env" contains "$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)" "-- env -i PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin HOME=/root LANG=C.UTF-8"
  check_not "host proxy variables are not copied into the guest" grep -qiE 'https?_proxy=' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"
  # shellcheck disable=SC2016  # a literal $cmd in the recorded guest script
  check "native/install.sh install was invoked" grep -q 'native/install.sh "\$cmd"' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"
  local settings="$STATE/pushed/101/root__.torrent-stack-proxmox.env"
  check "settings file pushed" test -f "$settings"
  check "settings: TZ" grep -qx 'TZ=America/New_York' "$settings"
  check "settings: PUID/PGID" grep -qx 'PUID=1000' "$settings"
  check_not "settings: no DOWNLOADS_PATH without a bind mount" grep -q DOWNLOADS_PATH "$settings"
  check "settings pushed with perms 0600" grep -q '"pct-push-file", "argv": \["101", "[^"]*settings.env", "/root/.torrent-stack-proxmox.env"\], "t": [0-9.]*, "perms": "0600"' "$STATE/calls.jsonl"
  local tarball="$STATE/pushed/101/root__torrent-stack-src.tar.gz" list
  check "source tarball pushed" test -f "$tarball"
  list=$(tar -tzf "$tarball")
  check "tarball has compose.yaml" contains "$list" "./compose.yaml"
  check "tarball has .env.example" contains "$list" "./.env.example"
  check "tarball has native/install.sh" contains "$list" "./native/install.sh"
  check "tarball keeps tracked-looking files outside configs" contains "$list" "./scripts/env-editor/app.py"
  for x in ./.git/ ./configs/ ./downloads/ ./incomplete/ ./scripts/env-editor/.venv/; do
    check_not "tarball excludes $x" grep -qF -- "$x" <<<"$list"
  done
  for x in ./.env ./.env.bak; do
    check_not "tarball excludes $x" grep -qxF -- "$x" <<<"$list"
  done
  check_not "tarball excludes __pycache__" grep -qF __pycache__ <<<"$list"
  check "tarball files owned by root" eq "$(tar -tvzf "$tarball" | awk '{print $2}' | sort -u)" "0/0"
  check "wireguard module persisted on the host" grep -qx wireguard /etc/modules-load.d/torrent-stack-wireguard.conf
  check "summary shows env-editor URL" contains "$OUT" "env-editor: http://192.0.2.50:9191"
  check "no answers file left on the host after a finished install" test ! -e /root/torrent-stack-101-settings.env
  check "pct create/set calls valid per Proxmox API schema" python3 -I "$HERE/lib/calls.py" "$STATE" validate "$APIDOC"

  scenario "R2 advanced wizard (static IP, VLAN, DNS, key, idmap bind mount, Do-Over)"
  local dl="$WORK/hostdl-idmap"
  rm -rf "$dl"
  local ans=(
    WT_ANSWER_SETTINGS_1=no WT_ANSWER_SETTINGS_2=no WT_ANSWER_SETTINGS_3=yes
    WT_ANSWER_CONTAINER_ID=9101 WT_ANSWER_HOSTNAME=media-vpn WT_ANSWER_CPU_CORES=4 WT_ANSWER_RAM=3072
    WT_ANSWER_SWAP=0 WT_ANSWER_DISK_SIZE=20 WT_ANSWER_BRIDGE=vmbr1 WT_ANSWER_VLAN_TAG=30
    WT_ANSWER_IPV4_ADDRESS=10.10.30.50/24 WT_ANSWER_GATEWAY_1=10.20.0.1 WT_ANSWER_GATEWAY=10.10.30.1
    "WT_ANSWER_DNS_SERVERS=1.1.1.1 9.9.9.9" WT_ANSWER_ROOT_PASSWORD_1=short
    WT_ANSWER_ROOT_PASSWORD=Advanced-Pass-123 "WT_ANSWER_SSH_PUBLIC_KEY=$KEY_FILE"
    WT_ANSWER_PUID=1001 WT_ANSWER_PGID=1002 "WT_ANSWER_DOWNLOADS_FOLDER=$dl"
    WT_ANSWER_DOWNLOADS_OWNERSHIP=idmap WT_ANSWER_START_ON_BOOT=no WT_ANSWER_STORAGE=tank
  )
  run_installer PVE_SHIM_VERSION=9.1.4 TS_INTERACTIVE=1 TS_SOURCE_DIR="$SRC" "${ans[@]}" --
  check "exit 0" eq "$RC" 0
  check "Do-Over asked the questions twice" eq "$(grep -c '"title": "HOSTNAME"' "$STATE/whiptail.jsonl")" 2
  check "wrong-subnet gateway was refused, then accepted" eq "$(grep -c '"title": "GATEWAY"' "$STATE/whiptail.jsonl")" 4
  check "short password refused" grep -q '"title": "ROOT PASSWORD", "box": "msgbox"' "$STATE/whiptail.jsonl"
  check_not "whiptail log masks passwords" grep -qF 'Advanced-Pass-123' "$STATE/whiptail.jsonl"
  check "vmid 9101" eq "$(opt vmid)" 9101
  check "hostname media-vpn" eq "$(opt hostname)" media-vpn
  check "cores/memory/swap" eq "$(opt cores)/$(opt memory)/$(opt swap)" "4/3072/0"
  check "rootfs on chosen storage tank" eq "$(opt rootfs)" "tank:20"
  check "net0 static + gw + VLAN" eq "$(opt net0)" "name=eth0,bridge=vmbr1,ip=10.10.30.50/24,gw=10.10.30.1,tag=30"
  check "nameserver" eq "$(opt nameserver)" "1.1.1.1 9.9.9.9"
  check "onboot 0" eq "$(opt onboot)" 0
  check "timezone (PVE 9.1)" eq "$(opt timezone)" "America/New_York"
  check "dev0 on PVE 9.1" eq "$(opt dev0)" /dev/net/tun
  check "mp0 bind mount" eq "$(opt mp0)" "$dl,mp=/mnt/downloads"
  check "ssh keys file passed" has_opt ssh-public-keys
  check_not "no --password" has_opt password
  local c
  c=$(conf 9101)
  check "idmap: u 0 100000 1001" contains "$c" "lxc.idmap: u 0 100000 1001"
  check "idmap: u 1001 1001 1" contains "$c" "lxc.idmap: u 1001 1001 1"
  check "idmap: u 1002 101002 64534" contains "$c" "lxc.idmap: u 1002 101002 64534"
  check "idmap: g 0 100000 1002" contains "$c" "lxc.idmap: g 0 100000 1002"
  check "idmap: g 1002 1002 1" contains "$c" "lxc.idmap: g 1002 1002 1"
  check "idmap: g 1003 101003 64533" contains "$c" "lxc.idmap: g 1003 101003 64533"
  check "subuid allows root:1001:1" grep -qx 'root:1001:1' /etc/subuid
  check "subgid allows root:1002:1" grep -qx 'root:1002:1' /etc/subgid
  check "host folder owned 1001:1002" eq "$(stat -c %u:%g "$dl")" "1001:1002"
  check "incomplete/ owned 1001:1002" eq "$(stat -c %u:%g "$dl/incomplete")" "1001:1002"
  local settings="$STATE/pushed/9101/root__.torrent-stack-proxmox.env"
  check "settings: DOWNLOADS_PATH" grep -qx 'DOWNLOADS_PATH=/mnt/downloads' "$settings"
  check "settings: INCOMPLETE_DOWNLOADS" grep -qx 'INCOMPLETE_DOWNLOADS=/mnt/downloads/incomplete' "$settings"
  check "settings: PUID 1001" grep -qx 'PUID=1001' "$settings"
  check "summary uses the static IP" contains "$OUT" "http://10.10.30.50:9191"
  check "pct calls valid per Proxmox API schema" python3 -I "$HERE/lib/calls.py" "$STATE" validate "$APIDOC"

  scenario "R2b re-run is safe: subuid lines not duplicated"
  rm -f "$STATE"/whiptail.count.*
  run_installer PVE_SHIM_VERSION=9.1.4 TS_INTERACTIVE=1 TS_SOURCE_DIR="$SRC" "${ans[@]/WT_ANSWER_CONTAINER_ID=9101/WT_ANSWER_CONTAINER_ID=9103}" --
  check "exit 0" eq "$RC" 0
  check "root:1001:1 once in subuid" eq "$(grep -cx 'root:1001:1' /etc/subuid)" 1

  scenario "R2c Do-Over can clear the password and SSH key typed in the first pass"
  rm -f "$STATE"/whiptail.count.*
  : >"$STATE/whiptail.jsonl"
  local login=(
    WT_ANSWER_SETTINGS_1=no WT_ANSWER_SETTINGS_2=no WT_ANSWER_SETTINGS_3=yes
    WT_ANSWER_CONTAINER_ID=9105 WT_ANSWER_STORAGE=local-lvm
    WT_ANSWER_ROOT_PASSWORD_1=Advanced-Pass-123 WT_ANSWER_ROOT_PASSWORD_2=Advanced-Pass-123
    "WT_ANSWER_SSH_PUBLIC_KEY_1=$KEY_FILE"
  )
  run_installer PVE_SHIM_VERSION=9.2.13 TS_INTERACTIVE=1 TS_SOURCE_DIR="$SRC" "${login[@]}" \
    WT_ANSWER_KEEP_ROOT_PASSWORD=no WT_ANSWER_ROOT_PASSWORD_3= WT_ANSWER_SSH_PUBLIC_KEY_2= WT_ANSWER_ROOT_LOGIN=yes --
  check "exit 0" eq "$RC" 0
  check "second pass asked whether to keep the password" eq "$(grep -c '"title": "KEEP ROOT PASSWORD"' "$STATE/whiptail.jsonl")" 1
  check "SSH box asked again in the second pass" grep -qF "\"title\": \"SSH PUBLIC KEY\", \"box\": \"inputbox\", \"n\": 2" "$STATE/whiptail.jsonl"
  check "no-login warning was shown" grep -q '"title": "ROOT LOGIN"' "$STATE/whiptail.jsonl"
  check "vmid 9105" eq "$(opt vmid)" 9105
  check_not "cleared SSH key: no --ssh-public-keys" has_opt ssh-public-keys
  check_not "cleared password: chpasswd not run" grep -q '^9105 -- chpasswd' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"

  scenario "R2d Do-Over keeps the password and the SSH key when told to"
  rm -f "$STATE"/whiptail.count.*
  : >"$STATE/whiptail.jsonl"
  run_installer PVE_SHIM_VERSION=9.2.13 TS_INTERACTIVE=1 TS_SOURCE_DIR="$SRC" "${login[@]/WT_ANSWER_CONTAINER_ID=9105/WT_ANSWER_CONTAINER_ID=9106}" \
    WT_ANSWER_KEEP_ROOT_PASSWORD=yes --
  check "exit 0" eq "$RC" 0
  check "vmid 9106" eq "$(opt vmid)" 9106
  check "SSH box pre-filled with the first answer on Do-Over" python3 -I -c 'import json,sys
rows=[json.loads(l) for l in open(sys.argv[1])]
sys.exit(0 if any(r["title"]=="SSH PUBLIC KEY" and r["n"]==2 and r["answer"]==sys.argv[2] for r in rows) else 1)' "$STATE/whiptail.jsonl" "$KEY_FILE"
  check "kept SSH key passed to pct create" has_opt ssh-public-keys
  check "kept password set once" eq "$(grep -c '^9106 -- chpasswd' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)")" 1
  check "password typed only in the first pass" eq "$(grep -c '"title": "ROOT PASSWORD", "box": "passwordbox"' "$STATE/whiptail.jsonl")" 2

  scenario "R3 PVE 8.0 legacy tun lines + shift-mapped bind mount"
  dl="$WORK/hostdl-shift"
  rm -rf "$dl"
  run_installer PVE_SHIM_VERSION=8.0.4 TS_UNATTENDED=1 TS_CTID=9102 TS_SOURCE_DIR="$SRC" TS_DOWNLOADS_HOST_PATH="$dl" TS_ONBOOT=0 --
  check "exit 0" eq "$RC" 0
  check_not "no dev0 on PVE 8.0" has_opt dev0
  c=$(conf 9102)
  check "lxc.cgroup2.devices.allow c 10:200" contains "$c" "lxc.cgroup2.devices.allow: c 10:200 rwm"
  check "lxc.mount.entry for /dev/net/tun" contains "$c" "lxc.mount.entry: /dev/net/tun dev/net/tun none bind,create=file"
  check_not "no lxc.idmap in shift mode" contains "$c" "lxc.idmap"
  check "host folder owned 101000:101000" eq "$(stat -c %u:%g "$dl")" "101000:101000"
  check "incomplete/ owned 101000:101000" eq "$(stat -c %u:%g "$dl/incomplete")" "101000:101000"
  check "pct calls valid per Proxmox API schema" python3 -I "$HERE/lib/calls.py" "$STATE" validate "$APIDOC"

  scenario "R4 refusals (nothing is created)"
  local before
  before=$(ncalls pct create)
  run_installer PVE_SHIM_VERSION=7.4-3 TS_UNATTENDED=1 --
  check "PVE 7 refused" eq "$RC/$(contains "$OUT" "needs 8.x or 9.x" && echo y)" "1/y"
  run_installer PVE_SHIM_ARCH=arm64 TS_UNATTENDED=1 --
  check "arm64 refused" eq "$RC/$(contains "$OUT" "only released for amd64" && echo y)" "1/y"
  RC=0
  # bash -s: the script arrives on stdin, so the unprivileged user needs no
  # access to the checkout.
  OUT=$(setpriv --reuid=65534 --regid=65534 --clear-groups env PATH="$BIN:$PATH" PVE_SHIM_STATE="$WORK/nobody-state" bash -s <"$INSTALLER" 2>&1) || RC=$?
  check "non-root refused" eq "$RC/$(contains "$OUT" "Run this script as root" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_CTID=9101 TS_SOURCE_DIR="$SRC" --
  check "ID in use refused" eq "$RC/$(contains "$OUT" "container ID '9101'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_IP=10.0.0.5/33 TS_SOURCE_DIR="$SRC" --
  check "bad CIDR refused" eq "$RC/$(contains "$OUT" "IPv4 '10.0.0.5/33'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_IP=10.0.0.5/24 TS_SOURCE_DIR="$SRC" --
  check "static IP without gateway refused" eq "$RC/$(contains "$OUT" "needed with a static IP" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_IP=10.0.0.5/24 TS_GATEWAY=10.0.1.1 TS_SOURCE_DIR="$SRC" --
  check "gateway outside subnet refused" eq "$RC/$(contains "$OUT" "is not in 10.0.0.5/24" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$WORK/empty-src" --
  check "TS_SOURCE_DIR without native/ refused" eq "$RC/$(contains "$OUT" "has no native/install.sh" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_DOWNLOADS_HOST_PATH=/etc TS_SOURCE_DIR="$SRC" --
  check "system folder as downloads refused" eq "$RC/$(contains "$OUT" "downloads folder '/etc'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_BRIDGE=vmbr9 TS_SOURCE_DIR="$SRC" --
  check "missing bridge refused" eq "$RC/$(contains "$OUT" "bridge 'vmbr9'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_PUID=0 TS_SOURCE_DIR="$SRC" --
  check "PUID 0 refused" eq "$RC/$(contains "$OUT" "PUID '0'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_ROOTFS_STORAGE=local TS_SOURCE_DIR="$SRC" --
  check "storage without rootdir refused" eq "$RC/$(contains "$OUT" "cannot hold container disks" && echo y)" "1/y"
  run_installer -- --bogus
  check "unknown argument refused" eq "$RC/$(contains "$OUT" "Unknown argument '--bogus'" && echo y)" "1/y"
  run_installer -- --help
  check "--help exits 0" eq "$RC/$(contains "$OUT" "Usage (as root on the Proxmox VE host)" && echo y)" "0/y"
  run_installer TS_INTERACTIVE=1 WT_ANSWER_TORRENT_STACK_LXC=no TS_SOURCE_DIR="$SRC" --
  check "user can cancel the wizard" eq "$RC/$(contains "$OUT" "User exited script" && echo y)" "0/y"
  RC=0
  OUT=$(env PATH="$WORK/bin-nowhiptail:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" PVE_SHIM_STATE="$STATE" \
    script -qec "bash '$INSTALLER'" /dev/null </dev/null 2>&1) || RC=$?
  check "terminal without whiptail refused" contains "$OUT" "whiptail is missing"
  check "no container created by any refusal" eq "$(ncalls pct create)" "$before"

  scenario "R5 offline host with an older template already downloaded"
  mkdir -p "$STATE/storage/local/template/cache"
  rm -f "$STATE/storage/local/template/cache/"*
  echo "local copy" >"$STATE/storage/local/template/cache/debian-13-standard_13.6-1_amd64.tar.zst"
  run_installer PVEAM_SHIM_OFFLINE=1 TS_UNATTENDED=1 TS_CTID=9104 TS_SOURCE_DIR="$SRC" --
  check "exit 0" eq "$RC" 0
  check "falls back to the local 13.6-1 template" eq "$(opt ostemplate)" "local:vztmpl/debian-13-standard_13.6-1_amd64.tar.zst"
  check "says it fell back" contains "$OUT" "using the newest one already on local"

  scenario "R6 --update / --resume on existing containers"
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --update 9101
  check "--update exit 0" eq "$RC" 0
  check "--update ran native self-update" grep -qE '9101 -- env -i .* bash -c .* /opt/torrent-stack /root/.torrent-stack-proxmox.env self-update$' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"
  check "--update ran native status" grep -qE '9101 -- env -i .* /root/.torrent-stack-proxmox.env status$' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" TS_GUEST_PROXY=http://10.0.0.2:3128 -- --update 9101
  check "TS_GUEST_PROXY reaches guest commands" grep -qF 'https_proxy=http://10.0.0.2:3128' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"
  local nexec
  nexec=$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds | wc -l)
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" TS_GUEST_PROXY=http://user:s3cret-pw@10.0.0.2:3128 -- --update 9101
  check "TS_GUEST_PROXY with a password refused" eq "$RC/$(contains "$OUT" "must not contain a user name or password" && echo y)" "1/y"
  check_not "  and the password is not echoed" contains "$OUT" "s3cret-pw"
  check "  and nothing ran in the guest" eq "$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds | wc -l)" "$nexec"
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --update
  check "--update without ID and several tagged containers asks for one" eq "$RC/$(contains "$OUT" "Several containers are tagged torrent-stack" && echo y)" "1/y"
  printf 'arch: amd64\nhostname: other\nmemory: 512\nostype: debian\nrootfs: local-lvm:vm-9200-disk-0,size=4G\nunprivileged: 1\n' >/etc/pve/lxc/9200.conf
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --update 9200
  check "untagged container refused" eq "$RC/$(contains "$OUT" "not tagged torrent-stack" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_FORCE=1 TS_SOURCE_DIR="$SRC" -- --update 9200
  check "TS_FORCE=1 overrides" eq "$RC" 0
  check "stopped container was started" grep -q '"argv": \["start", "9200"\]' "$STATE/calls.jsonl"
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --resume 9102
  check "--resume exit 0" eq "$RC" 0
  check "--resume ran native install" grep -qE '9102 -- env -i .* /root/.torrent-stack-proxmox.env install$' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)"
  run_installer TS_UNATTENDED=1 -- --resume
  check "--resume needs an ID" eq "$RC" 1

  guest_git_tests
  resume_tests
  path_tests
  validator_tests
  check "all pct create/set calls valid per Proxmox API schema" python3 -I "$HERE/lib/calls.py" "$STATE" validate "$APIDOC"
}

# R7: the exact GUEST_CLONE snippet from install.sh (install path) and the
# real native/install.sh git step that `native/install.sh self-update` runs
# (update path), with this host's git against a local "upstream".
guest_git_tests() {
  scenario "R7 update keeps live config files when a new commit changes the seeds"
  # Like the container: no user or system git config (this machine's may
  # sign commits through a helper that needs the network).
  local -x GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
  local g=(git -c user.name=t -c user.email=t@example.invalid -c init.defaultBranch=main)
  local up="$WORK/r7-up" dir="$WORK/r7-opt" snip q j cat
  rm -rf "$up" "$dir"
  q=configs/qbittorrent/qBittorrent/qBittorrent.conf
  j=configs/jackett/Jackett/ServerConfig.json
  cat=configs/qbittorrent/qBittorrent/categories.json
  "${g[@]}" init -q "$up"
  mkdir -p "$up/configs/qbittorrent/qBittorrent" "$up/configs/jackett/Jackett"
  echo "seed 1" >"$up/$q"
  echo "seed 1" >"$up/$j"
  echo "readme 1" >"$up/README.md"
  echo "old" >"$up/old.txt"
  "${g[@]}" -C "$up" add -A && "${g[@]}" -C "$up" commit -qm "c1"
  snip=$(bash -c 'source "$1"; printf "%s" "$GUEST_CLONE"' _ "$INSTALLER")
  check "clone (install path)" bash -c "$snip" bash "$dir" "file://$up" main
  check "an existing checkout is kept by the clone step" bash -c "$snip" bash "$dir" "file://$up" main
  # The update step: the real function, with the checkout as TS_ROOT.
  gupd() {
    bash -c 'source "$1/native/install.sh"; TS_ROOT="$2"; git_update_checkout "$3"' _ "$REPO_DIR" "$dir" "$1" >"$WORK/r7.log" 2>&1
  }
  # What native/install.sh and the apps do: rewrite a seed, own it as the
  # torrent user; delete another; create a file upstream will add later.
  printf '[LIVE]\nWebUI\\Port=8999\n' >"$dir/$q"
  chown 1000:1000 "$dir/$q"
  chmod 600 "$dir/$q"
  rm -f "$dir/$j"
  echo "live categories" >"$dir/$cat"
  echo "seed 2" >"$up/$q"
  echo "seed 2" >"$up/$j"
  echo "seed categories" >"$up/$cat"
  echo "readme 2" >"$up/README.md"
  rm -f "$up/old.txt"
  "${g[@]}" -C "$up" add -A && "${g[@]}" -C "$up" commit -qm "c2 changes the seeds"
  check "update on a branch succeeds (git pull used to refuse)" gupd ""
  check "moved to the new commit" eq "$(git -C "$dir" log -1 --format=%s)" "c2 changes the seeds"
  check "other files updated" eq "$(cat "$dir/README.md")" "readme 2"
  check "a file removed upstream is removed" test ! -e "$dir/old.txt"
  check "live qBittorrent.conf kept" eq "$(cat "$dir/$q")" "$(printf '[LIVE]\nWebUI\\Port=8999')"
  check "its owner and mode kept" eq "$(stat -c '%u:%g %a' "$dir/$q")" "1000:1000 600"
  check "a deleted seed stays deleted" test ! -e "$dir/$j"
  check "a live file that upstream now tracks is kept" eq "$(cat "$dir/$cat")" "live categories"
  check "says the live configs were kept" grep -qF "your live configs were kept" "$WORK/r7.log"
  check "nothing to do: no error" gupd ""
  check "  and says so" grep -qF "already up to date" "$WORK/r7.log"
  echo "readme 3" >"$up/README.md"
  "${g[@]}" -C "$up" commit -qam "c3"
  echo "my edit" >>"$dir/README.md"
  check_not "a hand-edited file the update changes: refused" gupd ""
  check "  and named" grep -qF "README.md" "$WORK/r7.log"
  check "  and left as it was" grep -qF "my edit" "$dir/README.md"
  git -C "$dir" checkout -q -- README.md
  echo "seed 3" >"$up/$q"
  "${g[@]}" -C "$up" commit -qam "c4" && "${g[@]}" -C "$up" tag v3
  check "TS_REF=<tag> switch succeeds" gupd v3
  check "detached at the tag's commit" eq "$(git -C "$dir" rev-parse HEAD)" "$(git -C "$up" rev-parse 'v3^{commit}')"
  check "live qBittorrent.conf kept after the tag switch" eq "$(head -n1 "$dir/$q")" "[LIVE]"
  check_not "a failing update fails" gupd no-such-ref
  check "live file untouched after a failed update" eq "$(stat -c '%u:%g %a' "$dir/$q"):$(head -n1 "$dir/$q")" "1000:1000 600:[LIVE]"
}

# R8: a first run that stops early, then --resume exactly as the hint says.
resume_tests() {
  local st exec_cmds
  scenario "R8 first run stops waiting for the network; --resume keeps every answer"
  local dl="$WORK/hostdl-r8"
  rm -rf "$dl"
  st=/root/torrent-stack-9110-settings.env
  run_installer PATH="$FAST:$BIN:$PATH" PCT_SHIM_NO_IP=1 TS_UNATTENDED=1 TS_CTID=9110 TS_REF=feature-x \
    TS_PUID=1001 TS_PGID=1002 TS_TZ=Europe/Berlin TS_DOWNLOADS_HOST_PATH="$dl" TS_DOWNLOADS_MAPPING=idmap \
    TS_ROOT_PASSWORD_FILE="$PW_FILE" --
  check "first run fails at the network" eq "$RC/$(contains "$OUT" "got no IPv4 address" && echo y)" "1/y"
  exec_cmds=$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)
  check "root password set before the network wait" eq "$(grep -c '^9110 -- chpasswd' <<<"$exec_cmds")" 1
  local gs="$STATE/pushed/9110/root__.torrent-stack-proxmox.env"
  check "answers copied in before the network wait" test -f "$gs"
  check "  PUID/PGID 1001/1002" eq "$(grep -E '^P[UG]ID=' "$gs" | tr '\n' ' ')" "PUID=1001 PGID=1002 "
  check "  TZ Europe/Berlin" grep -qx 'TZ=Europe/Berlin' "$gs"
  check "  DOWNLOADS_PATH" grep -qx 'DOWNLOADS_PATH=/mnt/downloads' "$gs"
  check "answers kept on the host" test -f "$st"
  check "host answers file is root-only" eq "$(stat -c '%a %u' "$st" 2>/dev/null)" "600 0"
  check_not "no password in the host answers file" grep -qF 'Corr3ct-Horse-Battery' "$st"
  check "hint keeps TS_REF" contains "$OUT" "TS_REF=feature-x bash"
  check "hint names the answers file" contains "$OUT" "$st"
  run_installer TS_UNATTENDED=1 -- --resume 9110
  check "--resume (no TS_* given) exit 0" eq "$RC" 0
  exec_cmds=$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)
  check "--resume cloned the saved branch" grep -qE '^9110 -- env -i .* /opt/torrent-stack https://github.com/rob-paprocki/qbittorrent-vpn-docker feature-x$' <<<"$exec_cmds"
  check "answers not pushed a second time" eq "$(grep -c '"pct-push-file", "argv": \["9110", "[^"]*settings.env"' "$STATE/calls.jsonl")" 1
  check "password not set a second time" eq "$(grep -c '^9110 -- chpasswd' <<<"$exec_cmds")" 1
  check_not "no 'worked out from its config' guess" contains "$OUT" "worked out from its config"
  check "answers file removed once finished" test ! -e "$st"

  scenario "R8b container does not start; --resume rebuilds the answers from the host file"
  dl="$WORK/hostdl-r8b"
  rm -rf "$dl"
  st=/root/torrent-stack-9111-settings.env
  run_installer PCT_SHIM_START_FAIL=1 TS_UNATTENDED=1 TS_CTID=9111 TS_PUID=1003 TS_PGID=1004 TS_TZ=Asia/Tokyo \
    TS_DOWNLOADS_HOST_PATH="$dl" TS_SOURCE_DIR="$SRC" TS_ROOT_PASSWORD_FILE="$PW_FILE" --
  check "first run fails at pct start" eq "$RC/$(contains "$OUT" "pct start 9111 failed" && echo y)" "1/y"
  check "hint keeps TS_SOURCE_DIR" contains "$OUT" "TS_SOURCE_DIR=$SRC bash"
  check "host file notes the password is still to be set" grep -qx 'S_ROOT_PW_PENDING=1' "$st"
  run_installer TS_UNATTENDED=1 -- --resume 9111
  check "--resume exit 0" eq "$RC" 0
  gs="$STATE/pushed/9111/root__.torrent-stack-proxmox.env"
  check "answers rebuilt from the host file: PUID/PGID 1003/1004" eq "$(grep -E '^P[UG]ID=' "$gs" | tr '\n' ' ')" "PUID=1003 PGID=1004 "
  check "  TZ Asia/Tokyo" grep -qx 'TZ=Asia/Tokyo' "$gs"
  check "  DOWNLOADS_PATH" grep -qx 'DOWNLOADS_PATH=/mnt/downloads' "$gs"
  check "used the saved TS_SOURCE_DIR" test -f "$STATE/pushed/9111/root__torrent-stack-src.tar.gz"
  check "warns that the chosen root password was never set" contains "$OUT" "root password you chose was never set"

  scenario "R8c no host file (idmap): --resume works the answers out from the config"
  dl="$WORK/hostdl-r8c"
  rm -rf "$dl"
  run_installer PCT_SHIM_START_FAIL=1 TS_UNATTENDED=1 TS_CTID=9112 TS_PUID=1005 TS_PGID=1006 TS_TZ=Europe/Paris \
    TS_DOWNLOADS_HOST_PATH="$dl" TS_DOWNLOADS_MAPPING=idmap TS_SOURCE_DIR="$SRC" --
  check "first run fails at pct start" eq "$RC" 1
  rm -f /root/torrent-stack-9112-settings.env
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" TS_ROOT_PASSWORD_FILE="$PW_FILE" -- --resume 9112
  check "--resume exit 0" eq "$RC" 0
  gs="$STATE/pushed/9112/root__.torrent-stack-proxmox.env"
  check "PUID/PGID from the lxc.idmap lines" eq "$(grep -E '^P[UG]ID=' "$gs" | tr '\n' ' ')" "PUID=1005 PGID=1006 "
  check "TZ from the container's timezone" grep -qx 'TZ=Europe/Paris' "$gs"
  check "says it guessed" contains "$OUT" "worked out from its config"
  check "TS_ROOT_PASSWORD_FILE on --resume sets the password" eq "$(grep -c '^9112 -- chpasswd' <<<"$(python3 -I "$HERE/lib/calls.py" "$STATE" exec-cmds)")" 1

  scenario "R8d no host file (shift): --resume reads PUID/PGID from the folder owner"
  dl="$WORK/hostdl-r8d"
  rm -rf "$dl"
  run_installer PCT_SHIM_START_FAIL=1 TS_UNATTENDED=1 TS_CTID=9113 TS_PUID=1007 TS_PGID=1008 \
    TS_DOWNLOADS_HOST_PATH="$dl" TS_SOURCE_DIR="$SRC" --
  check "first run fails at pct start" eq "$RC" 1
  rm -f /root/torrent-stack-9113-settings.env
  run_installer TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --resume 9113
  check "--resume exit 0" eq "$RC" 0
  gs="$STATE/pushed/9113/root__.torrent-stack-proxmox.env"
  check "PUID/PGID from 101007:101008 on the host" eq "$(grep -E '^P[UG]ID=' "$gs" | tr '\n' ' ')" "PUID=1007 PGID=1008 "
}

# R9: downloads folders are checked as their real path.
path_tests() {
  local before
  scenario "R9 downloads folder: real path checked, symlinks cannot redirect chown"
  before=$(ncalls pct create)
  run_installer TS_UNATTENDED=1 TS_DOWNLOADS_HOST_PATH=// TS_SOURCE_DIR="$SRC" --
  check "'//' (the host's /) refused" eq "$RC/$(contains "$OUT" "downloads folder '/'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_DOWNLOADS_HOST_PATH=/./etc/ TS_SOURCE_DIR="$SRC" --
  check "'/./etc/' refused as /etc" eq "$RC/$(contains "$OUT" "downloads folder '/etc'" && echo y)" "1/y"
  run_installer TS_UNATTENDED=1 TS_DOWNLOADS_HOST_PATH=/var/lib/pve-cluster TS_SOURCE_DIR="$SRC" --
  check "a folder under /var refused" eq "$RC" 1
  rm -rf "$WORK/etc-link" "$WORK/dl-trap" "$WORK/victim" "$WORK/dl-real" "$WORK/dl-link"
  ln -s /etc "$WORK/etc-link"
  run_installer TS_UNATTENDED=1 TS_DOWNLOADS_HOST_PATH="$WORK/etc-link/dl" TS_SOURCE_DIR="$SRC" --
  check "a symlink into /etc refused" eq "$RC/$(contains "$OUT" "downloads folder '/etc/dl'" && echo y)" "1/y"
  check "/etc/dl not created" test ! -e /etc/dl
  mkdir -p "$WORK/dl-trap" "$WORK/victim"
  ln -s "$WORK/victim" "$WORK/dl-trap/incomplete"
  run_installer TS_UNATTENDED=1 TS_DOWNLOADS_HOST_PATH="$WORK/dl-trap" TS_SOURCE_DIR="$SRC" --
  check "incomplete/ as a symlink refused" eq "$RC/$(contains "$OUT" "incomplete is a symbolic link" && echo y)" "1/y"
  check "symlink target not chowned" eq "$(stat -c %u:%g "$WORK/victim")" "0:0"
  check "no container created by these refusals" eq "$(ncalls pct create)" "$before"
  mkdir -p "$WORK/dl-real"
  ln -s "$WORK/dl-real" "$WORK/dl-link"
  run_installer TS_UNATTENDED=1 TS_CTID=9114 TS_DOWNLOADS_HOST_PATH="$WORK/dl-link/" TS_SOURCE_DIR="$SRC" --
  check "a symlink to a normal folder works" eq "$RC" 0
  check "mp0 uses the real path" eq "$(opt mp0)" "$(realpath "$WORK/dl-real"),mp=/mnt/downloads"
  check "the real folder got the owner" eq "$(stat -c %u:%g "$WORK/dl-real")" "101000:101000"
  check "the link itself untouched" eq "$(stat -c %u:%g "$WORK/dl-link")" "0:0"
}

# R10: validators called directly (install.sh is sourced in a subshell).
validator_tests() {
  scenario "R10 hostname and DNS checks do not expand * against files"
  local gd="$WORK/globdir"
  mkdir -p "$gd"
  : >"$gd/backups"
  : >"$gd/notes"
  : >"$gd/1.1.1.1"
  vcall() { (cd "$gd" && bash -c 'source "$1" && "$2" "$3"' _ "$INSTALLER" "$@") >/dev/null 2>&1; }
  local h
  for h in '*' 'b*' '?otes' 'a..b' '-x' 'Upper' 'a_b'; do check_not "hostname '$h' refused" vcall valid_hostname "$h"; done
  for h in torrent-stack media.lan; do check "hostname '$h' accepted" vcall valid_hostname "$h"; done
  check_not "DNS '1*' refused (no file-name expansion)" vcall valid_dns_or_empty '1*'
  check "DNS '1.1.1.1 9.9.9.9' accepted" vcall valid_dns_or_empty '1.1.1.1 9.9.9.9'
  local p
  for p in // //etc /./etc /root/. /var/lib/vz/. /usr/./ /var/log /usr/local /boot/efi /mnt/pve/nas \
    /rpool/data/subvol-101-disk-0/dl /mnt/pve/nas/images/101 /tank/a,b /tank/a=b /tank/a:b 'relative'; do
    check_not "downloads '$p' refused" vcall valid_host_path_or_empty "$p"
  done
  for p in /tank/downloads /mnt/pve/nas/downloads /var/lib/vz/downloads /home/rob/dl; do
    check "downloads '$p' accepted" vcall valid_host_path_or_empty "$p"
  done
}

# ---------------------------------------------------------------------------
# Incus-backed scenarios: the hand-off runs in a real Debian 13 container
# ---------------------------------------------------------------------------
gx() { incus exec "${PX}$1" -- "${@:2}"; }

incus_tests_1() {
  BACKEND=incus
  local id=9301 dl="$WORK/hostdl-incus"
  reset_state
  incus delete --force "${PX}$id" >/dev/null 2>&1 || true
  rm -rf "$dl"

  scenario "I1 full hand-off in a real Debian 13 container (TS_SOURCE_DIR)"
  PVE_SHIM_TZ=America/Chicago run_installer PVE_SHIM_VERSION=9.2.13 TS_UNATTENDED=1 TS_CTID=$id TS_SOURCE_DIR="$SRC" \
    TS_ROOT_PASSWORD_FILE="$PW_FILE" TS_SSH_KEY_FILE="$KEY_FILE" TS_DOWNLOADS_HOST_PATH="$dl" --
  check "exit 0" eq "$RC" 0
  if [[ "$RC" != 0 ]]; then
    tail -n 40 <<<"$OUT"
    incus delete --force "${PX}$id" >/dev/null 2>&1 || true
    return
  fi
  local log
  log=$(gx $id cat /root/native-stub.log 2>/dev/null || true)
  check "native/install.sh install ran in the guest" contains "$log" "=== args: install"
  check "guest env: TZ" grep -qx 'TZ=America/Chicago' <<<"$log"
  check "guest env: PUID/PGID" eq "$(grep -cxE 'P[UG]ID=1000' <<<"$log")" 2
  check "guest env: DOWNLOADS_PATH" grep -qx 'DOWNLOADS_PATH=/mnt/downloads' <<<"$log"
  check "guest env: INCOMPLETE_DOWNLOADS" grep -qx 'INCOMPLETE_DOWNLOADS=/mnt/downloads/incomplete' <<<"$log"
  check "guest env: LANG=C.UTF-8" grep -qx 'LANG=C.UTF-8' <<<"$log"
  check_not "guest env: no host variables leak in" grep -qE '^(PVE_SHIM_STATE|TS_SOURCE_DIR|TS_ROOT_PASSWORD_FILE)=' <<<"$log"
  check "repo at /opt/torrent-stack" gx $id test -f /opt/torrent-stack/compose.yaml
  check "has .env.example" gx $id test -f /opt/torrent-stack/.env.example
  check "has platforms/proxmox/install.sh" gx $id test -f /opt/torrent-stack/platforms/proxmox/install.sh
  local x
  for x in .git .env .env.bak configs downloads incomplete scripts/env-editor/.venv scripts/env-editor/__pycache__; do
    check_not "guest has no $x" gx $id test -e "/opt/torrent-stack/$x"
  done
  check "files are root-owned in the guest" eq "$(gx $id stat -c %u /opt/torrent-stack/compose.yaml)" 0
  check "tarball removed after unpacking" eq "$(gx $id sh -c 'ls /root/torrent-stack-src.tar.gz 2>/dev/null | wc -l')" 0
  check "/dev/net/tun is char 10:200" eq "$(gx $id stat -c '%F %t:%T' /dev/net/tun)" "character special file a:c8"
  check "a tun interface can be created (what Gluetun does)" gx $id sh -c 'ip tuntap add mode tun dev tsttun0 && ip link del tsttun0'
  check "systemd is running (nesting=1)" grep -qE '^(running|degraded)$' <<<"$(gx $id systemctl is-system-running 2>/dev/null || true)"
  check "security.nesting=true" eq "$(incus config get ${PX}$id security.nesting)" true
  check "limits.cpu=2" eq "$(incus config get ${PX}$id limits.cpu)" 2
  check "root password set" grep -qE '^root:\$' <<<"$(gx $id cat /etc/shadow)"
  check "authorized_keys installed" eq "$(gx $id cat /root/.ssh/authorized_keys)" "$(grep '^ssh-' "$KEY_FILE")"
  check "settings file mode 600" eq "$(gx $id stat -c %a /root/.torrent-stack-proxmox.env)" 600
  check "hostname" eq "$(gx $id cat /etc/hostname)" torrent-stack
  check "timezone link" eq "$(gx $id readlink /etc/localtime)" /usr/share/zoneinfo/America/Chicago
  check "downloads bind mount present" gx $id test -d /mnt/downloads/incomplete
  local ip
  ip=$(incus list "^${PX}$id\$" -c 4 -f csv | awk '{print $1}')
  check "summary prints env-editor URL with the guest IP" contains "$OUT" "env-editor: http://${ip}:9191"
  check "summary repeats the login from the guest's creds file" contains "$OUT" "saved in /root/torrent-stack.creds in the container"
  check "summary shows that login" contains "$OUT" "user: admin   password: StubPassw0rd-xyz"
  check "description set" grep -q "^#<div align='center'>" "/etc/pve/lxc/$id.conf"
  check "no install log kept on success" test ! -e "/root/torrent-stack-$id-install.log"

  scenario "I1b host-side --update"
  run_installer PVE_SHIM_VERSION=9.2.13 TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --update $id
  check "exit 0" eq "$RC" 0
  log=$(gx $id cat /root/native-stub.log)
  check "native update ran" contains "$log" "=== args: update"
  check "native status ran" contains "$log" "=== args: status"
  check "status shown" contains "$OUT" "env-editor    active"

  scenario "I1c update from inside the container (no pct there)"
  RC=0
  OUT=$(gx $id bash /opt/torrent-stack/platforms/proxmox/install.sh --update 2>&1) || RC=$?
  check "exit 0" eq "$RC" 0
  check "notes the copied (non-git) checkout" contains "$OUT" "not a git checkout"
  check "ran native update in place" eq "$(gx $id grep -c '=== args: update' /root/native-stub.log)" 2
  RC=0
  OUT=$(gx $id bash /opt/torrent-stack/platforms/proxmox/install.sh 2>&1) || RC=$?
  check "create inside the container refused" eq "$RC/$(contains "$OUT" "only --update works" && echo y)" "1/y"

  scenario "I1d uninstall = pct destroy (bind-mounted data stays)"
  echo "keep me" >"$dl/finished.mkv"
  pct_ stop $id && pct_ destroy $id --purge 1
  check "container gone" test -z "$(incus list "^${PX}$id\$" -c n -f csv)"
  check "host downloads kept" test -f "$dl/finished.mkv"
}

pct_() { env PATH="$BIN:$PATH" PVE_SHIM_STATE="$STATE" PVE_SHIM_APIDOC="$APIDOC" PCT_SHIM_BACKEND=incus pct "$@"; }

incus_tests_2() {
  BACKEND=incus
  local id=9302
  reset_state
  incus delete --force "${PX}$id" >/dev/null 2>&1 || true
  scenario "I2 PVE 8.0 legacy tun + git clone path; failure then --resume"
  run_installer PVE_SHIM_VERSION=8.0.4 TS_UNATTENDED=1 TS_CTID=$id TS_REF=main --
  check "fails: upstream main has no native/ yet" eq "$RC/$(contains "$OUT" "native/install.sh not found" && echo y)" "1/y"
  check "prints the --resume hint" contains "$OUT" "install.sh --resume $id"
  check "the hint keeps TS_REF=main" contains "$OUT" "TS_REF=main bash"
  check "answers kept on the host for --resume" test -f "/root/torrent-stack-$id-settings.env"
  if [[ "$(stat -c %a /dev/net/tun)" != 666 ]]; then
    check "warns that this host's /dev/net/tun is not 0666" contains "$OUT" "is mode $(stat -c %a /dev/net/tun), not 666"
  fi
  check "container kept for --resume" test -n "$(incus list "^${PX}$id\$" -c n -f csv)"
  check "git clone landed in /opt/torrent-stack" gx $id test -d /opt/torrent-stack/.git
  check "git, curl, ca-certificates installed" gx $id sh -c 'command -v git && command -v curl && test -d /etc/ssl/certs'
  check "legacy raw lxc lines give a usable tun" gx $id sh -c 'ip tuntap add mode tun dev tsttun0 && ip link del tsttun0'
  check "failure log kept root-only" eq "$(stat -c %a "/root/torrent-stack-$id-install.log" 2>/dev/null)" 600
  rm -f "/root/torrent-stack-$id-install.log"
  gx $id sh -c 'mkdir -p /opt/torrent-stack/native && touch /opt/torrent-stack/native/NO_CREDS_FILE'
  run_installer PVE_SHIM_VERSION=8.0.4 TS_UNATTENDED=1 TS_SOURCE_DIR="$SRC" -- --resume $id
  check "--resume completes" eq "$RC" 0
  check "answers file removed once finished" test ! -e "/root/torrent-stack-$id-settings.env"
  check "without a creds file the login comes from the installer output" contains "$OUT" "first-run login:      user admin   password StubPassw0rd-xyz"
  check "--resume ran native install" contains "$(gx $id cat /root/native-stub.log)" "=== args: install"

  scenario "I2b --update on a git checkout: native self-update (git step, then update)"
  run_installer PVE_SHIM_VERSION=8.0.4 TS_UNATTENDED=1 -- --update $id
  check "exit 0" eq "$RC" 0
  check "pulled from git" contains "$OUT" "Repository already up to date"
  check "native update ran" contains "$(gx $id cat /root/native-stub.log)" "=== args: update"
  RC=0
  OUT=$(gx $id bash /opt/torrent-stack/platforms/proxmox/install.sh --update 2>&1) || RC=$?
  check "in-guest update on a git checkout: exit 0" eq "$RC" 0
  check "in-guest update pulled" contains "$OUT" "Repository already up to date"
  check "in-guest update ran native update" eq "$(gx $id grep -c '=== args: update' /root/native-stub.log)" 2

  scenario "I2c --update keeps the live qBittorrent.conf when upstream changes the seed"
  # An "upstream" inside the guest (a copy of the real clone) whose new
  # commit changes the tracked seed; the live file is what the apps would
  # have written, owned by the torrent user. The real-main clone tracks the
  # seed at configs/qbittorrent/qBittorrent/qBittorrent.conf.
  local q=configs/qbittorrent/qBittorrent/qBittorrent.conf
  # shellcheck disable=SC2016  # runs in the guest
  local mk_upstream='set -e
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
q=$1 msg=$2
if [ ! -d /srv/up.git ]; then
  git clone -q --bare /opt/torrent-stack /srv/up.git
  git -C /opt/torrent-stack remote set-url origin file:///srv/up.git
fi
rm -rf /srv/up-work
git clone -q file:///srv/up.git /srv/up-work
printf "[Upstream]\nchange=%s\n" "$msg" >>"/srv/up-work/$q"
git -C /srv/up-work -c user.name=t -c user.email=t@example.invalid commit -qam "$msg"
git -C /srv/up-work push -q origin HEAD:main
printf "[LIVE]\nWebUI\\\\Port=8999\n" >"/opt/torrent-stack/$q"
chown 1000:1000 "/opt/torrent-stack/$q"
chmod 600 "/opt/torrent-stack/$q"'
  check "guest has the tracked seed" gx $id test -f "/opt/torrent-stack/$q"
  check "made an upstream commit that changes the seed" gx $id bash -c "$mk_upstream" bash "$q" "seed change one"
  run_installer PVE_SHIM_VERSION=8.0.4 TS_UNATTENDED=1 -- --update $id
  check "host-side --update exit 0" eq "$RC" 0
  check "guest moved to the new upstream commit" eq "$(gx $id git -C /opt/torrent-stack log -1 --format=%s)" "seed change one"
  check "live qBittorrent.conf kept" eq "$(gx $id head -n1 "/opt/torrent-stack/$q")" "[LIVE]"
  check "its owner and mode kept" eq "$(gx $id stat -c '%u:%g %a' "/opt/torrent-stack/$q")" "1000:1000 600"
  check "made a second upstream commit" gx $id bash -c "$mk_upstream" bash "$q" "seed change two"
  RC=0
  OUT=$(gx $id bash /opt/torrent-stack/platforms/proxmox/install.sh --update 2>&1) || RC=$?
  check "in-guest --update exit 0" eq "$RC" 0
  check "in-guest update moved to the second commit" eq "$(gx $id git -C /opt/torrent-stack log -1 --format=%s)" "seed change two"
  check "live qBittorrent.conf still kept" eq "$(gx $id stat -c '%u:%g %a' "/opt/torrent-stack/$q"):$(gx $id head -n1 "/opt/torrent-stack/$q")" "1000:1000 600:[LIVE]"
  check "pct calls valid per Proxmox API schema" python3 -I "$HERE/lib/calls.py" "$STATE" validate "$APIDOC"
  pct_ stop $id && pct_ destroy $id --purge 1
  check "container gone" test -z "$(incus list "^${PX}$id\$" -c n -f csv)"
}

case "$WHAT" in
record) record_tests ;;
incus1) incus_tests_1 ;;
incus2) incus_tests_2 ;;
incus)
  incus_tests_1
  incus_tests_2
  ;;
all)
  record_tests
  incus_tests_1
  incus_tests_2
  ;;
*)
  echo "usage: $0 [record|incus|incus1|incus2|all]" >&2
  exit 2
  ;;
esac

echo
echo "=== ${PASS} passed, ${FAILS} failed (outputs in ${WORK})"
for f in ${FAILED[@]+"${FAILED[@]}"}; do echo "  FAILED: $f"; done
((FAILS == 0))
