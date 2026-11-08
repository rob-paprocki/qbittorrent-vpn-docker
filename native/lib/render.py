#!/usr/bin/env python3
"""Render every native-install file that is derived from .env.

Part of qbittorrent-vpn-docker's native installer (MIT License, see LICENSE).
native/install.sh calls this; you normally do not run it by hand.

    render.py --root /opt/torrent-stack info [--env FILE]
        Print the resolved settings as JSON (paths, ports, uid/gid, whether
        the VPN and qBittorrent credentials are still placeholders).
        --env checks another .env file instead (the env-editor uses this to
        refuse values a native install cannot use before it saves them).
    render.py --root /opt/torrent-stack write [--dry-run]
        Write the systemd units, environment files, kill switch and app
        config tweaks. Only files whose content changes are written. Prints
        JSON naming the services whose files changed, so the installer
        restarts only those. --dry-run reports without writing.

Why Python and not bash: .env values can hold quotes, spaces and shell
characters (VPN passwords). Parsing and re-quoting them in bash is easy to
get subtly wrong, so this reuses the env-editor's own .env parser and does
all quoting in one place.

Security notes (see native/README.md for the full story):
  * gluetun.env and filebrowser-admin.pw hold secrets: written 0600,
    root-owned. systemd (or a root pre-start script) reads them.
  * killswitch.nft is the persistent kill switch for the torrent user.
  * The app config folders belong to the torrent user, the same user an
    exploited app would run as. Root never reads or writes files there:
    that part runs in a child process that has switched to the torrent
    user first (see as_user()), so a planted symlink gains nothing.
"""
from __future__ import annotations

import argparse
import grp
import json
import os
import pwd
import re
import stat
import sys
import tempfile
import urllib.parse
from pathlib import Path

# ---------------------------------------------------------------------------
# Fixed locations. native/install.sh uses the same values; change both.
# ---------------------------------------------------------------------------
LIB = Path("/usr/local/lib/torrent-stack")   # installed programs
ETC = Path("/etc/torrent-stack")             # rendered config (this script)
UNIT_DIR = Path("/etc/systemd/system")
TORRENT_USER = "torrent"                     # runs the apps (PUID/PGID)
GLUETUN_USER = "gluetun"                     # OpenVPN drops to this user
VPN_IFACE = "tun0"   # Gluetun's tunnel name; pinned via VPN_INTERFACE below
ENV_EDITOR_PORT = 9191
GATE_FLAG = ETC / "vpn-configured"           # exists = VPN settings filled in
KILLSWITCH_TABLE = "torrent_killswitch"

# Services in start order. The first four need the VPN and are gated.
SERVICES = ["gluetun", "qbittorrent", "jackett", "flaresolverr",
            "filebrowser", "env-editor"]
GATED = ["gluetun", "qbittorrent", "jackett", "flaresolverr"]

# Address ranges counted as "LAN" for replies to the web UIs: RFC 1918,
# carrier-grade NAT (Tailscale and similar use it), link-local, and the
# IPv6 unique-local and link-local ranges.
LAN_V4 = ["10.0.0.0/8", "100.64.0.0/10", "169.254.0.0/16",
          "172.16.0.0/12", "192.168.0.0/16"]
LAN_V6 = ["fc00::/7", "fe80::/10"]


class ConfigError(Exception):
    """A .env value the native install cannot use."""


# ---------------------------------------------------------------------------
# .env reading
# ---------------------------------------------------------------------------

def load_env(root: Path, env_path: Path | None = None) -> tuple[dict[str, str], dict[str, str]]:
    """Return (.env values, .env.example values).

    Uses scripts/env-editor/env_io.py so the native install reads .env
    exactly like the env-editor that writes it. Missing keys fall back to
    the .env.example value, as the env-editor form does.
    """
    sys.path.insert(0, str(root / "scripts" / "env-editor"))
    import env_io  # noqa: E402  (path set just above)

    # parse_env_literal undoes write_env's quoting, so a password like
    # pa"ss reaches Gluetun exactly as typed.
    example = env_io.parse_env_literal(root / ".env.example")
    current = env_io.parse_env_literal(env_path or root / ".env")
    merged = dict(example)
    merged.update(current)
    return merged, example


def _int(env: dict[str, str], key: str, lo: int, hi: int) -> int:
    raw = env.get(key, "").strip()
    if not re.fullmatch(r"[0-9]+", raw):
        raise ConfigError(f"{key} must be a number, got {raw!r}")
    value = int(raw)
    if not lo <= value <= hi:
        raise ConfigError(f"{key}={value} is outside {lo}-{hi}")
    return value


def _port(env: dict[str, str], key: str) -> int:
    value = _int(env, key, 1, 65535)
    if value < 1024:
        # In Docker, compose maps the host port to the app's fixed port
        # inside the container. Natively each app listens on the .env port
        # itself, as the unprivileged torrent user, and Linux reserves
        # ports below 1024 for root.
        raise ConfigError(
            f"{key}={value}: in a native install the apps run as the "
            f"unprivileged torrent user and cannot listen on ports below 1024. "
            f"Pick a port from 1024 to 65535.")
    return value


# Characters that cannot be written safely into a systemd unit file or the
# apps' config files (systemd reads % and $ as specifiers and variables;
# quotes and backslashes change how a line is split).
_UNSAFE_PATH_CHARS = set("%$\"'\\`")


def _check_path_chars(raw: str, key: str) -> None:
    bad = sorted({c for c in raw if c in _UNSAFE_PATH_CHARS or ord(c) < 32 or ord(c) == 127})
    if bad:
        shown = " ".join(repr(c) for c in bad)
        raise ConfigError(
            f"{key} contains {shown}. A native install writes this path into "
            f"systemd unit files, where those characters change its meaning; "
            f"rename the folder (spaces are fine).")


def _path(root: Path, raw: str, key: str, follow_symlinks: bool = True) -> Path:
    if not raw:
        raise ConfigError(f"{key} is empty")
    _check_path_chars(raw, key)
    p = Path(raw)
    # Relative paths resolve against the repo root, as in compose.
    p = p if p.is_absolute() else root / p
    if follow_symlinks:
        return p.resolve()
    # Downloads folders: keep the path as written. They may sit inside a
    # folder the torrent user owns (./downloads/incomplete does), where that
    # user could swap them for a symlink; resolving it here would hand the
    # symlink's target to root as if it were the downloads folder.
    return Path(os.path.abspath(p))


