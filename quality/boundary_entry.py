#!/usr/bin/env python3
"""Run the preserved SDK boundary engine with zero-debt capability configuration."""
import importlib.util
import json
from pathlib import Path
import sys

ROOT = Path(__file__).resolve().parents[1]

def engine(root=None):
    root=ROOT if root is None else root
    spec = importlib.util.spec_from_file_location('identity_boundary_engine', root.parent/'quality/upstream/boundary_gates.py')
    gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(gate)
    gate._RN_PARSER_ROOT = ROOT
    gate.ROOT = root
    gate.SOURCES = root / 'ios/Sources'
    gate.MANIFEST = root / 'Package.swift'
    gate.BASELINE_PATH = root / 'Gates/baselines.json'
    return gate

def configure(gate, root):
    config = json.loads((root / 'Gates/config.json').read_text())
    gate.REACT_NATIVE_HOSTS = ()
    gate.RN_HOST_UI_TESTS = {}
    gate.RN_HOST_UI_RESOURCES = {}
    gate.VENDOR_ADAPTERS = {}
    gate.THIRD_PARTY_PACKAGES = ()
    gate.AMBIENT_ADAPTERS = set()
    gate.LEAF = config['swiftModule']
    gate.EXPECTED_NEUTRAL_TARGETS = {gate.LEAF}
    if config['capability'] == 'document':
        gate.EXPECTED_NEUTRAL_TARGETS |= {'DocumentCaptureApple', 'DocumentCapturePreview', 'DocumentCaptureJournal', 'DocumentCapture'}
        from document_capture_guards import FOUNDATION_MODULES, native_permission_callback_rule
        own_modules = gate._own_modules
        gate._own_modules = lambda: own_modules() | FOUNDATION_MODULES
        original, label = gate.CHECKS['no_verdict']
        gate.CHECKS['no_verdict'] = (native_permission_callback_rule(gate, original), label)
    if config['capability'] == 'biometric':
        gate.EXPECTED_NEUTRAL_TARGETS |= {'BiometricCapture', 'BiometricCapturePreview', 'BiometricInference', 'quality-apple/BiometricQuality', 'AuraFaceNative'}
        try:
            from .capture_guards import motion_vendor_rule
        except ImportError:
            from capture_guards import motion_vendor_rule
        original, label = gate.CHECKS['no_vendor_identifiers']
        motion_rule = motion_vendor_rule(gate)
        def classified_motion(target):
            return motion_rule(target) if target == 'BiometricCapture' else original(target)
        gate.CHECKS['no_vendor_identifiers'] = (classified_motion, label)
    if config['capability'] == 'passport':
        gate.EXPECTED_NEUTRAL_TARGETS |= {'PassportNFC', 'PassportMRZCapture', 'PassportMRZPreview'}
        gate.THIRD_PARTY_ROOT = 'third-party'
        gate.THIRD_PARTY_PACKAGES = ('third-party/NFCPassportReader',)
        try:
            from .passport_guards import acquisition_state_rule, diagnostic_vendor_rule
        except ImportError:
            from passport_guards import acquisition_state_rule, diagnostic_vendor_rule
        original, label = gate.CHECKS['no_policy_numbers']
        gate.CHECKS['no_policy_numbers'] = (acquisition_state_rule(gate, original), label)
        original, label = gate.CHECKS['no_vendor_identifiers']
        gate.CHECKS['no_vendor_identifiers'] = (diagnostic_vendor_rule(gate, original), label)
    gate.LEAF_ALLOWED = {'Foundation'}
    if config['capability'] == 'passport':
        gate.LEAF_ALLOWED.add('CryptoKit')
    if config['capability'] == 'biometric':
        gate.LEAF_ALLOWED |= {'CryptoKit', 'CoreFoundation'}
    gate.GENERATED_TREES |= {'build', '.gradle'}
    gate._RN_PRUNE |= {'build', '.gradle'}
    return gate

def findings(root=None):
    root=ROOT if root is None else root
    gate = configure(engine(root), root)
    failures = gate.classification_conflicts() + gate.persistence_registry_gaps()
    if set(gate.neutral_targets()) != gate.EXPECTED_NEUTRAL_TARGETS:
        failures.append('Required neutral Swift target inventory differs')
    for target, applicable in gate.scan_plan():
        for name, (check, _) in applicable.items():
            # Emit locations, never source expressions or biometric values.
            for index, _ in enumerate(check(target), 1):
                failures.append(f'{name}::{target}: finding {index} (run upstream --report in a controlled checkout for details)')
    for name, (check, _) in gate.GLOBAL_CHECKS.items():
        if check():
            failures.append(name + ': dependency direction violation')
    return failures

def main():
    if sys.argv[1:] == ['--self-test']:
        # Preserve the upstream adversarial suite, including its synthetic RN/parser probes.
        engine().self_test()
        return 0
    if sys.argv[1:]:
        raise SystemExit('Usage: Gates/boundary_gates.py [--self-test]; capability gates have no baseline/suppression switches')
    problems = findings()
    for problem in problems:
        print('FAIL ' + problem)
    if not problems:
        print('PASS SDK boundary rules: zero findings; no inherited debt or exemptions')
    return bool(problems)

