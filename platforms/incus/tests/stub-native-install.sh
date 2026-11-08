#!/usr/bin/env bash
#
# platforms/incus/tests/stub-native-install.sh
#
# Purpose: test stand-in for native/install.sh, used by run-tests.sh. The
# test copies the repository to a temporary folder, puts this file at
# native/install.sh there and points TS_SOURCE_DIR at the copy, so
# platforms/incus/install.sh can be tested end to end without building the
# real stack. It:
#   * records every call (arguments and the environment the host script
#     passed) in /root/stub-calls.log inside the container;
#   * on "install" creates .env from .env.example (applying .env keys given
#     as environment variables, like the real installer), writes
#     /root/torrent-stack.creds in the real installer's format, and serves
#     a tiny web page on every web UI port from .env plus 9191, as systemd
#     services, so the proxy devices and LAN addresses can be checked;
#   * on "apply" re-reads the ports from .env and restarts those servers;
#   * on "self-update" runs the REAL installer's git step (git_update_checkout,
#     sourced from native/install.real.sh, which run-tests.sh puts there),
#     then its own "update".
# Each page says which service it stands for, its port and the client
# address the request came from.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOG=/root/stub-calls.log
CREDS=/root/torrent-stack.creds
SERVER=/root/stub-http.pl
STUB_PASSWORD="stub-password-123"
ENV_KEYS=(TZ PUID PGID DOWNLOADS_PATH INCOMPLETE_DOWNLOADS QBIT_WEBUI_PORT)

record() {
  local k
  {
    printf '=== %s args: %s\n' "$(date -u +%FT%TZ)" "$*"
    for k in "${ENV_KEYS[@]}" DEBIAN_FRONTEND http_proxy https_proxy; do
      [[ -n "${!k+x}" ]] && printf 'env %s=%s\n' "$k" "${!k}"
    done
    if { exec 3<>/dev/net/tun; } 2>/dev/null; then
      exec 3>&-
      echo "tun open-ok"
    else
      echo "tun open-failed"
    fi
  } >>"$LOG"
}

create_env() {
  [[ -f "$ROOT/.env" ]] && return 0
  cp "$ROOT/.env.example" "$ROOT/.env"
  local k
  for k in "${ENV_KEYS[@]}"; do
    if [[ -n "${!k+x}" ]]; then
      # Values here are plain (paths, ids, a time zone): no sed escaping needed
      # beyond the delimiter.
      sed -i "s|^${k}=.*|${k}=${!k}|" "$ROOT/.env"
      echo "    $k set from the environment"
    fi
  done
  chmod 0600 "$ROOT/.env"
}

# The last line for a key wins, as in the env-editor's parser (env_io.py).
port_of() { sed -n "s/^$1=//p" "$ROOT/.env" | tail -n1 | tr -d '"'; }

write_server() {
  cat >"$SERVER" <<'PERL'
#!/usr/bin/perl
# Minimal HTTP responder for the Incus installer tests.
use strict;
use warnings;
use IO::Socket::INET;
my ($port, $name) = @ARGV;
my $srv = IO::Socket::INET->new(LocalAddr => '0.0.0.0', LocalPort => $port,
    Proto => 'tcp', Listen => 16, ReuseAddr => 1) or die "listen $port: $!";
while (my $c = $srv->accept) {
    while (my $line = <$c>) { last if $line =~ /^\r?\n$/; }
    my $body = "stub $name on $port from " . $c->peerhost . "\n";
    print $c "HTTP/1.0 200 OK\r\nContent-Type: text/plain\r\nContent-Length: "
        . length($body) . "\r\n\r\n" . $body;
    close $c;
}
PERL
  chmod 0755 "$SERVER"
}

serve() {
  local name port
  for name in env-editor qbittorrent jackett flaresolverr filebrowser; do
    case "$name" in
    env-editor) port=9191 ;;
    qbittorrent) port=$(port_of QBIT_WEBUI_PORT) ;;
    jackett) port=$(port_of JACKETT_PORT) ;;
    flaresolverr) port=$(port_of FLARESOLVERR_PORT) ;;
    filebrowser) port=$(port_of FILEBROWSER_PORT) ;;
    esac
    systemctl stop "stub-${name}.service" 2>/dev/null || true
    systemctl reset-failed "stub-${name}.service" 2>/dev/null || true
    systemd-run --quiet --unit="stub-${name}" --property=Restart=always /usr/bin/perl "$SERVER" "$port" "$name"
  done
}

cmd=${1:-}
record "$@"
case "$cmd" in
install)
  echo "==> stub native install in $ROOT"
  create_env
  write_server
  serve
  if [[ ! -f "$CREDS" ]]; then
    ip=$(ip -4 -o addr show scope global | awk '{split($4, a, "/"); print a[1]; exit}')
    (
      umask 077
      cat >"$CREDS" <<EOF
# torrent-stack first-run logins (stub).
env-editor:  http://$ip:9191   user: admin   password: $STUB_PASSWORD
FileBrowser: http://$ip:$(port_of FILEBROWSER_PORT)   user: admin   password: $STUB_PASSWORD
EOF
    )
    echo "    first-run login:      user admin   password $STUB_PASSWORD"
  fi
  echo " ok Install finished (stub)."
  ;;
self-update)
  ref=""
  [[ "${2:-}" == --ref ]] && ref=${3:-}
  if [[ -d "$ROOT/.git" ]]; then
    # shellcheck source=/dev/null  # the real native/install.sh, copied by run-tests.sh
    source "$ROOT/native/install.real.sh"
    git_update_checkout "$ref"
  else
    echo "==> stub self-update: a copy, no git step"
  fi
  exec bash "$ROOT/native/install.sh" update
  ;;
update)
  echo "==> stub native update, source version $(cat "$ROOT/native/STUB_VERSION" 2>/dev/null || echo none)"
  ;;
apply)
  serve
  echo " ok applied (stub)"
  ;;
status)
  for name in env-editor qbittorrent jackett flaresolverr filebrowser; do
    printf '%-14s %s\n' "$name" "$(systemctl is-active "stub-${name}.service" 2>/dev/null || true)"
  done
  ;;
*)
  echo "stub: unknown command $cmd" >&2
  exit 2
  ;;
esac