def _ancestors(path: Path) -> list[Path]:
    out = [path]
    while out[-1].parent != out[-1]:
        out.append(out[-1].parent)
    return out


def _check_root_only(path: Path, lexical: Path, key: str, puid: int, pgid: int) -> None:
    """Refuse a folder (or a parent of it) that the torrent user can change.

    Root renders files into CONFIG_PATH and runs the env-editor from the
    repo folder. If the torrent user (the user an exploited app runs as)
    could rename or replace any folder on the way there, it could make
    root write somewhere else. Both the path as written and the path after
    following symlinks are checked.
    """
    for d in dict.fromkeys(_ancestors(lexical) + _ancestors(path)):
        try:
            st = os.lstat(d)
        except FileNotFoundError:
            continue
        mode = st.st_mode
        if (st.st_uid == puid
                or (st.st_gid == pgid and mode & stat.S_IWGRP)
                or mode & stat.S_IWOTH):
            raise ConfigError(
                f"{key} ({path}) is inside {d}, which the torrent user (uid {puid}) "
                f"or everyone can change. Root writes files there, so it must be in "
                f"a folder only root can change (the default ./configs is).")


def _is_placeholder(env: dict[str, str], example: dict[str, str], key: str) -> bool:
    value = env.get(key, "").strip()
    return value == "" or value == example.get(key, "").strip()


def settings(root: Path, env_path: Path | None = None) -> dict:
    """Validate .env and return everything the renderers need."""
    env, example = load_env(root, env_path)

    puid = _int(env, "PUID", 1, 2**31 - 1)
    pgid = _int(env, "PGID", 1, 2**31 - 1)
    ports = {
        "qbittorrent": _port(env, "QBIT_WEBUI_PORT"),
        "jackett": _port(env, "JACKETT_PORT"),
        "flaresolverr": _port(env, "FLARESOLVERR_PORT"),
        "filebrowser": _port(env, "FILEBROWSER_PORT"),
    }
    used = list(ports.values()) + [ENV_EDITOR_PORT]
    if len(set(used)) != len(used):
        raise ConfigError("the four web UI ports and the env-editor port "
                          f"{ENV_EDITOR_PORT} must all be different")
    for port, what in ((8000, "Gluetun's control server"), (9999, "Gluetun's health server")):
        if port in used:
            raise ConfigError(f"port {port} is taken by {what} (on 127.0.0.1)")

    vpn_type = env.get("VPN_TYPE", "").strip().lower()
    if vpn_type == "wireguard":
        cred_keys = ["WIREGUARD_PRIVATE_KEY", "WIREGUARD_ADDRESSES"]
    elif vpn_type == "openvpn":
        cred_keys = ["OPENVPN_USER", "OPENVPN_PASSWORD"]
    else:
        raise ConfigError(f"VPN_TYPE must be wireguard or openvpn, got {vpn_type!r}")
    missing = [k for k in cred_keys if _is_placeholder(env, example, k)]
    if not env.get("VPN_PROVIDER", "").strip():
        missing.append("VPN_PROVIDER")
    qbit_missing = [k for k in ("QBITTORRENT_USER", "QBITTORRENT_PASSWORD")
                    if _is_placeholder(env, example, k)]

    for key, value in env.items():
        if "\n" in value or "\r" in value:
            raise ConfigError(f"{key} contains a line break")

    _check_path_chars(str(root), "The repo folder")
    _check_root_only(root, root, "The repo folder", puid, pgid)
    config_root = _path(root, env.get("CONFIG_PATH", ""), "CONFIG_PATH")
    raw_cfg = Path(env.get("CONFIG_PATH", ""))
    lexical_cfg = Path(os.path.abspath(raw_cfg if raw_cfg.is_absolute() else root / raw_cfg))
    _check_root_only(config_root, lexical_cfg, "CONFIG_PATH", puid, pgid)
    return {
        "root": str(root),
        "env": env,
        "puid": puid,
        "pgid": pgid,
        "tz": env.get("TZ", "").strip() or "UTC",
        "ports": ports,
        "config_root": str(config_root),
        "downloads_root": str(_path(root, env.get("DOWNLOADS_PATH", ""), "DOWNLOADS_PATH", False)),
        "incomplete_root": str(_path(root, env.get("INCOMPLETE_DOWNLOADS", ""), "INCOMPLETE_DOWNLOADS", False)),
        "vpn_configured": not missing,
        "vpn_missing": missing,
        "qbit_configured": not qbit_missing,
        "qbit_user": env.get("QBITTORRENT_USER", ""),
        "qbit_password": env.get("QBITTORRENT_PASSWORD", ""),
    }


# ---------------------------------------------------------------------------
# Small helpers
# ---------------------------------------------------------------------------

def sd_quote(value: str) -> str:
    """Quote a value for a systemd EnvironmentFile.

    systemd (checked on 257) unescapes \\" \\\\ \\$ and \\` inside double
    quotes and does no $VAR expansion, so this keeps any value literal.
    """
    for ch in ("\\", '"', "$", "`"):
        value = value.replace(ch, "\\" + ch)
    return f'"{value}"'


def sd_arg(value: str) -> str:
    """Quote one ExecStart= argument so systemd passes it on literally.

    systemd splits ExecStart= at spaces, reads %x as specifiers and $X as
    variables. Inside double quotes \\ and " are escaped; %% and $$ are the
    literal % and $. (settings() already refuses %, $, quotes and
    backslashes in paths; this keeps spaces working.)
    """
    value = value.replace("\\", "\\\\").replace('"', '\\"')
    value = value.replace("%", "%%").replace("$", "$$")
    return f'"{value}"'


def sd_path(value: str) -> str:
    """A path for settings like WorkingDirectory= (no splitting there)."""
    return value.replace("%", "%%")


