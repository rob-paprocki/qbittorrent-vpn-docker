"""Read and write .env while preserving comments and ordering.

Field metadata (FIELDS) drives the form rendered by app.py. Each entry
declares how to prompt for and validate one .env key.
"""
from __future__ import annotations

import re
from pathlib import Path

# ---------------------------------------------------------------------------
# Field metadata — order mirrors .env.example
# ---------------------------------------------------------------------------

# Gluetun providers that this stack's port-forward integration needs.
# Taken from the .env.example note. The connect-only block below is for
# providers Gluetun supports but which have no port-forward path.
_PF_PROVIDERS = [
    "protonvpn",
    "private internet access",
    "perfect privacy",
    "privatevpn",
]
_NON_PF_PROVIDERS = [
    "mullvad", "nordvpn", "surfshark", "windscribe", "airvpn",
    "expressvpn", "ivpn", "cyberghost", "torguard", "vyprvpn",
]

FIELDS = [
    # --- System ---
    {"name": "PUID", "section": "System", "type": "int", "label": "Container UID",
     "help": "Host user id the containers run as. 1000 is the first non-root user on Debian/Ubuntu.",
     "required": True},
    {"name": "PGID", "section": "System", "type": "int", "label": "Container GID",
     "help": "Host group id the containers run as.", "required": True},
    {"name": "TZ", "section": "System", "type": "text", "label": "Timezone",
     "help": "IANA timezone (e.g. America/New_York) for log timestamps.", "required": True},
    {"name": "CONFIG_PATH", "section": "System", "type": "path", "label": "Config path",
     "help": "Host directory for per-service config folders.", "required": True},
    {"name": "DOWNLOADS_PATH", "section": "System", "type": "path", "label": "Downloads path",
     "help": "Host directory for completed downloads.", "required": True},
    {"name": "INCOMPLETE_DOWNLOADS", "section": "System", "type": "path", "label": "Incomplete path",
     "help": "Host directory for in-progress downloads.", "required": True},

    # --- VPN ---
    {"name": "VPN_TYPE", "section": "VPN", "type": "select", "label": "VPN protocol",
     "choices": ["wireguard", "openvpn"],
     "help": "Which protocol Gluetun negotiates with the provider.", "required": True},
    {"name": "VPN_PROVIDER", "section": "VPN", "type": "select", "label": "VPN provider",
     "choices_grouped": [
         ("Port-forward capable (recommended)", _PF_PROVIDERS),
         ("Connect-only — no port forwarding", _NON_PF_PROVIDERS),
     ],
     "help": "Only the port-forward-capable providers let qBittorrent accept incoming peers.",
     "required": True},
    {"name": "OPENVPN_USER", "section": "VPN", "type": "text", "label": "OpenVPN username",
     "help": "ProtonVPN: append `+pmp` to enable port forwarding (e.g. `foo+pmp`).",
     "shown_when": {"VPN_TYPE": "openvpn"}},
    {"name": "OPENVPN_PASSWORD", "section": "VPN", "type": "password", "label": "OpenVPN password",
     "shown_when": {"VPN_TYPE": "openvpn"}},
    {"name": "OPENVPN_PROTOCOL", "section": "VPN", "type": "select", "label": "OpenVPN transport",
     "choices": ["udp", "tcp"],
     "shown_when": {"VPN_TYPE": "openvpn"}},
    {"name": "WIREGUARD_PRIVATE_KEY", "section": "VPN", "type": "password", "label": "WireGuard private key",
     "help": "Base64-encoded 32-byte key from your provider's WireGuard config.",
     "shown_when": {"VPN_TYPE": "wireguard"}},
    {"name": "WIREGUARD_ADDRESSES", "section": "VPN", "type": "text", "label": "WireGuard addresses",
     "help": "The `Address` line from your WireGuard config (e.g. 10.2.0.2/32).",
     "shown_when": {"VPN_TYPE": "wireguard"}},
    {"name": "PORT_FORWARD_ONLY", "section": "VPN", "type": "toggle", "label": "Restrict to PF servers",
     "help": "`on` picks only servers that advertise port forwarding."},
    {"name": "VPN_PORT_FORWARDING", "section": "VPN", "type": "toggle", "label": "Enable port forwarding",
     "help": "`on` runs the port-forward script after each reconnect."},
    {"name": "SERVER_COUNTRIES", "section": "VPN", "type": "text", "label": "Exit countries",
     "help": "Comma-separated country names (e.g. `Switzerland,Netherlands`)."},

    # --- Ports ---
    {"name": "QBIT_WEBUI_PORT", "section": "Ports", "type": "port", "label": "qBittorrent WebUI port",
     "required": True},
    {"name": "JACKETT_PORT", "section": "Ports", "type": "port", "label": "Jackett port",
     "required": True},
    {"name": "FLARESOLVERR_PORT", "section": "Ports", "type": "port", "label": "FlareSolverr port",
     "required": True},
    {"name": "FILEBROWSER_PORT", "section": "Ports", "type": "port", "label": "FileBrowser port",
     "required": True},

    # --- qBittorrent ---
    {"name": "QBITTORRENT_USER", "section": "qBittorrent", "type": "text", "label": "WebUI username",
     "help": "Used by the port-forward script and seeded into qBittorrent.conf.", "required": True},
    {"name": "QBITTORRENT_PASSWORD", "section": "qBittorrent", "type": "password", "label": "WebUI password",
     "help": "Hashed into qBittorrent.conf (PBKDF2) and FileBrowser (bcrypt). Also reused as the FileBrowser admin password.",
     "required": True},
    {"name": "SCRIPT_NOTIFY_URL", "section": "qBittorrent", "type": "url", "label": "Discord webhook URL",
     "help": "Where port-forward successes/errors ping. Leave blank for no notifications."},

    # --- Watchtower ---
    {"name": "WATCHTOWER_NOTIFICATION_URL", "section": "Watchtower", "type": "text",
     "label": "Shoutrrr notification URL",
     "help": "e.g. discord://token@webhook_id — scheme auto-detected."},
    {"name": "WATCHTOWER_NOTIFICATION_LEVEL", "section": "Watchtower", "type": "select",
     "label": "Notification level", "choices": ["debug", "info", "warn"],
     "help": "`debug` pings on every image check; `info` only on updates/errors."},
    {"name": "WATCHTOWER_TITLE_TAG", "section": "Watchtower", "type": "text",
     "label": "Notification title prefix"},
    {"name": "WATCHTOWER_SCHEDULE", "section": "Watchtower", "type": "text",
     "label": "Watchtower cron",
     "help": "6-field cron (seconds included) for the Watchtower sweep."},
]

