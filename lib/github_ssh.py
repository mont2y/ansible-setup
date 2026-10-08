#!/usr/bin/env python3
"""Local SSH checks. Never print key data or captured command diagnostics."""
import argparse
import base64
import os
from pathlib import Path
import stat
import struct
import subprocess
import sys


class Unsafe(ValueError):
    pass


def run(args, **kwargs):
    return subprocess.run(args, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kwargs)


def safe_path(path, home, *, directory=False, required=False):
    path, home = Path(path), Path(home)
    if not path.is_absolute() or '..' in path.parts or not path.is_relative_to(home):
        raise Unsafe('Path must be absolute and inside the account home without parent traversal.')
    # User namespaces may expose the filesystem root owner as an overflow UID.
    root_uid = Path('/').stat().st_uid
    for part in [*reversed(path.parents), path]:
        try:
            info = part.lstat()
        except FileNotFoundError:
            if required or part == home:
                raise Unsafe('Required path is missing; run scripts/restore-github-ssh.sh first.') from None
            continue
        if stat.S_ISLNK(info.st_mode):
            raise Unsafe('Refusing a symlink in the managed path.')
        inside = part.is_relative_to(home)
        if info.st_uid not in ({os.getuid()} if inside else {root_uid, os.getuid()}):
            raise Unsafe('Path has unexpected ownership.')
        # A root-owned sticky temporary ancestor is allowed for isolated tests.
        sticky_root = not inside and info.st_uid == root_uid and info.st_mode & stat.S_ISVTX
        if info.st_mode & 0o022 and not sticky_root:
            raise Unsafe('Path is writable by group or others; repair its permissions first.')
        if part != path or directory:
            if not stat.S_ISDIR(info.st_mode):
                raise Unsafe('Expected a regular directory.')
        elif not stat.S_ISREG(info.st_mode) or info.st_nlink != 1:
            raise Unsafe('Refusing a non-regular or hard-linked file.')
    return path


def public_fields(path):
    data = Path(path).read_bytes()
    lines = data.splitlines()
    if len(lines) != 1:
        raise Unsafe('Expected exactly one OpenSSH public key entry.')
    fields = lines[0].split()
    if len(fields) < 2 or fields[0] not in (b'ssh-ed25519', b'ssh-rsa', b'ecdsa-sha2-nistp256', b'ecdsa-sha2-nistp384', b'ecdsa-sha2-nistp521'):
        raise Unsafe('Unsupported key type; use an Ed25519, RSA or ECDSA OpenSSH key.')
    try:
        base64.b64decode(fields[1], validate=True)
    except ValueError:
        raise Unsafe('Malformed OpenSSH public key.') from None
    if run(['ssh-keygen', '-lf', str(path)]).returncode:
        raise Unsafe('Malformed OpenSSH public key.')
    return fields[:2]


def encrypted_public_blob(path):
    """Read the public header without trusting an adjacent .pub file.

    ssh-keygen -lf PRIVATE may fingerprint PRIVATE.pub instead. OpenSSH's key
    container keeps its public key in plaintext even when its private block is
    encrypted. Restoration performs the full decrypt-and-derive validation;
    unattended runs compare this header and prove agent possession separately.
    """
    try:
        lines = Path(path).read_bytes().splitlines()
        if lines[0] != b'-----BEGIN OPENSSH PRIVATE KEY-----' or lines[-1] != b'-----END OPENSSH PRIVATE KEY-----':
            raise ValueError
        data = base64.b64decode(b''.join(lines[1:-1]), validate=True)
        magic = b'openssh-key-v1\0'
        if not data.startswith(magic):
            raise ValueError
        offset = len(magic)

        def number():
            nonlocal offset
            value = struct.unpack_from('>I', data, offset)[0]
            offset += 4
            return value

        def string():
            nonlocal offset
            size = number()
            value = data[offset:offset + size]
            offset += size
            if len(value) != size:
                raise ValueError
            return value

        cipher, kdf, options = string(), string(), string()
        if cipher == b'none' or kdf != b'bcrypt' or not options or number() != 1:
            raise ValueError
        public = string()
        if not string() or offset != len(data):
            raise ValueError
        return public
    except (ValueError, IndexError, struct.error):
        raise Unsafe('Invalid encrypted OpenSSH private key; rerun interactive restoration.') from None


