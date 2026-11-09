"""One-shot seeders for the config files qBittorrent and Jackett read on
first start. Each seeder is idempotent: if the target key is already
present it is overwritten with the current value; untouched fields stay as
the user left them. FileBrowser has no seeder: compose.yaml (natively,
native/install.sh) hands it the admin password directly.

Also runnable on its own (the "seeding CLI"), for installers that have no
env-editor running:

    python3 scripts/env-editor/seed_configs.py --env /path/to/.env [--config-root DIR]

It runs the same seeders as the env-editor's Apply and exits non-zero on
failure. See main() below for the options.
"""
from __future__ import annotations

import argparse
import base64
import hashlib
import json
import os
import re
import secrets
import sys
import urllib.request
from pathlib import Path

# qBittorrent runs this plugin's Python code, so it is never taken from a
# moving branch: the commit and the file's sha256 come from
# native/versions.env (QBIT_SEARCH_PLUGINS_COMMIT, QBIT_JACKETT_PLUGIN_SHA256),
# the same pins the native installer and TrueNAS use. A download whose
# sha256 differs is refused and nothing is written.
QBIT_JACKETT_PLUGIN_URL = (
    "https://raw.githubusercontent.com/qbittorrent/search-plugins/"
    "{commit}/nova3/engines/jackett.py"
)
VERSIONS_FILE = Path(__file__).resolve().parents[2] / "native" / "versions.env"


# ---------------------------------------------------------------------------
# qBittorrent
# ---------------------------------------------------------------------------

def qbit_password_hash(password: str) -> str:
    """Return the qBittorrent-format PBKDF2 password hash.

    qBit's on-disk format: `@ByteArray(<base64 salt>:<base64 hash>)` where
    hash = PBKDF2-HMAC-SHA512(password, salt, 100000 iterations, 64 bytes).
    """
    salt = secrets.token_bytes(16)
    digest = hashlib.pbkdf2_hmac("sha512", password.encode("utf-8"), salt, 100000)
    salt_b64 = base64.b64encode(salt).decode("ascii")
    hash_b64 = base64.b64encode(digest).decode("ascii")
    return f"@ByteArray({salt_b64}:{hash_b64})"


def seed_qbittorrent(config_root: Path, username: str, password: str,
                     pin: tuple[str, str] | None = None) -> None:
    """Write the qBit WebUI user, PBKDF2 password, and search-enabled flag
    into qBittorrent.conf. Also installs the Jackett search plugin into
    nova3/engines/ (pin: (commit, sha256), read from versions.env if None).
    """
    conf = config_root / "qbittorrent" / "qBittorrent" / "qBittorrent.conf"
    conf.parent.mkdir(parents=True, exist_ok=True)
    text = conf.read_text(encoding="utf-8") if conf.exists() else ""

    pw_hash = f'"{qbit_password_hash(password)}"'
    text = _upsert_ini(text, "Preferences", "WebUI\\Username", username)
    text = _upsert_ini(text, "Preferences", "WebUI\\Password_PBKDF2", pw_hash)
    text = _upsert_ini(text, "Preferences", "Search\\SearchEnabled", "true")
    # qBittorrent 5.x moves its web UI settings to a [WebUI] section the
    # first time it starts (and records [Meta] MigrationVersion 11 or later);
    # from then on it no longer reads the [Preferences] keys above. So once a
    # file has been migrated, the login goes into [WebUI] too, or a changed
    # password would be ignored. A file not migrated yet is left to
    # qBittorrent, which moves the keys itself.
    if _qbit_conf_migrated(text):
        text = _upsert_ini(text, "WebUI", "Username", username)
        text = _upsert_ini(text, "WebUI", "Password_PBKDF2", pw_hash)
    conf.write_text(text, encoding="utf-8")

    _install_qbit_search_plugin(config_root, pin)


