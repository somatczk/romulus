#!/usr/bin/env python3
"""Fail unless the hydra stack gets HYDRA_CREDENTIAL_KEY from 1Password in the engine, the backtest worker
and the trader, carries no exchange API key env (keys live encrypted in the hydra DB), has no dead hydra env,
declares the D5 split (the engine's HYDRA_TRADER__URL and the trader's minimal env)."""

import re
import sys
from pathlib import Path

import yaml

KEY = "HYDRA_CREDENTIAL_KEY"
KEY_REF = "op://romulus-deploy/hydra/HYDRA_CREDENTIAL_KEY"
KEY_SERVICES = ("hydra-engine", "hydra-backtest-worker", "hydra-trader")
EXCHANGE = re.compile(r"(?<![A-Z0-9])(?:BINANCE|BYBIT|KRAKEN|OKX)_\w*|HYDRA_EXCHANGES__\w*", re.IGNORECASE)
DEAD = ("HYDRA_TESTNET", "HYDRA_CORS_ORIGINS")
ENGINE = "hydra-engine"
TRADER = "hydra-trader"
TRADER_URL = "HYDRA_TRADER__URL"
TRADER_URL_VALUE = "http://hydra-trader:8000"
TOKEN = "HYDRA_API_TOKEN"
TRADER_ENV = ("TZ", "DATABASE_URL", "REDIS_URL", "HYDRA_CREDENTIAL_KEY", TOKEN)


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
    for m in sorted({m.upper() for m in EXCHANGE.findall(text)}):
        yield f"{where}: references {m}; exchange keys live encrypted in the hydra DB"
    services = (yaml.safe_load(text) or {}).get("services") or {}
    for name in KEY_SERVICES:
        value = env_of(services.get(name) or {}).get(KEY)
        if not (isinstance(value, str) and re.fullmatch(r"\$\{" + KEY + r":\?[^}]*\}", value)):
            yield f"{where}:{name}: environment {KEY} must be ${{{KEY}:?}}, got {value!r}"
    for name, svc in services.items():
        env = env_of(svc or {})
        for dead in DEAD:
            if dead in env:
                yield f"{where}:{name}: {dead} is not read by hydra"

    # the D5 split: the engine points at the trader, and the trader carries only the env it reads
    url = env_of(services.get(ENGINE) or {}).get(TRADER_URL)
    if url != TRADER_URL_VALUE:
        yield f"{where}:{ENGINE}: environment {TRADER_URL} must be {TRADER_URL_VALUE!r}, got {url!r}"
    trader = services.get(TRADER)
    if trader is None:
        yield f"{where}: service {TRADER} not found; layout changed?"
    else:
        env = env_of(trader)
        missing, extra = sorted(set(TRADER_ENV) - set(env)), sorted(set(env) - set(TRADER_ENV))
        if missing or extra:
            yield f"{where}:{TRADER}: environment must be exactly {sorted(TRADER_ENV)}, missing {missing}, extra {extra}"
        token = env.get(TOKEN)
        if not (isinstance(token, str) and re.fullmatch(r"\$\{" + TOKEN + r":\?[^}]*\}", token)):
            yield f"{where}:{TRADER}: environment {TOKEN} must be ${{{TOKEN}:?}}, got {token!r}"

    host = root / "stacks/host.env"
    for n, line in enumerate(host.read_text().splitlines(), 1):
        var = line.split("=", 1)[0].strip()
        if var in DEAD or EXCHANGE.search(var):
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
