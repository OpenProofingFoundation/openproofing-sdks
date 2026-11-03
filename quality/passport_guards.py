"""Closed passport product/supplier inventory; neutral rules remain intact."""
import hashlib
import json
import re
from pathlib import Path

ROOTS = ('ios/Sources/PassportNFC', 'ios/Sources/PassportMRZCapture', 'ios/Sources/PassportMRZPreview')
TARGETS = {'PassportSDK': 'ios/Sources/PassportSDK', **{Path(p).name:p for p in ROOTS}}
IMPORTS = {
    'PassportSDK': {'Foundation', 'CryptoKit'},
    'PassportNFC': {'Foundation', 'CoreNFC', 'PassportSDK', 'NFCPassportReader'},
    'PassportMRZCapture': {'Foundation', 'AVFoundation', 'Vision', 'ImageIO', 'CoreGraphics', 'PassportSDK'},
    'PassportMRZPreview': {'Foundation', 'UIKit', 'AVFoundation', 'PassportMRZCapture'},
}
PIN = '71dbe0b4514cdaad95961470db72e8231f5943a6'
SUPPLIER = 'third-party/NFCPassportReader'
AUTHORED_SOURCES = {'ios/Sources/PassportMRZCapture/MRZReadinessGate.swift'}
AUTHORED_TESTS = {
    'ios/Tests/CaptureMRZTests/MRZReadinessGateTests.swift',
    *{'ios/Tests/PassportNFCTests/'+name for name in (
        'SecureMessagingAdversarialTests.swift', 'PassportPortraitExtractionTests.swift',
        'PassportParserOwnershipTests.swift', 'PassportObservationMapperTests.swift',
        'PassportActiveAuthenticationTests.swift', 'PassportNestedParserTests.swift',
        'PassportTerminalAuthenticationTests.swift')},
}
AUTHORED_TEST_HELPERS = {'ios/Tests/PassportNFCTests/ReaderProtocolFixture.swift'}
EXTRACTION_TEST_ROOTS = ('PassportTests', 'PassportNFCTests', 'CaptureMRZTests')
DIAGNOSTIC_SOURCE = 'ios/Sources/PassportMRZCapture/NativeMRZSession.swift'
DIAGNOSTIC_HELPER_SHA256 = 'b78b8821bca96eab4e8c59a6031f61c3e9e310684505b0dd24d52acbbb46759b'
CAMERA_DIAGNOSTIC_SOURCE = 'ios/Sources/PassportMRZCapture/MRZCameraDriver.swift'
CAMERA_DIAGNOSTIC_HELPER_SHA256 = '45837a08a78d64dd3a4427bb7162884a7b98752b3409cff085e46f2c90dfe15e'
DIAGNOSTIC_SOURCES = (DIAGNOSTIC_SOURCE, CAMERA_DIAGNOSTIC_SOURCE)
SHA256 = re.compile(r'[0-9a-f]{64}')
SWIFT_GLOB = '*.swift'


def reviewed_diagnostic_source(name, source):
    """Classify only the reviewed scalar sink; all other logging remains forbidden."""
    if name not in DIAGNOSTIC_SOURCES:
        return source
    if name == CAMERA_DIAGNOSTIC_SOURCE:
        helper = re.search(r'(?m)^    private func diagnoseCamera\(\) \{[\s\S]*?^    }', source)
        digest = CAMERA_DIAGNOSTIC_HELPER_SHA256
        declaration = '    private let logger = Logger(subsystem: "com.kenshiki.passport", category: "MRZCamera")'
        calls = re.findall(r'self\.diagnoseCamera\([^\n]+', source)
        expected = ['self.diagnoseCamera()']
    else:
        helper = re.search(r'(?m)^    private func diagnose\(_ status: String, frame: MRZOCRFrame\) \{[\s\S]*?^    }', source)
        digest = DIAGNOSTIC_HELPER_SHA256
        declaration = '    private let logger = Logger(subsystem: "com.kenshiki.passport", category: "MRZCapture")'
        calls = re.findall(r'self\.diagnose\([^\n]+', source)
        expected = ['self.diagnose("awaiting_current_guide", frame: frame)',
                    'self.diagnose(self.readiness.status.rawValue, frame: frame)']
    if (not helper or hashlib.sha256(helper[0].encode()).hexdigest() != digest
            or source.count(declaration) != 1 or declaration not in source.splitlines() or calls != expected
            or len(re.findall(r'\blogger\s*\.', source)) != 1):
        return source
    return source.replace(declaration, ' ' * len(declaration), 1)


