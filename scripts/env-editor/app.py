"""env-editor — host-side Flask app for editing qbittorrent-vpn-docker's .env.

Entry point: `python3 app.py` (via scripts/setup.sh, which handles venv).

Default bind is 0.0.0.0:9191 with HTTP Basic Auth. Admin password is
auto-generated on first run, written to configs/env-editor/credentials.json
and printed to stdout once.
"""
from __future__ import annotations

import difflib
import functools
import json
import os
import secrets
import subprocess
import sys
import time
from pathlib import Path

import bcrypt
import requests
from flask import Flask, Response, abort, flash, redirect, render_template, request, session, url_for

import env_io
import restart_map
import seed_configs
from jackett_api import JackettClient

# ---------------------------------------------------------------------------
# Paths — resolved relative to the repo root (parent of scripts/)
# ---------------------------------------------------------------------------
HERE = Path(__file__).resolve().parent
REPO = HERE.parent.parent
ENV_PATH = REPO / ".env"
ENV_EXAMPLE = REPO / ".env.example"
COMPOSE_FILE = REPO / "compose.yaml"
CREDS_PATH = REPO / "configs" / "env-editor" / "credentials.json"

BIND = os.environ.get("ENV_EDITOR_BIND", "0.0.0.0:9191")
AUTH_USER = os.environ.get("ENV_EDITOR_USER", "admin")

app = Flask(__name__)
app.secret_key = secrets.token_hex(32)


# ---------------------------------------------------------------------------
# Auth
# ---------------------------------------------------------------------------

def _load_or_create_credentials() -> tuple[str, bytes]:
    """Return (username, bcrypt_hash). Generate + persist on first run."""
    CREDS_PATH.parent.mkdir(parents=True, exist_ok=True)
    if CREDS_PATH.exists():
        data = json.loads(CREDS_PATH.read_text(encoding="utf-8"))
        return data["username"], data["password_hash"].encode("ascii")
    password = secrets.token_urlsafe(18)
    pw_hash = bcrypt.hashpw(password.encode("utf-8"), bcrypt.gensalt())
    CREDS_PATH.write_text(json.dumps({
        "username": AUTH_USER,
        "password_hash": pw_hash.decode("ascii"),
    }, indent=2), encoding="utf-8")
    try:
        os.chmod(CREDS_PATH, 0o600)
    except OSError:
        pass
    print("")
    print("=" * 60)
    print(f"  env-editor first-time admin credentials")
    print(f"    user:     {AUTH_USER}")
    print(f"    password: {password}")
    print(f"  (also saved to {CREDS_PATH})")
    print("=" * 60)
    print("")
    return AUTH_USER, pw_hash


AUTH_USERNAME, AUTH_PW_HASH = _load_or_create_credentials()


def _check_auth(user: str, pw: str) -> bool:
    if not secrets.compare_digest(user, AUTH_USERNAME):
        return False
    try:
        return bcrypt.checkpw(pw.encode("utf-8"), AUTH_PW_HASH)
    except ValueError:
        return False


def require_auth(fn):
    @functools.wraps(fn)
    def wrapper(*a, **kw):
        auth = request.authorization
        if auth and _check_auth(auth.username or "", auth.password or ""):
            return fn(*a, **kw)
        return Response(
            "Authentication required.", 401,
            {"WWW-Authenticate": 'Basic realm="env-editor"'},
        )
    return wrapper


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

@app.route("/")
@require_auth
def form_page():
    current = env_io.parse_env(ENV_PATH)
    example = env_io.parse_env(ENV_EXAMPLE)
    sections: dict[str, list[dict]] = {}
    for f in env_io.FIELDS:
        value = current.get(f["name"], example.get(f["name"], ""))
        entry = dict(f)
        entry["value"] = value
        sections.setdefault(f["section"], []).append(entry)
    return render_template(
        "form.html",
        sections=sections,
        env_exists=ENV_PATH.exists(),
        env_path=str(ENV_PATH),
    )


@app.route("/preview", methods=["POST"])
@require_auth
def preview():
    submitted = _collect_form(request.form)
    current = env_io.parse_env(ENV_PATH)
    changed = {k: (current.get(k, ""), v) for k, v in submitted.items()
               if current.get(k, "") != v}
    services, seeders = restart_map.resolve(set(changed.keys()))
    session["pending"] = submitted
    return render_template(
        "confirm.html",
        changed=changed,
        services=services,
        seeders=seeders,
        full_restart=sorted(services) == sorted(restart_map.STACK),
    )


