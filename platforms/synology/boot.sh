#!/bin/bash
#
# platforms/synology/boot.sh
#
# Purpose: runs as root at every DSM boot, from the Task Scheduler task
# "Torrent stack boot" that platforms/synology/install.sh creates (Control
# Panel > Task Scheduler). It does two things:
#
#   1. Makes sure /dev/net/tun exists. Gluetun needs it, and DSM does not
#      always load the tun kernel module at boot. Without it Docker refuses
#      to create or start the gluetun container.
#   2. Waits for Container Manager, then checks the stack. At boot Container
#      Manager starts containers one by one and ignores depends_on, so
#      qBittorrent, Jackett and FlareSolverr (which live inside gluetun's
#      network) can fail to start, or come up before gluetun and be left
#      with no network. Docker never retries a container that failed to
#      start. When the stack is only half up, this runs `docker compose up -d`
#      for it (the same compose Container Manager uses) and recreates any app
#      that is not inside gluetun's current network.
#
#   A stack you stopped yourself (Container Manager > Project > Stop) is left
#   alone, and so is one whose VPN keys are still the .env.example
#   placeholders. So is one whose compose.yaml, .env or update-qbittorrent.sh
#   someone other than root could change: this runs as root, and so do the
#   containers compose would start from them.
#
#   The task itself runs this script only while root owns it and no one else
#   can write to it (see boot_command in install.sh), and loads tun on its own
#   otherwise.
#
# Usage (as root):  bash boot.sh [--tun-only] [--now] [--dry-run]
#   --tun-only   only step 1 (install.sh uses this to load tun right away)
#   --now        skip the wait for Container Manager's own start at boot
#   --dry-run    say what would be done, change nothing
# Log: /var/log/torrent-stack-boot.log (DSM's system log drops logger lines).
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)
#
# Loading tun from a Task Scheduler boot-up task is the long-standing
# Synology community method; the boot-order problem in step 2 is described
# in the field report linked from platforms/synology/README.md (References).
# Nothing is downloaded or sourced at run time.

# No `set -e`: at boot it is better to log a failed step and carry on (tun
# first, then the stack) than to stop at the first error.
set -Euo pipefail

readonly STACK="torrent-stack"
# Apps that share gluetun's network (network_mode: service:gluetun).
readonly APPS_IN_GLUETUN=(qbittorrent jackett flaresolverr)
readonly SERVICES=(gluetun qbittorrent jackett flaresolverr filebrowser)
# Container Manager starts containers about 5 s apart; give it time to
# finish before judging what it left behind.
readonly SETTLE_SECONDS=120
readonly DOCKER_WAIT_SECONDS=600
readonly LOG="/var/log/torrent-stack-boot.log"
readonly LOCK="/var/run/torrent-stack-boot.lock"

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STACK_DIR="$(cd "$HERE/../.." && pwd)"
ENV_FILE="$STACK_DIR/.env"
EXAMPLE_FILE="$STACK_DIR/.env.example"
COMPOSE_FILE="$STACK_DIR/compose.yaml"

# Task Scheduler runs scripts with a short PATH; docker lives in
# /usr/local/bin and Synology's own tools in /usr/syno/bin.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/syno/sbin:/usr/syno/bin:/sbin:/bin:/usr/sbin:/usr/bin${PATH:+:$PATH}"

TUN_ONLY=0
NOW=0
DRY_RUN=0
while (($#)); do
  case "$1" in
    --tun-only) TUN_ONLY=1 ;;
    --now) NOW=1 ;;
    --dry-run) DRY_RUN=1 ;;
    -h | --help)
      sed -n '3,35p' "${BASH_SOURCE[0]}"
      exit 0
      ;;
    *)
      echo "boot.sh: unknown option: $1 (see --help)" >&2
      exit 2
      ;;
  esac
  shift
done

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log() {
  local line
  line="$(date '+%Y-%m-%d %H:%M:%S') $*"
  printf '%s\n' "$line"
  if [[ "$DRY_RUN" != 1 ]]; then
    printf '%s\n' "$line" >>"$LOG" 2>/dev/null || true
  fi
}

# Keep the log small: it gets a few lines per boot.
trim_log() {
  [[ "$DRY_RUN" != 1 && -f "$LOG" ]] || return 0
  local lines
  lines=$(wc -l <"$LOG" 2>/dev/null) || return 0
  if ((lines > 2000)); then
    tail -n 1000 "$LOG" >"$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
  return 0
}

# run CMD...: run a command, or only log it in --dry-run.
run() {
  if [[ "$DRY_RUN" == 1 ]]; then
    log "dry-run: would run: $*"
    return 0
  fi
  "$@"
}

# run_logged CMD...: like run, and copy the command's output into the log.
run_logged() {
  if [[ "$DRY_RUN" == 1 ]]; then
    log "dry-run: would run: $*"
    return 0
  fi
  local out rc=0 line
  out=$("$@" 2>&1) || rc=$?
  if [[ -n "$out" ]]; then
    while IFS= read -r line; do log "    $line"; done <<<"$out"
  fi
  return "$rc"
}

