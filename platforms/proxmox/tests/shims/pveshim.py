#!/usr/bin/env python3
"""Stand-ins for Proxmox VE host tools, for testing platforms/proxmox/install.sh.

Purpose: run-tests.sh links this file as pct, pveam, pvesm, pvesh,
pveversion, timedatectl, modprobe and modinfo in a temporary bin directory.
Every call is appended to $PVE_SHIM_STATE/calls.jsonl. `pct create` and
`pct set` are checked against the official Proxmox VE API schema (see
tests/lib/pve_schema.py) and rejected the way Proxmox would reject them.

Two backends for containers (PCT_SHIM_BACKEND):
  incus  - each container is a real Incus system container named px-<CTID>
           (Debian 13), so `pct start/exec/push` really run in a guest.
           Proxmox options are translated: dev0=/dev/net/tun and raw
           lxc.cgroup2/lxc.mount.entry lines become the same device in Incus,
           features nesting -> security.nesting, cores/memory -> limits.*,
           bind mount points -> an Incus disk device.
  record - nothing is created; the config file and the calls are recorded,
           and `pct exec` answers only the probes the installer makes
           (hostname -I, getent, and test -f/-s/-e or cat on files it
           pushed with `pct push`). For argument/config tests.
           PCT_SHIM_NO_IP=1 makes `hostname -I` empty (no DHCP lease),
           PCT_SHIM_START_FAIL=1 makes `pct start` fail.

Behaviour copied from pve-container's src/PVE/CLI/pct.pm where it matters:
exec and push need a running container, push needs the target directory,
exec passes the caller's environment (keep-env defaults to 1) minus
SSL_CERT_FILE/SSL_CERT_DIR, errors exit 255.

License: MIT (see LICENSE in the repository root).
"""
from __future__ import annotations

import json
import os
import random
import re
import stat
import subprocess
import sys
import time
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.dont_write_bytecode = True  # keep __pycache__ out of the checkout
sys.path.insert(0, str(HERE.parent / "lib"))
import pve_schema as ps  # noqa: E402

STATE = Path(os.environ.get("PVE_SHIM_STATE", "/tmp/pve-shim-state"))
ETC = Path(os.environ.get("PVE_SHIM_ETC", "/etc/pve"))
BACKEND = os.environ.get("PCT_SHIM_BACKEND", "record")
APIDOC = os.environ.get("PVE_SHIM_APIDOC", "")
NODE = os.environ.get("PVE_SHIM_NODE", "pve")
# Incus name prefix for the backing containers (PVE_SHIM_PREFIX, default px-).
PREFIX = os.environ.get("PVE_SHIM_PREFIX", "px-")


def log_call(tool: str, argv: list[str], **extra) -> None:
    STATE.mkdir(parents=True, exist_ok=True)
    rec = {"tool": tool, "argv": argv, "t": round(time.time(), 3)}
    rec.update(extra)
    with open(STATE / "calls.jsonl", "a", encoding="utf-8") as fh:
        fh.write(json.dumps(rec) + "\n")


def fail(msg: str, code: int = 255) -> None:
    sys.stderr.write(msg.rstrip("\n") + "\n")
    sys.exit(code)


def run(cmd: list[str], **kw) -> subprocess.CompletedProcess:
    return subprocess.run(cmd, check=False, **kw)


def incus(*args: str, check: bool = True, capture: bool = False, **kw) -> subprocess.CompletedProcess:
    r = run(["incus", *args], capture_output=capture, text=True, **kw)
    if check and r.returncode != 0:
        fail(f"shim: incus {' '.join(args)} failed: {(r.stderr or '').strip()}")
    return r


# ---------------------------------------------------------------------------
# Storage fixture: $PVE_SHIM_STATE/storages.tsv
#   name  type  content(comma list)  total_kib  used_kib  avail_kib  [status]
# ---------------------------------------------------------------------------

def storages() -> list[dict]:
    out = []
    f = STATE / "storages.tsv"
    if not f.exists():
        return out
    for line in f.read_text().splitlines():
        if not line.strip() or line.startswith("#"):
            continue
        c = line.split("\t")
        out.append({"name": c[0], "type": c[1], "content": c[2].split(","),
                    "total": int(c[3]), "used": int(c[4]), "avail": int(c[5]),
                    "status": c[6] if len(c) > 6 else "active"})
    return out


