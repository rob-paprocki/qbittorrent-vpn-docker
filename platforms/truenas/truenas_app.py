#!/usr/bin/env python3
"""
platforms/truenas/truenas_app.py

Purpose: the Python half of platforms/truenas/install.sh. The shell script
runs the wizard and the TrueNAS API calls that carry no secrets (through
`midclt`); this helper does the parts that are easier and safer in Python:

  merge      combine .env.example with the installer's layers of settings
             (TrueNAS defaults, the current app, TS_* variables, wizard
             answers) into one values file, and check them
  extract    read the current custom app's compose (from `app.config`) back
             into .env values, so a re-run keeps what you edited in the
             app's YAML in the TrueNAS web UI
  render     turn the repository's compose.yaml plus those values into the
             YAML that TrueNAS stores for a custom app
  diff       list what a re-run would change in the app's current YAML
  payload    build the app.create / app.update parameters
  call       call a TrueNAS API method with parameters read from a file,
             through TrueNAS's own Python API client
  envfile    write a temporary .env for the seeding CLI
  qbit-defaults   give a new qBittorrent.conf the image's defaults
  qbit-webui-fix  keep a re-seeded qBittorrent login working on 5.3+
  fetch-plugin    install the pinned qBittorrent Jackett search plugin
  source-check    refuse to overwrite a folder the installer did not make
  json-get   pick fields out of `midclt` JSON output (for the shell script)
  same       compare settings between two values files
  get        print one value from a values file

Why a file and not the command line: `midclt call METHOD ARGS...` on
TrueNAS 25.10 only takes its JSON arguments on the command line, and every
local user can read any process's command line (ps, /proc/PID/cmdline).
The app's YAML holds the VPN key and the qBittorrent password, so
app.create and app.update go through `call`, which reads them from a 0600
file and sends them over the middleware's local socket with the same
client library midclt uses (python3-truenas-api-client, part of TrueNAS).

Only the Python standard library, PyYAML (a dependency of TrueNAS's own
middleware, so always installed) and that client are used.

Copyright (c) 2025-2026 Rob Paprocki
License: MIT (see LICENSE in the repository root)
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import secrets
import stat
import sys
from pathlib import Path

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# .env keys whose values are secret. They are never printed (the wizard
# only learns whether they are set) and are masked in --dry-run output.
SECRET_KEYS = {
    "OPENVPN_PASSWORD",
    "WIREGUARD_PRIVATE_KEY",
    "QBITTORRENT_PASSWORD",
    "SCRIPT_NOTIFY_URL",          # a Discord webhook URL carries its token
    "WATCHTOWER_NOTIFICATION_URL",
}

# Set by the installer from the datasets it uses; not taken from TS_*.
PATH_KEYS = ("CONFIG_PATH", "DOWNLOADS_PATH", "INCOMPLETE_DOWNLOADS")

# Services that share Gluetun's network namespace. They can only reach the
# internet through the VPN, which is the stack's main security property.
GLUETUN = "gluetun"
NETNS_SERVICES = ("qbittorrent", "jackett", "flaresolverr")

# Compose profile put on Gluetun and the services behind it while the VPN
# settings are still the .env.example placeholders. TrueNAS starts a custom
# app with plain `docker compose up`, which skips services whose profile is
# not active, so only FileBrowser runs until the VPN settings are filled in.
# Without it, app.create would fail: Gluetun exits on a placeholder key,
# `docker compose up` reports "dependency failed to start", and TrueNAS
# then deletes the half-created app again.
GATE_PROFILE = "vpn-not-configured"

# gtsteffaniak/filebrowser runs as a fixed uid 1000 and ignores PUID
# (its _docker/Dockerfile: `adduser -D -s /bin/true -u 1000 filebrowser`,
# `USER filebrowser`). On TrueNAS the downloads usually belong to the apps
# user (568), so FileBrowser gets PGID as an extra group (group_add) to be
# able to read and manage them.
FILEBROWSER_UID = 1000

# Jackett and FlareSolverr do not follow the .env port: the LinuxServer
# Jackett image listens on 9117 (its s6 service even waits for
# `nc -z localhost 9117`), and FlareSolverr listens on 8191 unless its own
# PORT variable says otherwise. So on TrueNAS only the host side of these
# two published ports changes; inside Gluetun's network namespace they
# stay 9117 and 8191 (which is also where qBittorrent's search plugin and
# Jackett's FlareSolverr URL point).
FIXED_CONTAINER_PORTS = {"JACKETT_PORT": 9117, "FLARESOLVERR_PORT": 8191}

# Ports already taken inside Gluetun's network namespace, which the
# qBittorrent web UI shares: Gluetun's own servers, Jackett and FlareSolverr.
NETNS_TAKEN_PORTS = {8000: "Gluetun's control server", 9999: "Gluetun's health server",
                     9117: "Jackett", 8191: "FlareSolverr"}

# Settings that must be whole numbers. They are stored without leading
# zeros: install.sh pastes PUID/PGID into JSON for midclt, where 01000 is
# not a number.
INT_KEYS = ("PUID", "PGID", "QBIT_WEBUI_PORT", "JACKETT_PORT", "FLARESOLVERR_PORT",
            "FILEBROWSER_PORT")

# The file install.sh writes into the repository copy on the dataset. Only
# a folder holding it is ever emptied and refilled (see source-check).
SOURCE_MARKER = ".torrent-stack-source"

KEY_RE = re.compile(r"^[A-Z_][A-Z0-9_]*$")
APP_NAME_RE = re.compile(r"^[a-z]([-a-z0-9]*[a-z0-9])?$")


class HelperError(Exception):
    """A problem the user can fix; printed without a traceback."""


# ---------------------------------------------------------------------------
# Small file helpers
# ---------------------------------------------------------------------------

def write_private(path: str | Path, text: str) -> None:
    """Write text to path with mode 0600, creating it that way (no window
    in which another user could open it)."""
    path = str(path)
    if path == "-":
        sys.stdout.write(text)
        return
    fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
    try:
        os.fchmod(fd, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fd = -1
            fh.write(text)
    finally:
        if fd >= 0:
            os.close(fd)


def read_private(path: str | Path) -> str:
    """Read a file that may hold secrets, refusing one that other users
    could read or that someone else owns."""
    st = os.stat(path)
    if st.st_mode & (stat.S_IRWXG | stat.S_IRWXO):
        raise HelperError(f"{path} must not be readable by other users (chmod 600 it)")
    if st.st_uid != os.geteuid():
        raise HelperError(f"{path} is not owned by the user running this script")
    return Path(path).read_text(encoding="utf-8")


def read_layer(path: str | Path) -> dict[str, str]:
    """Read a settings layer: NUL-separated KEY=VALUE records, as written by
    install.sh with bash's builtin printf (so values never pass through a
    command line)."""
    out: dict[str, str] = {}
    data = read_private(path)
    for rec in data.split("\0"):
        if not rec:
            continue
        key, sep, val = rec.partition("=")
        if not sep or not KEY_RE.match(key.lstrip("_")):
            raise HelperError(f"{path}: malformed record {key!r}")
        out[key] = val
    return out


def nul_records(items: dict[str, str]) -> str:
    return "".join(f"{k}={v}\0" for k, v in items.items())


def load_yaml_module():
    try:
        import yaml  # noqa: PLC0415 - imported late for a clear error
    except ImportError as exc:  # pragma: no cover - TrueNAS always has it
        raise HelperError("Python's yaml module (PyYAML) is missing. TrueNAS ships it "
                          "with its middleware; on another system install python3-yaml.") from exc
    return yaml


def repo_env_io(repo: Path):
    """Import scripts/env-editor/env_io.py from the checkout, so .env files
    are read and written exactly as the env-editor does."""
    sys.path.insert(0, str(repo / "scripts" / "env-editor"))
    try:
        import env_io  # noqa: PLC0415
    finally:
        sys.path.pop(0)
    return env_io


def example_values(repo: Path) -> dict[str, str]:
    return repo_env_io(repo).parse_env_literal(repo / ".env.example")


def load_values(path: str | Path) -> dict[str, str]:
    data = json.loads(read_private(path))
    if not isinstance(data, dict) or not all(isinstance(v, str) for v in data.values()):
        raise HelperError(f"{path} is not a values file")
    return data


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def is_placeholder(values: dict[str, str], example: dict[str, str], key: str) -> bool:
    """Same rule as native/lib/render.py: empty, or still the example value."""
    value = values.get(key, "").strip()
    return value == "" or value == example.get(key, "").strip()


def vpn_missing(values: dict[str, str], example: dict[str, str]) -> list[str]:
    """The VPN settings that still need filling in (empty list = ready)."""
    vpn_type = values.get("VPN_TYPE", "").strip().lower()
    keys = (["WIREGUARD_PRIVATE_KEY", "WIREGUARD_ADDRESSES"] if vpn_type == "wireguard"
            else ["OPENVPN_USER", "OPENVPN_PASSWORD"])
    missing = [k for k in keys if is_placeholder(values, example, k)]
    if not values.get("VPN_PROVIDER", "").strip():
        missing.append("VPN_PROVIDER")
    return missing


def _int(values: dict[str, str], key: str, lo: int, hi: int, errors: list[str]) -> int | None:
    raw = values.get(key, "").strip()
    try:
        n = int(raw, 10)
    except ValueError:
        errors.append(f"{key} must be a whole number (got {raw!r})")
        return None
    if not lo <= n <= hi:
        errors.append(f"{key} must be between {lo} and {hi} (got {n})")
        return None
    return n


def validate(values: dict[str, str], example: dict[str, str], *, need_paths: bool) -> list[str]:
    """Return a list of problems (empty when the values are usable)."""
    errors: list[str] = []
    for key, value in values.items():
        if any(c in value for c in "\n\r\0"):
            errors.append(f"{key} contains a line break")
    # 0 would make the LinuxServer images run the apps as root.
    _int(values, "PUID", 1, 2**31 - 1, errors)
    _int(values, "PGID", 1, 2**31 - 1, errors)
    ports: dict[str, int] = {}
    for key in ("QBIT_WEBUI_PORT", "JACKETT_PORT", "FLARESOLVERR_PORT", "FILEBROWSER_PORT"):
        n = _int(values, key, 1, 65535, errors)
        if n is not None:
            ports[key] = n
    if len(set(ports.values())) != len(ports):
        errors.append("the four web UI ports must all be different")
    # qBittorrent listens on QBIT_WEBUI_PORT inside Gluetun's network
    # namespace. (Jackett and FlareSolverr keep their fixed ports in there;
    # see FIXED_CONTAINER_PORTS.)
    qport = ports.get("QBIT_WEBUI_PORT")
    if qport in NETNS_TAKEN_PORTS:
        errors.append(f"QBIT_WEBUI_PORT={qport} is taken by {NETNS_TAKEN_PORTS[qport]} "
                      "inside the VPN container; pick another port")
    if values.get("VPN_TYPE", "").strip().lower() not in ("wireguard", "openvpn"):
        errors.append(f"VPN_TYPE must be wireguard or openvpn (got {values.get('VPN_TYPE')!r})")
    if not values.get("TZ", "").strip():
        errors.append("TZ (time zone) is empty")
    for key in ("QBITTORRENT_USER", "QBITTORRENT_PASSWORD"):
        if is_placeholder(values, example, key):
            errors.append(f"{key} is not set")
    if len(values.get("QBITTORRENT_PASSWORD", "")) < 6:
        # qBittorrent's Web UI refuses passwords shorter than 6 characters.
        errors.append("QBITTORRENT_PASSWORD must be at least 6 characters")
    if need_paths:
        for key in PATH_KEYS:
            if not values.get(key, "").startswith("/"):
                errors.append(f"{key} must be an absolute path (got {values.get(key)!r})")
            elif ":" in values[key]:
                # ':' separates the parts of a Compose volume entry
                # (host:container:mode); Compose would cut the path there.
                errors.append(f"{key} must not contain ':' (got {values[key]!r})")
    return errors


# ---------------------------------------------------------------------------
# merge
# ---------------------------------------------------------------------------

def cmd_merge(args) -> int:
    repo = Path(args.repo)
    example = example_values(repo)
    values = dict(example)
    for layer_path in args.layer:
        for key, val in read_layer(layer_path).items():
            if key.startswith("__"):
                continue          # metadata records, not .env keys
            if key not in example:
                raise HelperError(f"unknown setting {key} (not in .env.example)")
            values[key] = val
    # Watchtower stays off: TrueNAS updates custom app images itself.
    values["COMPOSE_PROFILES"] = ""
    # 01000 -> 1000 (see INT_KEYS). Anything else is left for validate().
    for key in INT_KEYS:
        raw = values.get(key, "").strip()
        if raw.isascii() and raw.isdigit():
            values[key] = str(int(raw, 10))
    if args.generate_qbit_password and is_placeholder(values, example, "QBITTORRENT_PASSWORD"):
        # 24 URL-safe characters: no quotes, $ or spaces to trip anyone up.
        values["QBITTORRENT_PASSWORD"] = secrets.token_urlsafe(18)
    errors = validate(values, example, need_paths=args.need_paths)
    write_private(args.out, json.dumps(values, indent=1) + "\n")
    if args.show:
        show = {k: ("" if k in SECRET_KEYS else v) for k, v in values.items()}
        for key in SECRET_KEYS & values.keys():
            show[f"__SET_{key}"] = "0" if is_placeholder(values, example, key) else "1"
        missing = vpn_missing(values, example)
        show["__VPN_MISSING"] = ",".join(missing)
        write_private(args.show, nul_records(show))
    if errors:
        for err in errors:
            print(f"  - {err}", file=sys.stderr)
        return 3
    return 0


# ---------------------------------------------------------------------------
# Compose interpolation (the subset Docker Compose documents)
# ---------------------------------------------------------------------------

_INTERP_RE = re.compile(
    r"\$(?:(?P<esc>\$)"
    r"|\{(?P<braced>[A-Za-z_][A-Za-z0-9_]*)(?:(?P<op>:?[-?])(?P<arg>[^}]*))?\}"
    r"|(?P<named>[A-Za-z_][A-Za-z0-9_]*))"
)


def interpolate(text: str, env: dict[str, str], unknown: set[str]) -> str:
    """Expand ${VAR}, ${VAR:-default}, ${VAR-default}, ${VAR:?err},
    ${VAR?err}, $VAR and $$ the way Docker Compose does with an .env file."""
    out: list[str] = []
    pos = 0
    for m in _INTERP_RE.finditer(text):
        if "$" in text[pos:m.start()]:
            raise HelperError(f"invalid interpolation in {text!r}")
        out.append(text[pos:m.start()])
        pos = m.end()
        if m.group("esc"):
            out.append("$")
            continue
        name = m.group("braced") or m.group("named")
        op, arg = m.group("op"), m.group("arg") or ""
        val = env.get(name)
        if op == ":-":
            out.append(val if val else arg)
        elif op == "-":
            out.append(val if val is not None else arg)
        elif op in (":?", "?"):
            if val is None or (op == ":?" and not val):
                raise HelperError(f"{name}: {arg or 'required'}")
            out.append(val)
        else:
            if val is None:
                unknown.add(name)
                val = ""
            out.append(val)
    if "$" in text[pos:]:
        raise HelperError(f"invalid interpolation in {text!r}")
    out.append(text[pos:])
    return "".join(out)


def walk_strings(node, fn):
    """Return a copy of node with fn applied to every string value (mapping
    keys are left alone, as Compose does)."""
    if isinstance(node, dict):
        return {k: walk_strings(v, fn) for k, v in node.items()}
    if isinstance(node, list):
        return [walk_strings(v, fn) for v in node]
    if isinstance(node, str):
        return fn(node)
    return node


# ---------------------------------------------------------------------------
# render
# ---------------------------------------------------------------------------

def _split_volume(spec: str) -> tuple[str, str, str]:
    """Split short volume syntax SRC:DST[:MODE]."""
    parts = spec.split(":")
    if len(parts) == 1:
        return "", parts[0], ""
    if len(parts) == 2:
        return parts[0], parts[1], ""
    return parts[0], parts[1], ":".join(parts[2:])


def _is_relative_host_path(src: str) -> bool:
    return src in (".", "..") or src.startswith("./") or src.startswith("../")


def _inside(path: str, roots: list[str], strict: bool = False) -> bool:
    """Is path inside one of roots? With strict, a root itself does not count."""
    path = os.path.normpath(path)
    for root in roots:
        root = os.path.normpath(root)
        if (path == root and not strict) or path.startswith(root + "/"):
            return True
    return False


_SAME_PORT_RE = re.compile(r"^\$\{(?P<key>[A-Z_]+)\}:\$\{(?P=key)\}(?P<proto>/(?:tcp|udp))?$")


def truenas_template(compose: dict) -> dict:
    """compose.yaml as TrueNAS gets it, still with its ${VAR} references.

    The one change at this stage: Gluetun publishes Jackett and FlareSolverr
    as ${JACKETT_PORT}:9117 and ${FLARESOLVERR_PORT}:8191 instead of
    ${PORT}:${PORT}, because those two apps do not move to the .env port
    (see FIXED_CONTAINER_PORTS). render() and extract() both start from
    this, so a port read back from the app's YAML is the host port."""
    gl = (compose.get("services") or {}).get(GLUETUN)
    if isinstance(gl, dict) and isinstance(gl.get("ports"), list):
        new_ports = []
        for item in gl["ports"]:
            m = _SAME_PORT_RE.match(item) if isinstance(item, str) else None
            if m and m.group("key") in FIXED_CONTAINER_PORTS:
                item = (f"${{{m.group('key')}}}:{FIXED_CONTAINER_PORTS[m.group('key')]}"
                        f"{m.group('proto') or ''}")
            new_ports.append(item)
        gl["ports"] = new_ports
    return compose


