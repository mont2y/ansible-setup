# Linux workstation setup with Ansible

This project converts [mont2y/test-setup](https://github.com/mont2y/test-setup) at commit `bc0a6016fa44e9bd2ed04167b9b83224fe60621b`. It configures Ubuntu/Debian, Fedora, and Arch/CachyOS/Omarchy workstations. Default switches mirror `settings.sh` from that commit. Review `group_vars/all.yml` before running it: system upgrades, Docker, OpenSSH, virtualization, desktop apps and secret recovery are enabled by default.

## Bootstrap

Install `git`, Python 3 and venv support on the target machine, then install the tested Ansible distribution into a user venv. The tested distribution bundles both required collections; `requirements.yml` pins them for installations that start from `ansible-core` instead.

```bash
# Ubuntu/Debian
sudo apt update && sudo apt install -y git python3 python3-venv python3-apt
# Fedora
sudo dnf install -y git python3
# Arch/CachyOS/Omarchy
sudo pacman -Syu --needed git python

python3 -m venv ~/.venvs/test-setup-ansible
~/.venvs/test-setup-ansible/bin/pip install 'ansible==13.4.0'
export PATH="$HOME/.venvs/test-setup-ansible/bin:$PATH"
# If using ansible-core separately, install pinned collections:
# ansible-galaxy collection install -r requirements.yml
```

Extract this archive somewhere permanent: tracked Zsh/Espanso configuration and the Bitwarden helper are linked to this checkout. Run as your **normal user** in your graphical login session (Syncthing and Flatpak use the user session):

```bash
cd test-setup-ansible
ansible-playbook site.yml -K --skip-tags secrets
```

You can also run one category, e.g. `ansible-playbook site.yml -K --tags virtualization`, or override a boolean with `-e install_steam=false`. Disable unwanted options in `group_vars/all.yml` before the first full run. Log out and back in after shell/group changes.

If you configure remote hosts, put them in `inventory/` and provide a logged-in user session for user services. The default inventory only targets the local workstation.

## Bitwarden and recovery

The secret helpers retain the source project's strict validation, file ownership and link checks, overwrite controls, Bitwarden isolation, Syncthing Device ID checksum checks, folder preflight, and additive topology changes. `lib/bitwarden.sh`, `lib/syncthing-recovery.sh`, `lib/syncthing-recovery.jq`, and `scripts/with-bitwarden-secret` are intentionally preserved. Ansible handles provisioning and invokes them where their specialized runtime behavior is needed. It never copies a Syncthing identity or database.

For an interactive vault unlock and visible peer-side Syncthing commands, run:

```bash
./scripts/restore-secrets.sh
```

Or unlock first, pass your session from the same shell, and use Ansible (it suppresses all vault task output):

```bash
bw login                      # only if necessary
export BW_SESSION="$(bw unlock --raw)"
ansible-playbook restore-secrets.yml
bw lock
unset BW_SESSION
```

The default `bitwarden_secrets_required: false` means missing vault access warns and keeps ordinary installation running. To require restoration, set it to `true`. The `rclone.conf` Secure Note must be named `Linux Setup - rclone.conf`; the Syncthing manifest Secure Note is `Linux Setup - Syncthing Recovery`. See `files/syncthing/recovery.example.json` for schema. Each existing peer must accept this machine's new Device ID. Run the direct restore script to display the exact peer-side commands.

The runtime wrapper lives at `scripts/with-bitwarden-secret` and is linked into `~/.local/bin`. Example:

```bash
with-bitwarden-secret 'Linux Setup - OpenAI' api_key OPENAI_API_KEY -- your-command
```

Never put `BW_SESSION`, a master password, rclone credentials, or identity files in inventory, `group_vars`, Git, or command arguments. Do not run secrets tasks with Ansible `--diff` or verbose output. The secret task itself uses `no_log`.

## Components

| Role | Work |
| --- | --- |
| `system` | OS updates, base/build packages |
| `shell` | Zsh, Oh My Zsh, plugins, backed-up config symlink, login shell |
| `terminal` | fonts, WezTerm repo/package/config checkout |
| `development` | NVM/Node, Python, Docker, VS Code, GitHub CLI |
| `apps` | Flathub/Flatpak apps, Brave, Postman, Thunderbird |
| `tools` | rclone, Syncthing, Solaar, Input Remapper, Espanso |
| `bitwarden` | verified native or npm CLI, Desktop, runtime wrapper |
| `virtualization` | QEMU/libvirt/virt-manager, NAT default network |
| `legion` | Lenovo only: dependencies, headers, DKMS, pipx tools, Secure Boot status |
| `secrets` | guarded Bitwarden rclone/Syncthing restoration |
| `services` | OpenSSH and optional Codex CLI |
| `aur` | install paru when needed, install AUR packages as normal user |

Package lists in `vars/packages.yml` were generated from every upstream `packages/*.txt` manifest. Edits to your tracked config or WezTerm checkout are preserved by backup/dirty checks. Pinned upstream font archives are downloaded into a user cache; Postman and Espanso use their upstream download endpoints.

## Validation and limits

```bash
ansible-playbook --syntax-check site.yml
ansible-playbook --syntax-check restore-secrets.yml
python3 tests/check-project.py
```

`--check` is useful for state modules and requires distro Python dependencies such as `python3-apt` on Debian. CLI-backed operations (vault, DKMS, AUR, cargo, NVM) need a real run to verify. Full installation changes system packages and services; it is intentionally not executed in the conversion environment. Some upstream network assets (Postman, Espanso, fonts) do not publish a pinned digest in the source project. Review upstream URLs and package availability on your distro before running. Syncthing user service requires an active user systemd manager.
