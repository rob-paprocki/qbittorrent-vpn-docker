#!/usr/bin/env python3
"""Print the ENV defaults of the last stage of a Dockerfile as KEY=VALUE lines.

Part of qbittorrent-vpn-docker's native installer (MIT License, see LICENSE).

Why this exists: Gluetun reads many of its defaults from the `ENV` block in
its Dockerfile, not from its Go code. Run outside Docker without them it
crashes (for example a nil-pointer panic in the pprof server setup). The
native installer runs this script against the Dockerfile of the exact
Gluetun version it built, so the systemd service starts from the same
defaults the Docker image has. Settings from .env are layered on top.

Usage: python3 -I dockerfile_env.py /path/to/Dockerfile > image-defaults.env

Output is a systemd EnvironmentFile: one KEY=VALUE per line, values
double-quoted, with backslashes and double quotes escaped.
"""
from __future__ import annotations

import re
import shlex
import sys


def last_stage_env(text: str) -> dict[str, str]:
    # Join line continuations, drop comment-only lines inside instructions.
    logical: list[str] = []
    buf = ""
    for raw in text.splitlines():
        stripped = raw.strip()
        if stripped.startswith("#"):
            continue  # comments may sit between continued ENV lines
        if stripped.endswith("\\"):
            buf += stripped[:-1] + " "
            continue
        buf += stripped
        if buf.strip():
            logical.append(buf.strip())
        buf = ""
    if buf.strip():
        logical.append(buf.strip())

    env: dict[str, str] = {}
    for line in logical:
        word = line.split(None, 1)[0].upper() if line else ""
        if word == "FROM":
            env = {}  # a new stage starts from scratch
        elif word == "ENV":
            rest = line.split(None, 1)[1] if " " in line else ""
            for token in shlex.split(rest):
                if "=" not in token:
                    raise ValueError(f"unsupported ENV syntax: {token!r}")
                key, value = token.split("=", 1)
                env[key] = value
    return env


def systemd_quote(value: str) -> str:
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(sys.argv[1], encoding="utf-8") as fh:
        env = last_stage_env(fh.read())
    if not env:
        print("no ENV found in the last stage", file=sys.stderr)
        return 1
    for key in sorted(env):
        if not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            print(f"bad key {key!r}", file=sys.stderr)
            return 1
        print(f"{key}={systemd_quote(env[key])}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
