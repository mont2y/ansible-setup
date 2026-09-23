#!/usr/bin/env bash
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${SETUP_TEST_CHILD:-}" != bitwarden ]]; then
    test_home="$(mktemp -d)"
    trap 'rm -rf "$test_home"' EXIT
    env HOME="$test_home" PATH=/usr/bin:/bin SETUP_TEST_CHILD=bitwarden bash "$0"
    exit
fi
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/bitwarden.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export BW_TEST_DIR="$HOME/mock"
mkdir -p "$BW_TEST_DIR" "$HOME/.local/bin"
ln -s "$ROOT_DIR/tests/helpers/bitwarden-mock.sh" "$HOME/.local/bin/bw"
export PATH="$HOME/.local/bin:$PATH"
export BW_TEST_SCENARIO=''
bitwarden_interactive() { :; }
reset_vault() {
    : > "$BW_TEST_DIR/calls"
    printf '%s\n' "${1:-locked}" > "$BW_TEST_DIR/state"
    unset BW_SESSION
    BW_TEST_SCENARIO=''
}
assert_no_leak() {
    ! grep -q SUPER_SECRET_SENTINEL_12345 "$BW_TEST_DIR/log" || fail 'Secret leaked to logs'
}

for initial in unauthenticated locked unlocked; do
    reset_vault "$initial"
    if [[ "$initial" == unlocked ]]; then export BW_SESSION=SUPER_SECRET_SENTINEL_12345_SESSION; fi
    (
        bitwarden_guard
        BITWARDEN_RELOCK=false
        trap bitwarden_cleanup_session EXIT
        bitwarden_authenticate
        [[ -n "$BW_SESSION" ]] || fail 'No session'
    ) > "$BW_TEST_DIR/log" 2>&1
    assert_no_leak
    grep -qx sync "$BW_TEST_DIR/calls" || fail 'Missing sync'
    if [[ "$initial" == unlocked ]]; then
        ! grep -Eq 'login|unlock|lock' "$BW_TEST_DIR/calls" || fail 'Existing session disturbed'
        [[ "$BW_SESSION" == SUPER_SECRET_SENTINEL_12345_SESSION ]] || fail 'Parent session changed'
    else
        grep -qx lock "$BW_TEST_DIR/calls" || fail 'Missing cleanup lock'
        [[ -z "${BW_SESSION:-}" ]] || fail 'Session escaped subshell'
    fi
done
for scenario in status-failure login-failure unlock-failure sync-failure empty-session; do
    reset_vault
    [[ "$scenario" != login-failure ]] || printf 'unauthenticated\n' > "$BW_TEST_DIR/state"
    BW_TEST_SCENARIO="$scenario"
    if (
        BITWARDEN_RELOCK=false
        trap bitwarden_cleanup_session EXIT
        bitwarden_authenticate
    ) > "$BW_TEST_DIR/log" 2>&1; then fail "Accepted $scenario"; fi
    assert_no_leak
    if [[ "$scenario" == sync-failure || "$scenario" == empty-session ]]; then
        grep -qx lock "$BW_TEST_DIR/calls" || fail 'Failed authentication did not clean up'
    fi
done
reset_vault unlocked
export BW_SESSION=SUPER_SECRET_SENTINEL_12345_SESSION
cat > "$BW_TEST_DIR/items.json" <<'JSON'
[{"name":"Linux Setup - rclone.conf","id":"11111111-1111-1111-1111-111111111111"},
 {"name":"Linux Setup - rclone.conf extra","id":"22222222-2222-2222-2222-222222222222"}]
