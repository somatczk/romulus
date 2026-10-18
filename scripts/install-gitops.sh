#!/usr/bin/env bash
# Host side of the GitOps setup, idempotent. Run as root on romulus:
#   sudo bash /DATA/stacks/scripts/install-gitops.sh   (or piped over ssh for the first run)
# Expects /DATA/doco-cd/op-token (romulus-deploy service account, read-only).
set -euo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
REPO=https://github.com/somatczk/romulus.git
STACKS=/DATA/stacks
DOCO=/DATA/doco-cd
APPDATA=/media/SSD-Storage/appdata

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
    curl -fsSL "https://github.com/restic/restic/releases/download/v0.17.3/restic_0.17.3_linux_amd64.bz2" |
        bunzip2 > /DATA/bin/restic
    chmod +x /DATA/bin/restic
fi

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

echo "== $STACKS as a git checkout"
if [[ ! -d $STACKS/.git ]]; then
    # authelia's users file only exists on the host, keep it outside the checkout
    users=$STACKS/configs/authelia/users_database.yml
    if [[ -f $users && ! -f $APPDATA/security/authelia/users_database.yml ]]; then
        install -D -m 600 "$users" "$APPDATA/security/authelia/users_database.yml"
    fi
    [[ -e $STACKS ]] && mv "$STACKS" "$STACKS.pre-gitops"
    git clone -q "$REPO" "$STACKS"
fi
install -m 644 "$STACKS/scripts/systemd/romulus-stacks-sync.service" "$STACKS/scripts/systemd/romulus-stacks-sync.timer" /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now romulus-stacks-sync.timer

echo "== doco-cd"
install -d -m 700 "$DOCO/data" "$DOCO/docker"
export OP_SERVICE_ACCOUNT_TOKEN
OP_SERVICE_ACCOUNT_TOKEN=$(cat "$DOCO/op-token")
# private hydra images on ghcr
op read op://romulus-deploy/ci/GITHUB_PAT | docker --config "$DOCO/docker" login ghcr.io -u somatczk --password-stdin >/dev/null
( umask 077
  printf 'ntfy://ntfy:80/deployments,tgram://%s/%s\n' \
      "$(op read op://romulus-deploy/shared/TELEGRAM_BOT_TOKEN)" "$(op read op://romulus-deploy/shared/TELEGRAM_CHAT_ID)" \
      > "$DOCO/apprise-urls" )
unset OP_SERVICE_ACCOUNT_TOKEN
docker compose -f "$STACKS/host/doco-cd/compose.yml" up -d --remove-orphans

echo "== crons"
bash "$STACKS/scripts/install-crons.sh"
echo "done"
