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
iptables -F FORWARD

# =============================================================================
# Set default policies
# =============================================================================
log_info "Setting default policies..."
iptables -P INPUT DROP
iptables -P FORWARD ACCEPT
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

# Allow ZeroTier (172.22.0.0/16)
iptables -A INPUT -s 172.22.0.0/16 -j ACCEPT
log_info "Accepting ZeroTier traffic (172.22.0.0/16)."

# Allow Docker networks (10.10.0.0/16)
iptables -A INPUT -s 10.10.0.0/16 -j ACCEPT
log_info "Accepting Docker network traffic (10.10.0.0/16)."

# SSH rate limiting (max 4 new connections per 60 seconds)
iptables -A INPUT -p tcp --dport 2222 -m state --state NEW -m recent --set --name SSH
iptables -A INPUT -p tcp --dport 2222 -m state --state NEW -m recent --update --seconds 60 --hitcount 4 --name SSH -j DROP
# Allow SSH from LAN and ZeroTier only
iptables -A INPUT -p tcp --dport 2222 -s 192.168.0.0/24 -j ACCEPT
iptables -A INPUT -p tcp --dport 2222 -s 172.22.0.0/16 -j ACCEPT
log_info "Accepting SSH (tcp/2222) from LAN + VPN only (rate-limited)."

# Allow HTTPS on port 443 (Traefik / Cloudflare DDNS)
iptables -A INPUT -p tcp --dport 443 -j ACCEPT
log_info "Accepting HTTPS (tcp/443)."

# Allow ZeroTier UDP port
iptables -A INPUT -p udp --dport 9993 -j ACCEPT
log_info "Accepting ZeroTier (udp/9993)."

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
