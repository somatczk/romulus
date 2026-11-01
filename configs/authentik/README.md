# Authentik

Authentik (`authentik` stack: `authentik-server`, `authentik-worker`, `authentik-postgresql`; data in
`${APPDATA}/security/authentik`) at `https://sso.romulus.hu`
guards every admin host (`secure-admin-ak`).

## Forward auth

- `secure-admin-ak` (`configs/traefik/dynamic/middlewares.yml`): crowdsec-bouncer → `strip-auth-headers` (empties
  `Remote-*` and `X-authentik-*` a client may send) → `authentik` (forwardAuth to the embedded outpost) →
  secure-headers.
- Router `authentik-outpost` on `authentik-server` sends `/outpost.goauthentik.io/` on every `*.${DOMAIN}` host to
  Authentik (login callback, sign-out); priority 1000 so it wins over the app's own router.
- Moving a host: add its provider, application and group binding to `applications.yaml`, add the provider to the
  embedded outpost's list there, then switch the router's middleware to `secure-admin-ak@file`.
- doco-cd does not recreate the server and worker for blueprint edits (`cd.doco.deployment.recreate.ignore` on
  `/blueprints/custom`): it syncs a live copy in place and Authentik applies the change from its file watcher, or at the
  hourly rescan. If an edit seems ignored, apply it under Customization → Blueprints.
- The embedded outpost's `authentik_host` must be `https://sso.romulus.hu` (Applications → Outposts). Authentik
  sets it from the first admin visit; the blueprint leaves the outpost config alone.

## OAuth for Hydra's MCP endpoint

- `applications.yaml` defines the `hydra-mcp` OAuth2/OpenID provider and the "Hydra MCP" application (slug
  `hydra-mcp`, no library tile), bound to `admins` and `hydra`. It is not an outpost provider: no forward auth sits in
  front of `trading.${DOMAIN}/mcp`, and Hydra verifies the access tokens itself.
- Public client `hydra-mcp` with PKCE, no secret, allowed the `authorization_code` and `refresh_token` grants. Redirect URIs: `http://localhost:<port>/callback` and
  `http://127.0.0.1:<port>/callback` on any port (Claude Code) and `https://claude.ai/api/mcp/auth_callback`
  (claude.ai custom connectors). Authentik has no dynamic client registration, so clients are given the client id.
- Tokens are RS256-signed with `authentik Self-signed Certificate` (Hydra reads the public keys from the issuer's
  JWKS). Access tokens last 10 minutes, refresh tokens 30 days; scopes openid, profile, email and offline_access.
- Issuer: `https://sso.romulus.hu/application/o/hydra-mcp/`, set on the hydra engine as `HYDRA_MCP__OAUTH_ISSUER`
  (with `HYDRA_MCP__OAUTH_AUDIENCE=hydra-mcp` and `HYDRA_MCP__RESOURCE_URL`). Traefik serves Hydra's RFC 9728
  metadata (`/.well-known/oauth-protected-resource`) on `trading.${DOMAIN}` without forward auth, so clients can find
  the issuer.
- The hydra engine reaches the issuer through Traefik: `extra_hosts` maps `sso.${DOMAIN}` to Traefik's hydra-edge
  address (10.10.13.2), because the public address does not hairpin from containers
  (`.github/tests/hydra-network.py` requires the mapping).
- Connecting Claude Code or claude.ai: hydra's README, "Connecting an MCP client".

## Blueprints

`blueprints/` is mounted read-only at `/blueprints/custom` in the server and the worker. Authentik finds every
`*.yaml` under `/blueprints` (subdirectories included, `.yml` ignored), applies new or changed files and rescans
hourly. Each file is one blueprint and applies atomically.

| File | What |
|------|------|
| `groups.yaml` | `admins` (Authentik superusers) and `hydra`. Membership is assigned in the UI, never on the invitation. |
| `login.yaml` | The default login flow's MFA stage is set to `configure` with the default TOTP setup stage: a user without an MFA device enrolls TOTP at login. Sessions last 4h, or 4h + 30d with "remember me". |
| `enrollment.yaml` | Flow `invitation-enrollment`: invitation → username and password → name and email → user created. No login stage, so the new user then signs in and is forced into TOTP. |
| `recovery.yaml` | Flow `default-recovery-flow`: identify → emailed link → new password. No login stage, so a reset still ends at password + MFA. Set as the default brand's recovery flow and as the "Forgot password?" link on the login page. |
| `applications.yaml` | One `forward_single` proxy provider and application per protected host, bound to a group, and the embedded outpost's provider list (the full set). Hosts: speed, traefik, dns, logs, portainer, prometheus, glances, sonarr, radarr, prowlarr, bazarr, lidarr, qbit → `admins`; trading → `admins` and `hydra`, with a scope mapping that sends `Remote-User` (the Authentik username) to Hydra and `/_next/static/` unauthenticated. Also the `hydra-mcp` OAuth2/OpenID provider for Hydra's MCP endpoint (see below). |

The files that change defaults (`login.yaml`, `recovery.yaml`) first apply the default blueprints they edit. On a
first boot one may still show **Error** under Admin → Customization → Blueprints if it ran before the defaults were
discovered; it retries on the hourly rescan, or apply it from that page.

Authelia's 6h inactivity timeout has no Authentik equivalent: a session ends at its expiry or at logout.

## First run (manual)

1. Before the first deploy, create the data directory for uid 1000 (the image's user; `setup.sh` chowns appdata to
   999:1000, which Authentik cannot write):
   `sudo install -d -o 1000 -g 1000 /media/SSD-Storage/appdata/security/authentik/data`
2. Log in at `https://sso.romulus.hu` as `akadmin` with `AUTHENTIK_BOOTSTRAP_PASSWORD` (1Password
   `romulus-deploy/security`). The bootstrap password is read on the first start only. You enroll TOTP here.
3. Directory → Users: create your own user, add it to `admins`, set a password (or invite yourself, below), log in
   as it, then deactivate `akadmin`.
4. Directory → Invitations: create an invitation with flow `invitation-enrollment` and send the link. After the
   user enrolls, add them to `admins` or `hydra` under Directory → Groups.
5. Recovery: "Forgot password?" on the login page, or Directory → Users → a user → "Send recovery link".

Everyone, the owner included, enrolls TOTP again: Authelia's enrollments do not carry over.
