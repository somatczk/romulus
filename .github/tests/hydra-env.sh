#!/usr/bin/env bash
# Runs hydra-env.py on the repo (must pass) and on mutated copies of the hydra stack config (each must fail).
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/../.." && pwd)
CHECK="$HERE/hydra-env.py"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

python3 "$CHECK" "$ROOT" || { echo "FAIL repo hydra env"; FAILS=$((FAILS + 1)); }

# copy the real files into $TMP/$1, apply the python edit in $2 (vars: doco, compose, host), expect a failure
expect_flagged() {
  local name=$1 dir="$TMP/$1"
  mkdir -p "$dir/stacks/hydra"
  cp "$ROOT/.doco-cd.yml" "$dir/"
  cp "$ROOT/stacks/host.env" "$dir/stacks/"
  cp "$ROOT/stacks/hydra/compose.yml" "$dir/stacks/hydra/"
  (cd "$dir" && python3 -c "
from pathlib import Path
doco, compose, host = Path('.doco-cd.yml'), Path('stacks/hydra/compose.yml'), Path('stacks/host.env')
def sub(p, old, new):
    s = p.read_text()
    assert old in s, f'{p}: fixture anchor {old!r} not found'
    p.write_text(s.replace(old, new, 1))
$2")
  if out=$(python3 "$CHECK" "$dir" 2>&1); then
    echo "FAIL $name: check passed but should flag"; echo "$out"; FAILS=$((FAILS + 1))
  else
    echo "ok   $name flagged: $(grep -m1 '::error::' <<< "$out")"
  fi
}

expect_flagged key-ref-missing "sub(doco, '  HYDRA_CREDENTIAL_KEY: op://romulus-deploy/hydra/HYDRA_CREDENTIAL_KEY\n', '')"
expect_flagged key-ref-wrong-item "sub(doco, 'op://romulus-deploy/hydra/HYDRA_CREDENTIAL_KEY', 'op://romulus-deploy/shared/HYDRA_CREDENTIAL_KEY')"
expect_flagged worker-key-missing "sub(compose, '      HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}\n    volumes:', '    volumes:')"
expect_flagged engine-key-unguarded "sub(compose, 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}', 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY}')"
expect_flagged exchange-secret "sub(doco, 'external_secrets:\n  HYDRA_CREDENTIAL_KEY', 'external_secrets:\n  BINANCE_API_KEY: op://romulus-deploy/hydra/BINANCE_API_KEY\n  HYDRA_CREDENTIAL_KEY')"
expect_flagged exchange-env "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      OKX_PASSPHRASE: \${OKX_PASSPHRASE}\n')"
expect_flagged testnet-env "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      HYDRA_TESTNET: \${HYDRA_TESTNET}\n')"
expect_flagged testnet-host "sub(host, 'TZ=', 'HYDRA_TESTNET=\nTZ=')"
expect_flagged old-cors-name "sub(compose, 'HYDRA_API__CORS_ORIGINS', 'HYDRA_CORS_ORIGINS')"
expect_flagged cors-plain-string "sub(compose, '''HYDRA_API__CORS_ORIGINS: '[\"https://trading.\${DOMAIN}\"]'\n''', 'HYDRA_API__CORS_ORIGINS: https://trading.\${DOMAIN}\n')"

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all hydra env cases pass"
