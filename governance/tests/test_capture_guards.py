"""Mutations must not hide optional capture targets, imports or provenance."""
import contextlib
import hashlib
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from quality.capture_guards import check
from quality.boundary_entry import findings

ROOT = Path(__file__).resolve().parents[2]


class CaptureGuardsTests(unittest.TestCase):
    @contextlib.contextmanager
    def checkout(self):
        with tempfile.TemporaryDirectory() as temporary:
            parent = Path(temporary)
            root = parent/'biometric'
            shutil.copytree(ROOT/'biometric', root, ignore=shutil.ignore_patterns(
                '.build', '.gradle', 'build', '__pycache__', 'node_modules'))
            shutil.copytree(ROOT/'quality', parent/'quality', ignore=shutil.ignore_patterns('__pycache__'))
            yield root

    def refresh(self, root, name):
        path = root/'Gates/capture-sources.json'
        data = json.loads(path.read_text())
        data['files'][name]['destinationSHA256'] = hashlib.sha256((root/name).read_bytes()).hexdigest()
        path.write_text(json.dumps(data))

    def test_current_capture_graph_and_sources_are_guarded(self):
        self.assertEqual(check(ROOT/'biometric'), [])
        self.assertEqual(findings(ROOT/'biometric'), [])

    def test_hidden_deleted_and_symlinked_sources_fail(self):
        with self.checkout() as root:
            path = root/'ios/Sources/BiometricCapture/Hidden.swift'
            path.write_text('struct Hidden {}')
            self.assertTrue(check(root))
            path.unlink()
            path.symlink_to(root/'ios/Sources/BiometricCapture/CapturedSelfie.swift')
            self.assertTrue(check(root))
            path.unlink()
            (root/'ios/Sources/BiometricCapture/CapturedSelfie.swift').unlink()
            self.assertTrue(check(root))

    def test_donor_and_destination_provenance_tampering_fail(self):
        with self.checkout() as root:
            path = root/'Gates/capture-sources.json'
            original = path.read_text()
            data = json.loads(original)
            item = data['files']['ios/Sources/BiometricCapture/CapturedSelfie.swift']
            item['sourceSHA256'] = '0'*64
            path.write_text(json.dumps(data))
            self.assertTrue(check(root))
            path.write_text(original)
            (root/'ios/Sources/BiometricCapture/CapturedSelfie.swift').write_text('// changed')
            self.assertTrue(check(root))

    def test_graph_reversal_and_unexported_module_fail(self):
        with self.checkout() as root:
            path = root/'Package.swift'
            original = path.read_text()
            path.write_text(original.replace('dependencies: ["BiometricSDK"]', 'dependencies: ["BiometricCapturePreview"]'))
            self.assertTrue(check(root))
            path.write_text(original.replace('targets: ["BiometricCapturePreview"]', 'targets: ["BiometricSDK"]'))
            self.assertTrue(check(root))

    def test_refreshed_digest_cannot_authorize_storage_transport_or_frame_escape(self):
        name = 'ios/Sources/BiometricCapture/CapturedSelfie.swift'
        probes = ['import IdentityEvidenceStorage', 'import Network',
                  'internal import\tNetwork', 'import\nNetwork',
                  'public let escapedFrame: CVPixelBuffer', 'let ambient = UserDefaults.standard']
        for probe in probes:
            with self.subTest(probe=probe), self.checkout() as root:
                path = root/name
                path.write_text(path.read_text()+'\n'+probe+'\n')
                self.refresh(root, name)
                self.assertTrue(check(root))

    def test_refreshed_digest_cannot_exempt_neutral_source_rules(self):
        name = 'ios/Sources/BiometricCapture/CapturedSelfie.swift'
        probes = {'no_authored_sentence': 'public let instruction = "Hold the phone steady."',
                  'no_ambient': 'public let now = Date()',
                  'no_policy_numbers': 'public let timeout: TimeInterval = 3.5',
                  'no_verdict': 'public var isIdentityAccepted: Bool { true }'}
        for rule, probe in probes.items():
            with self.subTest(rule=rule), self.checkout() as root:
                path = root/name
                path.write_text(path.read_text()+'\n'+probe+'\n')
                self.refresh(root, name)
                self.assertIn(rule, '\n'.join(findings(root)))

    def test_refreshed_digest_cannot_put_analysis_in_preview(self):
        name = 'ios/Sources/BiometricCapturePreview/NativeSelfiePreviewView.swift'
        with self.checkout() as root:
            path = root/name
            path.write_text(path.read_text()+'\nlet work = Task { }\n')
            self.refresh(root, name)
            self.assertTrue(any('supplied-session' in value for value in check(root)))

    def test_each_missing_optional_module_fails_the_boundary_entrypoint(self):
        for module in ('BiometricSDK', 'BiometricCapture', 'BiometricCapturePreview'):
            with self.subTest(module=module), self.checkout() as root:
                shutil.rmtree(root/'ios/Sources'/module)
                self.assertIn('Required neutral Swift target inventory differs', findings(root))

    def test_runtime_export_cannot_alias_another_target_or_add_quality_to_primitives(self):
        with self.checkout() as root:
            path = root/'Package.swift'
            source = path.read_text()
            self.assertNotIn('OFIQNative', source)
            self.assertNotIn('BiometricQuality', source)
            mutations = [source.replace('name: "BiometricRuntime", targets: ["onnxruntime"]',
                                        'name: "BiometricRuntime", targets: ["BiometricSDK"]'),
                         source.replace('.target(name: "BiometricSDK", path:',
                                        '.target(name: "BiometricSDK", dependencies: ["BiometricQuality"], path:')]
            for changed in mutations:
                self.assertNotEqual(changed, source, 'Mutation must change the actual declaration')
                path.write_text(changed)
                self.assertTrue(check(root))
            path.write_text(source)
            shutil.rmtree(root/'quality-apple/Sources/BiometricQuality')
            self.assertIn('Required neutral Swift target inventory differs', findings(root))

    def test_quality_target_receives_intact_neutral_rules(self):
        with self.checkout() as root:
            path = root/'quality-apple/Sources/BiometricQuality/OFIQFaceQuality.swift'
            path.write_text(path.read_text()+'\npublic let instruction = "Hold the phone steady."\n')
            self.assertIn('no_authored_sentence', '\n'.join(findings(root)))

    def test_shared_motion_type_reuse_does_not_allow_vendor_wire_or_redeclarations(self):
        name = 'ios/Sources/BiometricCapture/SelfieMotionEvidence.swift'
        for probe in ('let value = "PulseCeremonyMotionSummary"',
                      'typealias PulseCeremonyMotionSummary = Int',
                      'let value = PulseHiddenService()'):
            with self.subTest(probe=probe), self.checkout() as root:
                path = root/name
                path.write_text(path.read_text()+'\n'+probe+'\n')
                self.refresh(root, name)
                self.assertIn('no_vendor_identifiers', '\n'.join(findings(root)))
