#!/usr/bin/env python3
"""Fail unless hydra-engine is reachable only through hydra-edge: an internal network shared with Traefik alone,
where both have static addresses and the engine trusts Remote-User from Traefik's /32 only."""

import ipaddress
import re
import sys
from pathlib import Path
from urllib.parse import urlsplit

import yaml

EDGE = "hydra-edge"
ENGINE = ("stacks/hydra", "hydra-engine")
TRAEFIK = ("stacks/core", "traefik")
COMPOSE_GLOBS = ("stacks/*/compose.y*ml", "stacks/*/docker-compose.y*ml", "host/*/compose.y*ml", "host/*/docker-compose.y*ml")
NETS = "scripts/install-gitops.sh"
TOKEN = "HYDRA_API_TOKEN"
TOKEN_REF = "op://romulus-deploy/hydra/HYDRA_API_TOKEN"
RETIRED = ("HYDRA_AUTH_MODE", "HYDRA_TRUSTED_PROXY_CIDRS")
ENGINE_NETS = {EDGE, "hydra", "monitoring"}
DYNAMIC = "configs/traefik/dynamic/*.y*ml"
SERVICE_TARGET = re.compile(r"traefik\.(http|tcp|udp)\.services\.[^.]+\.loadbalancer\.server\.(url|address)")


def env_of(svc):
    raw = svc.get("environment") or {}
    if isinstance(raw, list):
        raw = dict(item.split("=", 1) if "=" in item else (item, None) for item in raw)
    return {str(k): v for k, v in raw.items()}


def labels_of(svc):
    raw = svc.get("labels") or {}
    if isinstance(raw, list):
        raw = dict(item.split("=", 1) for item in raw if "=" in item)
    return {str(k).strip().lower(): str(v).strip() for k, v in raw.items()}


def service_networks(doc, svc):
    """Docker network name -> per-service config, resolving compose keys through top-level `name:`."""
    declared = doc.get("networks") or {}
    if "networks" not in svc and not svc.get("network_mode"):
        return {str((declared.get("default") or {}).get("name") or "default"): {}}
    raw = svc.get("networks") or {}
    if isinstance(raw, list):
        raw = {str(n): None for n in raw}
    out = {}
    for key, conf in raw.items():
        top = declared.get(key) or {}
        out[str(top.get("name") or key)] = conf or {}
    return out


def edge_external(doc):
    declared = doc.get("networks") or {}
    return any(str((c or {}).get("name") or k) == EDGE and (c or {}).get("external") for k, c in declared.items())


def target_host(target):
    """Host of a Traefik server url (scheme://host:port) or tcp/udp address (host:port)."""
    target = str(target).strip()
    try:
        return urlsplit(target if "://" in target else f"//{target}").hostname
    except ValueError:
        return None


def edge_targets(root, compose_docs, subnet, engine_ip):
    """Traefik file or label services aimed at an address on hydra-edge, bypassing the engine's own router."""
    found = []
    for f in sorted(root.glob(DYNAMIC)):
        doc = yaml.safe_load(f.read_text()) or {}
        for proto in ("http", "tcp", "udp"):
            for name, svc in ((doc.get(proto) or {}).get("services") or {}).items():
                for server in ((svc or {}).get("loadBalancer") or {}).get("servers") or []:
                    for key in ("url", "address"):
                        if key in (server or {}):
                            found.append((f"{f.relative_to(root)}:{proto}.services.{name}", server[key]))
    for where, doc in compose_docs:
        for name, svc in (doc.get("services") or {}).items():
            for key, value in labels_of(svc or {}).items():
                if SERVICE_TARGET.fullmatch(key):
                    found.append((f"{where}:{name}:{key}", value))
    for where, target in found:
        try:
            ip = ipaddress.ip_address(target_host(target) or "")
        except ValueError:
            continue
        if (subnet and ip in subnet) or ip == engine_ip:
            yield f"{where}: targets {target} on {EDGE}; only hydra-engine's own docker router may reach it"


def compose_files(root):
    return sorted({f for g in COMPOSE_GLOBS for f in root.glob(g)})


def edge_subnet(root):
    text = (root / NETS).read_text()
    block = re.search(r"<<'NETS'\n(.*?)\nNETS\n", text, re.S)
    for line in (block[1] if block else "").splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == EDGE:
            return parts[1], parts[2]
    return None


def static_ip(conf, subnet, who):
    raw = conf.get("ipv4_address")
    if not raw:
        return None, f"{who}: no static ipv4_address on {EDGE}; a dynamic address can take the other's"
    try:
        ip = ipaddress.ip_address(str(raw))
    except ValueError:
        return None, f"{who}: {EDGE} ipv4_address {raw!r} is not an IP address"
    if subnet and (ip not in subnet or ip in (subnet.network_address, subnet.broadcast_address, subnet.network_address + 1)):
        return ip, f"{who}: {EDGE} address {ip} is not a usable host address in {subnet}"
    return ip, None


