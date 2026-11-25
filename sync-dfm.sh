#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TARGET_DIR=/usr/local/bin
ALIAS=/usr/bin/dfm
COMMANDS=(dfm)

fail() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

[[ $# -eq 0 ]] || fail "Usage: sync-dfm.sh (syncs dfm from this directory)"
[[ "$(id -u)" -eq 0 ]] || fail "Run this command as root."

for cmd in "${COMMANDS[@]}"; do
    source="${SCRIPT_DIR}/${cmd}"
    target="${TARGET_DIR}/${cmd}"
    [[ -f "$source" && -r "$source" ]] || fail "Source script not found or unreadable: $source"
    bash -n "$source" || fail "Source script has a Bash syntax error: $source"
    if [[ -L "$target" ]]; then
        fail "${target} is a symlink; refusing to replace it."
    fi
done

if [[ -e "$ALIAS" && ! -L "$ALIAS" ]]; then
    fail "${ALIAS} is not a symlink; refusing to replace it."
fi
if [[ -L "$ALIAS" ]] &&
   [[ "$(readlink -f "$ALIAS" 2>/dev/null || true)" != "${TARGET_DIR}/dfm" ]]; then
    fail "${ALIAS} points somewhere other than ${TARGET_DIR}/dfm."
fi

for cmd in "${COMMANDS[@]}"; do
    source="${SCRIPT_DIR}/${cmd}"
    target="${TARGET_DIR}/${cmd}"
    temporary="$(mktemp "${TARGET_DIR}/.dfm.XXXXXX")"
    trap 'rm -f "$temporary"' EXIT
    install -m 0755 "$source" "$temporary"
    mv -f "$temporary" "$target"
    trap - EXIT
    printf 'Updated %s from %s\n' "$target" "$source"
done

if [[ -L "$ALIAS" ]]; then
    printf 'Verified command alias: %s -> %s\n' "$ALIAS" "${TARGET_DIR}/dfm"
else
    ln -s "${TARGET_DIR}/dfm" "$ALIAS"
fi