def storage(name: str) -> dict | None:
    return next((s for s in storages() if s["name"] == name), None)


def template_dir(store: str) -> Path:
    return STATE / "storage" / store / "template" / "cache"


# ---------------------------------------------------------------------------
# Container config files (Proxmox format, sorted keys, description as
# leading '#' lines, raw lxc.* lines kept at the end)
# ---------------------------------------------------------------------------

def conf_path(vmid: str) -> Path:
    return ETC / "lxc" / f"{vmid}.conf"


def read_conf(vmid: str) -> tuple[dict, list[str], str]:
    p = conf_path(vmid)
    if not p.exists():
        fail(f"Configuration file 'nodes/{NODE}/lxc/{vmid}.conf' does not exist")
    conf, raw, desc = {}, [], []
    for line in p.read_text().splitlines():
        if not line.strip():
            continue
        if line.startswith("#"):
            desc.append(line[1:])
        elif re.match(r"lxc\.[a-z0-9_\-.]+(:|\s*=)", line):
            raw.append(line)
        else:
            k, _, v = line.partition(":")
            conf[k.strip()] = v.strip()
    return conf, raw, "\n".join(desc)


def write_conf(vmid: str, conf: dict, raw: list[str], desc: str) -> None:
    p = conf_path(vmid)
    p.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"#{d}" for d in desc.splitlines()] if desc else []
    lines += [f"{k}: {conf[k]}" for k in sorted(conf)]
    lines += raw
    p.write_text("\n".join(lines) + "\n")


def exists(vmid: str) -> bool:
    return conf_path(vmid).exists() or (ETC / "qemu-server" / f"{vmid}.conf").exists()


def state_file(vmid: str) -> Path:
    return STATE / "ct" / f"{vmid}.state"


def is_running(vmid: str) -> bool:
    if BACKEND == "incus":
        r = incus("list", f"^{PREFIX}{vmid}$", "-c", "s", "-f", "csv", capture=True, check=False)
        return r.stdout.strip() == "RUNNING"
    f = state_file(vmid)
    return f.exists() and f.read_text().strip() == "running"


def set_state(vmid: str, s: str) -> None:
    f = state_file(vmid)
    f.parent.mkdir(parents=True, exist_ok=True)
    f.write_text(s)


def props(path: str, method: str) -> dict:
    if not APIDOC:
        fail("shim: PVE_SHIM_APIDOC (path to the Proxmox apidoc.js) is not set")
    cache = STATE / f"schema-{method}-{path.replace('/', '_')}.json"
    if cache.exists():
        return json.loads(cache.read_text())
    p = ps.method_properties(APIDOC, path, method)
    cache.write_text(json.dumps(p))
    return p


def parse(argv: list[str], schema: dict, arg_params: list[str]) -> dict:
    try:
        opts = ps.parse_cli(argv, schema, arg_params)
        ps.validate_params(opts, schema)
    except ps.PveError as e:
        fail(str(e))
    return opts


def bool_opt(v: str | None, default: int) -> int:
    if v is None:
        return default
    b = ps.parse_boolean(v)
    return default if b is None else b


# ---------------------------------------------------------------------------
# Incus translation helpers
# ---------------------------------------------------------------------------

def incus_name(vmid: str) -> str:
    return f"{PREFIX}{vmid}"


def bridge_subnet() -> tuple[str, str] | None:
    r = incus("network", "get", "incusbr0", "ipv4.address", capture=True, check=False)
    v = r.stdout.strip()
    return (v.split("/")[0], v) if "/" in v else None


