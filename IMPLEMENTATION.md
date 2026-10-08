# Conversion notes

Source: `mont2y/test-setup`, commit `bc0a6016fa44e9bd2ed04167b9b83224fe60621b`.

## Mapping

| Source | Ansible implementation |
| --- | --- |
| `settings.sh` | `group_vars/all.yml`, retained switch names in lowercase; Syncthing recovery switches removed |
| `packages/*.txt`, `lib/packages.sh` | `vars/packages.yml` and `roles/manifest` (skip unavailable packages; fail actual install errors) |
| `00-system.sh` | `roles/system` |
| `10-shell.sh` | `roles/shell`, with backups before relinking |
| `20-terminal.sh` | `roles/terminal`, with package fonts and upstream fallbacks |
| `30-dev.sh` | `roles/development`, plus `roles/aur` |
| `40-apps.sh` | `roles/apps` |
| `50-tools.sh` | `roles/tools`, including Syncthing installation and automatic user-service startup |
| `55-bitwarden.sh` | `roles/bitwarden`; native checksum-verifying installer preserved for fallback |
| `60-virtualization.sh` | `roles/virtualization` and `community.libvirt.virt_net` |
| `70-legion.sh` | `roles/legion` |
| `80-secrets.sh`, `restore-secrets.sh` | `roles/secrets`, `scripts/restore-secrets.sh`, preserved validated helpers |
| `90-services.sh` | `roles/services` |
| `scripts/with-bitwarden-secret` | Preserved runtime executable linked to user bin |

The Bitwarden helpers retain file validation and vault session isolation beyond Ansible's standard modules. They are tested with adapted upstream mock suites. Secret values are never placed in YAML variables. Use `scripts/restore-secrets.sh` to restore rclone interactively; Ansible's `no_log` suppresses restoration output when the role invokes the helper.

Syncthing recovery, identity preparation, and topology management have been removed. The project installs the package, starts and enables its user service, and enables systemd lingering for the account so it runs from boot and after logout. Syncthing manages its own runtime configuration.

## Validation completed

- All YAML loads with PyYAML; the retained original settings keys have counterparts in `group_vars/all.yml`.
- Both playbooks pass `ansible-playbook --syntax-check` using ansible 13.4.0 / core 2.20.9 and `community.general` 12.4.0 / `community.libvirt` 2.1.0.
- Adapted upstream tests cover Bitwarden authentication and checksum fallback, secret file restore and process injection.
- Local read-only manifest smoke test checks behavior when a package is unavailable.
- The full upstream mock suite passed at the pinned source commit.

## Limits of offline validation

No full workstation install was performed. Fedora and Arch package names and upstream download endpoints are inherited from the pinned source but should be exercised on those systems. Full Ansible check mode cannot model commands that install NVM, AUR packages, DKMS modules, or secrets. Postman and Espanso use unpinned upstream latest assets as the source did.

## GitHub identity and private Espanso configuration (2026-10-08)

Implemented the two-phase workflow in `newplan.md` on
`feat/bitwarden-github-ssh-espanso`. Existing rclone authentication/restoration and
Syncthing behavior remain unchanged. `scripts/restore-github-ssh.sh` reads the two
named Secure Notes through the existing Bitwarden helpers, validates them using
OpenSSH, and promotes the pair from protected staging. `lib/github_ssh.py` supplies
path, keypair, SSH-agent and host-conflict checks without returning key contents
to Ansible. The final two file promotions are individually atomic, not a single
transaction; the private file is promoted last. No private-key backups are made.

`github_access` runs before tools, including `--tags tools`, while the Bitwarden
bootstrap tag remains independent. The host pin was independently verified against
GitHub's official documentation on 2026-10-08. Encrypted identities use the caller's
SSH agent or the agent created by interactive restoration; neither the role nor
the main playbook prompts for SSH passphrases.
Private configuration uses a separate, protected checkout with strict SSH checking,
rejects dirty or unrelated checkouts, and manages only Espanso's `match/base.yml`.
The default source is `private_git`, using `mont2y/espanso-config` on `main`.
The README documents the required SSH bootstrap and migration instructions.
`bundled` remains an explicit opt-in with a generic date example.

Baseline checks before implementation: YAML/settings/package validation, five Node
tests, Bitwarden mocks and rclone/secret-injection mocks all passed. No Ansible or
ShellCheck executable was initially installed; validation tools were installed in
an isolated `/tmp` virtual environment (Ansible 13.4.0, core 2.20.10; ShellCheck
0.11.0). No live vault, user SSH identity, GitHub account or private repository was
accessed. The SSH tests create disposable keys and fake vault records. Ansible
integration tests use real modules, temporary homes, a local Git repository and a
mock SSH transport to exercise host conflicts, gates, backups, clone/update,
idempotence and preservation of local edits. These are offline checks, not real
GitHub or distro acceptance tests. Full Debian/Ubuntu, Fedora, Arch/CachyOS/fish
and Omarchy installation checks still require suitable machines.

Final validation: 12 SSH tests passed, including an interactive encrypted-key
restore through a pseudo-terminal and validation after loading a disposable SSH
agent. The agent test needed execution outside the sandbox because local socket
creation was restricted. Both Ansible integration tests passed (including their
multi-step scenarios); both playbooks passed syntax checks with the pinned
collections. Existing YAML, Node, Bitwarden and rclone tests passed, and the
unavailable-package manifest smoke test passed with the Arch family override.
New shell entry points pass `bash -n` and ShellCheck with sourced files followed.
A whole-tree ShellCheck run still reports existing standalone helper annotations
and sourced-variable warnings in `files/helpers/restore-module.sh` and
`files/helpers/items.sh`; their runtime behavior was not changed to suppress lint.

## Automatic agent setup after SSH restoration

Restoration now loads encrypted keys into a reachable existing agent or starts
one at `~/.ssh/ansible-setup-agent/agent.sock`. `lib/github_agent.py` manages
protected agent state and shell detection; it parses the explicitly requested
`ssh-agent -s` output without evaluating shell code. Ansible discovers the socket
and passes it to identity checks, repository probes and the private Git module,
so child-process environment isolation does not require manual shell exports.
For manual Git use the script prints `export` for Bash/Zsh or `set -gx` for fish,
detecting the actual caller before falling back to the login-shell preference.
Only a newly started agent is terminated on failure. Vault cleanup happens before
agent setup, and the daemon environment excludes Bitwarden authentication data.

Agent validation passed 16 SSH tests, including real encrypted-key loading,
existing-agent reuse, new-agent failure cleanup, preservation of existing agents,
and socket-command execution in Bash, Zsh and fish. Both Ansible integration
tests passed with the selected socket asserted in the local mock SSH transport.
Playbook syntax, YAML validation, new-script ShellCheck and existing Bitwarden
and rclone regression suites passed. These tests used temporary identities only.
