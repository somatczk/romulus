#!/usr/bin/env bash
# Runs traefik-exposure.py on the repo (must pass) and on fixtures that each expose hydra or the Traefik API (must fail).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$HERE/traefik-exposure.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

python3 "$CHECK" "$ROOT" --min-routers 20 --require-static || { echo "FAIL repo exposes a router or has too few"; FAILS=$((FAILS + 1)); }

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

mkdir -p "$TMP/api-insecure/configs/traefik"
cat > "$TMP/api-insecure/configs/traefik/traefik.yml" <<'YML'
api:
  dashboard: true
  insecure: true
YML
expect_exposed api-insecure

mkdir -p "$TMP/api-insecure-string/configs/traefik"
cat > "$TMP/api-insecure-string/configs/traefik/traefik.yml" <<'YML'
API:
  Insecure: "TRUE"
YML
expect_exposed api-insecure-string

mkdir -p "$TMP/api-insecure-cli/stacks/core"
cat > "$TMP/api-insecure-cli/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    command: ["--api.insecure=true"]
YML
expect_exposed api-insecure-cli

mkdir -p "$TMP/api-insecure-env/stacks/core"
cat > "$TMP/api-insecure-env/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    environment:
      - TRAEFIK_API_INSECURE=true
YML
expect_exposed api-insecure-env

expect_exposed static-missing --require-static

mkdir -p "$TMP/dashboard-no-authelia/stacks/core"
cat > "$TMP/dashboard-no-authelia/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    labels:
      traefik.enable: "true"
      traefik.http.routers.traefik.rule: "Host(`traefik.${DOMAIN}`)"
      traefik.http.routers.traefik.entrypoints: "websecure"
      traefik.http.routers.traefik.service: "api@internal"
      traefik.http.routers.traefik.middlewares: "traefik-dashboard-redirect@file,secure@file"
YML
expect_exposed dashboard-no-authelia

mkdir -p "$TMP/dashboard-file-provider/configs/traefik/dynamic"
cat > "$TMP/dashboard-file-provider/configs/traefik/dynamic/api.yml" <<'YML'
http:
  routers:
    dash:
      rule: "Host(`traefik.example`)"
      entrypoints:
        - websecure
      service: api@internal
      middlewares:
        - secure
YML
expect_exposed dashboard-file-provider

mkdir -p "$TMP/overview-public/stacks/core"
cat > "$TMP/overview-public/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    labels:
      traefik.enable: "true"
      traefik.http.routers.o.rule: "Path(`/api/overview`)"
      traefik.http.routers.o.entrypoints: "traefik-api,websecure"
      traefik.http.routers.o.service: "api@internal"
YML
expect_exposed overview-public

mkdir -p "$TMP/overview-default-entrypoints/stacks/core"
cat > "$TMP/overview-default-entrypoints/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    labels:
      traefik.enable: "true"
      traefik.http.routers.o.rule: "Path(`/api/overview`)"
      traefik.http.routers.o.service: "api@internal"
YML
expect_exposed overview-default-entrypoints

mkdir -p "$TMP/api-prefix-internal/stacks/core"
cat > "$TMP/api-prefix-internal/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    labels:
      traefik.enable: "true"
      traefik.http.routers.o.rule: "PathPrefix(`/api`)"
      traefik.http.routers.o.entrypoints: "traefik-api"
      traefik.http.routers.o.service: "api@internal"
YML
expect_exposed api-prefix-internal

mkdir -p "$TMP/overview-or-rawdata/stacks/core"
cat > "$TMP/overview-or-rawdata/stacks/core/compose.yml" <<'YML'
services:
  traefik:
    labels:
      traefik.enable: "true"
      traefik.http.routers.o.rule: "Path(`/api/overview`) || Path(`/api/rawdata`)"
      traefik.http.routers.o.entrypoints: "traefik-api"
      traefik.http.routers.o.service: "api@internal"
YML
expect_exposed overview-or-rawdata

expect_exposed no-routers-below-floor --min-routers 1

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all traefik exposure cases pass"
