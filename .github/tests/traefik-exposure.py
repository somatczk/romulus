#!/usr/bin/env python3
"""Fail if a Traefik router reaches hydra, /metrics or /health without secure-admin@file."""

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


def compose_routers(root):
    files = sorted({f for g in COMPOSE_GLOBS for f in root.glob(g)})
    for f in files:
        doc = yaml.safe_load(f.read_text()) or {}
        hydra_stack = f.parent.name == "hydra"
        for name, svc in (doc.get("services") or {}).items():
            labels = labels_of(svc or {})
            enabled = labels.get("traefik.enable", "false").lower() == "true"
            routers = {}
            for key, value in labels.items():
                m = ROUTER_KEY.fullmatch(key)
                if m:
                    routers.setdefault(m[1], {})[m[2]] = value
            hydra_svc = hydra_stack or str(name).lower().startswith("hydra")
            where = f"{f.relative_to(root)}:{name}"
            if enabled and not routers:
                yield f"{where}:<default router>", "", [], hydra_svc
            for r, conf in routers.items():
                hydra = hydra_svc or conf.get("service", "").lower().startswith("hydra")
                mws = split_mws(conf.get("middlewares", ""), "docker")
                yield f"{where}:{r}", conf.get("rule", ""), mws, hydra


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
            yield f"{f.relative_to(root)}:{r}", rule, mws, hydra


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("root", nargs="?", default=".")
    ap.add_argument("--min-routers", type=int, default=0)
    args = ap.parse_args()
    root = Path(args.root)
    bad = 0
    checked = 0
    for f in sorted((root / DYNAMIC).rglob("*")):
        if f.suffix.lower() in (".toml", ".json"):
            bad += 1
            print(f"::error::{f.relative_to(root)}: only YAML dynamic config is checked; convert it")
    for where, rule, mws, hydra in [*compose_routers(root), *file_routers(root)]:
        checked += 1
        sensitive = bool(SENSITIVE.search(rule)) or "trading." in rule.lower()
        if (hydra or sensitive) and AUTH not in mws:
            bad += 1
            print(f"::error::{where} rule={rule!r} middlewares={mws} lacks {AUTH}")
    print(f"checked {checked} router(s), {bad} exposed")
    if checked < args.min_routers:
        bad += 1
        print(f"::error::checked {checked} router(s), expected at least {args.min_routers}; layout changed?")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
