#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

# Source-tree entry point; addons are implemented inside dfm.
exec "${SCRIPT_DIR}/dfm" addons "$@"
