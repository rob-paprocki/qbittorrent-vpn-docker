"""
platforms/truenas/tests/lib/fake_middleware.py

Purpose: a small stand-in for the TrueNAS middleware, used by the test
shims (tests/shims/midclt and tests/pylib/truenas_api_client) to test
platforms/truenas/install.sh without a TrueNAS machine.

  - Every call is checked against the call parameters documented for
    TrueNAS 25.10 (https://api.truenas.com/v25.10/, set TN_SHIM_API=27.0
    for the 27.0 differences that matter here), including whether the
    method is a job: midclt needs -j for a job and must not get it for a
    plain method.
  - Every call is appended to $TN_SHIM_STATE/calls.jsonl, with the command
    line for midclt calls (the tests check that no secret is on it).
  - State (pools, datasets, apps) lives in $TN_SHIM_STATE/state.json.
    Datasets are real folders under their mountpoints (the test runner
    puts a private tmpfs on /mnt), and chown/setperm really change owners,
    so the installer's file work can be checked afterwards.
  - app.create/app.update validate the YAML as middlewared 25.10 does
    (plugins/apps/custom_app_utils.py): exactly one of the two compose
    fields, YAML that parses, and `docker compose -f FILE config`.

License: MIT (see LICENSE in the repository root).
"""
from __future__ import annotations

import fcntl
import json
import os
import re
import subprocess
import tempfile
from pathlib import Path

import yaml

STATE_DIR = Path(os.environ.get("TN_SHIM_STATE", "/tmp/tn-shim-state"))
API = os.environ.get("TN_SHIM_API", "25.10")


class CallError(Exception):
    """An error the middleware would report (midclt exits 1)."""


class SchemaError(CallError):
    """The call did not match the documented parameters."""


# ---------------------------------------------------------------------------
# Documented parameters (TrueNAS API v25.10)
# ---------------------------------------------------------------------------

BOOL = {"type": "boolean"}
STR = {"type": "string"}
NONEMPTY = {"type": "string", "minLength": 1}
INT = {"type": "integer"}
UIDGID = {"type": ["integer", "null"], "minimum": -1, "maximum": 2147483647}
NAME_OR_NULL = {"type": ["string", "null"], "minLength": 1}

