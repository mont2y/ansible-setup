#!/usr/bin/env bash
set -Eeuo pipefail
[[ $- != *x* ]] || { printf 'Secret restoration refuses tracing\n' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT_DIR
source "$ROOT_DIR/lib/common.sh"
# All restore policy and validation are preserved from the source repository.
source "$ROOT_DIR/files/helpers/restore-module.sh"
