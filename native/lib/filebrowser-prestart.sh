#!/usr/bin/env bash
# filebrowser-prestart.sh USER: run (as root) by torrent-filebrowser.service
# before FileBrowser starts. Sets FileBrowser's "admin" password.
#
# Part of qbittorrent-vpn-docker's native installer. MIT License (see LICENSE).
#
# Why not FileBrowser's FILEBROWSER_ADMIN_PASSWORD variable: a program's
# environment can be read by every other program of the same user (in
# /proc/<pid>/environ). FileBrowser runs as the torrent user, like
# qBittorrent, Jackett and FlareSolverr, so an exploited app could read the
# password there. Instead, root opens the root-only password file
# (/etc/torrent-stack/filebrowser-admin.pw, rendered from .env) and hands it
# on stdin to a short `filebrowser user set` that runs as the torrent user
# (so root never writes FileBrowser's database itself). The server that
# starts afterwards never sees the password.
set -Euo pipefail

user="${1:?usage: filebrowser-prestart.sh USER}"
pw=/etc/torrent-stack/filebrowser-admin.pw
fb=/usr/local/lib/torrent-stack/filebrowser/filebrowser
config=/etc/torrent-stack/filebrowser.yaml

if [[ ! -s "$pw" ]]; then
    echo "filebrowser-prestart: $pw is missing; FileBrowser keeps its current admin login"
    exit 0
fi
uid="$(id -u "$user")"
gid="$(id -g "$user")"
db="$(sed -n 's/^    path: "\(.*\)"$/\1/p' "$config" | head -1)"

set_password() {
    setpriv --reuid="$uid" --regid="$gid" --clear-groups -- \
        "$fb" -c "$config" user set admin --password --admin < "$pw"
}

# The output is FileBrowser's own log lines (no password in them).
if [[ -n "$db" && -e "$db" ]]; then
    set_password; rc=$?
else
    # First start, no database yet. FileBrowser then creates "admin" itself
    # and, without a configured password, gives it a random one that it
    # logs and marks "must be changed". Hand it the real password for this
    # one short run, so the account is created with it straight away. It is
    # put in the environment (readable only by root and the torrent user),
    # never on a command line (readable by every user).
    ( FILEBROWSER_ADMIN_PASSWORD="$(cat "$pw")"; export FILEBROWSER_ADMIN_PASSWORD; set_password ); rc=$?
fi
if [[ $rc -eq 0 ]]; then
    echo "filebrowser-prestart: admin password set from $pw"
else
    # Keep FileBrowser usable with its previous password rather than not
    # starting it at all (FileBrowser needs at least 5 characters).
    echo "filebrowser-prestart: WARNING: could not set the admin password (see above); FileBrowser keeps the previous one" >&2
fi
exit 0