JSON
cat > "$BW_TEST_DIR/item.json" <<'JSON'
{"type":2,"notes":"SUPER_SECRET_SENTINEL_12345\n\n","fields":[{"name":"api_key","value":"SUPER_SECRET_SENTINEL_12345\n\n"}]}
JSON
[[ "$(bitwarden_find_item_exact 'Linux Setup - rclone.conf')" == 11111111-1111-1111-1111-111111111111 ]] || fail 'Exact match failed'
bitwarden_get_notes 'Linux Setup - rclone.conf' > "$BW_TEST_DIR/value"
printf 'SUPER_SECRET_SENTINEL_12345\n\n' > "$BW_TEST_DIR/expected"
cmp "$BW_TEST_DIR/value" "$BW_TEST_DIR/expected" || fail 'Notes bytes changed'
bitwarden_get_field 'Linux Setup - rclone.conf' api_key > "$BW_TEST_DIR/value"
cmp "$BW_TEST_DIR/value" "$BW_TEST_DIR/expected" || fail 'Field bytes changed'
cp "$BW_TEST_DIR/items.json" "$BW_TEST_DIR/original-items.json"
cp "$BW_TEST_DIR/item.json" "$BW_TEST_DIR/original-item.json"
for scenario in missing duplicate deleted invalid-id malformed list-failure get-failure; do
    cp "$BW_TEST_DIR/original-items.json" "$BW_TEST_DIR/items.json"
    BW_TEST_SCENARIO="$scenario"
    case "$scenario" in
        missing) printf '[]' > "$BW_TEST_DIR/items.json" ;;
        duplicate) jq '.[0:1] + .[0:1]' "$BW_TEST_DIR/original-items.json" > "$BW_TEST_DIR/items.json" ;;
        deleted) jq 'map(.deletedDate = "2026-01-01")' "$BW_TEST_DIR/original-items.json" > "$BW_TEST_DIR/items.json" ;;
        invalid-id) jq 'map(.id = "--help")' "$BW_TEST_DIR/original-items.json" > "$BW_TEST_DIR/items.json" ;;
        malformed) printf 'invalid' > "$BW_TEST_DIR/items.json" ;;
    esac
    if bitwarden_get_notes 'Linux Setup - rclone.conf' > "$BW_TEST_DIR/log" 2>&1; then fail "Accepted $scenario item"; fi
    assert_no_leak
done
BW_TEST_SCENARIO=''
cp "$BW_TEST_DIR/original-items.json" "$BW_TEST_DIR/items.json"
for filter in '.fields=[]' '.fields += .fields' '.fields[0].value=null' '.fields[0].value=""' '.fields[0].value="a\u0000b"'; do
    jq "$filter" "$BW_TEST_DIR/original-item.json" > "$BW_TEST_DIR/item.json"
    if bitwarden_get_field 'Linux Setup - rclone.conf' api_key > "$BW_TEST_DIR/log" 2>&1; then fail 'Invalid field accepted'; fi
    assert_no_leak
done
for filter in '.notes=null' '.notes=""' '.type=1' '.notes="a\u0000b"'; do
    jq "$filter" "$BW_TEST_DIR/original-item.json" > "$BW_TEST_DIR/item.json"
    if bitwarden_get_notes 'Linux Setup - rclone.conf' > "$BW_TEST_DIR/log" 2>&1; then fail 'Invalid notes accepted'; fi
    assert_no_leak
done
cp "$BW_TEST_DIR/original-item.json" "$BW_TEST_DIR/item.json"
if (set -x; bitwarden_guard) > "$BW_TEST_DIR/log" 2>&1; then fail 'Tracing accepted'; fi
assert_no_leak

# Installer selection uses mocks; no package manager or network is invoked.
INSTALL_BITWARDEN_CLI=false
INSTALL_BITWARDEN_DESKTOP=false
source "$ROOT_DIR/files/helpers/install-bitwarden.sh"
[[ ! -e "$BW_TEST_DIR/desktop" ]] || fail 'Disabled desktop installed'
install_many() { :; }
install_flatpak_app() { printf '%s\n' "$1" >> "$BW_TEST_DIR/desktop"; }
sudo() { fail 'Unexpected sudo'; }
npm() { printf '%s\n' "$*" >> "$BW_TEST_DIR/npm"; ln -sf "$ROOT_DIR/tests/helpers/bitwarden-mock.sh" "$HOME/.local/bin/bw"; }
install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1
[[ ! -e "$BW_TEST_DIR/npm" ]] || fail 'Reinstalled existing bw'
rm "$HOME/.local/bin/bw"
BITWARDEN_CLI_INSTALL_METHOD=npm
install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1
grep -qx 'install -g @bitwarden/cli' "$BW_TEST_DIR/npm" || fail 'Wrong npm install'

# Native archive exercises real sha256sum and unzip with a fake executable.
# ZIP containing bw: #!/bin/sh followed by printf "mock-version\\n".
printf '%s' 'UEsDBBQAAAAAAJeLNV2AnqCgIgAAACIAAAACAAAAYncjIS9iaW4vc2gKcHJpbnRmICJtb2NrLXZlcnNpb25cbiIKUEsBAhQDFAAAAAAAl4s1XYCeoKAiAAAAIgAAAAIAAAAAAAAAAAAAAIABAAAAAGJ3UEsFBgAAAAABAAEAMAAAAEIAAAAAAA==' |
    base64 -d > "$BW_TEST_DIR/bw.zip"
