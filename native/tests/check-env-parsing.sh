#!/usr/bin/env bash
#
# native/tests/check-env-parsing.sh
#
# Purpose: check that every reader of .env in this repository sees the same
# values as Docker Compose, and that the seeding CLI refuses an unpinned or
# altered Jackett search plugin. No containers, no root needed.
#
#   bash native/tests/check-env-parsing.sh
#
# 1. A .env with inline comments, quotes, escapes, duplicates and `export`
#    is read by `docker compose config` (the reference), by
#    scripts/env-editor/env_io.py parse_env_literal (seeding CLI, native
#    mode, TrueNAS) and by the bash env_get of the Unraid, Synology and
#    CasaOS installers. Every value must match Compose's.
#    (Needs docker with the compose plugin; skipped without it.)
# 2. seed_configs.py: the search plugin's commit and sha256 come from
#    native/versions.env, a download with another sha256 is refused and
#    nothing is written, and a qBittorrent 5 conf that has a [WebUI]
#    section gets the login there too. The download is faked, so no
#    network is needed.
# 3. The qBittorrent login rules both env-editor modes check before saving
#    (env_io.login_problems): QBITTORRENT_PASSWORD is also FileBrowser
#    Quantum's admin password, so 5 to 72 bytes and not "admin", and Docker
#    mode refuses the .env.example placeholders and a "$" (Compose would
#    expand it in the double quotes write_env uses). FileBrowser has no seeder
#    any more: the CLI refuses --only filebrowser, writes nothing for it,
#    and a password change still recreates FileBrowser. (The env-editor app
#    itself, which needs Flask, is tested by scripts/env-editor/tests/.)
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail
# The checks import scripts/env-editor/*.py: write no __pycache__ into the
# checkout (the Incus installer and tests copy the checkout as it is).
# python3 -I ignores PYTHON* variables, so its calls below also pass -B.
export PYTHONDONTWRITEBYTECODE=1

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
FAIL=0
ok() { printf '  ok    %s\n' "$1"; }
bad() {
  printf '  FAIL  %s\n' "$1"
  FAIL=1
}

# --- 1. .env parsing ---------------------------------------------------------
cat >"$WORK/.env" <<'EOF'
A=pw # note
B=pw# note
C="pw # note"
D="pw" # note
E='pw' # note
F='it\'s'
G="a\"b"
H="a\\b"
I="a\tb"
J=a\tb
K=1
K=2
L=pw	# tab comment
export M=x
N=  spaced value
O=
P='a"b' trailing
Q="x"y
R=#notcomment
S=a #b #c
T='a\\b'
V="a\xb"
W="a\\nb"
Z="a\nb"
AA="q\'q"
AB='x\"y'
AC=  "lead"  # c
AD=x #
AE="a"#c
AF="pa ss\\\"wd"
AG="d\$ollar"
EOF
KEYS="A B C D E F G H I J K L M N O P Q R S T V W Z AA AB AC AD AE AF AG"

echo "== .env parsing compared with docker compose"
if docker compose version >/dev/null 2>&1; then
  {
    echo "services:"
    echo "  t:"
    echo "    image: busybox"
    echo "    environment:"
    for k in $KEYS; do echo "      $k: \"\${$k-UNSET}\""; done
  } >"$WORK/compose.yaml"
  (cd "$WORK" && docker compose config --format json) >"$WORK/compose.json"
  for f in unraid synology casaos; do
    # The installer's own env_get function, nothing else from the script.
    bash -c 'eval "$(sed -n "/^env_get() {/,/^}/p" "$1")"; for k in $3; do printf "%s\0%s\0" "$k" "$(env_get "$2" "$k")"; done' \
      _ "$REPO/platforms/$f/install.sh" "$WORK/.env" "$KEYS" >"$WORK/bash-$f.out"
  done
  if out=$(python3 -I -B - "$REPO/scripts/env-editor" "$WORK" <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, sys.argv[1])
import env_io
work = Path(sys.argv[2])
# docker compose config writes a literal $ as $$.
want = {k: v.replace("$$", "$") for k, v in
        json.loads((work / "compose.json").read_text())["services"]["t"]["environment"].items()}
bad = []
got = env_io.parse_env_literal(work / ".env")
bad += [f"parse_env_literal {k}: {got.get(k)!r} != {v!r}" for k, v in want.items() if got.get(k) != v]
for f in ("unraid", "synology", "casaos"):
    parts = (work / f"bash-{f}.out").read_bytes().split(b"\0")[:-1]
    got = {parts[i].decode(): parts[i + 1].decode() for i in range(0, len(parts), 2)}
    bad += [f"{f} env_get {k}: {got.get(k)!r} != {v!r}" for k, v in want.items() if got.get(k) != v]
