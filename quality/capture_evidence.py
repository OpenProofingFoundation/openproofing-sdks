"""Fail closed on incomplete XCTest or Swift Testing capture execution evidence."""
import math
import re


def test_cases(nodes):
    pending = [(nodes, 0)]
    visited = 0
    while pending:
        children, depth = pending.pop()
        if not isinstance(children, list) or depth > 64:
            raise ValueError('Capture result tree is malformed or too deep')
        for node in children:
            visited += 1
            if visited > 20000 or not isinstance(node, dict):
                raise ValueError('Capture result nodes are malformed or excessive')
            if node.get('nodeType') == 'Test Case':
                yield node
            pending.append((node.get('children', []), depth + 1))


def validate_summary(summary, required, started_ns):
    total = summary.get('totalTestCount')
    if (type(total) is not int or total < len(required)
            or summary.get('result') != 'Passed' or summary.get('passedTests') != total
            or any(summary.get(key) != 0 for key in ('failedTests', 'skippedTests', 'expectedFailures'))):
        raise ValueError('Capture tests must all pass without skips or expected failures')
    start = summary.get('startTime')
    if (not isinstance(start, (int, float)) or isinstance(start, bool)
            or not math.isfinite(start) or start * 1_000_000_000 < started_ns):
        raise ValueError('Capture test result predates this execution')
    return total


def case_identifier(node):
    if node.get('result') != 'Passed':
        raise ValueError('Capture case did not pass')
    raw = node.get('nodeIdentifier', '')
    if not isinstance(raw, str) or not raw:
        raise ValueError('Missing capture case identity')
    return '.'.join(raw.removesuffix('()').replace('/', '.').split('.')[-2:])


def validate(summary, tests, required, started_ns):
    if type(started_ns) is not int or started_ns <= 0:
        raise ValueError('Invalid capture execution start')
    if not isinstance(summary, dict) or not isinstance(tests, dict) or not required:
        raise ValueError('Missing capture summary, test tree or required IDs')
    total = validate_summary(summary, required, started_ns)
    identifiers = []
    for node in test_cases(tests.get('testNodes', [])):
        identifier = case_identifier(node)
        if not identifier or identifier in identifiers:
            raise ValueError('Missing or duplicated capture case identity')
        identifiers.append(identifier)
    if len(identifiers) != total or required - set(identifiers):
        raise ValueError('Capture test identities are missing or disagree with summary')
    return sorted(identifiers)


def required_ids(manifest, test_sources):
    if (not isinstance(manifest, dict) or set(manifest) != {'schemaVersion', 'requiredIDs'}
            or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1):
        raise ValueError('Invalid capture test manifest')
    identifiers = manifest['requiredIDs']
    if (not isinstance(identifiers, list) or not identifiers
            or any(not isinstance(value, str) or not re.fullmatch(r'[A-Za-z]\w*Tests\.[A-Za-z]\w*', value, flags=re.ASCII)
                   for value in identifiers)
            or len(set(identifiers)) != len(identifiers)):
        raise ValueError('Invalid or duplicated required capture test IDs')
    declared = set()
    for source in test_sources:
        classes = re.findall(r'(?:class|struct) (\w+Tests)\b', source)
        if len(classes) != 1:
            raise ValueError('Expected one capture test suite per source')
        for names in re.findall(r'(?:func (test\w+)\(|@Test func (\w+)\()', source):
            identifier = classes[0] + '.' + next(name for name in names if name)
            if identifier in declared:
                raise ValueError('Duplicated declared capture test')
            declared.add(identifier)
    if set(identifiers) != declared:
        raise ValueError('Capture required IDs disagree with declared test inventory')
    return set(identifiers)
