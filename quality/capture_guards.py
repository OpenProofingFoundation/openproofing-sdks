"""Closed optional capture graph, provenance and dependency boundaries; no neutral exemptions."""
import hashlib
import json
from pathlib import Path
import re

CAPTURE = 'ios/Sources/BiometricCapture'
PREVIEW = 'ios/Sources/BiometricCapturePreview'
TESTS = 'ios/Tests/CaptureTests'
CORE_NAMES = {
    'CapturedSelfie', 'NativeSelfieSession', 'SelfieAdmissionGate', 'SelfieAdmissionPolicy',
    'SelfieAdmissionReceipt', 'SelfieCameraFailure', 'SelfieCaptureCoordinator',
    'SelfieCaptureFrame', 'SelfieCapturePresentation', 'SelfieCaptureTimeouts', 'SelfieCaptureWindowPolicy',
    'SelfieDepthMap', 'SelfieDepthPolicy', 'SelfieFrameAnalyzer', 'SelfieGuideGeometry',
    'SelfieFrameSnapshot', 'SelfiePixelBridge',
    'NativeSelfieMotion', 'SelfieMotionEvidence',
}
TEST_NAMES = {
    'SelfieFrameOwnershipTests', 'SelfiePixelBridgeTests', 'SelfieCaptureCoordinatorTests',
    'SelfieDepthMapTests', 'SelfieCapturePresentationTests', 'NativeSelfieSessionConsentTests',
    'SelfieDepthTests', 'SelfieGuideGeometryTests', 'SelfieAdmissionPolicyTests',
}
FILES = {CAPTURE+'/'+name+'.swift' for name in CORE_NAMES}
FILES |= {PREVIEW+'/NativeSelfiePreviewView.swift'}
FILES |= {TESTS+'/'+name+'.swift' for name in TEST_NAMES}
IMPORTS = {
    CAPTURE: {'Foundation', 'CryptoKit', 'CoreGraphics', 'CoreVideo', 'CoreImage',
              'ImageIO', 'ARKit', 'AVFoundation', 'Vision', 'UIKit', 'BiometricSDK', 'KenshikiMotion'},
    PREVIEW: {'ARKit', 'BiometricCapture'},
}
TARGETS = {'BiometricSDK': 'ios/Sources/BiometricSDK', 'BiometricCapture': CAPTURE,
           'BiometricCapturePreview': PREVIEW, 'BiometricInference': 'ios/Sources/BiometricInference',
           'AuraFaceNative': 'cpp'}