def apply_incus_devices(vmid: str, conf: dict, raw: list[str]) -> None:
    name = incus_name(vmid)
    have = incus("config", "device", "list", name, capture=True).stdout.split()
    for key, val in conf.items():
        if re.fullmatch(r"dev\d+", key) and key not in have:
            path = val.split(",")[0].removeprefix("path=")
            incus("config", "device", "add", name, key, "unix-char", f"source={path}", f"path={path}")
        if re.fullmatch(r"mp\d+", key) and key not in have:
            parts = dict(p.split("=", 1) for p in val.split(",")[1:] if "=" in p)
            src = val.split(",")[0].removeprefix("volume=")
            if src.startswith("/"):
                if not os.path.isdir(src):
                    fail(f"mount point '{src}' does not exist")
                # A plain Incus bind mount. Incus maps container ids to its own
                # host range (from /etc/subuid), not Proxmox's 100000+N, so
                # ownership translation is not reproduced here; the record
                # tests check the host-side ownership the installer sets.
                incus("config", "device", "add", name, key, "disk", f"source={src}",
                      f"path={parts['mp']}")
    lxc_lines = []
    for line in raw:
        k, v = re.split(r":|\s*=", line, maxsplit=1)
        k, v = k.strip(), v.strip()
        if k == "lxc.idmap":
            fail("shim: lxc.idmap needs root's /etc/subuid on this test host; use the record backend")
        if k == "lxc.mount.entry" and v.split()[0] == "/dev/net/tun" and stat.S_IMODE(os.stat("/dev/net/tun").st_mode) != 0o666:
            # Proxmox hosts have /dev/net/tun as 0666 (the kernel default);
            # this test host has 0600, which no unprivileged container can
            # open. Bind a 0666 node of the same device (10:200) instead.
            # It must sit where the container's mapped root can reach it.
            nd = Path(os.environ.get("PVE_SHIM_TUN_DIR", "/var/tmp/px-shim-tun"))
            nd.mkdir(mode=0o755, exist_ok=True)
            os.chmod(nd, 0o755)
            node = nd / "net-tun"
            if not node.exists():
                os.mknod(node, 0o666 | stat.S_IFCHR, os.makedev(10, 200))
                os.chmod(node, 0o666)
            v = v.replace("/dev/net/tun", str(node), 1)
        lxc_lines.append(f"{k} = {v}")
    if lxc_lines:
        incus("config", "set", name, "raw.lxc", "\n".join(lxc_lines))
    incus("config", "set", name, "boot.autostart", "true" if conf.get("onboot") == "1" else "false")


# ---------------------------------------------------------------------------
# pct
# ---------------------------------------------------------------------------

