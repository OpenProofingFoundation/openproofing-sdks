"""Adversarial capture evidence and optional public API coverage."""
import copy
import plistlib
import tempfile
from unittest import mock
import importlib.util
from pathlib import Path
import unittest

ROOT = Path(__file__).resolve().parents[2]


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, ROOT/path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


evidence = load('capture_evidence_tests', 'quality/capture_evidence.py')
api = load('optional_public_api_tests', 'quality/public_api.py')


class CaptureEvidenceTests(unittest.TestCase):
    def payload(self):
        summary = {'result': 'Passed', 'totalTestCount': 2, 'passedTests': 2,
                   'failedTests': 0, 'skippedTests': 0, 'expectedFailures': 0, 'startTime': 2}
        tests = {'testNodes': [{'children': [
            {'nodeType': 'Test Case', 'nodeIdentifier': 'CaptureTests/Suite/testOne()', 'result': 'Passed'},
            {'nodeType': 'Test Case', 'nodeIdentifier': 'Suite.testTwo()', 'result': 'Passed'}]}]}
        return summary, tests

    def test_complete_xctest_and_swift_testing_evidence(self):
        summary, tests = self.payload()
        self.assertEqual(evidence.validate(summary, tests, {'Suite.testOne', 'Suite.testTwo'}, 1),
                         ['Suite.testOne', 'Suite.testTwo'])

    def test_missing_skipped_failed_expected_and_stale_summary_refused(self):
        summary, tests = self.payload()
        for key, value in [('result', 'Failed'), ('skippedTests', 1), ('failedTests', 1),
                           ('expectedFailures', 1), ('passedTests', 1), ('totalTestCount', True),
                           ('startTime', 0), ('startTime', True), ('startTime', float('nan')), ('startTime', float('inf'))]:
            with self.subTest(key=key):
                changed = dict(summary, **{key: value})
                with self.assertRaises(ValueError): evidence.validate(changed, tests, {'Suite.testOne'}, 1)

    def test_empty_or_malformed_evidence_is_refused(self):
        summary, tests = self.payload()
        for changed_summary, changed_tests, required in [
            (summary, tests, set()), (None, tests, {'Suite.testOne'}),
            (summary, None, {'Suite.testOne'}),
            (summary, {'testNodes': [None]}, {'Suite.testOne'}),
            (summary, {'testNodes': {}}, {'Suite.testOne'}),
        ]:
            with self.assertRaises(ValueError):
                evidence.validate(changed_summary, changed_tests, required, 1)

    def test_missing_duplicate_and_failed_cases_refused(self):
        summary, tests = self.payload()
        mutations = []
        missing = copy.deepcopy(tests)
        missing['testNodes'][0]['children'].pop()
        mutations.append(missing)
        for key, value in [('nodeIdentifier', 'CaptureTests/Suite/testOne()'), ('result', 'Skipped'),
                           ('result', 'Failed')]:
            changed = copy.deepcopy(tests)
            changed['testNodes'][0]['children'][1][key] = value
            mutations.append(changed)
        for changed in mutations:
            with self.assertRaises(ValueError):
                evidence.validate(summary, changed, {'Suite.testOne', 'Suite.testTwo'}, 1)
        with self.assertRaises(ValueError): evidence.validate(summary, tests, {'Suite.absent'}, 1)

    def test_deep_and_excessive_result_trees_are_refused(self):
        summary, _ = self.payload()
        nodes = []
        for _ in range(70): nodes = [{'children': nodes}]
        for tests in [{'testNodes': nodes}, {'testNodes': [{}] * 20001}]:
            with self.assertRaises(ValueError): evidence.validate(summary, tests, {'Suite.testOne'}, 1)
        with self.assertRaises(ValueError): evidence.validate(summary, {'testNodes': []}, {'Suite.testOne'}, float('nan'))

    def test_manifest_requires_unique_exact_declared_inventory(self):
        source = ['final class AlphaTests { func testOne() {} }']
        good = {'schemaVersion': 1, 'requiredIDs': ['AlphaTests.testOne']}
        self.assertEqual(evidence.required_ids(good, source), {'AlphaTests.testOne'})
        for manifest in [None, {}, dict(good, schemaVersion=True), dict(good, extra=1),
                         dict(good, requiredIDs=[]), dict(good, requiredIDs='AlphaTests.testOne'),
                         dict(good, requiredIDs=['AlphaTests.testOne'] * 2),
                         dict(good, requiredIDs=['AlphaTests.absent']),
                         dict(good, requiredIDs=[True])]:
            with self.assertRaises(ValueError): evidence.required_ids(manifest, source)
        with self.assertRaises(ValueError): evidence.required_ids(good, source * 2)
        with self.assertRaises(ValueError): evidence.required_ids(good, ['func testOne() {}'])

    def test_optional_module_coverage_cannot_omit_capture_or_include_empty_macos_preview(self):
        self.assertEqual(api.swift_modules({'swiftModule': 'BiometricSDK'}, 'macos'),
                         ['BiometricSDK', 'BiometricCapture', 'BiometricInference', 'BiometricQuality', 'KenshikiMotion'])
        for lane in ('ios-device', 'ios-simulator'):
            self.assertEqual(api.swift_modules({'swiftModule': 'BiometricSDK'}, lane),
                             ['BiometricSDK', 'BiometricCapture', 'BiometricInference', 'BiometricQuality', 'KenshikiMotion', 'BiometricCapturePreview'])
        self.assertEqual(api.swift_modules({'swiftModule': 'DocumentSDK'}, 'macos'), ['DocumentSDK', 'DocumentCaptureJournal', 'DocumentCapture'])
        self.assertEqual(api.swift_modules({'swiftModule': 'DocumentSDK'}, 'ios-simulator'), ['DocumentSDK', 'DocumentCaptureJournal', 'DocumentCapture', 'DocumentCaptureApple', 'DocumentCapturePreview'])
        self.assertEqual(api.snapshot_path(ROOT, 'macos', 'BiometricSDK', 'BiometricSDK'), ROOT/'api/macos.json')
        self.assertEqual(api.snapshot_path(ROOT, 'macos', 'BiometricCapture', 'BiometricSDK'),
                         ROOT/'api/BiometricCapture/macos.json')

    def test_removed_visual_runtime_has_no_compiler_api_module_or_headers(self):
        for lane in ('macos', 'ios-device', 'ios-simulator'):
            self.assertNotIn('BiometricVisualAssessment', api.swift_modules({'swiftModule': 'BiometricSDK'}, lane))
        self.assertFalse(hasattr(api, 'visual_runtime_headers'))