QUERY_FILTERS = {"type": "array", "items": {"type": "array"}}
QUERY_OPTIONS = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "extra": {"type": "object"}, "order_by": {"type": "array", "items": STR},
        "select": {"type": "array"}, "count": BOOL, "get": BOOL,
        "offset": {"type": "integer", "minimum": 0},
        "limit": {"type": "integer", "minimum": 0, "maximum": 10000},
        "force_sql_filters": BOOL,
    },
}
INHERIT_ENUM = lambda *v: {"type": "string", "enum": list(v) + ["INHERIT"]}  # noqa: E731
DATASET_CREATE_FS = {
    "type": "object", "additionalProperties": False, "required": ["name"],
    "properties": {
        "name": NONEMPTY, "comments": STR,
        "sync": INHERIT_ENUM("STANDARD", "ALWAYS", "DISABLED"),
        "snapdev": INHERIT_ENUM("HIDDEN", "VISIBLE"),
        "compression": STR, "exec": INHERIT_ENUM("ON", "OFF"), "managedby": NONEMPTY,
        "quota_warning": {}, "quota_critical": {}, "refquota_warning": {}, "refquota_critical": {},
        "reservation": INT, "refreservation": INT, "special_small_block_size": {}, "copies": {},
        "snapdir": INHERIT_ENUM("DISABLED", "VISIBLE", "HIDDEN"),
        "deduplication": INHERIT_ENUM("ON", "VERIFY", "OFF"), "checksum": STR,
        "readonly": INHERIT_ENUM("ON", "OFF"),
        "share_type": {"type": "string", "enum": ["GENERIC", "MULTIPROTOCOL", "NFS", "SMB", "APPS"]},
        "encryption_options": {"type": "object"}, "encryption": BOOL, "inherit_encryption": BOOL,
        "user_properties": {"type": "array"}, "create_ancestors": BOOL,
        "type": {"type": "string", "enum": ["FILESYSTEM"]},
        "aclmode": INHERIT_ENUM("PASSTHROUGH", "RESTRICTED", "DISCARD"),
        "acltype": INHERIT_ENUM("OFF", "NFSV4", "POSIX"),
        "atime": INHERIT_ENUM("ON", "OFF"),
        "casesensitivity": INHERIT_ENUM("SENSITIVE", "INSENSITIVE"),
        "quota": {}, "refquota": {}, "recordsize": STR,
    },
}
CHOWN = {
    "type": "object", "additionalProperties": False, "required": ["path"],
    "properties": {
        "path": NONEMPTY, "uid": UIDGID, "user": NAME_OR_NULL, "gid": UIDGID, "group": NAME_OR_NULL,
        "options": {"type": "object", "additionalProperties": False,
                    "properties": {"recursive": BOOL, "traverse": BOOL}},
    },
}
SETPERM = {
    "type": "object", "additionalProperties": False, "required": ["path"],
    "properties": {
        "path": NONEMPTY, "uid": UIDGID, "user": NAME_OR_NULL, "gid": UIDGID, "group": NAME_OR_NULL,
        "mode": {"type": ["string", "null"]},
        "options": {"type": "object", "additionalProperties": False,
                    "properties": {"recursive": BOOL, "traverse": BOOL, "stripacl": BOOL}},
    },
}
IMAGE_PULL = {
    "type": "object", "additionalProperties": False, "required": ["image"],
    "properties": {"auth_config": {"type": ["object", "null"]}, "image": NONEMPTY},
}
APP_NAME = {"type": "string", "pattern": r"^[a-z]([-a-z0-9]*[a-z0-9])?$", "minLength": 1, "maxLength": 40}
APP_CREATE = {
    "type": "object", "additionalProperties": False, "required": ["app_name"],
    "properties": {
        "custom_app": BOOL, "values": {"type": "object"}, "custom_compose_config": {"type": "object"},
        "custom_compose_config_string": {"type": "string", "maxLength": 2147483647},
        "catalog_app": {"type": ["string", "null"]}, "app_name": APP_NAME,
        "train": NONEMPTY, "version": NONEMPTY,
    },
}
APP_UPDATE = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "values": {"type": "object"}, "custom_compose_config": {"type": "object"},
        "custom_compose_config_string": {"type": "string", "maxLength": 2147483647},
    },
}
APP_DELETE_OPTS = {
    "type": "object", "additionalProperties": False,
    "properties": {"remove_images": BOOL, "remove_ix_volumes": BOOL,
                   "force_remove_ix_volumes": BOOL, "force_remove_custom_app": BOOL},
}
if API.startswith("27"):
    # 27.0 dropped force_remove_ix_volumes from app.delete.
    APP_DELETE_OPTS = dict(APP_DELETE_OPTS, properties={
        k: v for k, v in APP_DELETE_OPTS["properties"].items() if k != "force_remove_ix_volumes"})

# method: (is a job, [parameter schemas], number of required parameters)
METHODS: dict[str, tuple[bool, list[dict], int]] = {
    "system.version": (False, [], 0),
    "docker.status": (False, [], 0),
    "docker.config": (False, [], 0),
    "system.general.config": (False, [], 0),
    "pool.query": (False, [QUERY_FILTERS, QUERY_OPTIONS], 0),
    "pool.dataset.query": (False, [QUERY_FILTERS, QUERY_OPTIONS], 0),
    "pool.dataset.create": (False, [DATASET_CREATE_FS], 1),
    "filesystem.chown": (True, [CHOWN], 1),
    "filesystem.setperm": (True, [SETPERM], 1),
    "app.query": (False, [QUERY_FILTERS, QUERY_OPTIONS], 0),
    "app.config": (False, [NONEMPTY], 1),
    "app.used_ports": (False, [], 0),
    "app.image.pull": (True, [IMAGE_PULL], 1),
    "app.create": (True, [APP_CREATE], 1),
    "app.update": (True, [NONEMPTY, APP_UPDATE], 1),
    "app.delete": (True, [NONEMPTY, APP_DELETE_OPTS], 1),
    "app.start": (True, [NONEMPTY], 1),
    "app.stop": (True, [NONEMPTY], 1),
}

_TYPES = {
    "object": dict, "array": list, "string": str, "boolean": bool, "null": type(None),
}