def doc_url(path: Path) -> str:
    """A file:// URL for Documentation= (space-separated, so encode spaces)."""
    return "file://" + urllib.parse.quote(str(path)).replace("%", "%%")


def env_file(pairs: list[tuple[str, str]], header: str) -> str:
    lines = [f"# {line}".rstrip() for line in header.strip().splitlines()]
    lines += [f"{k}={sd_quote(v)}" for k, v in pairs]
    return "\n".join(lines) + "\n"


def lookup_ids(name: str) -> tuple[int, int] | None:
    try:
        entry = pwd.getpwnam(name)
    except KeyError:
        return None
    return entry.pw_uid, entry.pw_gid


class Writer:
    """Collects file writes; writes only real changes; remembers who cares."""

    def __init__(self, dry_run: bool):
        self.dry_run = dry_run
        self.changed: dict[str, list[str]] = {}

    def write(self, path: Path, content: str, services: list[str],
              mode: int = 0o644, owner: tuple[int, int] = (0, 0)) -> bool:
        data = content.encode("utf-8")
        try:
            same = path.read_bytes() == data
        except FileNotFoundError:
            same = False
        if same:
            if not self.dry_run:
                self._fix_meta(path, mode, owner)
            return False
        for svc in services or ["-"]:
            self.changed.setdefault(svc, []).append(str(path))
        if self.dry_run:
            return True
        path.parent.mkdir(parents=True, exist_ok=True)
        # Write to a temp file in the same folder, then rename over the
        # target: a reader never sees a half-written file.
        fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.")
        try:
            os.fchmod(fd, mode)
            os.fchown(fd, *owner)
            with os.fdopen(fd, "wb") as fh:
                fh.write(data)
            os.replace(tmp, path)
        except BaseException:
            try:
                os.unlink(tmp)
            except FileNotFoundError:
                pass
            raise
        return True

    def remove(self, path: Path, services: list[str]) -> None:
        if path.exists() or path.is_symlink():
            for svc in services:
                self.changed.setdefault(svc, []).append(str(path))
            if not self.dry_run:
                path.unlink()

    def symlink(self, link: Path, target: Path, services: list[str]) -> None:
        if link.is_symlink() and os.readlink(link) == str(target):
            return
        if link.exists() and not link.is_symlink():
            raise ConfigError(f"{link} exists and is not a symlink; move it away")
        for svc in services:
            self.changed.setdefault(svc, []).append(str(link))
        if not self.dry_run:
            if link.is_symlink():
                link.unlink()
            link.symlink_to(target)

    @staticmethod
    def _fix_meta(path: Path, mode: int, owner: tuple[int, int]) -> None:
        st = path.stat()
        if (st.st_mode & 0o7777) != mode:
            os.chmod(path, mode)
        if (st.st_uid, st.st_gid) != owner:
            os.chown(path, *owner)


# ---------------------------------------------------------------------------
# Gluetun
# ---------------------------------------------------------------------------

def gluetun_env(s: dict, gluetun_ids: tuple[int, int]) -> str:
    env, root, ports = s["env"], Path(s["root"]), s["ports"]
    # Same variables as the gluetun service in compose.yaml, in the same
    # order. Gluetun's other defaults come from image-defaults.env, which
    # the installer extracts from the Dockerfile of the version it built.
    pairs = [
        ("VPN_SERVICE_PROVIDER", env.get("VPN_PROVIDER", "")),
        ("VPN_TYPE", env.get("VPN_TYPE", "")),
        ("OPENVPN_USER", env.get("OPENVPN_USER", "")),
        ("OPENVPN_PASSWORD", env.get("OPENVPN_PASSWORD", "")),
        ("OPENVPN_PROTOCOL", env.get("OPENVPN_PROTOCOL", "")),
        ("WIREGUARD_PRIVATE_KEY", env.get("WIREGUARD_PRIVATE_KEY", "")),
        ("WIREGUARD_ADDRESSES", env.get("WIREGUARD_ADDRESSES", "")),
        ("PORT_FORWARD_ONLY", env.get("PORT_FORWARD_ONLY", "")),
        ("VPN_PORT_FORWARDING", env.get("VPN_PORT_FORWARDING", "")),
        ("SERVER_COUNTRIES", env.get("SERVER_COUNTRIES", "")),
        ("TZ", s["tz"]),
        # Run through /bin/sh: the script is not marked executable in git.
        ("VPN_PORT_FORWARDING_UP_COMMAND", f"/bin/sh {root / 'update-qbittorrent.sh'}"),
        ("QBIT_WEBUI_PORT", str(ports["qbittorrent"])),
        ("QBITTORRENT_USER", env.get("QBITTORRENT_USER", "")),
        ("QBITTORRENT_PASSWORD", env.get("QBITTORRENT_PASSWORD", "")),
        ("SCRIPT_NOTIFY_URL", env.get("SCRIPT_NOTIFY_URL", "")),
        # ---- native-only settings below ----
        # The kill switch allows exactly this interface name, so pin it.
        # (The Docker image sets the same value.)
        ("VPN_INTERFACE", VPN_IFACE),
        # update-qbittorrent.sh reads the forwarded port from this file.
        ("VPN_PORT_FORWARDING_STATUS_FILE", "/tmp/gluetun/forwarded_port"),
        # In Docker these servers are private to the container; here the
        # container is on your LAN, so bind them to loopback only.
        ("HTTP_CONTROL_SERVER_ADDRESS", "127.0.0.1:8000"),
        ("HEALTH_SERVER_ADDRESS", "127.0.0.1:9999"),
        # Gluetun's firewall drops inbound LAN connections except on these
        # ports. In Docker, compose's port publishing did this job.
        ("FIREWALL_INPUT_PORTS", ",".join(str(p) for p in (
            ports["qbittorrent"], ports["jackett"], ports["flaresolverr"],
            ports["filebrowser"], ENV_EDITOR_PORT))),
        # OpenVPN drops privileges to this user. It must not be the torrent
        # user: the kill switch would block OpenVPN's own traffic.
        ("PUID", str(gluetun_ids[0])),
        ("PGID", str(gluetun_ids[1])),
        # Versions are pinned in native/versions.env, so skip Gluetun's
        # check for a newer release.
        ("VERSION_INFORMATION", "off"),
    ]
    return env_file(pairs, """
Generated by native/install.sh from /opt/torrent-stack/.env. Do not edit:
change .env (env-editor) and run `native/install.sh apply`. For extra
Gluetun settings create /etc/torrent-stack/gluetun.local.env (loaded last).
""")


