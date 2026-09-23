#!/usr/bin/env bash
# Modules are deliberately re-sourced to exercise their settings gates.
# shellcheck disable=SC2218
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${SETUP_TEST_CHILD:-}" != secrets ]]; then
    test_home="$(mktemp -d)"
    trap 'rm -rf "$test_home"' EXIT
    env HOME="$test_home" SETUP_TEST_CHILD=secrets bash "$0"
    exit
fi
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/bitwarden.sh"
RESTORE_BITWARDEN_SECRETS=false
RESTORE_SYNCTHING_FROM_BITWARDEN=false
source "$ROOT_DIR/files/helpers/restore-module.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export BW_TEST_DIR="$HOME/mock"
mkdir -p "$BW_TEST_DIR" "$HOME/.local/bin"
ln -s "$ROOT_DIR/tests/helpers/bitwarden-mock.sh" "$HOME/.local/bin/bw"
export PATH="$HOME/.local/bin:$PATH"
export BW_SESSION=SUPER_SECRET_SENTINEL_12345_SESSION
export BW_TEST_SCENARIO=''
printf 'unlocked\n' > "$BW_TEST_DIR/state"
printf '[{"name":"Linux Setup - rclone.conf","id":"11111111-1111-1111-1111-111111111111"}]' > "$BW_TEST_DIR/items.json"
cat > "$BW_TEST_DIR/item.json" <<'JSON'
{"type":2,"notes":"[b2]\nkey = SUPER_SECRET_SENTINEL_12345\n\n","fields":[{"name":"api_key","value":"SUPER_SECRET_SENTINEL_12345\n\n"}]}
JSON
cp "$BW_TEST_DIR/item.json" "$BW_TEST_DIR/original-item.json"
printf '[b2]\nkey = SUPER_SECRET_SENTINEL_12345\n\n' > "$BW_TEST_DIR/expected"
secret_destination="$HOME/.config/rclone/rclone.conf"
assert_no_leak() {
    ! grep -q SUPER_SECRET_SENTINEL_12345 "$BW_TEST_DIR/log" || fail 'Secret/session leaked to logs'
}
assert_no_temporary() {
    [[ -z "$(find "$HOME/.config" -name '.bitwarden-restore.*' -print)" ]] || fail 'Secret temporary file left behind'
}
RESTORE_RCLONE_FROM_BITWARDEN=true
restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1 || fail 'Initial restore failed'
cmp "$secret_destination" "$BW_TEST_DIR/expected" || fail 'Restored bytes differ'
[[ "$(stat -c %a "$secret_destination")" == 600 ]] || fail 'Wrong mode'
assert_no_leak
assert_no_temporary
inode="$(stat -c %i "$secret_destination")"
chmod 0644 "$secret_destination"
restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1 || fail 'Identical restore failed'
[[ "$(stat -c %i "$secret_destination")" == "$inode" ]] || fail 'Identical file replaced'
[[ "$(stat -c %a "$secret_destination")" == 600 ]] || fail 'Existing mode not repaired'

printf 'local contents\n' > "$secret_destination"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Conflict reported as restored'; fi
[[ "$(cat "$secret_destination")" == 'local contents' ]] || fail 'Existing file overwritten'
assert_no_leak
assert_no_temporary
BITWARDEN_OVERWRITE_EXISTING_SECRETS=true
restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1 || fail 'Overwrite failed'
cmp "$secret_destination" "$BW_TEST_DIR/expected" || fail 'Overwrite contents differ'
[[ "$(stat -c %i "$secret_destination")" != "$inode" ]] || fail 'Overwrite was not replacement'
[[ -z "$(find "$HOME/.config" -name '*backup*' -print)" ]] || fail 'Plaintext backup created'

jq '.notes=""' "$BW_TEST_DIR/original-item.json" > "$BW_TEST_DIR/item.json"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Empty note accepted'; fi
cmp "$secret_destination" "$BW_TEST_DIR/expected" || fail 'Empty note destroyed existing file'
assert_no_temporary
cp "$BW_TEST_DIR/original-item.json" "$BW_TEST_DIR/item.json"

