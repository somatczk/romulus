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
        # authelia runs as 999:1000 (PUID/PGID)
        [[ -f $f ]] && { install -D -m 600 -o 999 -g 1000 "$f" "$USERS_DB"; break; }
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
install -d -m 700 "$DOCO/data"
( umask 077
  printf 'ntfy://ntfy:80/deployments,tgram://%s/%s\n' \
      "$(op read op://romulus-deploy/shared/TELEGRAM_BOT_TOKEN)" "$(op read op://romulus-deploy/shared/TELEGRAM_CHAT_ID)" \
      > "$DOCO/apprise-urls" )
unset OP_SERVICE_ACCOUNT_TOKEN

echo "== docker networks"
# name, internal, subnet: the firewall (hardening-firewall.sh) keys on these subnets
while read -r net internal subnet; do
    if docker network inspect "$net" >/dev/null 2>&1; then
        got=$(docker network inspect "$net" --format '{{.Internal}} {{range .IPAM.Config}}{{.Subnet}}{{end}}')
        [[ $got == "$internal $subnet" ]] || { echo "network $net is '$got', expected '$internal $subnet'"; exit 1; }
    else
        flag=(); [[ $internal == true ]] && flag=(--internal)
        docker network create "${flag[@]}" --subnet "$subnet" "$net"
    fi
done <<'NETS'
proxy false 10.10.5.0/24
monitoring true 10.10.1.0/24
db-immich true 10.10.2.0/24
db-nextcloud true 10.10.3.0/24
media true 10.10.6.0/24
socket true 10.10.7.0/24
db-paperless true 10.10.12.0/24
hydra false 10.10.14.0/24
ai false 10.10.15.0/24
NETS

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
