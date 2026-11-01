#!/usr/bin/env bash
# Cron, every minute (install-crons.sh): does the CI VM's k3s API answer? A hung VM stays "running" in virsh
# (2026-11-01), so only a reply from inside it counts.
set -uo pipefail
METRICS_DIR="/var/lib/node_exporter/textfile_collector"
IP=192.168.122.10

# any HTTP status counts (401 without credentials); 000 means no reply
code=$(curl -sk -m 10 -o /dev/null -w '%{http_code}' "https://${IP}:6443/readyz")
up=0
[[ $code != 000 ]] && up=1

tmpfile="${METRICS_DIR}/ci_vm.prom.$$"
mkdir -p "${METRICS_DIR}"
cat > "${tmpfile}" <<PROM
# HELP homelab_ci_vm_up Whether the CI VM's k3s API answered the last probe (1=yes, 0=no).
# TYPE homelab_ci_vm_up gauge
homelab_ci_vm_up ${up}
# HELP homelab_ci_vm_probe_timestamp Unix timestamp of the last CI VM probe.
# TYPE homelab_ci_vm_probe_timestamp gauge
homelab_ci_vm_probe_timestamp $(date +%s)
PROM
mv "${tmpfile}" "${METRICS_DIR}/ci_vm.prom"
