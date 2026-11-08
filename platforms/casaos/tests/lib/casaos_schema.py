"""Checks that a rendered CasaOS app (docker-compose YAML with x-casaos) is
what CasaOS / ZimaOS accept and the dashboard can show.

Part of platforms/casaos/tests. License: MIT (see LICENSE in the repository
root). The rules are taken from IceWhaleTech's own sources (read, not
copied):

  * CasaOS-AppStore docs/specs/compose-and-x-casaos.md (x-casaos fields,
    required ones, the category list, port_map as a quoted string) and
    .github/actions/validate-compose/scripts/validate_compose.py (the
    top-level name and x-casaos.id patterns below are the same regexes);
  * CasaOS-AppManagement api/app_management/openapi.yaml (ComposeAppStoreInfo,
    EnvStoreInfo, PortStoreInfo, VolumeStoreInfo);
  * compose-go v1 (CasaOS-AppManagement's Compose loader), which rejects
    store apps whose ports[].target is not an integer or whose devices /
    cap_add are not lists (seen in a real CasaOS 0.4.15 log).

Plus the things CasaOS cannot keep: a '$' anywhere (it runs Compose variable
substitution twice) and relative bind paths (it loads the YAML in a
temporary folder).
"""
from __future__ import annotations

import re

import yaml

NAME_RE = re.compile(r"^[a-z0-9_-]+$")
ID_RE = re.compile(r"^[a-z0-9]+(?:[._-][a-z0-9]+)*(?:\.[a-z0-9]+(?:[._-][a-z0-9]+)*)+$")
CATEGORIES = {"Media", "Productivity", "Home", "Networking", "AI", "Finance",
              "Social", "Developer", "Others"}
ARCHES = {"amd64", "arm64", "arm", "arm-7", "riscv64"}
SEMVER_RE = re.compile(r"^\d+\.\d+\.\d+([-+][0-9A-Za-z.-]+)?$")
RESTART = {"no", "always", "on-failure", "unless-stopped"}


def _en(obj, where, errors, required=True):
    if obj is None:
        if required:
            errors.append(f"{where}: missing")
        return
    if not isinstance(obj, dict) or not isinstance(obj.get("en_US"), str) or not obj["en_US"].strip():
        errors.append(f"{where}: must be a locale map with a non-empty en_US string")


def _walk_strings(obj, path="$"):
    if isinstance(obj, dict):
        for k, v in obj.items():
            yield from _walk_strings(v, f"{path}.{k}")
    elif isinstance(obj, list):
        for i, v in enumerate(obj):
            yield from _walk_strings(v, f"{path}[{i}]")
    elif isinstance(obj, str):
        yield path, obj


def check_service(name, svc, services, errors):
    w = f"services.{name}"
    if not isinstance(svc, dict):
        errors.append(f"{w}: must be a mapping")
        return
    if not isinstance(svc.get("image"), str) or not svc["image"]:
        errors.append(f"{w}.image: missing")
    if svc.get("restart") not in RESTART:
        errors.append(f"{w}.restart: {svc.get('restart')!r} is not a restart policy")
    nm = svc.get("network_mode")
    if nm is not None:
        if not isinstance(nm, str):
            errors.append(f"{w}.network_mode: must be a string")
        elif nm.startswith("service:"):
            if nm[len("service:"):] not in services:
                errors.append(f"{w}.network_mode: {nm} names no service")
            if svc.get("ports"):
                errors.append(f"{w}: ports cannot be published with network_mode {nm}")
    for i, p in enumerate(svc.get("ports") or []):
        pw = f"{w}.ports[{i}]"
        if not isinstance(p, dict):
            errors.append(f"{pw}: use the long form (target/published/protocol)")
            continue
        if not isinstance(p.get("target"), int) or isinstance(p.get("target"), bool):
            errors.append(f"{pw}.target: must be an integer")
        if not isinstance(p.get("published"), str) or not p["published"].isdigit():
            errors.append(f"{pw}.published: must be a quoted number")
        if p.get("protocol") not in ("tcp", "udp"):
            errors.append(f"{pw}.protocol: must be tcp or udp")
    for key in ("devices", "cap_add"):
        val = svc.get(key)
        if val is not None and (not isinstance(val, list) or not all(isinstance(x, str) for x in val)):
            errors.append(f"{w}.{key}: must be a list of strings")
    for i, d in enumerate(svc.get("devices") or []):
        if isinstance(d, str) and (":" not in d or not d.startswith("/")):
            errors.append(f"{w}.devices[{i}]: {d!r} is not HOST:CONTAINER")
    for i, vol in enumerate(svc.get("volumes") or []):
        vw = f"{w}.volumes[{i}]"
        if not isinstance(vol, dict):
            errors.append(f"{vw}: use the long form (type/source/target)")
            continue
        if vol.get("type") != "bind":
            errors.append(f"{vw}.type: only bind mounts are expected here")
        for k in ("source", "target"):
            if not isinstance(vol.get(k), str) or not vol[k].startswith("/"):
                errors.append(f"{vw}.{k}: must be an absolute path (CasaOS loads the YAML in a temp folder)")
    env = svc.get("environment")
    if env is not None:
        if not isinstance(env, dict):
            errors.append(f"{w}.environment: must be a mapping")
        else:
            for k, v in env.items():
                if not isinstance(v, str):
                    errors.append(f"{w}.environment.{k}: must be a string, got {type(v).__name__}")
    labels = svc.get("labels")
    if labels is not None and (not isinstance(labels, dict) or not all(isinstance(v, str) for v in labels.values())):
        errors.append(f"{w}.labels: must be a mapping of strings")
    for dep, spec in (svc.get("depends_on") or {}).items():
        if dep not in services:
            errors.append(f"{w}.depends_on: {dep} is not a service")
        elif isinstance(spec, dict) and spec.get("condition") == "service_healthy" and \
                not (services[dep] or {}).get("healthcheck"):
            errors.append(f"{w}.depends_on.{dep}: service_healthy but {dep} has no healthcheck")
    hc = svc.get("healthcheck")
    if hc is not None and (not isinstance(hc.get("test"), list) or hc["test"][:1] not in (["CMD"], ["CMD-SHELL"])):
        errors.append(f"{w}.healthcheck.test: must be a CMD list")
    x = svc.get("x-casaos")
    if x is not None:
        for kind in ("envs", "ports", "volumes"):
            for i, item in enumerate(x.get(kind) or []):
                iw = f"{w}.x-casaos.{kind}[{i}]"
                if not isinstance(item, dict) or not isinstance(item.get("container"), str):
                    errors.append(f"{iw}.container: must be a string")
                    continue
                _en(item.get("description"), f"{iw}.description", errors)
        envs = {e.get("container") for e in (x.get("envs") or []) if isinstance(e, dict)}
        for e in envs - set((env or {}).keys()):
            errors.append(f"{w}.x-casaos.envs: {e} is not in environment")
        vols = {e.get("container") for e in (x.get("volumes") or []) if isinstance(e, dict)}
        targets = {v.get("target") for v in (svc.get("volumes") or []) if isinstance(v, dict)}
        for e in vols - targets:
            errors.append(f"{w}.x-casaos.volumes: {e} is not a volume target")