# ---------------------------------------------------------------------------
# Step 1: the tun device
# ---------------------------------------------------------------------------
ensure_tun() {
  if [[ -c /dev/net/tun ]]; then
    log "tun: /dev/net/tun is present"
    return 0
  fi
  log "tun: /dev/net/tun is missing; loading the tun kernel module"
  if [[ ! -d /sys/module/tun ]]; then
    if [[ -f /lib/modules/tun.ko ]]; then
      # DSM keeps its kernel modules directly in /lib/modules, and insmod
      # with the full path works on every DSM 7 model.
      run insmod /lib/modules/tun.ko || log "tun: insmod /lib/modules/tun.ko failed"
    else
      run modprobe tun || log "tun: modprobe tun failed"
    fi
  fi
  if [[ "$DRY_RUN" != 1 && ! -c /dev/net/tun ]]; then
    # The module is loaded but nothing created the device node: make the
    # standard one (character device 10:200).
    log "tun: creating the device node /dev/net/tun"
    if ! { mkdir -p /dev/net && mknod -m 666 /dev/net/tun c 10 200; }; then
      log "tun: mknod failed"
    fi
  fi
  if [[ "$DRY_RUN" == 1 ]]; then
    log "tun: dry run, nothing loaded"
    return 0
  fi
  if [[ -c /dev/net/tun ]]; then
    log "tun: /dev/net/tun is ready"
    return 0
  fi
  log "tun: ERROR: /dev/net/tun is still missing; Gluetun cannot start."
  return 1
}

# ---------------------------------------------------------------------------
# Step 2: the stack
# ---------------------------------------------------------------------------

# env_get FILE KEY: KEY's value with surrounding quotes removed.
env_get() {
  local file=$1 key=$2 line val
  [[ -f "$file" ]] || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%$'\r'}"
    [[ "$line" =~ ^[[:space:]]*${key}[[:space:]]*=(.*)$ ]] || continue
    val="${BASH_REMATCH[1]}"
    val="${val#"${val%%[![:space:]]*}"}"
    val="${val%"${val##*[![:space:]]}"}"
    if [[ ${#val} -ge 2 && ( "${val:0:1}" == "'" || "${val:0:1}" == '"' ) && "${val: -1}" == "${val:0:1}" ]]; then
      val="${val:1:${#val}-2}"
    fi
    printf '%s' "$val"
    return 0
  done <"$file"
}

# is_set KEY: the .env value is filled in (not empty, not the placeholder).
is_set() {
  local v
  v=$(env_get "$ENV_FILE" "$1")
  [[ -n "$v" && "$v" != "$(env_get "$EXAMPLE_FILE" "$1")" ]]
}

# root_only FILE: owned by root and not writable by its group or others.
root_only() {
  case "$(stat -c '%u %A' "$1" 2>/dev/null)" in
    '0 '?????w* | '0 '????????w*) return 1 ;;
    '0 '*) return 0 ;;
    *) return 1 ;;
  esac
}

vpn_ready() {
  if [[ "$(env_get "$ENV_FILE" VPN_TYPE)" == openvpn ]]; then
    is_set OPENVPN_USER && is_set OPENVPN_PASSWORD
  else
    is_set WIREGUARD_PRIVATE_KEY && is_set WIREGUARD_ADDRESSES
  fi
}

wait_for_docker() {
  local waited=0
  until docker info >/dev/null 2>&1; do
    if ((waited >= DOCKER_WAIT_SECONDS)); then
      log "docker: not running after ${DOCKER_WAIT_SECONDS}s (is Container Manager started?); giving up"
      return 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  log "docker: running"
}

COMPOSE=()
# Container Manager 24.0.2-1543 and later have `docker compose`; older ones
# only the standalone docker-compose.
pick_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE=(docker-compose)
  else
    return 1
  fi
}

compose() {
  "${COMPOSE[@]}" -p "$STACK" -f "$COMPOSE_FILE" --env-file "$ENV_FILE" "$@"
}

# container_of SERVICE: full id of the stack's container for SERVICE.
container_of() {
  local ids
  ids=$(docker ps -aq --no-trunc --filter "label=com.docker.compose.project=${STACK}" \
    --filter "label=com.docker.compose.service=$1" 2>/dev/null) || ids=""
  printf '%s' "${ids%%$'\n'*}"
}

is_running() {
  [[ "$(docker inspect -f '{{.State.Running}}' "$1" 2>/dev/null)" == true ]]
}

# netns_of ID: the network namespace a running container's process is in.
netns_of() {
  local pid
  pid=$(docker inspect -f '{{.State.Pid}}' "$1" 2>/dev/null) || return 1
  [[ "$pid" =~ ^[1-9][0-9]*$ ]] || return 1
  readlink "/proc/${pid}/ns/net" 2>/dev/null
}