# Unsafe destination types and parents must never change another file.
mv "$secret_destination" "$BW_TEST_DIR/original"
ln -s "$BW_TEST_DIR/original" "$secret_destination"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Symlink accepted'; fi
rm "$secret_destination"
ln "$BW_TEST_DIR/original" "$secret_destination"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Hard link accepted'; fi
rm "$secret_destination"
mkdir "$secret_destination"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Directory destination accepted'; fi
rmdir "$secret_destination"
mv "$BW_TEST_DIR/original" "$secret_destination"
mv "$HOME/.config/rclone" "$HOME/other-rclone"
ln -s "$HOME/other-rclone" "$HOME/.config/rclone"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Symlink parent accepted'; fi
rm "$HOME/.config/rclone"
mv "$HOME/other-rclone" "$HOME/.config/rclone"
chmod 0777 "$HOME/.config/rclone"
if restore_bitwarden_secrets > "$BW_TEST_DIR/log" 2>&1; then fail 'Unsafe directory permissions accepted'; fi
chmod 0700 "$HOME/.config/rclone"

# Failed writes and signals remove staged plaintext without touching destination.
if (
    # Invoked by the sourced restoration helper.
    # shellcheck disable=SC2329
    mv() { return 1; }
    printf 'local contents\n' > "$secret_destination"
    restore_bitwarden_secrets
) > "$BW_TEST_DIR/log" 2>&1; then fail 'Rename failure ignored'; fi
assert_no_temporary
if (
    bitwarden_get_notes() { printf 'SUPER_SECRET_SENTINEL_12345'; kill -TERM "$BASHPID"; }
    bitwarden_restore_note_file 'Linux Setup - rclone.conf' "$secret_destination" 0600
) > "$BW_TEST_DIR/log" 2>&1; then fail 'Signal ignored'; fi
assert_no_temporary
assert_no_leak

# Installer failure policy and disabled gates.
RESTORE_BITWARDEN_SECRETS=true
BITWARDEN_SECRETS_REQUIRED=false
BW_TEST_SCENARIO=sync-failure
source "$ROOT_DIR/files/helpers/restore-module.sh" > "$BW_TEST_DIR/log" 2>&1 || fail 'Optional failure stopped installer'
# This override must stay local to the fatal-policy test.
# shellcheck disable=SC2030
if (BITWARDEN_SECRETS_REQUIRED=true; source "$ROOT_DIR/files/helpers/restore-module.sh") > "$BW_TEST_DIR/log" 2>&1; then fail 'Required failure ignored'; fi
BW_TEST_SCENARIO=''
: > "$BW_TEST_DIR/calls"
RESTORE_BITWARDEN_SECRETS=false
source "$ROOT_DIR/files/helpers/restore-module.sh"
[[ ! -s "$BW_TEST_DIR/calls" ]] || fail 'Disabled module accessed vault'
RESTORE_RCLONE_FROM_BITWARDEN=false
restore_bitwarden_secrets
[[ ! -s "$BW_TEST_DIR/calls" ]] || fail 'Disabled rclone accessed vault'
RESTORE_RCLONE_FROM_BITWARDEN=true
if (set -x; restore_bitwarden_secrets) > "$BW_TEST_DIR/log" 2>&1; then fail 'Tracing allowed'
fi
assert_no_leak
[[ ! -s "$BW_TEST_DIR/calls" ]] || fail 'Tracing accessed vault'
if (
    # Invoked inside the sourced library.
    # shellcheck disable=SC2329
    command() { if [[ "$1" == -v && "$2" == jq ]]; then return 1; fi; builtin command "$@"; }
    restore_bitwarden_secrets
) > "$BW_TEST_DIR/log" 2>&1; then fail 'Missing jq accepted'; fi
if (
    # shellcheck disable=SC2329
    bitwarden_cli_available() { return 1; }
    restore_bitwarden_secrets
) > "$BW_TEST_DIR/log" 2>&1; then fail 'Missing bw accepted'; fi

