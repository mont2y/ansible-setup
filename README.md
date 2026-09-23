# Ansible Linux workstation setup

An Ansible conversion of [mont2y/test-setup](https://github.com/mont2y/test-setup) at commit `bc0a6016fa44e9bd2ed04167b9b83224fe60621b`. This repository configures a local Ubuntu/Debian, Fedora, or Arch/CachyOS/Omarchy workstation. Its default settings mirror the original Bash project.

> **Before running:** Most components are enabled by default. Review [`group_vars/all.yml`](group_vars/all.yml): the full playbook updates the OS and installs Docker, desktop applications, virtualization, and an OpenSSH server. Run it as your normal user in a graphical login session, not with `sudo ansible-playbook`.

## Fresh device setup

### 1. Install the prerequisites

Run the command for your distribution:

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install -y git python3 python3-venv python3-apt

# Fedora
sudo dnf install -y git python3

# Arch / CachyOS / Omarchy
sudo pacman -Syu --needed git python
```

### 2. Clone this repository

Choose a permanent location. Zsh and Espanso configuration files and the Bitwarden runtime helper are linked to this checkout, so do not move or delete it after installation.

```bash
mkdir -p "$HOME/projects"
git clone https://github.com/mont2y/ansible-setup.git "$HOME/projects/ansible-setup"
cd "$HOME/projects/ansible-setup"
```

The included inventory targets `localhost` through a local Ansible connection. You do not need SSH to configure the machine you are logged into.

### 3. Install Ansible in a user virtual environment

```bash
python3 -m venv "$HOME/.venvs/ansible-setup"
"$HOME/.venvs/ansible-setup/bin/pip" install 'ansible==13.4.0'
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --version
```

This project was syntax checked with Ansible 13.4.0 (ansible-core 2.20.9), `community.general` 12.4.0, and `community.libvirt` 2.1.0. The full `ansible` package includes those collections. If you installed only `ansible-core`, install this repository's pinned collections separately:

```bash
ansible-galaxy collection install -r requirements.yml
```

The commands below use the virtual environment's full executable path, so they work in fish, Bash, and Zsh without modifying your `PATH`.

### 4. Choose what to install

Open [`group_vars/all.yml`](group_vars/all.yml):

```bash
nano group_vars/all.yml
```

Change an unwanted component from `true` to `false`, for example `install_steam: false`. The original defaults enable system updates, Zsh, WezTerm, Node, Python, Docker, VS Code, GitHub CLI, Flatpak apps, rclone, Syncthing, Solaar, Input Remapper, Espanso, Bitwarden, virtualization, LenovoLegionLinux on Lenovo hardware, and OpenSSH. `install_codex` defaults to `false`.

For machine-specific settings that will not create Git changes in this checkout, put overrides in a separate YAML file, such as `$HOME/.config/ansible-setup/local.yml`:

```yaml
install_steam: false
install_openssh_server: false
enable_openssh_server: false
```

Pass that file with `-e "@$HOME/.config/ansible-setup/local.yml"` on each playbook run. You can also use a one-time override such as `-e install_steam=false`.

### 5. Check and run the playbook

From the repository directory:

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --syntax-check site.yml
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K --skip-tags secrets
```

Add `-e "@$HOME/.config/ansible-setup/local.yml"` to the second command if you created an overrides file. `-K` prompts for your sudo password; Ansible elevates only the tasks that require it. The first run can take time because it downloads and installs the selected components.

After it finishes, log out and back in so your new default shell and Docker/libvirt/KVM group memberships apply.

## Restore Bitwarden secrets and Syncthing topology

The initial command skips the `secrets` role so you can sign in to Bitwarden deliberately. If your vault has the required items, run this **in a terminal on the new device** from the repository directory:

```bash
env BITWARDEN_SECRETS_REQUIRED=true \
    RESTORE_RCLONE_FROM_BITWARDEN=true \
    RESTORE_SYNCTHING_FROM_BITWARDEN=true \
    ./scripts/restore-secrets.sh
```

The script can prompt for Bitwarden login or unlock. The required Secure Notes are named `Linux Setup - rclone.conf` and `Linux Setup - Syncthing Recovery`. See [`files/syncthing/recovery.example.json`](files/syncthing/recovery.example.json) for the recovery format. If you want to restore only rclone, set `RESTORE_SYNCTHING_FROM_BITWARDEN=false` in this command.

**Set `RESTORE_SYNCTHING_FROM_BITWARDEN=true` for the standalone script.** That setting is enabled in Ansible's YAML defaults, but a directly executed shell script does not read `group_vars/all.yml`. The script prints the local Syncthing Device ID and commands to run on existing peers. Accept the new device on each peer before expecting folders to sync. It does not copy Syncthing keys, certificates, configuration, or databases from another machine.

Alternatively, unlock Bitwarden in the same shell and invoke the Ansible restoration playbook:

```bash
bw login  # only if not already signed in
export BW_SESSION="$(bw unlock --raw)"
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" restore-secrets.yml
bw lock
unset BW_SESSION
```

Ansible suppresses the entire restoration task output with `no_log`, including peer instructions. Use the standalone script when you need to see those instructions. In fish, use `set -x BW_SESSION (bw unlock --raw)` and `set -e BW_SESSION` instead of Bash's `export` and `unset` syntax.

Never store your vault session, master password, `rclone.conf` contents, or Syncthing identity files in this repository. Do not run secret restoration with shell tracing or Ansible `--diff` or verbose output.

## Run selected components or rerun later

```bash
cd "$HOME/projects/ansible-setup"

# Example: only virtualization
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K --tags virtualization

# Rerun ordinary setup after changing settings
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K --skip-tags secrets
```

To fetch changes from GitHub, run `git pull --ff-only` in the checkout first. If you edited tracked files such as `group_vars/all.yml`, handle those local edits before pulling; keeping personal overrides outside the checkout avoids that conflict.

## What the roles configure

| Role | Components |
| --- | --- |
| `system` | System updates and base/build packages |
| `shell` | Zsh, Oh My Zsh, plugins, backed-up `.zshrc` link, login shell |
| `terminal` | Font packages and fallbacks, WezTerm, separate WezTerm config checkout |
| `development` | NVM and Node LTS, Python tools, Docker, VS Code, GitHub CLI |
| `apps` | Flatpak and Flathub, Telegram, Lutris, Steam, Brave, Postman, Thunderbird |
| `tools` | rclone, Syncthing, Solaar, Input Remapper, Espanso |
| `bitwarden` | Bitwarden CLI/Desktop and `with-bitwarden-secret` wrapper |
| `virtualization` | QEMU, KVM, libvirt, virt-manager, default NAT network |
| `legion` | Lenovo-only dependencies, headers, DKMS, pipx tools, Secure Boot status |
| `secrets` | Bitwarden-backed rclone restoration and additive Syncthing recovery |
| `services` | OpenSSH server and optional Codex CLI |
| `aur` | paru and selected AUR packages on Arch-based distributions |

Ordinary package lists live in [`vars/packages.yml`](vars/packages.yml). Specialized Bitwarden and Syncthing validation remains in small Bash/JQ helpers because it enforces file safety, vault session isolation, Device ID checksums, folder path preflight, and additive topology changes.

## Checks and practical limits

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --syntax-check site.yml
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --syntax-check restore-secrets.yml
python3 tests/check-project.py
bash tests/test-bitwarden.sh
bash tests/test-secrets.sh
bash tests/test-syncthing-recovery.sh
```

The conversion passed syntax checks and adapted mock tests, but it has not been run end to end on every supported distribution. Ansible check mode cannot fully simulate NVM, AUR builds, DKMS, Bitwarden, or Syncthing CLI operations. The user systemd manager must be available for Syncthing. Some upstream Postman, Espanso, and font downloads follow the original project's URLs without pinned digests.
