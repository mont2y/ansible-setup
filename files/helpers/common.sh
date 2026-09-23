#!/usr/bin/env bash

log()  { printf '\n\033[1;34m==>\033[0m %s\n' "$*"; }
ok()   { printf '\033[1;32m[OK]\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; exit 1; }

require_normal_user() {
    [[ ${EUID} -ne 0 ]] || die "Run this setup as your normal user, not root."
    command -v sudo >/dev/null 2>&1 || die "sudo is required."
    sudo -v
}

detect_distro() {
    [[ -r /etc/os-release ]] || die "/etc/os-release not found."
    # shellcheck disable=SC1091
    source /etc/os-release

    DISTRO_ID="${ID:-unknown}"
    DISTRO_LIKE="${ID_LIKE:-}"

    if [[ "$DISTRO_ID" == "ubuntu" || "$DISTRO_ID" == "debian" || "$DISTRO_LIKE" == *"debian"* ]]; then
        FAMILY="debian"
    elif [[ "$DISTRO_ID" == "fedora" || "$DISTRO_LIKE" == *"fedora"* || "$DISTRO_LIKE" == *"rhel"* ]]; then
        FAMILY="fedora"
    elif [[ "$DISTRO_ID" == "arch" || "$DISTRO_ID" == "cachyos" || "$DISTRO_ID" == "omarchy" || "$DISTRO_LIKE" == *"arch"* ]]; then
        FAMILY="arch"
    else
        die "Unsupported distro: ID=$DISTRO_ID ID_LIKE=$DISTRO_LIKE"
    fi

    export DISTRO_ID DISTRO_LIKE FAMILY PRETTY_NAME VERSION_CODENAME UBUNTU_CODENAME
    log "Detected ${PRETTY_NAME:-$DISTRO_ID} ($FAMILY)"
}

pkg_available() {
    local pkg="$1"
    case "$FAMILY" in
        debian) apt-cache show "$pkg" >/dev/null 2>&1 ;;
        fedora) dnf -q info "$pkg" >/dev/null 2>&1 ;;
        arch) pacman -Si "$pkg" >/dev/null 2>&1 ;;
    esac
}

pkg_installed() {
    local pkg="$1"
    case "$FAMILY" in
        debian) dpkg -s "$pkg" >/dev/null 2>&1 ;;
        fedora) rpm -q "$pkg" >/dev/null 2>&1 ;;
        arch) pacman -Q "$pkg" >/dev/null 2>&1 ;;
    esac
}

install_pkg() {
    local pkg="$1"
    if pkg_installed "$pkg"; then
        ok "$pkg already installed"
        return 0
    fi
    if ! pkg_available "$pkg"; then
        warn "$pkg is not available in configured repositories; skipping"
        return 0
    fi
    log "Installing $pkg"
    case "$FAMILY" in
        debian) sudo apt-get install -y "$pkg" ;;
        fedora) sudo dnf install -y "$pkg" ;;
        arch) sudo pacman -S --needed --noconfirm "$pkg" ;;
    esac
}

install_many() {
    local pkg
    for pkg in "$@"; do
        install_pkg "$pkg" || return $?
    done
}

system_service_exists() {
    local state
    state="$(systemctl show --property=LoadState --value "$1" 2>/dev/null)" || return 1
    [[ "$state" == loaded ]]
}

enable_system_service_if_exists() {
    local unit="$1"
    if system_service_exists "$unit"; then
        sudo systemctl enable --now "$unit" || warn "Could not enable $unit"
    else
        warn "System service not found: $unit"
    fi
}

enable_user_service_if_exists() {
    local unit="$1"
    if systemctl --user list-unit-files "$unit" >/dev/null 2>&1; then
        systemctl --user enable --now "$unit" || warn "Could not enable user service $unit"
    else
        warn "User service not found: $unit"
    fi
}

install_flatpak_app() {
    local app_id="$1"
    command -v flatpak >/dev/null 2>&1 || { warn "Flatpak not installed; skipping $app_id"; return 0; }
    if flatpak info --user "$app_id" >/dev/null 2>&1 || flatpak info "$app_id" >/dev/null 2>&1; then
        ok "$app_id already installed"
    else
        log "Installing Flatpak app $app_id"
        flatpak install --user -y flathub "$app_id"
    fi
}

install_paru_arch() {
    [[ "$FAMILY" == "arch" ]] || return 1
    if command -v paru >/dev/null 2>&1; then
        return 0
    fi
    [[ "${ALLOW_INSTALL_PARU:-true}" == true ]] || { warn "paru missing and ALLOW_INSTALL_PARU=false"; return 1; }
    log "Installing paru"
    install_many git base-devel
    local tmpdir
    tmpdir="$(mktemp -d)"
    git clone https://aur.archlinux.org/paru.git "$tmpdir/paru"
    (cd "$tmpdir/paru" && makepkg -si --noconfirm)
    rm -rf "$tmpdir"
}

backup_path() {
    local target="$1"
    [[ -e "$target" || -L "$target" ]] || return 0
    local backup
    backup="${target}.backup.$(date +%Y%m%d-%H%M%S)"
    mv "$target" "$backup"
    warn "Backed up $target to $backup"
}

link_config() {
    local source="$1"
    local target="$2"
    mkdir -p "$(dirname "$target")"

    if [[ -L "$target" ]] && [[ "$(readlink -f "$target")" == "$(readlink -f "$source")" ]]; then
        ok "$target already linked"
        return 0
    fi

    backup_path "$target"
    ln -s "$source" "$target"
    ok "Linked $target -> $source"
}
