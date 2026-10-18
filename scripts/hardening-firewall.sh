#!/bin/sh
# Idempotent hardening layered on top of firewall.sh (safe to re-run; called from it at boot).
# - CI subnets: no reach into the LAN / overlay nets, host reachable only on Docker's
#   ephemeral published-port range (Testcontainers) and DNS.
# - IPv6: default-deny inbound (the host has a public v6 address).
set -eu

CI_NETS="10.10.0.0/24 10.10.4.0/24 10.10.10.0/24 10.10.13.0/24"   # docker0, ci, ci-socket, ci-egress
PRIVATE_DSTS="192.168.0.0/16 172.16.0.0/12 100.64.0.0/10 169.254.0.0/16"
ROUTER_DNS=192.168.0.1

chain4() { iptables -N "$1" 2>/dev/null || true; iptables -F "$1"; }
chain6() { ip6tables -N "$1" 2>/dev/null || true; ip6tables -F "$1"; }

# --- v4: CI -> host ---
chain4 CI-IN
iptables -A CI-IN -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
for n in $CI_NETS; do
  iptables -A CI-IN -s "$n" -p tcp --dport 32768:60999 -j ACCEPT
  iptables -A CI-IN -s "$n" -p udp --dport 53 -j ACCEPT
  iptables -A CI-IN -s "$n" -p tcp --dport 53 -j ACCEPT
  iptables -A CI-IN -s "$n" -j DROP
done
iptables -C INPUT -j CI-IN 2>/dev/null || iptables -I INPUT 2 -j CI-IN

# Management ports only via LAN / ZeroTier / Tailscale (accepted earlier in INPUT).
iptables -D INPUT -p tcp -m tcp --dport 2222 -j ACCEPT 2>/dev/null || true
iptables -D INPUT -p tcp -m tcp --dport 80 -j ACCEPT 2>/dev/null || true

# --- v4: CI -> LAN / overlays (forwarded traffic) ---
chain4 CI-FWD
iptables -A CI-FWD -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
for n in $CI_NETS; do
  iptables -A CI-FWD -s "$n" -d "$ROUTER_DNS" -p udp --dport 53 -j RETURN
  iptables -A CI-FWD -s "$n" -d "$ROUTER_DNS" -p tcp --dport 53 -j RETURN
  for d in $PRIVATE_DSTS; do iptables -A CI-FWD -s "$n" -d "$d" -j DROP; done
done
iptables -C DOCKER-USER -j CI-FWD 2>/dev/null || iptables -I DOCKER-USER 1 -j CI-FWD

# --- v6: default-deny inbound ---
chain6 HOST6-IN
ip6tables -A HOST6-IN -i lo -j ACCEPT
ip6tables -A HOST6-IN -i virbr+ -j RETURN
ip6tables -A HOST6-IN -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
ip6tables -A HOST6-IN -p ipv6-icmp -j ACCEPT
ip6tables -A HOST6-IN -s fe80::/10 -j ACCEPT
ip6tables -A HOST6-IN -s fd00::/8 -j ACCEPT
ip6tables -A HOST6-IN -p udp --dport 9993 -j ACCEPT    # zerotier
ip6tables -A HOST6-IN -p udp --dport 41641 -j ACCEPT   # tailscale
ip6tables -A HOST6-IN -p tcp --dport 443 -j ACCEPT     # traefik
ip6tables -A HOST6-IN -p udp --dport 9987 -j ACCEPT    # teamspeak voice
ip6tables -A HOST6-IN -p tcp --dport 30033 -j ACCEPT   # teamspeak files
ip6tables -A HOST6-IN -j DROP
ip6tables -C INPUT -j HOST6-IN 2>/dev/null || ip6tables -I INPUT 1 -j HOST6-IN