def _qbit_conf_migrated(text: str) -> bool:
    """True when qBittorrent 5.x has moved this file's web UI keys to [WebUI]."""
    section = ""
    for line in text.splitlines():
        m = re.match(r'^\[([^\]]+)\]\s*$', line)
        if m:
            section = m.group(1)
            if section == "WebUI":
                return True
            continue
        if section == "Meta" and line.startswith("MigrationVersion="):
            try:
                if int(line.split("=", 1)[1].strip()) >= 11:
                    return True
            except ValueError:
                pass
    return False


def plugin_pin(versions_file: Path = VERSIONS_FILE) -> tuple[str, str]:
    """Return (commit, sha256) of the Jackett search plugin from versions.env.

    versions.env is read as KEY=VALUE data, never run. Raises RuntimeError
    when the file or either pin is missing or malformed.
    """
    pins: dict[str, str] = {}
    try:
        text = versions_file.read_text(encoding="utf-8")
    except OSError as exc:
        raise RuntimeError(f"cannot read the plugin pins in {versions_file}: {exc}") from exc
    for line in text.splitlines():
        line = line.strip()
        if line and not line.startswith("#") and "=" in line:
            key, value = line.split("=", 1)
            pins[key.strip()] = value.strip()
    commit = pins.get("QBIT_SEARCH_PLUGINS_COMMIT", "")
    want = pins.get("QBIT_JACKETT_PLUGIN_SHA256", "").lower()
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{64}", want):
        raise RuntimeError(f"{versions_file} has no valid QBIT_SEARCH_PLUGINS_COMMIT "
                           f"and QBIT_JACKETT_PLUGIN_SHA256 lines")
    return commit, want


def _install_qbit_search_plugin(config_root: Path,
                                pin: tuple[str, str] | None = None) -> None:
    engines = config_root / "qbittorrent" / "qBittorrent" / "nova3" / "engines"
    engines.mkdir(parents=True, exist_ok=True)
    plugin = engines / "jackett.py"
    if plugin.exists():
        return  # keep the installed copy (installers put the pinned one there)
    commit, want = pin or plugin_pin()
    url = QBIT_JACKETT_PLUGIN_URL.format(commit=commit)
    with urllib.request.urlopen(url, timeout=30) as resp:  # fixed https URL
        data = resp.read(2 * 1024 * 1024)
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        raise RuntimeError(f"{url} has sha256 {got}, native/versions.env expects "
                           f"{want}; not installing it")
    # Write to a temporary name first, so a half-written plugin never exists.
    tmp = plugin.with_name(plugin.name + ".part")
    tmp.write_bytes(data)
    os.replace(tmp, plugin)


def seed_qbit_jackett_wiring(config_root: Path, api_key: str,
                             jackett_host: str = "127.0.0.1",
                             jackett_port: int = 9117) -> None:
    """Write the plugin's JSON config pointing at Jackett."""
    engines = config_root / "qbittorrent" / "qBittorrent" / "nova3" / "engines"
    engines.mkdir(parents=True, exist_ok=True)
    (engines / "jackett.json").write_text(
        json.dumps({
            "api_key": api_key,
            "url": f"http://{jackett_host}:{jackett_port}",
            "tracker_first": False,
            "thingy": "",
        }, indent=2),
        encoding="utf-8",
    )


# ---------------------------------------------------------------------------
# Jackett
# ---------------------------------------------------------------------------

def ensure_jackett_api_key(config_root: Path) -> str:
    """Return Jackett's APIKey, generating one if ServerConfig.json has none."""
    sc = config_root / "jackett" / "Jackett" / "ServerConfig.json"
    sc.parent.mkdir(parents=True, exist_ok=True)
    data: dict = {}
    if sc.exists():
        try:
            data = json.loads(sc.read_text(encoding="utf-8"))
        except json.JSONDecodeError:
            data = {}
    if not data.get("APIKey"):
        data["APIKey"] = secrets.token_hex(16)
    data.setdefault("Port", 9117)
    data.setdefault("LocalBindAddress", "*")
    data.setdefault("FlareSolverrUrl", "http://127.0.0.1:8191")
    data.setdefault("FlareSolverrMaxTimeout", 55000)
    sc.write_text(json.dumps(data, indent=2), encoding="utf-8")
    return data["APIKey"]


