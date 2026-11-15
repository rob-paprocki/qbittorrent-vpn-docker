#!/usr/bin/env python3
"""Query the calls the Proxmox shims recorded, for run-tests.sh.

Purpose: test helper. Reads $STATE/calls.jsonl written by shims/pveshim.py.

  calls.py STATE create-opts            last `pct create`: KEY=VALUE per line
  calls.py STATE count TOOL [SUBCMD]    number of calls
  calls.py STATE argv-has TOOL NEEDLE   exit 0 if any TOOL call has NEEDLE as an argument
  calls.py STATE exec-cmds              every `pct exec` command, one per line
  calls.py STATE stdin-shapes           what was piped into `pct exec` (secrets masked)
  calls.py STATE validate APIDOC        re-check every pct create/set against the
                                        Proxmox API schema; print a report

License: MIT (see LICENSE in the repository root).
"""
from __future__ import annotations

import json
import sys
from pathlib import Path

sys.dont_write_bytecode = True  # keep __pycache__ out of the checkout
sys.path.insert(0, str(Path(__file__).resolve().parent))
import pve_schema as ps  # noqa: E402


def load(state: str) -> list[dict]:
    f = Path(state) / "calls.jsonl"
    if not f.exists():
        return []
    return [json.loads(line) for line in f.read_text().splitlines() if line.strip()]


def main() -> int:
    state, cmd, args = sys.argv[1], sys.argv[2], sys.argv[3:]
    calls = load(state)
    if cmd == "create-opts":
        creates = [c["argv"] for c in calls if c["tool"] == "pct" and c["argv"][:1] == ["create"]]
        if not creates:
            return 1
        argv = creates[-1][1:]
        print(f"vmid={argv[0]}")
        print(f"ostemplate={argv[1]}")
        i = 2
        while i < len(argv):
            k = argv[i].lstrip("-")
            print(f"{k}={argv[i + 1]}")
            i += 2
        return 0
    if cmd == "count":
        tool = args[0]
        sub = args[1] if len(args) > 1 else None
        print(sum(1 for c in calls if c["tool"] == tool and (sub is None or c["argv"][:1] == [sub])))
        return 0
    if cmd == "argv-has":
        tool, needle = args
        return 0 if any(c["tool"] == tool and needle in c["argv"] for c in calls) else 1
    if cmd == "exec-cmds":
        for c in calls:
            if c["tool"] == "pct" and c["argv"][:1] == ["exec"]:
                print(" ".join(x.replace("\n", "\\n") for x in c["argv"][1:]))
        return 0
    if cmd == "stdin-shapes":
        for c in calls:
            if c["tool"] == "pct-exec-stdin" and c.get("stdin_bytes"):
                print(c["stdin_shape"])
        return 0
    if cmd == "validate":
        apidoc = args[0]
        create = ps.method_properties(apidoc, "/nodes/{node}/lxc", "POST")
        setp = ps.method_properties(apidoc, "/nodes/{node}/lxc/{vmid}/config", "PUT")
        bad = 0
        n = 0
        for c in calls:
            if c["tool"] != "pct" or c["argv"][:1] not in (["create"], ["set"]):
                continue
            n += 1
            sub, rest = c["argv"][0], c["argv"][1:]
            schema, pos = (create, ["vmid", "ostemplate"]) if sub == "create" else (setp, ["vmid"])
            try:
                opts = ps.parse_cli(rest, schema, pos)
                ps.validate_params(opts, schema)
                print(f"OK   pct {sub} " + " ".join(f"{k}={v!r}" for k, v in opts.items()))
            except ps.PveError as e:
                bad += 1
                print(f"FAIL pct {sub}: {e}")
        print(f"{n} pct create/set call(s) checked, {bad} rejected")
        return 1 if bad or n == 0 else 0
    print(f"unknown command {cmd}", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main())
