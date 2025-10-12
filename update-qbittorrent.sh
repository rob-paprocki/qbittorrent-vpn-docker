#!/bin/sh

# This script is executed by Gluetun automatically.

# Read the new port directly from the file Gluetun creates
NEW_PORT=$(cat /tmp/gluetun/forwarded_port)

# These are passed in from the compose file's environment section
QBIT_USER="$QBITTORRENT_USER"
QBIT_PASS="$QBITTORRENT_PASSWORD"
QBIT_HOST="localhost"
QBIT_PORT="$QBIT_WEBUI_PORT"
NOTIFY_URL="$SCRIPT_NOTIFY_URL"

echo "➡️ Starting qBittorrent port update..."
echo "New port to set: $NEW_PORT"

# Wait for qBittorrent Web UI to be responsive
echo "⌛ Waiting for qBittorrent to become available..."
COUNTER=0
while [ $COUNTER -lt 24 ]; do # Loop for 120 seconds (24 * 5s)
    wget -q --spider --timeout=2 "http://$QBIT_HOST:$QBIT_PORT"
    if [ $? -eq 0 ]; then
        echo "✅ qBittorrent is online."
        break
    fi
    COUNTER=$(expr $COUNTER + 1)
    sleep 5
done

if [ $COUNTER -eq 24 ]; then
    echo "❌ ERROR: qBittorrent did not become available after 120 seconds."
    wget -q -O- --header='Content-Type: application/json' --post-data "{\"content\":\"⚠️ **qBittorrent Startup Error!**\\n The script inside Gluetun failed to connect to qBittorrent after 120 seconds.\"}" "$NOTIFY_URL"
    exit 1
fi

# Log in to qBittorrent and update the port
echo "Logging in to qBittorrent..."
COOKIE_FILE=$(mktemp)
LOGIN_RESPONSE=$(wget -q --save-cookies "$COOKIE_FILE" --keep-session-cookies --post-data "username=$QBIT_USER&password=$QBIT_PASS" --header "Referer: http://$QBIT_HOST:$QBIT_PORT" -O - "http://$QBIT_HOST:$QBIT_PORT/api/v2/auth/login")

if [ "$LOGIN_RESPONSE" != "Ok." ]; then
    echo "❌ ERROR: Failed to log in to qBittorrent. Check credentials. Response: $LOGIN_RESPONSE"
    wget -q -O- --header='Content-Type: application/json' --post-data "{\"content\":\"⚠️ **qBittorrent Login Error!**\\n The script inside Gluetun failed to log in. Check credentials.\"}" "$NOTIFY_URL"
    rm "$COOKIE_FILE"
    exit 1
else
    echo "✅ Successfully logged in to qBittorrent."
    wget -q --load-cookies "$COOKIE_FILE" --post-data "json={\"listen_port\": $NEW_PORT}" -O /dev/null "http://$QBIT_HOST:$QBIT_PORT/api/v2/app/setPreferences"
    rm "$COOKIE_FILE"
    echo "✅ qBittorrent listening port update command sent."
    wget -q -O- --header='Content-Type: application/json' --post-data "{\"content\":\"✅ **qBittorrent Port Updated!**\\nNew forwarded port is: **$NEW_PORT**\"}" "$NOTIFY_URL"
fi

echo "----------------------------------------"
exit 0
