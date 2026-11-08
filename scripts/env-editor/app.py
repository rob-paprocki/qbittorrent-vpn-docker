"""env-editor — host-side Flask app for editing qbittorrent-vpn-docker's .env.

Entry point: `python3 app.py` (via scripts/setup.sh, which handles venv).

Default bind is 0.0.0.0:9191 with HTTP Basic Auth. Admin password is
auto-generated on first run, written to configs/env-editor/credentials.json
and printed to stdout once.

Two modes, chosen by the TS_MODE environment variable:
  docker (default)  Apply runs `docker compose up -d <services>`.
  native            Apply runs `native/install.sh apply <services>`, which
                    re-renders the configs and restarts the systemd units
                    torrent-<service>. Set by the torrent-env-editor unit
                    that native/install.sh writes inside a Debian container.
"""
from __future__ import annotations

import difflib
import functools
import json
import os
import secrets
import subprocess
import sys
import tempfile
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

# Native (systemd) mode: see the module docstring.
NATIVE = os.environ.get("TS_MODE", "docker").strip().lower() == "native"
NATIVE_INSTALLER = REPO / "native" / "install.sh"

# Native mode reads .env values literally (undoing write_env's quoting), so
# a password holding " or \\ survives being shown in the form and saved
# again. Docker mode keeps the original parser unchanged.
_parse_env = env_io.parse_env_literal if NATIVE else env_io.parse_env

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
    current = _parse_env(ENV_PATH)
    example = _parse_env(ENV_EXAMPLE)
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
    current = _parse_env(ENV_PATH)
    changed = {k: (current.get(k, ""), v) for k, v in submitted.items()
               if current.get(k, "") != v}
    services, seeders, remove = restart_map.resolve(set(changed.keys()), submitted)
    all_services = restart_map.all_services(submitted)
    if NATIVE:
        services, seeders, remove, all_services = _native_plan(
            services, seeders, all_services, set(changed))
        problem = _native_check(submitted)
        if problem:
            return render_template("native_invalid.html", problem=problem)
        if not changed:
            # Offer to apply .env again, for example after an Apply that
            # failed half-way (the values were already saved then).
            session["pending"] = submitted
            return render_template("native_unchanged.html")
    session["pending"] = submitted
    return render_template(
        "confirm.html",
        changed=changed,
        services=services,
        seeders=seeders,
        remove=remove,
        full_restart=sorted(services) == sorted(all_services),
        native=NATIVE,
    )


@app.route("/apply", methods=["POST"])
@require_auth
def apply():
    submitted = session.pop("pending", None)
    if not submitted:
        flash("Session expired — resubmit the form.", "error")
        return redirect(url_for("form_page"))

    current = _parse_env(ENV_PATH)
    changed_keys = {k for k, v in submitted.items() if current.get(k, "") != v}
    services, seeders, remove = restart_map.resolve(changed_keys, submitted)

    if NATIVE:
        # Refuse values the native install cannot use before saving them.
        problem = _native_check(submitted)
        if problem:
            return render_template("native_invalid.html", problem=problem)

    env_io.write_env(ENV_PATH, ENV_EXAMPLE, submitted)

    log: list[str] = [f"Wrote {ENV_PATH}"]
    if NATIVE:
        services = _apply_native(changed_keys, services, seeders, log)
        return render_template("applied.html", log=log, services=services,
                               native=True)

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

    if remove:
        # A service whose profile was switched off keeps running until it is
        # removed: `up` never touches it again.
        proc = subprocess.run(
            ["docker", "compose", "-f", str(COMPOSE_FILE), "rm", "-s", "-f", *remove],
            cwd=str(REPO), capture_output=True, text=True, timeout=180,
        )
        log.append(f"docker compose rm -s -f {' '.join(remove)}")
        output = (proc.stdout + proc.stderr).strip()
        if output:
            log.append(output)
        if proc.returncode != 0:
            log.append(f"[exit {proc.returncode}]")

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
# Native (systemd) mode
# ---------------------------------------------------------------------------