def check(value, schema: dict, where: str) -> None:
    """Validate value against the small JSON-schema subset used above."""
    types = schema.get("type")
    if types is not None:
        types = types if isinstance(types, list) else [types]
        ok = False
        for t in types:
            if t == "integer":
                ok = ok or (isinstance(value, int) and not isinstance(value, bool))
            elif isinstance(value, _TYPES[t]) and not (t != "boolean" and isinstance(value, bool)):
                ok = True
        if not ok:
            raise SchemaError(f"{where}: expected {'/'.join(types)}, got {type(value).__name__} {value!r}")
    if value is None:
        return
    if "enum" in schema and value not in schema["enum"]:
        raise SchemaError(f"{where}: {value!r} is not one of {schema['enum']}")
    if isinstance(value, str):
        if len(value) < schema.get("minLength", 0) or len(value) > schema.get("maxLength", 1 << 62):
            raise SchemaError(f"{where}: length {len(value)} out of range")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            raise SchemaError(f"{where}: {value!r} does not match {schema['pattern']}")
    if isinstance(value, int) and not isinstance(value, bool):
        if value < schema.get("minimum", -(1 << 62)) or value > schema.get("maximum", 1 << 62):
            raise SchemaError(f"{where}: {value} out of range")
    if isinstance(value, dict):
        props = schema.get("properties", {})
        for req in schema.get("required", []):
            if req not in value:
                raise SchemaError(f"{where}: missing required {req!r}")
        for key, sub in value.items():
            if key in props:
                check(sub, props[key], f"{where}.{key}")
            elif schema.get("additionalProperties") is False:
                raise SchemaError(f"{where}: {key!r} is not a documented field")
    if isinstance(value, list) and "items" in schema:
        for i, item in enumerate(value):
            check(item, schema["items"], f"{where}[{i}]")


def validate_call(method: str, params: list, job: bool) -> None:
    if method not in METHODS:
        raise SchemaError(f"{method}: not a method this installer should call (no schema)")
    is_job, schemas, required = METHODS[method]
    if is_job != job:
        raise SchemaError(f"{method}: {'is' if is_job else 'is not'} a job, but was called "
                          f"{'with' if job else 'without'} job handling (-j)")
    if len(params) > len(schemas):
        raise SchemaError(f"{method}: {len(params)} parameters, at most {len(schemas)} allowed")
    if len(params) < required:
        raise SchemaError(f"{method}: {len(params)} parameters, {required} required")
    for i, (value, schema) in enumerate(zip(params, schemas)):
        check(value, schema, f"{method} param {i + 1}")


# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------

def _state_path() -> Path:
    return STATE_DIR / "state.json"


class State:
    """state.json, locked for the duration of one call."""

    def __enter__(self):
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        self._lock = open(STATE_DIR / ".lock", "w")
        fcntl.flock(self._lock, fcntl.LOCK_EX)
        self.data = json.loads(_state_path().read_text())
        return self.data

    def __exit__(self, *exc):
        # Keep the state on success, and on a failure that happens after
        # the server already saved something (see _commit_and_raise).
        if exc[0] is None or (exc[0] is not None and issubclass(exc[0], _CommitThenRaise)):
            _state_path().write_text(json.dumps(self.data, indent=1))
        fcntl.flock(self._lock, fcntl.LOCK_UN)
        self._lock.close()


