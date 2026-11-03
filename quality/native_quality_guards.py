"""Closed optional quality source/profile boundary; native execution has separate receipts."""
import hashlib
import json
import re
from pathlib import Path

PROFILE = 'tools/native_quality/profile.json'
PROFILE_SHA256 = '154433c5e66cfb80f8bd1fdf91b92c4aa212c6eea3c9ea1624bbca3b4a8e4557'
SOURCES = {
    'quality-apple/Sources/BiometricQuality/OFIQFaceQuality.swift',
    'quality-apple/Tests/QualityTests/OFIQFaceQualityTests.swift',
    'cpp/quality/ofiq_bridge.cpp', 'cpp/quality/include/ofiq_native.h',
    'tools/native_quality/build.py', PROFILE, 'quality-apple/Package.swift',
}
IMPORTS = {'Foundation', 'CryptoKit', 'BiometricSDK', 'OFIQNative'}

def check_sidecar(root, failures):
    try:
        from .boundary_entry import engine, configure
    except ImportError:
        from boundary_entry import engine, configure
    authority=Path(__file__).resolve().parents[1]/'biometric'
    gate=configure(engine(authority),authority)
    sidecar=root/'quality-apple'
    gate.ROOT=sidecar
    gate.SOURCES=sidecar/'Sources'
    gate.MANIFEST=sidecar/'Package.swift'
    gate.EXPECTED_NEUTRAL_TARGETS={'BiometricQuality'}
    if gate.neutral_targets()!=['BiometricQuality']:
        failures.append('Quality sidecar target inventory differs')
    for target,applicable in gate.scan_plan():
        for name,(rule,_) in applicable.items():
            if rule(target):failures.append('Quality sidecar neutral rule: '+name)
    manifest=gate.MANIFEST.read_text()
    binary=re.findall(r'\.binaryTarget\s*\(\s*name:\s*"([^"]+)"\s*,\s*path:\s*"([^"]+)"\s*\)',manifest)
    if binary!=[('OFIQNative','.build/native-quality/OFIQNative.xcframework')] or manifest.count('.binaryTarget')!=1:
        failures.append('Quality sidecar requires the single source-built native binary')
    products=re.findall(r'\.product\s*\(\s*name:\s*"([^"]+)"\s*,\s*package:\s*"([^"]+)"\s*\)',manifest)
    if products!=[('BiometricSDK','biometric'),('BiometricRuntime','biometric')]:
        failures.append('Quality sidecar must share the parent primitives and one runtime')
    packages=re.findall(r'\.package\s*\(\s*path:\s*"([^"]+)"\s*\)',manifest)
    if packages!=['..'] or manifest.count('.package')!=1 or re.search(r'unsafeFlags|\.plugin\s*\(',manifest):
        failures.append('Quality sidecar dependency graph differs')

def check(root):
    failures=[]
    actual={'quality-apple/Package.swift'} if (root/'quality-apple/Package.swift').is_file() else set()
    for folder in ('quality-apple/Sources/BiometricQuality','quality-apple/Tests/QualityTests','cpp/quality','tools/native_quality'):
        for path in (root/folder).rglob('*'):
            if '__pycache__' in path.parts: continue
            if path.is_symlink(): failures.append('Quality source symlink: '+path.relative_to(root).as_posix())
            elif path.is_file(): actual.add(path.relative_to(root).as_posix())
    if actual!=SOURCES:failures.append('Quality exact source inventory differs: '+str(sorted(actual^SOURCES)))
    try:
        check_sidecar(root,failures)
        lock=json.loads((root/'Gates/quality-sources.json').read_text())
        if set(lock)!=SOURCES:failures.append('Quality source lock inventory differs')
        for name in SOURCES:
            path=root/name
            if not path.is_file() or path.is_symlink() or hashlib.sha256(path.read_bytes()).hexdigest()!=lock.get(name):
                failures.append('Quality source requires reviewed digest: '+name)
        profile=root/PROFILE
        if hashlib.sha256(profile.read_bytes()).hexdigest()!=PROFILE_SHA256:failures.append('Quality profile identity differs')
        source=(root/'quality-apple/Sources/BiometricQuality/OFIQFaceQuality.swift').read_text()
        if set(re.findall(r'^import (\w+)',source,re.M))-IMPORTS:failures.append('Quality dependency outside declared boundary')
        code=re.sub(r'//[^\n]*','',source)
        if re.search(r'\b(?:UIKit|SwiftUI|URLSession|UserDefaults|Logger|NSLog|print)\b',code):
            failures.append('Quality cannot own UI, transport or diagnostics')
        if source.count('"'+PROFILE_SHA256+'"')!=1:failures.append('Quality compiled profile binding differs')
        bridge=(root/'cpp/quality/ofiq_bridge.cpp').read_text()
        if re.search(r'\b(?:printf|fprintf|cout|cerr|socket|connect|system|popen|fopen|fstream|sqlite3)\b',bridge):
            failures.append('Quality bridge cannot own storage, transport or diagnostics')
    except (OSError,ValueError,KeyError,TypeError):failures.append('Quality provenance missing or invalid')
    return failures
