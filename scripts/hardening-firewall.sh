#!/bin/sh
# Layered on firewall.sh. Idempotent: runs at boot and every 5 minutes from cron, so
# Docker/Tailscale restarts cannot drop or reorder the jumps. Chains are rebuilt only
# when their content changes. Blocks are independent: one failure never skips the rest.
#
# v4: the Docker address pool minus the long-lived homelab networks is "CI" (docker0, the
#     ci* networks, anything a job creates). CI may reach the host only on Docker's
#     ephemeral published ports (Testcontainers) and DNS, and never LAN/overlay ranges.
# v6: inbound default-deny except LAN, link-local, ULA, overlays and public services.
set -u
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# One run at a time: cron, boot and deploys share the temporary chains.
exec 9>/run/hardening-firewall.lock
flock -w 60 9 || { echo "hardening-firewall: lock busy" >&2; exit 1; }

IPT="iptables -w"
IP6T="ip6tables -w"
DOCKER_POOL=10.10.0.0/16
HOMELAB_NETS="proxy socket media monitoring hydra db-nextcloud db-immich db-paperless core_default security_authelia utilities_ts-db"
PRIVATE_DSTS="192.168.0.0/16 172.16.0.0/12 100.64.0.0/10 169.254.0.0/16"
ROUTER_DNS=192.168.0.1
LAN_IF=$(ip -o route show default | awk '{print $5; exit}')  # eth1 on ZimaOS, eth0 on Ubuntu

log() { echo "$(date +%FT%T) hardening-firewall: $*" >&2; }

# $1=iptables cmd, $2=chain; desired rules on stdin, one per line.
sync_chain() {
  ipt=$1; c=$2; t="$c-NEW"
  $ipt -N "$t" 2>/dev/null; $ipt -F "$t"
  while read -r r; do [ -n "$r" ] && $ipt -A "$t" $r; done
  want=$($ipt -S "$t" | sed 1d | sed "s/^-A $t /-A $c /")
  if [ "$want" != "$($ipt -S "$c" 2>/dev/null | sed 1d)" ]; then
    $ipt -N "$c" 2>/dev/null; $ipt -F "$c"
    $ipt -S "$t" | sed 1d | sed "s/^-A $t //" | while read -r r; do $ipt -A "$c" $r; done
    log "rebuilt $c"
  fi
  $ipt -F "$t"; $ipt -X "$t"
}

# Keep "-j $3" as the first rule of chain $2.
ensure_first() {
  ipt=$1; parent=$2; c=$3
  [ "$($ipt -S "$parent" | sed -n 2p)" = "-A $parent -j $c" ] && return 0
  while $ipt -D "$parent" -j "$c" 2>/dev/null; do :; done
  $ipt -I "$parent" 1 -j "$c" && log "linked $c at top of $parent"
}

homelab_subnets() {
  for n in $HOMELAB_NETS; do
    s=$(docker network inspect "$n" -f '{{range .IPAM.Config}}{{.Subnet}} {{end}}' 2>/dev/null) \
      || { log "WARN homelab network $n not found"; continue; }
    echo "$s"
  done
}

v4() {
  homelab=$(homelab_subnets)
  # Docker not up yet (boot): leave v4 alone; the next cron run applies it.
  [ -n "$homelab" ] || { log "no homelab networks visible, skipping v4"; return 0; }
  {
    echo "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    for s in $homelab; do echo "-s $s -j RETURN"; done
    echo "-s $DOCKER_POOL -p tcp --dport 32768:60999 -j ACCEPT"
    echo "-s $DOCKER_POOL -p udp --dport 53 -j ACCEPT"
    echo "-s $DOCKER_POOL -p tcp --dport 53 -j ACCEPT"
    echo "-s $DOCKER_POOL -j DROP"
  } | sync_chain "$IPT" CI-IN
  ensure_first "$IPT" INPUT CI-IN

  {
    echo "-m conntrack --ctstate RELATED,ESTABLISHED -j RETURN"
    for s in $homelab; do echo "-s $s -j RETURN"; done
    echo "-s $DOCKER_POOL -d $ROUTER_DNS -p udp --dport 53 -j RETURN"
    echo "-s $DOCKER_POOL -d $ROUTER_DNS -p tcp --dport 53 -j RETURN"
    for d in $PRIVATE_DSTS; do echo "-s $DOCKER_POOL -d $d -j DROP"; done
  } | sync_chain "$IPT" CI-FWD
  # DOCKER-USER is the only FORWARD hook Docker keeps first; it re-sorts FORWARD on every
  # network change. Creating it early is safe: Docker adopts an existing chain.
  $IPT -N DOCKER-USER 2>/dev/null
  while $IPT -D FORWARD -j CI-FWD 2>/dev/null; do :; done
  ensure_first "$IPT" DOCKER-USER CI-FWD
}

v6() {
  lan=$(ip -6 route show dev "$LAN_IF" | awk '$1 ~ /^[23][0-9a-f]*:.*\// {print $1}' | sort -u)
  {
    echo "-i lo -j ACCEPT"
    echo "-i virbr+ -j RETURN"
    echo "-m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT"
    echo "-p ipv6-icmp -j ACCEPT"
    echo "-s fe80::/10 -j ACCEPT"
    echo "-s fc00::/7 -j ACCEPT"
    for p in $lan; do echo "-s $p -j ACCEPT"; done
    echo "-p udp --dport 41641 -j ACCEPT"
    echo "-p tcp --dport 443 -j ACCEPT"
    echo "-p udp --dport 9987 -j ACCEPT"
    echo "-p tcp --dport 30033 -j ACCEPT"
    echo "-j DROP"
  } | sync_chain "$IP6T" HOST6-IN
  ensure_first "$IP6T" INPUT HOST6-IN
}

# CI VM (libvirt NAT on virbr0): internet and tailnet VPC routes only. A separate nftables
# table at priority -10 runs before iptables, so libvirt/Docker rule churn cannot reorder it.
vm() {
  nft -f - <<'NFT'
table inet romulus_vm_guard
delete table inet romulus_vm_guard
table inet romulus_vm_guard {
  set blocked4 {
    type ipv4_addr; flags interval
    elements = { 0.0.0.0/8, 127.0.0.0/8, 192.168.0.0/16, 172.16.0.0/12, 100.64.0.0/10, 169.254.0.0/16, 10.10.0.0/16 }
  }
  chain forward {
    type filter hook forward priority -10; policy accept;
    iifname "virbr0" ct state established,related accept
    iifname "virbr0" ip daddr @blocked4 drop
    iifname "virbr0" meta nfproto ipv6 drop
  }
  chain input {
    type filter hook input priority -10; policy accept;
    iifname "virbr0" ct state established,related accept
    iifname "virbr0" udp dport { 53, 67 } accept
    iifname "virbr0" tcp dport 53 accept
    iifname "virbr0" drop
  }
}
NFT
}

v4 || log "ERROR v4 block failed"
v6 || log "ERROR v6 block failed"
vm || log "ERROR vm block failed"