def load_template(repo: Path) -> dict:
    yaml = load_yaml_module()
    compose = yaml.safe_load((repo / "compose.yaml").read_text(encoding="utf-8"))
    if not isinstance(compose, dict) or not isinstance(compose.get("services"), dict):
        raise HelperError("compose.yaml has no services")
    return truenas_template(compose)


def render(repo: Path, values: dict[str, str], source_dir: str,
           allowed_roots: list[str]) -> tuple[dict, dict]:
    """Return (compose dict for TrueNAS, metadata for install.sh)."""
    example = example_values(repo)
    errors = validate(values, example, need_paths=True)
    if errors:
        raise HelperError("settings are not valid:\n  - " + "\n  - ".join(errors))

    compose = load_template(repo)

    # 1. Fill in ${VAR} from the values, as `docker compose` does with .env.
    unknown: set[str] = set()
    compose = walk_strings(compose, lambda s: interpolate(s, values, unknown))
    if unknown:
        raise HelperError("compose.yaml uses settings missing from .env.example: "
                          + ", ".join(sorted(unknown)))

    # 2. TrueNAS names the Compose project ix-<app name> itself.
    compose.pop("name", None)

    # 3. Profiles: COMPOSE_PROFILES is always empty here, so services that
    #    only run with a profile (Watchtower) are left out.
    services: dict = compose["services"]
    for svc in [s for s, d in services.items() if isinstance(d, dict) and d.get("profiles")]:
        del services[svc]

    # 4. The kill-switch property: the apps must live in Gluetun's network
    #    namespace and Gluetun must have the tun device and NET_ADMIN.
    gl = services.get(GLUETUN)
    if not isinstance(gl, dict):
        raise HelperError("compose.yaml has no gluetun service")
    for svc in NETNS_SERVICES:
        if svc in services and services[svc].get("network_mode") != f"service:{GLUETUN}":
            raise HelperError(f"{svc} is not on network_mode: service:{GLUETUN}; refusing to "
                              "render a stack that could bypass the VPN")
    caps = gl.setdefault("cap_add", [])
    if "NET_ADMIN" not in caps:
        caps.append("NET_ADMIN")
    devices = gl.setdefault("devices", [])
    if not any(str(d).split(":")[0] == "/dev/net/tun" for d in devices):
        devices.append("/dev/net/tun:/dev/net/tun")

    # 5. Host paths: relative ones (./update-qbittorrent.sh) are relative to
    #    the repository copy on the dataset, as Compose resolves them against
    #    the project folder. Every host path must be on a pool.
    if ":" in source_dir:
        raise HelperError(f"the repository copy's path {source_dir} contains ':', which a "
                          "Compose volume entry cannot hold")
    binds: list[tuple[str, str, str]] = []
    for svc, sdef in services.items():
        new_vols = []
        for vol in sdef.get("volumes", []) or []:
            if isinstance(vol, dict):
                src = vol.get("source", "")
                if vol.get("type", "volume") == "bind":
                    if _is_relative_host_path(src):
                        src = os.path.normpath(os.path.join(source_dir, src))
                        vol = dict(vol, source=src)
                    binds.append((svc, src, vol.get("target", "")))
                new_vols.append(vol)
                continue
            if vol.count(":") > 2:
                raise HelperError(f"{svc}: volume entry {vol!r} has more than two ':'; "
                                  "a host path with ':' cannot be mounted")
            src, dst, mode = _split_volume(vol)
            if _is_relative_host_path(src):
                src = os.path.normpath(os.path.join(source_dir, src))
            if src.startswith("/"):
                binds.append((svc, src, dst))
            elif src:
                raise HelperError(f"{svc}: named volume {src!r} is not supported here; "
                                  "use a path on a dataset")
            new_vols.append(":".join(p for p in (src, dst, mode) if p))
        if "volumes" in sdef:
            sdef["volumes"] = new_vols
    for svc, src, _dst in binds:
        if "/.ix-apps" in os.path.normpath(src) + "/" or "/ix-apps/" in os.path.normpath(src) + "/":
            raise HelperError(f"{svc}: {src} is inside TrueNAS's own apps dataset (ix-apps)")
        if ":" in src:
            # ':' separates the parts of a volume entry; Compose would cut
            # the path there and mount the wrong folder.
            raise HelperError(f"{svc}: host path {src} contains ':', which a Compose volume "
                              "entry cannot hold; use a dataset name without ':'")
        if not _inside(src, allowed_roots):
            raise HelperError(f"{svc}: host path {src} is not inside a pool "
                              f"({', '.join(allowed_roots) or 'no pools found'})")

    # 6. FileBrowser (FileBrowser Quantum, the :stable image) keeps its users
    #    and settings in an SQLite database whose path comes from
    #    FILEBROWSER_DATABASE_PATH; the image sets it to a folder that is
    #    not mounted, so every redeploy (TrueNAS recreates the containers on
    #    each update) would start from an empty database. Put it in the
    #    config folder instead. FILEBROWSER_ADMIN_PASSWORD sets the password
    #    of its admin user ("admin") on every start: here the qBittorrent
    #    password, so there is no default or one-off login to find. (The
    #    image reads its config file from /home/filebrowser/data, so the
    #    seeding CLI's settings.yaml is not used on TrueNAS.)
    #    It also runs as uid 1000 whatever PUID is: group_add lets it use
    #    the PGID group's access to the downloads (see FILEBROWSER_UID).
    fb = services.get("filebrowser")
    if isinstance(fb, dict):
        conf_targets = [dst for svc, src, dst in binds
                        if svc == "filebrowser" and _inside(src, [values["CONFIG_PATH"]], strict=True)]
        if not conf_targets:
            raise HelperError("compose.yaml: filebrowser has no folder under CONFIG_PATH mounted; "
                              "its database would be lost on every update")
        env = fb.get("environment")
        if env is None:
            env = fb["environment"] = {}
        if not isinstance(env, dict):
            raise HelperError("compose.yaml: filebrowser's environment must be a mapping")
        env["FILEBROWSER_DATABASE_PATH"] = conf_targets[0].rstrip("/") + "/database.sqlite"
        env["FILEBROWSER_ADMIN_PASSWORD"] = values["QBITTORRENT_PASSWORD"]
        groups = [str(g) for g in fb.get("group_add", [])]
        if values["PGID"] not in groups:
            groups.append(values["PGID"])
        fb["group_add"] = groups

    # 7. Startup gating while the VPN settings are placeholders.
    missing = vpn_missing(values, example)
    gated: list[str] = []
    if missing:
        gated = [GLUETUN] + [s for s in services
                             if services[s].get("network_mode") == f"service:{GLUETUN}"]
        for svc in gated:
            services[svc]["profiles"] = [GATE_PROFILE]

    # 8. Escape every $ so Compose on TrueNAS (which has no .env to read)
    #    passes values such as a password containing $ through literally.
    compose = walk_strings(compose, lambda s: s.replace("$", "$$"))

    images = []
    for sdef in compose["services"].values():
        if sdef.get("image") and sdef["image"] not in images:
            images.append(sdef["image"])
    meta = {
        "images": images,
        "gated": gated,
        "vpn_missing": missing,
        "binds": binds,
        "services": list(compose["services"]),
    }
    return compose, meta


