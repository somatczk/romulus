#!/usr/bin/env bash
# =============================================================================
# ZimaOS - iptables Firewall Rules
# =============================================================================
# Configures host-level firewall. Run once, then persist with the crontab entry
# shown at the bottom of this script.
#
# Usage: sudo bash firewall.sh
#
# To persist across reboots, add to root's crontab:
#   @reboot /path/to/zimaos-config/scripts/firewall.sh
# =============================================================================
set -euo pipefail

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info()  { echo -e "${GREEN}[INFO]${NC}  $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC}  $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# --- Pre-flight checks ---
if [[ $EUID -ne 0 ]]; then
    log_error "This script must be run as root (sudo)."
    exit 1
fi

if ! command -v iptables &>/dev/null; then
    log_error "iptables is not installed."
    exit 1
fi

# =============================================================================
# Flush existing rules
# =============================================================================
log_info "Flushing existing iptables rules..."
iptables -F INPUT
iptables -F OUTPUT

# =============================================================================
# Set default policies
# =============================================================================
log_info "Setting default policies..."
iptables -P INPUT DROP
iptables -P OUTPUT ACCEPT

# =============================================================================
# INPUT chain rules
# =============================================================================

# Allow established and related connections
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
log_info "Accepting established/related connections."

# Allow loopback interface
iptables -A INPUT -i lo -j ACCEPT
log_info "Accepting loopback traffic."

# Allow LAN (192.168.0.0/24)
iptables -A INPUT -s 192.168.0.0/24 -j ACCEPT
log_info "Accepting LAN traffic (192.168.0.0/24)."

# libvirt VM bridge: DHCP + DNS from libvirt's dnsmasq only (the VM itself is fenced in hardening-firewall.sh).
iptables -A INPUT -i virbr0 -p udp -m multiport --dports 53,67 -j ACCEPT
iptables -A INPUT -i virbr0 -p tcp --dport 53 -j ACCEPT

# Allow Docker networks (10.10.0.0/16)
iptables -A INPUT -s 10.10.0.0/16 -j ACCEPT
log_info "Accepting Docker network traffic (10.10.0.0/16)."

# SSH from the LAN only (Tailscale is accepted via tailscale0); keys only, MaxAuthTries 3.
iptables -A INPUT -p tcp --dport 2222 -s 192.168.0.0/24 -j ACCEPT
log_info "Accepting SSH (tcp/2222) from LAN."

# Allow HTTPS on port 443 (Traefik / Cloudflare DDNS)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
log_info "Accepting HTTPS (tcp/443)."

# Allow TeamSpeak 3 Voice (UDP)
iptables -A INPUT -p udp --dport 9987 -j ACCEPT
log_info "Accepting TeamSpeak voice (udp/9987)."

# Allow TeamSpeak 3 File Transfer (TCP)
iptables -A INPUT -p tcp --dport 30033 -j ACCEPT
log_info "Accepting TeamSpeak file transfer (tcp/30033)."

# Allow ICMP echo-request (ping)
iptables -A INPUT -p icmp --icmp-type echo-request -j ACCEPT
log_info "Accepting ICMP echo-request."

# Log and drop everything else
iptables -A INPUT -j LOG --log-prefix "IPT-DROP: " --log-level 4
iptables -A INPUT -j DROP
log_info "Logging and dropping all other INPUT traffic."

# =============================================================================
# Summary
# =============================================================================
echo ""
echo -e "${GREEN}=============================================================================${NC}"
echo -e "${GREEN} Firewall rules applied successfully.${NC}"
echo -e "${GREEN}=============================================================================${NC}"
echo ""
echo "  Current INPUT rules:"
iptables -L INPUT -n -v --line-numbers
echo ""
echo -e "${YELLOW}  To persist across reboots, add to root's crontab:${NC}"
echo "    sudo crontab -e"
echo "    @reboot $(readlink -f "$0")"
echo ""
# The INPUT flush above drops Tailscale's hook; restore it if tailscaled is running.
iptables -N ts-input 2>/dev/null && iptables -X ts-input || iptables -C INPUT -j ts-input 2>/dev/null || iptables -I INPUT 1 -j ts-input
# Tailscale on nftables (Ubuntu) has no ts-input hook; tailnet ACLs gate what reaches tailscale0.
iptables -C INPUT -i tailscale0 -j ACCEPT 2>/dev/null || iptables -I INPUT 2 -i tailscale0 -j ACCEPT
# FORWARD is Docker's; CI isolation + IPv6 live in hardening-firewall.sh (also re-run by cron).
"$(dirname "$(readlink -f "$0")")/hardening-firewall.sh" || true
