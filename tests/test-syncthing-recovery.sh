#!/usr/bin/env bash
# Sourced helpers use subshell-local manifest variables, not this test's fixture.
# shellcheck disable=SC2031
set -Eeuo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if [[ "${SETUP_TEST_CHILD:-}" != syncthing ]]; then
    test_home="$(mktemp -d)"
    trap 'rm -rf "$test_home"' EXIT
    env HOME="$test_home" PATH=/usr/bin:/bin SETUP_TEST_CHILD=syncthing bash "$0"
    exit
fi
source "$ROOT_DIR/lib/common.sh"
source "$ROOT_DIR/lib/syncthing-recovery.sh"
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
export ST_TEST_DIR="$HOME/mock"
mkdir -p "$ST_TEST_DIR" "$HOME/bin"
ln -s "$ROOT_DIR/tests/helpers/syncthing-mock.sh" "$HOME/bin/syncthing"
export PATH="$HOME/bin:$PATH"
# Synthetic hashes of test labels, not real device certificates.
export ST_TEST_LOCAL_ID=5KK7T2R-QLEZ5DC-WSZ6VOJ-KWCW5TD-QING35M-6RXHPF6-7IFYQWS-OCBLUQI
primary=J7J6O5A-MIULSGK-ECSEIXM-IFQ5Z23-QAVKH6X-TWBXPKO-GK6AXZU-I6DHUAG
secondary=T6IBNHO-7RPD4Y3-QZT4YXD-YXGD4XA-J3ZRBKN-CFABA26-YTAPUTS-Y5OFLAR
unmanaged=MKEKD2Y-BSW23I6-27QMSDC-6XQMC3F-W3PT2ZN-FL3KMER-7P4HUOM-7JIFWAT
export ST_TEST_FAILURE='' ST_TEST_READY_AFTER=0 ST_TEST_LEGACY=false
SYNCTHING_RECOVERY_WAIT_SECONDS=2
# Direct systemctl queries and sudo are mocked separately.
# shellcheck disable=SC2032
systemctl() {
    printf 'systemctl %s\n' "$*" >> "$ST_TEST_DIR/calls"
    case "$*" in
        '--user show --property=LoadState --value syncthing.service') printf '%s\n' "${test_service_state:-loaded}" ;;
        '--user is-active --quiet syncthing.service') [[ -f "$ST_TEST_DIR/active" ]] ;;
        '--user list-unit-files syncthing.service') printf 'syncthing.service enabled\n' ;;
        '--user enable --now syncthing.service')
            [[ "$ST_TEST_FAILURE" != service ]] || return 1
            touch "$ST_TEST_DIR/active" ;;
        *) fail 'Unexpected service command' ;;
    esac
}
# These operations are never authorized by recovery.
ssh() { fail 'Remote SSH mutation'; }
scp() { fail 'Remote copy'; }
curl() { fail 'Remote HTTP'; }
sudo() { fail 'Unexpected privilege escalation'; }
reset_state() {
    rm -f "$ST_TEST_DIR/active" "$ST_TEST_DIR/local-id"
    printf '0\n' > "$ST_TEST_DIR/readiness"
    printf '{"devices":[],"folders":[]}\n' > "$ST_TEST_DIR/config.json"
    : > "$ST_TEST_DIR/calls"
    ST_TEST_FAILURE=''
    ST_TEST_READY_AFTER=0
    test_service_state=loaded
    SYNCTHING_RECOVERY_ALLOW_PATHS_OUTSIDE_HOME=false
    SYNCTHING_RECOVERY_ALLOW_NONEMPTY_NEW_FOLDERS=false
}
manifest="$ST_TEST_DIR/manifest.json"
jq -n --arg primary "$primary" --arg secondary "$secondary" '{version:1,
 devices:[{alias:"primary",deviceID:$primary,name:"SENTINEL_PRIVATE_NAME",introducer:true},
          {alias:"secondary",deviceID:$secondary,name:"Other peer",introducer:false}],
 folders:[{id:"work",label:"SENTINEL_PRIVATE_LABEL",path:"{HOME}/Sync/with spaces",type:"sendreceive",devices:["primary"]},
          {id:"archive",label:"Archive",path:"{HOME}/Sync/archive",type:"receiveonly",devices:["primary","secondary"]}]}' > "$manifest"
