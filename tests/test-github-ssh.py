"""Offline restoration/security tests using disposable keys and a fake vault."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import pty
import select
import signal
import time
import subprocess
import tempfile
import unittest
import sys

ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / 'scripts/restore-github-ssh.sh'
SPEC = importlib.util.spec_from_file_location('github_ssh', ROOT / 'lib/github_ssh.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)
sys.path.insert(0, str(ROOT / 'lib'))
import github_agent as AGENT
MOCK = '''#!/usr/bin/env python3
import json, os, pathlib, sys
root = pathlib.Path(os.environ['BW_TEST_DIR'])
cmd = sys.argv[1]
with (root/'calls').open('a') as f: f.write(cmd+'\\n')
if cmd == 'status': print(json.dumps({'status': (root/'state').read_text()}))
elif cmd in ('login', 'unlock'):
    (root/'state').write_text('unlocked')
    print('FAKE_SESSION_SENTINEL')
elif cmd == 'lock': (root/'state').write_text('locked')
elif cmd == 'sync': pass
elif cmd == 'list': print((root/'items.json').read_text())
elif cmd == 'get': print((root/(sys.argv[3]+'.json')).read_text())
else: sys.exit(1)
'''


@unittest.skipIf(os.getuid() == 0, 'Restoration deliberately refuses root')
class RestoreTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.addCleanup(self.stop_managed_agent)
        self.home = Path(self.tmp.name)
        self.vault = self.home / 'vault'
        self.vault.mkdir()
        self.bin = self.home / '.local/bin'
        self.bin.mkdir(parents=True)
        (self.bin / 'bw').write_text(MOCK)
        (self.bin / 'bw').chmod(0o700)
        self.env = dict(os.environ, HOME=str(self.home), BW_TEST_DIR=str(self.vault),
                        BW_SESSION='FAKE_SESSION_SENTINEL', PATH=f'{self.bin}:/usr/bin:/bin')
        self.env.pop('SSH_AUTH_SOCK', None)
        (self.vault / 'state').write_text('unlocked')
        self.ids = ['11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222']
        self.key = self.home / 'test-key'
        self.other = self.home / 'other-key'
        for key in (self.key, self.other):
            subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(key)], check=True)
        self.original_private = self.key.read_text()
        self.original_public = Path(str(self.key) + '.pub').read_text()
        self.items = [{'name': 'Linux Setup - github-ssh-' + name, 'id': key_id}
                      for name, key_id in zip(('private', 'public'), self.ids)]
        self.save_items()
        self.note(0, self.original_private)
        self.note(1, self.original_public)
        self.private = self.home / '.ssh/id_ed25519_github'
        self.public = self.home / '.ssh/id_ed25519_github.pub'

    def stop_managed_agent(self):
        pid_file = self.home / '.ssh/ansible-setup-agent/agent.pid'
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text()), signal.SIGTERM)
            except ProcessLookupError:
                pass

    def save_items(self):
        (self.vault / 'items.json').write_text(json.dumps(self.items))

    def note(self, index, value, kind=2):
        (self.vault / (self.ids[index] + '.json')).write_text(json.dumps({'type': kind, 'notes': value}))

    def invoke(self, ok=True, env=None, args=None):
        result = subprocess.run(args or ['bash', str(SCRIPT)], env=env or self.env,
                                stdin=subprocess.DEVNULL, capture_output=True, text=True)
        output = result.stdout + result.stderr
        self.assertNotIn('FAKE_SESSION_SENTINEL', output)
        self.assertNotIn('BEGIN OPENSSH PRIVATE KEY', output)
        for line in self.original_private.splitlines()[1:-1]:
            self.assertNotIn(line, output)
        self.assertEqual(result.returncode == 0, ok, output)
        self.assertFalse(list(self.home.glob('.ssh/.github-ssh-restore.*')))
        return output

    def test_first_restore_and_idempotence(self):
        self.invoke()
        self.assertEqual(self.private.read_text(), self.original_private)
        self.assertEqual(self.public.read_text(), self.original_public)
        inode = self.private.stat().st_ino
        self.private.chmod(0o644)
        self.public.chmod(0o600)
        self.invoke()
        self.assertEqual(self.private.stat().st_ino, inode)
        for path, mode in ((self.private, 0o600), (self.public, 0o644), (self.private.parent, 0o700)):
            self.assertEqual(path.stat().st_mode & 0o777, mode)
        self.assertNotIn('lock', (self.vault / 'calls').read_text().splitlines())

    def test_mismatch_and_conflict_preserve_both_files(self):
        self.invoke()
        self.note(1, Path(str(self.other) + '.pub').read_text())
        self.invoke(False)
        self.assertEqual(self.private.read_text(), self.original_private)
        self.assertEqual(self.public.read_text(), self.original_public)
        self.note(0, self.other.read_text())
        self.invoke(False)
        self.assertEqual(self.private.read_text(), self.original_private)
        self.invoke(env=dict(self.env, GITHUB_SSH_OVERWRITE_EXISTING='true'))
        self.assertEqual(self.private.read_text(), self.other.read_text())

    def test_bad_vault_items(self):
        original = list(self.items)
        for bad in ([], original + original, [dict(x, deletedDate='2026-01-01') for x in original],
                    [dict(x, id='--help') for x in original]):
            self.items = bad
            self.save_items()
            self.invoke(False)
            self.assertFalse(self.private.exists())
        (self.vault/'items.json').write_text('not json')
        self.invoke(False)
        self.items = original
        self.save_items()
        for value, kind in (('', 2), (None, 2), ('bad', 2), (self.original_private, 1)):
            self.note(0, value, kind)
            self.invoke(False)
            self.assertFalse(self.private.exists())

    def test_public_format_and_comments(self):
        for value in ('bad', self.original_public * 2, '\n' + self.original_public, self.original_public + '\n'):
            self.note(1, value)
            self.invoke(False)
        self.note(1, ' '.join(self.original_public.split()[:2]) + ' different comment\n')
        self.invoke()

    def test_unsafe_destinations(self):
        self.private.parent.mkdir(mode=0o700)
        for path in (self.private, self.public):
            path.symlink_to(self.home / 'absent')
            self.invoke(False)
            path.unlink()
            path.mkdir()
            self.invoke(False)
            path.rmdir()
            os.link(self.key, path)
            self.invoke(False)
            path.unlink()
        self.private.write_text(self.original_private)
        self.private.chmod(0o666)
        self.invoke(False)
        self.private.unlink()
        self.private.parent.chmod(0o777)
        self.invoke(False)
        self.private.parent.chmod(0o700)
        self.home.chmod(0o777)
        self.invoke(False)
        self.home.chmod(0o700)
        self.private.parent.rmdir()
        self.private.parent.symlink_to(self.vault, target_is_directory=True)
        self.invoke(False)

    def test_unexpected_owner(self):
        from unittest.mock import patch
        with patch.object(CHECK.os, 'getuid', return_value=os.getuid() + 1):
            with self.assertRaises(CHECK.Unsafe):
                CHECK.safe_path(self.home, self.home, directory=True, required=True)

    def test_write_failure_and_signal_cleanup(self):
        # ln is used by staged note restoration; no installed identity may result.
        for command in ('exit 9', 'kill -TERM "$PPID"; exit 9'):
            mock = self.bin / 'ln'
            mock.write_text('#!/bin/bash\n' + command + '\n')
            mock.chmod(0o700)
            self.invoke(False)
            self.assertFalse(self.private.exists())
            mock.unlink()

    def test_rename_failure_preserves_existing_private_key(self):
        self.invoke()
        self.note(0, self.other.read_text())
        self.note(1, Path(str(self.other)+'.pub').read_text())
        mock = self.bin / 'mv'
        mock.write_text('#!/bin/bash\nexit 9\n')
        mock.chmod(0o700)
        self.invoke(False, dict(self.env, GITHUB_SSH_OVERWRITE_EXISTING='true'))
        self.assertEqual(self.private.read_text(), self.original_private)
        self.assertEqual(self.public.read_text(), self.original_public)

    def test_tracing_missing_tools_and_noninteractive_unlock(self):
        self.invoke(False, args=['bash', '-x', str(SCRIPT)])
        # Use Bash functions exported solely into the child to simulate dependencies.
        for dependency in ('bw', 'jq', 'ssh-keygen', 'ssh-add', 'ssh-agent'):
            env = dict(self.env)
            env['BASH_FUNC_command%%'] = '() { if [[ "$1" == -v && "$2" == ' + dependency + ' ]]; then return 1; fi; builtin command "$@"; }'
            self.invoke(False, env)
        (self.vault/'state').write_text('locked')
        self.assertIn('interactive terminal', self.invoke(False))

    def test_interactive_owned_session_relocks(self):
        if not shutil.which('script'):
            self.skipTest('util-linux script unavailable')
        for valid in (True, False):
            (self.vault/'state').write_text('locked')
            self.note(1, self.original_public if valid else 'bad')
            self.invoke(valid, args=['script', '-q', '-e', '-c', str(SCRIPT), '/dev/null'])
            self.assertEqual((self.vault/'state').read_text(), 'locked')

    def test_encrypted_key_noninteractive(self):
        encrypted = self.home / 'encrypted'
        # Disposable test password, never an actual user credential.
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', 'ephemeral-test-only', '-f', str(encrypted)], check=True)
        self.note(0, encrypted.read_text())
        self.note(1, Path(str(encrypted)+'.pub').read_text())
        self.assertIn('interactive terminal', self.invoke(False))
        self.assertFalse(self.private.exists())

    def test_encrypted_key_interactive_and_agent_guidance(self):
        encrypted = self.home / 'encrypted'
        passphrase = 'ephemeral-test-only'
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', passphrase, '-f', str(encrypted)], check=True)
        self.note(0, encrypted.read_text())
        self.note(1, Path(str(encrypted)+'.pub').read_text())
        pid, terminal = pty.fork()
        if pid == 0:
            os.execve(str(SCRIPT), [str(SCRIPT)], self.env)
        transcript = b''
        prompts_sent = 0
        deadline = time.monotonic() + 15
        try:
            while time.monotonic() < deadline:
                if select.select([terminal], [], [], 0.2)[0]:
                    try:
                        data = os.read(terminal, 4096)
                    except OSError:
                        break
                    if not data:
                        break
                    transcript += data
                    prompts = transcript.lower().count(b'enter passphrase')
                    if prompts > prompts_sent:
                        os.write(terminal, passphrase.encode() + b'\n')
                        prompts_sent += 1
            else:
                os.kill(pid, signal.SIGKILL)
                self.fail('Interactive restore timed out')
        finally:
            os.close(terminal)
            _, status = os.waitpid(pid, 0)
        self.assertEqual(os.waitstatus_to_exitcode(status), 0)
        self.assertEqual(prompts_sent, 2)
        self.assertNotIn(passphrase.encode(), transcript)
        self.assertNotIn(b'FAKE_SESSION_SENTINEL', transcript)
        self.assertNotIn(b'BEGIN OPENSSH PRIVATE KEY', transcript)
        self.assertEqual(self.private.read_bytes(), encrypted.read_bytes())
        result = subprocess.run(['python3', str(ROOT/'lib/github_ssh.py'), 'identity',
                                 '--home', str(self.home), '--private', str(self.private),
                                 '--public', str(self.public)], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('ssh-add', result.stderr)

        # ssh-keygen -lf PRIVATE may trust PRIVATE.pub. A swapped adjacent public
        # file must be rejected by inspecting the encrypted container itself.
        self.public.write_bytes(Path(str(self.other)+'.pub').read_bytes())
        mismatch = subprocess.run(['python3', str(ROOT/'lib/github_ssh.py'), 'identity',
                                  '--home', str(self.home), '--private', str(self.private),
                                  '--public', str(self.public)], env=self.env, capture_output=True, text=True)
        self.assertNotEqual(mismatch.returncode, 0)
        self.assertIn('mismatched', mismatch.stderr)
        self.public.write_bytes(Path(str(encrypted)+'.pub').read_bytes())

        # The restore script itself started and loaded this isolated agent.
        socket = self.home / '.ssh/ansible-setup-agent/agent.sock'
        discovered = subprocess.run(['python3', str(ROOT/'lib/github_agent.py'), 'socket',
                                     '--home', str(self.home)], env=self.env, capture_output=True, text=True, check=True)
        self.assertEqual(discovered.stdout.strip(), str(socket))
        agent_env = dict(self.env, SSH_AUTH_SOCK=str(socket))
        checked = subprocess.run(['python3', str(ROOT/'lib/github_ssh.py'), 'identity',
                                  '--home', str(self.home), '--private', str(self.private),
                                  '--public', str(self.public)], env=agent_env, capture_output=True)
        self.assertEqual(checked.returncode, 0, checked.stderr.decode())
        pid_before = (socket.parent/'agent.pid').read_text()
        # Loading an already-unlocked key is idempotent and needs no terminal.
        for env in (self.env, agent_env, dict(self.env, SSH_AUTH_SOCK=str(self.home/'stale.sock'))):
            ready = subprocess.run(['python3', str(ROOT/'lib/github_agent.py'), 'load',
                                    '--home', str(self.home), '--private', str(self.private),
                                    '--public', str(self.public)], env=env, stdin=subprocess.DEVNULL,
                                   capture_output=True, text=True)
            self.assertEqual(ready.returncode, 0, ready.stderr)
            self.assertIn('loaded in an SSH agent', ready.stdout)
            self.assertEqual((socket.parent/'agent.pid').read_text(), pid_before)

    def test_agent_load_failure_stops_only_new_agents(self):
        from unittest.mock import patch
        self.private.parent.mkdir(mode=0o700)
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', 'ephemeral-test-only',
                        '-f', str(self.private)], check=True)
        original = self.private.read_bytes()
        with patch.dict(os.environ, self.env, clear=True), \
                patch.object(sys.stdin, 'isatty', return_value=True), \
                patch.object(sys.stderr, 'isatty', return_value=True), \
                patch.object(AGENT, 'add_key', side_effect=AGENT.Unsafe('Simulated rejected passphrase')), \
                patch.object(AGENT.os, 'kill', wraps=os.kill) as killed:
            with self.assertRaises(AGENT.Unsafe):
                AGENT.load(str(self.home), str(self.private), str(self.public), os.getppid())
            killed.assert_called_once()
            self.assertEqual(killed.call_args.args[1], signal.SIGTERM)
        state = self.private.parent/'ansible-setup-agent'
        self.assertFalse((state/'agent.pid').exists())
        self.assertFalse((state/'agent.sock').exists())
        self.assertEqual(self.private.read_bytes(), original)

        socket = self.home/'existing-agent.sock'
        agent = subprocess.Popen(['ssh-agent', '-D', '-a', str(socket)],
                                 stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            deadline = time.monotonic() + 5
            while not socket.exists() and time.monotonic() < deadline and agent.poll() is None:
                time.sleep(0.02)
            self.assertTrue(socket.exists())
            with patch.dict(os.environ, dict(self.env, SSH_AUTH_SOCK=str(socket)), clear=True), \
                    patch.object(AGENT, 'add_key', side_effect=AGENT.Unsafe('Simulated rejected passphrase')), \
                    patch.object(AGENT.os, 'kill', wraps=os.kill) as killed:
                with self.assertRaises(AGENT.Unsafe):
                    AGENT.load(str(self.home), str(self.private), str(self.public), os.getppid())
                killed.assert_not_called()
            self.assertIsNone(agent.poll())
            self.assertTrue(socket.exists())
        finally:
            agent.terminate()
            agent.wait(timeout=5)

    def test_managed_agent_rejects_unsafe_state(self):
        self.private.parent.mkdir(mode=0o700)
        directory = self.private.parent / 'ansible-setup-agent'
        directory.symlink_to(self.vault, target_is_directory=True)
        with self.assertRaises(AGENT.Unsafe):
            AGENT.managed_paths(self.home)
        directory.unlink()
        directory.mkdir(mode=0o700)
        socket = directory/'agent.sock'
        socket.write_text('unrelated data')
        with self.assertRaises(AGENT.Unsafe):
            AGENT.managed_paths(self.home)
        self.assertEqual(socket.read_text(), 'unrelated data')

    def test_shell_detection_and_connection_quoting(self):
        # Evaluate only our generated socket assignment, in each real shell.
        tricky = str(self.home / "socket with '$dollar`tick\\slash")
        for shell in ('bash', 'zsh', 'fish'):
            binary = shutil.which(shell)
            if not binary:
                continue
            command = AGENT.connection_command(shell, tricky)
            result = subprocess.run([binary, '-c', command + '; printenv SSH_AUTH_SOCK'],
                                    env=self.env, capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.rstrip('\n'), tricky)
            pid_var = '$fish_pid' if shell == 'fish' else '$$'
            # The process name must win over an intentionally wrong login SHELL.
            python = "import sys; sys.path.insert(0, sys.argv[1]); import github_agent; print(github_agent.caller_shell(sys.argv[2]))"
            import shlex
            detection = 'python3 -c ' + shlex.quote(python) + ' ' + shlex.quote(str(ROOT/'lib')) + ' ' + pid_var + '; true'
            result = subprocess.run([binary, '-c', detection], env=dict(self.env, SHELL='/bin/wrong'),
                                    capture_output=True, text=True, check=True)
            self.assertEqual(result.stdout.strip(), shell)

    def test_empty_agent_is_available_and_vault_environment_is_removed(self):
        from unittest.mock import patch
        for status, expected in ((0, True), (1, True), (2, False)):
            with patch.object(AGENT, 'run', return_value=subprocess.CompletedProcess([], status)):
                self.assertEqual(AGENT.available('/tmp/mock-socket'), expected)
        with patch.object(AGENT, 'run', side_effect=subprocess.TimeoutExpired('ssh-add', 3)):
            with self.assertRaises(AGENT.Unsafe):
                AGENT.available('/tmp/mock-socket')
        with patch.dict(os.environ, BW_SESSION='FAKE_SESSION_SENTINEL', BW_PASSWORD='fake', BITWARDENCLI_DEBUG='true'):
            env = AGENT.agent_environment('/tmp/mock-socket')
        self.assertFalse(any(key.startswith(('BW_', 'BITWARDEN')) for key in env))


if __name__ == '__main__':
    unittest.main()