# ---------------------------------------------------------------------------
# Minimal INI helper for qBittorrent.conf
# ---------------------------------------------------------------------------

def _upsert_ini(text: str, section: str, key: str, value: str) -> str:
    """Insert-or-replace a section/key in a Qt-style INI blob.

    Qt's INI uses backslash-escaped sub-keys (e.g. WebUI\\Password_PBKDF2)
    which configparser mangles, so we do line-level string ops instead.
    """
    section_re = re.compile(r'^\[([^\]]+)\]\s*$')
    key_literal = f"{key}={value}"
    key_re = re.compile(r'^\s*' + re.escape(key) + r'\s*=')

    lines = text.splitlines()
    current = None
    section_start = None
    section_end = None
    key_line_idx = None

    for i, line in enumerate(lines):
        m = section_re.match(line)
        if m:
            if current == section and section_end is None:
                section_end = i
            current = m.group(1)
            if current == section and section_start is None:
                section_start = i
            continue
        if current == section and key_re.match(line):
            key_line_idx = i

    if key_line_idx is not None:
        lines[key_line_idx] = key_literal
        return "\n".join(lines) + ("\n" if text.endswith("\n") else "")

    if section_start is None:
        suffix = [] if text.endswith("\n") or not text else [""]
        return (text + "\n".join(suffix + [f"[{section}]", key_literal, ""])).rstrip("\n") + "\n"

    insert_at = section_end if section_end is not None else len(lines)
    while insert_at > section_start + 1 and lines[insert_at - 1].strip() == "":
        insert_at -= 1
    lines.insert(insert_at, key_literal)
    return "\n".join(lines) + ("\n" if text.endswith("\n") else "")


# ---------------------------------------------------------------------------
# Command-line entry point (the seeding CLI)
# ---------------------------------------------------------------------------

SEEDERS = ("jackett", "qbit")

# Keys whose .env.example placeholder values must never become a real login.
_LOGIN_KEYS = ("QBITTORRENT_USER", "QBITTORRENT_PASSWORD")


def _placeholder_login(values: dict[str, str], env_path: Path, env_io) -> list[str]:
    """Return the login keys that are empty or still the .env.example value.

    Compared against this repo's own .env.example (and the one next to the
    .env, if there is one), so a copy of .env elsewhere is checked too.
    """
    examples: dict[str, set[str]] = {k: set() for k in _LOGIN_KEYS}
    for example in (Path(__file__).resolve().parents[2] / ".env.example",
                    env_path.parent / ".env.example"):
        if example.is_file():
            parsed = env_io.parse_env_literal(example)
            for k in _LOGIN_KEYS:
                if parsed.get(k, "").strip():
                    examples[k].add(parsed[k].strip())
    return [k for k in _LOGIN_KEYS
            if not values.get(k, "").strip() or values[k].strip() in examples[k]]


def _become(uid: int, gid: int) -> None:
    """Drop root for good: from here on every file is touched as uid/gid."""
    os.setgroups([])
    os.setgid(gid)
    os.setuid(uid)