# ---------------------------------------------------------------------------
# Kill switch (nftables)
# ---------------------------------------------------------------------------

def killswitch(s: dict) -> str:
    ports = ", ".join(str(p) for p in s["ports"].values())
    uid = s["puid"]
    return f"""#!/usr/sbin/nft -f
# torrent-stack kill switch. Generated by native/install.sh; do not edit.
#
# What it does, in plain words: every packet sent by a program running as
# the torrent user (uid {uid}: qBittorrent, Jackett, FlareSolverr,
# FileBrowser) may leave only
#   * over loopback (lo), to reach the other apps and Gluetun's DNS (but
#     not Gluetun's control and health servers or the env-editor),
#   * over the VPN tunnel ({VPN_IFACE}),
#   * as a reply to a connection a LAN device opened to one of the web UI
#     ports ({ports}).
# Everything else from that user is dropped. This does not depend on
# Gluetun running: with Gluetun stopped there is no {VPN_IFACE}, so the torrent
# user simply has no internet. DNS is only allowed to 127.0.0.1 (Gluetun's
# resolver, which forwards through the tunnel) or through the tunnel.
#
# Loading this file replaces the table in one step (the first two lines),
# so there is never a moment without rules.

table inet {KILLSWITCH_TABLE}
delete table inet {KILLSWITCH_TABLE}

table inet {KILLSWITCH_TABLE} {{
    set webui_ports {{
        type inet_service
        elements = {{ {ports} }}
    }}

    set lan_v4 {{
        type ipv4_addr
        flags interval
        elements = {{ {", ".join(LAN_V4)} }}
    }}

    set lan_v6 {{
        type ipv6_addr
        flags interval
        elements = {{ {", ".join(LAN_V6)} }}
    }}

    chain output {{
        type filter hook output priority filter; policy accept;
        # Only the torrent user's packets are inspected; everything else
        # (root, Gluetun, OpenVPN, the env-editor) passes untouched.
        meta skuid {uid} jump torrent_out
    }}

    chain torrent_out {{
        # DNS over loopback only to Gluetun's resolver on 127.0.0.1. This
        # blocks local stub resolvers (127.0.0.53 and friends), which would
        # forward the query outside the tunnel.
        oifname "lo" meta l4proto {{ tcp, udp }} th dport {{ 53, 853 }} ip daddr != 127.0.0.1 counter drop
        oifname "lo" meta nfproto ipv6 meta l4proto {{ tcp, udp }} th dport {{ 53, 853 }} counter drop
        # The apps have no business with Gluetun's control server (8000),
        # its health server (9999) or the env-editor ({ENV_EDITOR_PORT}): all run as
        # root, and without an auth file Gluetun v3.41's control server
        # answers some requests without a password (public IP, forwarded
        # port, even stopping the VPN).
        oifname "lo" tcp dport {{ 8000, 9999, {ENV_EDITOR_PORT} }} counter drop
        oifname "lo" counter accept
        oifname "{VPN_IFACE}" counter accept
        # Replies to LAN devices using the web UIs, VPN up or down.
        ct direction reply ct original proto-dst @webui_ports ct original ip saddr @lan_v4 counter accept
        ct direction reply ct original proto-dst @webui_ports ct original ip6 saddr @lan_v6 counter accept
        counter drop
    }}
}}
"""


# ---------------------------------------------------------------------------
# systemd units
# ---------------------------------------------------------------------------

# Files each app unit sees instead of the container's own (see dns_view()).
APP_RESOLVE = ETC / "app-resolve"          # resolv.conf: nameserver 127.0.0.1
GLUETUN_RESOLVE = ETC / "gluetun-resolve"  # Gluetun's private, writable copy
NSSWITCH = ETC / "nsswitch.conf"           # hosts: files dns
RESOLVED_DIR = Path("/run/systemd/resolve")


def resolv_target() -> Path:
    """The file /etc/resolv.conf really is (it is often a symlink)."""
    return Path(os.path.realpath("/etc/resolv.conf"))


def dns_view(writable: bool) -> list[str]:
    """systemd lines that give a unit its own resolv.conf.

    Why a folder and not just the file: a bind mount on a single file is
    silently dropped in the unit's namespace when the host replaces that
    file by renaming a new one over it, which systemd-resolved and DHCP
    clients do. So when /etc/resolv.conf is a symlink into a folder (as on
    Incus' Debian images: /run/systemd/resolve/), the whole folder is
    replaced in the unit's view. Renames on the host then happen in the
    real folder, which the unit no longer sees, and cannot undo this.
    When /etc/resolv.conf is a plain file (as on Proxmox), the file itself
    is bind-mounted; stack-check.sh restarts a unit that lost it.
    """
    src = GLUETUN_RESOLVE if writable else APP_RESOLVE
    key = "BindPaths" if writable else "BindReadOnlyPaths"
    target = resolv_target()
    lines = []
    if target.parent != Path("/etc"):
        lines.append(f"{key}={src}:{target.parent}")
    else:
        lines.append(f"{key}={src}/resolv.conf:{target}")
    if not writable and RESOLVED_DIR.is_dir() and target.parent != RESOLVED_DIR:
        # Also hide systemd-resolved's socket (see below).
        lines.append(f"BindReadOnlyPaths={APP_RESOLVE}:{RESOLVED_DIR}")
    return lines


def resolve_names() -> list[str]:
    """File names the private resolv.conf folders must contain."""
    return sorted({"resolv.conf", "stub-resolv.conf", resolv_target().name})