def check_doc(doc) -> list[str]:
    errors: list[str] = []
    if not isinstance(doc, dict):
        return ["document: must be a mapping"]
    name = doc.get("name")
    if not isinstance(name, str) or not NAME_RE.fullmatch(name):
        errors.append(f"name: {name!r} must match {NAME_RE.pattern}")
    services = doc.get("services")
    if not isinstance(services, dict) or not services:
        return errors + ["services: missing"]
    for sname, svc in services.items():
        check_service(sname, svc, services, errors)
    for path, s in _walk_strings(doc):
        if "$" in s:
            errors.append(f"{path}: contains '$' (CasaOS substitutes variables twice)")
    x = doc.get("x-casaos")
    if not isinstance(x, dict):
        return errors + ["x-casaos: missing top-level block"]
    app_id = str(x.get("id") or "").strip().lower()
    if not ID_RE.fullmatch(app_id):
        errors.append(f"x-casaos.id: {x.get('id')!r} is not reverse-domain")
    if x.get("main") not in services:
        errors.append(f"x-casaos.main: {x.get('main')!r} is not a service")
    if not isinstance(x.get("index"), str) or not x["index"].startswith("/"):
        errors.append("x-casaos.index: must be a path starting with /")
    pm = x.get("port_map")
    published = {p.get("published") for s in services.values() for p in (s.get("ports") or [])
                 if isinstance(p, dict)}
    if not isinstance(pm, str) or not pm.isdigit():
        errors.append(f"x-casaos.port_map: {pm!r} must be a quoted port number")
    elif pm not in published:
        errors.append(f"x-casaos.port_map: {pm} is not a published port")
    if x.get("scheme", "http") not in ("http", "https"):
        errors.append("x-casaos.scheme: must be http or https")
    icon = x.get("icon")
    if not isinstance(icon, str) or not re.match(r"^(https?://|data:image/)", icon):
        errors.append("x-casaos.icon: must be an http(s) URL or a data:image URI")
    _en(x.get("title"), "x-casaos.title", errors)
    _en(x.get("tagline"), "x-casaos.tagline", errors)
    _en(x.get("description"), "x-casaos.description", errors)
    tips = x.get("tips")
    if tips is not None:
        if not isinstance(tips, dict):
            errors.append("x-casaos.tips: must be a mapping")
        else:
            for k, v in tips.items():
                _en(v, f"x-casaos.tips.{k}", errors)
    if x.get("category") not in CATEGORIES:
        errors.append(f"x-casaos.category: {x.get('category')!r} is not one of {sorted(CATEGORIES)}")
    arch = x.get("architectures")
    if not isinstance(arch, list) or not arch or not set(arch) <= ARCHES:
        errors.append(f"x-casaos.architectures: {arch!r}")
    if not isinstance(x.get("version"), str) or not SEMVER_RE.fullmatch(x["version"]):
        errors.append(f"x-casaos.version: {x.get('version')!r} must be a quoted semver string")
    for k in ("author", "developer"):
        if not isinstance(x.get(k), str) or not x[k].strip():
            errors.append(f"x-casaos.{k}: missing")
    return errors


def check_text(text: str) -> list[str]:
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError as exc:
        return [f"YAML: {exc}"]
    return check_doc(doc)


if __name__ == "__main__":
    import sys

    errs = check_text(open(sys.argv[1], encoding="utf-8").read())
    for e in errs:
        print(e)
    sys.exit(1 if errs else 0)