YAML_HEADER = """\
# torrent-stack for TrueNAS (custom app). Generated by
# platforms/truenas/install.sh from the repository's compose.yaml.
# TrueNAS keeps only this YAML (no .env file): settings are written in
# place below. Edit them here (Apps > {app} > Edit), or re-run the
# installer, which reads them back and keeps them.
# A $$ is a literal $ (Docker Compose would otherwise expand it).
"""

GATE_NOTE = """\
# VPN NOT CONFIGURED YET: gluetun, qbittorrent, jackett and flaresolverr
# carry `profiles: [{profile}]`, so TrueNAS does not start them. Fill in the
# VPN settings under gluetun > environment, delete those four `profiles:`
# lines and save. (Or re-run the installer with the VPN settings.)
"""


def dump_compose(compose: dict, app_name: str, gated: bool) -> str:
    yaml = load_yaml_module()
    body = yaml.safe_dump(compose, sort_keys=False, default_flow_style=False,
                          allow_unicode=True, width=4096)
    header = YAML_HEADER.format(app=app_name)
    if gated:
        header += GATE_NOTE.format(profile=GATE_PROFILE)
    return header + body


def cmd_render(args) -> int:
    repo = Path(args.repo)
    values = load_values(args.values)
    if args.redact:
        example = example_values(repo)
        for key in SECRET_KEYS & values.keys():
            if not is_placeholder(values, example, key):
                values[key] = f"REDACTED-{key}"
    compose, meta = render(repo, values, args.source_dir, args.allowed_root or [])
    write_private(args.out_yaml, dump_compose(compose, args.app_name, bool(meta["gated"])))
    if args.meta:
        recs = []
        for img in meta["images"]:
            recs.append(f"IMAGE={img}\0")
        for svc in meta["gated"]:
            recs.append(f"GATED={svc}\0")
        if meta["vpn_missing"]:
            recs.append(f"VPN_MISSING={','.join(meta['vpn_missing'])}\0")
        for svc, src, dst in meta["binds"]:
            recs.append(f"BIND={svc}\t{src}\t{dst}\0")
        write_private(args.meta, "".join(recs))
    return 0


