from pathlib import Path
import yaml

root = Path(__file__).resolve().parents[1]
for path in sorted(root.rglob('*.yml')):
    if 'files/espanso/' in str(path):
        continue
    with path.open() as stream:
        list(yaml.safe_load_all(stream))
settings = yaml.safe_load((root / 'group_vars/all.yml').read_text())
source = (root.parent / 'source/settings.sh')
if source.exists():
    import re
    expected = {key.lower() for key in re.findall(r'^([A-Z][A-Z_]+)=', source.read_text(), re.M)}
    missing = expected - settings.keys()
    assert not missing, f'Missing settings: {sorted(missing)}'
packages = yaml.safe_load((root / 'vars/packages.yml').read_text())['setup_packages']
assert all(isinstance(p, list) for p in packages.values())
assert 'fonts_debian' in packages and 'legion_clang_arch' in packages
assert 'no_log: true' in (root / 'roles/secrets/tasks/main.yml').read_text()
print('YAML, settings and package coverage passed')
