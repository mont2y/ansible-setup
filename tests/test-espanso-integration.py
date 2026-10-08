"""Run real Ansible modules against temporary homes and a local SSH transport mock.

No packages, services, vaults or remote repositories are accessed.
Set ANSIBLE_PLAYBOOK to use an executable outside PATH.
"""
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
ANSIBLE = os.environ.get('ANSIBLE_PLAYBOOK', shutil.which('ansible-playbook'))
PIN = yaml.safe_load((ROOT/'roles/github_access/vars/main.yml').read_text())['github_verified_host_key']


@unittest.skipUnless(ANSIBLE and os.getuid() != 0, 'Ansible and a normal user are required')
class IntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        cls.work = Path(cls.temp.name)
        cls.home = cls.work/'home'
        cls.home.mkdir(mode=0o700)
        cls.ssh = cls.home/'.ssh'
        cls.ssh.mkdir(mode=0o700)
        cls.private = cls.ssh/'id_ed25519'
        cls.public = Path(str(cls.private)+'.pub')
        subprocess.run(['ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(cls.private)], check=True)
        cls.repo = cls.work/'origin'
        cls.repo.mkdir()
        cls.git('init', '-b', 'main')
        (cls.repo/'match').mkdir()
        (cls.repo/'match/base.yml').write_text('matches: []\n')
        cls.commit('initial')
        cls.bin = cls.work/'bin'
        cls.bin.mkdir()
        (cls.bin/'ssh').write_text('''#!/usr/bin/env python3
import os, sys
args = ' '.join(sys.argv[1:])
if os.environ.get('SSH_AUTH_SOCK') != os.environ['TEST_EXPECTED_AGENT']: sys.exit(87)
for option in ('StrictHostKeyChecking=yes', 'IdentitiesOnly=yes', 'HostKeyAlgorithms=ssh-ed25519', 'BatchMode=yes'):
    if option not in args: sys.exit(88)
if 'git@github.com' not in args or 'git-upload-pack' not in args: sys.exit(89)
with open(os.environ['TEST_SSH_CALLS'], 'a') as f: f.write('ssh\\n')
os.execv('/usr/bin/git-upload-pack', ['git-upload-pack', os.environ['TEST_ORIGIN']])
''')
        (cls.bin/'ssh-add').write_text('#!/bin/sh\nexit 0\n')
        (cls.bin/'espanso').write_text('#!/bin/bash\nprintf "%s\\n" "$*" >> "$TEST_RESTARTS"\n')
        for path in cls.bin.iterdir(): path.chmod(0o700)
        cls.env = dict(os.environ, PATH=f'{cls.bin}:'+os.environ['PATH'],
                       ANSIBLE_HOME=str(cls.work/'ansible'), ANSIBLE_LOCAL_TEMP=str(cls.work/'local'),
                       ANSIBLE_REMOTE_TEMP=str(cls.work/'remote'), ANSIBLE_NOCOLOR='1',
                       TEST_ORIGIN=str(cls.repo), TEST_SSH_CALLS=str(cls.work/'ssh-calls'),
                       TEST_RESTARTS=str(cls.work/'restarts'), GIT_SSH_VARIANT='ssh',
                       SSH_AUTH_SOCK=str(cls.work/'fake-agent'), TEST_EXPECTED_AGENT=str(cls.work/'fake-agent'))
        cls.checkout = cls.home/'.local/share/ansible-setup/espanso-config'
        cls.match = cls.home/'.config/espanso/match'
        cls.match.mkdir(parents=True, mode=0o700)
        (cls.match/'base.yml').write_text('local previous config\n')
        (cls.match/'unrelated.yml').write_text('untouched\n')
        cls.vars = yaml.safe_load((ROOT/'group_vars/all.yml').read_text())
        cls.vars.update(setup_home=str(cls.home), install_espanso=True,
                        ansible_facts={'date_time': {'iso8601_basic_short': '20261008T000000'}},
                        ansible_python_interpreter=shutil.which('python3'))
        cls.varfile = cls.work/'vars.json'
        with tempfile.NamedTemporaryFile(prefix='.test-espanso-', suffix='.yml', dir=ROOT, delete=False) as play:
            cls.play = Path(play.name)
        cls.play.write_text('''- hosts: localhost
  gather_facts: false
  roles:
    - {role: github_access, tags: [github_access, tools]}
  tasks:
    - name: Exercise only the configuration phase
      ansible.builtin.include_role:
        name: tools
        tasks_from: espanso-config
        apply:
          tags: tools
      when: install_espanso | bool and not (test_access_only | default(false) | bool)
      tags: tools
''')

    @classmethod
    def tearDownClass(cls):
        cls.play.unlink(missing_ok=True)
        cls.temp.cleanup()

    @classmethod
    def git(cls, *args):
        return subprocess.run(['git', '-C', str(cls.repo), *args], check=True, capture_output=True)

    @classmethod
    def commit(cls, message):
        cls.git('add', '.')
        cls.git('-c', 'user.name=Test', '-c', 'user.email=test@example.invalid', 'commit', '-m', message)

    def playbook(self, ok=True, **overrides):
        self.varfile.write_text(json.dumps(dict(self.vars, **overrides)))
        result = subprocess.run([ANSIBLE, str(self.play), '-e', '@'+str(self.varfile), '--tags', 'tools'],
                                cwd=ROOT, env=self.env, capture_output=True, text=True)
        output = result.stdout + result.stderr
        self.assertEqual(result.returncode == 0, ok, output)
        self.assertNotIn('BEGIN OPENSSH PRIVATE KEY', output)
        return output

    def test_workflow(self):
        # A missing identity fails before host mutation or cloning.
        self.private.rename(self.work/'saved-key')
        self.playbook(False)
        self.assertFalse(self.checkout.exists())
        (self.work/'saved-key').rename(self.private)
        self.playbook(install_espanso=False)
        self.assertFalse(self.checkout.exists())
        # Bundled config neither reads keys nor contacts the repository.
        self.playbook(espanso_config_source='bundled')
        self.assertFalse((self.work/'ssh-calls').exists())
        self.assertEqual((self.match/'base.yml').resolve(), ROOT/'files/espanso/base.yml')
        self.assertEqual(len(list(self.match.glob('base.yml.backup.*'))), 1)
        # Preserve an existing other-algorithm entry and unrelated host.
        known = self.ssh/'known_hosts'
        known.write_text('example.invalid ' + self.public.read_text() +
                         'github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABAQCTestOnly\n')
        self.playbook()
        self.assertIn(PIN, known.read_text())
        self.assertIn('github.com ssh-rsa', known.read_text())
        self.assertEqual((self.match/'base.yml').resolve(), self.checkout/'match/base.yml')
        self.assertEqual((self.match/'unrelated.yml').read_text(), 'untouched\n')
        self.assertEqual(self.checkout.stat().st_mode & 0o777, 0o700)
        restarts = (self.work/'restarts').read_text()
        rerun = self.playbook()
        self.assertIn('changed=0', rerun)
        self.assertEqual((self.work/'restarts').read_text(), restarts)
        # A new commit is loaded, without losing other matches.
        (self.repo/'match/base.yml').write_text('matches: []\n# updated\n')
        self.commit('update')
        self.playbook()
        self.assertIn('# updated', (self.match/'base.yml').read_text())
        self.assertNotEqual((self.work/'restarts').read_text(), restarts)
        # Dirty checkout is preserved and reported without dumping content.
        (self.checkout/'match/base.yml').write_text('local private edits\n')
        self.assertIn('local edits', self.playbook(False))
        self.assertEqual((self.checkout/'match/base.yml').read_text(), 'local private edits\n')
        subprocess.run(['git', '-C', str(self.checkout), 'restore', 'match/base.yml'], check=True)
        # Conflicts, including hashed entries, stop before replacement.
        conflict = 'github.com ' + self.public.read_text()
        known.write_text(conflict)
        subprocess.run(['ssh-keygen', '-H', '-f', str(known)], capture_output=True, check=True)
        old = known.read_bytes()
        self.assertIn('Conflicting GitHub', self.playbook(False))
        self.assertEqual(known.read_bytes(), old)
        known.unlink()
        known.symlink_to(self.work/'elsewhere')
        self.assertIn('symlink', self.playbook(False))
        known.unlink()
        self.playbook(test_access_only=True)
        # An absent source must preserve the current destination link.
        target = os.readlink(self.match/'base.yml')
        self.playbook(False, espanso_config_base_relative_path='match/missing.yml')
        self.assertEqual(os.readlink(self.match/'base.yml'), target)
        self.playbook(False, espanso_config_base_relative_path='../outside')
        self.assertIn('Cannot read the private Espanso', self.playbook(False, espanso_config_branch='absent-branch'))
        subprocess.run(['git', '-C', str(self.checkout), 'remote', 'set-url', 'origin', 'git@github.com:other/repo.git'], check=True)
        self.assertIn('different origin', self.playbook(False))

    def test_tag_contract(self):
        for tags in ('bitwarden', 'tools'):
            result = subprocess.run([ANSIBLE, 'site.yml', '--list-tasks', '--tags', tags],
                                    cwd=ROOT, env=self.env, capture_output=True, text=True, check=True)
            if tags == 'bitwarden':
                self.assertNotIn('github_access :', result.stdout)
                self.assertIn('Bitwarden', result.stdout)
            else:
                self.assertIn('github_access :', result.stdout)


if __name__ == '__main__':
    unittest.main()