# ---------------------------------------------------------------------------
# extract: current app YAML -> .env values
# ---------------------------------------------------------------------------

def _scalar_text(value, example_value: str) -> str | None:
    """Text of a YAML scalar as the user meant it in the app's YAML."""
    if isinstance(value, bool):
        # PyYAML (YAML 1.1) reads an unquoted on/off as a boolean.
        if example_value.strip().lower() in ("on", "off"):
            return "on" if value else "off"
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, str):
        return value
    return None


def _template_regex(template: str) -> tuple[re.Pattern, list[str]] | None:
    """Regex matching what a compose.yaml string renders to, with one group
    per ${VAR}. Returns None for strings without variables."""
    parts: list[str] = []
    names: list[str] = []
    pos = 0
    found = False
    for m in _INTERP_RE.finditer(template):
        parts.append(re.escape(template[pos:m.start()]))
        pos = m.end()
        if m.group("esc"):
            parts.append(re.escape("$"))
            continue
        found = True
        name = m.group("braced") or m.group("named")
        if name in names:
            parts.append(f"(?P={name})")
        else:
            names.append(name)
            parts.append(f"(?P<{name}>.*?)")
    if not found:
        return None
    parts.append(re.escape(template[pos:]))
    return re.compile("^" + "".join(parts) + "$", re.DOTALL), names


