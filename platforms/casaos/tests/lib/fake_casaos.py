"""Fake CasaOS app-management (v2 API) for testing platforms/casaos/install.sh.

Part of platforms/casaos/tests. License: MIT (see LICENSE in the repository
root).

Implements the calls install.sh makes, with the behaviour read from
IceWhaleTech/CasaOS-AppManagement (route/v2.go, route/v2/compose_app.go,
service/compose_app.go, service/compose_service.go) and checked against a
real CasaOS 0.4.15 / app-management v0.4.5:

  GET    /v2/app_management/compose              list (200)
  GET    /v2/app_management/compose/{id}         200 (YAML with Accept:
                                                 application/yaml) or 404
  POST   /v2/app_management/compose[?dry_run]    install; 400 on bad YAML or
                                                 ports in use; async
  PUT    /v2/app_management/compose/{id}[?dry_run]
                                                 apply settings; 404 if absent;
                                                 ports of the app itself are
                                                 not "in use"
  DELETE /v2/app_management/compose/{id}?delete_config_folder=
                                                 uninstall (async)

Requests without an Authorization header are accepted, as CasaOS does for
127.0.0.1, unless config.json sets "require_auth". Every body must be
`Content-Type: application/yaml` and pass casaos_schema.check_doc. Containers
are kept in containers.json, which tests/shims/docker reads and writes, so
`docker ps` shows what CasaOS would have created.

Containers carry the service's labels, the id of the image they were made
from, a pid and a network namespace (apps on network_mode service:gluetun
share Gluetun's), and starting qBittorrent migrates its settings like the
real one (tests/lib/fake_apps.py).

State directory files:
  config.json     {"require_auth", "ports_in_use": [..], "gluetun_status",
                   "foreign": {"config_files": ".."},
                   "rollback": true (a PUT is answered 200 but nothing
                   changes, as when CasaOS's background apply fails),
                   "restart_keeps_netns": true (docker shim)}  (tests edit it)
  apps/<id>.yml   the stored app
  containers.json [{"id", "service", "state", "status", "config_files",
                    "labels", "image_id", "pid", "netns", "qbit_conf"}]
  images.changed  written by the docker shim when a pull got a new image
  requests.jsonl  one line per request
"""
from __future__ import annotations

import hashlib
import http.server
import json
import os
import secrets
import shutil
import sys
import threading
import urllib.parse
from pathlib import Path

import yaml

sys.dont_write_bytecode = True  # no __pycache__ in the repository
sys.path.insert(0, str(Path(__file__).resolve().parent))
import casaos_schema  # noqa: E402
import fake_apps  # noqa: E402

PREFIX = "/v2/app_management"
NETNS_DEPENDENTS = fake_apps.NETNS_DEPENDENTS


def new_netns() -> str:
    return f"net:[40265{secrets.randbelow(10 ** 5):05d}]"


def new_pid() -> int:
    return secrets.randbelow(10 ** 6) + 1000


class State:
    def __init__(self, root: Path, apps_dir: str):
        self.root = root
        self.apps_dir = apps_dir
        (root / "apps").mkdir(parents=True, exist_ok=True)

    def config(self) -> dict:
        p = self.root / "config.json"
        return json.loads(p.read_text()) if p.exists() else {}

    def containers(self) -> list:
        p = self.root / "containers.json"
        return json.loads(p.read_text()) if p.exists() else []

    def save_containers(self, rows: list) -> None:
        tmp = self.root / "containers.json.tmp"
        tmp.write_text(json.dumps(rows, indent=1))
        tmp.replace(self.root / "containers.json")

    def app_file(self, app: str) -> Path:
        return self.root / "apps" / f"{app}.yml"

    def working_dir(self, app: str) -> Path:
        # CasaOS's own copy of an app lives in <apps dir>/<app>/.
        return Path(self.apps_dir) / app


def service_hashes(doc: dict) -> dict:
    out = {}
    for name, svc in doc["services"].items():
        out[name] = hashlib.sha256(json.dumps(svc, sort_keys=True).encode()).hexdigest()
    return out