EDGES = {
    ('onnxruntime', False): set(),
    ('BiometricSDK', False): set(), ('BiometricCapture', False): {'BiometricSDK', 'KenshikiMotion', 'motion'},
    ('BiometricCapturePreview', False): {'BiometricCapture'},
    ('AuraFaceNative', False): {'onnxruntime'},
    ('BiometricInference', False): {'BiometricSDK', 'AuraFaceNative'},
    ('InferenceTests', True): {'BiometricInference'},
    ('CaptureTests', True): {'BiometricCapture'},
    ('QualityGuardsTests', True): {'BiometricSDK'}, ('PrimitiveTests', True): {'BiometricSDK'},
}
DONOR_REVISION = 'b3884d93374ceb5b63743be831c38390794d9562'
DONOR_PINS = {
    "Sources/CaptureSelfie/CapturedSelfie.swift": "58abcdb1ae4b420bf37aa0aae227a209a2e77140b4af08c8f7d95ec88adca1ff",
    "Sources/CaptureSelfie/NativeSelfieSession.swift": "b0b09e9cc7d797dd3320d36fb5e46882bacb5bf52345a6631d4207f5bf7d9413",
    "Sources/CaptureSelfie/SelfieAdmissionGate.swift": "cc87c2d55300494fa358955c9b18a37a127a42e3441831abf0b3ca3e33df8cfb",
    "Sources/CaptureSelfie/SelfieAdmissionPolicy.swift": "3b7b28be39c58adc7ed832c82d6ea77155a93b9e2c7d51ec4bf19e9701dc5a97",
    "Sources/CaptureSelfie/SelfieAdmissionReceipt.swift": "d640e4e27b8afe26fc4c8a54f59d74978b1f69f63b894f3697923e141157d5b9",
    "Sources/CaptureSelfie/SelfieCameraFailure.swift": "7acd550ed87c89c879f68ceba99f03b3717d92cd786640fc29393700d269f943",
    "Sources/CaptureSelfie/SelfieCaptureCoordinator.swift": "0ef00d8aaa64753b1449c6b4415dd9355199aabeda97eecf1256687250ae21cc",
    "Sources/CaptureSelfie/SelfieCaptureFrame.swift": "b19fd18ab6d676196f5829e9a618f103907945d78fb1e130ad061d90df41da5a",
    "Sources/CaptureSelfie/SelfieCapturePresentation.swift": "eff1a1dbc7677d89aa066920a3aadcbc7a7373664fea2c564cffe0b201c0bdce",
    "Sources/CaptureSelfie/SelfieCaptureTimeouts.swift": "61fc8dfe4e3b530cddccb126c8739208131872599318e3ce7b10c7939a5d1e2e",
    "Sources/CaptureSelfie/SelfieDepthMap.swift": "b11f9c0d3404ec40ff045d50b40c41df45ea84a6bcce836eddd494be7b27218e",
    "Sources/CaptureSelfie/SelfieDepthPolicy.swift": "2e58cc66ca2c92190fe386eee64889e2a804c9a5b12aaea9051ecae9321dadf9",
    "Sources/CaptureSelfie/SelfieFrameAnalyzer.swift": "352f3236f4c277d1a9b525a4069240120fc9891abc0c34a0847e589e879da991",
    "Sources/CaptureSelfie/SelfieGuideGeometry.swift": "016dea2f2bc1779370145bb6f041bc0ff851dde7447d1cfb5814c6354bfe00a8",
    "Sources/CaptureSelfiePreview/NativeSelfiePreviewView.swift": "47536ef50209a6859277c45db56c63bb7d394be92bdcf2544f7c4e5df3562448",
    "Tests/CaptureSelfieTests/NativeSelfieSessionConsentTests.swift": "1834ddb0d08d83f03f5e72f092e3798a69a72e1de68896d612e2da6d806034b6",
    "Tests/CaptureSelfieTests/SelfieAdmissionPolicyTests.swift": "31ec25877d2fed041dd34f9d80c44f13eaba4bd13d010e9265d574acc364ec38",
    "Tests/CaptureSelfieTests/SelfieCaptureCoordinatorTests.swift": "333f625fbae969eda08d3ec48039de1d2fb7ac038eb394a5ae79f2b45338e510",
    "Tests/CaptureSelfieTests/SelfieCapturePresentationTests.swift": "fdede39df35497812c6c68758016bc81f6f8be764810b05b29dc4f1903b46086",
    "Tests/CaptureSelfieTests/SelfieDepthMapTests.swift": "6d98c888de70723a752356b5a917f9c94611475be434623ad42f668d962573d5",
    "Tests/CaptureSelfieTests/SelfieDepthTests.swift": "0a12d1564daf2792efd2f2b15224870d73ec05fcdc65e049405b85ba26695514",
    "Tests/CaptureSelfieTests/SelfieGuideGeometryTests.swift": "290772cb23bab288b233baa7b5c21b8c8f9aba6d4fbe7cc48f4f7a854cdf1a42"
}

DONOR_FILES = {
    "ios/Sources/BiometricCapture/CapturedSelfie.swift": "Sources/CaptureSelfie/CapturedSelfie.swift",
    "ios/Sources/BiometricCapture/NativeSelfieSession.swift": "Sources/CaptureSelfie/NativeSelfieSession.swift",
    "ios/Sources/BiometricCapture/SelfieAdmissionGate.swift": "Sources/CaptureSelfie/SelfieAdmissionGate.swift",
    "ios/Sources/BiometricCapture/SelfieAdmissionPolicy.swift": "Sources/CaptureSelfie/SelfieAdmissionPolicy.swift",
    "ios/Sources/BiometricCapture/SelfieAdmissionReceipt.swift": "Sources/CaptureSelfie/SelfieAdmissionReceipt.swift",
    "ios/Sources/BiometricCapture/SelfieCameraFailure.swift": "Sources/CaptureSelfie/SelfieCameraFailure.swift",
    "ios/Sources/BiometricCapture/SelfieCaptureCoordinator.swift": "Sources/CaptureSelfie/SelfieCaptureCoordinator.swift",
    "ios/Sources/BiometricCapture/SelfieCaptureFrame.swift": "Sources/CaptureSelfie/SelfieCaptureFrame.swift",
    "ios/Sources/BiometricCapture/SelfieCapturePresentation.swift": "Sources/CaptureSelfie/SelfieCapturePresentation.swift",
    "ios/Sources/BiometricCapture/SelfieCaptureTimeouts.swift": "Sources/CaptureSelfie/SelfieCaptureTimeouts.swift",
    "ios/Sources/BiometricCapture/SelfieDepthMap.swift": "Sources/CaptureSelfie/SelfieDepthMap.swift",
    "ios/Sources/BiometricCapture/SelfieDepthPolicy.swift": "Sources/CaptureSelfie/SelfieDepthPolicy.swift",
    "ios/Sources/BiometricCapture/SelfieFrameAnalyzer.swift": "Sources/CaptureSelfie/SelfieFrameAnalyzer.swift",
    "ios/Sources/BiometricCapture/SelfieGuideGeometry.swift": "Sources/CaptureSelfie/SelfieGuideGeometry.swift",
    "ios/Sources/BiometricCapturePreview/NativeSelfiePreviewView.swift": "Sources/CaptureSelfiePreview/NativeSelfiePreviewView.swift",
    "ios/Tests/CaptureTests/NativeSelfieSessionConsentTests.swift": "Tests/CaptureSelfieTests/NativeSelfieSessionConsentTests.swift",
    "ios/Tests/CaptureTests/SelfieAdmissionPolicyTests.swift": "Tests/CaptureSelfieTests/SelfieAdmissionPolicyTests.swift",
    "ios/Tests/CaptureTests/SelfieCaptureCoordinatorTests.swift": "Tests/CaptureSelfieTests/SelfieCaptureCoordinatorTests.swift",
    "ios/Tests/CaptureTests/SelfieCapturePresentationTests.swift": "Tests/CaptureSelfieTests/SelfieCapturePresentationTests.swift",
    "ios/Tests/CaptureTests/SelfieDepthMapTests.swift": "Tests/CaptureSelfieTests/SelfieDepthMapTests.swift",
    "ios/Tests/CaptureTests/SelfieDepthTests.swift": "Tests/CaptureSelfieTests/SelfieDepthTests.swift",
    "ios/Tests/CaptureTests/SelfieGuideGeometryTests.swift": "Tests/CaptureSelfieTests/SelfieGuideGeometryTests.swift"
}

