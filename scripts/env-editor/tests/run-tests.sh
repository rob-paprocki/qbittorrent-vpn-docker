#!/usr/bin/env bash
#
# scripts/env-editor/tests/run-tests.sh
#
# Purpose: test the env-editor web app (app.py) in Docker mode and in native
# mode with Flask's test client: what it refuses before saving and what its
# Apply writes. Nothing runs against a real stack: the app works on a
# throwaway copy of the repo, and `docker` is a stub that logs its
# arguments (and on `stop qbittorrent` writes qBittorrent.conf over, as
# qBittorrent does). No root needed, no containers.
#
#   bash scripts/env-editor/tests/run-tests.sh
#
# Python: $ENV_EDITOR_PYTHON if set, else scripts/env-editor/.venv/bin/python
# (made by scripts/setup.sh) if it has Flask, else a new venv in a temporary
# folder with the locked versions from native/locks/env-editor.txt (that one
# needs PyPI; behind a TLS-inspecting proxy set PIP_CERT).
# The checks of env_io and seed_configs that need no Flask are in
# native/tests/check-env-parsing.sh.
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

has_flask() { "$1" -I -B -c 'import flask, bcrypt, requests' 2>/dev/null; }

PY="${ENV_EDITOR_PYTHON:-}"
if [[ -z "$PY" ]] && has_flask "$REPO/scripts/env-editor/.venv/bin/python"; then
  PY="$REPO/scripts/env-editor/.venv/bin/python"
fi
if [[ -z "$PY" ]]; then
  echo "== making a venv with native/locks/env-editor.txt"
  python3 -m venv "$WORK/venv"
  "$WORK/venv/bin/python" -m pip install -q --require-hashes --only-binary=:all: \
    -r "$REPO/native/locks/env-editor.txt"
  PY="$WORK/venv/bin/python"
fi
has_flask "$PY" || { echo "$PY has no flask, bcrypt or requests" >&2; exit 1; }
echo "== Python: $PY ($("$PY" -c 'import sys; print(sys.version.split()[0])'))"

mkdir -p "$WORK/shim"
cat >"$WORK/shim/docker" <<'EOF'
#!/bin/sh
printf '%s\n' "docker $*" >>"$DOCKER_LOG"
# Like qBittorrent, which writes the settings it holds in memory back to
# its config when it stops: a login seeded before the stop is lost.
case "$*" in
  *" stop qbittorrent")
    if [ -f "$QBIT_CONF" ]; then printf '[Preferences]\nWebUI\\Username=in-memory\n' >"$QBIT_CONF"; fi ;;
esac
EOF
chmod +x "$WORK/shim/docker"
# One login for every copy: admin / test-pass.
creds=$("$PY" -I -B -c 'import bcrypt, json; print(json.dumps({"username": "admin", "password_hash": bcrypt.hashpw(b"test-pass", bcrypt.gensalt()).decode()}))')

FAIL=0
for mode in docker native; do
  fx="$WORK/$mode"
  mkdir -p "$fx/native" "$fx/configs/env-editor"
  # A copy, so the app's .env, credentials and configs never land in the
  # checkout.
  (cd "$REPO" && tar -c --exclude=__pycache__ --exclude=.venv --exclude=tests scripts/env-editor) |
    tar -x -C "$fx"
  cp "$REPO/.env.example" "$REPO/compose.yaml" "$fx/"
  cp "$REPO/native/versions.env" "$fx/native/"
  printf '%s\n' "$creds" >"$fx/configs/env-editor/credentials.json"
  # The search plugin is "installed", so Apply never downloads it.
  mkdir -p "$fx/configs/qbittorrent/qBittorrent/nova3/engines"
  echo '# stub' >"$fx/configs/qbittorrent/qBittorrent/nova3/engines/jackett.py"
  echo "== $mode mode"
  if ! (cd "$WORK" && PATH="$WORK/shim:$PATH" TS_MODE="$mode" DOCKER_LOG="$WORK/$mode-docker.log" \
        QBIT_CONF="$fx/configs/qbittorrent/qBittorrent/qBittorrent.conf" \
        "$PY" -I -B "$HERE/test_app.py" "$fx" 2>&1); then
    FAIL=1
  fi
done

echo
if [[ "$FAIL" == 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit "$FAIL"