# stopped_by_hand ID: Docker marks a container it was told to stop (docker
# stop, or Stop in Container Manager); it does not when it shuts down itself.
stopped_by_hand() {
  local root
  root=$(docker info -f '{{.DockerRootDir}}' 2>/dev/null) || return 1
  grep -q '"HasBeenManuallyStopped":true' "${root}/containers/$1/config.v2.json" 2>/dev/null
}

# assess: set STATE (absent | stopped | down | partial | ok), DETAIL and
# STALE (running apps that are not inside gluetun's network).
STATE=""
DETAIL=""
STALE=()
assess() {
  STATE="" DETAIL="" STALE=()
  local svc id gl_id gl_ns ns any=0
  local -a running=() down=()
  for svc in "${SERVICES[@]}"; do
    id=$(container_of "$svc")
    if [[ -z "$id" ]]; then
      down+=("${svc}(missing)")
      continue
    fi
    any=1
    if is_running "$id"; then running+=("$svc"); else down+=("$svc"); fi
  done
  if ((any == 0)); then
    STATE=absent
    return 0
  fi
  gl_id=$(container_of gluetun)
  if ((${#running[@]} == 0)); then
    if [[ -n "$gl_id" ]] && stopped_by_hand "$gl_id"; then
      STATE=stopped
    else
      STATE=down
      DETAIL="nothing is running"
    fi
    return 0
  fi
  if [[ -n "$gl_id" ]] && is_running "$gl_id" && gl_ns=$(netns_of "$gl_id"); then
    for svc in "${APPS_IN_GLUETUN[@]}"; do
      id=$(container_of "$svc")
      if [[ -z "$id" ]] || ! is_running "$id"; then continue; fi
      ns=$(netns_of "$id") || continue
      [[ "$ns" == "$gl_ns" ]] || STALE+=("$svc")
    done
  fi
  if ((${#down[@]} == 0 && ${#STALE[@]} == 0)); then
    STATE=ok
    return 0
  fi
  STATE=partial
  DETAIL="not running: ${down[*]:-none}; outside gluetun's network: ${STALE[*]:-none}"
}

heal() {
  log "stack: docker compose up -d"
  run_logged compose up -d || log "stack: docker compose up -d failed (output above)"
  if [[ "$DRY_RUN" != 1 ]]; then
    assess
  fi
  if ((${#STALE[@]})); then
    log "stack: recreating ${STALE[*]} inside gluetun's network"
    run_logged compose up -d --no-deps --force-recreate "${STALE[@]}" ||
      log "stack: recreating ${STALE[*]} failed (output above)"
  fi
}

main() {
  if [[ "$DRY_RUN" != 1 ]] && command -v flock >/dev/null 2>&1; then
    exec 9>"$LOCK"
    flock -n 9 || {
      echo "boot.sh is already running; exiting."
      exit 0
    }
  fi
  trim_log
  log "boot.sh: start (stack folder ${STACK_DIR}$([[ "$DRY_RUN" == 1 ]] && echo ', dry run'))"
  local rc=0 attempt
  ensure_tun || rc=1
  ((TUN_ONLY == 0)) || exit "$rc"

  if [[ ! -f "$COMPOSE_FILE" || ! -f "$ENV_FILE" ]]; then
    log "stack: no compose.yaml or .env in ${STACK_DIR}; nothing to start"
    exit "$rc"
  fi
  if ! vpn_ready; then
    log "stack: the VPN keys in .env are still the placeholders; not starting it"
    exit "$rc"
  fi
  local f
  for f in "$COMPOSE_FILE" "$ENV_FILE" "$STACK_DIR/update-qbittorrent.sh"; do
    if ! root_only "$f"; then
      log "stack: ${f} is not root-only (owned by root, not writable by others); not running docker compose as root on it. Re-run install.sh --update to fix the files."
      exit 1
    fi
  done
  wait_for_docker || exit 1
  pick_compose || {
    log "docker compose is missing; update Container Manager in Package Center"
    exit 1
  }
  cd "$STACK_DIR" || exit 1
  if ((NOW == 0 && DRY_RUN == 0)); then
    log "waiting ${SETTLE_SECONDS}s for Container Manager to finish starting containers"
    sleep "$SETTLE_SECONDS"
  fi

  for attempt in 1 2 3; do
    assess
    case "$STATE" in
      absent)
        log "stack: no containers (not started yet, or removed with Clean); nothing to do"
        exit "$rc"
        ;;
      stopped)
        log "stack: stopped by hand; leaving it stopped"
        exit "$rc"
        ;;
      ok)
        log "stack: all services are running"
        exit "$rc"
        ;;
    esac
    log "stack: attempt ${attempt} of 3: ${DETAIL}"
    heal
    [[ "$DRY_RUN" != 1 ]] || exit "$rc"
    assess
    if [[ "$STATE" == ok ]]; then
      log "stack: all services are running"
      exit "$rc"
    fi
    ((attempt == 3)) || sleep 30
  done
  log "stack: ERROR: still not fully running after 3 attempts (${DETAIL:-$STATE}). Check Container Manager > Project > ${STACK}."
  exit 1
}

main
