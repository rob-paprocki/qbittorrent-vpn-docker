"""Validate Proxmox VE command-line parameters against the published API schema.

Purpose: test helper for platforms/proxmox/install.sh. The `pct` shim and
validate-pct-calls.py use it to check every `pct create`/`pct set` call the
installer makes, the way Proxmox VE itself would: the parameter list, types,
ranges, enums and patterns come from the official API schema (apidoc.js,
published at https://pve.proxmox.com/pve-docs/api-viewer/apidoc.js and
downloaded by run-tests.sh), and the named formats ("dns-name",
"pve-ipv4-config", ...) are re-implemented here after pve-common's
src/PVE/JSONSchema.pm and pve-container's src/PVE/LXC/Config.pm.

License: MIT (see LICENSE in the repository root). Written for this
repository; no Proxmox code is copied.
"""
from __future__ import annotations

import ipaddress
import json
import re
from pathlib import Path


class PveError(Exception):
    """A parameter Proxmox VE would reject (message as close to PVE's as practical)."""


# ---------------------------------------------------------------------------
# Schema loading
# ---------------------------------------------------------------------------

def load_api_schema(apidoc_js: str | Path) -> list:
    text = Path(apidoc_js).read_text(encoding="utf-8")
    start = text.index("[")
    data, _ = json.JSONDecoder().raw_decode(text[start:])
    return data


def find_method(schema: list, path: str, method: str) -> dict:
    stack = list(schema)
    while stack:
        node = stack.pop()
        if node.get("path") == path:
            return node["info"][method]
        stack.extend(node.get("children") or [])
    raise KeyError(f"{method} {path} not in schema")


def method_properties(apidoc_js: str | Path, path: str, method: str) -> dict:
    return find_method(load_api_schema(apidoc_js), path, method)["parameters"]["properties"]


def resolve_prop(props: dict, name: str) -> dict | None:
    """Return the schema of `name`, expanding indexed keys (net[n] -> net0)."""
    if name in props:
        return props[name]
    m = re.fullmatch(r"([a-z_]+)(\d+)", name)
    if m and f"{m.group(1)}[n]" in props:
        return props[f"{m.group(1)}[n]"]
    return None


# ---------------------------------------------------------------------------
# Named formats (after PVE::JSONSchema / PVE::LXC::Config)
# ---------------------------------------------------------------------------
ZONE_TAB = Path("/usr/share/zoneinfo/zone.tab")


def _ipv4(v: str) -> bool:
    if not re.fullmatch(r"\d{1,3}(\.\d{1,3}){3}", v):
        return False
    return all(int(o) <= 255 for o in v.split("."))


def _ipv6(v: str) -> bool:
    try:
        ipaddress.IPv6Address(v)
        return True
    except ValueError:
        return False


def _cidr4(v: str) -> bool:
    m = re.fullmatch(r"(.+)/(\d+)", v)
    return bool(m and _ipv4(m.group(1)) and 7 < int(m.group(2)) <= 32)


def _cidr6(v: str) -> bool:
    m = re.fullmatch(r"(.+)/(\d+)", v)
    return bool(m and _ipv6(m.group(1)) and 7 < int(m.group(2)) <= 128)


def _dns_name(v: str) -> bool:
    label = r"[a-zA-Z0-9]([a-zA-Z0-9\-]*[a-zA-Z0-9])?"
    return bool(re.fullmatch(rf"({label}\.)*{label}", v))


def _storage_id(v: str) -> bool:
    return len(v) >= 2 and bool(re.fullmatch(r"[a-z][a-z0-9\-_.]*[a-z0-9]", v, re.I))


def _timezone(v: str) -> bool:
    if v in ("host", "UTC"):
        return True
    for line in ZONE_TAB.read_text(encoding="utf-8").splitlines():
        if line.startswith("#"):
            continue
        cols = line.split("\t")
        if len(cols) > 2 and cols[2] == v:
            return True
    return False


def _mp_string(v: str) -> bool:
    return not (re.search(r"/\.\.?/", v) or re.search(r"/\.\.?$", v) or v.startswith("../"))


def _dev_string(v: str) -> bool:
    return v.startswith("/dev/") and not re.search(r"/\.\.?(/|$)", v)


def _disk_size(v: str) -> bool:
    return bool(re.fullmatch(r"\d+(\.\d+)?([KMGT](iB)?)?", v))


