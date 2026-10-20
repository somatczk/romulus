#!/usr/bin/env python3
"""Fail if a Traefik router reaches hydra, /metrics, /health or the Traefik API without secure-admin@file,
or if the Traefik API is served insecurely."""

import argparse
import re
import sys
from pathlib import Path

import yaml

AUTH = "secure-admin@file"
SENSITIVE = re.compile(r"path(prefix)?\(\s*[`\"']/(metrics|health)", re.IGNORECASE)
ROUTER_KEY = re.compile(r"traefik\.http\.routers\.([^.]+)\.(.+)")
COMPOSE_GLOBS = ("stacks/*/compose.y*ml", "stacks/*/docker-compose.y*ml", "host/*/compose.y*ml", "host/*/docker-compose.y*ml")
DYNAMIC = "configs/traefik/dynamic"
STATIC = "configs/traefik/traefik.yml"
API_SERVICE = "api@internal"
PUBLIC_ENTRYPOINTS = {"web", "websecure"}
OVERVIEW_ONLY = re.compile(r"path\(\s*([`\"'])/api/overview\1\s*\)", re.IGNORECASE)
INSECURE_ARG = re.compile(r"--api\.insecure(=(?!false\b)\S*)?$", re.IGNORECASE)


def labels_of(svc):
    raw = svc.get("labels") or {}
    if isinstance(raw, list):
        raw = dict(item.split("=", 1) for item in raw if "=" in item)
    return {str(k).strip().lower(): str(v).strip() for k, v in raw.items()}


def split_mws(value, default_provider):
    items = value if isinstance(value, list) else str(value).split(",")
    out = []
    for m in (str(i).strip() for i in items):
        if m:
            out.append(m if "@" in m else f"{m}@{default_provider}")
    return out


def truthy(value):
    return value is not None and str(value).strip().lower() not in ("false", "")


def split_list(value):
    items = value if isinstance(value, list) else str(value).split(",")
    return [str(i).strip().lower() for i in items if str(i).strip()]


def insecure_flags(svc):
    cmd = svc.get("command") or []
    args = cmd.split() if isinstance(cmd, str) else [str(a) for a in cmd]
    env = svc.get("environment") or {}
    if isinstance(env, list):
        env = dict(item.split("=", 1) if "=" in item else (item, "true") for item in env)
    found = [a for a in args if INSECURE_ARG.match(a.strip())]
    found += [f"{k}={v}" for k, v in env.items() if str(k).upper() == "TRAEFIK_API_INSECURE" and truthy(v)]
    return found


def compose_services(root):
    for f in sorted({f for g in COMPOSE_GLOBS for f in root.glob(g)}):
        doc = yaml.safe_load(f.read_text()) or {}
        for name, svc in (doc.get("services") or {}).items():
            yield f, name, svc or {}


def compose_routers(root):
    for f, name, svc in compose_services(root):
        hydra_stack = f.parent.name == "hydra"
        labels = labels_of(svc)
        enabled = labels.get("traefik.enable", "false").lower() == "true"
        routers = {}
        for key, value in labels.items():
            m = ROUTER_KEY.fullmatch(key)
            if m:
                routers.setdefault(m[1], {})[m[2]] = value
        hydra_svc = hydra_stack or str(name).lower().startswith("hydra")
        where = f"{f.relative_to(root)}:{name}"
        if enabled and not routers:
            yield f"{where}:<default router>", "", [], hydra_svc, "", []
        for r, conf in routers.items():
            service = conf.get("service", "").lower()
            hydra = hydra_svc or service.startswith("hydra")
            mws = split_mws(conf.get("middlewares", ""), "docker")
            eps = split_list(conf.get("entrypoints", ""))
            yield f"{where}:{r}", conf.get("rule", ""), mws, hydra, service, eps


def file_routers(root):
    files = sorted(f for f in (root / DYNAMIC).rglob("*") if f.suffix.lower() in (".yml", ".yaml"))
    for f in files:
        doc = yaml.safe_load(f.read_text()) or {}
        http = {str(k).lower(): v for k, v in doc.items()}.get("http") or {}
        http = {str(k).lower(): v for k, v in http.items()}
        services = http.get("services") or {}
        for r, conf in (http.get("routers") or {}).items():
            conf = {str(k).lower(): v for k, v in (conf or {}).items()}
            svc = str(conf.get("service", ""))
            target = str(services.get(svc, ""))
            rule = str(conf.get("rule", ""))
            hydra = svc.lower().startswith("hydra") or "hydra" in target.lower() or "trading." in rule.lower()
            mws = split_mws(conf.get("middlewares") or [], "file")
            eps = split_list(conf.get("entrypoints") or [])
            yield f"{f.relative_to(root)}:{r}", rule, mws, hydra, svc.lower(), eps


def insecure_errors(root, required):
    f = root / STATIC
    if f.is_file():
        api = {str(k).lower(): v for k, v in (yaml.safe_load(f.read_text()) or {}).items()}.get("api")
        api = {str(k).lower(): v for k, v in api.items()} if isinstance(api, dict) else {}
        if truthy(api.get("insecure")):
            yield f"{STATIC}: api.insecure={api['insecure']!r} serves the Traefik API unauthenticated"
    elif required:
        yield f"{STATIC} missing; api.insecure unchecked"
    for cf, name, svc in compose_services(root):
        for flag in insecure_flags(svc):
            yield f"{cf.relative_to(root)}:{name}: {flag} serves the Traefik API unauthenticated"


def api_exempt(rule, eps):
    return bool(OVERVIEW_ONLY.fullmatch(rule.strip())) and bool(eps) and not PUBLIC_ENTRYPOINTS & set(eps)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--min-routers", type=int, default=0)
    ap.add_argument("--require-static", action="store_true")
    args = ap.parse_args()
    root = Path(args.root)
    bad = 0
    checked = 0
    for f in sorted((root / DYNAMIC).rglob("*")):
        if f.suffix.lower() in (".toml", ".json"):
            bad += 1
            print(f"::error::{f.relative_to(root)}: only YAML dynamic config is checked; convert it")
    for err in insecure_errors(root, args.require_static):
        bad += 1
        print(f"::error::{err}")
    for where, rule, mws, hydra, service, eps in [*compose_routers(root), *file_routers(root)]:
        checked += 1
        sensitive = bool(SENSITIVE.search(rule)) or "trading." in rule.lower()
        api = service == API_SERVICE and not api_exempt(rule, eps)
        if (hydra or sensitive or api) and AUTH not in mws:
            bad += 1
            print(f"::error::{where} rule={rule!r} entrypoints={eps} middlewares={mws} lacks {AUTH}")
    print(f"checked {checked} router(s), {bad} exposed")
    if checked < args.min_routers:
        bad += 1
        print(f"::error::checked {checked} router(s), expected at least {args.min_routers}; layout changed?")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
