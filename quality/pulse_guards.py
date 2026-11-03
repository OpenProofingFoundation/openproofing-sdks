"""Inventory and dependency boundaries for the optional Pulse passport adapter."""
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[1]
DIRECTORY = 'services/pulse'
MODULE = 'KenshikiPulsePassport'
NATIVE = {'.swift', '.c', '.h', '.m', '.mm', '.cpp', '.hpp', '.kt', '.java'}
PRUNE = {'.build', '.swiftpm', '__pycache__'}
IMPORT = re.compile(r'(?<![\w`])import\b\s*(?:(?:class|struct|enum|protocol|typealias|func|let|var)\b\s*)?(`?[A-Za-z_]\w*`?)')
LITERAL = re.compile(r'(#+)?("""|")')
ALLOWED = {'Foundation', 'CryptoKit', 'Security', 'DeviceCheck', 'KenshikiOperationBinding'}


def _swift_comment_end(source, cursor):
    cursor += 2
    depth = 1
    while cursor < len(source) and depth:
        if source.startswith('/*', cursor):
            depth += 1; cursor += 2
        elif source.startswith('*/', cursor):
            depth -= 1; cursor += 2
        else:
            cursor += 1
    if depth:
        raise ValueError('Unclosed Swift comment')
    return cursor


def _swift_literal_end(source, cursor, literal):
    hashes, quote = literal.group(1) or '', literal.group(2)
    closing = quote + hashes
    cursor += len(literal[0])
    while cursor < len(source):
        if source.startswith(closing, cursor):
            return cursor + len(closing)
        if source.startswith('\\' + hashes, cursor):
            cursor += 2 + len(hashes)
        else:
            cursor += 1
    raise ValueError('Unclosed Swift literal')


def _swift_masked_end(source, cursor):
    if source.startswith('//', cursor):
        end = source.find('\n', cursor + 2)
        return len(source) if end < 0 else end
    if source.startswith('/*', cursor):
        return _swift_comment_end(source, cursor)
    literal = LITERAL.match(source, cursor)
    return _swift_literal_end(source, cursor, literal) if literal else None


def swift_imports(source):
    """Read import tokens after Swift comments/literals, independent of line layout."""
    code = list(source)
    cursor = 0
    while cursor < len(source):
        end = _swift_masked_end(source, cursor)
        if end is None:
            cursor += 1
            continue
        for index in range(cursor, min(end, len(source))):
            if code[index] != '\n':
                code[index] = ' '
        cursor = end
    return {module.strip('`') for module in IMPORT.findall(''.join(code))}


def inventory(root):
    """Every source is seen, including unregistered languages and symlinked trees."""
    found = set()
    errors = []
    folder = root/DIRECTORY
    if folder.is_symlink() or not folder.is_dir():
        return found, ['Pulse adapter source root unavailable']
    for current, dirs, files in os.walk(folder, followlinks=False):
        for name in dirs + files:
            path = Path(current)/name
            if path.is_symlink():
                errors.append('Pulse adapter source symlink: '+path.relative_to(root).as_posix())
        dirs[:] = sorted(name for name in dirs if name not in PRUNE and not (Path(current)/name).is_symlink())
        for name in files:
            path = Path(current)/name
            if path.suffix in NATIVE and not path.is_symlink():
                found.add(path.relative_to(root).as_posix())
    return found, errors


def boundary_engine():
    spec = importlib.util.spec_from_file_location('pulse_boundary_engine', ROOT/'quality/upstream/boundary_gates.py')
    engine = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(engine)
    return engine


def check(root=ROOT):
    errors = []
    try:
        policy = json.loads((root/DIRECTORY/'sources.json').read_text())
        if not valid_policy(policy):
            return ['Invalid Pulse adapter source policy']
        manifest = root/'Package.swift'
        if manifest.is_symlink() or hashlib.sha256(manifest.read_bytes()).hexdigest() != policy['rootManifestSHA256']:
            errors.append('Unreviewed Pulse adapter package graph')
        actual, discovered = inventory(root)
        errors.extend(discovered)
        if actual != set(policy['sources']):
            errors.append('Pulse adapter source inventory mismatch')
        engine = boundary_engine()
        engine.ROOT = root
        production = inspect_sources(root, policy['sources'], actual, errors)
        if engine._surface_escapes_in_files(production):
            errors.append('Pulse adapter reaches past a public SDK surface')
        errors.extend(neutral_dependencies(root))
    except (OSError, ValueError, KeyError, TypeError):
        errors.append('Pulse adapter policy or source unavailable')
    return errors


def valid_policy(policy):
    return (set(policy) == {'schemaVersion', 'rootManifestSHA256', 'sources'}
            and type(policy['schemaVersion']) is int and policy['schemaVersion'] == 1
            and isinstance(policy['sources'], dict) and bool(policy['sources']))


def valid_source_role(name, role, actual):
    prefix = DIRECTORY+('/Sources/'+MODULE+'/' if role == 'vendor-adapter' else '/Tests/'+MODULE+'Tests/')
    return (role in {'vendor-adapter', 'test'} and name.startswith(prefix)
            and '..' not in Path(name).parts and name.endswith('.swift') and name in actual)


def inspect_sources(root, sources, actual, errors):
    production = []
    for name, role in sources.items():
        if not valid_source_role(name, role, actual):
            errors.append('Invalid Pulse adapter source role: '+name)
            continue
        source = (root/name).read_text()
        allowed = ALLOWED if role == 'vendor-adapter' else ALLOWED | {MODULE, 'XCTest'}
        if swift_imports(source) - allowed:
            errors.append('Forbidden Pulse adapter dependency: '+name)
        if role == 'vendor-adapter':
            production.append(root/name)
    return production


def forbidden_neutral_reference(path):
    if path.name == 'Package.swift':
        return re.search(r'\b'+MODULE+r'\b', path.read_text()) is not None
    if 'Sources' in path.parts or 'src' in path.parts:
        return MODULE in swift_imports(path.read_text())
    return False


def neutral_dependencies(root):
    errors = []
    for name in ('foundation', 'passport', 'document', 'biometric', 'presentation'):
        for path in (root/name).rglob('*.swift'):
            if any(part in PRUNE | {'build'} for part in path.relative_to(root).parts):
                continue
            if forbidden_neutral_reference(path):
                errors.append('Neutral module depends on Pulse adapter: '+path.relative_to(root).as_posix())
    return errors


if __name__ == '__main__':
    findings = check()
    for finding in findings:
        print('FAIL '+finding)
    if not findings:
        print('PASS optional Pulse adapter inventory, public surface and dependency direction')
    raise SystemExit(bool(findings))
