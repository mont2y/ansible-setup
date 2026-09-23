#!/usr/bin/env bash
# Stateful fake CLI: records only test data; refuses unknown commands.
# jq expressions passed through update must remain literal.
# shellcheck disable=SC2016
set -euo pipefail
: "${ST_TEST_DIR:?}"
{ printf '%q' "$1"; if (($# > 1)); then printf ' %q' "${@:2}"; fi; printf '\n'; } >> "$ST_TEST_DIR/calls"
[[ -z "${BW_SESSION:-}" ]] || { echo 'Vault session inherited' >&2; exit 1; }
fail() { printf 'Unexpected mock command\n' >&2; exit 1; }
update() {
    jq "$@" "$ST_TEST_DIR/config.json" > "$ST_TEST_DIR/next.json"
    mv "$ST_TEST_DIR/next.json" "$ST_TEST_DIR/config.json"
}
case "$*" in
    '--version') printf 'syncthing v%s\n' "${ST_TEST_VERSION:-2.1.5}"; exit ;;
    'generate --help')
        [[ "${ST_TEST_LEGACY:-false}" != true ]] || printf '%s\n' --no-default-folder
        exit 0 ;;
    generate|'generate --no-default-folder')
        [[ "${ST_TEST_FAILURE:-}" != generate ]] || exit 1
        # Generation preserves an existing ID. No identity files are involved.
        [[ -e "$ST_TEST_DIR/local-id" ]] || printf '%s\n' "$ST_TEST_LOCAL_ID" > "$ST_TEST_DIR/local-id"
        exit 0 ;;
esac
[[ "$1" == cli ]] || fail
shift
if [[ "$*" == 'show system' ]]; then
    count=$(cat "$ST_TEST_DIR/readiness")
    printf '%s\n' "$((count + 1))" > "$ST_TEST_DIR/readiness"
    [[ "${ST_TEST_FAILURE:-}" != timeout ]] && ((count >= ${ST_TEST_READY_AFTER:-0})) || exit 1
    [[ "${ST_TEST_FAILURE:-}" != bad-local ]] || { printf '{"myID":"invalid"}\n'; exit; }
    jq -n --arg id "$(cat "$ST_TEST_DIR/local-id")" '{myID:$id}'
    exit
fi
[[ "$1" == config ]] || fail
shift
if [[ "$*" == dump-json ]]; then
    [[ "${ST_TEST_FAILURE:-}" != snapshot ]] || exit 1
    cat "$ST_TEST_DIR/config.json"
    exit
fi
kind=$1
shift
[[ "$kind" == devices || "$kind" == folders ]] || fail
if [[ "$1" == add ]]; then
    [[ "${ST_TEST_FAILURE:-}" != "$kind-add" ]] || exit 1
    shift
    id='' name='' label='' path='' type=''
    while (($#)); do
        case "$1" in
            --device-id|--id) id=$2 ;;
            --name) name=$2 ;;
            --label) label=$2 ;;
            --path) path=$2 ;;
            --type) type=$2 ;;
            *) fail ;;
        esac
        shift 2
    done
    if [[ "$kind" == devices ]]; then
        update --arg id "$id" --arg name "$name" '.devices += [{deviceID:$id,name:$name,introducer:false,addresses:["dynamic"],autoAcceptFolders:false}]'
    else
        update --arg id "$id" --arg label "$label" --arg path "$path" --arg type "$type" --arg local "$ST_TEST_LOCAL_ID" \
            '.folders += [{id:$id,label:$label,path:$path,type:$type,devices:[{deviceID:$local}],markerName:".stfolder"}]'
    fi
    exit
fi
id=$1
shift
case "$kind $*" in
    'devices introducer set true')
        [[ "${ST_TEST_FAILURE:-}" != introducer ]] || exit 1
        update --arg id "$id" '(.devices[] | select(.deviceID == $id)).introducer = true' ;;
    'folders dump-json') jq --arg id "$id" '.folders[] | select(.id == $id)' "$ST_TEST_DIR/config.json" ;;
    'folders devices add --device-id '*)
        [[ "${ST_TEST_FAILURE:-}" != share ]] || exit 1
        [[ "${ST_TEST_FAILURE:-}" != ignored-share ]] || exit 0
        update --arg id "$id" --arg device "$4" '(.folders[] | select(.id == $id)).devices += [{deviceID:$device}]' ;;
    *) fail ;;
esac
