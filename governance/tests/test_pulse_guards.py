"""The optional service cannot gain unreviewed sources or invert SDK dependencies."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pulse_guards', ROOT/'quality/pulse_guards.py')
GUARDS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GUARDS)


class PulseAdapterBoundaryTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='pulse-adapter-guard-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.source = self.root/'services/pulse/Sources/KenshikiPulsePassport/Service.swift'
        self.source.parent.mkdir(parents=True)
        self.source.write_text('import Foundation\nimport KenshikiOperationBinding\npublic struct Service {}\n')
        self.test = self.root/'services/pulse/Tests/KenshikiPulsePassportTests/ServiceTests.swift'
        self.test.parent.mkdir(parents=True)
        self.test.write_text('import XCTest\n@testable import KenshikiPulsePassport\n')
        self.manifest = self.root/'Package.swift'
        self.manifest.write_text('// Synthetic reviewed manifest\n')
        policy = {
            'schemaVersion': 1,
            'rootManifestSHA256': hashlib.sha256(self.manifest.read_bytes()).hexdigest(),
            'sources': {
                self.source.relative_to(self.root).as_posix(): 'vendor-adapter',
                self.test.relative_to(self.root).as_posix(): 'test',
            },
        }
        self.policy = self.root/'services/pulse/sources.json'
        self.policy.write_text(json.dumps(policy))

    def test_reviewed_optional_service_and_own_internal_tests_are_admitted(self):
        self.assertEqual(GUARDS.check(self.root), [])

    def test_hidden_source_language_missing_source_and_symlink_are_rejected(self):
        for change in ('hidden-swift', 'hidden-c', 'missing', 'symlink'):
            with self.subTest(change=change):
                path = self.source.parent/('Hidden.c' if change == 'hidden-c' else 'Hidden.swift')
                original = self.source.read_bytes()
                if change == 'missing':
                    self.source.unlink()
                elif change == 'symlink':
                    path.symlink_to(self.source)
                else:
                    path.write_text('void hidden(void) {}' if change == 'hidden-c' else 'struct Hidden {}')
                self.assertTrue(GUARDS.check(self.root))
                if path.exists() or path.is_symlink():
                    path.unlink()
                self.source.write_bytes(original)

    def test_capability_ui_and_old_sdk_imports_are_forbidden(self):
        original = self.source.read_text()
        for module in ('PassportSDK', 'BiometricSDK', 'UIKit', 'SwiftUI', 'IdentityGateway', 'CaptureSelfie'):
            with self.subTest(module=module):
                self.source.write_text(original+'\nimport '+module+'\n')
                self.assertTrue(any('Forbidden Pulse adapter dependency' in error for error in GUARDS.check(self.root)))

    def test_production_cannot_borrow_test_or_private_surface(self):
        original = self.source.read_text()
        for extra in ('@testable import KenshikiOperationBinding', '@_spi(Test) import KenshikiOperationBinding',
                      'let reflected = Mirror(reflecting: 1)', 'let hidden = value._private'):
            with self.subTest(extra=extra):
                self.source.write_text(original+'\n'+extra+'\n')
                self.assertTrue(any('public SDK surface' in error for error in GUARDS.check(self.root)))

    def test_import_layout_comments_and_scoped_imports_cannot_hide_dependencies(self):
        statements = (
            'import Foundation; import PassportSDK',
            'import /* trivia */ PassportSDK',
            'import /* outer /* nested */ end */ struct PassportSDK.Observation',
            'import\nclass\nPassportSDK.Observation',
            'import`PassportSDK`',
            'let value = #"ends with a backslash\\"#; import PassportSDK',
            'let value = ##"one # is not an escape \\#"##; import PassportSDK',
        )
        for statement in statements:
            with self.subTest(statement=statement):
                self.source.write_text(statement+'\npublic struct Service {}\n')
                self.assertTrue(any('Forbidden Pulse adapter dependency' in error for error in GUARDS.check(self.root)))

    def test_import_text_in_comments_and_swift_literals_is_inert(self):
        source = '''import struct Foundation.Date
// import PassportSDK
/* outer /* import PassportSDK */ import BiometricSDK */
let ordinary = "import PassportSDK; /* not a comment */"
let raw = #"import PassportSDK; \\"#
let multiline = """
import PassportSDK
"""
let rawMultiline = ##"""
import PassportSDK
"""##
public struct Service {}
'''
        self.source.write_text(source)
        self.assertEqual(GUARDS.check(self.root), [])

    def test_neutral_import_layout_cannot_reverse_the_dependency(self):
        path = self.root/'foundation/Sources/Neutral/Neutral.swift'
        path.parent.mkdir(parents=True)
        for statement in (
            'import Foundation; import KenshikiPulsePassport',
            'import /* trivia */ KenshikiPulsePassport',
            'import struct KenshikiPulsePassport.Acceptance',
            'let value = #"ends with a backslash\\"#; import KenshikiPulsePassport',
        ):
            with self.subTest(statement=statement):
                path.write_text(statement+'\n')
                self.assertTrue(any('Neutral module depends' in error for error in GUARDS.check(self.root)))
        path.write_text('let note = "import KenshikiPulsePassport"\n/* import KenshikiPulsePassport */\n')
        self.assertEqual(GUARDS.check(self.root), [])

    def test_neutral_foundation_capability_and_presentation_cannot_import_service(self):
        for folder in ('foundation', 'passport', 'document', 'biometric', 'presentation'):
            for manifest in (False, True):
                with self.subTest(folder=folder, manifest=manifest):
                    path = self.root/folder/('Package.swift' if manifest else 'Sources/Neutral/Neutral.swift')
                    path.parent.mkdir(parents=True, exist_ok=True)
                    path.write_text('let dependency = "KenshikiPulsePassport"' if manifest else 'import KenshikiPulsePassport\n')
                    self.assertTrue(any('Neutral module depends' in error for error in GUARDS.check(self.root)))
                    path.unlink()

    def test_role_escape_and_changed_package_graph_are_rejected(self):
        original = self.policy.read_text()
        policy = json.loads(original)
        policy['sources'][self.source.relative_to(self.root).as_posix()] = 'test'
        self.policy.write_text(json.dumps(policy))
        self.assertTrue(any('source role' in error for error in GUARDS.check(self.root)))
        self.policy.write_text(original)
        self.manifest.write_text('let hidden = "dependency"\n')
        self.assertTrue(any('package graph' in error for error in GUARDS.check(self.root)))


if __name__ == '__main__':
    unittest.main()
