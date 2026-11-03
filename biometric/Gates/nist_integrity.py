"""Exact reviewed inventory for attributed NIST evaluation tooling; never mobile SDK source."""
from pathlib import Path
import hashlib
import json

MANIFEST_SHA256 = "91a8ce8f711c76c7dd5cbf681284ac490feeb71cb81bd558551bd096caba7d10"
REVISION = "18c2f84d80c0636cede6ff1db0479fe068aedac4"


def verify(root):
    folder = Path(root)/'nist/upstream'
    manifest = Path(root)/'nist/upstream-manifest.json'
    failures = []
    if not manifest.is_file() or manifest.is_symlink() or hashlib.sha256(manifest.read_bytes()).hexdigest() != MANIFEST_SHA256:
        return set(), ['NIST manifest differs from reviewed pin']
    data = json.loads(manifest.read_text())
    expected = {entry['path']: entry for entry in data['files']}
    if data['revision'] != REVISION or len(expected) != len(data['files']):
        failures.append('NIST revision/duplicate inventory mismatch')
    actual,inventory_failures=_file_inventory(folder,expected)
    failures.extend(inventory_failures)
    if actual != set(expected):
        failures.append('NIST source inventory missing or expanded')
    failures.extend(_interface_pin_failures(root,expected))
    return ({'nist/upstream/'+name for name in expected} if not failures else set()), failures


def _interface_pin_failures(root,expected):
    failures=[]
    # Cross-check the earlier published interface pin as well.
    for entry in json.loads((Path(root)/'nist/sources.json').read_text())['sources']:
        if expected.get(entry['path'], {}).get('sha256') != entry['sha256']:
            failures.append('NIST interface/reference pin diverged: '+entry['path'])
    return failures


def _file_inventory(folder,expected):
    failures=[]
    actual = set()
    if folder.is_symlink():
        failures.append('NIST upstream directory is a symlink')
    for path in folder.rglob('*'):
        name = path.relative_to(folder).as_posix()
        if path.is_symlink():
            failures.append('NIST symlink: '+name)
        elif path.is_file():
            actual.add(name)
            entry = expected.get(name)
            if entry is None or hashlib.sha256(path.read_bytes()).hexdigest() != entry['sha256']:
                failures.append('NIST unreviewed/modified file: '+name)
    return actual,failures
