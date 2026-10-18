#!/usr/bin/env bash
# Keeps /DATA/stacks equal to origin/master (romulus-stacks-sync.timer). The checkout is
# read-only by convention, so local edits are discarded. When master moved, re-applies
# the host side that doco-cd doesn't own: crons, units and doco-cd itself.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /DATA/stacks
git fetch -q origin master
[[ $(git rev-parse HEAD) == $(git rev-parse origin/master) ]] && exit 0
git reset -q --hard origin/master
echo "synced to $(git rev-parse --short HEAD)"
bash scripts/install-crons.sh >/dev/null
docker compose -f host/doco-cd/compose.yml up -d --remove-orphans