print("\n".join(bad) if bad else f"{len(want)} values")
sys.exit(1 if bad else 0)
PY
  ); then
    ok "parse_env_literal and the Unraid, Synology and CasaOS env_get match docker compose ($out)"
  else
    bad "a parser differs from docker compose:"
    printf '        %s\n' "$out"
  fi
else
  echo "  skip  docker compose is not available"
fi

# --- 2. seeding CLI: plugin pin and [WebUI] ----------------------------------
echo "== seed_configs.py: pinned search plugin, qBittorrent 5 [WebUI]"
if out=$(python3 -I -B - "$REPO" "$WORK" <<'PY' 2>&1
import hashlib, io, sys
from pathlib import Path
repo, work = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo / "scripts" / "env-editor"))
import seed_configs as sc

commit, want = sc.plugin_pin()
assert commit and want, "no pins"
served = {}
class Resp(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): return False
def fake_urlopen(url, timeout=0):
    served["url"] = url
    return Resp(served["body"])
sc.urllib.request.urlopen = fake_urlopen

root = work / "cfg"
plugin = root / "qbittorrent" / "qBittorrent" / "nova3" / "engines" / "jackett.py"
# A body whose sha256 does not match the pin: refused, nothing written.
served["body"] = b"print('not the pinned plugin')\n"
try:
    sc._install_qbit_search_plugin(root)
    sys.exit("an altered plugin was installed")
except RuntimeError as exc:
    assert "not installing" in str(exc), exc
assert not plugin.exists() and not plugin.with_name("jackett.py.part").exists(), "a file was left"
assert f"/{commit}/" in served["url"] and "/master/" not in served["url"], served["url"]
# Bad pins: refused.
bad = work / "versions.env"
bad.write_text("QBIT_SEARCH_PLUGINS_COMMIT=master\nQBIT_JACKETT_PLUGIN_SHA256=x\n")
try:
    sc.plugin_pin(bad)
    sys.exit("bad pins accepted")
except RuntimeError:
    pass
# [WebUI]: written once qBittorrent 5 has moved the login there.
plugin.parent.mkdir(parents=True, exist_ok=True)
plugin.write_text("stub")
conf = root / "qbittorrent" / "qBittorrent" / "qBittorrent.conf"
conf.write_text("[Preferences]\nWebUI\\Port=8090\n")
sc.seed_qbittorrent(root, "u1", "p1")
assert "[WebUI]" not in conf.read_text(), "unmigrated conf got [WebUI]"
conf.write_text("[Meta]\nMigrationVersion=12\n\n[WebUI]\nUsername=old\nPassword_PBKDF2=\"x\"\n")
sc.seed_qbittorrent(root, "u2", "p2")
webui = conf.read_text().split("[WebUI]")[1]
assert "Username=u2" in webui and "Username=old" not in webui, webui
print(f"pin {commit[:12]} ok")
PY
); then
  ok "plugin from the pinned commit only, a wrong sha256 refused with nothing written, bad pins refused, [WebUI] login written once migrated ($out)"
else
  bad "seeding CLI checks:"
  printf '        %s\n' "$out"
fi