def _ip_ll(v: str) -> bool:
    m = re.fullmatch(r"(fe80:[^%]+)%(.*)", v)
    if m:
        return _ipv6(m.group(1))
    return _ipv4(v) or _ipv6(v)


def _split_list(v: str) -> list[str]:
    # PVE::Tools::split_list: separators are whitespace, ',' ';' and NUL
    return [p for p in re.split(r"[\s,;\0]+", v) if p]


FORMATS = {
    "pve-vmid": lambda v: bool(re.fullmatch(r"[1-9][0-9]{2,8}", v)),
    "pve-storage-id": _storage_id,
    "pve-poolid": lambda v: bool(re.fullmatch(r"[A-Za-z0-9_\-/]+", v)),
    "pve-node": _dns_name,
    "dns-name": _dns_name,
    "ipv4": _ipv4,
    "ipv6": _ipv6,
    "pve-ipv4-config": lambda v: v in ("dhcp", "manual") or _cidr4(v),
    "pve-ipv6-config": lambda v: v in ("auto", "dhcp", "manual") or _cidr6(v),
    "mac-addr": lambda v: bool(re.fullmatch(r"[a-f0-9][02468ace](:[a-f0-9]{2}){5}", v, re.I)),
    "disk-size": _disk_size,
    "pve-tag": lambda v: bool(re.fullmatch(r"[a-z0-9_][a-z0-9_\-+.]*", v, re.I)),
    "pve-ct-timezone": _timezone,
    "pve-lxc-mp-string": _mp_string,
    "pve-lxc-dev-string": _dev_string,
    "lxc-ip-with-ll-iface": _ip_ll,
    "pve-startup-order": lambda v: all(
        re.fullmatch(r"(order=)?\d+|up=\d+|down=\d+", p) for p in v.split(",") if p.strip()),
    "pve-volume-id": lambda v: bool(re.fullmatch(r"[a-z][a-z0-9\-_.]*[a-z0-9]:.+", v, re.I)),
}


def parse_boolean(v: str):
    if re.fullmatch(r"1|on|yes|true", v, re.I):
        return 1
    if re.fullmatch(r"0|off|no|false", v, re.I):
        return 0
    return None


def _perl_re(pattern: str) -> str:
    # Perl's (?^:...) flag group means "default flags"; Python has no ^ flag.
    return pattern.replace("(?^:", "(?:")


# ---------------------------------------------------------------------------
# Value checks
# ---------------------------------------------------------------------------

def check_named_format(fmt: str, value: str, where: str) -> None:
    base, kind = fmt, None
    m = re.fullmatch(r"(.*?)-(list|opt)", fmt)
    if m and m.group(1) in FORMATS:
        base, kind = m.group(1), m.group(2)
    if base not in FORMATS:
        raise PveError(f"{where}: test validator does not know format '{fmt}'")
    if kind == "list":
        values = _split_list(value)
    elif kind == "opt":
        values = [value] if value else []
    else:
        values = [value]
    for v in values:
        if not FORMATS[base](v):
            raise PveError(f"{where}: value '{v}' does not match format '{base}'")


def check_value(schema: dict, value: str, where: str) -> None:
    typ = schema.get("type", "string")
    if typ == "boolean":
        if parse_boolean(value) is None:
            raise PveError(f"{where}: type check ('boolean') failed - got '{value}'")
        return
    if typ in ("integer", "number"):
        pat = r"[+-]?\d+" if typ == "integer" else r"[+-]?(\d+\.\d+|\d+\.|\.\d+|\d+)([eE][+-]?\d+)?"
        if not re.fullmatch(pat, value):
            raise PveError(f"{where}: type check ('{typ}') failed - got '{value}'")
        num = float(value)
        if "minimum" in schema and num < float(schema["minimum"]):
            raise PveError(f"{where}: value must have a minimum value of {schema['minimum']}")
        if "maximum" in schema and num > float(schema["maximum"]):
            raise PveError(f"{where}: value may only be {schema['maximum']}")
        return
    # string
    if "enum" in schema and value not in schema["enum"]:
        raise PveError(f"{where}: value '{value}' does not have a value in the enumeration "
                       f"'{', '.join(schema['enum'])}'")
    if "maxLength" in schema and len(value) > int(schema["maxLength"]):
        raise PveError(f"{where}: value may only be {schema['maxLength']} characters long")
    if "minLength" in schema and len(value) < int(schema["minLength"]):
        raise PveError(f"{where}: value must be at least {schema['minLength']} characters long")
    if "pattern" in schema and not re.fullmatch(_perl_re(schema["pattern"]), value):
        raise PveError(f"{where}: value does not match the regex pattern")
    fmt = schema.get("format")
    if isinstance(fmt, dict):
        parse_property_string(fmt, value, where)
    elif isinstance(fmt, str):
        check_named_format(fmt, value, where)