def _match_into(template, current, example: dict[str, str], found: dict[str, str],
                single_pass: bool) -> None:
    """Walk compose.yaml (template) and the app's compose (current) side by
    side and record the value of each ${VAR} found. With single_pass, only
    strings that are exactly one variable (`KEY: ${KEY}`) are used; the
    second pass fills in the rest from strings such as
    `${CONFIG_PATH}/gluetun:/gluetun`. So a value written plainly in an
    environment block wins over one that is part of a longer string."""
    if isinstance(template, dict) and isinstance(current, dict):
        for key, tval in template.items():
            if key in current:
                _match_into(tval, current[key], example, found, single_pass)
        return
    if isinstance(template, list) and isinstance(current, list):
        for i, tval in enumerate(template):
            if isinstance(tval, str):
                # The same position first, then any item (lists such as
                # ports may have been reordered in the web UI).
                cands = ([current[i]] if i < len(current) else []) + list(current)
                for cand in cands:
                    if _match_string(tval, cand, example, found, single_pass):
                        break
            elif i < len(current):
                _match_into(tval, current[i], example, found, single_pass)
        return
    if isinstance(template, str):
        _match_string(template, current, example, found, single_pass)


def _match_string(template: str, current, example: dict[str, str], found: dict[str, str],
                  single_pass: bool) -> bool:
    compiled = _template_regex(template)
    if compiled is None:
        return False
    regex, names = compiled
    single = template.strip()
    single_var = len(names) == 1 and single in (f"${{{names[0]}}}", f"${names[0]}")
    if single_var != single_pass:
        return False
    text = _scalar_text(current, example.get(names[0], "") if single_var else "")
    if text is None:
        return False
    # The rendered YAML has every $ doubled; undo that before matching.
    text = text.replace("$$", "$")
    m = regex.match(text)
    if not m:
        return False
    for name in names:
        found.setdefault(name, m.group(name))
    return True


def extract(repo: Path, current: dict) -> tuple[dict[str, str], dict[str, str]]:
    """Return (values recovered from the app's compose, metadata)."""
    example = example_values(repo)
    template = load_template(repo)
    meta: dict[str, str] = {}
    services = current.get("services") if isinstance(current, dict) else None
    if not isinstance(services, dict) or GLUETUN not in services or "qbittorrent" not in services:
        meta["FOREIGN"] = "1"
        return {}, meta
    found: dict[str, str] = {}
    _match_into(template, current, example, found, single_pass=True)
    _match_into(template, current, example, found, single_pass=False)
    values = {k: v for k, v in found.items() if k in example}

    # Where the repository copy lives: the host side of the mount that
    # compose.yaml writes as ./update-qbittorrent.sh.
    for tsvc, tdef in (template.get("services") or {}).items():
        for tvol in tdef.get("volumes", []) or []:
            if not isinstance(tvol, str):
                continue
            tsrc, tdst, _ = _split_volume(tvol)
            if not _is_relative_host_path(tsrc):
                continue
            for cvol in (services.get(tsvc) or {}).get("volumes", []) or []:
                if isinstance(cvol, str):
                    csrc, cdst, _ = _split_volume(cvol.replace("$$", "$"))
                    rel = os.path.normpath(tsrc)
                    if cdst == tdst and csrc.endswith("/" + rel):
                        meta["SOURCE_DIR"] = csrc[: -len(rel) - 1]
    if any(GATE_PROFILE in (services.get(s) or {}).get("profiles", []) for s in services):
        meta["GATED"] = "1"
    return values, meta


def cmd_extract(args) -> int:
    repo = Path(args.repo)
    current = json.loads(read_private(args.config))
    values, meta = extract(repo, current)
    write_private(args.out, nul_records(values))
    write_private(args.meta, nul_records(meta))
    return 0


# ---------------------------------------------------------------------------
# diff
# ---------------------------------------------------------------------------

def _flatten(node, prefix: str, out: dict[str, object]) -> None:
    if isinstance(node, dict):
        for k, v in node.items():
            _flatten(v, f"{prefix}.{k}" if prefix else str(k), out)
    elif isinstance(node, list):
        if all(not isinstance(v, (dict, list)) for v in node):
            # Order of ports, volumes and the like rarely matters; compare
            # them as sets of items. An item with "=" (KEY=VALUE) shows only
            # its key, so a secret in a list-style environment is not shown.
            for v in node:
                text = str(v)
                if "=" in text:
                    shown = text.split("=", 1)[0] + "=#" + hashlib.sha256(text.encode()).hexdigest()[:8]
                else:
                    shown = text
                out[f"{prefix}[{shown}]"] = True
        else:
            for i, v in enumerate(node):
                _flatten(v, f"{prefix}[{i}]", out)
    else:
        out[prefix] = node