def diagnostic_vendor_rule(gate, original):
    """Retain the original vendor rule except the exact private logging subsystem."""
    def check(target):
        hits = original(target)
        if target != 'PassportMRZCapture':
            return hits
        allowed = []
        for name in DIAGNOSTIC_SOURCES:
            source = (gate.ROOT/name).read_text()
            classified = reviewed_diagnostic_source(name, source)
            allowed.extend(f'{name}:{number} ' for number, (before, after) in enumerate(
                zip(source.splitlines(), classified.splitlines()), start=1)
                if before != after and not gate.VENDOR.search(gate.mask(after, keep_literals=True)))
        allowed = tuple(allowed)
        return [hit for hit in hits if not allowed or not hit.startswith(allowed)]
    return check


def acquisition_state_rule(gate, original):
    """Zeroed private clock state is not a calibrated acquisition threshold."""
    def check(target):
        if target != 'PassportMRZCapture':
            return original(target)
        hits = []
        for path in gate.swift_files(target):
            name = path.relative_to(gate.ROOT).as_posix()
            source = path.read_text(encoding='utf-8')
            if name in AUTHORED_SOURCES:
                source = re.sub(r'(?m)^  private var (?:first|last)Timestamp: TimeInterval = 0$',
                                lambda match: ' ' * len(match[0]), source)
            spans = gate._attributed_spans(source)
            for number, line in enumerate(gate.mask(source).split('\n'), start=1):
                if gate.POLICY_NUMBER.search(line) and not any(start <= number <= end for start, end in spans):
                    hits.append(f'{name}:{number} unattributed policy number')
        return hits
    return check


def check_graph(root, gate, fail):
    text = (root/'Package.swift').read_text()
    if dict(gate._target_declarations(text)) != TARGETS:
        fail('Package.swift', 'passport exact target graph differs')
    if gate._exported_targets(text) != set(TARGETS):
        fail('Package.swift', 'passport products must remain independently exported')
    dependencies = re.findall(r'\.package\s*\(([^)]*)\)', text)
    if dependencies != ['path: "'+SUPPLIER+'"']:
        fail('Package.swift', 'passport supplier dependency differs')
    if re.search(r'unsafeFlags|\.plugin\s*\(|\.binaryTarget\s*\(', text):
        fail('Package.swift', 'dependency/plugin/binary needs reviewed provenance and boundary extension')
    if set(gate.neutral_targets()) != set(TARGETS):
        fail('Package.swift', 'all authored passport products must retain neutral rules')
    lock = root/'Gates/passport-graph.json'
    try:
        expected = json.loads(lock.read_text())
        actual = [[name, test, sorted(deps)] for name,test,deps in gate._dependency_edges(text)]
        if actual != expected['edges'] or hashlib.sha256(text.encode()).hexdigest() != expected['manifestSHA256']:
            fail('Package.swift', 'reviewed passport manifest/dependency edges changed')
    except (OSError, ValueError, KeyError):
        fail('Gates/passport-graph.json', 'missing or invalid passport graph lock')


def test_manifest(registry):
    manifest = json.loads(registry.read_text())
    if (set(manifest) != {'schemaVersion', 'files', 'authoredTests', 'authoredTestSHA256',
                          'authoredTestHelpers', 'scope'}
            or type(manifest['schemaVersion']) is not int or manifest['schemaVersion'] != 1):
        raise ValueError('Invalid passport test provenance policy')
    return manifest