def units(s: dict) -> dict[str, str]:
    root = Path(s["root"])
    cfg = Path(s["config_root"])
    lib_dir = root / "native" / "lib"
    doc = f"Documentation={doc_url(root / 'native' / 'README.md')}"
    gate = (f"# Startup gating: skipped (not failed) until .env holds real VPN\n"
            f"# settings. native/install.sh apply creates this file.\n"
            f"ConditionPathExists={GATE_FLAG}")
    # Every unit that runs as the torrent user is tied to the kill switch:
    # it is not started unless the kill switch loaded, and refuses to start
    # if the table has gone missing since (for example after someone ran
    # `nft flush ruleset`).
    app_dns = "\n".join(dns_view(writable=False))
    torrent_common = f"""User={TORRENT_USER}
Group={TORRENT_USER}
NoNewPrivileges=yes
# Its own /tmp: the apps cannot touch root's or Gluetun's files in /tmp.
PrivateTmp=yes
# Name lookups go only to Gluetun's DNS on 127.0.0.1 (see native/README.md,
# "DNS"): a private resolv.conf, and an nsswitch.conf whose hosts line is
# "files dns", so glibc never hands a lookup to a local helper such as
# systemd-resolved (libnss-resolve), nscd or avahi. Those helpers run as
# other users, so the kill switch could not stop their queries. Their
# sockets, and the D-Bus system bus (systemd-resolved also answers lookups
# there), are hidden from the apps as well; none of the apps needs them.
BindReadOnlyPaths={NSSWITCH}:/etc/nsswitch.conf
{app_dns}
InaccessiblePaths=-/run/nscd -/run/avahi-daemon -/run/dbus
ExecStartPre=+/bin/sh -c '/usr/sbin/nft list table inet {KILLSWITCH_TABLE} >/dev/null'"""
    torrent_after = ("After=network-online.target torrent-killswitch.service\n"
                     "Requires=torrent-killswitch.service")
    vpn_after = ("After=network-online.target torrent-killswitch.service torrent-gluetun.service\n"
                 "Requires=torrent-killswitch.service\n"
                 # Wants, not Requires: stopping Gluetun must not stop the
                 # apps (their web UIs stay reachable; the kill switch keeps
                 # them offline).
                 "Wants=network-online.target torrent-gluetun.service")
    out: dict[str, str] = {}

    out["torrent-killswitch.service"] = f"""[Unit]
Description=torrent-stack kill switch: torrent user may only use loopback and the VPN
{doc}
# Loaded early, before the network and before any app.
DefaultDependencies=no
After=local-fs.target nftables.service
Before=network-pre.target shutdown.target
Wants=network-pre.target
Conflicts=shutdown.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f {ETC}/killswitch.nft
ExecReload=/usr/sbin/nft -f {ETC}/killswitch.nft
# No ExecStop on purpose: stopping this unit leaves the rules in force.
# `native/install.sh uninstall` removes them.

[Install]
WantedBy=sysinit.target
"""

    out["torrent-killswitch-check.service"] = f"""[Unit]
Description=torrent-stack: check the kill switch and the apps' private DNS files
{doc}

[Service]
Type=oneshot
# Runs every minute: keep the routine start/finish lines out of the journal.
# Its warnings carry a "<4>" prefix, so they still show.
LogLevelMax=notice
ExecStart=/bin/bash {sd_arg(str(lib_dir / 'stack-check.sh'))}
"""

    out["torrent-killswitch-check.timer"] = f"""[Unit]
Description=torrent-stack: check the kill switch every minute
{doc}

[Timer]
OnBootSec=1min
OnUnitActiveSec=1min
AccuracySec=10s

[Install]
WantedBy=timers.target
"""

    gluetun_dns = "\n".join(dns_view(writable=True))
    out["torrent-gluetun.service"] = f"""[Unit]
Description=torrent-stack: Gluetun VPN client (VPN tunnel, its firewall and DNS)
{doc}
Documentation=https://github.com/qdm12/gluetun-wiki
After=network-online.target torrent-killswitch.service
Wants=network-online.target
Requires=torrent-killswitch.service
{gate}

[Service]
Type=simple
# Gluetun's own defaults (from its Dockerfile), then the .env settings,
# then optional local overrides.
EnvironmentFile={LIB}/gluetun/image-defaults.env
EnvironmentFile={ETC}/gluetun.env
EnvironmentFile=-{ETC}/gluetun.local.env
# systemd sets USER; Gluetun reads it as an old name for OPENVPN_USER.
UnsetEnvironment=USER LOGNAME
# openvpn2.6 -> Debian's openvpn (Gluetun calls it by that name).
Environment=PATH={LIB}/gluetun/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Gluetun rewrites /etc/resolv.conf to point at its own DNS server. Give it
# a private copy so the container's own resolver (used by root, apt and
# this installer) keeps working when Gluetun is stopped.
{gluetun_dns}
# Remember the iptables rules from before Gluetun, so they can be put back
# exactly when it stops (Gluetun adds its own and leaves them behind).
ExecStartPre=+/bin/bash {sd_arg(str(lib_dir / 'gluetun-iptables.sh'))} save
ExecStart={LIB}/gluetun/gluetun
# Gluetun leaves its firewall (default DROP) in place when it exits. Undo
# it so root keeps internet access for updates; the torrent user stays
# blocked by the kill switch.
ExecStopPost=+/bin/bash {sd_arg(str(lib_dir / 'gluetun-iptables.sh'))} restore
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
"""

    out["torrent-qbittorrent.service"] = f"""[Unit]
Description=torrent-stack: qBittorrent with the VueTorrent web UI (internet only through the VPN)
{doc}
{vpn_after}
{gate}

[Service]
Type=simple
{torrent_common}
EnvironmentFile={ETC}/qbittorrent.env
WorkingDirectory={sd_path(str(cfg / 'qbittorrent'))}
ExecStart={LIB}/qbittorrent/qbittorrent-nox --webui-port=${{QBIT_WEBUI_PORT}}
Restart=on-failure
RestartSec=5
# qBittorrent saves resume data on the way out; give it time.
TimeoutStopSec=90

[Install]
WantedBy=multi-user.target
"""

    out["torrent-jackett.service"] = f"""[Unit]
Description=torrent-stack: Jackett indexer proxy (internet only through the VPN)
{doc}
{vpn_after}
{gate}

[Service]
Type=simple
{torrent_common}
EnvironmentFile={ETC}/jackett.env
WorkingDirectory={sd_path(str(cfg / 'jackett'))}
# --NoUpdates: versions are pinned in native/versions.env.
ExecStart={LIB}/jackett/jackett --NoUpdates --NoRestart --ListenPublic --Port=${{JACKETT_PORT}} {sd_arg('--DataFolder=' + str(cfg / 'jackett' / 'Jackett'))}
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
"""

    out["torrent-flaresolverr.service"] = f"""[Unit]
Description=torrent-stack: FlareSolverr (internet only through the VPN)
{doc}
{vpn_after}
{gate}

[Service]
Type=simple
{torrent_common}
EnvironmentFile={ETC}/flaresolverr.env
WorkingDirectory={sd_path(str(cfg / 'flaresolverr'))}
# Keep FlareSolverr's patched copy of Debian's chromedriver in step with
# the installed chromium package.
ExecStartPre=+/bin/bash {sd_arg(str(lib_dir / 'flaresolverr-prestart.sh'))} {TORRENT_USER}
ExecStart={LIB}/flaresolverr/venv/bin/python -u {LIB}/flaresolverr/src/flaresolverr.py
Restart=on-failure
RestartSec=5
TimeoutStopSec=30

[Install]
WantedBy=multi-user.target
"""

    out["torrent-filebrowser.service"] = f"""[Unit]
Description=torrent-stack: FileBrowser Quantum for the downloads folder
{doc}
{torrent_after}
Wants=network-online.target

[Service]
Type=simple
{torrent_common}
EnvironmentFile={ETC}/filebrowser.env
WorkingDirectory={sd_path(str(cfg / 'filebrowser'))}
# Set the admin password from {ETC}/filebrowser-admin.pw (root-only),
# passed on stdin to a short `filebrowser user set` run as the torrent
# user. The password is never in the server's environment, where the other
# apps (same user) could read it.
ExecStartPre=+/bin/bash {sd_arg(str(lib_dir / 'filebrowser-prestart.sh'))} {TORRENT_USER}
ExecStart={LIB}/filebrowser/filebrowser -c {ETC}/filebrowser.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"""

    out["torrent-env-editor.service"] = f"""[Unit]
Description=torrent-stack: env-editor web UI for .env (port {ENV_EDITOR_PORT})
{doc}
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# Runs as root: it rewrites .env and restarts the other units.
Environment=TS_MODE=native
Environment=ENV_EDITOR_BIND=0.0.0.0:{ENV_EDITOR_PORT}
Environment=PYTHONUNBUFFERED=1
WorkingDirectory={sd_path(str(root))}
ExecStart={sd_arg(str(root / 'scripts' / 'env-editor' / '.venv' / 'bin' / 'python'))} {sd_arg(str(root / 'scripts' / 'env-editor' / 'app.py'))}
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
"""
    return out