def cmd_diff(args) -> int:
    yaml = load_yaml_module()
    old = json.loads(read_private(args.old))
    new = yaml.safe_load(read_private(args.new_yaml))
    a: dict[str, object] = {}
    b: dict[str, object] = {}
    _flatten(old, "", a)
    _flatten(new, "", b)
    removed = sorted(set(a) - set(b))
    added = sorted(set(b) - set(a))
    changed = sorted(k for k in set(a) & set(b) if a[k] != b[k])
    # The VPN gate (see GATE_PROFILE) is reported in words, not as a
    # removed or added entry, which would look like a lost hand edit.
    gate = re.compile(r"^services\.([^.]+)\.profiles\[" + re.escape(GATE_PROFILE) + r"\]$")
    for key in [k for k in removed if gate.match(k)]:
        print(f"    starts now (VPN settings filled in): {gate.match(key).group(1)}")
    for key in [k for k in added if gate.match(k)]:
        print(f"    held back until the VPN settings are filled in: {gate.match(key).group(1)}")
    removed = [k for k in removed if not gate.match(k)]
    added = [k for k in added if not gate.match(k)]
    for label, keys in (("removed", removed), ("added", added), ("changed", changed)):
        for key in keys:
            print(f"    {label}: {key}")
    return 0


# ---------------------------------------------------------------------------
# payload and call
# ---------------------------------------------------------------------------

def cmd_payload(args) -> int:
    yaml_text = read_private(args.yaml)
    if not APP_NAME_RE.match(args.app_name) or len(args.app_name) > 40:
        raise HelperError(f"invalid app name {args.app_name!r}")
    if args.mode == "create":
        # app.create (a job): AppCreateArgs in the TrueNAS 25.10 API.
        params = [{
            "custom_app": True,
            "app_name": args.app_name,
            "custom_compose_config_string": yaml_text,
        }]
    else:
        # app.update (a job): app name, then AppUpdate.
        params = [args.app_name, {"custom_compose_config_string": yaml_text}]
    write_private(args.out, json.dumps(params, indent=1 if args.out == "-" else None) + "\n")
    return 0


def cmd_call(args) -> int:
    params = json.loads(read_private(args.params)) if args.params else []
    if not isinstance(params, list):
        raise HelperError("the parameters file must hold a JSON list")
    try:
        from truenas_api_client import Client  # noqa: PLC0415
        from truenas_api_client.exc import ClientException  # noqa: PLC0415
    except ImportError as exc:
        raise HelperError("truenas_api_client is missing: this must run on TrueNAS "
                          "(it is the library behind midclt)") from exc

    last = {"desc": None}

    def progress(job):
        prog = job.get("progress") or {}
        desc = prog.get("description")
        if desc and desc != last["desc"]:
            last["desc"] = desc
            pct = prog.get("percent")
            print(f"      {pct if pct is not None else '?'}% {desc}", file=sys.stderr)

    try:
        with Client() as client:
            kwargs = {"job": True, "callback": progress} if args.job else {}
            result = client.call(args.method, *params, **kwargs)
    except ClientException as exc:
        print(f"{args.method} failed: {exc}", file=sys.stderr)
        trace = getattr(exc, "trace", None) or {}
        if trace.get("formatted"):
            lines = str(trace["formatted"]).strip().splitlines()
            print("    " + "\n    ".join(lines[-6:]), file=sys.stderr)
        return 1
    except OSError as exc:
        print(f"could not reach the TrueNAS middleware (is middlewared running?): {exc}",
              file=sys.stderr)
        return 1
    if args.out:
        write_private(args.out, json.dumps(result) + "\n")
    return 0


# ---------------------------------------------------------------------------
# envfile, get, json-get
# ---------------------------------------------------------------------------

def cmd_envfile(args) -> int:
    repo = Path(args.repo)
    values = load_values(args.values)
    # The seeding CLI points qBittorrent's search plugin at
    # http://127.0.0.1:${JACKETT_PORT}. That address is inside Gluetun's
    # network namespace, where Jackett always listens on 9117 (see
    # FIXED_CONTAINER_PORTS); JACKETT_PORT in the YAML is the host port.
    for key, port in FIXED_CONTAINER_PORTS.items():
        values[key] = str(port)
    env_io = repo_env_io(repo)
    # Create the file 0600 first; write_env then only rewrites its contents.
    write_private(args.out, "")
    env_io.write_env(Path(args.out), repo / ".env.example", values)
    os.chmod(args.out, 0o600)
    return 0


# ---------------------------------------------------------------------------
# qbit-defaults, qbit-webui-fix: qBittorrent.conf before and after seeding
# ---------------------------------------------------------------------------

# What the LinuxServer qBittorrent image puts in a new qBittorrent.conf
# (root/defaults/qBittorrent.conf in linuxserver/docker-qbittorrent). Its
# init script copies that file only when there is no qBittorrent.conf yet,
# and on a fresh install the seeding CLI creates one first, with only the
# login keys. Without these, qBittorrent would save downloads to its
# built-in default ~/Downloads, which is /config/Downloads in that image,
# i.e. in the configs dataset where FileBrowser never sees them, and UPnP
# would be on.
QBIT_DEFAULTS = (
    ("AutoRun", "enabled", "false"),
    ("AutoRun", "program", ""),
    ("LegalNotice", "Accepted", "true"),
    ("Preferences", "Connection\\UPnP", "false"),
    ("Preferences", "Connection\\PortRangeMin", "6881"),
    ("Preferences", "Downloads\\SavePath", "/downloads/"),
    ("Preferences", "Downloads\\TempPath", "/downloads/incomplete/"),
    ("Preferences", "WebUI\\Address", "*"),
    ("Preferences", "WebUI\\ServerDomains", "*"),
    # From the repository's own seed (configs/qbittorrent/qBittorrent/
    # qBittorrent.conf), which the other Docker platforms copy: VueTorrent
    # as the web UI (the VueTorrent mod puts it at /vuetorrent but does not
    # switch it on), the login asked for even from localhost, and the
    # incomplete folder actually used.
    ("BitTorrent", "Session\\TempPathEnabled", "true"),
    ("Preferences", "WebUI\\LocalHostAuth", "true"),
    ("Preferences", "WebUI\\AuthSubnetWhitelistEnabled", "false"),
    ("Preferences", "WebUI\\AlternativeUIEnabled", "true"),
    ("Preferences", "WebUI\\RootFolder", "/vuetorrent"),
)


