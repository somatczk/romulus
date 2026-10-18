# Romulus: homelab server configuration

Homelab configuration for a ZimaCube (Ryzen 9 5950X, 128GB RAM, GTX 1650 SUPER) running Ubuntu 26.04 LTS. This repo is the source of truth: compose stacks for the host, Flux manifests for the CI cluster.

## Architecture

11 Docker Compose stacks:

| Stack | Services | RAM |
|-------|----------|-----|
| **core** | Traefik, Socket Proxy, Cloudflare DDNS, AdGuard | 960 MB |
| **security** | Authelia, CrowdSec, Bouncer | 640 MB |
| **media** | Jellyfin, Sonarr, Radarr, FlareSolverr, Prowlarr, Bazarr, Lidarr, qBittorrent, Jellyseerr | 11 GB |
| **productivity** | Nextcloud, Immich, Home Assistant, Paperless-ngx, Actual Budget, Homebox (+ PostgreSQL/Redis) | 26.5 GB |
| **monitoring** | Prometheus, Grafana, Loki, Promtail, Node/GPU/SMART/Restic Exporters, cAdvisor, Uptime Kuma, Glances | 5.1 GB |
| **notifications** | ntfy | 256 MB |
| **utilities** | Watchtower, Dozzle, Speedtest, Portainer, TeamSpeak, Autoheal | 2.6 GB |
| **dashboard** | Homepage | 512 MB |
| **ai** | Ollama, OpenClaw, Open WebUI, Socket Proxy | ~19 GB |
| **hydra** | Hydra Engine, Dashboard, Backtest Worker, TimescaleDB, Redis | 18.5 GB |

Image versions pinned in single-line Dockerfiles (`stacks/<stack>/<service>/Dockerfile`). Dependabot opens weekly PRs; patch and minor bumps of stateless images auto-merge after CI passes, majors, 0.x and calendar-version minors and stateful images (databases, immich, nextcloud, paperless, Home Assistant) wait for a review.

## Deployment

