#!/usr/bin/env bash
# Call secret helpers only inside a guarded subshell. Value-producing helpers
# write to stdout for capture/piping, never for display. Diagnostics use stderr.

bitwarden_cli_available() { command -v bw >/dev/null 2>&1; }

bitwarden_load_cli_path() {
    export PATH="$HOME/.local/bin:$PATH"
    if ! bitwarden_cli_available && [[ -s "$HOME/.nvm/nvm.sh" ]]; then
        export NVM_DIR="$HOME/.nvm"
        # shellcheck disable=SC1091
        source "$NVM_DIR/nvm.sh" >/dev/null 2>&1 || return 1
    fi
}

bitwarden_error() { warn "$*"; return 1; }

bitwarden_secret_failure() {
    if [[ "${BITWARDEN_SECRETS_REQUIRED:-false}" == true ]]; then
        die "$*"
    fi
    warn "$*"
}

bitwarden_guard() {
    [[ $- != *x* ]] || { bitwarden_error 'Bitwarden secret access refuses shell tracing'; return 1; }
    # Do not allow CLI debugging or inherited API/master-password authentication.
    unset BITWARDENCLI_DEBUG BW_PASSWORD BW_CLIENTID BW_CLIENTSECRET
    bitwarden_load_cli_path || return 1
    bitwarden_cli_available || { bitwarden_error 'Bitwarden CLI unavailable; install bw first'; return 1; }
    command -v jq >/dev/null 2>&1 || { bitwarden_error 'jq is required for Bitwarden secret access'; return 1; }
    umask 077
}

bitwarden_status() {
    bw status --nointeraction 2>/dev/null |
        jq -er '.status | select(. == "unauthenticated" or . == "locked" or . == "unlocked")' 2>/dev/null
}

bitwarden_interactive() {
    [[ -t 0 && -t 2 ]] || { bitwarden_error 'Bitwarden login/unlock requires an interactive terminal; rerun ./restore-secrets.sh there'; return 1; }
}

bitwarden_login() {
    bitwarden_interactive || return 1
    # Ordinary login output includes a session key. Capture raw output instead.
    BW_SESSION="$(bw login --raw)" || { bitwarden_error 'Bitwarden login failed'; return 1; }
    [[ -n "$BW_SESSION" ]] || { bitwarden_error 'Bitwarden login returned no session'; return 1; }
    export BW_SESSION
}

bitwarden_unlock() {
    bitwarden_interactive || return 1
    BW_SESSION="$(bw unlock --raw)" || { bitwarden_error 'Bitwarden unlock failed'; return 1; }
    [[ -n "$BW_SESSION" ]] || { bitwarden_error 'Bitwarden unlock returned no session'; return 1; }
    export BW_SESSION
}

bitwarden_sync() {
    bw sync --nointeraction >/dev/null 2>&1 || { bitwarden_error 'Bitwarden vault synchronization failed'; return 1; }
    ok 'Bitwarden vault synchronized' >&2
}

bitwarden_authenticate() {
    local state
    state="$(bitwarden_status)" || { bitwarden_error 'Could not inspect Bitwarden status'; return 1; }
    BITWARDEN_RELOCK=false
    case "$state" in
        unauthenticated)
            BITWARDEN_RELOCK=true
            bitwarden_login || return 1 ;;
        locked)
            BITWARDEN_RELOCK=true
            bitwarden_unlock || return 1 ;;
        unlocked)
            [[ -n "${BW_SESSION:-}" ]] || bitwarden_unlock || return 1 ;;
    esac
    [[ "$(bitwarden_status)" == unlocked ]] || { bitwarden_error 'Bitwarden session verification failed'; return 1; }
    bitwarden_sync
}

bitwarden_cleanup_session() {
    if [[ "${BITWARDEN_RELOCK:-false}" == true ]]; then
        bw lock --nointeraction >/dev/null 2>&1 || warn 'Could not re-lock Bitwarden; run bw lock manually'
    fi
    unset BW_SESSION BITWARDEN_RELOCK
}

