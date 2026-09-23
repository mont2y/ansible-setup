#!/usr/bin/env bash
# Syncthing owns its identity/configuration. Use its CLI only, never identity files.

syncthing_recovery_error() { warn "Syncthing recovery: $*"; return 1; }

syncthing_recovery_cli() (
    # The CLI does not need the vault session, nor should it inherit it.
    unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD
    timeout 15s syncthing cli "$@" 2>/dev/null
)

syncthing_recovery_prepare() (
    local help version state
    unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD
    command -v syncthing >/dev/null 2>&1 || { syncthing_recovery_error 'syncthing is unavailable'; return 1; }
    state="$(systemctl --user show --property=LoadState --value syncthing.service 2>/dev/null)" || return 1
    [[ "$state" == loaded ]] || { syncthing_recovery_error 'syncthing.service is unavailable'; return 1; }
    # Do not rewrite the on-disk configuration while the daemon is running.
    if ! systemctl --user is-active --quiet syncthing.service 2>/dev/null; then
        help="$(syncthing generate --help 2>/dev/null)" || return 1
        if [[ "$help" == *--no-default-folder* ]]; then
            syncthing generate --no-default-folder >/dev/null 2>&1 || return 1
        else
            version="$(syncthing --version 2>/dev/null)" || return 1
            # 2.x removed automatic default folders and the old flag. Unknown
            # versions fail closed rather than starting with an unwanted folder.
            [[ "$version" =~ ^syncthing\ v2\. ]] || { syncthing_recovery_error 'unsupported generation CLI'; return 1; }
            syncthing generate >/dev/null 2>&1 || return 1
        fi
    fi
    systemctl --user enable --now syncthing.service >/dev/null 2>&1 ||
        { syncthing_recovery_error 'could not enable/start syncthing.service'; return 1; }
)

