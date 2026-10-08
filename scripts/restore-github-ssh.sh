#!/usr/bin/env bash
set -Eeuo pipefail
[[ $- != *x* ]] || { printf 'SSH restoration refuses shell tracing\n' >&2; exit 1; }
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/bitwarden.sh"
source "$ROOT_DIR/configs/bitwarden/items.sh"
[[ $EUID -ne 0 ]] || die 'Run SSH restoration as your normal user, never root.'
[[ $# == 0 ]] || die 'Usage: restore-github-ssh.sh (see README for overwrite policy)'
for dependency in python3 ssh-keygen ssh-add ssh-agent; do
    command -v "$dependency" >/dev/null 2>&1 || die "$dependency is required for SSH restoration."
done
case "${GITHUB_SSH_OVERWRITE_EXISTING:-false}" in
    true) warn 'Explicit replacement enabled: differing GitHub identity files will be replaced without backups.' ;;
    false) ;;
    *) die 'GITHUB_SSH_OVERWRITE_EXISTING must be true or false.' ;;
esac
private="$HOME/.ssh/id_ed25519"
public="$HOME/.ssh/id_ed25519.pub"
check_paths() {
    python3 "$ROOT_DIR/lib/github_ssh.py" paths --home "$HOME" --private "$private" --public "$public"
}
check_paths
umask 077
mkdir -p -- "$HOME/.ssh"
chmod 0700 "$HOME/.ssh"
stage=''
BITWARDEN_RELOCK=false
cleanup() {
    [[ -z "$stage" ]] || rm -rf -- "$stage"
    bitwarden_cleanup_session
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
bitwarden_guard
bitwarden_authenticate
stage="$(mktemp -d "$HOME/.ssh/.github-ssh-restore.XXXXXX")"
bitwarden_restore_note_file "$BITWARDEN_GITHUB_SSH_PRIVATE_ITEM" "$stage/private" 0600
bitwarden_restore_note_file "$BITWARDEN_GITHUB_SSH_PUBLIC_ITEM" "$stage/public" 0600
python3 "$ROOT_DIR/lib/github_ssh.py" pair --private "$stage/private" --public "$stage/public" --interactive
# Preflight BOTH files before any promotion. The protected parent prevents other
# accounts racing these checks; concurrent modifications by this user are unsupported.
check_paths
for name in private public; do
    target="${!name}"
    if [[ -e "$target" ]]; then
        comparison=0
        cmp -s -- "$stage/$name" "$target" || comparison=$?
        [[ "$comparison" != 2 ]] || die 'Cannot compare existing SSH file; preserved.'
        if [[ "$comparison" != 0 ]]; then
            [[ "${GITHUB_SSH_OVERWRITE_EXISTING:-false}" == true ]] || die 'Existing SSH key differs; preserved. Use GITHUB_SSH_OVERWRITE_EXISTING=true only for deliberate replacement.'
        fi
    fi
done
# Each promotion is atomic, but the pair is not a filesystem transaction. Publish
# the private file last so a failure publishing the public file leaves it untouched.
for name in public private; do
    target="${!name}"
    mode=0600
    [[ "$name" != public ]] || mode=0644
    if [[ -e "$target" ]] && cmp -s -- "$stage/$name" "$target"; then
        chmod "$mode" "$target"
        continue
    fi
    chmod "$mode" "$stage/$name"
    if [[ -e "$target" ]]; then
        mv -fT -- "$stage/$name" "$target"
    else
        ln -T -- "$stage/$name" "$target"
        rm -f -- "$stage/$name"
    fi
done
ok "GitHub SSH identity installed: $private and $public"
# Finish vault cleanup before starting any long-lived SSH agent process.
rm -rf -- "$stage"
stage=''
bitwarden_cleanup_session
python3 "$ROOT_DIR/lib/github_agent.py" load --home "$HOME" \
    --private "$private" --public "$public" --shell-pid "$PPID"
