#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/files/helpers/install-bitwarden.sh"