FIELD_BY_NAME = {f["name"]: f for f in FIELDS}


# ---------------------------------------------------------------------------
# .env I/O preserving comments
# ---------------------------------------------------------------------------

_ASSIGN_RE = re.compile(r'^\s*([A-Z_][A-Z0-9_]*)\s*=\s*(.*)$')


def parse_env(path: Path) -> dict[str, str]:
    """Parse a dotenv file into a {name: value} dict. Strips matched quotes."""
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _ASSIGN_RE.match(raw)
        if not m:
            continue
        key, val = m.group(1), m.group(2).rstrip()
        if len(val) >= 2 and val[0] == val[-1] and val[0] in ('"', "'"):
            val = val[1:-1]
        out[key] = val
    return out


def write_env(env_path: Path, example_path: Path, values: dict[str, str]) -> None:
    """Write .env using the example as a template.

    Comment lines, blank lines, and the order of keys are preserved from
    .env.example. For every KEY=... line in the example, the current value
    is replaced with values[KEY] when present. Values containing whitespace
    or shell metacharacters are double-quoted.
    """
    lines_out: list[str] = []
    seen: set[str] = set()
    for raw in example_path.read_text(encoding="utf-8").splitlines():
        m = _ASSIGN_RE.match(raw)
        if m:
            key = m.group(1)
            seen.add(key)
            if key in values:
                lines_out.append(f"{key}={_quote(values[key])}")
            else:
                lines_out.append(raw)
        else:
            lines_out.append(raw)
    for key, val in values.items():
        if key not in seen:
            lines_out.append(f"{key}={_quote(val)}")
    env_path.write_text("\n".join(lines_out) + "\n", encoding="utf-8")


def _quote(val: str) -> str:
    """Quote a value if it contains whitespace or shell meta."""
    if val == "" or re.search(r'[\s"\'$`\\]', val):
        escaped = val.replace("\\", "\\\\").replace('"', '\\"')
        return f'"{escaped}"'
    return val
