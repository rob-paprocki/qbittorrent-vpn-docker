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
#
# Copyright (c) 2025-2026 Rob Paprocki
# License: MIT (see LICENSE in the repository root)

set -Eeuo pipefail

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
  if out=$(python3 -I - "$REPO/scripts/env-editor" "$WORK" <<'PY'
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
if out=$(python3 -I - "$REPO" "$WORK" <<'PY' 2>&1
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

echo
if [[ "$FAIL" == 0 ]]; then echo "All checks passed."; else echo "Some checks FAILED."; fi
exit "$FAIL"