def pct_create(argv: list[str]) -> None:
    schema = props("/nodes/{node}/lxc", "POST")
    opts = parse(argv, schema, ["vmid", "ostemplate"])
    vmid = opts.pop("vmid")
    tmpl = opts.pop("ostemplate")
    if exists(vmid):
        fail(f"unable to create CT {vmid} - CT {vmid} already exists on node '{NODE}'")
    m = re.fullmatch(r"([^:]+):vztmpl/(.+)", tmpl)
    if not m or not (template_dir(m.group(1)) / m.group(2)).exists():
        fail(f"unable to create CT {vmid} - volume '{tmpl}' does not exist")
    rootfs = opts.pop("rootfs", None) or f"{opts.get('storage', 'local')}:4"
    rm = re.fullmatch(r"([^:,]+):(\d+)(,.*)?", rootfs)
    if not rm:
        fail(f"unable to create CT {vmid} - test shim only supports STORAGE:SIZE_GiB for rootfs")
    st = storage(rm.group(1))
    if not st or "rootdir" not in st["content"]:
        fail(f"unable to create CT {vmid} - storage '{rm.group(1)}' does not support container directories")
    for k, v in opts.items():
        if re.fullmatch(r"dev\d+", k):
            path = v.split(",")[0].removeprefix("path=")
            if not os.path.exists(path) or not (stat.S_ISCHR(os.stat(path).st_mode) or stat.S_ISBLK(os.stat(path).st_mode)):
                fail(f"unable to create CT {vmid} - Path {path} is not a device")
    keys = None
    if "ssh-public-keys" in opts:
        kf = opts.pop("ssh-public-keys")
        try:
            keys = Path(kf).read_text()
        except OSError as e:
            fail(f"unable to open file '{kf}' - {e.strerror}")
    password_on_cmdline = "password" in opts
    opts.pop("password", None)
    conf = {
        "arch": opts.pop("arch", "amd64"),
        "memory": opts.pop("memory", "512"),
        "swap": opts.pop("swap", "512"),
        "ostype": opts.pop("ostype", "debian"),
        "unprivileged": str(bool_opt(opts.pop("unprivileged", None), 1)),
        "rootfs": f"{rm.group(1)}:vm-{vmid}-disk-0,size={rm.group(2)}G",
    }
    desc = opts.pop("description", "")
    for k, v in opts.items():
        if re.fullmatch(r"net\d+", k):
            parts = v.split(",")
            if not any(p.startswith("hwaddr=") for p in parts):
                parts.insert(1, "hwaddr=BC:24:11:%02X:%02X:%02X" % tuple(random.randrange(256) for _ in range(3)))
            if not any(p.startswith("type=") for p in parts):
                parts.append("type=veth")
            v = ",".join(parts)
        if ps.resolve_prop(schema, k) and ps.resolve_prop(schema, k).get("type") == "boolean":
            v = str(bool_opt(v, 1))
        conf[k] = v
    write_conf(vmid, conf, [], desc)
    log_call("pct-create-result", [vmid], password_on_cmdline=password_on_cmdline,
             ssh_keys=keys is not None)
    print(f"extracting archive '{template_dir(m.group(1)) / m.group(2)}'")
    if BACKEND == "incus":
        name = incus_name(vmid)
        incus("init", "images:debian/13", name, "-q",
              "-c", f"security.nesting={'true' if 'nesting=1' in conf.get('features', '') else 'false'}",
              "-c", f"security.privileged={'false' if conf['unprivileged'] == '1' else 'true'}",
              "-c", f"limits.cpu={conf.get('cores', '1')}",
              "-c", f"limits.memory={conf['memory']}MiB")
        tmp = STATE / f"push-{vmid}"
        tmp.mkdir(parents=True, exist_ok=True)
        if keys is not None:
            (tmp / "authorized_keys").write_text(keys)
            incus("file", "push", str(tmp / "authorized_keys"), f"{name}/root/.ssh/authorized_keys",
                  "--create-dirs", "--mode", "0600", "-q")
        ipm = re.search(r"(?:^|,)ip=([0-9.]+)/(\d+)", conf.get("net0", ""))
        sub = bridge_subnet()
        if ipm and sub:
            import ipaddress
            if ipaddress.ip_address(ipm.group(1)) in ipaddress.ip_network(sub[1], strict=False):
                # Stand-in for a static address: a fixed lease on the Incus bridge.
                incus("config", "device", "override", name, "eth0", f"ipv4.address={ipm.group(1)}")
    print(f"Creating SSH host key 'ssh_host_ed25519_key' - this may take some time ...\ndone: SHA256:shim root@{conf.get('hostname', 'localhost')}")
    set_state(vmid, "stopped")


def pct_set(argv: list[str]) -> None:
    schema = props("/nodes/{node}/lxc/{vmid}/config", "PUT")
    opts = parse(argv, schema, ["vmid"])
    vmid = opts.pop("vmid")
    conf, raw, desc = read_conf(vmid)
    for k in [d for d in re.split(r"[,;\s]+", opts.pop("delete", "")) if d]:
        conf.pop(k, None)
    if "description" in opts:
        desc = opts.pop("description")
    conf.update(opts)
    write_conf(vmid, conf, raw, desc)


