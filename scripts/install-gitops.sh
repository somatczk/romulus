#!/usr/bin/env bash
# Host side of the GitOps setup, idempotent. Run as root on romulus:
#   sudo bash /DATA/stacks/scripts/install-gitops.sh
# First run (before /DATA/stacks is a checkout), straight from the repo:
#   curl -fsSL https://raw.githubusercontent.com/somatczk/romulus/master/scripts/install-gitops.sh | sudo bash
# Expects /DATA/doco-cd/op-token (romulus-deploy service account, read-only).
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPO=https://github.com/somatczk/romulus.git
STACKS=/DATA/stacks
DOCO=/DATA/doco-cd
USERS_DB=/media/SSD-Storage/appdata/security/authelia/users_database.yml
RESTIC_VERSION=0.17.3
RESTIC_SHA=5097faeda6aa13167aae6e36efdba636637f8741fed89bbf015678334632d4d3

[[ $EUID -eq 0 ]] || { echo "run as root"; exit 1; }
[[ -s $DOCO/op-token ]] || { echo "$DOCO/op-token missing"; exit 1; }

echo "== packages"
if ! command -v op >/dev/null; then
    curl -fsS https://downloads.1password.com/linux/keys/1password.asc |
        gpg --dearmor --yes -o /usr/share/keyrings/1password-archive-keyring.gpg
    echo "deb [arch=amd64 signed-by=/usr/share/keyrings/1password-archive-keyring.gpg] https://downloads.1password.com/linux/debian/amd64 stable main" \
        > /etc/apt/sources.list.d/1password.list
    apt-get update -qq && apt-get install -y -qq 1password-cli
fi
if [[ ! -x /DATA/bin/restic ]]; then
    mkdir -p /DATA/bin
    tmp=$(mktemp)
    curl -fsSLo "$tmp" "https://github.com/restic/restic/releases/download/v${RESTIC_VERSION}/restic_${RESTIC_VERSION}_linux_amd64.bz2"
    echo "$RESTIC_SHA  $tmp" | sha256sum -c --quiet -
    bunzip2 -c "$tmp" > /DATA/bin/restic && chmod +x /DATA/bin/restic && rm -f "$tmp"
fi

echo "== $STACKS as a git checkout"
if [[ ! -d $STACKS/.git ]]; then
    [[ -e $STACKS.pre-gitops ]] && { echo "$STACKS.pre-gitops exists, clean it up first"; exit 1; }
    rm -rf "$STACKS.new"
    git clone -q "$REPO" "$STACKS.new"
fi
# authelia's users file only exists on the host, it moves next to authelia's data
if [[ ! -f $USERS_DB ]]; then
    for src in "$STACKS" "$STACKS.pre-gitops"; do
        f=$src/configs/authelia/users_database.yml
        [[ -f $f ]] && { install -D -m 600 "$f" "$USERS_DB"; break; }
    done
fi
[[ -f $USERS_DB ]] || { echo "authelia users file not found, aborting before anything moves"; exit 1; }

echo "== preflight: every secret in .doco-cd.yml resolves"
src=$STACKS; [[ -d $STACKS.new ]] && src=$STACKS.new
export OP_SERVICE_ACCOUNT_TOKEN
OP_SERVICE_ACCOUNT_TOKEN=$(cat "$DOCO/op-token")
while read -r ref; do
    op read "$ref" >/dev/null || { echo "cannot read $ref"; exit 1; }
done < <(grep -oE 'op://[^ ]+' "$src/.doco-cd.yml" | sort -u)
install -d -m 700 "$DOCO/data" "$DOCO/docker"
# private hydra images on ghcr
op read op://romulus-deploy/ci/GITHUB_PAT | docker --config "$DOCO/docker" login ghcr.io -u somatczk --password-stdin >/dev/null
( umask 077
  printf 'ntfy://ntfy:80/deployments,tgram://%s/%s\n' \
      "$(op read op://romulus-deploy/shared/TELEGRAM_BOT_TOKEN)" "$(op read op://romulus-deploy/shared/TELEGRAM_CHAT_ID)" \
      > "$DOCO/apprise-urls" )
unset OP_SERVICE_ACCOUNT_TOKEN

echo "== docker networks"
for net in proxy socket media db-nextcloud db-immich monitoring db-paperless ai hydra; do
    docker network inspect "$net" >/dev/null 2>&1 || docker network create "$net"
done
# the firewall expects ci internal on this subnet; never reuse a stale one
if docker network inspect ci >/dev/null 2>&1; then
    got=$(docker network inspect ci --format '{{.Internal}} {{range .IPAM.Config}}{{.Subnet}}{{end}}')
    [[ $got == "true 10.10.4.0/24" ]] || { echo "network ci is '$got', expected 'true 10.10.4.0/24'"; exit 1; }
else
    docker network create --internal --subnet 10.10.4.0/24 ci
fi

if [[ -d $STACKS.new ]]; then
    echo "== swap $STACKS (old tree kept at $STACKS.pre-gitops for rollback)"
    mv "$STACKS" "$STACKS.pre-gitops"
    mv "$STACKS.new" "$STACKS"
fi
install -m 644 "$STACKS/scripts/systemd/romulus-stacks-sync.service" "$STACKS/scripts/systemd/romulus-stacks-sync.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now romulus-stacks-sync.timer

echo "== doco-cd"
docker compose -f "$STACKS/host/doco-cd/compose.yml" up -d --remove-orphans

echo "== crons"
bash "$STACKS/scripts/install-crons.sh"
echo "done"
