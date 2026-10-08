#!/usr/bin/env python3
"""Load the restored identity and discover its agent without exporting secrets."""
import argparse
import base64
import fcntl
import os
from pathlib import Path
import re
import shlex
import signal
import stat
import subprocess
import sys
import time

from github_ssh import Unsafe, encrypted_public_blob, public_fields, run, safe_path


def agent_environment(socket):
    # A newly started daemon must never inherit the vault's authentication state.
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(('BW_', 'BITWARDEN'))}
    env['SSH_AUTH_SOCK'] = str(socket)
    env.pop('SSH_AGENT_PID', None)
    return env


def available(socket):
    if not socket:
        return False
    # Exit 1 is a reachable agent with no identities, not a reason to start another.
    try:
        return run(['ssh-add', '-l'], env=agent_environment(socket), timeout=3).returncode in (0, 1)
    except subprocess.TimeoutExpired:
        raise Unsafe('SSH agent is not responding; resolve it before retrying. Its socket was preserved.') from None


def managed_paths(home):
    directory = safe_path(Path(home) / '.ssh/ansible-setup-agent', home, directory=True)
    if directory.exists() and stat.S_IMODE(directory.stat().st_mode) != 0o700:
        raise Unsafe('Managed agent directory must have mode 0700; repair its permissions first.')
    socket = directory / 'agent.sock'
    if socket.exists() or socket.is_symlink():
        info = socket.lstat()
        if not stat.S_ISSOCK(info.st_mode) or info.st_uid != os.getuid():
            raise Unsafe('Managed agent socket must be a user-owned socket, never a symlink or regular file.')
        if stat.S_IMODE(info.st_mode) != 0o600:
            raise Unsafe('Managed agent socket must have mode 0600; repair its permissions first.')
    return directory, socket


def discover(home):
    inherited = os.environ.get('SSH_AUTH_SOCK', '')
    if available(inherited):
        return inherited
    _, socket = managed_paths(home)
    return str(socket) if available(str(socket)) else ''


def caller_shell(pid):
    # The current terminal may differ from the account's login-shell preference.
    try:
        shell = Path(os.readlink(f'/proc/{pid}/exe')).name
        if shell in ('bash', 'zsh', 'fish'):
            return shell
    except OSError:
        pass
    shell = Path(os.environ.get('SHELL', '')).name
    return shell if shell in ('bash', 'zsh', 'fish') else ''


def connection_command(shell, socket):
    if shell == 'fish':
        quoted = "'" + socket.replace('\\', '\\\\').replace("'", "\\'") + "'"
        return 'set -gx SSH_AUTH_SOCK ' + quoted
    if shell in ('bash', 'zsh'):
        return 'export SSH_AUTH_SOCK=' + shlex.quote(socket)
    return ''


def report(socket, shell_pid):
    print('GitHub SSH key is loaded in an SSH agent. Ansible will discover it automatically.')
    if socket != os.environ.get('SSH_AUTH_SOCK'):
        shell = caller_shell(shell_pid)
        command = connection_command(shell, socket)
        if command:
            print(f'For manual Git/SSH in this {shell} terminal, run:')
            print(command)
        else:
            print('For manual Git/SSH, export SSH_AUTH_SOCK using your shell syntax: ' + socket)


def add_key(socket, private, public):
    env = agent_environment(socket)
    if run(['ssh-add', '-T', str(public)], env=env).returncode == 0:
        return
    if not (sys.stdin.isatty() and sys.stderr.isatty()):
        raise Unsafe('Loading the encrypted key requires an interactive terminal; rerun scripts/restore-github-ssh.sh there.')
    env['SSH_ASKPASS_REQUIRE'] = 'never'
    # OpenSSH reads the passphrase directly from /dev/tty. Captured diagnostics
    # are discarded, including the key comment normally printed by ssh-add.
    if run(['ssh-add', str(private)], env=env).returncode:
        raise Unsafe('Could not load the restored SSH key into the agent; installed files are preserved. Rerun restoration in a terminal.')
    if run(['ssh-add', '-T', str(public)], env=env).returncode:
        raise Unsafe('The SSH agent cannot use the restored key; installed files are preserved.')


