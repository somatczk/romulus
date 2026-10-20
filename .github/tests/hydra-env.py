#!/usr/bin/env python3
"""Fail unless the hydra stack gets HYDRA_CREDENTIAL_KEY from 1Password in the engine and the backtest worker,
carries no exchange API key env (keys live encrypted in the hydra DB), and has no dead or mis-typed hydra env."""

import json
import re
import sys
from pathlib import Path

import yaml

KEY = "HYDRA_CREDENTIAL_KEY"
KEY_REF = "op://romulus-deploy/hydra/HYDRA_CREDENTIAL_KEY"
KEY_SERVICES = ("hydra-engine", "hydra-backtest-worker")
EXCHANGE = re.compile(r"\b(BINANCE|BYBIT|KRAKEN|OKX)_[A-Z_]*", re.IGNORECASE)
DEAD = ("HYDRA_TESTNET", "HYDRA_CORS_ORIGINS")
CORS = "HYDRA_API__CORS_ORIGINS"


def env_of(svc):
    raw = svc.get("environment") or {}
    if isinstance(raw, list):
        raw = dict(item.split("=", 1) if "=" in item else (item, None) for item in raw)
    return {str(k): v for k, v in raw.items()}


def check(root):
    hydra = [d for d in yaml.safe_load_all((root / ".doco-cd.yml").read_text()) if d and d.get("name") == "hydra"]
    if len(hydra) != 1:
        yield f".doco-cd.yml: expected one hydra deployment, found {len(hydra)}"
        return
    secrets = hydra[0].get("external_secrets") or {}
    if secrets.get(KEY) != KEY_REF:
        yield f".doco-cd.yml: hydra {KEY} must be {KEY_REF}, got {secrets.get(KEY)!r}"
    for name, ref in secrets.items():
        if EXCHANGE.search(f"{name} {ref}"):
            yield f".doco-cd.yml: hydra secret {name} is an exchange key; exchange keys live encrypted in the hydra DB"

    stack = root / hydra[0]["working_dir"]
    files = [f for f in (stack / "compose.yml", stack / "compose.yaml") if f.is_file()]
    if not files:
        yield f"{stack.relative_to(root)}: no compose file"
        return
    text = files[0].read_text()
    where = files[0].relative_to(root)
    for m in sorted(set(EXCHANGE.findall(text))):
        yield f"{where}: references {m}_*; exchange keys live encrypted in the hydra DB"
    services = (yaml.safe_load(text) or {}).get("services") or {}
    for name in KEY_SERVICES:
        value = env_of(services.get(name) or {}).get(KEY)
        if not (isinstance(value, str) and re.fullmatch(r"\$\{" + KEY + r":?\?[^}]*\}", value)):
            yield f"{where}:{name}: environment {KEY} must be ${{{KEY}:?}}, got {value!r}"
    for name, svc in services.items():
        env = env_of(svc or {})
        for dead in DEAD:
            if dead in env:
                yield f"{where}:{name}: {dead} is not read by hydra"
        if CORS in env:
            try:
                ok = isinstance(json.loads(str(env[CORS]).replace("${DOMAIN}", "x")), list)
            except ValueError:
                ok = False
            if not ok:
                yield f"{where}:{name}: {CORS} must be a JSON array; hydra parses list env as JSON and fails otherwise"

    host = root / "stacks/host.env"
    for n, line in enumerate(host.read_text().splitlines(), 1):
        var = line.split("=", 1)[0].strip()
        if var in DEAD or EXCHANGE.match(var):
            yield f"stacks/host.env:{n}: {var} is dead hydra env"


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else ".")
    errors = list(check(root))
    for e in errors:
        print(f"::error::{e}")
    print(f"hydra env: {len(errors)} problem(s)")
    sys.exit(1 if errors else 0)


if __name__ == "__main__":
    main()
