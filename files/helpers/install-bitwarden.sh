#!/usr/bin/env bash

# Installation only; authentication belongs to 80-secrets.sh.
install_bitwarden_native() (
    local architecture version="${BITWARDEN_CLI_VERSION:-2026.9.0}" asset url digest metadata temporary stage=''
    case "$(uname -m)" in
        x86_64|amd64) architecture=linux ;;
        aarch64|arm64) architecture=linux-arm64 ;;
        *) warn 'No supported native Bitwarden build; enable Node/npm and select npm'; return 1 ;;
    esac
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
    install_many curl jq unzip ca-certificates || return 1
    for dependency in curl jq unzip sha256sum; do
        command -v "$dependency" >/dev/null 2>&1 || { warn "Native Bitwarden install requires $dependency"; return 1; }
    done
    temporary="$(mktemp -d)" || return 1
    trap 'rm -rf -- "$temporary"; [[ -z "$stage" ]] || rm -f -- "$stage"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    asset="bw-${architecture}-${version}.zip"
    metadata="https://api.github.com/repos/bitwarden/clients/releases/tags/cli-v${version}"
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 120 \
        "$metadata" -o "$temporary/release.json" || return 1
    url="$(jq -er --arg asset "$asset" --arg tag "cli-v$version" '
        select(.tag_name == $tag and .draft == false and .prerelease == false) |
        [.assets[] | select(.name == $asset)] |
        if length == 1 then .[0].browser_download_url else empty end
        ' "$temporary/release.json")" || return 1
    [[ "$url" == "https://github.com/bitwarden/clients/releases/download/cli-v${version}/${asset}" ]] || return 1
    digest="$(jq -er --arg asset "$asset" '.assets[] | select(.name == $asset) | .digest' "$temporary/release.json")" || return 1
    [[ "$digest" =~ ^sha256:[a-fA-F0-9]{64}$ ]] || { warn 'Official Bitwarden SHA-256 digest unavailable'; return 1; }
    curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --connect-timeout 15 --max-time 300 \
        "$url" -o "$temporary/bw.zip" || return 1
    printf '%s  %s\n' "${digest#sha256:}" "$temporary/bw.zip" |
        sha256sum --check --status || { warn 'Bitwarden checksum mismatch; refusing installation'; return 1; }
    # Extract only the executable, never archive-controlled paths or permissions.
    unzip -p "$temporary/bw.zip" bw > "$temporary/bw" || return 1
    [[ -s "$temporary/bw" ]] || return 1
    chmod 0755 "$temporary/bw" || return 1
    "$temporary/bw" --version >/dev/null 2>&1 || return 1
    mkdir -p "$HOME/.local/bin" || return 1
    stage="$(mktemp "$HOME/.local/bin/.bw-install.XXXXXX")" || return 1
    install -m 0755 "$temporary/bw" "$stage" || return 1
    mv -fT -- "$stage" "$HOME/.local/bin/bw" || return 1
    stage=''
)

install_bitwarden_cli() {
    local method="${BITWARDEN_CLI_INSTALL_METHOD:-auto}"
    export PATH="$HOME/.local/bin:$PATH"
    if command -v bw >/dev/null 2>&1; then
        bw --version >/dev/null 2>&1 || return 1
        ok 'Bitwarden CLI already available'
        return 0
    fi
    case "$method" in auto|npm|native) ;; *) warn 'Invalid BITWARDEN_CLI_INSTALL_METHOD (use auto, npm, or native)'; return 1 ;; esac
    # Prefer the user's NVM environment even when system npm is on PATH.
    if [[ "$method" != native && -s "$HOME/.nvm/nvm.sh" ]]; then
        export NVM_DIR="$HOME/.nvm"
        # shellcheck disable=SC1091
        source "$NVM_DIR/nvm.sh" || return 1
    fi
    if [[ "$method" == auto ]]; then
        if command -v npm >/dev/null 2>&1; then method=npm; else method=native; fi
    fi
    if [[ "$method" == npm ]]; then
        command -v npm >/dev/null 2>&1 || { warn 'npm unavailable; enable INSTALL_NVM_NODE or select native'; return 1; }
        npm install -g @bitwarden/cli || { warn 'Bitwarden npm installation failed; use a writable user/NVM prefix or select native'; return 1; }
    else
        install_bitwarden_native || return 1
    fi
    command -v bw >/dev/null 2>&1 && bw --version >/dev/null 2>&1 || return 1
    ok 'Bitwarden CLI available'
}

if [[ "${INSTALL_BITWARDEN_CLI:-true}" == true ]]; then
    install_bitwarden_cli || die 'Bitwarden CLI installation failed; resolve the error above and rerun the Bitwarden role'
fi
if [[ "${INSTALL_BITWARDEN_DESKTOP:-true}" == true ]]; then
    install_flatpak_app com.bitwarden.desktop || warn 'Bitwarden Desktop installation failed'
fi