syncthing_recovery_wait_ready() {
    local wait_seconds="${SYNCTHING_RECOVERY_WAIT_SECONDS:-30}" deadline remaining system
    if [[ ! "$wait_seconds" =~ ^[0-9]{1,4}$ ]] || ((10#$wait_seconds < 1 || 10#$wait_seconds > 3600)); then
        syncthing_recovery_error 'WAIT_SECONDS must be between 1 and 3600'; return 1
    fi
    deadline=$((SECONDS + 10#$wait_seconds))
    while ((SECONDS < deadline)); do
        remaining=$((deadline - SECONDS))
        if system="$(
            unset BW_SESSION BW_CLIENTID BW_CLIENTSECRET BW_PASSWORD
            timeout "${remaining}s" syncthing cli show system 2>/dev/null
        )" && jq -e -L "$ROOT_DIR/lib" --arg local_id '' 'include "syncthing-recovery"; .myID | device_id' <<< "$system" >/dev/null 2>&1; then
            jq -r '.myID' <<< "$system"
            return 0
        fi
        ((SECONDS < deadline)) && sleep 1
    done
    syncthing_recovery_error 'service readiness timed out; no topology changes made'
}

syncthing_recovery_resolve_path() {
    local path="$1" home_path resolved parent
    [[ "$path" != *$'\n'* && "$path" != *$'\r'* ]] || return 1
    if [[ "$path" == '{HOME}/'* ]]; then path="$HOME/${path#\{HOME\}/}"; fi
    [[ "$path" == /* && "$path" != *'{'* && "$path" != *'}'* && "$path" != *'$'* ]] || return 1
    # Reject traversal explicitly; realpath also resolves symlinks to enforce the
    # boundary for existing parents, including links to outside HOME.
    [[ "/${path#/}/" != *'/../'* && "/${path#/}/" != *'/./'* ]] || return 1
    IFS= read -r -d '' home_path < <(realpath -ez -- "$HOME" 2>/dev/null) || return 1
    IFS= read -r -d '' resolved < <(realpath -mz -- "$path" 2>/dev/null) || return 1
    [[ ! "$resolved" =~ [[:cntrl:]] ]] || return 1
    [[ "$resolved" != / && "$resolved" != "$home_path" ]] || return 1
    if [[ "${SYNCTHING_RECOVERY_ALLOW_PATHS_OUTSIDE_HOME:-false}" != true ]]; then
        [[ "$resolved" == "$home_path/"* ]] || return 1
    fi
    [[ ! -e "$resolved" || -d "$resolved" ]] || return 1
    parent="$resolved"
    while [[ ! -e "$parent" ]]; do parent="$(dirname -- "$parent")"; done
    [[ -d "$parent" && -x "$parent" && -w "$parent" ]] || return 1
    printf '%s\n' "$resolved"
}

syncthing_recovery_validate_manifest() {
    local manifest="$1" local_id="$2"
    # Slurp also rejects multiple JSON documents. Diagnostics must not quote data.
    jq -e -s -L "$ROOT_DIR/lib" --arg local_id "$local_id" \
        'include "syncthing-recovery"; length == 1 and (.[0] | manifest)' "$manifest" >/dev/null 2>&1 ||
        { syncthing_recovery_error 'invalid recovery manifest (schema, IDs, aliases, or types)'; return 1; }
}

syncthing_recovery_snapshot() {
    # Filter out GUI/API credentials and unrelated settings immediately. Never
    # print the full configuration or persist it as a recovery artifact.
    syncthing_recovery_cli config dump-json |
        jq -ce '{devices: [.devices[] | {deviceID,name,introducer}],
            folders: [.folders[] | {id,label,path,type,devices: [.devices[] | {deviceID}]}]}' 2>/dev/null
}

syncthing_recovery_check_folder() {
    local folder="$1" snapshot="$2" id path current current_path entry
    id="$(jq -r .id <<< "$folder")" || return 1
    path="$(syncthing_recovery_resolve_path "$(jq -r .path <<< "$folder")")" ||
        { syncthing_recovery_error 'unsafe folder path'; return 1; }
    current="$(jq -c --arg id "$id" '.folders[] | select(.id == $id)' <<< "$snapshot")" || return 1
    if [[ -n "$current" ]]; then
        current_path="$(realpath -m -- "$(jq -r .path <<< "$current")")" || return 1
        [[ "$current_path" == "$path" && "$(jq -r .type <<< "$current")" == "$(jq -r .type <<< "$folder")" ]] ||
            { syncthing_recovery_error 'existing folder path/type conflict; preserved'; return 1; }
    elif [[ -d "$path" && "${SYNCTHING_RECOVERY_ALLOW_NONEMPTY_NEW_FOLDERS:-false}" != true ]]; then
        entry="$(find "$path" -mindepth 1 -maxdepth 1 -print -quit 2>/dev/null)" || return 1
        [[ -z "$entry" ]] || { syncthing_recovery_error 'new folder target is non-empty; preserved'; return 1; }
    fi
    printf '%s\n' "$path"
}

syncthing_recovery_apply_device() {
    local device="$1" snapshot="$2" id name current
    id="$(jq -r .deviceID <<< "$device")"
    name="$(jq -r .name <<< "$device")"
    current="$(jq -c --arg id "$id" '.devices[] | select(.deviceID == $id)' <<< "$snapshot")" || return 1
    if [[ -z "$current" ]]; then
        syncthing_recovery_cli config devices add --device-id "$id" --name "$name" >/dev/null || return 1
    elif [[ "$(jq -r .name <<< "$current")" != "$name" ]]; then
        log 'Syncthing: keeping existing peer name'
    fi
    if [[ "$(jq -r .introducer <<< "$device")" == true &&
          ( -z "$current" || "$(jq -r .introducer <<< "$current")" != true ) ]]; then
        syncthing_recovery_cli config devices "$id" introducer set true >/dev/null || return 1
    fi
}

syncthing_recovery_apply_shares() {
    local folder="$1" manifest="$2" current="$3" alias id folder_id
    folder_id="$(jq -r .id <<< "$folder")"
    while IFS= read -r alias; do
        id="$(jq -r --arg alias "$alias" '.devices[] | select(.alias == $alias) | .deviceID' "$manifest")" || return 1
        if ! jq -e --arg id "$id" '.devices | any(.deviceID == $id)' <<< "$current" >/dev/null; then
            syncthing_recovery_cli config folders "$folder_id" devices add --device-id "$id" >/dev/null || return 1
        fi
    done < <(jq -r '.devices[]' <<< "$folder")
}

syncthing_recovery_apply_folder() {
    local folder="$1" manifest="$2" snapshot="$3" path id current
    path="$(syncthing_recovery_check_folder "$folder" "$snapshot")" || return 1
    id="$(jq -r .id <<< "$folder")"
    current="$(jq -c --arg id "$id" '.folders[] | select(.id == $id)' <<< "$snapshot")" || return 1
    if [[ -z "$current" ]]; then
        mkdir -p -- "$path" || return 1
        syncthing_recovery_cli config folders add --id "$id" \
            --label "$(jq -r .label <<< "$folder")" --path "$path" --type "$(jq -r .type <<< "$folder")" >/dev/null || return 1
        current="$(syncthing_recovery_cli config folders "$id" dump-json)" || return 1
    elif [[ "$(jq -r .label <<< "$current")" != "$(jq -r .label <<< "$folder")" ]]; then
        log 'Syncthing: keeping existing folder label'
    fi
    syncthing_recovery_apply_shares "$folder" "$manifest" "$current"
}

syncthing_recovery_print_peer_commands() {
    local manifest="$1" local_id="$2" host alias folder_id
    host="$(hostname 2>/dev/null)" || host=Linux
    [[ -n "$host" ]] || host=Linux
    printf '\nSyncthing recovery:\n  Local Device ID: %s\n' "$local_id"
    printf '  Trusted peers configured: %s\n  Managed folders configured: %s\n' \
        "$(jq '.devices | length' "$manifest")" "$(jq '.folders | length' "$manifest")"
    printf '  Manual peer acceptance required: yes (unless already accepted)\n'
    while IFS= read -r alias; do
        printf '\nOn peer %s, add this device if absent, then add missing shares:\n' "$alias"
        printf 'syncthing cli config devices add --device-id %q --name %q\n' "$local_id" "$host"
        while IFS= read -r folder_id; do
            printf 'syncthing cli config folders %q devices add --device-id %q\n' "$folder_id" "$local_id"
        done < <(jq -r --arg alias "$alias" '.folders[] | select(.devices | index($alias)) | .id' "$manifest")
    done < <(jq -r '.devices[].alias' "$manifest")
}

syncthing_recovery_verify() {
    local manifest="$1" snapshot="$2" device folder id alias peer
    while IFS= read -r device; do
        jq -e --argjson desired "$device" '.devices | any(
            .deviceID == $desired.deviceID and ($desired.introducer == false or .introducer == true))' \
            <<< "$snapshot" >/dev/null || return 1
    done < <(jq -c '.devices[]' "$manifest")
    while IFS= read -r folder; do
        id="$(jq -r .id <<< "$folder")"
        syncthing_recovery_check_folder "$folder" "$snapshot" >/dev/null || return 1
        jq -e --arg id "$id" '.folders | any(.id == $id)' <<< "$snapshot" >/dev/null || return 1
        while IFS= read -r alias; do
            peer="$(jq -r --arg alias "$alias" '.devices[] | select(.alias == $alias) | .deviceID' "$manifest")"
            jq -e --arg id "$id" --arg peer "$peer" '.folders[] | select(.id == $id) | .devices | any(.deviceID == $peer)' \
                <<< "$snapshot" >/dev/null || return 1
        done < <(jq -r '.devices[]' <<< "$folder")
    done < <(jq -c '.folders[]' "$manifest")
}

syncthing_recovery_apply_manifest() (
    local manifest="$1" local_id snapshot folder device path other existing normalized
    local -a paths=()
    [[ $- != *x* ]] || { syncthing_recovery_error 'refuses shell tracing'; return 1; }
    for dependency in syncthing jq realpath timeout; do
        command -v "$dependency" >/dev/null 2>&1 || { syncthing_recovery_error "missing dependency: $dependency"; return 1; }
    done
    # Validate before starting the service, then again against the actual local ID.
    syncthing_recovery_validate_manifest "$manifest" '' || return 1
    syncthing_recovery_prepare || return 1
    local_id="$(syncthing_recovery_wait_ready)" || return 1
    syncthing_recovery_validate_manifest "$manifest" "$local_id" || return 1
    snapshot="$(syncthing_recovery_snapshot)" || { syncthing_recovery_error 'could not inspect current topology'; return 1; }
    # Preflight every path and existing conflict before the first topology write.
    while IFS= read -r folder; do
        path="$(syncthing_recovery_check_folder "$folder" "$snapshot")" || return 1
        for other in "${paths[@]}"; do
            [[ "$path" != "$other" && "$path/" != "$other/"* && "$other/" != "$path/"* ]] ||
                { syncthing_recovery_error 'duplicate or overlapping managed paths'; return 1; }
        done
        paths+=("$path")
        while IFS= read -r existing; do
            [[ "$(jq -r .id <<< "$existing")" != "$(jq -r .id <<< "$folder")" ]] || continue
            normalized="$(realpath -m -- "$(jq -r .path <<< "$existing")")" || return 1
            [[ "$path" != "$normalized" && "$path/" != "$normalized/"* && "$normalized/" != "$path/"* ]] ||
                { syncthing_recovery_error 'path overlaps another configured folder'; return 1; }
        done < <(jq -c '.folders[]' <<< "$snapshot")
    done < <(jq -c '.folders[]' "$manifest")
    while IFS= read -r device; do
        syncthing_recovery_apply_device "$device" "$snapshot" || { syncthing_recovery_error 'could not configure peer; rerun to resume'; return 1; }
    done < <(jq -c '.devices[]' "$manifest")
    while IFS= read -r folder; do
        syncthing_recovery_apply_folder "$folder" "$manifest" "$snapshot" || { syncthing_recovery_error 'could not configure folder/shares; rerun to resume'; return 1; }
    done < <(jq -c '.folders[]' "$manifest")
    if ! snapshot="$(syncthing_recovery_snapshot)" || ! syncthing_recovery_verify "$manifest" "$snapshot"; then
        syncthing_recovery_error 'final topology verification failed; rerun to resume'; return 1
    fi
    syncthing_recovery_print_peer_commands "$manifest" "$local_id"
)

syncthing_recovery_restore() (
    local temporary=''
    [[ $- != *x* ]] || { syncthing_recovery_error 'refuses shell tracing'; return 1; }
    umask 077
    trap '[[ -z "$temporary" ]] || rm -f -- "$temporary"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    temporary="$(mktemp)" || return 1
    bitwarden_get_notes "$BITWARDEN_SYNCTHING_RECOVERY_ITEM" > "$temporary" || return 1
    syncthing_recovery_apply_manifest "$temporary"
)