def authored_test_policy(manifest, failures):
    authored = manifest['authoredTests']
    hashes = manifest['authoredTestSHA256']
    if (not isinstance(authored, list) or len(authored) != len(AUTHORED_TESTS)
            or set(authored) != AUTHORED_TESTS or not isinstance(hashes, dict)
            or set(hashes) != AUTHORED_TESTS):
        failures.append('passport authored test provenance inventory differs')
    helpers = manifest['authoredTestHelpers']
    if (not isinstance(helpers, list) or len(helpers) != len(AUTHORED_TEST_HELPERS)
            or {row.get('destination') for row in helpers} != AUTHORED_TEST_HELPERS):
        failures.append('passport authored test helper inventory differs')


def imported_test_records(rows, failures):
    records = {}
    for row in rows:
        destination = row['destination']
        if (not destination.startswith('passport/') or not SHA256.fullmatch(row.get('sourceSHA256', ''))
                or not row.get('source') or not row.get('patch')):
            failures.append('passport imported test provenance incomplete')
        name = destination.removeprefix('passport/')
        if name in records or name in AUTHORED_TESTS | AUTHORED_TEST_HELPERS:
            failures.append('passport authored test cannot claim donor provenance')
        records[name] = row.get('destinationSHA256')
    return records


def append_test_helpers(rows, records, failures):
    for row in rows:
        if (set(row) != {'destination', 'destinationSHA256', 'origin', 'purpose'}
                or row.get('origin') != 'kenshiki-sdks-authored' or not row.get('purpose')):
            failures.append('passport authored test helper cannot claim donor provenance')
        name = row.get('destination', '')
        if name in records:
            failures.append('passport duplicate test provenance')
        records[name] = row.get('destinationSHA256')


