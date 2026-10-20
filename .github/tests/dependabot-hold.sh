#!/usr/bin/env bash
# Runs the real auto-merge step of dependabot-auto-merge.yml (or $1) against a stubbed gh.
set -euo pipefail

WF=${1:-"$(dirname "$0")/../workflows/dependabot-auto-merge.yml"}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

python3 - "$WF" "$TMP/step.sh" <<'PY'
import shlex, sys, yaml
wf, out = sys.argv[1:]
step = yaml.safe_load(open(wf))["jobs"]["auto-merge"]["steps"][0]
with open(out, "w") as f:
    for k, v in step["env"].items():
        if "${{" not in str(v):
            f.write(f"export {k}={shlex.quote(str(v))}\n")
    f.write(step["run"])
PY

mkdir "$TMP/bin"
cat > "$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  "pr list") echo "1 $STUB_TITLE" ;;
  "pr merge") shift 2; echo "$*" >> "$MERGE_LOG" ;;
  *) echo "unexpected gh call: $*" >&2; exit 2 ;;
esac
SH
chmod +x "$TMP/bin/gh"

FAILS=0
check() {
  local expect=$1 title=$2 out merged
  : > "$TMP/merge.log"
  out=$(env -i PATH="$TMP/bin:$PATH" HOME="$HOME" HEAD_BRANCH=dependabot/test \
    STUB_TITLE="$title" MERGE_LOG="$TMP/merge.log" bash -e "$TMP/step.sh" 2>&1) || {
    echo "FAIL step exited non-zero: $title"; echo "$out"; FAILS=$((FAILS + 1)); return
  }
  merged=$(cat "$TMP/merge.log")
  if [[ "$expect" == merge ]]; then
    if [[ "$merged" == "1 --merge --delete-branch" && "$out" != *"leaving #1"* ]]; then
      echo "ok   merged: $title"
    else
      echo "FAIL expected merge: $title"; echo "  out: $out"; echo "  merge log: $merged"; FAILS=$((FAILS + 1))
    fi
  else
    if [[ -z "$merged" && "$out" == *"leaving #1 for review ($expect): $title"* ]]; then
      echo "ok   held ($expect): $title"
    else
      echo "FAIL expected hold ($expect): $title"; echo "  out: $out"; echo "  merge log: $merged"; FAILS=$((FAILS + 1))
    fi
  fi
}

check "hydra image" "docker: bump somatczk/hydra-engine from 2.1.10 to 2.1.11 in /stacks/hydra/engine"
check "hydra image" "docker: bump somatczk/hydra-dashboard from 2.1.10 to 2.2.0 in /stacks/hydra/dashboard"
check "hydra image" "docker: bump somatczk/hydra-backtest from 2.1.10 to 2.1.11 in /stacks/hydra/backtest-worker"
check "hydra image" "docker: bump ghcr.io/somatczk/hydra-engine from 2.1.10 to 2.1.11 in /stacks/hydra/engine"
check "stateful image" "docker: bump timescale/timescaledb from 2.30.0-pg16 to 2.30.2-pg16 in /stacks/hydra/timescaledb"
check "major" "docker: bump amir20/dozzle from 10.6.10 to 11.0.0 in /stacks/utilities/dozzle"
check merge "docker: bump amir20/dozzle from 10.6.10 to 10.6.11 in /stacks/utilities/dozzle"
check merge "ci: bump the actions group across 2 directories with 3 updates"

if [[ $FAILS -gt 0 ]]; then
  echo "$FAILS case(s) failed"
  exit 1
fi
echo "all auto-merge hold cases pass"