def parse_property_string(fmt: dict, data: str, where: str) -> dict:
    """Mirror of PVE::JSONSchema::parse_property_string + check_object."""
    res: dict[str, str] = {}
    default_key = next((k for k, s in fmt.items() if s.get("default_key")), None)
    used_default = False
    for part in data.split(","):
        if not part.strip():
            continue
        if "\n" in part:
            raise PveError(f"{where}: properties must not contain newlines")
        m = re.fullmatch(r"([^=]+)=(.+)", part, re.S)
        if m:
            k, v = m.group(1), m.group(2)
            if k in res:
                raise PveError(f"{where}: duplicate key in comma-separated list property: {k}")
            if k not in fmt:
                raise PveError(f"{where}: invalid format - invalid key in comma-separated list property: {k}")
            res[k] = v
        elif "=" not in part:
            if default_key is None:
                raise PveError(f"{where}: value without key, but schema does not define a default key")
            if used_default or default_key in res:
                raise PveError(f"{where}: duplicate key in comma-separated list property: {default_key}")
            res[default_key] = part
            used_default = True
        else:
            raise PveError(f"{where}: missing key in comma-separated list property")
    for k, s in fmt.items():
        if not s.get("optional") and k not in res:
            raise PveError(f"{where}: invalid format - {k}: property is missing and it is not optional")
    for k, v in res.items():
        check_value(fmt[k], v, f"{where}.{k}")
    return res


# ---------------------------------------------------------------------------
# CLI parsing (after PVE::JSONSchema::get_options: Getopt::Long with
# prefix "--" or "-", booleans take an optional value, "-list" formats may
# repeat)
# ---------------------------------------------------------------------------

def parse_cli(argv: list[str], props: dict, arg_params: list[str]) -> dict:
    opts: dict[str, str] = {}
    positional: list[str] = []
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--":
            positional.extend(argv[i + 1:])
            break
        if re.match(r"--?[a-z]", a):
            name, _, inline = a.lstrip("-").partition("=")
            schema = resolve_prop(props, name)
            if schema is None or name in arg_params:
                raise PveError(f"Unknown option: {name}\n400 unable to parse option")
            if schema.get("type") == "boolean":
                if "=" in a:
                    value = inline
                elif i + 1 < len(argv) and not argv[i + 1].startswith("-"):
                    value = argv[i + 1]
                    i += 1
                else:
                    value = "1"
                value = value or "1"
            else:
                if "=" in a:
                    value = inline
                elif i + 1 < len(argv):
                    value = argv[i + 1]
                    i += 1
                else:
                    raise PveError(f"Option {name} requires an argument\n400 unable to parse option")
            fmt = schema.get("format")
            if name in opts and isinstance(fmt, str) and "-list" in fmt:
                opts[name] += "," + value
            elif name in opts:
                raise PveError(f"duplicate option: {name}")
            else:
                opts[name] = value
        else:
            positional.append(a)
        i += 1
    if len(positional) < len(arg_params):
        raise PveError("400 not enough arguments")
    if len(positional) > len(arg_params):
        raise PveError("400 too many arguments")
    for k, v in zip(arg_params, positional):
        opts[k] = v
    return opts


def validate_params(opts: dict, props: dict) -> None:
    errors = []
    for name, value in opts.items():
        schema = resolve_prop(props, name)
        if schema is None:
            errors.append(f"{name}: property is not defined in schema and the schema does not allow additional properties")
            continue
        try:
            check_value(schema, str(value), name)
        except PveError as e:
            errors.append(str(e))
    for name, schema in props.items():
        if not schema.get("optional") and "[n]" not in name and name != "node" and name not in opts:
            errors.append(f"{name}: property is missing and it is not optional")
    if errors:
        raise PveError("400 Parameter verification failed.\n" + "\n".join(errors))