Pull-based: [doco-cd](https://doco.cd) on the host polls `master` every minute and deploys the stacks listed in `.doco-cd.yml`. Merging is deploying; there is no deploy job in CI.

- **Secrets:** 1Password vault `romulus-deploy`, one item per stack. doco-cd reads it with a read-only service account (token in `/DATA/doco-cd/op-token`) and interpolates only the secrets each stack lists. Non-secret settings are in `stacks/host.env`. Containers get only the variables their compose service maps, never a shared `.env`.
- **Host files:** `/DATA/stacks` is a checkout kept on `origin/master` by `romulus-stacks-sync.timer` (every 5 minutes, local edits are discarded). When master moves it also re-applies the crons and doco-cd itself. Host scripts load their secrets through `scripts/lib/env.sh` and alert via ntfy if 1Password is unreachable.
- **Notifications:** deploy results (success, warnings, failures) go to ntfy and Telegram through apprise. Prometheus scrapes doco-cd; `DocoCdDown` fires after 10 minutes down.
- **Host setup** (packages, networks, checkout, doco-cd, crons), idempotent: `sudo bash /DATA/stacks/scripts/install-gitops.sh`.

Check a deploy: `docker logs -f doco-cd`, `git -C /DATA/stacks log -1`, labels `cd.doco.deployment.target.sha` on the containers. Roll back: `git revert` on master (that is a deploy too). Rotate a secret: edit it in 1Password, then redeploy the stack (a commit touching it, or `docker restart doco-cd`).

### Disaster recovery

Fresh host: restore `/media/*-Storage` from restic, create a new service account for `romulus-deploy` (1Password, read-only), write its token to `/DATA/doco-cd/op-token`, run `curl -fsSL https://raw.githubusercontent.com/somatczk/romulus/master/scripts/install-gitops.sh | sudo bash`. `ai` is disabled and not deployed. Keep a copy of `RESTIC_PASSWORD` outside 1Password (paper or a separate vault): restoring the backups must not depend on the service that holds the secrets.

## CI platform

Organisation runners run in a single-node k3s cluster inside a KVM guest (`romulus-ci`, 24 vCPU, 96 GB RAM, 250 GB disk) and autoscale from zero with [Actions Runner Controller](https://github.com/actions/actions-runner-controller).

```mermaid
flowchart LR
  gh[GitHub] -- job --> listener[ARC listener]
  subgraph vm[romulus-ci VM: k3s]
    listener --> pod[runner pod + dind sidecar]
    pod --> bk[per-org buildkitd]
    pod --> mirror[registry mirror]
    eso[External Secrets] --> secret[GitHub App secret]
  end
  op[1Password vault] --> eso
  flux[Flux] -- reconciles --> vm
  repo[(this repo)] --> flux
```

- **GitOps:** Flux syncs `clusters/romulus` and `kubernetes/` from `master`; nothing is applied by hand except the bootstrap below.
- **Identity:** one GitHub App per org (no PATs). Keys live in 1Password and reach the cluster through External Secrets; git holds no credentials, encrypted or not.
- **Runners:** ephemeral pods per job with a native dind sidecar. Labels match the old compose fleet, so workflows did not change. Per-org PVC cache, per-org BuildKit, shared Docker Hub mirror.
- **Supply chain:** the runner image (`images/arc-runner`) is built on GitHub-hosted runners with SBOM and provenance, cosign-signed from `master`, and deployed by digest.
- **Network:** the host fences the VM off the LAN (`scripts/hardening-firewall.sh`, `vm()`); NetworkPolicies keep each org namespace to itself, DNS, the mirror and the internet.

**Trust model.** dind needs `privileged`, so a job can reach the node. Every org on this cluster therefore shares one trust boundary; the VM is the wall between CI and the homelab, not between orgs. All orgs here belong to the same owner. A tenant needing hard isolation gets its own VM (`create.sh` with another name/IP).

**Capacity.** Requests (4 GiB heavy, 2 GiB light per pod) are what the scheduler packs; limits (16 GiB heavy, 7 GiB light) overcommit on purpose because jobs rarely peak together. Kubelet reserves 4 GiB for the system and evicts below 2 GiB free. Max concurrency: vetoo 4 heavy (1 warm) + 8 light, coordentra 1 + 2, solhouse 2.

**Bootstrap / disaster recovery** (caches are rebuildable and not backed up):

```bash
sudo scripts/ci-vm/create.sh ~/.ssh/id_ed25519.pub        # on romulus
ssh romulus-ci sudo cat /etc/rancher/k3s/k3s.yaml | \
  sed 's#127.0.0.1:6443#192.168.122.10:6443#' > ~/.kube/romulus-ci.yaml && chmod 600 ~/.kube/romulus-ci.yaml
export KUBECONFIG=~/.kube/romulus-ci.yaml                   # reach it via: ssh -L 6443:192.168.122.10:6443 romulus
kubectl create namespace external-secrets
op read "op://<vault>/<service account item>/credential" | tr -d '\n' | \
  kubectl -n external-secrets create secret generic onepassword-token --from-file=token=/dev/stdin
kubectl apply -k clusters/romulus/flux-system && kubectl apply -k clusters/romulus
```

Flux version: `flux install --export > clusters/romulus/flux-system/gotk-components.yaml` regenerates the vendored components (currently v2.9.6).

## Service URLs

All at `*.romulus.hu` via Traefik + Authelia 2FA:

| Service | URL |
|---------|-----|
| Homepage | `romulus.hu` |
| Traefik | `traefik.romulus.hu` |
| AdGuard | `dns.romulus.hu` |
| Authelia | `auth.romulus.hu` |
| Jellyfin | `jellyfin.romulus.hu` |
| Sonarr / Radarr / Prowlarr / Bazarr / Lidarr | `sonarr.` / `radarr.` / `prowlarr.` / `bazarr.` / `lidarr.romulus.hu` |
| qBittorrent | `qbit.romulus.hu` |
| Jellyseerr | `requests.romulus.hu` |
| Nextcloud | `cloud.romulus.hu` |
| Immich | `photos.romulus.hu` |
| Home Assistant | `home.romulus.hu` |
| Paperless-ngx | `paperless.romulus.hu` |
| Actual Budget | `budget.romulus.hu` |
| Homebox | `homebox.romulus.hu` |
| Grafana | `grafana.romulus.hu` |
| Uptime Kuma | `status.romulus.hu` |
| ntfy | `notify.romulus.hu` |
| Dozzle | `logs.romulus.hu` |
| Speedtest | `speed.romulus.hu` |
| Portainer | `portainer.romulus.hu` |
| TeamSpeak | `teamspeak.romulus.hu` |
| OpenClaw | `ai.romulus.hu` |
| Open WebUI | `chat.romulus.hu` |
| Hydra Trading | `trading.romulus.hu` |

## GPU Sharing

GTX 1650 SUPER (4GB VRAM) shared between:
- **Jellyfin**: NVENC/NVDEC transcoding (~200-500MB/stream)
- **Immich ML**: Face/object recognition (~1-2GB)
- **Ollama**: Hybrid CPU+GPU inference (~1-2GB, tunable via `OLLAMA_NUM_GPU`)

CI runners are CPU-only to prevent VRAM contention.

## Security

LAN + Tailscale only. SSH on port 2222 (key-only). Firewall defaults to DROP. Authelia 2FA on admin services. CrowdSec for threat intelligence. TLS 1.3 + HSTS everywhere. Docker socket proxied read-only. Backups AES-256 encrypted with restic.

## Backup

```bash
sudo /DATA/stacks/scripts/backup.sh           # run backup
restic -r /media/HDD-Storage/backups/restic-repo snapshots  # check
restic restore latest --target /tmp/restore    # restore
```

BTRFS snapshots managed by `scripts/btrfs-snapshot.sh`.
