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
expect_flagged worker-key-missing "sub(compose, '      HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}\n    volumes:\n      - \${APPDATA}/hydra/config/strategies:/app/config/strategies:ro\n      - \${APPDATA}/hydra/models:/app/models:rw', '    volumes:\n      - \${APPDATA}/hydra/config/strategies:/app/config/strategies:ro\n      - \${APPDATA}/hydra/models:/app/models:rw')"
expect_flagged engine-key-unguarded "sub(compose, 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}', 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY}')"
expect_flagged engine-key-allows-empty "sub(compose, 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}', 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY?}')"
expect_flagged worker-key-allows-empty "sub(compose, 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}\n    volumes:\n      - \${APPDATA}/hydra/config/strategies:/app/config/strategies:ro\n      - \${APPDATA}/hydra/models:/app/models:rw', 'HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY?missing}\n    volumes:\n      - \${APPDATA}/hydra/config/strategies:/app/config/strategies:ro\n      - \${APPDATA}/hydra/models:/app/models:rw')"
expect_flagged exchange-secret "sub(doco, 'external_secrets:\n  HYDRA_CREDENTIAL_KEY', 'external_secrets:\n  BINANCE_API_KEY: op://romulus-deploy/hydra/BINANCE_API_KEY\n  HYDRA_CREDENTIAL_KEY')"
expect_flagged exchange-env "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      OKX_PASSPHRASE: \${OKX_PASSPHRASE}\n')"
expect_flagged exchange-env-nested "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      HYDRA_EXCHANGES__BINANCE__API_KEY: \${X}\n')"
expect_flagged exchange-env-nested-any "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      HYDRA_EXCHANGES__COINBASE__API_KEY: \${X}\n')"
expect_flagged exchange-secret-nested "sub(doco, 'external_secrets:\n  HYDRA_CREDENTIAL_KEY', 'external_secrets:\n  HYDRA_EXCHANGES__OKX__PASSPHRASE: op://romulus-deploy/hydra/X\n  HYDRA_CREDENTIAL_KEY')"
expect_flagged exchange-host-nested "sub(host, 'TZ=', 'HYDRA_EXCHANGES__KRAKEN__API_SECRET=\nTZ=')"
expect_flagged testnet-env "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      HYDRA_TESTNET: \${HYDRA_TESTNET}\n')"
expect_flagged testnet-host "sub(host, 'TZ=', 'HYDRA_TESTNET=\nTZ=')"
expect_flagged old-cors-name "sub(compose, '      REDIS_URL: redis://hydra-redis:6379\n', '      REDIS_URL: redis://hydra-redis:6379\n      HYDRA_CORS_ORIGINS: https://trading.\${DOMAIN}\n')"
expect_flagged trader-key-missing "sub(compose, '      HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}\n      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n    volumes:', '      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n    volumes:')"
expect_flagged trader-token-unguarded "sub(compose, '      HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}\n      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n    volumes:', '      HYDRA_CREDENTIAL_KEY: \${HYDRA_CREDENTIAL_KEY:?}\n      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN}\n    volumes:')"
expect_flagged trader-extra-env "sub(compose, '      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n    volumes:', '      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n      HYDRA_MCP_TOKEN: \${HYDRA_MCP_TOKEN:?}\n    volumes:')"
expect_flagged trader-url-missing "sub(compose, '      # the D5 split knob: set = this process is the API only, the trader holds the sessions\n      HYDRA_TRADER__URL: http://hydra-trader:8000\n', '')"
expect_flagged trader-url-wrong "sub(compose, 'HYDRA_TRADER__URL: http://hydra-trader:8000', 'HYDRA_TRADER__URL: http://localhost:8000')"
expect_flagged trader-gone "sub(compose, '  hydra-trader:\n    build: ./engine', '  hydra-trader-gone:\n    build: ./engine')"
# anchors the trader volumes: a removed or flipped models mount goes stale here and aborts, not silently
expect_flagged trader-token-missing "sub(compose, '      HYDRA_API_TOKEN: \${HYDRA_API_TOKEN:?}\n    volumes:\n      # read-only: the API process owns strategy writes; the trader reads them for recovery and reload\n      - \${APPDATA}/hydra/config/strategies:/app/config/strategies:ro\n      # read-only: the backtest worker ml_train owns artifact writes; the trader reads them for the session ML attach, the P5-C recovery re-validation and the ML overlay Production-model reads (services/sessions.py, execution/session_recovery.py, ml/consumers.py; all via ml/serving.py)\n      - \${APPDATA}/hydra/models:/app/models:ro', '    volumes:\n      # read-only: the API process owns strategy writes; the trader reads them for recovery and reload\n      - \${APPDATA}/hydra/config/strategies:/app/config/strategies:ro\n      # read-only: the backtest worker ml_train owns artifact writes; the trader reads them for the session ML attach, the P5-C recovery re-validation and the ML overlay Production-model reads (services/sessions.py, execution/session_recovery.py, ml/consumers.py; all via ml/serving.py)\n      - \${APPDATA}/hydra/models:/app/models:ro')"
expect_flagged worker-shared-hostname "sub(compose, '    # (its id) keeps the worker ids unique - never set a shared hostname here\n', '    # (its id) keeps the worker ids unique - never set a shared hostname here\n    hostname: hydra-backtest-worker\n')"
expect_flagged worker-host-network "sub(compose, '    # (its id) keeps the worker ids unique - never set a shared hostname here\n', '    # (its id) keeps the worker ids unique - never set a shared hostname here\n    network_mode: host\n')"
expect_flagged worker-budget-multiplied "sub(compose, 'HYDRA_DATA__FETCH_WEIGHT_PER_MIN: \"300\"', 'HYDRA_DATA__FETCH_WEIGHT_PER_MIN: \"900\"')"
expect_flagged worker-budget-unset "sub(compose, '      HYDRA_DATA__FETCH_WEIGHT_PER_MIN: \"300\"\n', '')"
expect_flagged worker-more-replicas "sub(compose, '      replicas: 3\n', '      replicas: 4\n')"
expect_flagged worker-gone "sub(compose, '  hydra-backtest-worker:\n    build: ./backtest-worker', '  hydra-backtest-worker-gone:\n    build: ./backtest-worker')"

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all hydra env cases pass"
