"""Map .env key changes to the compose services that need recycling."""
from __future__ import annotations

STACK = ["gluetun", "qbittorrent", "jackett", "flaresolverr", "filebrowser", "watchtower"]

# Services that share Gluetun's network namespace. Recycling gluetun's
# network namespace tears these down with it, so a VPN change implies all of
# them.
_GLUETUN_NETNS = ["gluetun", "qbittorrent", "jackett", "flaresolverr"]

# Sentinels used in the map below:
#   "*"          -> every service in STACK
#   "gluetun+"   -> gluetun and everything on its network namespace
#   "_reseed_X"  -> run the named seeder (not a service to recycle)
RESTART_MAP: dict[str, list[str]] = {
    # System
    "PUID": ["*"],
    "PGID": ["*"],
    "TZ": ["*"],
    "CONFIG_PATH": ["*"],
    "DOWNLOADS_PATH": ["qbittorrent", "filebrowser"],
    "INCOMPLETE_DOWNLOADS": ["qbittorrent"],

    # VPN — all cascade through gluetun's network namespace
    "VPN_TYPE": ["gluetun+"],
    "VPN_PROVIDER": ["gluetun+"],
    "OPENVPN_USER": ["gluetun+"],
    "OPENVPN_PASSWORD": ["gluetun+"],
    "OPENVPN_PROTOCOL": ["gluetun+"],
    "WIREGUARD_PRIVATE_KEY": ["gluetun+"],
    "WIREGUARD_ADDRESSES": ["gluetun+"],
    "PORT_FORWARD_ONLY": ["gluetun+"],
    "VPN_PORT_FORWARDING": ["gluetun+"],
    "SERVER_COUNTRIES": ["gluetun+"],

    # Ports — qBit's port is published by gluetun, so changing it rotates both
    "QBIT_WEBUI_PORT": ["gluetun+"],
    "JACKETT_PORT": ["gluetun", "jackett"],
    "FLARESOLVERR_PORT": ["gluetun", "flaresolverr"],
    "FILEBROWSER_PORT": ["filebrowser"],

    # qBittorrent credentials — re-seed configs then recycle
    "QBITTORRENT_USER": ["qbittorrent", "gluetun", "_reseed_qbit"],
    "QBITTORRENT_PASSWORD": [
        "qbittorrent", "filebrowser", "gluetun",
        "_reseed_qbit", "_reseed_filebrowser",
    ],
    "SCRIPT_NOTIFY_URL": ["gluetun"],

    # Watchtower is standalone
    "WATCHTOWER_NOTIFICATION_URL": ["watchtower"],
    "WATCHTOWER_NOTIFICATION_LEVEL": ["watchtower"],
    "WATCHTOWER_TITLE_TAG": ["watchtower"],
    "WATCHTOWER_SCHEDULE": ["watchtower"],
}


def resolve(changed_keys: set[str]) -> tuple[list[str], list[str]]:
    """Return (services_to_recycle, seeders_to_run).

    Service list is sorted and deduped. Seeder names are the suffix of the
    "_reseed_X" sentinel.
    """
    services: set[str] = set()
    seeders: set[str] = set()
    for key in changed_keys:
        for mark in RESTART_MAP.get(key, []):
            if mark == "*":
                services.update(STACK)
            elif mark == "gluetun+":
                services.update(_GLUETUN_NETNS)
            elif mark.startswith("_reseed_"):
                seeders.add(mark[len("_reseed_"):])
            else:
                services.add(mark)
    return sorted(services), sorted(seeders)
