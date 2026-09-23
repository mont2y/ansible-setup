"""Exercise the Node task shell commands offline using an isolated mock NVM."""
from pathlib import Path
import subprocess
import tempfile
import unittest

import jinja2
import yaml


ROOT = Path(__file__).resolve().parents[1]
TASKS = yaml.safe_load((ROOT / 'roles/development/tasks/node.yml').read_text())
JINJA = jinja2.Environment(undefined=jinja2.StrictUndefined)


class NodeTasksTest(unittest.TestCase):
    def run_task(self, index, mock):
        with tempfile.TemporaryDirectory() as directory:
            home = Path(directory)
            (home / '.nvm').mkdir()
            (home / '.nvm/nvm.sh').write_text(mock)
            script = JINJA.from_string(TASKS[index]['ansible.builtin.shell']).render(
                setup_home=directory
            )
            result = subprocess.run(['/bin/bash', '-c', script], capture_output=True, text=True)
            return {'rc': result.returncode, 'stdout': result.stdout.rstrip('\n')}

    def probe_failed(self, result):
        return JINJA.compile_expression(TASKS[1]['failed_when'])(existing_node_lts=result)

    def test_fresh_install_reaches_install_task(self):
        result = self.run_task(1, 'nvm() { echo N/A; return 3; }\n')
        self.assertFalse(self.probe_failed(result))
        self.assertTrue(JINJA.compile_expression(TASKS[2]['when'])(
            existing_node_lts=result, ansible_check_mode=False
        ))

    def test_installed_lts_skips_install(self):
        result = self.run_task(1, 'nvm() { echo v22.0.0; }\n')
        self.assertFalse(self.probe_failed(result))
        self.assertFalse(JINJA.compile_expression(TASKS[2]['when'])(
            existing_node_lts=result, ansible_check_mode=False
        ))

    def test_unexpected_probe_failures_are_fatal(self):
        for mock in ['return 9\n', 'nvm() { echo N/A; return 1; }\n',
                     'nvm() { echo broken; return 3; }\n']:
            with self.subTest(mock=mock):
                self.assertTrue(self.probe_failed(self.run_task(1, mock)))

    def test_failed_install_does_not_set_alias(self):
        result = self.run_task(2, '''nvm() {
            case "$1" in
                install) return 7 ;;
                alias) echo alias-was-called ;;
            esac
        }
        ''')
        self.assertEqual(result['rc'], 7)
        self.assertEqual(result['stdout'], '')

    def test_successful_install_sets_alias(self):
        result = self.run_task(2, 'nvm() { echo "$*"; }\n')
        self.assertEqual(result['rc'], 0)
        self.assertEqual(result['stdout'], 'install --lts\nalias default lts/*')


if __name__ == '__main__':
    unittest.main()