@app.route("/apply", methods=["POST"])
@require_auth
def apply():
    submitted = session.pop("pending", None)
    if not submitted:
        flash("Session expired — resubmit the form.", "error")
        return redirect(url_for("form_page"))

    current = env_io.parse_env(ENV_PATH)
    changed_keys = {k for k, v in submitted.items() if current.get(k, "") != v}
    services, seeders = restart_map.resolve(changed_keys)

    env_io.write_env(ENV_PATH, ENV_EXAMPLE, submitted)

    log: list[str] = [f"Wrote {ENV_PATH}"]
    config_root = Path(submitted.get("CONFIG_PATH") or "./configs")
    if not config_root.is_absolute():
        config_root = (REPO / config_root).resolve()

    # Always ensure Jackett API key exists; it's needed to wire qBit → Jackett.
    api_key = seed_configs.ensure_jackett_api_key(config_root)
    log.append(f"Jackett API key present ({api_key[:4]}…)")

    if "qbit" in seeders or not changed_keys:
        seed_configs.seed_qbittorrent(
            config_root,
            submitted["QBITTORRENT_USER"],
            submitted["QBITTORRENT_PASSWORD"],
        )
        seed_configs.seed_qbit_jackett_wiring(
            config_root, api_key, "127.0.0.1",
            int(submitted.get("JACKETT_PORT", "9117")),
        )
        log.append("Seeded qBittorrent.conf (PBKDF2 + search plugin)")

    if "filebrowser" in seeders or not changed_keys:
        seed_configs.seed_filebrowser(
            config_root,
            submitted["QBITTORRENT_USER"],
            submitted["QBITTORRENT_PASSWORD"],
        )
        log.append("Seeded FileBrowser admin (bcrypt)")

    if services:
        proc = subprocess.run(
            ["docker", "compose", "-f", str(COMPOSE_FILE), "up", "-d", *services],
            cwd=str(REPO), capture_output=True, text=True, timeout=180,
        )
        log.append(f"docker compose up -d {' '.join(services)}")
        if proc.stdout:
            log.append(proc.stdout.strip())
        if proc.returncode != 0:
            log.append(f"[exit {proc.returncode}] {proc.stderr.strip()}")

    return render_template("applied.html", log=log, services=services)


@app.route("/indexers")
@require_auth
def indexers_page():
    client = _jackett_client()
    if not client:
        return render_template("indexers.html", up=False, configured=[], available=[])
    if not client.ping():
        return render_template("indexers.html", up=False, configured=[], available=[])
    configured = client.list_indexers(configured=True)
    available = client.list_indexers(configured=False)
    return render_template(
        "indexers.html", up=True,
        configured=configured, available=available,
    )


@app.route("/indexers/<indexer_id>/configure", methods=["GET", "POST"])
@require_auth
def indexer_configure(indexer_id: str):
    client = _jackett_client()
    if not client or not client.ping():
        abort(503, "Jackett is not reachable")
    if request.method == "POST":
        schema = client.get_config_schema(indexer_id)
        for item in schema:
            iid = item.get("id")
            if iid is None:
                continue
            posted = request.form.get(f"f_{iid}")
            if posted is None:
                continue
            if item.get("type") == "inputbool":
                item["value"] = posted == "on"
            else:
                item["value"] = posted
        result = client.configure(indexer_id, schema)
        if result.get("ok"):
            flash(f"Indexer {indexer_id} configured.", "ok")
            return redirect(url_for("indexers_page"))
        flash(f"Jackett rejected the config: {result.get('detail')}", "error")
    schema = client.get_config_schema(indexer_id)
    return render_template("indexer_configure.html",
                           indexer_id=indexer_id, schema=schema)


@app.route("/indexers/<indexer_id>/delete", methods=["POST"])
@require_auth
def indexer_delete(indexer_id: str):
    client = _jackett_client()
    if not client or not client.delete(indexer_id):
        flash(f"Could not delete {indexer_id}.", "error")
    else:
        flash(f"Removed {indexer_id}.", "ok")
    return redirect(url_for("indexers_page"))


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def _collect_form(form) -> dict[str, str]:
    out: dict[str, str] = {}
    for f in env_io.FIELDS:
        name = f["name"]
        if f["type"] == "toggle":
            out[name] = "on" if form.get(name) == "on" else "off"
        else:
            out[name] = (form.get(name) or "").strip()
    return out


def _jackett_client() -> JackettClient | None:
    env = env_io.parse_env(ENV_PATH)
    port = env.get("JACKETT_PORT", "9117")
    config_root = Path(env.get("CONFIG_PATH") or "./configs")
    if not config_root.is_absolute():
        config_root = (REPO / config_root).resolve()
    sc = config_root / "jackett" / "Jackett" / "ServerConfig.json"
    if not sc.exists():
        return None
    try:
        data = json.loads(sc.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        return None
    api_key = data.get("APIKey")
    if not api_key:
        return None
    return JackettClient(f"http://127.0.0.1:{port}", api_key)


# ---------------------------------------------------------------------------
# Entrypoint
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    host, _, port_s = BIND.partition(":")
    port = int(port_s or "9191")
    print(f"env-editor listening on http://{host}:{port}  (basic auth required)")
    print(f"repo root: {REPO}")
    app.run(host=host, port=port, debug=False)