cp "$manifest" "$ST_TEST_DIR/original.json"
no_mutation() { ! grep -Eq 'config (devices|folders).* (add|set) ' "$ST_TEST_DIR/calls" || fail 'Unexpected topology mutation'; }
run_recovery() { syncthing_recovery_apply_manifest "$manifest" > "$ST_TEST_DIR/log" 2>&1; }
reset_state
run_recovery || { cat "$ST_TEST_DIR/log"; fail 'Fresh recovery'; }
[[ -d "$HOME/Sync/with spaces" ]] || fail 'Missing folder'
[[ "$(cat "$ST_TEST_DIR/local-id")" == "$ST_TEST_LOCAL_ID" ]] || fail 'Wrong identity'
grep -qx generate "$ST_TEST_DIR/calls" || fail 'Missing v2 generation'
generation_line=$(grep -n '^generate$' "$ST_TEST_DIR/calls" | cut -d: -f1)
service_line=$(grep -n '^systemctl --user enable' "$ST_TEST_DIR/calls" | cut -d: -f1)
cli_line=$(grep -n '^cli show system' "$ST_TEST_DIR/calls" | head -1 | cut -d: -f1)
((generation_line < service_line && service_line < cli_line)) || fail 'Wrong initialization order'
jq -e --arg primary "$primary" '.devices | any(.deviceID == $primary and .introducer and (.autoAcceptFolders | not))' "$ST_TEST_DIR/config.json" >/dev/null || fail 'Introducer state'
! grep -q SENTINEL_PRIVATE "$ST_TEST_DIR/log" || fail 'Manifest leaked'
! grep -Eq 'key.pem|cert.pem|config.xml|delete|remove|pending' "$ST_TEST_DIR/calls" || fail 'Forbidden operation'
# Only primary gets work; both peers get archive.
[[ "$(grep -c '^syncthing cli config folders work ' "$ST_TEST_DIR/log")" == 1 ]] || fail 'Wrong peer commands'
[[ "$(grep -c '^syncthing cli config folders archive ' "$ST_TEST_DIR/log")" == 2 ]] || fail 'Wrong peer commands'
cp "$ST_TEST_DIR/config.json" "$ST_TEST_DIR/expected.json"
: > "$ST_TEST_DIR/calls"
run_recovery || fail 'Rerun'
no_mutation
cmp "$ST_TEST_DIR/config.json" "$ST_TEST_DIR/expected.json" || fail 'Rerun changed topology'
! grep -q '^generate' "$ST_TEST_DIR/calls" || fail 'Running daemon regenerated'
# Legacy generation preserves the existing local identity.
rm "$ST_TEST_DIR/active"
ST_TEST_LEGACY=true
run_recovery || fail 'Legacy generation'
grep -q '^generate --no-default-folder' "$ST_TEST_DIR/calls" || fail 'Missing legacy flag'
[[ "$(cat "$ST_TEST_DIR/local-id")" == "$ST_TEST_LOCAL_ID" ]] || fail 'Identity replaced'
ST_TEST_LEGACY=false
# Preserve names, labels, extra shares, introducers, unmanaged options and folders.
jq --arg extra "$unmanaged" --arg path "$HOME/unmanaged" '
 .devices[0].name="Local name" | .devices[0].addresses=["tcp://example.invalid:22000"] |
 .devices[1].introducer=true | .folders[0].label="Local label" |
 .folders[0].devices += [{deviceID:$extra}] |
 .devices += [{deviceID:$extra,name:"Unmanaged",introducer:false}] |
 .folders += [{id:"unmanaged",label:"Other",path:$path,type:"sendonly",devices:[]}]' \
 "$ST_TEST_DIR/config.json" > "$ST_TEST_DIR/expected.json"