# Wrapper launches a real child. It checks the secret without displaying it.
cat > "$BW_TEST_DIR/child" <<'CHILD'
#!/usr/bin/env bash
[[ "$OPENAI_API_KEY" == $'SUPER_SECRET_SENTINEL_12345\n\n' ]] || exit 90
[[ -z "${BW_SESSION:-}${BW_CLIENTSECRET:-}${BW_PASSWORD:-}" ]] || exit 91
[[ "$1" == 'argument with spaces' && "$2" == '--literal' ]] || exit 92
exit "${BW_TEST_CHILD_STATUS:-0}"
CHILD
chmod +x "$BW_TEST_DIR/child"
wrapper="$ROOT_DIR/scripts/with-bitwarden-secret"
for child_status in 0 7 127; do
    actual=0
    BW_TEST_CHILD_STATUS="$child_status" "$wrapper" 'Linux Setup - rclone.conf' api_key OPENAI_API_KEY -- "$BW_TEST_DIR/child" 'argument with spaces' --literal > "$BW_TEST_DIR/log" 2>&1 || actual=$?
    [[ "$actual" == "$child_status" ]] || fail "Child status $child_status became $actual"
    assert_no_leak
    [[ -z "${OPENAI_API_KEY:-}" && "$BW_SESSION" == SUPER_SECRET_SENTINEL_12345_SESSION ]] || fail 'Parent environment changed'
done
for invalid in 1BAD 'BAD-NAME' 'X[0]' BW_SESSION BASH_ENV PATH __bw_value LD_PRELOAD; do
    if "$wrapper" 'Linux Setup - rclone.conf' api_key "$invalid" -- true > "$BW_TEST_DIR/log" 2>&1; then fail 'Unsafe variable accepted'; fi
    assert_no_leak
done
if "$wrapper" > "$BW_TEST_DIR/log" 2>&1; then fail 'Missing arguments accepted'; fi
if "$wrapper" '' api_key KEY -- true > "$BW_TEST_DIR/log" 2>&1; then fail 'Empty item accepted'; fi
if "$wrapper" 'Linux Setup - rclone.conf' absent KEY -- true > "$BW_TEST_DIR/log" 2>&1; then fail 'Missing field accepted'; fi
if bash -x "$wrapper" 'Linux Setup - rclone.conf' api_key OPENAI_API_KEY -- true > "$BW_TEST_DIR/log" 2>&1; then fail 'Wrapper tracing accepted'; fi
assert_no_leak
# Noninteractive locked vaults must fail promptly without prompting or running child.
printf 'locked\n' > "$BW_TEST_DIR/state"
if "$wrapper" 'Linux Setup - rclone.conf' api_key OPENAI_API_KEY -- true < /dev/null > "$BW_TEST_DIR/log" 2>&1; then fail 'Noninteractive unlock accepted'; fi
grep -q 'interactive terminal' "$BW_TEST_DIR/log" || fail 'Missing terminal guidance'
assert_no_leak
if command -v script >/dev/null 2>&1; then
    # A pseudo-terminal exercises the real interactive gate without a real vault.
    for scenario in success get-failure; do
        printf 'locked\n' > "$BW_TEST_DIR/state"
        : > "$BW_TEST_DIR/calls"
        BW_TEST_SCENARIO="$scenario"
        actual=0
        # Expand these variables only in the shell created by script.
        # shellcheck disable=SC2016
        BW_TEST_WRAPPER="$wrapper" BW_TEST_CHILD_STATUS=7 script -q -e -c \
            'exec "$BW_TEST_WRAPPER" "Linux Setup - rclone.conf" api_key OPENAI_API_KEY -- "$BW_TEST_DIR/child" "argument with spaces" --literal' \
            /dev/null < /dev/null > "$BW_TEST_DIR/log" 2>&1 || actual=$?
        if [[ "$scenario" == success ]]; then
            [[ "$actual" == 7 ]] || fail 'Interactive child status lost'
        else
            [[ "$actual" == 1 ]] || fail 'Interactive retrieval failure ignored'
        fi
        grep -qx unlock "$BW_TEST_DIR/calls" || fail 'Interactive wrapper did not unlock'
        grep -qx lock "$BW_TEST_DIR/calls" || fail 'Interactive wrapper did not clean up'
        [[ "$(cat "$BW_TEST_DIR/state")" == locked ]] || fail 'Wrapper left owned session unlocked'
        assert_no_leak
    done
fi
BW_TEST_SCENARIO=''
printf 'unlocked\n' > "$BW_TEST_DIR/state"
rm "$secret_destination"
if [[ $EUID -ne 0 ]]; then
    "$ROOT_DIR/scripts/restore-secrets.sh" > "$BW_TEST_DIR/log" 2>&1 || fail 'Standalone restore failed'
    cmp "$secret_destination" "$BW_TEST_DIR/expected" || fail 'Standalone did not restore'
    assert_no_leak
fi
printf 'Secret restoration, permissions, cleanup, policy, and process injection checks passed.\n'
