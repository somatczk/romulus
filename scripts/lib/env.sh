#!/usr/bin/env bash
# Sourced by the host scripts: loads stacks/host.env, then exports the named secrets
# from the romulus-deploy vault, e.g. `source lib/env.sh DOMAIN RESTIC_PASSWORD`.
# Needs root (the service account token is root-only) and the op CLI.
_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
# shellcheck source=../../stacks/host.env
source "${_repo}/stacks/host.env"
set +a

declare -A _item=(
    [DOMAIN]=shared [NTFY_BASE_URL]=shared [TELEGRAM_BOT_TOKEN]=shared [TELEGRAM_CHAT_ID]=shared
    [RESTIC_PASSWORD]=backup [TEAMSPEAK_DB_PASSWORD]=utilities
)
OP_SERVICE_ACCOUNT_TOKEN="$(cat /DATA/doco-cd/op-token)"
export OP_SERVICE_ACCOUNT_TOKEN
for _name in "$@"; do
    [[ -n "${_item[$_name]:-}" ]] || { echo "env.sh: no vault item mapped for $_name" >&2; exit 1; }
    _value="$(op read "op://romulus-deploy/${_item[$_name]}/${_name}")" || { echo "env.sh: cannot read $_name" >&2; exit 1; }
    export "$_name=$_value"
done
unset _repo _item _name _value OP_SERVICE_ACCOUNT_TOKEN
