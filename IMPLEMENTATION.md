# Conversion notes

Source: `mont2y/test-setup`, commit `bc0a6016fa44e9bd2ed04167b9b83224fe60621b`.

## Mapping

| Source | Ansible implementation |
| --- | --- |
| `settings.sh` | `group_vars/all.yml`, same switch names in lowercase |
| `packages/*.txt`, `lib/packages.sh` | `vars/packages.yml` and `roles/manifest` (skip unavailable packages; fail actual install errors) |
| `00-system.sh` | `roles/system` |
| `10-shell.sh` | `roles/shell`, with backups before relinking |
| `20-terminal.sh` | `roles/terminal`, with package fonts and upstream fallbacks |
| `30-dev.sh` | `roles/development`, plus `roles/aur` |
| `40-apps.sh` | `roles/apps` |
| `50-tools.sh` | `roles/tools`, with Syncthing identity preparation before user service start |
| `55-bitwarden.sh` | `roles/bitwarden`; native checksum-verifying installer preserved for fallback |
| `60-virtualization.sh` | `roles/virtualization` and `community.libvirt.virt_net` |
| `70-legion.sh` | `roles/legion` |
| `80-secrets.sh`, `restore-secrets.sh` | `roles/secrets`, `scripts/restore-secrets.sh`, preserved validated helpers |
| `90-services.sh` | `roles/services` |
| `scripts/with-bitwarden-secret` | Preserved runtime executable linked to user bin |

The Bitwarden and Syncthing recovery programs remain executable because they implement validation and process isolation beyond Ansible's standard modules. They were copied from the pinned source commit and are tested with the adapted upstream mock suites. Their data is never placed in YAML variables. On a clean run, configure the vault in an interactive terminal using `scripts/restore-secrets.sh` for the peer acceptance commands. Ansible's `no_log` obscures the restoration output when the role invokes the helper.

## Validation completed

- All YAML loads with PyYAML; the original settings keys have counterparts in `group_vars/all.yml`.
- Both playbooks pass `ansible-playbook --syntax-check` using ansible 13.4.0 / core 2.20.9 and `community.general` 12.4.0 / `community.libvirt` 2.1.0.
- Adapted upstream tests cover Bitwarden authentication and checksum fallback, secret file restore and process injection, Syncthing checksum/schema/path safety and additive reruns.
- Local read-only manifest smoke test checks behavior when a package is unavailable.
- The full upstream mock suite passed at the pinned source commit.

## Limits of offline validation

No full workstation install was performed. Fedora and Arch package names and upstream download endpoints are inherited from the pinned source but should be exercised on those systems. Full Ansible check mode cannot model commands that install NVM, AUR packages, DKMS modules, or secrets. The user systemd session must exist for Syncthing service operations. Postman and Espanso use unpinned upstream latest assets as the source did.