# --- 3. qBittorrent login rules, no FileBrowser seeder ----------------------
echo "== env_io.login_problems and the seeding CLI without a FileBrowser seeder"
if out=$(python3 -I -B - "$REPO" "$WORK" <<'PY' 2>&1
import subprocess, sys
from pathlib import Path
repo, work = Path(sys.argv[1]), Path(sys.argv[2])
sys.path.insert(0, str(repo / "scripts" / "env-editor"))
import env_io, restart_map
import seed_configs as sc

example = env_io.parse_env(repo / ".env.example")
PU, PP = example["QBITTORRENT_USER"], example["QBITTORRENT_PASSWORD"]
assert PU and PP, "no placeholders in .env.example"
# (user, password, unset_ok, text every refusal must contain, or None for "accepted")
cases = [
    (PU, "Good-pass-1", False, "QBITTORRENT_USER is still the .env.example placeholder"),
    ("rob", PP, False, "QBITTORRENT_PASSWORD is still the .env.example placeholder"),
    (PU, PP, False, "QBITTORRENT_PASSWORD is still the .env.example placeholder"),
    ("", "Good-pass-1", False, "QBITTORRENT_USER is empty"),
    ("rob", "", False, "QBITTORRENT_PASSWORD is empty"),
    ("rob", "   ", False, "QBITTORRENT_PASSWORD is empty"),
    ("rob", "admin", False, 'cannot be "admin"'),
    ("rob", "abcd", False, "has 4 bytes"),
    ("rob", "éé", False, "has 4 bytes"),      # 2 characters, 4 bytes
    ("rob", "x" * 73, False, "has 73 bytes"),
    ("rob", "é" * 37, False, "has 74 bytes"),
    ("rob", "abcde", False, None),
    ("rob", "ééé", False, None),         # 3 characters, 6 bytes: FileBrowser counts bytes
    ("rob", "x" * 72, False, None),
    ("rob", "é" * 36, False, None),                # 72 bytes
    ("rob", "Admin", False, None),                      # FileBrowser compares exactly
    ("rob", 'pa ss"w\\ord #x', False, None),
    ("rob", 'pa ss"w\\ord$x', False, 'cannot contain "$"'),
    ("rob", "admin$xyz", False, 'cannot contain "$"'),
    # Native mode: an unset login means "not set up yet" (render.py's rule).
    (PU, PP, True, None),
    ("rob", "", True, None),
    ("rob", PP, True, None),
    ("", "Good-pass-1", True, None),
    ("rob", "admin", True, 'cannot be "admin"'),
    ("rob", "abcd", True, "has 4 bytes"),
    ("rob", "x" * 73, True, "has 73 bytes"),
    ("rob", "Good-pass-1", True, None),
    ("rob", 'pa ss"w\\ord$x', True, None),         # natively .env is read literally
]
for user, pw, unset_ok, want in cases:
    got = env_io.login_problems({"QBITTORRENT_USER": user, "QBITTORRENT_PASSWORD": pw},
                                example, unset_ok)
    label = f"{user!r}/{pw!r} unset_ok={unset_ok}"
    if want is None:
        assert got == [], f"{label} refused: {got}"
    else:
        assert got and any(want in p for p in got), f"{label}: {got} lacks {want!r}"
        if len(pw.strip()) > 1 and pw not in ("admin", PP):
            assert all(pw not in p for p in got), f"{label}: the password is in the message"
# A missing key counts as empty.
assert env_io.login_problems({}, example) == ["QBITTORRENT_USER is empty.",
                                              "QBITTORRENT_PASSWORD is empty."]

# No FileBrowser seeder: not in the module, refused by the CLI.
assert not hasattr(sc, "seed_filebrowser") and "filebrowser" not in sc.SEEDERS, sc.SEEDERS
env = work / "seed.env"
env.write_text((repo / ".env.example").read_text()
               .replace(f"QBITTORRENT_USER={PU}", "QBITTORRENT_USER=rob")
               .replace(f"QBITTORRENT_PASSWORD={PP}", "QBITTORRENT_PASSWORD=Good-pass-1"))
cli = subprocess.run([sys.executable, "-I", "-B", str(repo / "scripts" / "env-editor" / "seed_configs.py"),
                      "--env", str(env), "--config-root", str(work / "cli"), "--only", "jackett,filebrowser"],
                     capture_output=True, text=True)
assert cli.returncode == 2 and "unknown seeder(s): filebrowser" in cli.stderr, (cli.returncode, cli.stderr)
assert not (work / "cli").exists(), "a refused --only wrote files"
# Every seeder (the default): qBittorrent and Jackett, nothing for FileBrowser.
root = work / "all"
engines = root / "qbittorrent" / "qBittorrent" / "nova3" / "engines"
engines.mkdir(parents=True)
(engines / "jackett.py").write_text("stub")   # installed: nothing is downloaded
def no_network(*a, **k):
    raise AssertionError("the seeder tried to download")
sc.urllib.request.urlopen = no_network
log = sc.run_seeders(env, root)
assert not (root / "filebrowser").exists(), "something was written for FileBrowser"
assert (root / "qbittorrent" / "qBittorrent" / "qBittorrent.conf").is_file()
assert not any("FileBrowser" in line for line in log), log
# The placeholder login: qBittorrent is skipped with a warning.
env.write_text((repo / ".env.example").read_text())
log = sc.run_seeders(env, work / "placeholder")
assert any(l.startswith("WARNING:") and "skipped seeding qbit " in l for l in log), log
assert not (work / "placeholder" / "qbittorrent" / "qBittorrent" / "qBittorrent.conf").exists()

# A new password still recreates FileBrowser, which reads it at every start.
services, seeders, _ = restart_map.resolve({"QBITTORRENT_PASSWORD"}, {})
assert "filebrowser" in services and seeders == ["qbit"], (services, seeders)
print(f"{len(cases)} login cases")
PY
); then
  ok "login rules (placeholders, empty, admin, 5-72 bytes, \$ in Docker mode, native unset login), no FileBrowser seeder, password change recreates FileBrowser ($out)"
else
  bad "login rules / FileBrowser seeder checks:"
  printf '        %s\n' "$out"
fi

echo
if [[ "$FAIL" == 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit "$FAIL"
