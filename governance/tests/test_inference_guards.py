"""Adversarial checks for the optional runtime and source boundary."""
import importlib.util
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('inference_guards', ROOT/'quality/inference_guards.py')
guards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guards)


class InferenceGuardsTests(unittest.TestCase):
    def checkout(self, temporary):
        root = Path(temporary)/'biometric'
        files = guards.SOURCES | {'Package.swift', 'Gates/onnxruntime-apple.json', 'Gates/inference-sources.json'}
        for name in files:
            destination = root/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/'biometric'/name, destination)
        return root

    def test_current_optional_boundary_is_closed(self):
        self.assertEqual(guards.check(ROOT/'biometric'), [])

    def test_runtime_replacement_addition_and_native_source_redirection_fail(self):
        for old, new in [
            (guards.RUNTIME_SHA256, '0'*64),
            (guards.RUNTIME_URL, 'https://example.invalid/runtime.zip'),
            ('"src/auraface.cpp"', '"../other/auraface.cpp"'),
            (', "src/frame_selection.cpp"', ''),
            ('.binaryTarget(name: "onnxruntime"', '.binaryTarget(name: "unreviewed"'),
        ]:
            with self.subTest(new=new), tempfile.TemporaryDirectory() as temporary:
                root = self.checkout(temporary)
                manifest = root/'Package.swift'
                manifest.write_text(manifest.read_text().replace(old, new))
                self.assertTrue(guards.check(root))

    def test_unregistered_source_is_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.checkout(temporary)
            (root/'ios/Sources/BiometricInference/Hidden.swift').write_text('import Foundation\n')
            self.assertTrue(any('inventory' in error for error in guards.check(root)))

    def test_mutated_runtime_source_and_forbidden_effects_are_rejected(self):
        for mutation in ['import UIKit', 'import Network', 'let session = URLSession.shared',
                         'let defaults = UserDefaults.standard', 'print("image")']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = self.checkout(temporary)
                source = root/'ios/Sources/BiometricInference/AuraFaceComparison.swift'
                source.write_text(source.read_text()+'\n'+mutation)
                errors = guards.check(root)
                self.assertTrue(any('reviewed digest' in error for error in errors))
                self.assertTrue(any('dependency' in error or 'cannot own' in error for error in errors))

    def test_native_test_evidence_requires_all_inference_cases(self):
        from quality.portrait_evidence import SWIFT_REQUIRED
        for name in ('testSubstitutedSourceRejectedBeforeModelAccess',
                     'testMalformedImageRejectedBeforeModelAccess', 'testEmptyImageRejected',
                     'testBlankImageDoesNotProduceSimilarity'):
            self.assertIn('InferenceTests.AuraFaceComparisonTests.'+name, SWIFT_REQUIRED)

    def test_selector_wrapper_cannot_hide_side_effects_behind_updated_digest(self):
        import hashlib
        import json
        with tempfile.TemporaryDirectory() as temporary:
            root = self.checkout(temporary)
            name = 'ios/Sources/BiometricInference/FaceFrameSelection.swift'
            source = root/name
            source.write_text(source.read_text()+'\nlet transport = URLSession.shared\n')
            lock_path = root/'Gates/inference-sources.json'
            lock = json.loads(lock_path.read_text())
            lock[name] = hashlib.sha256(source.read_bytes()).hexdigest()
            lock_path.write_text(json.dumps(lock))
            self.assertTrue(any('cannot own' in error for error in guards.check(root)))

    def test_native_test_evidence_requires_selector_behavior_cases(self):
        from quality.portrait_evidence import SWIFT_REQUIRED
        names = ('testBothPoliciesUseOriginalIndexAndNativeScoreThroughSharedCore',
                 'testNativeTieUsesEarliestOriginalIndexRegardlessOfInputOrder',
                 'testEmptyAndIneligibleBatchesHaveNoFallback',
                 'testSourceBindingsExcludeSubstitutedAndUnavailableObservations',
                 'testQualityFailuresRetainEveryExclusion',
                 'testMalformedPresentDigestRejectsBatchRatherThanSilentlyExcluding',
                 'testDuplicateIdentityOrIndexRejectsWholeBatchEvenWhenFrameFails',
                 'testIdenticalPixelsWithDistinctFrameIdentitiesArePermitted',
                 'testResourceBoundaryAccepts32AndRejects33',
                 'testInvalidLineageAndEmbeddedNulNeverTruncateAcrossBridge')
        for name in names:
            self.assertIn('InferenceTests.FaceFrameSelectionTests.'+name, SWIFT_REQUIRED)


if __name__ == '__main__':
    unittest.main()
