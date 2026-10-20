#!/usr/bin/env bash
# Runs traefik-exposure.py on the repo (must pass) and on fixtures that each expose hydra (must fail).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$HERE/traefik-exposure.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

python3 "$CHECK" "$ROOT" --min-routers 20 || { echo "FAIL repo exposes a router or has too few"; FAILS=$((FAILS + 1)); }

expect_exposed() {
  local name=$1 dir="$TMP/$1"
  mkdir -p "$dir"
  if out=$(python3 "$CHECK" "$dir" "${@:2}" 2>&1); then
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

mkdir -p "$TMP/file-provider-yaml-ext/configs/traefik/dynamic"
cat > "$TMP/file-provider-yaml-ext/configs/traefik/dynamic/hydra.yaml" <<'YML'
http:
  routers:
    m:
      rule: "Host(`trading.example`) && Path(`/metrics`)"
      service: m
      middlewares:
        - secure
  services:
    m:
      loadBalancer:
        servers:
          - url: "http://hydra-engine:8000"
YML
expect_exposed file-provider-yaml-ext

mkdir -p "$TMP/file-provider-toml/configs/traefik/dynamic"
cat > "$TMP/file-provider-toml/configs/traefik/dynamic/hydra.toml" <<'TOML'
[http.routers.m]
  rule = "Path(`/metrics`)"
TOML
expect_exposed file-provider-toml

mkdir -p "$TMP/compose-yaml-ext/stacks/hydra"
cat > "$TMP/compose-yaml-ext/stacks/hydra/compose.yaml" <<'YML'
services:
  hydra-engine:
    labels:
      traefik.enable: "true"
      traefik.http.routers.m.rule: "Host(`trading.${DOMAIN}`) && Path(`/metrics`)"
      traefik.http.routers.m.middlewares: "secure@file"
YML
expect_exposed compose-yaml-ext

mkdir -p "$TMP/implicit-router/stacks/hydra"
cat > "$TMP/implicit-router/stacks/hydra/compose.yml" <<'YML'
services:
  hydra-engine:
    labels:
      traefik.enable: "true"
      traefik.http.routers.hydra-api.rule: "Host(`trading.${DOMAIN}`) && PathPrefix(`/api`)"
      traefik.http.routers.hydra-api.middlewares: "secure-admin@file"
      traefik.http.routers.m.entrypoints: "websecure"
YML
expect_exposed implicit-router

mkdir -p "$TMP/mixed-case-keys/stacks/other"
cat > "$TMP/mixed-case-keys/stacks/other/compose.yml" <<'YML'
services:
  shim:
    labels:
      Traefik.Enable: "true"
      Traefik.HTTP.Routers.Shim.Rule: "Host(`shim.${DOMAIN}`) && Path(\"/metrics\")"
      Traefik.HTTP.Routers.Shim.Middlewares: "secure@file"
YML
expect_exposed mixed-case-keys

expect_exposed no-routers-below-floor --min-routers 1

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all traefik exposure cases pass"
