"""Stand-ins for what the stack's apps do, for testing platforms/casaos/install.sh.

Part of platforms/casaos/tests. License: MIT (see LICENSE in the repository
root).

install.sh checks the apps after CasaOS has started them: every web UI must
answer on its port, qBittorrent must accept the login in .env, and
qBittorrent, Jackett and FlareSolverr must be in Gluetun's network
namespace. These functions give the shims (tests/shims/curl, tests/shims/
docker) and tests/lib/fake_casaos.py the behaviour those checks depend on,
taken from the real images:

  * qBittorrent 5.3 (lscr.io/linuxserver/qbittorrent): on start, a
    qBittorrent.conf without [Meta] MigrationVersion >= 11 has its
    [Preferences] WebUI\\* keys moved to a [WebUI] section, and
    MigrationVersion=12 is written (qBittorrent src/app/upgrade.cpp,
    migrateWebUISettings). Afterwards only [WebUI] counts for the login. It
    listens on its WEBUI_PORT variable. Login: POST /api/v2/auth/login,
    204 when accepted, 401 when not (seen on CasaOS 0.4.15).
  * Jackett listens on the Port in ServerConfig.json (default 9117).
  * FlareSolverr listens on its PORT variable (default 8191).
  * FileBrowser listens on 80.
  * An app with network_mode service:gluetun answers only while it is in
    the network namespace of the RUNNING Gluetun (containers.json "netns");
    after Gluetun alone restarts, it is left in a dead one.

The stored app (state/apps/torrent-stack.yml) says which host port goes
where, as Docker's port publishing would.
"""
from __future__ import annotations

import base64
import hashlib
import json
import os
import re
import sys
from pathlib import Path

NETNS_DEPENDENTS = ("qbittorrent", "jackett", "flaresolverr")


# --- qBittorrent.conf -------------------------------------------------------
def _read_ini(path: Path) -> list[list]:
    """[[section, [lines...]], ...]; the part before any section is ''."""
    out: list[list] = [["", []]]
    for line in path.read_text(encoding="utf-8").splitlines():
        m = re.fullmatch(r"\[(.+)\]\s*", line)
        if m:
            out.append([m.group(1), []])
        else:
            out[-1][1].append(line)
    return out


def _write_ini(path: Path, ini: list[list]) -> None:
    lines: list[str] = []
    for name, body in ini:
        if name:
            if lines and lines[-1] != "":
                lines.append("")
            lines.append(f"[{name}]")
        lines += [x for x in body if x != ""] if name else body
    path.write_text("\n".join(lines).strip("\n") + "\n", encoding="utf-8")


def _get(ini, section, key):
    for name, body in ini:
        if name == section:
            for line in body:
                if line.startswith(key + "="):
                    return line[len(key) + 1:]
    return None


def _section(ini, section):
    for item in ini:
        if item[0] == section:
            return item[1]
    ini.append([section, []])
    return ini[-1][1]


def _set(ini, section, key, value):
    body = _section(ini, section)
    for i, line in enumerate(body):
        if line.startswith(key + "="):
            body[i] = f"{key}={value}"
            return
    body.append(f"{key}={value}")


def qbit_start(conf: Path) -> None:
    """What a qBittorrent 5.3 start does to qBittorrent.conf."""
    if not conf.exists():
        return
    ini = _read_ini(conf)
    version = int(_get(ini, "Meta", "MigrationVersion") or 0)
    if version >= 11:
        return
    prefs = _section(ini, "Preferences")
    keep = []
    for line in prefs:
        if line.startswith("WebUI\\") and "=" in line:
            key, value = line[len("WebUI\\"):].split("=", 1)
            _set(ini, "WebUI", key, value)
        else:
            keep.append(line)
    prefs[:] = keep
    _set(ini, "Meta", "MigrationVersion", "12")
    _write_ini(conf, ini)


def _pbkdf2_ok(stored: str | None, password: str) -> bool:
    if not stored:
        return False
    m = re.fullmatch(r'"?@ByteArray\(([^:]+):([^)]+)\)"?', stored.strip())
    if not m:
        return False
    salt, want = base64.b64decode(m.group(1)), base64.b64decode(m.group(2))
    return hashlib.pbkdf2_hmac("sha512", password.encode(), salt, 100000) == want


def qbit_login_ok(conf: Path, user: str, password: str) -> bool:
    """Would qBittorrent 5.3 accept this login with this qBittorrent.conf?"""
    if not conf.exists():
        return False
    ini = _read_ini(conf)
    if int(_get(ini, "Meta", "MigrationVersion") or 0) >= 11:
        name = _get(ini, "WebUI", "Username") or "admin"
        stored = _get(ini, "WebUI", "Password_PBKDF2")
    else:
        name = _get(ini, "Preferences", "WebUI\\Username") or "admin"
        stored = _get(ini, "Preferences", "WebUI\\Password_PBKDF2")
    return name == user and _pbkdf2_ok(stored, password)


