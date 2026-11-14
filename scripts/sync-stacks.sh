#!/usr/bin/env bash
# Keeps /DATA/stacks equal to origin/master (romulus-stacks-sync.timer). The checkout is
# read-only by convention, so local edits are discarded. When master moved, re-applies
# the host side that doco-cd doesn't own: crons, units and doco-cd itself.
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
cd /DATA/stacks
if [[ ${1:-} != --apply ]]; then
    git fetch -q origin master
    [[ $(git rev-parse HEAD) == $(git rev-parse origin/master) ]] && exit 0
    git reset -q --hard origin/master
    echo "synced to $(git rev-parse --short HEAD)"
    # bash already holds the old copy of this script; run the new one so its checks apply to this sync
    exec bash scripts/sync-stacks.sh --apply
fi
bash scripts/install-crons.sh >/dev/null
# a missing bind source would be created as a directory and break doco-cd; keep the old one running
[[ -f /DATA/doco-cd/git-token && -s /DATA/doco-cd/git-token ]] || { echo "/DATA/doco-cd/git-token missing, doco-cd not updated"; exit 1; }
docker compose -f host/doco-cd/compose.yml up -d --remove-orphans