bitwarden_find_item_exact() {
    local id
    id="$(bw list items --search "$1" --nointeraction 2>/dev/null |
        jq -er --arg name "$1" '
            [.[] | select(.name == $name and (.deletedDate == null))] |
            if length == 1 then .[0].id else error("missing or ambiguous item") end |
            select(type == "string" and test("^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$"))
        ' 2>/dev/null)" || { bitwarden_error 'Bitwarden item missing, ambiguous, or invalid'; return 1; }
    printf '%s\n' "$id"
}

bitwarden_get_item_json() {
    local id
    id="$(bitwarden_find_item_exact "$1")" || return 1
    bw get item "$id" --nointeraction 2>/dev/null || { bitwarden_error 'Could not retrieve Bitwarden item'; return 1; }
}

bitwarden_get_field() {
    bitwarden_get_item_json "$1" |
        jq -ej --arg field "$2" '
            [.fields[]? | select(.name == $field)] |
            if length == 1 then .[0].value else error("missing or duplicate field") end |
            if type == "string" and length > 0 and (contains("\u0000") | not)
            then . else error("invalid field") end
        ' 2>/dev/null || { bitwarden_error 'Bitwarden field missing, ambiguous, empty, or invalid'; return 1; }
}

bitwarden_get_notes() {
    bitwarden_get_item_json "$1" |
        jq -ej 'if .type == 2 and (.notes | type == "string" and length > 0 and (contains("\u0000") | not))
            then .notes else error("expected nonempty Secure Note") end' 2>/dev/null ||
        { bitwarden_error 'Bitwarden Secure Note missing, empty, or invalid'; return 1; }
}

bitwarden_restore_note_file() (
    local item="$1" destination="$2" mode="$3" directory current temporary='' comparison
    umask 077
    trap '[[ -z "$temporary" ]] || rm -f -- "$temporary"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    [[ "$destination" == /* && "$mode" == 0600 ]] || { bitwarden_error 'Invalid secret destination or mode'; return 1; }
    directory="$(dirname -- "$destination")"
    # Refuse symlink destinations/parents, including dangling links.
    current="$destination"
    while [[ "$current" != / ]]; do
        [[ ! -L "$current" ]] || { bitwarden_error 'Refusing a symlink in the secret destination'; return 1; }
        current="$(dirname -- "$current")"
    done
    mkdir -p -- "$directory" || return 1
    if [[ ! -O "$directory" ]] || (( (8#$(stat -c %a -- "$directory") & 0022) != 0 )); then
        bitwarden_error 'Secret directory must be owned by you and not writable by other users'
        return 1
    fi
    if [[ -e "$destination" ]]; then
        [[ -f "$destination" && -O "$destination" && "$(stat -c %h -- "$destination")" == 1 ]] ||
            { bitwarden_error 'Refusing non-regular, unowned, or hard-linked secret destination'; return 1; }
    fi
    temporary="$(mktemp "$directory/.bitwarden-restore.XXXXXX")" || return 1
    bitwarden_get_notes "$item" > "$temporary" || return 1
    [[ -s "$temporary" ]] || return 1
    chmod "$mode" "$temporary" || return 1
    if [[ -e "$destination" ]]; then
        comparison=0
        cmp -s -- "$temporary" "$destination" || comparison=$?
        if [[ "$comparison" == 0 ]]; then
            chmod "$mode" "$destination" || return 1
            ok 'Secret file already matches the vault' >&2
            return 0
        elif [[ "$comparison" != 1 ]]; then
            bitwarden_error 'Could not compare the existing secret file'; return 1
        elif [[ "${BITWARDEN_OVERWRITE_EXISTING_SECRETS:-false}" != true ]]; then
            bitwarden_error 'Existing secret file differs; preserved (enable BITWARDEN_OVERWRITE_EXISTING_SECRETS to replace)'; return 1
        fi
        mv -fT -- "$temporary" "$destination" || return 1
    else
        # Atomic creation without clobbering a file created since our check.
        ln -T -- "$temporary" "$destination" || return 1
        rm -f -- "$temporary" || return 1
    fi
    temporary=''
    [[ -s "$destination" && "$(stat -c %a -- "$destination")" == 600 ]] || return 1
    ok 'Restored secret file with mode 0600' >&2
)