# --- the stored app ---------------------------------------------------------
def bind_source(svc: dict, target: str) -> str | None:
    for v in svc.get("volumes") or []:
        if isinstance(v, dict) and v.get("target") == target:
            return v.get("source")
    return None


def qbit_conf_of(doc: dict) -> Path | None:
    src = bind_source(doc["services"].get("qbittorrent") or {}, "/config")
    return Path(src) / "qBittorrent" / "qBittorrent.conf" if src else None


def _listen_port(name: str, svc: dict) -> int:
    env = svc.get("environment") or {}
    if name == "qbittorrent":
        return int(env.get("WEBUI_PORT") or 8080)
    if name == "jackett":
        src = bind_source(svc, "/config")
        try:
            return int(json.loads((Path(src) / "Jackett" / "ServerConfig.json").read_text()).get("Port", 9117))
        except (OSError, ValueError, TypeError):
            return 9117
    if name == "flaresolverr":
        return int(env.get("PORT") or 8191)
    if name == "filebrowser":
        return 80
    return -1


def who_answers(state: Path, host_port: int):
    """(service name, service dict, stored doc) listening behind host_port, or None."""
    import yaml  # here, so the docker shim also runs on a python without PyYAML

    f = state / "apps" / "torrent-stack.yml"
    if not f.exists():
        return None
    doc = yaml.safe_load(f.read_text())
    p = state / "containers.json"
    rows = {c["service"]: c for c in (json.loads(p.read_text()) if p.exists() else [])}
    services = doc["services"]
    for owner, svc in services.items():
        for port in svc.get("ports") or []:
            if str(port.get("published")) != str(host_port):
                continue
            owner_c = rows.get(owner)
            if not owner_c or owner_c["state"] != "running":
                return None
            # Who in the owner's network namespace listens on the target port?
            candidates = [owner] + [n for n, s in services.items()
                                    if s.get("network_mode") == f"service:{owner}"]
            for name in candidates:
                c = rows.get(name)
                if not c or c["state"] != "running":
                    continue
                if name != owner and c.get("netns") != owner_c.get("netns"):
                    continue  # left behind in a dead namespace
                if _listen_port(name, services[name]) == int(port["target"]):
                    return name, services[name], doc
            return None
    return None


# --- curl stand-in for requests to the apps ---------------------------------
def curl_main(argv: list[str]) -> int:
    """Handle `curl ... http://127.0.0.1:PORT/...` the way install.sh calls it."""
    state = Path(os.environ["CASAOS_SHIM_STATE"])
    out_file, wfmt, url, fields = None, "", None, {}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-o", "-w", "-m", "--max-time", "--noproxy", "-X", "-H"):
            v = argv[i + 1]
            if a == "-o":
                out_file = v
            elif a == "-w":
                wfmt = v
            i += 2
            continue
        if a == "--data-urlencode":
            name, _, path = argv[i + 1].partition("@")
            fields[name] = Path(path).read_text()
            i += 2
            continue
        if a in ("-s", "-S", "-sS"):
            i += 1
            continue
        if a.startswith("http://"):
            url = a
            i += 1
            continue
        print(f"curl shim (apps): unexpected argument {a!r}", file=sys.stderr)
        return 2
    m = re.fullmatch(r"http://127\.0\.0\.1:(\d+)(/.*)?", url or "")
    if not m:
        print(f"curl shim (apps): unexpected URL {url!r}", file=sys.stderr)
        return 2
    path = m.group(2) or "/"
    found = who_answers(state, int(m.group(1)))
    body = ""
    if not found:
        code = "000"
    else:
        name, svc, doc = found
        if name == "qbittorrent" and path == "/api/v2/auth/login":
            conf = qbit_conf_of(doc)
            ok = conf is not None and qbit_login_ok(conf, fields.get("username", ""), fields.get("password", ""))
            code = "204" if ok else "401"
        elif name == "jackett":
            code = "302" if path.startswith("/UI/") else "301"
        else:
            code = "200"
            body = "FlareSolverr is ready!" if name == "flaresolverr" else "<html></html>"
    with open(state / "app-requests.log", "a") as f:
        f.write(f"{m.group(1)} {path} {code}\n")
    if out_file:
        Path(out_file).write_text(body)
    if wfmt:
        print(wfmt.replace("%{http_code}", code), end="")
    return 7 if code == "000" else 0


if __name__ == "__main__":
    sys.exit(curl_main(sys.argv[1:]))
