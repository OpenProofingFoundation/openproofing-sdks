"""Closed optional Apple inference boundary and immutable runtime provenance."""
import hashlib
import json
import re

RUNTIME_URL = 'https://download.onnxruntime.ai/pod-archive-onnxruntime-c-1.22.0.zip'
RUNTIME_SHA256 = '90d9de5a139087a6b05a18125d01d01d198820e1731e6f0f11b38749b2ab181f'
SOURCES = {
    'ios/Sources/BiometricInference/AuraFaceComparison.swift',
    'ios/Tests/InferenceTests/AuraFaceComparisonTests.swift',
    'ios/Sources/BiometricInference/FaceFrameSelection.swift',
    'ios/Tests/InferenceTests/FaceFrameSelectionTests.swift',
}
IMPORTS = {'Foundation', 'CryptoKit', 'BiometricSDK', 'AuraFaceNative', 'CoreGraphics', 'ImageIO', 'Vision'}


def check_manifest(root, failures):
    manifest = (root/'Package.swift').read_text()
    binaries = re.findall(r'\.binaryTarget\s*\(\s*name:\s*"([^"]+)"\s*,\s*url:\s*"([^"]+)"\s*,\s*checksum:\s*"([^"]+)"\s*\)', manifest)
    if binaries != [('onnxruntime', RUNTIME_URL, RUNTIME_SHA256)] or manifest.count('.binaryTarget') != 1:
        failures.append('Only the pinned ONNX Runtime Apple binary is allowed in the base package')
    native = re.search(r'\.target\(name: "AuraFaceNative".*?publicHeadersPath: "include"\)', manifest, re.S)
    expected = ['src/portrait.cpp', 'src/auraface_input.cpp', 'src/auraface.cpp', 'src/face_alignment.cpp', 'src/auraface_bridge.cpp', 'src/frame_selection.cpp']
    if not native or re.findall(r'"(src/[^\"]+)"', native.group()) != expected:
        failures.append('Native inference must use the shared C++ implementation')


def check_provenance(root, failures):
    policy = json.loads((root/'Gates/onnxruntime-apple.json').read_text())
    if policy['url'] != RUNTIME_URL or policy['sha256'] != RUNTIME_SHA256 or policy['version'] != '1.22.0':
        failures.append('Apple runtime provenance differs')
    lock = json.loads((root/'Gates/inference-sources.json').read_text())
    if set(lock) != SOURCES:
        failures.append('Inference source lock inventory differs')
    for name in SOURCES:
        p = root/name
        if not p.is_file() or p.is_symlink() or hashlib.sha256(p.read_bytes()).hexdigest() != lock.get(name):
            failures.append('Inference source requires reviewed digest: '+name)


def check_source(root, failures):
    for name in sorted(name for name in SOURCES if '/Sources/' in name):
        source = (root/name).read_text()
        if any(module not in IMPORTS for module in re.findall(r'^import (\w+)', source, re.M)):
            failures.append('Inference dependency outside declared boundary: '+name)
        if re.search(r'\b(?:UIKit|SwiftUI|URLSession|UserDefaults|FileManager|Logger|NSLog|print)\b', source):
            failures.append('Inference cannot own UI, ambient storage, transport or diagnostics: '+name)
    source = (root/'ios/Sources/BiometricInference/AuraFaceComparison.swift').read_text()
    if source.count('VNDetectFaceLandmarksRequestRevision3') != 1:
        failures.append('Vision revision must remain explicit')


def check(root):
    failures = []
    actual = {str(p.relative_to(root)) for folder in ['ios/Sources/BiometricInference', 'ios/Tests/InferenceTests']
              for p in (root/folder).rglob('*') if p.is_file()}
    if actual != SOURCES:
        failures.append('Inference exact source inventory differs')
    try:
        check_manifest(root, failures)
        check_provenance(root, failures)
        check_source(root, failures)
    except (OSError, ValueError, KeyError):
        failures.append('Inference provenance missing or invalid')
    return failures
