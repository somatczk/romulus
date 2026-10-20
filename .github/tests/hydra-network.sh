#!/usr/bin/env bash
# Runs hydra-network.py on the repo (must pass) and on mutated copies of the stack config (each must fail).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$HERE/hydra-network.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

python3 "$CHECK" "$ROOT" || { echo "FAIL repo hydra network"; FAILS=$((FAILS + 1)); }

# copy the real files into $TMP/$1 and apply the python edit in $2 (vars: doco, hydra, core, nets, root)
mutate() {
  local dir="$TMP/$1"
  mkdir -p "$dir/scripts"
  cp "$ROOT/.doco-cd.yml" "$dir/"
  cp "$ROOT/scripts/install-gitops.sh" "$dir/scripts/"
  (cd "$ROOT" && find stacks host -maxdepth 2 \( -name 'compose.y*ml' -o -name 'docker-compose.y*ml' \)) | while read -r f; do
    mkdir -p "$dir/$(dirname "$f")"; cp "$ROOT/$f" "$dir/$f"
  done
  (cd "$dir" && python3 -c "
from pathlib import Path
root = Path('.')
doco, hydra, core, nets = Path('.doco-cd.yml'), Path('stacks/hydra/compose.yml'), Path('stacks/core/compose.yml'), Path('scripts/install-gitops.sh')
def sub(p, old, new):
    s = p.read_text()
    assert old in s, f'{p}: fixture anchor {old!r} not found'
    p.write_text(s.replace(old, new, 1))
$2")
}

expect_flagged() {
  mutate "$1" "$2"
  if out=$(python3 "$CHECK" "$TMP/$1" 2>&1); then
    echo "FAIL $1: check passed but should flag"; echo "$out"; FAILS=$((FAILS + 1))
  else
    echo "ok   $1 flagged: $(grep -m1 '::error::' <<< "$out")"
  fi
}

expect_ok() {
  mutate "$1" "$2"
  if out=$(python3 "$CHECK" "$TMP/$1" 2>&1); then
    echo "ok   $1 passes"
  else
    echo "FAIL $1: check flagged a safe layout"; echo "$out"; FAILS=$((FAILS + 1))
  fi
}

ENGINE_NETS='      hydra-edge:\n        ipv4_address: 10.10.13.3\n      hydra: {}\n      monitoring: {}\n'
TRAEFIK_EDGE='      hydra-edge:\n        ipv4_address: 10.10.13.2\n'

expect_flagged engine-on-proxy "sub(hydra, '$ENGINE_NETS', '${ENGINE_NETS}      proxy: {}\n')"
expect_flagged engine-on-proxy-list "sub(hydra, '$ENGINE_NETS', '      - proxy\n      - hydra-edge\n      - hydra\n')"
expect_flagged engine-off-edge "sub(hydra, '$ENGINE_NETS', '      hydra: {}\n      monitoring: {}\n')"
expect_flagged engine-no-static-ip "sub(hydra, '      hydra-edge:\n        ipv4_address: 10.10.13.3\n', '      hydra-edge: {}\n')"
expect_flagged engine-takes-traefik-ip "sub(hydra, 'ipv4_address: 10.10.13.3', 'ipv4_address: 10.10.13.2')"
expect_flagged engine-ip-is-gateway "sub(hydra, 'ipv4_address: 10.10.13.3', 'ipv4_address: 10.10.13.1')"
expect_flagged auth-mode-missing "sub(hydra, '      HYDRA_API__AUTH_MODE: proxy\n', '')"
expect_flagged auth-mode-dev "sub(hydra, 'HYDRA_API__AUTH_MODE: proxy', 'HYDRA_API__AUTH_MODE: dev')"
expect_flagged auth-mode-token "sub(hydra, 'HYDRA_API__AUTH_MODE: proxy', 'HYDRA_API__AUTH_MODE: token')"
expect_flagged auth-mode-retired-name "sub(hydra, 'HYDRA_API__AUTH_MODE: proxy', 'HYDRA_API__AUTH_MODE: proxy\n      HYDRA_AUTH_MODE: proxy')"
expect_flagged label-proxy "sub(hydra, 'traefik.docker.network: \"hydra-edge\"', 'traefik.docker.network: \"proxy\"')"
expect_flagged label-missing "sub(hydra, '      traefik.docker.network: \"hydra-edge\"\n', '')"
expect_flagged cidrs-whole-subnet "sub(hydra, 'TRUSTED_PROXY_CIDRS: 10.10.13.2/32', 'TRUSTED_PROXY_CIDRS: 10.10.13.0/24')"
expect_flagged cidrs-engine-ip "sub(hydra, 'TRUSTED_PROXY_CIDRS: 10.10.13.2/32', 'TRUSTED_PROXY_CIDRS: 10.10.13.3/32')"
expect_flagged cidrs-extra-entry "sub(hydra, 'TRUSTED_PROXY_CIDRS: 10.10.13.2/32', 'TRUSTED_PROXY_CIDRS: 10.10.13.2/32,10.10.5.0/24')"
expect_flagged cidrs-missing "sub(hydra, '      HYDRA_API__TRUSTED_PROXY_CIDRS: 10.10.13.2/32\n', '')"
expect_flagged traefik-ip-moved "sub(core, 'ipv4_address: 10.10.13.2', 'ipv4_address: 10.10.13.4')"
expect_flagged traefik-no-static-ip "sub(core, '$TRAEFIK_EDGE', '      hydra-edge: {}\n')"
expect_flagged traefik-off-edge "sub(core, '$TRAEFIK_EDGE', '')"
expect_flagged traefik-outside-subnet "sub(core, 'ipv4_address: 10.10.13.2', 'ipv4_address: 10.10.16.2'); sub(hydra, '10.10.13.2/32', '10.10.16.2/32')"
expect_flagged edge-not-external "sub(hydra, '  hydra-edge:\n    external: true\n', '  hydra-edge:\n    internal: true\n')"
expect_flagged dashboard-on-edge "sub(hydra, '    networks:\n      - proxy\n    environment:\n      TZ: \${TZ}\n      NEXT_PUBLIC_API_URL', '    networks:\n      - proxy\n      - hydra-edge\n    environment:\n      TZ: \${TZ}\n      NEXT_PUBLIC_API_URL')"
expect_flagged other-stack-aliased-edge "(root / 'stacks/rogue').mkdir(); (root / 'stacks/rogue/compose.yml').write_text('networks:\n  edge:\n    external: true\n    name: hydra-edge\nservices:\n  shim:\n    image: busybox:1.37\n    networks:\n      edge:\n        ipv4_address: 10.10.13.9\n')"
expect_flagged shares-engine-netns "(root / 'stacks/rogue').mkdir(); (root / 'stacks/rogue/compose.yml').write_text('services:\n  shim:\n    image: busybox:1.37\n    network_mode: container:hydra-engine\n')"
expect_flagged engine-renamed "sub(hydra, '  hydra-engine:\n    build: ./engine', '  hydra-api:\n    build: ./engine')"
expect_flagged traefik-renamed "sub(core, '  traefik:\n    build: ./traefik', '  edge-proxy:\n    build: ./traefik')"
expect_flagged nets-missing "sub(nets, 'hydra-edge true 10.10.13.0/24\n', '')"
expect_flagged nets-not-internal "sub(nets, 'hydra-edge true 10.10.13.0/24', 'hydra-edge false 10.10.13.0/24')"
expect_flagged token-unguarded "sub(hydra, 'HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}', 'HYDRA_API_TOKEN: \${HYDRA_API_TOKEN}')"
expect_flagged token-missing "sub(hydra, '      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n', '')"
expect_flagged token-ref-missing "sub(doco, '  HYDRA_API_TOKEN: op://romulus-deploy/hydra/HYDRA_API_TOKEN\n', '')"
expect_flagged token-ref-wrong-item "sub(doco, 'op://romulus-deploy/hydra/HYDRA_API_TOKEN', 'op://romulus-deploy/shared/HYDRA_API_TOKEN')"

expect_ok other-internal-network "(root / 'stacks/rogue').mkdir(); (root / 'stacks/rogue/compose.yml').write_text('networks:\n  edge:\n    external: true\n    name: hydra-edge-test\nservices:\n  shim:\n    image: busybox:1.37\n    networks:\n      - edge\n')"

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all hydra network cases pass"