def pct_start(argv: list[str]) -> None:
    vmid = argv[0] if argv else fail("400 not enough arguments")
    conf, raw, _ = read_conf(vmid)
    if is_running(vmid):
        fail(f"CT {vmid} already running")
    # PCT_SHIM_START_FAIL=1: the container cannot start (for --resume tests).
    if os.environ.get("PCT_SHIM_START_FAIL") == "1":
        fail(f"startup for container '{vmid}' failed")
    for k, v in conf.items():
        if re.fullmatch(r"mp\d+", k):
            src = v.split(",")[0].removeprefix("volume=")
            if src.startswith("/") and not os.path.isdir(src):
                fail(f"mount point '{src}' does not exist\nstartup for container '{vmid}' failed")
    if BACKEND == "incus":
        apply_incus_devices(vmid, conf, raw)
        incus("start", incus_name(vmid))
        for _ in range(30):
            if incus("exec", incus_name(vmid), "--", "true", check=False).returncode == 0:
                break
            time.sleep(1)
        # Test-network fixture, not Proxmox behaviour: this sandbox
        # intercepts the containers' HTTPS with its own CA, which a guest on a
        # normal LAN never sees. run-tests.sh passes that CA when it exists.
        # Wait for boot to finish first: an update-ca-certificates run while
        # the guest is still starting did not reach the bundle (seen in the
        # integration run). --fresh rebuilds it, and the bundle is checked.
        ca = os.environ.get("PVE_SHIM_GUEST_CA")
        if ca and os.path.isfile(ca):
            name = incus_name(vmid)
            incus("exec", name, "--", "sh", "-c",
                  "timeout 120 systemctl is-system-running --wait >/dev/null 2>&1 || true", check=False)
            incus("file", "push", ca, f"{name}/usr/local/share/ca-certificates/test-network-ca.crt", "-q", check=False)
            # A line from the middle of the CA's PEM text: update-ca-certificates
            # copies certificates into the bundle verbatim.
            pem = [ln.strip() for ln in Path(ca).read_text().splitlines()
                   if ln.strip() and not ln.startswith("-----")]
            marker = pem[len(pem) // 2] if pem else ""
            check_cmd = ("command -v update-ca-certificates >/dev/null || exit 0; "
                         "update-ca-certificates --fresh >/dev/null 2>&1; "
                         'grep -qF -- "$1" /etc/ssl/certs/ca-certificates.crt')
            for _ in range(3):
                if incus("exec", name, "--", "sh", "-c", check_cmd, "sh", marker, check=False).returncode == 0:
                    break
                time.sleep(2)
            else:
                sys.stderr.write(f"pveshim: test CA did not reach {name}'s CA bundle\n")
        # Proxmox's container setup writes the hostname and time zone on
        # every start (Incus's image templates would otherwise win).
        hn = conf.get("hostname", f"CT{vmid}")
        incus("exec", incus_name(vmid), "--", "sh", "-c",
              f"echo '{hn}' > /etc/hostname && hostname '{hn}'", check=False)
        tz = conf.get("timezone")
        if tz:
            target = "/usr/share/zoneinfo/" + ("Etc/UTC" if tz == "UTC" else tz)
            incus("exec", incus_name(vmid), "--", "sh", "-c",
                  f"ln -sf '{target}' /etc/localtime && echo '{tz}' > /etc/timezone", check=False)
    set_state(vmid, "running")


def pct_stop(argv: list[str]) -> None:
    vmid = argv[0]
    read_conf(vmid)
    if BACKEND == "incus" and is_running(vmid):
        incus("stop", "--force", incus_name(vmid))
    set_state(vmid, "stopped")


def pct_status(argv: list[str]) -> None:
    vmid = argv[0] if argv else fail("400 not enough arguments")
    read_conf(vmid)
    print(f"status: {'running' if is_running(vmid) else 'stopped'}")


def pct_exec(argv: list[str]) -> None:
    if not argv:
        fail("400 not enough arguments")
    vmid, rest = argv[0], argv[1:]
    keep_env = 1
    while rest and rest[0] != "--":
        if rest[0] in ("--keep-env", "-keep-env") and len(rest) > 1:
            keep_env = bool_opt(rest[1], 1)
            rest = rest[2:]
        else:
            # pct would parse this as an option too; the installer always uses --
            fail(f"Unknown option: {rest[0].lstrip('-')}\n400 unable to parse option")
    cmd = rest[1:]
    read_conf(vmid)
    if not is_running(vmid):
        fail(f"container '{vmid}' not running!")
    if not cmd:
        fail("missing command")
    stdin_data = None
    if not sys.stdin.isatty():
        stdin_data = sys.stdin.buffer.read()
    log_call("pct-exec-stdin", [vmid], stdin_bytes=len(stdin_data or b""),
             stdin_shape=re.sub(rb":.*", b":<redacted>", (stdin_data or b"")[:80]).decode("utf-8", "replace"))
    if BACKEND == "incus":
        env_args = []
        if keep_env:
            for k, v in os.environ.items():
                if k in ("SSL_CERT_FILE", "SSL_CERT_DIR") or "\n" in v:
                    continue
                env_args += ["--env", f"{k}={v}"]
        r = run(["incus", "exec", "-T", *env_args, incus_name(vmid), "--", *cmd], input=stdin_data)
        sys.exit(r.returncode)
    # record backend: answer the probes the installer makes.
    joined = " ".join(cmd)
    conf, _, _ = read_conf(vmid)
    # Files the installer pushed are "in the guest": test -f/-s/-e and cat
    # answer from them (after an `env -i VAR=... ` prefix).
    inner = cmd
    if inner[:2] == ["env", "-i"]:
        inner = inner[2:]
        while inner and re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*=.*", inner[0], re.S):
            inner = inner[1:]
    pushed = STATE / "pushed" / vmid
    if len(inner) == 3 and inner[0] == "test" and inner[1] in ("-f", "-s", "-e"):
        f = pushed / inner[2].strip("/").replace("/", "__")
        ok = f.is_file() and (inner[1] != "-s" or f.stat().st_size > 0)
        sys.exit(0 if ok else 1)
    if len(inner) == 2 and inner[0] == "cat":
        f = pushed / inner[1].strip("/").replace("/", "__")
        if not f.is_file():
            fail(f"cat: {inner[1]}: No such file or directory", 1)
        sys.stdout.buffer.write(f.read_bytes())
        sys.exit(0)
    if re.search(r"(^| )hostname -I( |$)", joined):
        # PCT_SHIM_NO_IP=1: the guest never gets an address (DHCP broken).
        if os.environ.get("PCT_SHIM_NO_IP") == "1":
            print("")
            sys.exit(0)
        m = re.search(r"(?:^|,)ip=([0-9.]+)/", conf.get("net0", ""))
        print((m.group(1) if m else "192.0.2.50") + " ")
    elif "getent" in cmd:
        print("203.0.113.7     STREAM deb.debian.org")
    elif cmd[-1:] == ["install"] and any("native" in c for c in cmd):
        print("record backend: native/install.sh install not run")
    sys.exit(0)


def pct_push(argv: list[str]) -> None:
    opts = {}
    pos = []
    i = 0
    while i < len(argv):
        if argv[i] in ("--perms", "--user", "--group", "-perms", "-user", "-group"):
            opts[argv[i].lstrip("-")] = argv[i + 1]
            i += 2
            continue
        pos.append(argv[i])
        i += 1
    if len(pos) != 3:
        fail("400 not enough arguments" if len(pos) < 3 else "400 too many arguments")
    vmid, src, dest = pos
    read_conf(vmid)
    if not is_running(vmid):
        fail("can only push files to a running CT")
    if not os.path.isfile(src):
        fail(f"failed to open {src} for reading")
    perms = opts.get("perms")
    if perms is not None and not perms.startswith("0"):
        perms = "0" + perms
    log_call("pct-push-file", [vmid, src, dest], perms=perms, size=os.path.getsize(src),
             mode=oct(os.stat(src).st_mode & 0o777))
    if BACKEND == "incus":
        name = incus_name(vmid)
        parent = os.path.dirname(dest) or "/"
        if incus("exec", name, "--", "test", "-d", parent, check=False).returncode != 0:
            fail(f"failed to create file '{dest}': No such file or directory")
        args = ["file", "push", src, f"{name}{dest}", "-q"]
        if perms:
            args += ["--mode", perms]
        if "user" in opts:
            args += ["--uid", opts["user"]]
        if "group" in opts:
            args += ["--gid", opts["group"]]
        incus(*args)
    else:
        saved = STATE / "pushed" / vmid
        saved.mkdir(parents=True, exist_ok=True)
        (saved / dest.strip("/").replace("/", "__")).write_bytes(Path(src).read_bytes())


def pct_config(argv: list[str]) -> None:
    conf, raw, desc = read_conf(argv[0])
    if desc:
        print("description: " + desc.replace("\n", "\\n"))
    for k in sorted(conf):
        print(f"{k}: {conf[k]}")
    for line in raw:
        print(line)


def pct_list(argv: list[str]) -> None:
    d = ETC / "lxc"
    print(f"{'VMID':<10} {'Status':<10} {'Lock':<12} Name")
    for p in sorted(d.glob("*.conf"), key=lambda p: int(p.stem)) if d.exists() else []:
        conf, _, _ = read_conf(p.stem)
        print(f"{p.stem:<10} {'running' if is_running(p.stem) else 'stopped':<10} {'':<12} {conf.get('hostname', '')}")


def pct_destroy(argv: list[str]) -> None:
    vmid = argv[0]
    read_conf(vmid)
    force = "--force" in argv or "-force" in argv
    if is_running(vmid) and not force:
        fail(f"CT {vmid} is running - destroy failed")
    if BACKEND == "incus":
        incus("delete", "--force", incus_name(vmid), check=False)
    conf_path(vmid).unlink()
    state_file(vmid).unlink(missing_ok=True)


def main_pct(argv: list[str]) -> None:
    if not argv:
        fail("ERROR: no command specified")
    cmd, rest = argv[0], argv[1:]
    table = {"create": pct_create, "set": pct_set, "start": pct_start, "stop": pct_stop,
             "shutdown": pct_stop, "status": pct_status, "exec": pct_exec, "push": pct_push,
             "config": pct_config, "list": pct_list, "destroy": pct_destroy}
    if cmd not in table:
        fail(f"ERROR: unknown command 'pct {cmd}'")
    table[cmd](rest)


# ---------------------------------------------------------------------------
# pveam / pvesm / pvesh / pveversion
# ---------------------------------------------------------------------------

def available_templates() -> list[tuple[str, str]]:
    f = STATE / "aplinfo.tsv"
    out = []
    for line in f.read_text().splitlines() if f.exists() else []:
        if line.strip():
            sec, name = line.split("\t")
            out.append((sec, name))
    return out


def main_pveam(argv: list[str]) -> None:
    offline = os.environ.get("PVEAM_SHIM_OFFLINE") == "1"
    if not argv:
        fail("ERROR: no command specified")
    cmd = argv[0]
    if cmd == "update":
        if offline:
            fail("update failed - see /var/log/pveam.log for details")
        print("update successful")
    elif cmd == "available":
        section = argv[argv.index("--section") + 1] if "--section" in argv else None
        for sec, name in available_templates():
            if section is None or sec == section:
                print(f"{sec:<15} {name}")
    elif cmd == "list":
        store = argv[1]
        st = storage(store) or fail(f"storage '{store}' does not exist")
        if "vztmpl" not in st["content"]:
            fail(f"storage '{store}' does not support templates")
        print(f"{'NAME':<60} SIZE")
        d = template_dir(store)
        for p in sorted(d.glob("*")) if d.exists() else []:
            print(f"{store + ':vztmpl/' + p.name:<60} 128.00MB")
    elif cmd == "download":
        store, name = argv[1], argv[2]
        st = storage(store) or fail(f"storage '{store}' does not exist")
        if "vztmpl" not in st["content"]:
            fail(f"400 Parameter verification failed.\nstorage: storage '{store}' does not support templates")
        if name not in [n for _, n in available_templates()]:
            fail(f"400 Parameter verification failed.\ntemplate: no such template")
        if offline:
            fail(f"download failed: unable to resolve 'download.proxmox.com'")
        d = template_dir(store)
        d.mkdir(parents=True, exist_ok=True)
        (d / name).write_text("shim template\n")
        print(f"downloading http://download.proxmox.com/images/system/{name} to {d / name}")
        print(f"download of 'http://download.proxmox.com/images/system/{name}' to '{d / name}' finished")
    else:
        fail(f"ERROR: unknown command 'pveam {cmd}'")


def main_pvesm(argv: list[str]) -> None:
    if not argv:
        fail("ERROR: no command specified")
    cmd, rest = argv[0], argv[1:]
    if cmd == "status":
        content = storage_name = None
        i = 0
        while i < len(rest):
            if rest[i] in ("--content", "-content"):
                content = rest[i + 1]
                i += 2
            elif rest[i] in ("--storage", "-storage"):
                storage_name = rest[i + 1]
                i += 2
            elif rest[i] in ("--enabled", "-enabled"):
                i += 2
            else:
                fail(f"Unknown option: {rest[i]}\n400 unable to parse option")
        if storage_name and not storage(storage_name):
            fail(f"storage '{storage_name}' does not exist")
        print(f"{'Name':<16} {'Type':>8} {'Status':>8} {'Total':>15} {'Used':>15} {'Available':>15} {'%':>8}")
        for s in storages():
            if content and content not in s["content"]:
                continue
            if storage_name and s["name"] != storage_name:
                continue
            pct = 100.0 * s["used"] / s["total"] if s["total"] else 0
            print(f"{s['name']:<16} {s['type']:>8} {s['status']:>8} {s['total']:>15} {s['used']:>15} {s['avail']:>15} {pct:>7.2f}%")
    elif cmd == "path":
        m = re.fullmatch(r"([^:]+):vztmpl/(.+)", rest[0])
        if not m:
            fail("shim: only vztmpl volumes")
        print(template_dir(m.group(1)) / m.group(2))
    else:
        fail(f"ERROR: unknown command 'pvesm {cmd}'")


def main_pvesh(argv: list[str]) -> None:
    if len(argv) < 2 or argv[0] != "get":
        fail("shim: only 'pvesh get' is implemented")
    path = argv[1]
    if path != "/cluster/nextid":
        fail(f"No 'get' handler defined for '{path}'")
    used = {int(x) for x in os.environ.get("PVE_SHIM_USED_IDS", "").split() if x}
    for sub in ("lxc", "qemu-server"):
        d = ETC / sub
        used |= {int(p.stem) for p in d.glob("*.conf")} if d.exists() else set()
    if "--vmid" in argv:
        vmid = int(argv[argv.index("--vmid") + 1])
        if vmid in used:
            fail(f"400 Parameter verification failed.\nvmid: VM {vmid} already exists")
        print(vmid)
        return
    n = 100
    while n in used:
        n += 1
    print(n)


def main_pveversion(argv: list[str]) -> None:
    ver = os.environ.get("PVE_SHIM_VERSION", "9.2.13")
    print(f"pve-manager/{ver}/2a5c0f1e9d8b7c6a (running kernel: 6.17.2-1-pve)")


def main_timedatectl(argv: list[str]) -> None:
    tz = os.environ.get("PVE_SHIM_TZ")
    if argv[:1] == ["show"] and tz:
        print(tz)
        return
    fail("System has not been booted with systemd as init system (PID 1). Can't operate.", 1)


def main_modprobe(argv: list[str]) -> None:
    mods = os.environ.get("PVE_SHIM_MODULES", "tun wireguard").split()
    if argv and argv[-1] not in mods:
        fail(f"modprobe: FATAL: Module {argv[-1]} not found in directory /lib/modules/6.17.2-1-pve", 1)


def main_modinfo(argv: list[str]) -> None:
    mods = os.environ.get("PVE_SHIM_MODULES", "tun wireguard").split()
    if argv and argv[-1] in mods:
        print(f"filename:       /lib/modules/6.17.2-1-pve/kernel/drivers/net/{argv[-1]}.ko")
        return
    fail(f"modinfo: ERROR: Module {argv[-1] if argv else ''} not found.", 1)


def main_dpkg(argv: list[str]) -> None:
    # Only what the installer asks: the host architecture.
    if argv == ["--print-architecture"]:
        print(os.environ.get("PVE_SHIM_ARCH", "amd64"))
        return
    os.execv("/usr/bin/dpkg", ["dpkg", *argv])


def main() -> None:
    tool = Path(sys.argv[0]).name
    argv = sys.argv[1:]
    log_call(tool, argv)
    {"pct": main_pct, "pveam": main_pveam, "pvesm": main_pvesm, "pvesh": main_pvesh,
     "pveversion": main_pveversion, "timedatectl": main_timedatectl,
     "modprobe": main_modprobe, "modinfo": main_modinfo, "dpkg": main_dpkg}.get(
        tool, lambda a: fail(f"pveshim: unknown tool name {tool}"))(argv)


if __name__ == "__main__":
    main()