def check_test_sources(root, records, safe_file, failures):
    actual = {path.relative_to(root).as_posix() for folder in EXTRACTION_TEST_ROOTS
              for path in (root/'ios/Tests'/folder).rglob(SWIFT_GLOB)}
    if actual != set(records):
        failures.append('passport test source inventory differs')
    for name, digest in records.items():
        path = root/name
        if (Path(name).is_absolute() or '..' in Path(name).parts or Path(name).as_posix() != name
                or not name.startswith('ios/Tests/') or not safe_file(path) or not path.is_file()
                or not SHA256.fullmatch(digest or '')
                or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
            failures.append('passport test provenance differs: '+name)


def check_test_inventory(root, tooling, safe_file):
    """Keep authored regressions/helpers distinct from immutable historical donor records."""
    failures = []
    registry = root/'Gates/extraction-tests.json'
    try:
        manifest = test_manifest(registry)
        if tooling.get('passport/Gates/extraction-tests.json') != hashlib.sha256(registry.read_bytes()).hexdigest():
            failures.append('passport test registry requires reviewed tooling pin')
        authored_test_policy(manifest, failures)
        records = imported_test_records(manifest['files'], failures)
        for name in manifest['authoredTests']:
            records[name] = manifest['authoredTestSHA256'].get(name)
        append_test_helpers(manifest['authoredTestHelpers'], records, failures)
        check_test_sources(root, records, safe_file, failures)
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        failures.append('passport extraction test provenance missing or invalid')
    return failures


def check(root):
    from boundary_gates import configure, engine
    from capture_guards import imported_modules
    gate = configure(engine(root), root)
    failures=[]
    supplier_sources=set()
    for module, folder in TARGETS.items():
        for path in (root/folder).rglob(SWIFT_GLOB):
            code=gate.mask(path.read_text())
            allowed = IMPORTS[module]
            if path.relative_to(root).as_posix() in DIAGNOSTIC_SOURCES:
                allowed = allowed | {'OSLog'}
            if set(imported_modules(code))-allowed:
                failures.append('unexpected import: '+str(path.relative_to(root)))
            if re.search(r'\b(?:IdentityEvidenceStorage|UserDefaults|URLSession|URLRequest|SwiftUI)\b', code):
                failures.append('product storage, network or workflow in passport: '+str(path.relative_to(root)))
    def safe_file(path):
        return (not any((root/Path(*path.relative_to(root).parts[:i])).is_symlink() for i in range(1,len(path.relative_to(root).parts)+1))
                and path.resolve().is_relative_to(root.resolve()))
    vendor=root/SUPPLIER
    for path in vendor.rglob('*'):
        if path.is_file() and not any(p in {'.build','.git'} for p in path.relative_to(vendor).parts):
            if not safe_file(path):
                failures.append('passport supplier symlink or escape: '+path.relative_to(root).as_posix())
                continue
            supplier_sources.add(path.relative_to(root).as_posix())
    try:
        lock=json.loads((root/'Gates/extraction-sources.json').read_text())
        records=lock['files'] + lock['supplierFiles']
        authored_records=lock.get('authoredSources', [])
        if (not isinstance(authored_records, list)
                or {row.get('destination') for row in authored_records} != AUTHORED_SOURCES
                or len(authored_records) != len(AUTHORED_SOURCES)):
            failures.append('passport authored source provenance inventory differs')
        for row in authored_records:
            if (set(row) != {'destination', 'destinationSHA256', 'origin', 'purpose'}
                    or row.get('origin') != 'kenshiki-sdks-authored' or not row.get('purpose')):
                failures.append('passport authored source cannot claim donor provenance')
        tooling=json.loads((root.parent/'governance/tooling-lock.json').read_text())
        failures.extend(check_test_inventory(root, tooling, safe_file))
        if tooling.get('passport/Gates/extraction-sources.json') != hashlib.sha256((root/'Gates/extraction-sources.json').read_bytes()).hexdigest():
            failures.append('passport extraction registry requires reviewed tooling pin')
        # Every vendored file is audited; new files cannot inherit supplier classification silently.
        if isinstance(records,list):records={row['destination']:row for row in records}
        for name in supplier_sources:
            row=records.get(name,{})
            if row.get('destinationSHA256') != hashlib.sha256((root/name).read_bytes()).hexdigest():
                failures.append('unreviewed passport supplier bytes: '+name)
        authored={p.relative_to(root).as_posix() for folder in TARGETS.values() for p in (root/folder).rglob(SWIFT_GLOB)}
        declared={name for name in records if name.startswith('ios/Sources/')} | AUTHORED_SOURCES
        if authored != declared | {'ios/Sources/PassportSDK/PassportCheckOutcome.swift'}:
            failures.append('passport authored source inventory differs')
        for name,row in records.items():
            if Path(name).is_absolute() or '..' in Path(name).parts or Path(name).as_posix() != name:
                failures.append('invalid passport provenance path')
                continue
            if not SHA256.fullmatch(row.get('sourceSHA256','')) or not row.get('patch'):
                failures.append('passport donor provenance incomplete: '+name)
            path=root/name
            if not safe_file(path) or not path.is_file() or row.get('destinationSHA256') != hashlib.sha256(path.read_bytes()).hexdigest():
                failures.append('passport extraction provenance differs: '+name)
        for row in authored_records:
            name=row.get('destination', '')
            if name not in AUTHORED_SOURCES:
                continue
            path=root/name
            if (not safe_file(path) or not path.is_file()
                    or row.get('destinationSHA256') != hashlib.sha256(path.read_bytes()).hexdigest()):
                failures.append('passport authored source provenance differs: '+name)
        declared_supplier={name for name in records if name.startswith(SUPPLIER+'/')}
        if declared_supplier != supplier_sources:failures.append('passport supplier inventory differs')
    except (OSError,ValueError,KeyError,TypeError):
        failures.append('passport extraction source provenance missing or invalid')
    manifest=(vendor/'Package.swift').read_text()
    if PIN not in manifest or 'upToNext' in manifest or 'from:' in manifest:
        failures.append('OpenSSL must retain exact reviewed revision')
    return supplier_sources,failures