cp "$ST_TEST_DIR/expected.json" "$ST_TEST_DIR/config.json"
: > "$ST_TEST_DIR/calls"
run_recovery || fail 'Preservation rerun'
no_mutation
cmp "$ST_TEST_DIR/expected.json" "$ST_TEST_DIR/config.json" || fail 'Unmanaged configuration changed'
# Remove one desired share; add it back exactly once.
jq '.folders[0].devices |= .[0:1]' "$ST_TEST_DIR/config.json" > "$ST_TEST_DIR/next.json"
mv "$ST_TEST_DIR/next.json" "$ST_TEST_DIR/config.json"
: > "$ST_TEST_DIR/calls"
run_recovery || fail 'Missing share repair'
[[ "$(grep -c 'devices add --device-id' "$ST_TEST_DIR/calls")" == 1 ]] || fail 'Share added more than once'
# Entire manifest validated before mutations, including a bad final folder.
for filter in 'del(.version)' '.version=2' '.devices={}' '.folders={}' '.devices += [.devices[0]]' \
 '.devices[1].deviceID=.devices[0].deviceID' '.devices[0].deviceID="INVALID"' \
 '.devices[0].deviceID="J7J6O5A-MIULSGA-ECSEIXM-IFQ5Z23-QAVKH6X-TWBXPKO-GK6AXZU-I6DHUAG"' \
 '.devices[0].introducer="true"' '.devices[0].name=""' '.devices[0].name="a\u0000b"' \
 '.devices[0].alias="bad alias"' '.folders += [.folders[0]]' '.folders[1].devices=["unknown"]' \
 '.folders[1].devices=["primary","primary"]' '.folders[1].devices="primary"' '.folders[1].type="invalid"' \
 '.folders[1].path="/"' '.folders[1].path="{HOME}"' '.folders[1].path="{HOME}/../escape"' \
 '.folders[1].path="{HOME}/Sync/../traversal"' '.folders[1].path="{OTHER}/data"' \
 '.folders[1].path="relative"' '.folders[1].path="{HOME}/bad\npath"' '.folders[1].path=42' \
 '.folders[1].id="--help"' '.folders[1].label=""' '.key="forbidden"' '.folders[1].path=.folders[0].path'; do
    reset_state
    jq "$filter" "$ST_TEST_DIR/original.json" > "$manifest"
    if run_recovery; then fail "Invalid manifest accepted: $filter"; fi
    no_mutation
done
reset_state
jq --arg local "$ST_TEST_LOCAL_ID" '.devices[0].deviceID=$local' "$ST_TEST_DIR/original.json" > "$manifest"
if run_recovery; then fail 'Local ID accepted as peer'; fi
no_mutation
printf '{}\n{}\n' > "$manifest"
if run_recovery; then fail 'Multiple JSON documents accepted'; fi
printf 'not JSON' > "$manifest"
if run_recovery; then fail 'Malformed JSON accepted'; fi
cp "$ST_TEST_DIR/original.json" "$manifest"
# Non-empty safety, external paths, symlink escape, and non-directory targets.
reset_state
printf 'keep me' > "$HOME/Sync/archive/keep"
if run_recovery; then fail 'Non-empty target accepted'; fi
no_mutation
[[ "$(cat "$HOME/Sync/archive/keep")" == 'keep me' ]] || fail 'Local files modified'
SYNCTHING_RECOVERY_ALLOW_NONEMPTY_NEW_FOLDERS=true
run_recovery || fail 'Non-empty opt-in'
rm "$HOME/Sync/archive/keep"
external=$(mktemp -d)
trap 'rm -rf "$external"' EXIT
for target in "$external/data" "$HOME" /; do
    reset_state
    jq --arg path "$target" '.folders[0].path=$path' "$ST_TEST_DIR/original.json" > "$manifest"
    if run_recovery; then fail 'Unsafe target accepted'; fi
    no_mutation
done
jq --arg path "$external/data" '.folders[0].path=$path' "$ST_TEST_DIR/original.json" > "$manifest"
SYNCTHING_RECOVERY_ALLOW_PATHS_OUTSIDE_HOME=true
run_recovery || fail 'External opt-in'
ln -s "$external" "$HOME/escape"
reset_state
jq '.folders[0].path="{HOME}/escape/data"' "$ST_TEST_DIR/original.json" > "$manifest"
if run_recovery; then fail 'Symlink escape'; fi
no_mutation
printf data > "$HOME/not-directory"
jq '.folders[0].path="{HOME}/not-directory"' "$ST_TEST_DIR/original.json" > "$manifest"
if run_recovery; then fail 'File target'; fi
no_mutation
# Existing path/type conflicts fail before adding a missing peer.
for property in path type; do
    reset_state
    cp "$ST_TEST_DIR/original.json" "$manifest"
    run_recovery || fail 'Conflict setup'
    jq --arg property "$property" '.devices=[] | .folders[1][$property]="different"' "$ST_TEST_DIR/config.json" > "$ST_TEST_DIR/next.json"
    mv "$ST_TEST_DIR/next.json" "$ST_TEST_DIR/config.json"
    cp "$ST_TEST_DIR/config.json" "$ST_TEST_DIR/expected.json"
    : > "$ST_TEST_DIR/calls"
    if run_recovery; then fail 'Existing conflict accepted'; fi
    no_mutation
    cmp "$ST_TEST_DIR/config.json" "$ST_TEST_DIR/expected.json" || fail 'Conflict changed config'