class NativeQualityAPITests(unittest.TestCase):
    def artifact(self, root):
        artifact = root/'quality-apple/.build/native-quality/OFIQNative.xcframework'
        artifact.mkdir(parents=True)
        libraries = []
        for name, platform, variant in [('desktop-reviewed', 'macos', None), ('phone-reviewed', 'ios', None), ('sim-reviewed', 'ios', 'simulator')]:
            headers = artifact/name/'Headers'; headers.mkdir(parents=True)
            (headers/'module.modulemap').write_text('module OFIQNative {}')
            row = {'LibraryIdentifier': name, 'HeadersPath': 'Headers', 'SupportedPlatform': platform, 'SupportedArchitectures': ['arm64']}
            if variant: row['SupportedPlatformVariant'] = variant
            libraries.append(row)
        (artifact/'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': libraries}))
        return artifact, libraries

    def test_native_quality_headers_follow_exact_platform_variant_and_architecture(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(api.platform, 'machine', return_value='arm64'):
            root = Path(temporary); artifact, _ = self.artifact(root)
            for lane, name in [('macos', 'desktop-reviewed'), ('ios-device', 'phone-reviewed'), ('ios-simulator', 'sim-reviewed')]:
                self.assertEqual(api.native_import_arguments(root, 'BiometricQuality', lane), ['-I', str(artifact/name/'Headers')])
            self.assertEqual(api.native_import_arguments(root, 'BiometricCapture', 'ios-device'), [])
            self.assertEqual(api.native_import_arguments(root, 'BiometricInference', 'macos'), ['-I', str(root/'cpp/include')])

    def test_missing_ambiguous_foreign_and_escaping_native_headers_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary, mock.patch.object(api.platform, 'machine', return_value='arm64'):
            root = Path(temporary); artifact, original = self.artifact(root)
            variants = [[], original + [original[0]], [dict(original[0], SupportedArchitectures=['x86_64'])],
                        [dict(original[0], HeadersPath='../outside')], [dict(original[0], LibraryIdentifier='/outside')]]
            for libraries in variants:
                with self.subTest(libraries=libraries):
                    (artifact/'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': libraries}))
                    with self.assertRaises(ValueError): api.native_import_arguments(root, 'BiometricQuality', 'macos')
            (artifact/'Info.plist').write_bytes(plistlib.dumps({'AvailableLibraries': original}))
            (artifact/'desktop-reviewed/Headers/module.modulemap').unlink()
            with self.assertRaises(ValueError): api.native_import_arguments(root, 'BiometricQuality', 'macos')
