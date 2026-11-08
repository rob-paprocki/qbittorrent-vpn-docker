"""Drift check: does the CasaOS rendering still match compose.yaml?

Part of platforms/casaos/tests. License: MIT (see LICENSE in the repository
root).

platforms/casaos/install.sh writes the stack out by hand (CasaOS cannot read
.env files), so it could fall behind when compose.yaml changes. This runs
`docker compose config --format json` on both, with the same .env, and
compares every service. The only differences allowed are the ones the
CasaOS rendering makes on purpose:

  * service-level `x-casaos` blocks (dashboard descriptions);
  * with --no-ipv6-sysctl: gluetun's IPv6 sysctl, which install.sh leaves
    out on kernels booted with ipv6.disable=1;
  * `profiles` (a profiled service is rendered only when its profile is on)
    and the empty `bind: {}` Compose adds to short-syntax volumes;
  * the revision label (io.github.rob-paprocki.torrent-stack.rev) on every
    service, which install.sh uses to see what CasaOS has applied;
  * `restart: true` on the depends_on of the apps behind Gluetun, while
    compose.yaml does not have it yet (requested as a change there; once it
    lands, both sides are equal and nothing needs allowing). Reported as a
    note so it stays visible.

Jackett's and FlareSolverr's container ports (always 9117 and 8191 in the
rendering) only differ from compose.yaml when JACKETT_PORT or
FLARESOLVERR_PORT are changed; the tests compare with the default ports.

usage: compare_compose.py RENDERED COMPOSE_YAML ENV_FILE PROJECT_DIR
                          [--profile watchtower] [--no-ipv6-sysctl]
"""
from __future__ import annotations

import argparse
import json
import subprocess
import sys

REV_LABEL = "io.github.rob-paprocki.torrent-stack.rev"


def compose_config(args: list[str]) -> dict:
    out = subprocess.run(["docker", "compose", *args, "config", "--format", "json"],
                         capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"docker compose {' '.join(args)} config failed:\n{out.stderr}")
    return json.loads(out.stdout)


def diff(a, b, path="") -> list[str]:
    if isinstance(a, dict) and isinstance(b, dict):
        out = []
        for k in sorted(set(a) | set(b)):
            if k not in a:
                out.append(f"{path}.{k}: only in compose.yaml: {json.dumps(b[k])[:200]}")
            elif k not in b:
                out.append(f"{path}.{k}: only in the CasaOS rendering: {json.dumps(a[k])[:200]}")
            else:
                out += diff(a[k], b[k], f"{path}.{k}")
        return out
    if a != b:
        return [f"{path}: CasaOS {json.dumps(a)[:200]} != compose.yaml {json.dumps(b)[:200]}"]
    return []


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("rendered")
    ap.add_argument("compose_yaml")
    ap.add_argument("env_file")
    ap.add_argument("project_dir")
    ap.add_argument("--profile", action="append", default=[])
    ap.add_argument("--no-ipv6-sysctl", action="store_true")
    a = ap.parse_args()

    profiles = [x for p in a.profile for x in ("--profile", p)]
    casa = compose_config(["-f", a.rendered])
    repo = compose_config(["--project-directory", a.project_dir, "--env-file", a.env_file,
                           "-f", a.compose_yaml, *profiles])
    if casa.get("name") != repo.get("name"):
        print(f"name: {casa.get('name')} != {repo.get('name')}")
        return 1
    for svc in casa["services"].values():
        svc.pop("x-casaos", None)
    for svc in repo["services"].values():
        # The rendering includes a profiled service only when its profile
        # is on, so the profile itself has nothing left to say.
        svc.pop("profiles", None)
    for doc in (casa, repo):
        for svc in doc["services"].values():
            for vol in svc.get("volumes") or []:
                # Short-syntax binds (compose.yaml) come out with an empty
                # "bind" block; the long syntax (CasaOS) without one.
                if vol.get("bind") == {}:
                    del vol["bind"]
    if a.no_ipv6_sysctl:
        repo["services"]["gluetun"].pop("sysctls", None)
    for svc in casa["services"].values():
        (svc.get("labels") or {}).pop(REV_LABEL, None)
    for name, svc in casa["services"].items():
        for dep, spec in (svc.get("depends_on") or {}).items():
            theirs = ((repo["services"].get(name) or {}).get("depends_on") or {}).get(dep)
            if spec.get("restart") is True and isinstance(theirs, dict) and not theirs.get("restart"):
                print(f"note: services.{name}.depends_on.{dep}.restart is true here, "
                      "not yet in compose.yaml (allowed)")
                theirs["restart"] = True
    problems = diff(casa["services"], repo["services"], "services")
    for p in problems:
        print(p)
    if not problems:
        print(f"services match: {', '.join(sorted(casa['services']))}")
    return 1 if problems else 0


if __name__ == "__main__":
    sys.exit(main())