SHA256 = re.compile(r'[0-9a-f]{64}')
MOTION_ADAPTERS = {CAPTURE+'/NativeSelfieMotion.swift', CAPTURE+'/SelfieMotionEvidence.swift',
                   CAPTURE+'/SelfieAdmissionReceipt.swift'}
SHARED_MOTION_TYPES = re.compile(r'\b(?:KenshikiMotion|PulseMotionPermission|PulseCeremonyMotion(?:Summary|Witness|Summarizer))\b')


def motion_vendor_rule(gate):
    """Preserved shared type references are not external vendor DTOs or wire strings."""
    def check(target):
        hits = []
        for path in gate.swift_files(target):
            name = path.relative_to(gate.ROOT).as_posix()
            source = path.read_text()
            text = gate.mask(source, keep_literals=True)
            if name in MOTION_ADAPTERS:
                code = gate.mask(source)
                characters = list(text)
                for match in SHARED_MOTION_TYPES.finditer(code):
                    characters[match.start():match.end()] = ' ' * len(match[0])
                text = ''.join(characters)
                if re.search(r'\b(?:typealias|struct|class|enum)\s+(?:KenshikiMotion|PulseCeremonyMotion)', code):
                    hits.append(name+': shared motion contracts cannot be redeclared by capture')
            if gate.VENDOR.search(path.name):
                hits.append(name+': filename carries an unreviewed vendor name')
            for number, line in enumerate(text.split('\n'), start=1):
                if gate.VENDOR.search(line):
                    hits.append(name+':'+str(number)+': vendor identifier outside shared motion type reference')
        return hits
    return check


def check_graph(root, gate, failures):
    text = (root/'Package.swift').read_text()
    declarations = list(gate._target_declarations(text))
    if len(declarations) != len(TARGETS) or dict(declarations) != TARGETS:
        failures.append('Capture target source inventory differs')
    products = re.findall(r'\.library\s*\(\s*name:\s*"([^"]+)"\s*,\s*targets:\s*\[\s*"([^"]+)"\s*\]\s*\)', text)
    expected_products = {(name, name) for name in set(TARGETS)-{'AuraFaceNative'}}
    expected_products.add(('BiometricRuntime', 'onnxruntime'))
    if (gate._exported_targets(text) != set(TARGETS)-{'AuraFaceNative'} | {'onnxruntime'}
        or len(products) != len(expected_products) or set(products) != expected_products):
        failures.append('Capture products must remain independently exported libraries')
    # Assert that retired inference cannot return through package graph changes.
    try:
        from .visual_assessment_guards import check_graph as check_visual_graph
    except ImportError:
        from visual_assessment_guards import check_graph as check_visual_graph
    check_visual_graph(root, failures)
    parsed = list(gate._dependency_edges(text))
    edges = {(name, test): dependencies for name, test, dependencies in parsed}
    if edges != EDGES or len(parsed) != len(EDGES):
        failures.append('Capture dependency graph differs')
    if set(gate.neutral_targets()) != set(TARGETS) | {'quality-apple/BiometricQuality'}:
        failures.append('All capture targets must receive the intact neutral rules')