def _seed_module(repo: Path):
    """scripts/env-editor/seed_configs.py, for its Qt-INI helper."""
    sys.path.insert(0, str(repo / "scripts" / "env-editor"))
    try:
        import seed_configs  # noqa: PLC0415
    finally:
        sys.path.pop(0)
    return seed_configs


def cmd_qbit_defaults(args) -> int:
    """Write the LinuxServer defaults to a qBittorrent.conf that does not
    exist yet. An existing file (qBittorrent has run) is left alone."""
    conf = Path(args.conf)
    if conf.exists():
        print("exists")
        return 0
    upsert = _seed_module(Path(args.repo))._upsert_ini
    text = ""
    for section, key, value in QBIT_DEFAULTS:
        text = upsert(text, section, key, value)
    conf.parent.mkdir(parents=True, exist_ok=True)
    write_private(conf, text)
    print("written")
    return 0


def _ini_sections(text: str) -> list[tuple[str | None, list[str]]]:
    sections: list[tuple[str | None, list[str]]] = [(None, [])]
    for line in text.splitlines():
        m = re.match(r"^\[([^\]]+)\]\s*$", line)
        if m:
            sections.append((m.group(1), []))
        else:
            sections[-1][1].append(line)
    return sections


def cmd_qbit_webui_fix(args) -> int:
    """Move [Preferences] WebUI\\X keys to [WebUI] X when qBittorrent has
    already done that itself.

    qBittorrent 5.3 keeps its web UI settings in a [WebUI] section. Its
    settings migration 11 (src/app/upgrade.cpp) moves the old [Preferences]
    WebUI\\... keys there once, then records Meta\\MigrationVersion and never
    looks at [Preferences] again. The seeding CLI writes the old keys, so a
    re-seeded password (a qBittorrent login change) would be ignored once
    qBittorrent has started. This does what the migration does: the seeded
    [Preferences] value replaces the one in [WebUI]. Before the first start
    (no MigrationVersion yet) nothing is changed; qBittorrent migrates the
    keys itself then."""
    conf = Path(args.conf)
    if not conf.exists():
        return 0
    text = conf.read_text(encoding="utf-8")
    version = 0
    for name, lines in _ini_sections(text):
        if name == "Meta":
            for line in lines:
                m = re.match(r"^\s*MigrationVersion\s*=\s*(\d+)\s*$", line)
                if m:
                    version = int(m.group(1))
    if version < 11:
        print("not migrated yet")
        return 0
    out: list[str] = []
    moved: list[tuple[str, str]] = []
    for name, lines in _ini_sections(text):
        if name is not None:
            out.append(f"[{name}]")
        for line in lines:
            if name == "Preferences" and line.startswith("WebUI\\") and "=" in line:
                key, value = line[len("WebUI\\"):].split("=", 1)
                moved.append((key.strip(), value))
                continue
            out.append(line)
    new = "\n".join(out) + "\n"
    upsert = _seed_module(Path(args.repo))._upsert_ini
    for key, value in moved:
        new = upsert(new, "WebUI", key, value)
    if new != text:
        mode = stat.S_IMODE(conf.stat().st_mode)
        write_private(conf, new)
        os.chmod(conf, mode)
    print(f"moved {len(moved)} key(s) to [WebUI]")
    return 0


# ---------------------------------------------------------------------------
# fetch-plugin: qBittorrent's Jackett search plugin, pinned
# ---------------------------------------------------------------------------

PLUGIN_URL = "https://raw.githubusercontent.com/qbittorrent/search-plugins/{commit}/nova3/engines/jackett.py"


def _read_pins(path: Path) -> dict[str, str]:
    """KEY=VALUE lines of native/versions.env (read as data, never run)."""
    pins: dict[str, str] = {}
    for line in path.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, value = line.split("=", 1)
        pins[key.strip()] = value.strip()
    return pins


def cmd_fetch_plugin(args) -> int:
    """Put the Jackett search plugin at --dest from the commit pinned in
    native/versions.env, checked against its sha256. The seeding CLI only
    downloads the plugin (from the search-plugins master branch) when the
    file is missing, so with this file in place it uses the pinned one.

    Exit 0: in place (or already there). Exit 4: no pins in this checkout.
    Exit 2: download failed or the checksum did not match (nothing written)."""
    dest = Path(args.dest)
    if dest.exists():
        print("exists")
        return 0
    pins_file = Path(args.repo) / "native" / "versions.env"
    pins = _read_pins(pins_file) if pins_file.is_file() else {}
    commit = pins.get("QBIT_SEARCH_PLUGINS_COMMIT", "")
    want = pins.get("QBIT_JACKETT_PLUGIN_SHA256", "").lower()
    if not re.fullmatch(r"[0-9a-f]{40}", commit) or not re.fullmatch(r"[0-9a-f]{64}", want):
        print(f"no plugin pins in {pins_file}", file=sys.stderr)
        return 4
    import urllib.request  # noqa: PLC0415
    url = PLUGIN_URL.format(commit=commit)
    try:
        with urllib.request.urlopen(url, timeout=30) as resp:  # noqa: S310 - fixed https URL
            data = resp.read(2 * 1024 * 1024)
    except OSError as exc:
        raise HelperError(f"could not download {url}: {exc}") from exc
    got = hashlib.sha256(data).hexdigest()
    if got != want:
        raise HelperError(f"{url} has sha256 {got}, expected {want}; not installing it")
    dest.parent.mkdir(parents=True, exist_ok=True)
    tmp = dest.with_name(dest.name + ".part")
    tmp.write_bytes(data)
    os.replace(tmp, dest)
    print(f"installed (search-plugins {commit[:12]})")
    return 0


# ---------------------------------------------------------------------------
# source-check: is it safe to (re)fill the repository copy's folder?
# ---------------------------------------------------------------------------

