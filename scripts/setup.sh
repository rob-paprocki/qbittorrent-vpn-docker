#!/usr/bin/env bash
# Launch env-editor. Creates a venv under scripts/env-editor/.venv on first
# run, installs requirements, then runs the Flask app. Re-running after
# install just launches the app.
#
# Env overrides (all optional):
#   ENV_EDITOR_BIND=host:port   default 0.0.0.0:9191
#   ENV_EDITOR_USER=username    default admin
#
# Password is auto-generated on first launch and printed to stdout; it is
# also saved to configs/env-editor/credentials.json (gitignored).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EDITOR_DIR="$SCRIPT_DIR/env-editor"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
VENV_DIR="$EDITOR_DIR/.venv"

cd "$REPO_ROOT"

# Seed .env from the example on first run — the editor fills it in.
if [[ ! -f .env ]]; then
    cp .env.example .env
    echo "Created .env from .env.example"
fi

# Pick a Python interpreter. Debian/Ubuntu/PVE ship python3; some hosts
# have python3.12 or python3.11 only — try the alternatives.
PY="${PYTHON:-}"
if [[ -z "$PY" ]]; then
    for cand in python3 python3.12 python3.11 python3.10 python3.9; do
        if command -v "$cand" >/dev/null 2>&1; then PY="$cand"; break; fi
    done
fi
if [[ -z "$PY" ]]; then
    echo "ERROR: no python3 found on PATH. Install python3 (and python3-venv)." >&2
    exit 1
fi

# Create venv + install deps on first run.
if [[ ! -d "$VENV_DIR" ]]; then
    echo "Creating venv at $VENV_DIR …"
    "$PY" -m venv "$VENV_DIR"
    "$VENV_DIR/bin/pip" install -q --upgrade pip
    "$VENV_DIR/bin/pip" install -q -r "$EDITOR_DIR/requirements.txt"
fi

exec "$VENV_DIR/bin/python" "$EDITOR_DIR/app.py"