def load(home, private, public, shell_pid):
    for path, mode in ((private, 0o600), (public, 0o644)):
        safe_path(path, home, required=True)
        if Path(path).parent != Path(home) / '.ssh' or stat.S_IMODE(Path(path).stat().st_mode) != mode:
            raise Unsafe('Use restored identity files directly under ~/.ssh with modes 0600/0644.')
    expected = public_fields(public)
    derived = run(['ssh-keygen', '-y', '-P', '', '-f', private])
    if derived.returncode == 0:
        if derived.stdout.split()[:2] != expected:
            raise Unsafe('Private and public SSH keys do not match.')
        print('Unencrypted GitHub SSH key is ready for direct use; no agent is required.')
        return
    if encrypted_public_blob(private) != base64.b64decode(expected[1], validate=True):
        raise Unsafe('Private and public SSH keys do not match.')
    socket = discover(home)
    if socket:
        add_key(socket, private, public)
        report(socket, shell_pid)
        return
    if not (sys.stdin.isatty() and sys.stderr.isatty()):
        raise Unsafe('Starting an agent for an encrypted key requires an interactive terminal.')
    directory, managed_socket = managed_paths(home)
    directory.mkdir(mode=0o700, parents=True, exist_ok=True)
    directory.chmod(0o700)
    lock_path = safe_path(directory / 'lock', home)
    # Lock the protected state directory to avoid duplicate agents on concurrent runs.
    with os.fdopen(os.open(lock_path, os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW, 0o600), 'w') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        socket = discover(home)
        if socket:
            add_key(socket, private, public)
            report(socket, shell_pid)
            return
        managed_paths(home)  # Recheck socket type after taking the lock.
        managed_socket.unlink(missing_ok=True)  # Only a dead, owned socket is removed.
        pid_path = safe_path(directory / 'agent.pid', home)
        pid_path.unlink(missing_ok=True)
        created_pid = None
        keep_agent = False
        try:
            # Python sets the environment itself; do not eval shell-generated text.
            # -s is requested explicitly regardless of the caller's shell.
            started = run(['ssh-agent', '-s', '-a', str(managed_socket)],
                          env=agent_environment(managed_socket))
            match = re.search(rb'^SSH_AGENT_PID=([0-9]+);', started.stdout, re.MULTILINE)
            if started.returncode or not match:
                raise Unsafe('Could not start ssh-agent; check OpenSSH installation and socket permissions.')
            created_pid = int(match.group(1))
            pid_path.write_text(str(created_pid) + '\n')
            pid_path.chmod(0o600)
            for _ in range(50):
                if available(str(managed_socket)):
                    break
                time.sleep(0.1)
            else:
                raise Unsafe('The new SSH agent did not become available.')
            add_key(str(managed_socket), private, public)
            report(str(managed_socket), shell_pid)
            keep_agent = True
        finally:
            # Never terminate a pre-existing or desktop-managed agent.
            if created_pid is not None and not keep_agent:
                try:
                    os.kill(created_pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                managed_socket.unlink(missing_ok=True)
                pid_path.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['load', 'socket'])
    parser.add_argument('--home', required=True)
    parser.add_argument('--private')
    parser.add_argument('--public')
    parser.add_argument('--shell-pid', type=int, default=os.getppid())
    args = parser.parse_args()
    if os.getuid() == 0:
        raise Unsafe('Run agent setup as your normal user, never root.')
    if args.action == 'socket':
        print(discover(args.home))
    else:
        if not args.private or not args.public:
            parser.error('load requires --private and --public')
        load(args.home, args.private, args.public, args.shell_pid)


if __name__ == '__main__':
    def interrupted(signum, frame):
        raise KeyboardInterrupt

    for event in (signal.SIGTERM, signal.SIGHUP):
        signal.signal(event, interrupted)
    try:
        main()
    except KeyboardInterrupt:
        print('SSH agent setup interrupted; installed identity files are preserved.', file=sys.stderr)
        sys.exit(130)
    except (Unsafe, OSError) as error:
        print('SSH agent setup failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