native_digest="$(sha256sum "$BW_TEST_DIR/bw.zip")"
native_digest="${native_digest%% *}"
native_scenario=success
native_arch=x86_64
uname() { printf '%s\n' "$native_arch"; }
curl() {
    local url="${*: -3:1}" output="${*: -1}" asset=bw-linux-2026.9.0.zip digest="$native_digest"
    [[ "$native_scenario" != download-failure ]] || return 1
    [[ "$native_arch" != aarch64 ]] || asset=bw-linux-arm64-2026.9.0.zip
    if [[ "$url" == https://api.github.com/* ]]; then
        [[ "$native_scenario" != mismatch ]] || digest="${digest//[a-f0-9]/0}"
        [[ "$native_scenario" != no-digest ]] || digest=missing
        printf '{"tag_name":"cli-v2026.9.0","draft":false,"prerelease":false,"assets":[{"name":"%s","browser_download_url":"https://github.com/bitwarden/clients/releases/download/cli-v2026.9.0/%s","digest":"sha256:%s"}]}' "$asset" "$asset" "$digest" > "$output"
    else
        cp "$BW_TEST_DIR/bw.zip" "$output"
    fi
}
BITWARDEN_CLI_INSTALL_METHOD=native
for native_scenario in mismatch no-digest download-failure success; do
    rm -f "$HOME/.local/bin/bw"
    if install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1; then
        [[ "$native_scenario" == success ]] || fail "Accepted $native_scenario"
        [[ "$(stat -c %a "$HOME/.local/bin/bw")" == 755 ]] || fail 'Wrong executable permissions'
    else
        [[ "$native_scenario" != success ]] || fail 'Native install failed'
        [[ ! -e "$HOME/.local/bin/bw" ]] || fail 'Failed download installed executable'
    fi
done
rm "$HOME/.local/bin/bw"
native_arch=aarch64
install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1 || fail 'ARM64 native install failed'
rm "$HOME/.local/bin/bw"
native_arch=riscv64
if install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1; then fail 'Unsupported architecture accepted'; fi

# Simulate a fresh shell whose NVM exists but has not been sourced.
mkdir -p "$HOME/.nvm"
printf 'BW_TEST_NVM_LOADED=true\n' > "$HOME/.nvm/nvm.sh"
BW_TEST_NVM_LOADED=false
# Invoked by the sourced installer.
# shellcheck disable=SC2329
command() {
    if [[ "${1:-}" == -v && "${2:-}" == npm && "$BW_TEST_NVM_LOADED" == false ]]; then return 1; fi
    builtin command "$@"
}
BITWARDEN_CLI_INSTALL_METHOD=auto
install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1 || fail 'NVM load path failed'
[[ "$BW_TEST_NVM_LOADED" == true ]] || fail 'NVM not loaded'
unset -f command
rm "$HOME/.local/bin/bw"
# Existing system npm must not prevent loading the user's NVM environment.
BW_TEST_NVM_LOADED=false
install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1 || fail 'NVM preference failed'
[[ "$BW_TEST_NVM_LOADED" == true ]] || fail 'Existing npm bypassed NVM'
rm "$HOME/.local/bin/bw"
# Simulate npm and NVM both unavailable, exercising auto's native fallback.
rm "$HOME/.nvm/nvm.sh"
# shellcheck disable=SC2329
command() {
    if [[ "${1:-}" == -v && "${2:-}" == npm ]]; then return 1; fi
    builtin command "$@"
}
native_arch=x86_64
install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1 || fail 'Auto native fallback failed'
rm "$HOME/.local/bin/bw"
BITWARDEN_CLI_INSTALL_METHOD=npm
if install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1; then fail 'Missing npm accepted'; fi
unset -f command
BITWARDEN_CLI_INSTALL_METHOD=invalid
if install_bitwarden_cli > "$BW_TEST_DIR/log" 2>&1; then fail 'Invalid install method accepted'; fi
# Exercise the real entry point: an installation error must reach Ansible.
if INSTALL_BITWARDEN_CLI=true INSTALL_BITWARDEN_DESKTOP=false BITWARDEN_CLI_INSTALL_METHOD=invalid \
    bash "$ROOT_DIR/scripts/install-bitwarden.sh" > "$BW_TEST_DIR/log" 2>&1; then
    fail 'Installer entry point hid CLI installation failure'
fi
grep -q 'Bitwarden CLI installation failed' "$BW_TEST_DIR/log" || fail 'Missing installation failure diagnostic'
INSTALL_BITWARDEN_DESKTOP=true
# Already analyzed above; this second source only exercises the desktop switch.
# shellcheck source=/dev/null
source "$ROOT_DIR/files/helpers/install-bitwarden.sh"
grep -qx com.bitwarden.desktop "$BW_TEST_DIR/desktop" || fail 'Desktop not installed'
printf 'Bitwarden authentication, retrieval, leakage, and installation checks passed.\n'