# ---------------------------------------------------------------------------
# App configs
# ---------------------------------------------------------------------------

def app_envs(s: dict, bootstrap_password: str | None) -> dict[str, tuple[str, int]]:
    cfg = Path(s["config_root"])
    ports = s["ports"]
    common = [("TZ", s["tz"]), ("LANG", "C.UTF-8")]
    header = "Generated by native/install.sh from .env. Do not edit."
    out = {
        # Same HOME/XDG layout as the LinuxServer image (/config), so the
        # config files sit where the compose stack keeps them.
        "qbittorrent": (env_file(common + [
            ("HOME", f"{cfg}/qbittorrent"),
            ("XDG_CONFIG_HOME", f"{cfg}/qbittorrent"),
            ("XDG_DATA_HOME", f"{cfg}/qbittorrent"),
            ("XDG_CACHE_HOME", f"{cfg}/qbittorrent/.cache"),
            ("QBIT_WEBUI_PORT", str(ports["qbittorrent"])),
        ], header), 0o644),
        "jackett": (env_file(common + [
            ("HOME", f"{cfg}/jackett"),
            ("XDG_CONFIG_HOME", f"{cfg}/jackett"),
            ("JACKETT_PORT", str(ports["jackett"])),
        ], header), 0o644),
        "flaresolverr": (env_file(common + [
            ("HOME", f"{cfg}/flaresolverr"),
            ("LOG_LEVEL", "info"),
            ("HOST", "0.0.0.0"),
            ("PORT", str(ports["flaresolverr"])),
        ], header), 0o644),
    }
    out["filebrowser"] = (env_file(common + [("HOME", f"{cfg}/filebrowser")], header), 0o644)
    return out


def filebrowser_password(s: dict, bootstrap_password: str | None) -> str | None:
    """FileBrowser's admin password, for filebrowser-admin.pw.

    Real qBittorrent credentials -> the same password as qBittorrent (as the
    env-editor seeds it in Docker mode). Placeholders -> the env-editor's
    first-run password, so nobody gets a known default login.
    native/lib/filebrowser-prestart.sh feeds it to FileBrowser on stdin.
    """
    if s["qbit_configured"]:
        return s["qbit_password"]
    return bootstrap_password


def filebrowser_yaml(s: dict) -> str:
    cfg = Path(s["config_root"])
    # Always "admin": FileBrowser resets the password of an existing admin
    # user on start but never renames or creates one, so a changing
    # QBITTORRENT_USER here would leave you with no working login.
    admin = "admin"
    return "\n".join([
        "# FileBrowser Quantum config. Generated by native/install.sh; do not edit.",
        "# Only the downloads folder is shared: never point it at configs or .env.",
        "http:",
        f"  port: {s['ports']['filebrowser']}",
        '  listen: "0.0.0.0"',
        "server:",
        "  disableUpdateCheck: true",
        f"  cacheDir: {json.dumps(str(cfg / 'filebrowser' / 'cache'))}",
        "  database:",
        f"    path: {json.dumps(str(cfg / 'filebrowser' / 'filebrowser.db'))}",
        "  sources:",
        f"    - path: {json.dumps(s['downloads_root'])}",
        '      name: "downloads"',
        "auth:",
        f"  adminUsername: {json.dumps(admin)}",
        "",
    ])


