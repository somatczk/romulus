#!/usr/bin/env bash
# Runs hydra-sync.sh against a fake hydra main (file://) for each drift/trigger combination.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
SYNC="$HERE/hydra-sync.sh"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAILS=0

mkdir -p "$TMP/up"
printf 'groups: []\n' > "$TMP/up/prometheus-rules.yml"
printf 'rule_files:\n  - prometheus-rules.yml\n' > "$TMP/up/prometheus-rules.test.yml"
printf '{"title": "hydra"}\n' > "$TMP/up/grafana-dashboard.json"

tree() {
  local dir="$TMP/$1"
  rm -rf "$dir"; mkdir -p "$dir/configs/prometheus/tests" "$dir/configs/grafana/dashboards"
  cp "$TMP/up/prometheus-rules.yml" "$dir/configs/prometheus/hydra-alert-rules.yml"
  printf 'rule_files:\n  - ../hydra-alert-rules.yml\n' > "$dir/configs/prometheus/tests/hydra-alert-rules.test.yml"
  cp "$TMP/up/grafana-dashboard.json" "$dir/configs/grafana/dashboards/hydra-trading.json"
  echo "$dir"
}

# case <name> <want rc> <drifted copy or -> <changed paths or --strict>
case_() {
  local name=$1 want=$2 drift=$3 changed=$4 dir rc=0 out
  dir=$(tree "$name")
  [[ $drift == - ]] || echo "drift" >> "$dir/$drift"
  if [[ $changed == --strict ]]; then
    out=$(cd "$dir" && HYDRA_RAW="${UP:-file://$TMP/up}" bash "$SYNC" --strict < /dev/null 2>&1) || rc=$?
  else
    out=$(cd "$dir" && printf '%s\n' "$changed" | HYDRA_RAW="${UP:-file://$TMP/up}" bash "$SYNC" 2>&1) || rc=$?
  fi
  local tag="::error"
  [[ $want -eq 1 || $drift == - ]] || tag="::warning"
  if [[ $rc -eq $want ]] && { [[ $want -eq 0 && $drift == - ]] || grep -q "^$tag" <<< "$out"; }; then
    echo "ok   $name (rc=$rc)"
  else
    echo "FAIL $name: rc=$rc want $want"; echo "$out"; FAILS=$((FAILS + 1))
  fi
}

RULES=configs/prometheus/hydra-alert-rules.yml
TEST=configs/prometheus/tests/hydra-alert-rules.test.yml
DASH=configs/grafana/dashboards/hydra-trading.json

case_ in-sync-unrelated 0 - stacks/media/compose.yml
case_ in-sync-strict 0 - --strict
case_ in-sync-hydra-bump 0 - stacks/hydra/engine/Dockerfile
case_ drift-untouched-warns 0 "$RULES" stacks/media/compose.yml
case_ drift-touched-fails 1 "$RULES" "$RULES"
case_ test-drift-touched-fails 1 "$TEST" "$TEST"
case_ drift-engine-bump-fails 1 "$DASH" stacks/hydra/engine/Dockerfile
case_ drift-dashboard-bump-fails 1 "$RULES" stacks/hydra/dashboard/Dockerfile
case_ drift-backtest-bump-fails 1 "$TEST" stacks/hydra/backtest-worker/Dockerfile
case_ drift-timescaledb-bump-warns 0 "$RULES" stacks/hydra/timescaledb/Dockerfile
case_ drift-strict-fails 1 "$DASH" --strict
UP="file://$TMP/missing" case_ fetch-error-strict-fails 1 - --strict

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all hydra sync cases pass"
