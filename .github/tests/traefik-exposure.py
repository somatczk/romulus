#!/usr/bin/env python3
"""Fail if a Traefik router reaches hydra, /metrics, /health or the Traefik API without secure-admin@file
(the token-authenticated hydra-mcp router is the sole D5 exception, valid only while its secure-mcp chain
still contains crowdsec + the rate limit and its rule stays scoped to /mcp), or if the Traefik API is
served insecurely or its internal entrypoint is published."""

import argparse
import re
import sys
from pathlib import Path

import yaml

AUTH = "secure-admin@file"
# D5 (hydra-build ui2-mcp1 decisions): the hydra-mcp router authenticates non-interactive MCP clients
# with a bearer token at the app (HYDRA_MCP_TOKEN, constant-time check) behind crowdsec + rate limit;
# Authelia's interactive 2FA is deliberately absent. It is the only router allowed to skip AUTH, and
# only while the whole D5 contract holds - the middleware reference, the chain's contents and the
# rule's /mcp scope. Broadening the rule would out-prioritize the dashboard router (explicit priority 1,
# length beats it) and serve every non-/api path through the no-Authelia chain.
TOKEN_AUTH_OK = {
    "stacks/hydra/compose.yml:hydra-engine:hydra-mcp": {
        "middleware": "secure-mcp@file",
        "chain_members": ("crowdsec-bouncer", "mcp-rate-limit"),
        "rule_segment": "PathPrefix(`/mcp`)",
    }
}
SENSITIVE = re.compile(r"path(prefix)?\(\s*[`\"']/(metrics|health)", re.IGNORECASE)
ROUTER_KEY = re.compile(r"traefik\.http\.routers\.([^.]+)\.(.+)")
COMPOSE_GLOBS = ("stacks/*/compose.y*ml", "stacks/*/docker-compose.y*ml", "host/*/compose.y*ml", "host/*/docker-compose.y*ml")
DYNAMIC = "configs/traefik/dynamic"
STATIC = "configs/traefik/traefik.yml"
API_SERVICES = {"api@internal", "dashboard@internal"}
API_ENTRYPOINT = "traefik-api"
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


def load_static(root):
    f = root / STATIC
    doc = yaml.safe_load(f.read_text()) if f.is_file() else None
    return {str(k).lower(): v for k, v in (doc or {}).items()} if isinstance(doc, dict) else None


def api_port(static):
    eps = {str(k).lower(): v for k, v in ((static or {}).get("entrypoints") or {}).items()}
    conf = {str(k).lower(): v for k, v in (eps.get(API_ENTRYPOINT) or {}).items()}
    return str(conf.get("address") or ":8080").rsplit(":", 1)[-1].split("/")[0]


def container_ports(svc):
    for p in svc.get("ports") or []:
        if isinstance(p, dict):
            yield str(p.get("target", "")).split("/")[0]
        else:
            yield str(p).split("/")[0].rsplit(":", 1)[-1]


def publishes(svc, port):
    for target in container_ports(svc):
        lo, _, hi = target.partition("-")
        if target == port or (hi.isdigit() and lo.isdigit() and port.isdigit() and int(lo) <= int(port) <= int(hi)):
            return True
    return False


def is_traefik(name, svc):
    build = svc.get("build")
    build = build.get("context", "") if isinstance(build, dict) else build
    return any("traefik" in str(v).lower() for v in (name, svc.get("image") or "", build or ""))


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


def dynamic_chain(root, ref):
    """Middleware names a @file chain links, or None when it is not defined in the dynamic config."""
    name = ref.split("@", 1)[0]
    for f in sorted(p for p in (root / DYNAMIC).rglob("*") if p.suffix.lower() in (".yml", ".yaml")):
        doc = yaml.safe_load(f.read_text()) or {}
        http = {str(k).lower(): v for k, v in doc.items()}.get("http") or {}
        http = {str(k).lower(): v for k, v in http.items()}
        defined = {str(k).lower(): v for k, v in (http.get("middlewares") or {}).items()}
        if name not in defined:
            continue
        conf = defined[name] if isinstance(defined[name], dict) else {}
        chain = conf.get("chain") or {}
        return [str(m) for m in (chain.get("middlewares") or [])]
    return None


def insecure_errors(root, required):
    static = load_static(root)
    if static is not None:
        api = static.get("api")
        api = {str(k).lower(): v for k, v in api.items()} if isinstance(api, dict) else {}
        if truthy(api.get("insecure")):
            yield f"{STATIC}: api.insecure={api['insecure']!r} serves the Traefik API unauthenticated"
    elif required:
        yield f"{STATIC} missing; api.insecure unchecked"
    port = api_port(static)
    for cf, name, svc in compose_services(root):
        where = f"{cf.relative_to(root)}:{name}"
        for flag in insecure_flags(svc):
            yield f"{where}: {flag} serves the Traefik API unauthenticated"
        if is_traefik(name, svc) and str(svc.get("network_mode", "")).lower() == "host":
            yield f"{where}: network_mode=host publishes the {API_ENTRYPOINT} entrypoint (:{port})"
        elif is_traefik(name, svc) and publishes(svc, port):
            yield f"{where}: publishes the {API_ENTRYPOINT} entrypoint port {port}; it must stay internal"


def api_exempt(rule, eps, mws):
    overview = OVERVIEW_ONLY.fullmatch(rule.strip())
    return bool(overview) and not mws and bool(eps) and not PUBLIC_ENTRYPOINTS & set(eps)


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
        api = service in API_SERVICES and not api_exempt(rule, eps, mws)
        allow = TOKEN_AUTH_OK.get(where)
        required = allow["middleware"] if allow else AUTH
        if (hydra or sensitive or api) and AUTH not in mws and required not in mws:
            bad += 1
            print(f"::error::{where} rule={rule!r} entrypoints={eps} middlewares={mws} lacks {required}")
        if allow and allow["rule_segment"] not in rule:
            bad += 1
            print(f"::error::{where} rule={rule!r} no longer scoped to {allow['rule_segment']}")
        if allow and required in mws:
            members = dynamic_chain(root, required)
            if members is None:
                bad += 1
                print(f"::error::{where}: {required} is not defined in {DYNAMIC}")
            else:
                for lost in (m for m in allow["chain_members"] if m not in members):
                    bad += 1
                    print(f"::error::{where}: {required} chain lost {lost}")
    print(f"checked {checked} router(s), {bad} exposed")
    if checked < args.min_routers:
        bad += 1
        print(f"::error::checked {checked} router(s), expected at least {args.min_routers}; layout changed?")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
