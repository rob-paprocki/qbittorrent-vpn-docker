"""Read and write .env while preserving comments and ordering.

Field metadata (FIELDS) drives the form rendered by app.py. Each entry
declares how to prompt for and validate one .env key. login_problems() is
the one set of rules for the qBittorrent login (which is also FileBrowser's
admin password) that the env-editor checks in both modes before it saves.
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
     "help": "Hashed into qBittorrent.conf (PBKDF2) on Apply. Also FileBrowser's password for "
             "user `admin`: FileBrowser sets it from this value every time it starts. "
             "5 to 72 bytes (letters outside A-Z take 2 to 4 bytes each), not `admin`; "
             "with Docker Compose also no `$`.",
     "required": True},
    {"name": "SCRIPT_NOTIFY_URL", "section": "qBittorrent", "type": "url", "label": "Discord webhook URL",
     "help": "Where port-forward successes/errors ping. Leave blank for no notifications."},

    # --- Watchtower ---
    {"name": "COMPOSE_PROFILES", "section": "Watchtower", "type": "select",
     "label": "Run Watchtower",
     "choices": ["", "watchtower"],
     "choice_labels": {"": "off — Dockhand or another updater handles image updates",
                       "watchtower": "on — this stack's own Watchtower updates it"},
     "help": "Off on the docker-pve VM, where Dockhand applies image updates. "
             "The settings below only apply while this is on."},
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
# qBittorrent login rules (shared by the env-editor's Docker and native modes)
# ---------------------------------------------------------------------------

LOGIN_KEYS = ("QBITTORRENT_USER", "QBITTORRENT_PASSWORD")

# QBITTORRENT_PASSWORD is also FileBrowser Quantum's password for user
# "admin": compose.yaml passes it as FILEBROWSER_ADMIN_PASSWORD, and the
# native install hands it to `filebrowser user set admin`. What FileBrowser
# Quantum does with it (checked in gtsteffaniak/filebrowser v2.0.2-stable):
#   - "" and "admin" are ignored: ConfigTriggersAdminPasswordReset() in
#     backend/pkg/settings/auth.go leaves the stored password as it is, and
#     a new database gets a random one, printed once in the log
#     (backend/internal/state/bootstrap_admin_password.go).
#   - Fewer than 5 bytes are refused: ValidatePasswordPolicy() in
#     backend/pkg/settings/password_policy.go compares Go's len() (bytes)
#     with auth.methods.password.minLength, default 5
#     (backend/pkg/settings/config.go). The startup reset logs an error and
#     keeps the old password (backend/cmd/user.go).
#   - More than 72 bytes are refused: the password is stored as a bcrypt
#     hash (backend/internal/utils/crypto.go), and golang.org/x/crypto's
#     bcrypt.GenerateFromPassword returns ErrPasswordTooLong beyond 72.
# "admin" is also FileBrowser's well-known default, so both modes refuse it
# (natively, `filebrowser user set` would accept it).
FILEBROWSER_PASSWORD_MIN_BYTES = 5
FILEBROWSER_PASSWORD_MAX_BYTES = 72


def _unset(values: dict[str, str], example: dict[str, str], key: str) -> bool:
    """True when key is empty or still the .env.example value (render.py's rule)."""
    value = values.get(key, "").strip()
    return value == "" or value == example.get(key, "").strip()


def login_problems(values: dict[str, str], example: dict[str, str],
                   unset_ok: bool = False) -> list[str]:
    """Return why QBITTORRENT_USER / QBITTORRENT_PASSWORD cannot be used, or [].

    values: the .env values to check. example: the .env.example values (for
    the placeholders your_qbit_username / your_qbit_password, which are
    public). The password itself is never put in a message.

    unset_ok=False (Docker mode): both keys must be set. FileBrowser gets the
    password on a port published on every interface, so an empty value or
    the placeholder is refused. So is a password with "$": write_env puts it
    in double quotes, where Docker Compose expands $name, so Gluetun and
    FileBrowser would get another password than the one seeded into
    qBittorrent, and the byte count here would not be FileBrowser's.
    unset_ok=True (native mode): an empty or placeholder login means "not
    set up yet", as native/lib/render.py reads it: qBittorrent is not seeded
    and FileBrowser keeps the first-run password. The password rules apply
    once both keys are set; "$" is fine there (render.py reads .env
    literally).
    """
    if unset_ok and any(_unset(values, example, k) for k in LOGIN_KEYS):
        return []
    problems = []
    for key in LOGIN_KEYS:
        if not values.get(key, "").strip():
            problems.append(f"{key} is empty.")
        elif _unset(values, example, key):
            problems.append(f"{key} is still the .env.example placeholder "
                            f"({example[key].strip()}), which anyone can look up.")
    if problems:
        return problems
    password = values["QBITTORRENT_PASSWORD"]
    size = len(password.encode("utf-8"))
    what = "QBITTORRENT_PASSWORD (also FileBrowser's password for user admin)"
    if password == "admin":
        problems.append(f"{what} cannot be \"admin\": that is FileBrowser's default "
                        f"password, and FileBrowser's FILEBROWSER_ADMIN_PASSWORD setting "
                        f"ignores it (FileBrowser keeps its old password, or makes up "
                        f"a random one).")
    elif "$" in password and not unset_ok:
        problems.append(f"{what} cannot contain \"$\": Docker Compose reads $ in .env as "
                        f"the start of a variable name, so Gluetun and FileBrowser would "
                        f"get a shorter password than the one qBittorrent gets.")
    elif size < FILEBROWSER_PASSWORD_MIN_BYTES:
        problems.append(f"{what} has {size} bytes; FileBrowser needs at least "
                        f"{FILEBROWSER_PASSWORD_MIN_BYTES} (5 plain characters).")
    elif size > FILEBROWSER_PASSWORD_MAX_BYTES:
        problems.append(f"{what} has {size} bytes; FileBrowser stores a bcrypt hash of "
                        f"it, which holds at most {FILEBROWSER_PASSWORD_MAX_BYTES}. Letters "
                        f"outside A-Z take 2 to 4 bytes each.")
    return problems


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


_LITERAL_ASSIGN_RE = re.compile(r'^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=(.*)$')
_DQ_ESCAPES = {"n": "\n", "r": "\r", "t": "\t", "\\": "\\", '"': '"', "$": "$"}


def _closing_quote(text: str, quote: str, start: int) -> int:
    """Index of the quote that closes a value opened at text[start - 1], or -1.

    A quote preceded by an odd number of backslashes is escaped.
    """
    i = start
    while i < len(text):
        c = text[i]
        if c == "\\":
            i += 2
            continue
        if c == quote:
            return i
        i += 1
    return -1


def parse_env_literal(path: Path) -> dict[str, str]:
    """Parse .env the way Docker Compose does and return the literal values.

    Used by the seeding CLI, native mode and TrueNAS, which read values back
    from .env. They must see what Compose (and so Gluetun and
    update-qbittorrent.sh) sees, or the seeded qBittorrent password and the
    one the port-forward script logs in with could differ. Compose's rules
    (https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/#env-file-syntax),
    checked against `docker compose config`:

    - Blank lines and lines starting with # are skipped; `export KEY=...`
      is the same as `KEY=...`; when a key appears twice the last one wins.
    - Unquoted: an inline comment starts at " #" (a space, then #);
      `pw#1` stays `pw#1`. Surrounding spaces are trimmed.
    - Double quotes: \\n \\r \\t \\\\ \\" and \\$ are unescaped (write_env
      writes \\\\ and \\"), other backslashes are kept, and anything after
      the closing quote (such as `# note`) is ignored. The value may span
      lines.
    - Single quotes: taken literally except \\' -> '. May span lines.

    Not done: ${VAR} interpolation, which Compose applies to unquoted and
    double-quoted values. Avoid $ in such values, or single-quote them.
    """
    if not path.exists():
        return {}
    out: dict[str, str] = {}
    lines = path.read_text(encoding="utf-8").splitlines()
    i = 0
    while i < len(lines):
        raw = lines[i]
        i += 1
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        m = _LITERAL_ASSIGN_RE.match(raw)
        if not m:
            continue
        key, val = m.group(1), m.group(2).lstrip()
        quote = val[:1]
        if quote in ('"', "'"):
            text, end = val, _closing_quote(val, quote, 1)
            j = i
            while end < 0 and j < len(lines):   # a quoted value may span lines
                text += "\n" + lines[j]
                j += 1
                end = _closing_quote(text, quote, 1)
            if end >= 0:
                i = j
                body = text[1:end]
                if quote == '"':
                    val = re.sub(r'\\(.)', lambda e: _DQ_ESCAPES.get(e.group(1), e.group(0)),
                                 body, flags=re.S)
                else:
                    val = body.replace("\\'", "'")
                out[key] = val
                continue
            # No closing quote anywhere (Compose would refuse the file):
            # fall through and take the line as an unquoted value.
        cut = val.find(" #")
        if cut >= 0:
            val = val[:cut]
        out[key] = val.strip()
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
