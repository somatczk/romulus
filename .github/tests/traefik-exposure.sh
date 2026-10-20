#!/usr/bin/env bash
# Runs traefik-exposure.py on the repo (must pass) and on fixtures that each expose hydra (must fail).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$HERE/traefik-exposure.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

python3 "$CHECK" "$ROOT" || { echo "FAIL repo exposes a router"; FAILS=$((FAILS + 1)); }

expect_exposed() {
  local name=$1 dir="$TMP/$1"
  if out=$(python3 "$CHECK" "$dir" 2>&1); then
    echo "FAIL $name: check passed but should flag"; echo "$out"; FAILS=$((FAILS + 1))
  else
    echo "ok   $name flagged: $(grep -c '::error::' <<< "$out") router(s)"
  fi
}

mkdir -p "$TMP/old-metrics-router/stacks/hydra"
cat > "$TMP/old-metrics-router/stacks/hydra/compose.yml" <<'YML'
services:
  hydra-engine:
    labels:
      traefik.enable: "true"
      traefik.http.routers.hydra-api.rule: "Host(`trading.${DOMAIN}`) && PathPrefix(`/api`)"
      traefik.http.routers.hydra-api.middlewares: "secure-admin@file"
      traefik.http.routers.hydra-metrics.rule: "Host(`trading.${DOMAIN}`) && (Path(`/health`) || Path(`/metrics`))"
      traefik.http.routers.hydra-metrics.middlewares: "secure@file"
YML
expect_exposed old-metrics-router

mkdir -p "$TMP/list-labels-catchall/stacks/other"
cat > "$TMP/list-labels-catchall/stacks/other/compose.yml" <<'YML'
services:
  proxy-shim:
    labels:
      - traefik.enable=true
      - traefik.http.routers.shim.rule=Host(`shim.${DOMAIN}`)
      - traefik.http.routers.shim.middlewares=secure@file
      - traefik.http.routers.shim.service=hydra-api
YML
expect_exposed list-labels-catchall

mkdir -p "$TMP/default-router/stacks/hydra"
cat > "$TMP/default-router/stacks/hydra/compose.yml" <<'YML'
services:
  hydra-engine:
    labels:
      traefik.enable: "true"
YML
expect_exposed default-router

mkdir -p "$TMP/file-provider/configs/traefik/dynamic"
cat > "$TMP/file-provider/configs/traefik/dynamic/hydra.yml" <<'YML'
http:
  routers:
    probe:
      rule: "Host(`probe.example`) && Path(`/metrics`)"
      service: probe
      middlewares:
        - secure
  services:
    probe:
      loadBalancer:
        servers:
          - url: "http://hydra-engine:8000"
YML
expect_exposed file-provider

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all traefik exposure cases pass"