def pair(private, public, interactive=False, agent=False):
    expected = public_fields(public)
    result = run(['ssh-keygen', '-y', '-P', '', '-f', str(private)])
    if result.returncode == 0:
        if result.stdout.split()[:2] != expected:
            raise Unsafe('Private and public SSH keys do not match.')
    elif interactive and sys.stdin.isatty() and sys.stderr.isatty():
        # OpenSSH prompts through /dev/tty; suppress diagnostics that could include data.
        env = dict(os.environ, SSH_ASKPASS_REQUIRE='never')
        result = run(['ssh-keygen', '-y', '-f', str(private)], env=env)
        if result.returncode or result.stdout.split()[:2] != expected:
            raise Unsafe('Invalid private key, incorrect passphrase, or mismatched keypair.')
    elif agent:
        if encrypted_public_blob(private) != base64.b64decode(expected[1], validate=True):
            raise Unsafe('Invalid or mismatched encrypted keypair; rerun interactive restoration.')
        if not os.environ.get('SSH_AUTH_SOCK') or run(['ssh-add', '-T', str(public)]).returncode:
            raise Unsafe('Encrypted key needs an unlocked SSH agent: rerun scripts/restore-github-ssh.sh in a terminal to load it automatically, then rerun Ansible. Manual alternative: ssh-add ~/.ssh/id_ed25519.')
    else:
        raise Unsafe('Invalid or encrypted private key: rerun in an interactive terminal to enter its passphrase.')
    fingerprint = run(['ssh-keygen', '-lf', str(public)]).stdout.split()
    print('SSH keypair verified: ' + fingerprint[1].decode() + ' (' + expected[0].decode() + ')')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['paths', 'pair', 'identity', 'host', 'directory', 'file'])
    parser.add_argument('--home', default=os.environ.get('HOME'))
    parser.add_argument('--private')
    parser.add_argument('--public')
    parser.add_argument('--path')
    parser.add_argument('--host-key')
    parser.add_argument('--interactive', action='store_true')
    args = parser.parse_args()
    if os.getuid() == 0:
        raise Unsafe('Run SSH restoration/checks as your normal user, never root.')
    if args.action in ('paths', 'identity'):
        safe_path(args.home, args.home, directory=True, required=True)
        for path in (args.private, args.public):
            if Path(path).parent != Path(args.home) / '.ssh':
                raise Unsafe('SSH identity paths must be directly inside ~/.ssh.')
            safe_path(path, args.home, required=args.action == 'identity')
        if args.private == args.public:
            raise Unsafe('Private and public key paths must differ.')
    if args.action == 'identity':
        for path, mode in ((args.private, 0o600), (args.public, 0o644)):
            if stat.S_IMODE(Path(path).stat().st_mode) != mode:
                raise Unsafe('SSH key modes must be 0600 (private) and 0644 (public); rerun restoration.')
        pair(args.private, args.public, agent=True)
    elif args.action == 'pair':
        pair(args.private, args.public, interactive=args.interactive)
    elif args.action == 'host':
        path = safe_path(args.path, args.home)
        if path.exists():
            result = run(['ssh-keygen', '-F', 'github.com', '-f', str(path)])
            if result.returncode not in (0, 1):
                raise Unsafe('Cannot inspect known_hosts.')
            expected = args.host_key.split()[1:3]
            for line in result.stdout.decode().splitlines():
                if line.startswith('#'):
                    continue
                fields = line.split()
                offset = 1 if fields and fields[0].startswith('@') else 0
                if len(fields) > offset + 2 and fields[offset + 1] == 'ssh-ed25519':
                    if offset or fields[offset + 1:offset + 3] != expected:
                        raise Unsafe('Conflicting GitHub Ed25519 host key: verify GitHub announcements and resolve known_hosts manually. No key was replaced.')
    elif args.action in ('directory', 'file'):
        safe_path(args.path, args.home, directory=args.action == 'directory', required=args.action == 'file')


if __name__ == '__main__':
    try:
        main()
    except (Unsafe, OSError, ValueError) as error:
        # Exceptions from subprocess never include key output; file errors have paths only.
        print('SSH/config validation failed: ' + str(error), file=sys.stderr)
        sys.exit(1)