def run_seeders(env_path: Path, config_root: Path | None = None,
                only: tuple[str, ...] = SEEDERS,
                as_user: tuple[int, int] | None = None,
                jackett_port: int | None = None) -> list[str]:
    """Run the seeders the env-editor's Apply runs, with values from env_path.

    Same calls and arguments as app.py's apply(): the Jackett API key is
    ensured first (the qBittorrent search plugin needs it), then
    qBittorrent (PBKDF2 password + Jackett search plugin wiring). Returns
    human-readable log lines; raises on failure.

    It never seeds the .env.example placeholder login (your_qbit_username /
    your_qbit_password) or an empty one: the qBittorrent seeder is then
    skipped with a warning, so no publicly known login is ever set up. (The
    env-editor refuses to save such a login in Docker mode instead.)

    as_user=(uid, gid): read .env first (it is usually root-only), then
    switch to that user before touching any config file. The native
    installer uses this because the config folders belong to the app user.

    jackett_port: the port qBittorrent's search plugin reaches Jackett on
    (127.0.0.1:PORT). Default: JACKETT_PORT from .env. Docker installers
    whose Jackett listens on 9117 inside the shared network while the host
    port differs pass 9117.
    """
    # env_io sits next to this file. Added explicitly so the CLI also works
    # when run with `python3 -I`, which leaves the script folder off sys.path.
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    import env_io

    env_path = env_path.resolve()
    if not env_path.is_file():
        raise FileNotFoundError(f"{env_path} does not exist")
    # Literal values: a password holding " or \\ must be seeded as typed.
    values = env_io.parse_env_literal(env_path)
    if config_root is None:
        # Same rule as app.py: a relative CONFIG_PATH is relative to the
        # folder holding .env (the repo root).
        config_root = Path(values.get("CONFIG_PATH") or "./configs")
        if not config_root.is_absolute():
            config_root = (env_path.parent / config_root).resolve()

    log: list[str] = []
    placeholders = _placeholder_login(values, env_path, env_io)
    if placeholders and "qbit" in only:
        only = tuple(x for x in only if x != "qbit")
        log.append(f"WARNING: {', '.join(placeholders)} still empty or the "
                   f".env.example placeholder; skipped seeding qbit "
                   f"(set a real login, then seed again)")
    # Read the plugin pins now, while versions.env is surely readable (before
    # as_user) and before any config file is written, so a failure never
    # leaves half the configs seeded.
    pin = plugin_pin() if "qbit" in only else None

    if as_user is not None:
        _become(*as_user)

    api_key = ensure_jackett_api_key(config_root)
    log.append(f"Jackett API key present ({api_key[:4]}…)")
    if "qbit" in only:
        seed_qbittorrent(config_root, values["QBITTORRENT_USER"],
                         values["QBITTORRENT_PASSWORD"], pin)
        seed_qbit_jackett_wiring(config_root, api_key, "127.0.0.1",
                                 jackett_port or int(values.get("JACKETT_PORT", "9117")))
        log.append("Seeded qBittorrent.conf (PBKDF2 + search plugin)")
    return log


def _uid_gid(text: str) -> tuple[int, int]:
    uid, sep, gid = text.partition(":")
    if not (sep and uid.isdigit() and gid.isdigit()):
        raise argparse.ArgumentTypeError("expected UID:GID, for example 1000:1000")
    return int(uid), int(gid)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        description="Seed qBittorrent and Jackett configs from a .env file, "
                    "as the env-editor's Apply does. The .env.example "
                    "placeholder login is never seeded.")
    parser.add_argument("--env", required=True, type=Path,
                        help="path to the stack's .env")
    parser.add_argument("--config-root", type=Path, default=None,
                        help="config folder (default: CONFIG_PATH from .env, "
                             "relative to the .env folder)")
    parser.add_argument("--only", default=",".join(SEEDERS),
                        help="comma-separated subset of: " + ", ".join(SEEDERS)
                             + " (default: all). The Jackett API key is "
                               "always ensured.")
    parser.add_argument("--as-user", type=_uid_gid, default=None, metavar="UID:GID",
                        help="read --env as the calling user (root), then switch "
                             "to UID:GID before writing any config file")
    parser.add_argument("--jackett-port", type=int, default=None, metavar="PORT",
                        help="port the qBittorrent search plugin reaches Jackett on, "
                             "at 127.0.0.1 (default: JACKETT_PORT from .env)")
    args = parser.parse_args(argv)
    if args.jackett_port is not None and not 1 <= args.jackett_port <= 65535:
        parser.error("--jackett-port must be 1-65535")

    only = tuple(s.strip() for s in args.only.split(",") if s.strip())
    unknown = [s for s in only if s not in SEEDERS]
    if unknown:
        parser.error(f"unknown seeder(s): {', '.join(unknown)}")
    try:
        for line in run_seeders(args.env, args.config_root, only, args.as_user,
                                args.jackett_port):
            print(line, file=sys.stderr if line.startswith("WARNING") else sys.stdout)
    except Exception as exc:  # report any failure as a non-zero exit
        print(f"seed_configs: ERROR: {type(exc).__name__}: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
