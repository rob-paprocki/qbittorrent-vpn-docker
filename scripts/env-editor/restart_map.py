"""Map .env key changes to the compose services that need recycling."""
from __future__ import annotations

# Services that always run.
STACK = ["gluetun", "qbittorrent", "jackett", "flaresolverr", "filebrowser"]

# Services behind a Compose profile, mapped to that profile. They run only
# while their profile is listed in COMPOSE_PROFILES, so they are recycled
# only then: naming a profiled service on the `docker compose up` command
# line starts it even when its profile is off.
PROFILED: dict[str, str] = {"watchtower": "watchtower"}

# Services that share Gluetun's network namespace. Recycling gluetun's
# network namespace tears these down with it, so a VPN change implies all of
# them.
_GLUETUN_NETNS = ["gluetun", "qbittorrent", "jackett", "flaresolverr"]

# Sentinels used in the map below:
#   "*"          -> every service that runs (STACK plus active profiled ones)
#   "gluetun+"   -> gluetun and everything on its network namespace
#   "_profiles"  -> start profiled services whose profile is now on, and
#                   remove the ones whose profile is now off
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

    # qBittorrent credentials — re-seed configs then recycle. FileBrowser
    # needs no seeding: it takes the password from FILEBROWSER_ADMIN_PASSWORD
    # (compose.yaml) every time it starts, so recreating it is enough.
    "QBITTORRENT_USER": ["qbittorrent", "gluetun", "_reseed_qbit"],
    "QBITTORRENT_PASSWORD": [
        "qbittorrent", "filebrowser", "gluetun",
        "_reseed_qbit",
    ],
    "SCRIPT_NOTIFY_URL": ["gluetun"],

    # Optional services switched on and off by profile
    "COMPOSE_PROFILES": ["_profiles"],

    # Watchtower is standalone (and only recycled while its profile is on)
    "WATCHTOWER_NOTIFICATION_URL": ["watchtower"],
    "WATCHTOWER_NOTIFICATION_LEVEL": ["watchtower"],
    "WATCHTOWER_TITLE_TAG": ["watchtower"],
    "WATCHTOWER_SCHEDULE": ["watchtower"],
}


def active_profiles(env: dict[str, str]) -> set[str]:
    """Profiles listed in COMPOSE_PROFILES (comma-separated)."""
    return {p.strip() for p in env.get("COMPOSE_PROFILES", "").split(",") if p.strip()}


def all_services(env: dict[str, str]) -> list[str]:
    """Every service that runs with this .env: STACK plus active profiled ones."""
    active = active_profiles(env)
    return STACK + [svc for svc, profile in PROFILED.items() if profile in active]


def resolve(
    changed_keys: set[str], env: dict[str, str]
) -> tuple[list[str], list[str], list[str]]:
    """Return (services_to_recycle, seeders_to_run, services_to_remove).

    `env` is the .env being applied; it decides which profiled services run.
    Profiled services whose profile is off are never in the recycle list.
    Lists are sorted and deduped. Seeder names are the suffix of the
    "_reseed_X" sentinel.
    """
    running = all_services(env)
    services: set[str] = set()
    seeders: set[str] = set()
    remove: set[str] = set()
    for key in changed_keys:
        for mark in RESTART_MAP.get(key, []):
            if mark == "*":
                services.update(running)
            elif mark == "gluetun+":
                services.update(_GLUETUN_NETNS)
            elif mark == "_profiles":
                for svc in PROFILED:
                    (services if svc in running else remove).add(svc)
            elif mark.startswith("_reseed_"):
                seeders.add(mark[len("_reseed_"):])
            else:
                services.add(mark)
    services &= set(running)
    return sorted(services), sorted(seeders), sorted(remove)
