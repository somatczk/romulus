# Authentik

Authentik (`authentik` stack: `authentik-server`, `authentik-worker`, `authentik-postgresql`; data in
`${APPDATA}/security/authentik`) at `https://sso.romulus.hu`
replaces Authelia in phases. **Phase 1: no route uses it yet**; every admin route is still on Authelia
(`secure-admin`). Authelia stays until phase 4.

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
