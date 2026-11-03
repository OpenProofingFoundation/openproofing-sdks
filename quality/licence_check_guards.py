"""Closed portable licence-check package graph and source-bound functional qualification."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = 'services/licence-check'
INVENTORY = DIRECTORY+'/sources.json'
SOURCE_NAMES = (
    '.gitignore', 'README.md', 'contracts/provenance.json', 'contracts/trusona-adapter-vectors.json',
    'core/README.md', 'core/package.json', 'core/scripts/check.mjs', 'core/src/adapter.ts',
    'core/src/contract.ts', 'core/src/index.ts', 'core/src/policy.ts', 'core/test/dates.test.ts',
    'core/test/policy.test.ts', 'core/tsconfig.json', 'core/tsconfig.test.json', 'package-lock.json',
    'package.json', 'scripts/check.mjs', 'scripts/consumer.mjs', 'trusona/README.md',
    'trusona/package.json', 'trusona/scripts/check.mjs', 'trusona/src/adapter.ts',
    'trusona/src/dldv.ts', 'trusona/src/http.ts', 'trusona/src/index.ts',
    'trusona/test/connection.test.ts', 'trusona/test/dldv.test.ts', 'trusona/test/transport.test.ts',
    'trusona/test/vectors.test.ts', 'trusona/tsconfig.json', 'trusona/tsconfig.test.json',
)
EXPECTED_FILES = {DIRECTORY+'/'+name for name in SOURCE_NAMES}
REQUIRED_TESTS = {'core': 14, 'trusona': 156, 'sharedVectors': 66}
# This intentionally fixed graph is reviewed independently of re-pinning source bytes.
# Canonical JSON permits formatting changes but refuses any dependency/export/build/test change.
GRAPH_SHA256 = {
    'package.json': 'e0e19027efd2c8a5076f24e2b8e751e0515a2f5d47723cff923aeef0bde951e9',
    'core/package.json': 'ceb0172b050f6978389ae8b1e0ae1c82966186f59f12a86fdb2110e1b084b137',
    'trusona/package.json': 'd886f2fe2924cddfba3bf6330db0242e847d9aa8da1b7819689b8d7c77c51009',
    'package-lock.json': '52c9936999006bfe156f8e91d116a7c0d66fb020607b1d65080d8f3d0cb57910',
    'core/tsconfig.json': 'fd18ed209cb3f0406d6f830092eec3bd102aaa39d1c951c87389969e02e30350',
    'core/tsconfig.test.json': 'f31adf6c594e86233a714552ddb93f27eea0d8301a656cb46ae6b5c1b4dadadf',
    'trusona/tsconfig.json': '08d26d7b0762ed99330ba7279ecfa2584f3a21566d723aa0be6a0621641b5b6d',
    'trusona/tsconfig.test.json': 'f31adf6c594e86233a714552ddb93f27eea0d8301a656cb46ae6b5c1b4dadadf',
    'contracts/provenance.json': 'd58505bf0b20c04bf53e4c6fec2a2880c35de6c91c388e59c1444ad8d0edee98',
}
RUNNER_SHA256 = {
    'scripts/check.mjs': '73b8fe62dee4c251bf90a8876c95fd23a12f7bf80095b72cd389300fe776b634',
    'scripts/consumer.mjs': '84ba16a78a32ca8a19245db9238e8b6e939eb3facede2a752e9c6eac44132291',
    'core/scripts/check.mjs': 'f085034c45eb0a949a088539531e27c2bf8c6f9a783ce44077fcc48ea3b5d385',
    'trusona/scripts/check.mjs': '1623b2877304a459d23eeece5b35f1ef6dc142c3783079c47d1d3222f6ff3612',
    'contracts/trusona-adapter-vectors.json': '99f58d1963cd32f0de1ee056c47f6813e04f830982bd1e92bcdd919cfd8cb105',
}
GENERATED_DIRECTORIES = {'node_modules', '.build', 'core/dist', 'trusona/dist', 'core/.build', 'trusona/.build'}
GENERATED_LOGS = {'.build-package-check.log', '.build-package-check-node22.log'}
ASSERTIONS = ['artifact-import', 'public-adapter-flow', 'unqualified-evaluation', 'bound-subject',
              'pre-dispatch-expiry', 'post-dispatch-uncertainty']


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def strict_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate licence-check JSON key: '+key)
            result[key] = value
        return result
    def constant(value):
        raise ValueError('Nonfinite licence-check JSON value: '+value)
    return json.loads(path.read_text(), object_pairs_hook=pairs, parse_constant=constant)


def checked_file(root, name):
    path = root/name
    if (Path(name).is_absolute() or '..' in Path(name).parts or not path.is_file()
            or path.is_symlink() or any((root/parent).is_symlink() for parent in Path(name).parents)):
        raise ValueError('Licence-check input unavailable or redirected: '+name)
    return path


def source_inventory(root):
    base = root/DIRECTORY
    if base.is_symlink() or not base.is_dir() or (root/'services').is_symlink():
        raise ValueError('Licence-check source root unavailable or redirected')
    found = set()
    for current, directories, files in os.walk(base, followlinks=False):
        folder = Path(current)
        for name in directories+files:
            if (folder/name).is_symlink():
                # npm workspace links live inside the top-level generated node_modules only.
                raise ValueError('Licence-check source symlink: '+str(folder/name))
        directories[:] = [name for name in directories
                          if (folder/name).relative_to(base).as_posix() not in GENERATED_DIRECTORIES]
        for name in files:
            relative = (folder/name).relative_to(base).as_posix()
            if relative not in GENERATED_LOGS:
                found.add((folder/name).relative_to(root).as_posix())
    return found


def reviewed_inventory(root):
    record = strict_json(checked_file(root, INVENTORY))
    if (not isinstance(record, dict) or set(record) != {'schemaVersion', 'module', 'files', 'requiredTests'}
            or type(record['schemaVersion']) is not int or record['schemaVersion'] != 1
            or record['module'] != 'licence-check' or not isinstance(record['files'], dict)
            or set(record['files']) != EXPECTED_FILES or record['requiredTests'] != REQUIRED_TESTS):
        raise ValueError('Licence-check reviewed inventory or required tests differ')
    if source_inventory(root) != EXPECTED_FILES | {INVENTORY}:
        raise ValueError('Licence-check closed source inventory differs')
    for name, expected in record['files'].items():
        if not isinstance(expected, str) or not re.fullmatch(r'[0-9a-f]{64}', expected):
            raise ValueError('Invalid licence-check source digest')
        if digest(checked_file(root, name)) != expected:
            raise ValueError('Licence-check reviewed source digest differs: '+name)
    return record


def validate(root=ROOT):
    reviewed_inventory(root)
    for name, expected in GRAPH_SHA256.items():
        graph = strict_json(checked_file(root, DIRECTORY+'/'+name))
        encoded = json.dumps(graph, sort_keys=True, separators=(',', ':'), ensure_ascii=False).encode()
        if hashlib.sha256(encoded).hexdigest() != expected:
            raise ValueError('Licence-check reviewed package/dependency/compiler graph differs: '+name)
    for name, expected in RUNNER_SHA256.items():
        if digest(checked_file(root, DIRECTORY+'/'+name)) != expected:
            raise ValueError('Licence-check reviewed executable/vector contract differs: '+name)
    return EXPECTED_FILES | {INVENTORY}


def check(root=ROOT):
    try:
        validate(root)
        return []
    except (OSError, ValueError, KeyError, TypeError) as error:
        return [str(error)]


def execution_counts(text):
    expected = [REQUIRED_TESTS['core'], REQUIRED_TESTS['trusona']]
    counts = {}
    for label in ('tests', 'pass', 'fail', 'cancelled', 'skipped', 'todo'):
        counts[label] = [int(value) for value in re.findall(r'(?m)^ℹ '+label+r' (\d+)\s*$', text)]
        wanted = expected if label in {'tests', 'pass'} else [0, 0]
        if counts[label] != wanted:
            raise ValueError('Licence-check execution must include all required cases without skips: '+label)
    return counts


def valid_consumer_record(record):
    if not isinstance(record, dict):
        return False
    outcome, commands, artifacts = (record.get(key) for key in ('outcome', 'commands', 'tarballSHA256'))
    return (record.get('passed') is True and isinstance(outcome, dict) and outcome.get('passed') is True
            and outcome.get('assertions') == ASSERTIONS and type(outcome.get('supplierCalls')) is int
            and outcome['supplierCalls'] == 0 and isinstance(commands, list) and len(commands) == 5
            and all(isinstance(command, dict) and type(command.get('status')) is int
                    and command['status'] == 0 for command in commands)
            and isinstance(artifacts, dict) and len(artifacts) == 2)


def consumer_evidence(root, previous):
    folder = root/DIRECTORY/'.build/consumer'
    current = set(folder.glob('*/receipt.json'))
    new = current-previous
    if len(new) != 1:
        raise ValueError('Licence-check requires exactly one fresh external consumer receipt')
    path = new.pop()
    checked_file(root, path.relative_to(root).as_posix())
    record = strict_json(path)
    if not valid_consumer_record(record):
        raise ValueError('Licence-check external consumer did not demonstrate all required outcomes')
    outcome, artifacts = record['outcome'], record['tarballSHA256']
    for name, expected in artifacts.items():
        artifact = Path(name)
        if artifact.parent != path.parent or artifact.suffix != '.tgz':
            raise ValueError('Licence-check consumer artifact redirected')
        if digest(checked_file(root, artifact.relative_to(root).as_posix())) != expected:
            raise ValueError('Licence-check consumer artifact digest differs')
    return {'receipt': path.relative_to(root).as_posix(), 'sha256': digest(path), 'outcome': outcome,
            'tarballSHA256': artifacts}


def compiled_artifacts(root):
    artifacts = {}
    for package in ('core', 'trusona'):
        folder = root/DIRECTORY/package/'dist'
        names = {path.stem for path in (root/DIRECTORY/package/'src').glob('*.ts')}
        expected = {name+extension for name in names for extension in ('.js', '.d.ts')}
        actual = {path.relative_to(folder).as_posix() for path in folder.rglob('*') if path.is_file() or path.is_symlink()}
        if actual != expected:
            raise ValueError('Licence-check compiled package artifact inventory differs')
        for name in expected:
            path = folder/name
            artifacts[path.relative_to(root).as_posix()] = digest(checked_file(root, path.relative_to(root).as_posix()))
    return artifacts


def checkout_identity(root):
    def git(*arguments):
        return subprocess.check_output(['git', *arguments], cwd=root, text=True)
    return {'repository': git('rev-parse', '--show-toplevel').strip(),
            'revision': git('rev-parse', 'HEAD').strip(),
            'gitStatus': git('status', '--porcelain')}


def execute(root=ROOT):
    output = root/'.build/licence-check'
    output.mkdir(parents=True, exist_ok=True)
    attempt = Path(tempfile.mkdtemp(prefix='node-', dir=output))
    log = attempt/'execution.log'
    record = {'schemaVersion': 1, 'passed': False, 'command': ['npm', 'run', 'check'],
              'startedEpoch': time.time(), 'sourceSHA256': {},
              'host': {'system': platform.system(), 'release': platform.release(),
                       'machine': platform.machine(), 'python': platform.python_version()},
              'scope': 'Offline core/Trusona packages and external consumer; no service rollout or supplier qualification'}
    try:
        identity = checkout_identity(root)
        record.update(identity)
        inputs = validate(root) | {'quality/licence_check_guards.py', '.node-version'}
        before = record['sourceSHA256']
        for name in sorted(inputs):
            before[name] = digest(checked_file(root, name))
        record['node'] = subprocess.check_output(['node', '--version'], text=True).strip()
        record['npm'] = subprocess.check_output(['npm', '--version'], text=True).strip()
        if record['node'] != 'v'+(root/'.node-version').read_text().strip():
            raise ValueError('Licence-check execution requires the reviewed Node version')
        previous = set((root/DIRECTORY/'.build/consumer').glob('*/receipt.json'))
        with log.open('w') as stream:
            subprocess.run(record['command'], cwd=root/DIRECTORY, stdout=stream,
                           stderr=subprocess.STDOUT, timeout=600, check=True)
        record['executedTests'] = execution_counts(log.read_text())
        record['externalConsumer'] = consumer_evidence(root, previous)
        record['artifactSHA256'] = compiled_artifacts(root)
        after = {name: digest(checked_file(root, name)) for name in sorted(inputs)}
        record['endSourceSHA256'] = after
        record['sourceUnchanged'] = before == after
        if before != after:
            raise ValueError('Licence-check inputs changed during execution')
        validate(root)
        end_identity = checkout_identity(root)
        record['endCheckout'] = end_identity
        record['checkoutUnchanged'] = identity == end_identity
        if identity != end_identity:
            raise ValueError('Licence-check repository revision or dirty state changed during execution')
        record['passed'] = True
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        record['error'] = type(error).__name__+': '+str(error)
    record['finishedEpoch'] = time.time()
    if log.is_file():
        record['logSHA256'] = digest(log)
    path = attempt/'receipt.json'
    path.write_text(json.dumps(record, indent=2)+'\n')
    print(('PASS ' if record['passed'] else 'FAIL ')+str(path))
    return int(not record['passed'])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--execute', action='store_true', help='Run the actual installed package gate and preserve receipts')
    arguments = parser.parse_args()
    if arguments.execute:
        return execute()
    errors = check()
    for error in errors:
        print('FAIL '+error)
    if not errors:
        print('PASS licence-check closed source, executable, dependency and package contracts')
    return int(bool(errors))


if __name__ == '__main__':
    sys.exit(main())
