#!/bin/sh

# Invoked by Gluetun whenever a new forwarded VPN port is assigned.
# Reads the port, logs in to qBittorrent, pushes the port into qBittorrent's
# preferences, and reports the outcome to a Discord webhook.

set -u

QBIT_HOST="localhost"
QBIT_PORT="$QBIT_WEBUI_PORT"
QBIT_USER="$QBITTORRENT_USER"
QBIT_PASS="$QBITTORRENT_PASSWORD"
NOTIFY_URL="$SCRIPT_NOTIFY_URL"

NEW_PORT=$(cat /tmp/gluetun/forwarded_port 2>/dev/null || true)
case "$NEW_PORT" in
    ''|*[!0-9]*)
        echo "ERROR: invalid or empty forwarded port: '$NEW_PORT'" >&2
        exit 1
        ;;
esac
if [ "$NEW_PORT" -lt 1 ] || [ "$NEW_PORT" -gt 65535 ]; then
    echo "ERROR: forwarded port out of range: $NEW_PORT" >&2
    exit 1
fi

echo "Starting qBittorrent port update."
echo "New port to set: $NEW_PORT"

echo "Waiting for qBittorrent to become available..."
COUNTER=0
while [ "$COUNTER" -lt 24 ]; do # 24 * 5s = 120s
    if wget -q --spider --timeout=2 "http://$QBIT_HOST:$QBIT_PORT"; then
        echo "qBittorrent is online."
        break
    fi
    COUNTER=$((COUNTER + 1))
    sleep 5
done

if [ "$COUNTER" -eq 24 ]; then
    echo "ERROR: qBittorrent did not become available after 120 seconds." >&2
    wget -q -O- --header='Content-Type: application/json' --post-data '{"content":"qBittorrent Startup Error: the Gluetun port-update script could not reach qBittorrent after 120 seconds."}' "$NOTIFY_URL"
    exit 1
fi

COOKIE_FILE=$(mktemp)
trap 'rm -f "$COOKIE_FILE"' EXIT HUP INT TERM

echo "Logging in to qBittorrent..."
LOGIN_RESPONSE=$(wget -q --save-cookies "$COOKIE_FILE" --keep-session-cookies \
    --post-data "username=$QBIT_USER&password=$QBIT_PASS" \
    --header "Referer: http://$QBIT_HOST:$QBIT_PORT" \
    -O - "http://$QBIT_HOST:$QBIT_PORT/api/v2/auth/login")

if [ "$LOGIN_RESPONSE" != "Ok." ]; then
    echo "ERROR: failed to log in to qBittorrent. Response: $LOGIN_RESPONSE" >&2
    wget -q -O- --header='Content-Type: application/json' --post-data '{"content":"qBittorrent Login Error: the Gluetun port-update script could not log in. Check QBITTORRENT_USER/QBITTORRENT_PASSWORD."}' "$NOTIFY_URL"
    exit 1
fi

echo "Logged in. Setting listen_port=$NEW_PORT ..."
wget -q --load-cookies "$COOKIE_FILE" \
    --post-data "json={\"listen_port\": $NEW_PORT}" \
    -O /dev/null "http://$QBIT_HOST:$QBIT_PORT/api/v2/app/setPreferences"
echo "qBittorrent listening port updated."
wget -q -O- --header='Content-Type: application/json' --post-data "{\"content\":\"qBittorrent port updated. New forwarded port: $NEW_PORT.\"}" "$NOTIFY_URL"
echo "----------------------------------------"
exit 0