def move_webui_keys(text: str) -> tuple[str, list[tuple[str, str]]]:
    """Take `WebUI\\X=...` lines out of [Preferences]; return (text, [(X, value)]).

    qBittorrent 5.3 and later read web UI settings from a [WebUI] section
    (their settings migration 11 moves them there once, on first start).
    The env-editor's seeder writes the old [Preferences] WebUI\\... keys,
    so after that first start a re-seeded password would be ignored. The
    native install moves such keys into [WebUI] itself, exactly as that
    migration does (newest value wins).
    """
    out, moved, section = [], [], None
    for line in text.splitlines():
        m = re.match(r"^\[([^\]]+)\]\s*$", line)
        if m:
            section = m.group(1)
        elif section == "Preferences" and line.startswith("WebUI\\") and "=" in line:
            key, value = line[len("WebUI\\"):].split("=", 1)
            moved.append((key.strip(), value))
            continue
        out.append(line)
    return "\n".join(out) + ("\n" if text.endswith("\n") or not text else ""), moved


def qbittorrent_conf(s: dict, current: str) -> str:
    """Point qBittorrent at the real paths (the Docker seed uses /downloads)."""
    sys.path.insert(0, str(Path(s["root"]) / "scripts" / "env-editor"))
    from seed_configs import _upsert_ini  # Qt-INI aware key upsert

    text, moved = move_webui_keys(current)
    for key, value in moved:
        text = _upsert_ini(text, "WebUI", key, value)
    for section, key, value in [
        ("LegalNotice", "Accepted", "true"),
        ("BitTorrent", "Session\\DefaultSavePath", s["downloads_root"]),
        ("BitTorrent", "Session\\TempPath", s["incomplete_root"]),
        ("BitTorrent", "Session\\TempPathEnabled", "true"),
        ("WebUI", "Port", str(s["ports"]["qbittorrent"])),
        ("WebUI", "AlternativeUIEnabled", "true"),
        ("WebUI", "RootFolder", str(LIB / "vuetorrent")),
    ]:
        text = _upsert_ini(text, section, key, value)
    return text


def jackett_server_config(s: dict, current: str) -> str | None:
    """Keep Jackett's FlareSolverr URL and port in step with .env."""
    try:
        data = json.loads(current) if current.strip() else {}
    except json.JSONDecodeError:
        return None  # leave a file Jackett wrote and we cannot parse alone
    data["Port"] = s["ports"]["jackett"]
    data["AllowExternal"] = True
    data["FlareSolverrUrl"] = f"http://127.0.0.1:{s['ports']['flaresolverr']}"
    data["UpdateDisabled"] = True
    return json.dumps(data, indent=2)


def jackett_plugin_wiring(s: dict, current: str) -> str | None:
    """Keep the qBittorrent search plugin's Jackett URL in step with .env."""
    try:
        data = json.loads(current)
    except json.JSONDecodeError:
        return None
    data["url"] = f"http://127.0.0.1:{s['ports']['jackett']}"
    return json.dumps(data, indent=2)


# ---------------------------------------------------------------------------
# Files inside the app config folders: handled as the torrent user
# ---------------------------------------------------------------------------

def warn(text: str) -> None:
    print(f"render: warning: {text}", file=sys.stderr)


def read_text(path: Path) -> str:
    """Read a root-owned file (missing = empty)."""
    try:
        return path.read_text(encoding="utf-8")
    except FileNotFoundError:
        return ""


def read_app_file(path: Path) -> str | None:
    """Read a file in an app config folder; None means "leave it alone".

    Called only after switching to the torrent user (see as_user()), so it
    can never read anything that user could not read anyway. O_NOFOLLOW and
    the regular-file check stop a planted symlink or FIFO from turning the
    config into a copy of another file, or hanging the installer.
    """
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC)
    except FileNotFoundError:
        return ""
    except OSError as exc:
        warn(f"left {path} alone: {exc.strerror} (a symlink or unreadable file)")
        return None
    with os.fdopen(fd, "rb") as fh:
        if not stat.S_ISREG(os.fstat(fh.fileno()).st_mode):
            warn(f"left {path} alone: not a regular file")
            return None
        try:
            return fh.read().decode("utf-8")
        except UnicodeDecodeError:
            warn(f"left {path} alone: not UTF-8 text")
            return None


def app_config_changes(s: dict, dry_run: bool) -> dict[str, list[str]]:
    """Update the three app config files that depend on .env.

    Runs as the torrent user. `s` holds no secrets here (see write_all).
    """
    w = Writer(dry_run)
    ids = (os.getuid(), os.getgid())
    cfg = Path(s["config_root"])

    qconf = cfg / "qbittorrent" / "qBittorrent" / "qBittorrent.conf"
    current = read_app_file(qconf)
    if current is not None:
        w.write(qconf, qbittorrent_conf(s, current), ["qbittorrent"], 0o644, ids)

    sconf = cfg / "jackett" / "Jackett" / "ServerConfig.json"
    current = read_app_file(sconf)
    new = jackett_server_config(s, current) if current is not None else None
    if new is not None:
        w.write(sconf, new, ["jackett"], 0o644, ids)

    wiring = cfg / "qbittorrent" / "qBittorrent" / "nova3" / "engines" / "jackett.json"
    current = read_app_file(wiring)
    if current:
        new = jackett_plugin_wiring(s, current)
        if new is not None:
            # Read by the plugin on each search: no restart needed.
            w.write(wiring, new, [], 0o644, ids)
    return w.changed