def cmd_source_check(args) -> int:
    """Decide whether install.sh may put the repository copy in --source-dir.

    install.sh empties and refills that folder (rsync --delete) and makes it
    root-owned without ACLs, so it must be a folder this installer made:
    new, empty, or holding SOURCE_MARKER. Prints STATE=new|empty|owned and,
    for an owned folder, MARKER_APP=<app the marker names>. Exit 2 with the
    reason when the folder must not be used."""
    src = args.source_dir
    if not src.startswith("/") or os.path.normpath(src) != src:
        raise HelperError(f"{src} is not a clean absolute path")
    if ":" in src or any(c.isspace() for c in src):
        raise HelperError(f"{src} contains ':' or spaces")
    roots = [os.path.normpath(r) for r in args.allowed_root or []]
    if src in roots:
        raise HelperError(f"{src} is a pool's top folder, not a folder of its own")
    if not _inside(src, roots, strict=True):
        raise HelperError(f"{src} is not inside a pool ({', '.join(roots) or 'no pools found'})")
    if "/.ix-apps/" in src + "/" or "/ix-apps/" in src + "/":
        raise HelperError(f"{src} is inside TrueNAS's own apps dataset (ix-apps)")
    for prot in args.protect or []:
        prot = os.path.normpath(prot)
        if prot == src or prot.startswith(src + "/") or src.startswith(prot + "/"):
            raise HelperError(f"{src} overlaps {prot} (the stack's configs or downloads)")
    # No symbolic links anywhere on the way: the checks above are about the
    # real folder.
    probe = src
    while not os.path.lexists(probe):
        probe = os.path.dirname(probe)
    if os.path.realpath(probe) != probe:
        raise HelperError(f"{probe} is or goes through a symbolic link")
    if not os.path.lexists(src):
        print("STATE=new")
        return 0
    if not os.path.isdir(src) or os.path.islink(src):
        raise HelperError(f"{src} exists and is not a folder")
    marker = Path(src) / SOURCE_MARKER
    if marker.is_file() and not marker.is_symlink():
        app = ""
        for line in marker.read_text(encoding="utf-8", errors="replace").splitlines():
            if line.startswith("app="):
                app = line[4:].strip()
        print("STATE=owned")
        print(f"MARKER_APP={app}")
        return 0
    with os.scandir(src) as it:
        if next(it, None) is None:
            print("STATE=empty")
            return 0
    raise HelperError(f"{src} already holds files that this installer did not put there "
                      f"(it has no {SOURCE_MARKER} file)")


def cmd_same(args) -> int:
    """Exit 0 when every given key has the same value in both files."""
    a, b = load_values(args.a), load_values(args.b)
    return 0 if all(a.get(k) == b.get(k) for k in args.keys) else 1


def cmd_get(args) -> int:
    values = load_values(args.values)
    if args.key not in values:
        raise HelperError(f"{args.key} is not set")
    print(values[args.key])
    return 0


def _json_path(node, segments: list[str]):
    if not segments:
        yield node
        return
    head, rest = segments[0], segments[1:]
    if head == "*":
        if isinstance(node, list):
            for item in node:
                yield from _json_path(item, rest)
        elif isinstance(node, dict):
            for item in node.values():
                yield from _json_path(item, rest)
        return
    if isinstance(node, dict) and head in node:
        yield from _json_path(node[head], rest)
    elif isinstance(node, list) and head.isdigit() and int(head) < len(node):
        yield from _json_path(node[int(head)], rest)


def cmd_json_get(args) -> int:
    """Print the values at a dotted path ('*' walks a list) of the JSON on
    stdin, one per line; objects and lists are printed as JSON. A path that
    is not there prints nothing."""
    raw = sys.stdin.read().strip()
    data = json.loads(raw) if raw else None
    segments = [s for s in args.path.split(".") if s] if args.path not in ("", ".") else []
    for leaf in _json_path(data, segments):
        if isinstance(leaf, bool):
            print("true" if leaf else "false")
        elif leaf is None:
            print("null")
        elif isinstance(leaf, (dict, list)):
            print(json.dumps(leaf))
        else:
            print(leaf)
    return 0


# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

def main(argv: list[str] | None = None) -> int:
    os.umask(0o077)
    p = argparse.ArgumentParser(description=__doc__.split("\n\n")[1] if __doc__ else None)
    sub = p.add_subparsers(dest="cmd", required=True)

    s = sub.add_parser("merge")
    s.add_argument("--repo", required=True)
    s.add_argument("--layer", action="append", default=[])
    s.add_argument("--out", required=True)
    s.add_argument("--show")
    s.add_argument("--generate-qbit-password", action="store_true")
    s.add_argument("--need-paths", action="store_true")
    s.set_defaults(fn=cmd_merge)

    s = sub.add_parser("extract")
    s.add_argument("--repo", required=True)
    s.add_argument("--config", required=True)
    s.add_argument("--out", required=True)
    s.add_argument("--meta", required=True)
    s.set_defaults(fn=cmd_extract)

    s = sub.add_parser("render")
    s.add_argument("--repo", required=True)
    s.add_argument("--values", required=True)
    s.add_argument("--app-name", required=True)
    s.add_argument("--source-dir", required=True)
    s.add_argument("--allowed-root", action="append")
    s.add_argument("--out-yaml", required=True)
    s.add_argument("--meta")
    s.add_argument("--redact", action="store_true")
    s.set_defaults(fn=cmd_render)

    s = sub.add_parser("diff")
    s.add_argument("--old", required=True)
    s.add_argument("--new-yaml", required=True)
    s.set_defaults(fn=cmd_diff)

    s = sub.add_parser("payload")
    s.add_argument("--mode", choices=("create", "update"), required=True)
    s.add_argument("--app-name", required=True)
    s.add_argument("--yaml", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_payload)

    s = sub.add_parser("call")
    s.add_argument("method")
    s.add_argument("--job", action="store_true")
    s.add_argument("--params")
    s.add_argument("--out")
    s.set_defaults(fn=cmd_call)

    s = sub.add_parser("envfile")
    s.add_argument("--repo", required=True)
    s.add_argument("--values", required=True)
    s.add_argument("--out", required=True)
    s.set_defaults(fn=cmd_envfile)

    s = sub.add_parser("qbit-defaults")
    s.add_argument("--repo", required=True)
    s.add_argument("--conf", required=True)
    s.set_defaults(fn=cmd_qbit_defaults)

    s = sub.add_parser("qbit-webui-fix")
    s.add_argument("--repo", required=True)
    s.add_argument("--conf", required=True)
    s.set_defaults(fn=cmd_qbit_webui_fix)

    s = sub.add_parser("fetch-plugin")
    s.add_argument("--repo", required=True)
    s.add_argument("--dest", required=True)
    s.set_defaults(fn=cmd_fetch_plugin)

    s = sub.add_parser("source-check")
    s.add_argument("--source-dir", required=True)
    s.add_argument("--allowed-root", action="append")
    s.add_argument("--protect", action="append")
    s.set_defaults(fn=cmd_source_check)

    s = sub.add_parser("same")
    s.add_argument("--a", required=True)
    s.add_argument("--b", required=True)
    s.add_argument("keys", nargs="+")
    s.set_defaults(fn=cmd_same)

    s = sub.add_parser("get")
    s.add_argument("--values", required=True)
    s.add_argument("key")
    s.set_defaults(fn=cmd_get)

    s = sub.add_parser("json-get")
    s.add_argument("path")
    s.set_defaults(fn=cmd_json_get)

    args = p.parse_args(argv)
    try:
        return args.fn(args)
    except HelperError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
