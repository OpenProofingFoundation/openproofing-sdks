"""Shared capability guards preserve lexical refusal and dependency verification floors."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('shared_capability_guard_tests', ROOT/'quality/capability_guards.py')
guards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guards)


class SharedCapabilityGuardTests(unittest.TestCase):
    def test_nested_kotlin_comments_and_literals_preserve_offsets(self):
        text = 'val a = "ignored" /* first\n /* nested */ last */\nval b = 1 // tail'
        masked = guards.kotlin_mask(text)
        self.assertEqual(len(masked), len(text))
        self.assertEqual([i for i, c in enumerate(masked) if c == '\n'],
                         [i for i, c in enumerate(text) if c == '\n'])
        self.assertNotIn('ignored', masked)
        self.assertNotIn('nested', masked)
        self.assertIn('val b = 1', masked)
        kept = guards.kotlin_mask(text, strings=True)
        self.assertIn('"ignored"', kept)
        self.assertNotIn('nested', kept)
        for text in ['/* unclosed', '/* one /* nested */', '"unclosed', "'unclosed", '"""unclosed']:
            with self.subTest(text=text), self.assertRaises(ValueError):
                guards.kotlin_mask(text)

    def test_interpolation_cannot_hide_side_effects(self):
        text = 'val value = "${System.getenv(\"SECRET\")}"'
        findings = guards.inspect_kotlin(text)
        self.assertIn(('string interpolation requires reviewed mechanism', 1), findings)
        self.assertEqual(guards.inspect_kotlin('// System.getenv("SECRET")\nval count = 0'), [])

    def fixture(self, root, metadata):
        target = root/'android/gradle/verification-metadata.xml'
        target.parent.mkdir(parents=True)
        target.write_text(metadata)
        manifest = root/'docs/test-dependencies.json'
        manifest.parent.mkdir()
        manifest.write_text(json.dumps({'gradleVerificationSHA256': hashlib.sha256(target.read_bytes()).hexdigest()}))
        return target

    def metadata(self, enabled='true', signatures='false'):
        return ('<verification-metadata xmlns="https://schema.gradle.org/dependency-verification">'
                '<configuration><verify-metadata>'+enabled+'</verify-metadata>'
                '<verify-signatures>'+signatures+'</verify-signatures></configuration>'
                '</verification-metadata>')

    def test_dependency_metadata_requires_pinned_bytes_and_verification_enabled(self):
        for enabled, signatures, accepted in [('true', 'false', True), ('false', 'false', False), ('true', 'true', False)]:
            with self.subTest(enabled=enabled, signatures=signatures), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                target = self.fixture(root, self.metadata(enabled, signatures))
                failures = []
                guards._check_dependency_verification(root, lambda path, message: failures.append(message))
                self.assertEqual(not failures, accepted)
                target.write_text(target.read_text()+'\n')
                failures.clear()
                guards._check_dependency_verification(root, lambda path, message: failures.append(message))
                self.assertEqual(failures, ['reviewed metadata digest differs'])

    def test_dependency_metadata_rejects_symlink_substitution(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            target = self.fixture(root, self.metadata())
            original = root/'original.xml'
            target.rename(original)
            target.symlink_to(original)
            failures = []
            guards._check_dependency_verification(root, lambda path, message: failures.append(message))
            self.assertEqual(failures, ['required verification metadata missing'])

    def test_production_source_inventory_and_test_exemption_remain_explicit(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            approved = root/'ios/Sources/SDK'
            source_roots = [approved]
            failures = []
            guards._check_source_location('hidden/escape.cpp', root/'hidden/escape.cpp', source_roots,
                                          lambda path, message: failures.append(message))
            self.assertEqual(len(failures), 2)
            failures.clear()
            guards._check_source_location('ios/Tests/SDKTests/fixture.cpp', root/'ios/Tests/SDKTests/fixture.cpp', source_roots,
                                          lambda path, message: failures.append(message))
            self.assertEqual(failures, [])


if __name__ == '__main__':
    unittest.main()