def as_user(uid: int, gid: int, fn, *args):
    """Run fn(*args) in a child process that has become uid/gid first.

    The result travels back as JSON. Root itself never opens a path inside
    the torrent user's folders. (After the switch the child is also not
    "dumpable", so other torrent-user processes cannot read its memory.)
    """
    if os.geteuid() != 0:
        return fn(*args)
    sys.stdout.flush()
    sys.stderr.flush()
    rfd, wfd = os.pipe()
    pid = os.fork()
    if pid == 0:  # child
        code = 1
        try:
            os.close(rfd)
            os.setgroups([])
            os.setgid(gid)
            os.setuid(uid)
            result = fn(*args)
            with os.fdopen(wfd, "w", encoding="utf-8") as fh:
                json.dump(result, fh)
            code = 0
        except BaseException as exc:  # noqa: BLE001  (report anything)
            try:
                print(f"render: as uid {uid}: {type(exc).__name__}: {exc}", file=sys.stderr)
                sys.stderr.flush()
            except BaseException:  # noqa: BLE001
                pass
        os._exit(code)
    os.close(wfd)
    with os.fdopen(rfd, "r", encoding="utf-8") as fh:
        data = fh.read()
    _, status = os.waitpid(pid, 0)
    if os.waitstatus_to_exitcode(status) != 0:
        raise RuntimeError(f"updating the app configs as uid {uid} failed (see above)")
    return json.loads(data)


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

NSSWITCH_CONF = """\
# Generated by native/install.sh. Bind-mounted over /etc/nsswitch.conf for
# the apps. "hosts: files dns" makes glibc read /etc/hosts and then ask the
# DNS server in resolv.conf (Gluetun's, 127.0.0.1) directly, never a local
# helper such as systemd-resolved, nscd or avahi, which would ask the LAN's
# DNS server outside the VPN.
passwd:         files
group:          files
shadow:         files
gshadow:        files
hosts:          files dns
networks:       files
protocols:      files
services:       files
ethers:         files
rpc:            files
netgroup:       files
"""

APP_RESOLV_CONF = """\
# Generated by native/install.sh. What the apps see as /etc/resolv.conf:
# Gluetun's DNS server, which answers through the VPN.
nameserver 127.0.0.1
options edns0
"""

TMPFILES_CONF = """\
# Generated by native/install.sh. Debian 13 deletes files in /tmp that were
# not used for 10 days. Gluetun creates /tmp/gluetun once, at start, and
# keeps the forwarded port and public IP there; without it, port forwarding
# stops updating qBittorrent after the next reconnect.
x /tmp/gluetun
"""


def write_all(s: dict, dry_run: bool) -> dict:
    w = Writer(dry_run)
    cfg = Path(s["config_root"])
    torrent_ids = lookup_ids(TORRENT_USER) or (s["puid"], s["pgid"])
    gluetun_ids = lookup_ids(GLUETUN_USER)
    if gluetun_ids is None:
        raise ConfigError(f"system user {GLUETUN_USER!r} is missing; run native/install.sh install")
    bootstrap = read_text(ETC / "bootstrap-password").strip() or None

    if not dry_run:
        ETC.mkdir(mode=0o755, parents=True, exist_ok=True)

    w.write(ETC / "gluetun.env", gluetun_env(s, gluetun_ids), ["gluetun"], 0o600)
    w.write(ETC / "killswitch.nft", killswitch(s), ["killswitch"])

    # The apps' private DNS files (see dns_view()).
    w.write(NSSWITCH, NSSWITCH_CONF, [])
    for name in resolve_names():
        w.write(APP_RESOLVE / name, APP_RESOLV_CONF, [])
        # Gluetun's private copies start as a copy of the container's
        # resolv.conf; Gluetun then rewrites them. Created once, never reset.
        if not (GLUETUN_RESOLVE / name).exists():
            w.write(GLUETUN_RESOLVE / name, read_text(Path("/etc/resolv.conf")), [])
    # Files used by earlier versions of this installer.
    w.remove(ETC / "resolv.conf", [])
    w.remove(ETC / "gluetun-resolv.conf", [])
    w.write(Path("/etc/tmpfiles.d/torrent-stack.conf"), TMPFILES_CONF, [])

    for name, (content, mode) in app_envs(s, bootstrap).items():
        w.write(ETC / f"{name}.env", content, [name], mode)
    w.write(ETC / "filebrowser.yaml", filebrowser_yaml(s), ["filebrowser"])
    fb_pw = filebrowser_password(s, bootstrap)
    if fb_pw:
        w.write(ETC / "filebrowser-admin.pw", fb_pw + "\n", ["filebrowser"], 0o600)

    # The startup gate.
    if s["vpn_configured"]:
        if not GATE_FLAG.exists():
            w.write(GATE_FLAG, "# VPN settings in .env are filled in; see native/README.md\n", GATED)
    else:
        w.remove(GATE_FLAG, GATED)

    for unit, content in units(s).items():
        svc = unit.removeprefix("torrent-").rsplit(".", 1)[0]
        if svc.startswith("killswitch"):
            svc = "killswitch"
        w.write(UNIT_DIR / unit, content, [svc, "_units"])

    # Gluetun keeps servers.json and friends in /gluetun (a volume in Docker).
    w.symlink(Path("/gluetun"), cfg / "gluetun", ["gluetun"])

    # App config tweaks inside CONFIG_PATH, done as the torrent user, who
    # owns those folders. Only what the renderers need is passed: no .env
    # values, no passwords.
    safe = {k: s[k] for k in ("root", "config_root", "downloads_root",
                              "incomplete_root", "ports")}
    for svc, paths in as_user(*torrent_ids, app_config_changes, safe, dry_run).items():
        w.changed.setdefault(svc, []).extend(paths)

    return w.changed


def public(s: dict) -> dict:
    out = {k: v for k, v in s.items() if k not in ("env", "qbit_password")}
    return out


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--root", required=True, type=Path)
    sub = ap.add_subparsers(dest="cmd", required=True)
    ip = sub.add_parser("info")
    ip.add_argument("--env", type=Path, default=None,
                    help="check this file instead of ROOT/.env")
    wp = sub.add_parser("write")
    wp.add_argument("--dry-run", action="store_true")
    args = ap.parse_args()

    try:
        s = settings(args.root.resolve(), getattr(args, "env", None))
        if args.cmd == "info":
            print(json.dumps(public(s), indent=2))
            return 0
        changed = write_all(s, args.dry_run)
    except ConfigError as exc:
        print(f"render: .env problem: {exc}", file=sys.stderr)
        return 3
    except (RuntimeError, OSError) as exc:
        print(f"render: {exc}", file=sys.stderr)
        return 4
    result = public(s)
    result["changed"] = changed
    result["dry_run"] = args.dry_run
    print(json.dumps(result, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
