#!/usr/bin/env bash
# Sourced by the host scripts: loads stacks/host.env, then exports the named secrets
# from the romulus-deploy vault, e.g. `source lib/env.sh RESTIC_PASSWORD`.
# Secrets need root (the service account token is root-only) and the op CLI.
# Pass `--` when no secrets are needed: a bare `source` hands over the caller's own
# arguments (e.g. `btrfs-snapshot.sh ssd`), which would be read as secret names.
_repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
set -a
# shellcheck source=../../stacks/host.env
source "${_repo}/stacks/host.env"
set +a

[[ ${1:-} == -- ]] && shift
if (( $# )); then
    declare -A _item=(
        [TELEGRAM_BOT_TOKEN]=shared [TELEGRAM_CHAT_ID]=shared
        [RESTIC_PASSWORD]=backup [TEAMSPEAK_DB_PASSWORD]=utilities
    )
    # a vault outage must not fail a backup silently
    _fail() {
        echo "env.sh: $1" >&2
        curl -s --max-time 10 -H "Title: $(basename "$0") cannot start" -H "Tags: warning" \
            -d "$1" "https://notify.${DOMAIN}/alerts" >/dev/null || true
        exit 1
    }
    OP_SERVICE_ACCOUNT_TOKEN="$(cat /DATA/doco-cd/op-token)" || _fail "cannot read the 1Password token"
    export OP_SERVICE_ACCOUNT_TOKEN
    for _name in "$@"; do
        [[ -n "${_item[$_name]:-}" ]] || _fail "no vault item mapped for $_name"
        _value="$(op read "op://romulus-deploy/${_item[$_name]}/${_name}")" || _fail "1Password read failed for $_name"
        export "$_name=$_value"
    done
    unset -f _fail
    unset _item _name _value OP_SERVICE_ACCOUNT_TOKEN
fi
unset _repo
