#!/usr/bin/env bash
# Diffs romulus copies against hydra main: drift fails with --strict, or when the changed paths on stdin touch a copy or a hydra image.
set -euo pipefail

RAW=${HYDRA_RAW:-https://raw.githubusercontent.com/somatczk/hydra/main/deploy}
STRICT=0
CHANGED=""
if [[ ${1:-} == --strict ]]; then
  STRICT=1
else
  CHANGED=$(cat)
fi
if grep -qE '^stacks/hydra/(engine|dashboard|backtest-worker)/Dockerfile$' <<< "$CHANGED"; then
  echo "hydra image bump: every synced copy must match hydra main"
  STRICT=1
fi

DRIFT=0
sync() {
  if curl -fsSL "$RAW/$1" | sed 's#^  - prometheus-rules\.yml$#  - ../hydra-alert-rules.yml#' | diff -u - "$2"; then
    echo "in sync: $2"
  elif [[ $STRICT -eq 1 ]] || grep -qxF "$2" <<< "$CHANGED"; then
    echo "::error file=$2::differs from hydra main deploy/$1"
    DRIFT=1
  else
    echo "::warning file=$2::differs from hydra main deploy/$1 (not touched by this PR)"
  fi
}
sync prometheus-rules.yml configs/prometheus/hydra-alert-rules.yml
sync prometheus-rules.test.yml configs/prometheus/tests/hydra-alert-rules.test.yml
sync grafana-dashboard.json configs/grafana/dashboards/hydra-trading.json
exit "$DRIFT"
