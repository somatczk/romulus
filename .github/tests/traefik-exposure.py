#!/usr/bin/env python3
"""Fail if a Traefik router reaches hydra, /metrics or /health without secure-admin@file."""

import re
import sys
from pathlib import Path

import yaml

AUTH = "secure-admin@file"
SENSITIVE = re.compile(r"Path(Prefix)?\(\s*`/(metrics|health)")
ROUTER_KEY = re.compile(r"traefik\.http\.routers\.([^.]+)\.(rule|middlewares|service)")


def labels_of(svc):
    raw = svc.get("labels") or {}
    if isinstance(raw, list):
        raw = dict(item.split("=", 1) for item in raw if "=" in item)
    return {str(k): str(v) for k, v in raw.items()}


def split_mws(value, default_provider):
    items = value if isinstance(value, list) else str(value).split(",")
    out = []
    for m in (str(i).strip() for i in items):
        if m:
            out.append(m if "@" in m else f"{m}@{default_provider}")
    return out


def compose_routers(root):
    files = sorted(root.glob("stacks/*/compose.yml")) + sorted(root.glob("host/*/compose.yml"))
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
            hydra_svc = hydra_stack or str(name).startswith("hydra")
            where = f"{f.relative_to(root)}:{name}"
            if enabled and not routers:
                yield f"{where}:<default router>", "", [], hydra_svc
            for r, conf in routers.items():
                hydra = hydra_svc or conf.get("service", "").startswith("hydra")
                mws = split_mws(conf.get("middlewares", ""), "docker")
                yield f"{where}:{r}", conf.get("rule", ""), mws, hydra


def file_routers(root):
    for f in sorted(root.glob("configs/traefik/dynamic/*.yml")):
        http = (yaml.safe_load(f.read_text()) or {}).get("http") or {}
        services = http.get("services") or {}
        for r, conf in (http.get("routers") or {}).items():
            svc = str(conf.get("service", ""))
            target = str(services.get(svc, ""))
            rule = str(conf.get("rule", ""))
            hydra = svc.startswith("hydra") or "hydra" in target or "trading." in rule
            mws = split_mws(conf.get("middlewares") or [], "file")
            yield f"{f.relative_to(root)}:{r}", rule, mws, hydra


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    bad = 0
    checked = 0
    for where, rule, mws, hydra in [*compose_routers(root), *file_routers(root)]:
        checked += 1
        sensitive = bool(SENSITIVE.search(rule)) or "trading." in rule
        if (hydra or sensitive) and AUTH not in mws:
            bad += 1
            print(f"::error::{where} rule={rule!r} middlewares={mws} lacks {AUTH}")
    print(f"checked {checked} router(s), {bad} exposed")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
