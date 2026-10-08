# Ansible Linux workstation setup

An Ansible conversion of [mont2y/test-setup](https://github.com/mont2y/test-setup) at commit `bc0a6016fa44e9bd2ed04167b9b83224fe60621b`. This repository configures a local Ubuntu/Debian, Fedora, or Arch/CachyOS/Omarchy workstation. Its default settings are based on the original Bash project; Syncthing is installed without recovery or configuration management.

> **Before running:** Most components are enabled by default. Review [`group_vars/all.yml`](group_vars/all.yml): the full playbook updates the OS and installs Docker, desktop applications, virtualization, and an OpenSSH server. Run it as your normal user in a graphical login session, not with `sudo ansible-playbook`.

## Fresh device setup

### 1. Install the prerequisites

Run the command for your distribution:

```bash
# Ubuntu / Debian
sudo apt update && sudo apt install -y git python3 python3-venv python3-apt openssh-client

# Fedora
sudo dnf install -y git python3 openssh-clients

# Arch / CachyOS / Omarchy
sudo pacman -Syu --needed git python openssh
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

### 5. Bootstrap private Espanso configuration

The default is `espanso_config_source: private_git`, using
`git@github.com:mont2y/espanso-config.git` on branch `main`. Complete the SSH
bootstrap below before running the full playbook with Espanso enabled. No source
override is needed. To use the generic example instead, explicitly set
`espanso_config_source: bundled`. `install_espanso: false` needs neither a GitHub
identity nor a private repository.

Ensure the **private** GitHub repository `mont2y/espanso-config` contains
`match/base.yml` on its `main` branch. Setup does not create the repository.
The existing public SSH key must
already be authorized on the GitHub account or as a deploy key with repository
read access.

In Bitwarden, create these two **Secure Notes** with exact names:

| Note | Contents |
| --- | --- |
| `Linux Setup - github-ssh-private` | Original OpenSSH private key, including BEGIN/END lines, original line breaks and final newline |
| `Linux Setup - github-ssh-public` | Matching one-line OpenSSH public key; a trailing newline is allowed |

Keep the existing private-key passphrase. The restore command accepts Ed25519,
RSA and ECDSA keys and detects the actual type; its dedicated filename stays
`id_ed25519_github` even for a legacy algorithm. It never touches `id_ed25519`.
Encrypted keys should use OpenSSH format for the subsequent agent validation.

Install the CLI first; this does not require GitHub SSH access or vault login:

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K \
  --tags bitwarden -e install_bitwarden_desktop=false
./scripts/restore-github-ssh.sh
```

Run restoration in a terminal as your normal user. It authenticates to Bitwarden
once, reads both notes, validates the matching pair, and installs
`~/.ssh/id_ed25519_github` (`0600`) and its `.pub` (`0644`) under `~/.ssh` (`0700`).
It prints paths and the public fingerprint only. It supports an interactive SSH
passphrase prompt, separate from the vault master password, and relocks only a
vault session it acquired itself. Normal Ansible reruns never fetch these keys.

The restore script also handles the SSH agent for encrypted keys:

- It reuses a reachable agent from your current session, including desktop agents.
- If none is available, it reuses or starts an agent at
  `~/.ssh/ansible-setup-agent/agent.sock` and runs `ssh-add` for the restored key.
- An already-loaded key is reused. OpenSSH may ask for the key passphrase twice
  on the first restore: once to validate the pair and once to load the agent.
- Ansible discovers this agent automatically, so you can proceed directly to the
  playbook from Bash, Zsh or fish. Unencrypted keys work directly without an agent.

An executable cannot export variables into its parent terminal. If the script
starts or reconnects to its own agent, it prints the correct optional command for
manual Git/SSH in the calling shell. It detects the running shell before using
`$SHELL` as a fallback:

```bash
# Bash / Zsh: the script prints the actual, safely quoted socket path.
export SSH_AUTH_SOCK="$HOME/.ssh/ansible-setup-agent/agent.sock"
```

```fish
# fish
set -gx SSH_AUTH_SOCK "$HOME/.ssh/ansible-setup-agent/agent.sock"
```

You do not need these exports for this project's Ansible runs. Existing agents
remain running and keep their other identities. A newly created agent is stopped
if key loading fails; restored files remain available for retry. The managed agent
keeps the unlocked key in memory until it is removed or the agent exits (for
example at reboot); starting another terminal does not relock it. After an agent
exits or loses the key, rerun restoration in a terminal. No shell startup files
are modified, and vault credentials are removed before starting the agent. Never
put a passphrase, vault session token or PAT in YAML or command-line arguments.

These settings are already the defaults in `group_vars/all.yml`. Use
`$HOME/.config/ansible-setup/local.yml` only if you want to override them:

```yaml
espanso_config_source: private_git
espanso_config_repo: git@github.com:mont2y/espanso-config.git
espanso_config_branch: main
```

The separate checkout defaults to
`~/.local/share/ansible-setup/espanso-config`. A custom `espanso_config_checkout`
must stay below `~/.local/share/ansible-setup/`; `espanso_config_base_relative_path`
defaults to `match/base.yml` and must not traverse parent directories. Ansible
accepts identity path overrides `github_ssh_private_key_path` and
`github_ssh_public_key_path` directly under `~/.ssh`; the restoration command
always uses the dedicated default filenames.

Then run the full setup:

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K --skip-tags secrets
```

The `github_access` role verifies the installed identity/agent, installs the pinned
GitHub host key, and probes the selected repository and branch. It runs before
Espanso package tasks and is included by `--tags tools`. Private mode never falls
back to bundled snippets on authentication or repository errors. Git clone uses
strict host checking and the identity **path**; no key contents enter Ansible.

### 6. Check and run the playbook

From the repository directory:

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --syntax-check site.yml
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K --skip-tags secrets
```

Add `-e "@$HOME/.config/ansible-setup/local.yml"` to the second command if you created an overrides file. `-K` prompts for your sudo password; Ansible elevates only the tasks that require it. The first run can take time because it downloads and installs the selected components.

After it finishes, log out and back in so your new default shell and Docker/libvirt/KVM group memberships apply.

## SSH restoration policy and GitHub host trust

Restoration stages both Secure Notes inside a private directory under `~/.ssh`.
It validates both before touching installed files, refuses symlinks/hardlinks,
unsafe ownership and directories writable by others, and preserves differing
existing files by default. Identical reruns preserve file inodes and repair
permissions. Deliberate replacement requires this explicit opt-in:

```bash
env GITHUB_SSH_OVERWRITE_EXISTING=true ./scripts/restore-github-ssh.sh
```

No plaintext backups are made. Each file is installed atomically, but the pair
requires two filesystem operations: a crash or failure between promotions may
leave only the public file updated. The private file is promoted last; fix the
failure and rerun restoration to recover. Do not concurrently modify these files.
Staging is removed on ordinary exits and catchable signals; a power loss or SIGKILL
cannot run cleanup, so inspect/remove any stale `.github-ssh-restore.*` directory
under `~/.ssh` after such an interruption.

Sharing one SSH identity across machines means compromise of any machine
compromises that identity; revocation requires rekeying every machine.

GitHub's Ed25519 host key was checked against the
[official fingerprint page](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints)
on 2026-10-08. Its fingerprint is
`SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU`.
The role preserves other host entries and algorithms, and refuses conflicting
GitHub Ed25519 entries, including hashed entries. It never trusts an unverified
network scan. Update the pin in `roles/github_access/vars/main.yml` only after
verifying an official rotation announcement; resolve a conflict manually.

To test authentication after the role configures trust:

```bash
ssh -i ~/.ssh/id_ed25519_github -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -T git@github.com
```

GitHub can greet you successfully and still exit with status **1** because it
provides no shell. The role uses `git ls-remote` against the actual repository and
branch for an exit-zero access check. Encrypted keys require `ssh-add` in the same
session; an authorized key alone does not create a missing private repository.

## Migrate and update Espanso snippets

Copy your personal snippets from the old `files/espanso/base.yml` (or its Git
history) into the private repository's `match/base.yml` on an authorized machine.
Verify the contents there before switching to `private_git`. The public bundled
file now contains only a generic date example. Actual passwords, API tokens and
other secrets belong in Bitwarden, including when the Git repository is private.

Removing content from the current branch does not erase old commits, forks,
clones or caches. Rotate any credentials ever committed. Coordinate any history
rewrite separately; this setup does not rewrite history or push your snippets.

The role backs up only an unrelated local `~/.config/espanso/match/base.yml`, then
links the selected source. Other match files and local Espanso configuration stay
in place. Dirty private checkouts stop with instructions to commit or move edits;
updates never force-discard them. The checkout and its parent are restricted to
the account, and Espanso restarts only when the link or checkout changes.

After committing/pushing snippets from an authorized workstation, rerun:

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" site.yml -K --tags github_access,tools
```

`--tags tools` also includes the GitHub prerequisite checks. `--tags bitwarden`
remains independent for initial bootstrap. To return to the generic example,
set `espanso_config_source: bundled`; the private checkout is preserved.

## Restore rclone configuration from Bitwarden

The initial command skips the `secrets` role so you can sign in to Bitwarden deliberately. If your vault has the required items, run this **in a terminal on the new device** from the repository directory:

```bash
env BITWARDEN_SECRETS_REQUIRED=true \
    RESTORE_RCLONE_FROM_BITWARDEN=true \
    ./scripts/restore-secrets.sh
```

The script can prompt for Bitwarden login or unlock. Store the rclone configuration in a Secure Note named `Linux Setup - rclone.conf`.

Alternatively, unlock Bitwarden in the same shell and invoke the Ansible restoration playbook:

```bash
bw login  # only if not already signed in
export BW_SESSION="$(bw unlock --raw)"
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" restore-secrets.yml
bw lock
unset BW_SESSION
```

Ansible suppresses the entire restoration task output with `no_log`. In fish, use `set -x BW_SESSION (bw unlock --raw)` and `set -e BW_SESSION` instead of Bash's `export` and `unset` syntax.

Never store your vault session, master password, or `rclone.conf` contents in this repository. Do not run secret restoration with shell tracing or Ansible `--diff` or verbose output.

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
| `apps` | Flatpak and Flathub, Telegram, Lutris, Steam, Obsidian, Brave, Postman, Thunderbird |
| `tools` | rclone, Syncthing, Solaar, Input Remapper, Espanso |
| `bitwarden` | Bitwarden CLI/Desktop and `with-bitwarden-secret` wrapper |
| `github_access` | Pinned GitHub host trust, restored identity/agent validation, private repository access |
| `virtualization` | QEMU, KVM, libvirt, virt-manager, default NAT network |
| `legion` | Lenovo-only dependencies, headers, DKMS, pipx tools, Secure Boot status |
| `secrets` | Bitwarden-backed rclone restoration |
| `services` | OpenSSH server and optional Codex CLI |
| `aur` | paru and selected AUR packages on Arch-based distributions |

Ordinary package lists live in [`vars/packages.yml`](vars/packages.yml). Bitwarden Bash/jq helpers enforce secret-file safety and vault session isolation.

`install_syncthing: true` installs Syncthing, starts its user service in the background, and enables it for future boots. It also enables systemd lingering for your account so user services can start before login and keep running after logout. Configure Syncthing devices and folders yourself; the project does not restore its secrets or topology.

## Checks and practical limits

```bash
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --syntax-check site.yml
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" --syntax-check restore-secrets.yml
python3 tests/check-project.py
bash tests/test-bitwarden.sh
bash tests/test-secrets.sh
python3 tests/test-node.py
bash tests/test-github-ssh.sh
ANSIBLE_PLAYBOOK="$HOME/.venvs/ansible-setup/bin/ansible-playbook" python3 tests/test-espanso-integration.py
# Debian smoke test; on Arch add -e setup_family=arch (Fedora: fedora).
"$HOME/.venvs/ansible-setup/bin/ansible-playbook" tests/manifest-smoke.yml
```

The conversion passed syntax checks and adapted mock tests, but it has not been run end to end on every supported distribution. Ansible check mode cannot fully simulate NVM, AUR builds, DKMS, or Bitwarden operations. Some upstream Postman, Espanso, and font downloads follow the original project's URLs without pinned digests.

The SSH and private Espanso tests use ephemeral test-only keys, mock vaults and a
local Git transport; they never access your vault or GitHub account. For a manual
encrypted-key acceptance check, run restoration from a terminal, enter the SSH
passphrase at OpenSSH's prompts, let restoration load the agent, and run the
private tools command above. Full workstation installs and real GitHub access
still need testing on Debian/Ubuntu, Fedora, Arch/CachyOS/fish and Omarchy.