done
# Bounded readiness and service/CLI failures; never report false success.
for failure in timeout bad-local snapshot generate service devices-add folders-add introducer share ignored-share; do
    reset_state
    ST_TEST_FAILURE="$failure"
    if run_recovery; then fail "Failure ignored: $failure"; fi
    case "$failure" in timeout|bad-local|snapshot|generate|service) no_mutation ;; esac
    ! grep -q 'Trusted peers configured:' "$ST_TEST_DIR/log" || fail 'False success summary'
done
reset_state
ST_TEST_READY_AFTER=1
run_recovery || fail 'Readiness retry'
reset_state
test_service_state=not-found
if run_recovery; then fail 'Missing unit accepted'; fi
no_mutation
reset_state
export ST_TEST_VERSION=3.0.0
if run_recovery; then fail 'Unknown generation version accepted'; fi
unset ST_TEST_VERSION
no_mutation
for wait_seconds in 0 -1 invalid 99999; do
    SYNCTHING_RECOVERY_WAIT_SECONDS="$wait_seconds"
    if syncthing_recovery_wait_ready > "$ST_TEST_DIR/log" 2>&1; then fail 'Invalid timeout accepted'; fi
done
SYNCTHING_RECOVERY_WAIT_SECONDS=2
# Missing dependencies fail before generation or topology writes.
for missing in syncthing jq realpath timeout; do
    reset_state
    if (
        # shellcheck disable=SC2329
        command() {
            if [[ "${1:-}" == -v && "${2:-}" == "$missing" ]]; then return 1; fi
            builtin command "$@"
        }
        run_recovery
    ); then fail 'Missing dependency accepted'; fi
    [[ ! -s "$ST_TEST_DIR/calls" ]] || fail 'Missing dependency caused operations'
done
# Peer command output preserves shell arguments, including hostile hostnames.
# Literal shell syntax is test data; the recorder is invoked through eval.
# shellcheck disable=SC2016,SC2329
(
    hostname() { printf '%s\n' 'host;$(touch SHOULD_NOT_EXIST)'; }
    syncthing_recovery_print_peer_commands "$ST_TEST_DIR/original.json" "$ST_TEST_LOCAL_ID" > "$ST_TEST_DIR/peer-commands"
    # Evaluate only generated commands against a recorder, never a real CLI.
    syncthing() { printf '%s\n' "${*: -1}" >> "$ST_TEST_DIR/peer-arguments"; }
    while IFS= read -r generated; do
        [[ "$generated" != syncthing\ cli* ]] || eval "$generated"
    done < "$ST_TEST_DIR/peer-commands"
    grep -Fxq 'host;$(touch SHOULD_NOT_EXIST)' "$ST_TEST_DIR/peer-arguments" || fail 'Unsafe peer command quoting'
    [[ ! -e SHOULD_NOT_EXIST ]] || fail 'Peer command injection'
)
# Guard the implementation against introducing direct identity/config access.
if grep -Eq '(https-)?(key|cert)\.pem|config\.xml' "$ROOT_DIR/lib/syncthing-recovery.sh"; then
    fail 'Recovery must not access identity/config files directly'
fi
# Every supported folder type is propagated unchanged.
for type in sendreceive sendonly receiveonly receiveencrypted; do
    reset_state
    jq --arg type "$type" '.folders[0].type=$type' "$ST_TEST_DIR/original.json" > "$manifest"
    run_recovery || fail "Folder type $type"
    jq -e --arg type "$type" '.folders[0].type == $type' "$ST_TEST_DIR/config.json" >/dev/null || fail 'Wrong type'
done
printf 'Syncthing schema, identity, readiness, path safety, additive recovery, and rerun checks passed.\n'