def check(root):
    nets = edge_subnet(root)
    subnet = None
    if not nets:
        yield f"{NETS}: no '{EDGE} true <subnet>' line in NETS; a rebuilt host would lack the network"
    else:
        internal, cidr = nets
        subnet = ipaddress.ip_network(cidr)
        if internal != "true":
            yield f"{NETS}: {EDGE} must be internal (true), got {internal!r}"

    found = {}
    docs = []
    for f in compose_files(root):
        doc = yaml.safe_load(f.read_text()) or {}
        stack = str(f.parent.relative_to(root))
        where = f.relative_to(root)
        docs.append((where, doc))
        for name, svc in (doc.get("services") or {}).items():
            svc = svc or {}
            ident = (stack, str(name))
            mode = str(svc.get("network_mode") or "")
            for target in (ENGINE[1], TRAEFIK[1]):
                if mode in (f"container:{target}", f"service:{target}"):
                    yield f"{where}:{name}: network_mode {mode} shares {target}'s network namespace, so it is on {EDGE}"
            on = service_networks(doc, svc)
            if ident in (ENGINE, TRAEFIK):
                found[ident] = (where, doc, svc, on)
            elif EDGE in on:
                yield f"{where}:{name}: joins {EDGE}; only traefik and hydra-engine may"

    for ident in (ENGINE, TRAEFIK):
        if ident not in found:
            yield f"{ident[0]}: service {ident[1]} not found; layout changed?"
    if len(found) < 2:
        return

    where, doc, svc, on = found[TRAEFIK]
    traefik_ip = None
    if EDGE not in on:
        yield f"{where}:traefik: not on {EDGE}"
    else:
        traefik_ip, err = static_ip(on[EDGE], subnet, f"{where}:traefik")
        if err:
            yield err
        if not edge_external(doc):
            yield f"{where}: {EDGE} must be declared external"

    where, doc, svc, on = found[ENGINE]
    engine_ip = None
    if "proxy" in on:
        yield f"{where}:hydra-engine: on proxy; every container there could call the API"
    elif set(on) != ENGINE_NETS:
        yield f"{where}:hydra-engine: networks must be exactly {sorted(ENGINE_NETS)}, got {sorted(on)}"
    if EDGE not in on:
        yield f"{where}:hydra-engine: not on {EDGE}"
    else:
        engine_ip, err = static_ip(on[EDGE], subnet, f"{where}:hydra-engine")
        if err:
            yield err
        if engine_ip and engine_ip == traefik_ip:
            yield f"{where}:hydra-engine: {EDGE} address {engine_ip} is Traefik's"
        if not edge_external(doc):
            yield f"{where}: {EDGE} must be declared external"
    yield from edge_targets(root, docs, subnet, engine_ip)
    label = labels_of(svc).get("traefik.docker.network")
    if label != EDGE:
        yield f"{where}:hydra-engine: label traefik.docker.network must be {EDGE}, got {label!r}"

    env = env_of(svc)
    if env.get("HYDRA_API__AUTH_MODE") != "proxy":
        yield f"{where}:hydra-engine: HYDRA_API__AUTH_MODE must be proxy, got {env.get('HYDRA_API__AUTH_MODE')!r}"
    want = f"{traefik_ip}/32" if traefik_ip else "<traefik static address>/32"
    cidrs = env.get("HYDRA_API__TRUSTED_PROXY_CIDRS")
    if str(cidrs).strip() != want:
        yield f"{where}:hydra-engine: HYDRA_API__TRUSTED_PROXY_CIDRS must be exactly Traefik's {want}, got {cidrs!r}"
    for old in RETIRED:
        if old in env:
            yield f"{where}:hydra-engine: {old} is retired; the P1 engine refuses to start with it"
    token = env.get(TOKEN)
    if not (isinstance(token, str) and re.fullmatch(r"\$\{" + TOKEN + r":\?[^}]*\}", token)):
        yield f"{where}:hydra-engine: environment {TOKEN} must be ${{{TOKEN}:?}}, got {token!r}"

    hydra = [d for d in yaml.safe_load_all((root / ".doco-cd.yml").read_text()) if d and d.get("name") == "hydra"]
    ref = (hydra[0].get("external_secrets") or {}).get(TOKEN) if len(hydra) == 1 else None
    if ref != TOKEN_REF:
        yield f".doco-cd.yml: hydra {TOKEN} must be {TOKEN_REF}, got {ref!r}"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    errors = list(check(root))
    for e in errors:
        print(f"::error::{e}")
    print(f"hydra network: {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
