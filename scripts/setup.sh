#!/usr/bin/env bash
# Launch env-editor. Builds a venv under scripts/env-editor/.venv, installs
# requirements, then runs the Flask app. The venv is rebuilt when it is
# missing, when an earlier build failed partway, or when requirements.txt
# has changed; otherwise re-running just launches the app.
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

# Build the venv unless a previous build finished for the current
# requirements.txt. The stamp is written only after pip succeeds, so a run
# that died partway (e.g. before python3-venv was installed) is retried
# instead of leaving a venv without its dependencies.
REQ_FILE="$EDITOR_DIR/requirements.txt"
VENV_STAMP="$VENV_DIR/.requirements.sha256"
REQ_HASH="$("$PY" -c 'import hashlib, sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$REQ_FILE")"
if [[ ! -f "$VENV_STAMP" || "$(cat "$VENV_STAMP")" != "$REQ_HASH" ]]; then
    echo "Building venv at $VENV_DIR …"
    # --clear empties any half-built venv left by an earlier failed run.
    if ! "$PY" -m venv --clear "$VENV_DIR"; then
        echo "ERROR: could not create a Python venv with $PY." >&2
        echo "On Debian/Ubuntu, install the venv module and re-run:" >&2
        echo "    sudo apt-get install -y python3-venv" >&2
        exit 1
    fi
    # `python -m pip` rather than bin/pip: pip's script carries an absolute
    # shebang that breaks if the checkout folder is renamed or moved.
    "$VENV_DIR/bin/python" -m pip install -q --upgrade pip
    "$VENV_DIR/bin/python" -m pip install -q -r "$REQ_FILE"
    echo "$REQ_HASH" > "$VENV_STAMP"
fi

exec "$VENV_DIR/bin/python" "$EDITOR_DIR/app.py"