# Extra restarts that only exist natively, where every service shares one
# network namespace and listens on its .env port: Gluetun's firewall lets
# the FileBrowser port in, and Jackett stores FlareSolverr's URL.
NATIVE_EXTRA_RESTARTS: dict[str, list[str]] = {
    "FILEBROWSER_PORT": ["gluetun"],
    "FLARESOLVERR_PORT": ["jackett"],
}


def _native_plan(services: list[str], seeders: list[str],
                 all_services: list[str], changed_keys: set[str]):
    """Adjust a Docker restart plan for native mode.

    Profiled services (Watchtower) do not exist natively: updates are
    `native/install.sh update`. The FileBrowser seeder is dropped because
    native/install.sh apply renders FileBrowser's config, admin login
    included, from .env every time.
    """
    profiled = set(restart_map.PROFILED)
    extra = {svc for key in changed_keys for svc in NATIVE_EXTRA_RESTARTS.get(key, [])}
    services = sorted((set(services) | extra) - profiled)
    all_services = [s for s in all_services if s not in profiled]
    seeders = [s for s in seeders if s != "filebrowser"]
    return services, seeders, [], all_services


def _apply_native(changed_keys: set[str], services: list[str],
                  seeders: list[str], log: list[str]) -> list[str]:
    """Hand the restart (and the qBittorrent seeding) to native/install.sh.

    The installer stops the units first, then seeds and re-renders, then
    starts them, so qBittorrent cannot overwrite the freshly seeded
    password with its old in-memory settings while shutting down.
    Returns the services that were restarted.
    """
    services, seeders, _remove, _all = _native_plan(services, seeders, [], changed_keys)
    cmd = ["bash", str(NATIVE_INSTALLER), "apply"]
    # Same rule as Docker mode: seed qBittorrent when its credentials
    # changed, or when Apply was pressed with nothing changed.
    if "qbit" in seeders or not changed_keys:
        cmd.append("--seed=qbit")
    if not changed_keys:
        # "Apply again": re-render everything and restart the whole stack
        # (`apply` with no service names), e.g. after a failed Apply.
        services = [s for s in restart_map.all_services({}) if s not in restart_map.PROFILED]
    elif services:
        cmd += services
    else:
        # `apply` with no service names restarts everything; ask for none.
        cmd.append("--no-restart")
    log.append(" ".join(cmd[1:]))
    try:
        # native/install.sh waits at most 5 minutes for another run (an
        # `update`, say) to finish, so this timeout is longer than that.
        proc = subprocess.run(cmd, cwd=str(REPO), capture_output=True,
                              text=True, timeout=600)
    except subprocess.TimeoutExpired:
        log.append("[timeout] native/install.sh apply took over 10 minutes; "
                   "check `journalctl -u 'torrent-*'`, then use Apply again")
        return services
    output = (proc.stdout + proc.stderr).strip()
    if output:
        log.append(output)
    if proc.returncode != 0:
        log.append(f"[exit {proc.returncode}]")
    return services


def _native_check(submitted: dict[str, str]) -> str | None:
    """Ask native/lib/render.py whether the submitted values are usable.

    Returns its error message, or None when they are fine. The values are
    written to a private temporary file (never to .env) for the check.
    """
    fd, tmp = tempfile.mkstemp(prefix=".env.check.", dir=str(CREDS_PATH.parent))
    os.close(fd)  # mkstemp made it 0600; write_env keeps that mode
    try:
        env_io.write_env(Path(tmp), ENV_EXAMPLE, submitted)
        proc = subprocess.run(
            [sys.executable, "-I", str(REPO / "native" / "lib" / "render.py"),
             "--root", str(REPO), "info", "--env", tmp],
            capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(tmp)
    if proc.returncode == 0:
        return None
    text = (proc.stderr or proc.stdout).strip()
    return text.removeprefix("render: .env problem: ") or f"check failed (exit {proc.returncode})"


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
    env = _parse_env(ENV_PATH)
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