class Handler(http.server.BaseHTTPRequestHandler):
    state: State

    def log_message(self, fmt, *args):  # keep test output quiet
        pass

    def _log(self, body: bytes):
        u = urllib.parse.urlsplit(self.path)
        entry = {
            "method": self.command,
            "path": u.path,
            "query": dict(urllib.parse.parse_qsl(u.query)),
            "content_type": self.headers.get("Content-Type", ""),
            "accept": self.headers.get("Accept", ""),
            "authorization": bool(self.headers.get("Authorization")),
            "body_sha256": hashlib.sha256(body).hexdigest() if body else "",
        }
        with open(self.state.root / "requests.jsonl", "a") as f:
            f.write(json.dumps(entry) + "\n")

    def _send(self, code: int, obj=None, text: str | None = None):
        data = text.encode() if text is not None else json.dumps(obj or {}).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/yaml" if text is not None else "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _route(self):
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        self._log(body)
        cfg = self.state.config()
        if cfg.get("require_auth") and not self.headers.get("Authorization"):
            return self._send(401, {"message": "missing or malformed jwt"})
        u = urllib.parse.urlsplit(self.path)
        q = dict(urllib.parse.parse_qsl(u.query))
        if not u.path.startswith(PREFIX + "/compose"):
            return self._send(404, {"message": "Not Found"})
        rest = u.path[len(PREFIX + "/compose"):].strip("/")
        if self.command == "GET" and not rest:
            apps = {p.stem: {} for p in (self.state.root / "apps").glob("*.yml")}
            return self._send(200, {"data": apps, "message": ""})
        if self.command == "GET":
            return self._get(rest)
        if self.command == "POST" and not rest:
            return self._install(body, q, cfg)
        if self.command == "PUT" and rest and "/" not in rest:
            return self._apply(rest, body, q, cfg)
        if self.command == "DELETE" and rest and "/" not in rest:
            return self._uninstall(rest, q)
        return self._send(405, {"message": "method not allowed (fake)"})

    do_GET = do_POST = do_PUT = do_DELETE = _route

    # --- handlers -----------------------------------------------------------
    def _get(self, app: str):
        f = self.state.app_file(app)
        foreign = self.state.config().get("foreign")
        if f.exists():
            text = f.read_text()
        elif foreign and any(c["config_files"] == foreign["config_files"] for c in self.state.containers()):
            # CasaOS lists any Compose project Docker knows about.
            text = f"name: {app}\nservices:\n  gluetun:\n    image: qmcgaw/gluetun:latest\n"
        else:
            return self._send(404, {"message": f"compose app `{app}` not found"})
        if self.headers.get("Accept") == "application/yaml":
            return self._send(200, text=text)
        return self._send(200, {"data": {"compose": yaml.safe_load(text)}, "message": "debug"})

    def _parse(self, body: bytes):
        if self.headers.get("Content-Type") != "application/yaml":
            return None, (400, {"message": "fake: Content-Type must be application/yaml"})
        try:
            doc = yaml.safe_load(body.decode())
        except yaml.YAMLError as exc:
            return None, (400, {"message": f"yaml: {exc}"})
        errors = casaos_schema.check_doc(doc)
        if errors:
            return None, (400, {"message": "fake: " + "; ".join(errors[:5])})
        return doc, None

    def _ports_in_use(self, doc: dict, cfg: dict, own: set) -> list:
        busy = {str(p) for p in cfg.get("ports_in_use", [])} - own
        wanted = {p["published"] for s in doc["services"].values() for p in (s.get("ports") or [])}
        return sorted(busy & wanted)

    def _containers_for(self, doc: dict, app: str, old: list, recreate: set) -> list:
        cfg = self.state.config()
        images = json.loads((self.state.root / "images.json").read_text()) \
            if (self.state.root / "images.json").exists() else {}
        by_service = {c["service"]: c for c in old}
        rows = []
        # Gluetun first: the apps on its network join its namespace.
        names = sorted(doc["services"], key=lambda n: n != "gluetun")
        gluetun_ns = None
        for name in names:
            svc = doc["services"][name]
            c = by_service.get(name)
            starting = c is None or name in recreate or c["state"] != "running"
            if c is None or name in recreate:
                c = {"id": secrets.token_hex(6), "service": name,
                     "config_files": f"{self.state.apps_dir}/{app}/docker-compose.yml",
                     "labels": dict(svc.get("labels") or {}),
                     "image_id": images.get(svc["image"], "sha256:not-pulled"),
                     "netns": new_netns()}
            if starting:
                c["pid"] = new_pid()
                if svc.get("network_mode") == "service:gluetun" and gluetun_ns:
                    c["netns"] = gluetun_ns
                elif name not in NETNS_DEPENDENTS:
                    c["netns"] = new_netns() if name == "gluetun" else c.get("netns") or new_netns()
                if name == "qbittorrent":
                    conf = fake_apps.qbit_conf_of(doc)
                    c["qbit_conf"] = str(conf) if conf else ""
                    if conf:
                        fake_apps.qbit_start(conf)
            if name == "gluetun":
                gluetun_ns = c["netns"]
            c["state"] = "running"
            if name == "gluetun":
                c["status"] = cfg.get("gluetun_status", "Up 2 minutes (healthy)")
            elif name == "filebrowser":
                c["status"] = "Up 2 minutes (healthy)"
            else:
                c["status"] = "Up 1 minute"
            rows.append(c)
        return rows

    def _install(self, body: bytes, q: dict, cfg: dict):
        doc, err = self._parse(body)
        if err:
            return self._send(*err)
        busy = self._ports_in_use(doc, cfg, set())
        if busy:
            return self._send(400, {"data": {"ports_in_use": {"TCP": busy, "UDP": []}},
                                    "message": "there are ports in use"})
        if q.get("dry_run") == "true":
            return self._send(200, {"message": "only validation has been done because `dry_run` is specified - skipping compose app installation"})
        app = doc["name"]
        if self.state.app_file(app).exists():
            return self._send(500, {"message": "fake: POST for an app that is installed (install.sh should PUT)"})
        self.state.app_file(app).write_text(body.decode())
        self.state.working_dir(app).mkdir(parents=True, exist_ok=True)
        others = [c for c in self.state.containers() if c.get("project", app) != app]
        self.state.save_containers(others + self._containers_for(doc, app, [], set(doc["services"])))
        return self._send(200, {"message": "compose app is being installed asynchronously"})

    def _apply(self, app: str, body: bytes, q: dict, cfg: dict):
        f = self.state.app_file(app)
        if not f.exists():
            return self._send(404, {"message": f"compose app `{app}` not found"})
        doc, err = self._parse(body)
        if err:
            return self._send(*err)
        old_doc = yaml.safe_load(f.read_text())
        own = {p["published"] for s in old_doc["services"].values() for p in (s.get("ports") or [])}
        busy = self._ports_in_use(doc, cfg, own)
        if busy:
            return self._send(400, {"data": {"ports_in_use": {"TCP": busy, "UDP": []}},
                                    "message": "there are ports in use"})
        if q.get("dry_run") == "true":
            return self._send(200, {"message": "only validation has been done because `dry_run` is specified - skipping compose app installation"})
        if cfg.get("rollback"):
            # CasaOS answers first and works in the background; when that
            # fails (seen on CasaOS 0.4.15: its backup copy could not be
            # written) the app keeps the old definition, and nobody is told.
            return self._send(200, {"message": "compose app is being applied with changes asynchroniously"})
        if doc["name"] != app:
            return self._send(500, {"message": "compose app name does not match"})
        # Like `docker compose up`: recreate what changed (and, when gluetun
        # is recreated, everything on its network), start what was stopped.
        old_h, new_h = service_hashes(old_doc), service_hashes(doc)
        recreate = {s for s in new_h if old_h.get(s) != new_h[s]}
        flag = self.state.root / "images.changed"
        if flag.exists():
            recreate |= set(new_h)
            flag.unlink()
        if "gluetun" in recreate:
            recreate |= set(NETNS_DEPENDENTS) & set(new_h)
        f.write_text(body.decode())
        self.state.save_containers(self._containers_for(doc, app, self.state.containers(), recreate))
        return self._send(200, {"message": "compose app is being applied with changes asynchroniously"})

    def _uninstall(self, app: str, q: dict):
        f = self.state.app_file(app)
        if not f.exists():
            return self._send(404, {"message": f"compose app `{app}` not found"})
        f.unlink()
        self.state.save_containers([])
        # Like CasaOS: the containers go first; the images and then the app's
        # working folder a little later, in the background.
        threading.Timer(1.0, shutil.rmtree, args=(self.state.working_dir(app),),
                        kwargs={"ignore_errors": True}).start()
        return self._send(200, {"message": "compose app is being uninstalled asynchronously"})


def main() -> int:
    import argparse

    ap = argparse.ArgumentParser()
    ap.add_argument("--state", required=True, type=Path)
    ap.add_argument("--port-file", required=True, type=Path)
    ap.add_argument("--apps-dir", required=True)
    a = ap.parse_args()
    Handler.state = State(a.state, a.apps_dir)
    srv = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    a.port_file.write_text(str(srv.server_address[1]))
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        pass
    return 0


if __name__ == "__main__":
    sys.exit(main())
