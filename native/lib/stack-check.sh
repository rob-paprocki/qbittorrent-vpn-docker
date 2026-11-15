#!/usr/bin/env bash
# stack-check.sh: run every minute (as root) by torrent-killswitch-check.timer.
#
# Part of qbittorrent-vpn-docker's native installer. MIT License (see LICENSE).
#
# 1. Puts the kill switch back if its nftables table disappeared (for
#    example after `nft flush ruleset`, or Debian's nftables.service).
# 2. Checks that each running app still sees its private resolv.conf
#    (Gluetun's DNS, 127.0.0.1) and nsswitch.conf ("hosts: files dns"), and
#    that Gluetun still sees its private resolv.conf. Those are bind mounts
#    in each unit's own view of the filesystem. When /etc/resolv.conf is a
#    plain file and something on the host replaces it by renaming a new
#    file over it (a DHCP client can), Linux drops such a mount in the
#    unit's view. Then the app's lookups fail (the kill switch blocks the
#    real DNS servers), or Gluetun writes the container's real resolv.conf.
#    The cure is a restart of that unit, done here at most once per
#    10 minutes per unit.
#
# Warnings carry a "<4>" prefix: the unit logs only notices and above.
set -u

ETC=/etc/torrent-stack
TABLE=torrent_killswitch
STAMPS=/run/torrent-stack/check
warn() { printf '<4>%s\n' "$*" >&2; }

if ! nft list table inet "$TABLE" >/dev/null 2>&1; then
    warn "kill switch table was missing, reloading it"
    nft -f "$ETC/killswitch.nft" || warn "reloading the kill switch FAILED"
fi

# ino PID PATH: device:inode of PATH as the unit with main PID sees it.
ino() { nsenter -t "$1" -m -- stat -L -c %d:%i "$2" 2>/dev/null; }

view_ok() {  # view_ok SERVICE PID
    local svc="$1" pid="$2" name
    name="$(basename "$(realpath /etc/resolv.conf)")"
    if [[ "$svc" == gluetun ]]; then
        [[ "$(ino "$pid" /etc/resolv.conf)" == "$(stat -c %d:%i "$ETC/gluetun-resolve/$name" 2>/dev/null)" ]]
    else
        nsenter -t "$pid" -m -- cmp -s /etc/resolv.conf "$ETC/app-resolve/resolv.conf" \
            && nsenter -t "$pid" -m -- cmp -s /etc/nsswitch.conf "$ETC/nsswitch.conf"
    fi
}

# Leave the services alone while native/install.sh runs (it stops and
# starts them itself); try again next minute.
install -d -m 0700 "$STAMPS"
exec 9>/run/torrent-stack/install.lock
flock -n 9 || exit 0
for svc in gluetun qbittorrent jackett flaresolverr filebrowser; do
    pid="$(systemctl show -p MainPID --value "torrent-$svc" 2>/dev/null || echo 0)"
    [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 0 ]] || continue
    view_ok "$svc" "$pid" && continue
    stamp="$STAMPS/$svc"
    if [[ -f "$stamp" && $(( $(date +%s) - $(stat -c %Y "$stamp") )) -lt 600 ]]; then
        continue
    fi
    touch "$stamp"
    warn "torrent-$svc lost its private resolv.conf/nsswitch.conf (the host replaced the file); restarting it. If this repeats, run: bash /opt/torrent-stack/native/install.sh apply"
    systemctl restart --no-block "torrent-$svc"
done
exit 0