def log_call(entry: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    with open(STATE_DIR / "calls.jsonl", "a", encoding="utf-8") as fh:
        fh.write(json.dumps(entry) + "\n")


def _filter(items: list[dict], filters: list) -> list[dict]:
    out = items
    for f in filters:
        if not (isinstance(f, list) and len(f) == 3 and f[1] == "="):
            raise CallError(f"fake middleware: unsupported filter {f!r}")
        out = [i for i in out if i.get(f[0]) == f[2]]
    return out


def _select(items: list[dict], options: dict) -> list[dict]:
    sel = options.get("select") or []
    if not sel:
        return items
    return [{k: v for k, v in i.items() if k in sel} for i in items]


# ---------------------------------------------------------------------------
# Methods
# ---------------------------------------------------------------------------

def _validate_compose(data: dict, schema_name: str) -> dict:
    """As middlewared's custom_app_utils.validate_payload."""
    keys = ("custom_compose_config", "custom_compose_config_string")
    if all(not data.get(k) for k in keys):
        raise CallError(f"[EINVAL] {schema_name}.custom_compose_config: This field is required")
    if all(data.get(k) for k in keys):
        raise CallError(f"[EINVAL] {schema_name}.custom_compose_config_string: Only one of these fields should be provided")
    if data.get("custom_compose_config_string"):
        try:
            config = yaml.load(data["custom_compose_config_string"], Loader=yaml.SafeLoader)
        except yaml.YAMLError as exc:
            raise CallError(f"[EINVAL] {schema_name}.custom_compose_config_string: Invalid YAML provided") from exc
        text = data["custom_compose_config_string"]
    else:
        config = data["custom_compose_config"]
        text = yaml.safe_dump(config)
    if not isinstance(config, dict) or "services" not in config:
        # The 25.10 RC1 message users reported (forums.truenas.com/t/55300).
        raise CallError(f"[EINVAL] {schema_name}.custom_compose_config_string: "
                        "YAML is missing required \"services\" key")
    with tempfile.NamedTemporaryFile("w", suffix=".yaml", dir=STATE_DIR, delete=True) as tmp:
        tmp.write(text)
        tmp.flush()
        cp = subprocess.run(["docker", "compose", "-f", tmp.name, "config"],
                            capture_output=True, text=True, timeout=60, check=False)
    if cp.returncode != 0:
        raise CallError(f"[EINVAL] {schema_name}: Invalid compose configuration: {cp.stderr.strip()}")
    return config


def _app_entry(app: dict) -> dict:
    return {
        "name": app["name"], "id": app["name"], "state": app["state"], "upgrade_available": False,
        "latest_version": None, "image_updates_available": False, "custom_app": app["custom_app"],
        "migrated": False, "human_version": "1.0.0", "version": "1.0.0", "metadata": {},
        "active_workloads": {"containers": 0, "used_ports": [], "used_host_ips": [],
                             "container_details": [], "volumes": [], "images": [], "networks": []},
        "notes": None, "portals": {},
    }


def _chown_tree(path: str, uid, gid, recursive: bool) -> None:
    uid = -1 if uid is None else uid
    gid = -1 if gid is None else gid
    os.chown(path, uid, gid, follow_symlinks=False)
    if recursive and os.path.isdir(path):
        for root, dirs, files in os.walk(path):
            for name in dirs + files:
                os.chown(os.path.join(root, name), uid, gid, follow_symlinks=False)


def dispatch(method: str, params: list):
    with State() as st:
        if method == "system.version":
            return st["version"]
        if method == "docker.status":
            return {"status": st["docker_status"], "description": ""}
        if method == "docker.config":
            return {"id": 1, "enable_image_updates": True, "dataset": f"{st['apps_pool']}/ix-apps",
                    "pool": st["apps_pool"], "nvidia": False, "address_pools": [],
                    "cidr_v6": "fdd0::/64", "secure_registry_mirrors": [],
                    "insecure_registry_mirrors": []}
        if method == "system.general.config":
            return {"id": 1, "timezone": st["timezone"], "ui_port": 80, "ui_httpsport": 443}
        if method == "pool.query":
            pools = [{"name": p["name"], "path": p["path"], "status": "ONLINE", "healthy": True}
                     for p in st["pools"]]
            return _select(_filter(pools, params[0] if params else []), params[1] if len(params) > 1 else {})
        if method == "pool.dataset.query":
            return _filter(list(st["datasets"].values()), params[0] if params else [])
        if method == "pool.dataset.create":
            data = params[0]
            name = data["name"]
            if name in st["datasets"]:
                raise CallError(f"[EEXIST] pool_dataset_create.name: {name} already exists")
            parent = name.rsplit("/", 1)[0]
            if parent not in st["datasets"]:
                if not data.get("create_ancestors"):
                    raise CallError(f"[ENOENT] pool_dataset_create.name: parent {parent} does not exist")
                dispatch_create_ancestors(st, parent)
            mount = st["datasets"][parent]["mountpoint"] + "/" + name.rsplit("/", 1)[1]
            if os.path.exists(mount):
                raise CallError(f"[EINVAL] pool_dataset_create.name: Path {mount} already exists")
            os.makedirs(mount)
            os.chmod(mount, 0o755)
            st["datasets"][name] = _dataset(name, mount, data.get("share_type", "GENERIC"))
            return st["datasets"][name]
        if method in ("filesystem.chown", "filesystem.setperm"):
            data = params[0]
            if not os.path.exists(data["path"]):
                raise CallError(f"[ENOENT] {data['path']} does not exist")
            opts = data.get("options", {})
            _chown_tree(data["path"], data.get("uid"), data.get("gid"), opts.get("recursive", False))
            if method == "filesystem.setperm" and data.get("mode"):
                os.chmod(data["path"], int(data["mode"], 8))
            st.setdefault("perm_calls", []).append({"method": method, **data})
            return None
        if method == "app.query":
            apps = [_app_entry(a) for a in st["apps"].values()]
            return _select(_filter(apps, params[0] if params else []), params[1] if len(params) > 1 else {})
        if method == "app.config":
            app = _get_app(st, params[0])
            return app["config"]
        if method == "app.used_ports":
            return sorted(st.get("other_app_ports", []))
        if method == "app.image.pull":
            image = params[0]["image"]
            if image in st.get("fail_pull", []):
                raise CallError(f"[EFAULT] Failed to pull {image}")
            st.setdefault("pulled", []).append(image)
            return None
        if method == "app.create":
            data = params[0]
            if st["docker_status"] != "RUNNING":
                raise CallError("[EFAULT] Docker service is not running")
            if data["app_name"] in st["apps"]:
                raise CallError(f"[EEXIST] Application with name {data['app_name']} already exists")
            if not data.get("custom_app"):
                raise CallError("fake middleware: only custom apps are supported")
            config = _validate_compose(data, "app_create")
            st["apps"][data["app_name"]] = {"name": data["app_name"], "custom_app": True,
                                            "state": "RUNNING", "config": config,
                                            "yaml": data.get("custom_compose_config_string", "")}
            return _app_entry(st["apps"][data["app_name"]])
        if method == "app.update":
            # As crud.py do_update/update_internal (25.10.8): validate, save
            # the new config, then `compose up --force-recreate` only when
            # the app is not STOPPED. st['fail_up'] makes that `up` fail
            # (the new config stays saved, the app ends up CRASHED).
            app = _get_app(st, params[0])
            config = _validate_compose(params[1] if len(params) > 1 else {}, "app_update")
            app["config"] = config
            app["yaml"] = params[1].get("custom_compose_config_string", "")
            app["updates"] = app.get("updates", 0) + 1
            if app["state"] != "STOPPED":
                if st.get("fail_up"):
                    app["state"] = "CRASHED"
                    _commit_and_raise(st, f"[EFAULT] Failed 'up' action for {params[0]!r} app. "
                                          "Please check /var/log/app_lifecycle.log for more details")
                app["state"] = "RUNNING"
            return _app_entry(app)
        if method == "app.stop":
            _get_app(st, params[0])["state"] = "STOPPED"
            return None
        if method == "app.start":
            app = _get_app(st, params[0])
            if st.get("fail_up"):
                app["state"] = "CRASHED"
                _commit_and_raise(st, f"[EFAULT] Failed 'up' action for {params[0]!r} app. "
                                      "Please check /var/log/app_lifecycle.log for more details")
            app["state"] = "RUNNING"
            return None
        if method == "app.delete":
            _get_app(st, params[0])
            del st["apps"][params[0]]
            return True
    raise CallError(f"fake middleware: {method} not implemented")


class _CommitThenRaise(CallError):
    """A failure after the server already changed its state (State keeps it)."""


def _commit_and_raise(st: dict, message: str) -> None:
    raise _CommitThenRaise(message)


def _dataset(name: str, mount: str, share_type: str) -> dict:
    return {"id": name, "name": name, "pool": name.split("/")[0], "type": "FILESYSTEM",
            "mountpoint": mount, "locked": False, "encrypted": False, "share_type": share_type}


def dispatch_create_ancestors(st: dict, name: str) -> None:
    parent = name.rsplit("/", 1)[0]
    if parent not in st["datasets"]:
        if "/" not in name:
            raise CallError(f"[ENOENT] pool {name} does not exist")
        dispatch_create_ancestors(st, parent)
    mount = st["datasets"][parent]["mountpoint"] + "/" + name.rsplit("/", 1)[1]
    os.makedirs(mount, exist_ok=True)
    st["datasets"][name] = _dataset(name, mount, "GENERIC")


def _get_app(st: dict, name):
    if not isinstance(name, str):
        raise CallError(f"app name must be a string, got {name!r}")
    if name not in st["apps"]:
        raise CallError(f"[ENOENT] App {name!r} not found")
    return st["apps"][name]


def call(method: str, params: list, *, job: bool, via: str, argv: list[str] | None = None,
         callback=None):
    """Validate, log and run one call. Raises CallError like the server."""
    entry = {"via": via, "method": method, "params": params, "job": job}
    if argv is not None:
        entry["argv"] = argv
    try:
        validate_call(method, params, job)
    except SchemaError as exc:
        entry["schema_error"] = str(exc)
        log_call(entry)
        raise
    log_call(entry)
    if job and callback:
        callback({"progress": {"percent": 50, "description": f"{method} (fake) running"}})
    return dispatch(method, params)