def check_inventory(root, failures):
    actual = set()
    for name in (CAPTURE, PREVIEW, TESTS):
        folder = root/name
        if not folder.is_dir() or folder.is_symlink():
            failures.append('Capture source root missing or symlinked: '+name)
            continue
        for path in folder.rglob('*'):
            if path.is_symlink():
                failures.append('Capture source symlink: '+path.relative_to(root).as_posix())
            elif path.is_file():
                actual.add(path.relative_to(root).as_posix())
    if actual != FILES:
        failures.append('Capture exact source inventory differs: '+str(sorted(actual ^ FILES)))


def check_record(root, name, record, failures):
    source = root/name
    digest = record.get('destinationSHA256', '')
    if (not SHA256.fullmatch(digest) or not source.is_file() or source.is_symlink()
            or hashlib.sha256(source.read_bytes()).hexdigest() != digest):
        failures.append('Capture source requires reviewed digest: '+name)
    expected_source = DONOR_FILES.get(name)
    if expected_source:
        check_donor_record(name, record, expected_source, failures)
    elif record.get('origin') != 'new':
        failures.append('Capture source origin missing: '+name)


def check_donor_record(name, record, expected_source, failures):
    if record.get('origin') != 'extracted' or record.get('sourcePath') != expected_source:
        failures.append('Capture extracted origin cannot be reclassified: '+name)
    patches = record.get('patches')
    if (DONOR_PINS.get(record.get('sourcePath')) != record.get('sourceSHA256')
            or not isinstance(patches, list)
            or not all(isinstance(patch, str) for patch in patches)):
        failures.append('Capture donor provenance incomplete: '+name)


def read_lock(path):
    if path.is_symlink():
        raise ValueError('symlink')
    lock = json.loads(path.read_text())
    if (set(lock) != {'schemaVersion', 'donorRepository', 'donorRevision', 'files'}
            or lock['schemaVersion'] != 1 or lock['donorRevision'] != DONOR_REVISION
            or lock['donorRepository'] != 'Kenshiki-Labs/kenshiki-identity-sdk'):
        raise ValueError('schema')
    records = lock['files']
    if not isinstance(records, dict) or any(not isinstance(row, dict) for row in records.values()):
        raise ValueError('records')
    return records


def check_lock(root, failures):
    try:
        records = read_lock(root/'Gates/capture-sources.json')
        if set(records) != FILES:
            failures.append('Capture provenance inventory differs')
        for name in FILES:
            check_record(root, name, records.get(name, {}), failures)
    except (OSError, ValueError, KeyError, TypeError):
        failures.append('Capture provenance lock missing or invalid')


def imported_modules(code):
    # Swift whitespace, including comments and newlines, cannot hide an import.
    words = code.split()
    selectors = {'class', 'struct', 'enum', 'func', 'let', 'var', 'typealias'}
    for index, word in enumerate(words[:-1]):
        if word != 'import':
            continue
        index += 1
        if words[index] in selectors:
            index += 1
        if index < len(words):
            yield words[index].split('.')[0].rstrip(';')


def check_capture_file(root, gate, name, folder, allowed, failures):
    path = root/name
    if not path.is_file():
        return
    code = gate.mask(path.read_text())
    if any(module not in allowed for module in imported_modules(code)):
        failures.append('Capture dependency outside declared platform boundary: '+name)
    if re.search(r'\b(?:SwiftUI|SelfieCustody|RetainedSelfie|IdentityEvidenceStorage|CaptureEvidenceStore|URLSession|URLRequest|NWConnection|UserDefaults|FileManager)\b', code):
        failures.append('Capture must not own UI workflow, custody, storage or transport: '+name)
    if re.search(r'\bpublic\s+(?:let|var)\s+\w+\s*:\s*(?:CVPixelBuffer|AVDepthData)\b', code):
        failures.append('Capture mutable frame storage cannot escape publicly: '+name)
    if folder == PREVIEW and re.search(r'\b(?:Task|DispatchQueue|SelfieAdmissionGate|SelfieDepthPolicy|VN\w+Request|ARFaceTrackingConfiguration)\b', code):
        failures.append('Capture preview must remain a supplied-session renderer: '+name)


def check_source(root, gate, failures):
    for folder, allowed in IMPORTS.items():
        for name in FILES:
            if name.startswith(folder+'/'):
                check_capture_file(root, gate, name, folder, allowed, failures)


def check(root):
    try:
        from .boundary_entry import configure, engine
    except ImportError:
        from boundary_entry import configure, engine
    gate = configure(engine(root), root)
    failures = []
    check_inventory(root, failures)
    check_lock(root, failures)
    try:
        check_graph(root, gate, failures)
        check_source(root, gate, failures)
    except (OSError, ValueError, KeyError, TypeError):
        failures.append('Capture graph/source parsing failed')
    return failures
