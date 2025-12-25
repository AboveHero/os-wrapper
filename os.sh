#!/usr/bin/env bash
set -euo pipefail

RC_FILE="${OS_RC_FILE:-$HOME/openrc}"

# Cache root (per identity subfolders are created later)
CACHE_ROOT="${XDG_CACHE_HOME:-$HOME/.cache}/openstack"

# Refresh a bit before actual expiry (seconds)
SAFETY_MARGIN=60

# Check if credentials are already defined
have_env_creds=0
if [[ -n "${OS_AUTH_URL:-}" && -n "${OS_USERNAME:-}" && -n "${OS_PASSWORD:-}" ]]; then
    if [[ -n "${OS_PROJECT_ID:-}" || -n "${OS_PROJECT_NAME:-}" ]]; then
        have_env_creds=1
    fi
fi

# If credentials not defined, source them, if not possible, exit with error
if [[ $have_env_creds -eq 0 ]]; then
    if [[ -f "$RC_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$RC_FILE"
    else
        echo "No suitable OpenStack credentials in env, and RC file not found: $RC_FILE" >&2
        echo "Either export OS_AUTH_URL/OS_USERNAME/OS_PASSWORD/OS_PROJECT_* or set OS_RC_FILE." >&2
        exit 1
    fi
fi

# Ensure Keystone URL ends with /v3
if [[ "${OS_AUTH_URL}" != *"/v3" && "${OS_AUTH_URL}" != *"/v3/" ]]; then
    OS_AUTH_URL="${OS_AUTH_URL%/}/v3"
    export OS_AUTH_URL
fi

cache_key() {
    printf '%s\0' \
        "${OS_AUTH_URL:-}" \
        "${OS_USERNAME:-}" \
        "${OS_USER_DOMAIN_NAME:-}" \
        "${OS_USER_DOMAIN_ID:-}" \
        "${OS_PROJECT_ID:-}" \
        "${OS_PROJECT_NAME:-}" \
        "${OS_PROJECT_DOMAIN_NAME:-}" \
        "${OS_PROJECT_DOMAIN_ID:-}" \
        "${OS_DOMAIN_ID:-}" \
        "${OS_DOMAIN_NAME:-}"
}

CACHE_KEY=$(cache_key | sha256sum | awk '{print $1}')
CACHE_DIR="${CACHE_ROOT}/${CACHE_KEY}"
mkdir -p "$CACHE_DIR"
TOKEN_FILE="$CACHE_DIR/token"
EXPIRY_FILE="$CACHE_DIR/token_expires"

get_new_token() {
    # Make sure we use normal password/appcred auth for this call
    unset OS_TOKEN OS_AUTH_TYPE

    local tmp
    tmp=$(mktemp)

    if ! openstack token issue -f shell > "$tmp" 2>/dev/null; then
        rm -f "$tmp"
        echo "Unable to issue v3 token via: $OS_AUTH_URL" >&2
        exit 1
    fi

    # This defines: id, expires OR expires_at, etc.
    # shellcheck disable=SC1090
    source "$tmp"
    rm -f "$tmp"

    local _id _expires
    _id="${id:-}"
    _expires="${expires:-${expires_at:-}}"

    if [[ -z "$_id" || -z "$_expires" ]]; then
        echo "Missing id/expires from 'openstack token issue' output." >&2
        exit 1
    fi

    printf '%s\n' "$_id"      > "$TOKEN_FILE"
    printf '%s\n' "$_expires" > "$EXPIRY_FILE"
}

is_token_valid() {
    [[ -f "$TOKEN_FILE" && -f "$EXPIRY_FILE" ]] || return 1

    local now_ts exp_ts exp_raw
    now_ts=$(date -u +%s)
    exp_raw=$(<"$EXPIRY_FILE")

    if ! exp_ts=$(date -u -d "$exp_raw" +%s 2>/dev/null); then
        return 1
    fi

    (( exp_ts - now_ts > SAFETY_MARGIN ))
}

ensure_token() {
    if ! is_token_valid; then
        get_new_token
    fi

    # Reuse cached token via token plugin
    export OS_AUTH_TYPE=token
    export OS_TOKEN
    OS_TOKEN=$(<"$TOKEN_FILE")

    # Workaround OSC+token bug: token plugin must NOT see user_domain_*
    unset OS_USER_DOMAIN_NAME OS_USER_DOMAIN_ID
}

ensure_token

# Delegate to OpenStack CLI with cached token
openstack "$@"
