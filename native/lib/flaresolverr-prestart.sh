#!/usr/bin/env bash
# flaresolverr-prestart.sh USER: run (as root) before FlareSolverr starts.
#
# Part of qbittorrent-vpn-docker's native installer. MIT License (see LICENSE).
#
# Why: FlareSolverr patches chromedriver in place so websites cannot spot
# it. Its official Docker image moves Debian's chromedriver to a writable
# /app/chromedriver for that. The native install points FlareSolverr at
# /usr/local/lib/torrent-stack/flaresolverr/chromedriver instead (a
# one-line path change made at install time) and keeps a copy there that
# the app user may patch.
#
# chromedriver must match the installed chromium version, and apt updates
# both together. So whenever Debian's chromedriver changes, the copy is
# refreshed here on the next FlareSolverr start. Without a copy FlareSolverr
# would try to download a driver from the internet instead.
set -Eeuo pipefail

user="${1:?usage: flaresolverr-prestart.sh USER}"
dir=/usr/local/lib/torrent-stack/flaresolverr
dst="$dir/chromedriver"
stamp="$dir/chromedriver.source-sha256"

src="$(readlink -f /usr/bin/chromedriver || true)"
if [[ -z "$src" || ! -x "$src" ]]; then
    echo "flaresolverr-prestart: /usr/bin/chromedriver is missing; install the chromium-driver package" >&2
    exit 1
fi

sum="$(sha256sum "$src" | cut -d' ' -f1)"
if [[ ! -x "$dst" || ! -f "$stamp" || "$(cat "$stamp")" != "$sum" ]]; then
    install -m 0755 -o "$user" -g "$user" "$src" "$dst.new"
    mv -f "$dst.new" "$dst"
    printf '%s\n' "$sum" > "$stamp"
    echo "flaresolverr-prestart: copied $src for FlareSolverr ($("$src" --version 2>/dev/null | head -1))"
fi
