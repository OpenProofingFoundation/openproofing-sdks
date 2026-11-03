"""Mutation coverage for the real passport supplier, graph and neutral boundaries."""
import contextlib
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

from quality import boundary_entry, capability_guards, capture_guards, passport_guards
from quality.boundary_entry import configure, engine, findings

ROOT = Path(__file__).resolve().parents[2]
SUPPLIER = passport_guards.SUPPLIER
RUNTIME = 'ios/Sources/PassportNFC/PassportChipReader.swift'


class PassportGuardsTests(unittest.TestCase):
    @contextlib.contextmanager
    def checkout(self):
        with tempfile.TemporaryDirectory() as folder:
            parent = Path(folder)
            root = parent/'passport'
            ignored = shutil.ignore_patterns('.build', '.gradle', 'build', '__pycache__', 'node_modules')
            shutil.copytree(ROOT/'passport', root, ignore=ignored)
            shutil.copytree(ROOT/'quality', parent/'quality', ignore=ignored)
            (parent/'governance').mkdir()
            shutil.copy2(ROOT/'governance/tooling-lock.json', parent/'governance/tooling-lock.json')
            yield root

    def check(self, root):
        with patch.dict(sys.modules, {'boundary_gates': boundary_entry,
                                      'capture_guards': capture_guards}):
            return passport_guards.check(root)[1]

    def graph(self, root):
        problems = []
        passport_guards.check_graph(root, configure(engine(root), root),
                                   lambda path, message: problems.append((path, message)))
        return problems

    def change_lock(self, root, mutate):
        path = root/'Gates/extraction-sources.json'
        data = json.loads(path.read_text())
        mutate(data)
        path.write_text(json.dumps(data))

    def refresh(self, root, name):
        digest = hashlib.sha256((root/name).read_bytes()).hexdigest()
        def mutate(data):
            for row in data['files'] + data['supplierFiles'] + data.get('authoredSources', []):
                if row['destination'] == name:
                    row['destinationSHA256'] = digest
                    return
            self.fail('Mutation target must already be registered')
        self.change_lock(root, mutate)

    def test_current_sources_and_exact_graph_pass(self):
        self.assertEqual(self.check(ROOT/'passport'), [])
        self.assertEqual(self.graph(ROOT/'passport'), [])

    def test_supplier_addition_deletion_and_byte_edit_fail(self):
        name = SUPPLIER+'/Sources/NFCPassportReader/ResponseAPDU.swift'
        with self.checkout() as root:
            added = root/SUPPLIER/'Sources/NFCPassportReader/Unreviewed.swift'
            added.write_text('struct Unreviewed {}\n')
            self.assertTrue(self.check(root))
            added.unlink()
            original = (root/name).read_bytes()
            (root/name).write_bytes(original+b'\n// changed supplier bytes\n')
            self.assertTrue(self.check(root))
            (root/name).unlink()
            self.assertTrue(self.check(root))

    def test_refreshing_supplier_digest_cannot_self_authorize_changed_bytes(self):
        name = SUPPLIER+'/Sources/NFCPassportReader/ResponseAPDU.swift'
        with self.checkout() as root:
            path = root/name
            path.write_text(path.read_text()+'\n// a refreshed local registry is not approval\n')
            self.refresh(root, name)
            self.assertIn('passport extraction registry requires reviewed tooling pin', self.check(root))

    def test_supplier_symlink_fails_even_with_identical_bytes(self):
        with self.checkout() as root:
            target = root/SUPPLIER/'LICENSE'
            replacement = root/'same-license.txt'
            replacement.write_bytes(target.read_bytes())
            target.unlink()
            target.symlink_to(replacement)
            self.assertTrue(self.check(root))

    def test_unregistered_authored_runtime_source_fails(self):
        with self.checkout() as root:
            (root/'ios/Sources/PassportNFC/Unreviewed.swift').write_text(
                'import Foundation\nstruct Unreviewed {}\n')
            self.assertTrue(self.check(root))

    def test_donor_hash_tampering_fails(self):
        for field in ('files', 'supplierFiles'):
            with self.subTest(field=field), self.checkout() as root:
                self.change_lock(root, lambda data: data[field][0].update(sourceSHA256='0'*64))
                self.assertTrue(self.check(root))

    def test_authored_readiness_cannot_claim_a_donor_or_expand_inventory(self):
        for mutation in ('donor', 'missing', 'extra', 'bytes'):
            with self.subTest(mutation=mutation), self.checkout() as root:
                def change(data):
                    rows = data['authoredSources']
                    if mutation == 'donor':
                        rows[0]['sourceRepository'] = 'kenshiki-identity-sdk'
                    elif mutation == 'missing':
                        rows.clear()
                    elif mutation == 'extra':
                        rows.append(dict(rows[0], destination='ios/Sources/PassportNFC/Hidden.swift'))
                    else:
                        rows[0]['destinationSHA256'] = '0'*64
                self.change_lock(root, change)
                # Repin the registry so the authored-source checks, not only its outer pin, reject it.
                path = root.parent/'governance/tooling-lock.json'
                lock = json.loads(path.read_text())
                lock['passport/Gates/extraction-sources.json'] = hashlib.sha256(
                    (root/'Gates/extraction-sources.json').read_bytes()).hexdigest()
                path.write_text(json.dumps(lock))
                self.assertTrue(any('authored source' in value for value in self.check(root)))

    def test_only_exact_private_zero_clock_state_is_classified(self):
        name = 'ios/Sources/PassportMRZCapture/MRZReadinessGate.swift'
        with self.checkout() as root:
            self.assertNotIn('no_policy_numbers', '\n'.join(findings(root)))
        for old, new in [
            ('firstTimestamp: TimeInterval = 0', 'firstTimestamp: TimeInterval = 0.5'),
            ('lastTimestamp: TimeInterval = 0', 'lastTimestamp: TimeInterval = 1'),
            ('private var firstTimestamp', 'public var firstTimestamp'),
        ]:
            with self.subTest(new=new), self.checkout() as root:
                path = root/name
                self.assertIn(old, path.read_text())
                path.write_text(path.read_text().replace(old, new, 1))
                self.assertIn('no_policy_numbers', '\n'.join(findings(root)))
        with self.checkout() as root:
            path = root/name
            path.write_text(path.read_text()+'\nprivate let minimumConfidence: Double = 0.5\n')
            self.assertIn('no_policy_numbers', '\n'.join(findings(root)))

    def test_reviewed_diagnostics_cannot_emit_mrz_text_or_add_another_sink(self):
        name = passport_guards.DIAGNOSTIC_SOURCE
        source = (ROOT/'passport'/name).read_text()
        safe = passport_guards.reviewed_diagnostic_source(name, source)
        self.assertNotIn('Logger(', safe)
        self.assertIn('logger.notice(', safe)
        self.assertEqual(passport_guards.reviewed_diagnostic_source('other.swift', source), source)
        for changed in (
            source.replace('rows=\\(frame.candidates.count)', 'rows=\\(frame.candidates)'),
            source.replace('self.readiness.status.rawValue, frame: frame', 'frame.candidates[0][0], frame: frame'),
            source + '\nlet other = Logger()\n',
            source + '\nfunc leak() { logger.notice("secret") }\n',
        ):
            self.assertIn('Logger(', passport_guards.reviewed_diagnostic_source(name, changed))

    def test_refreshed_digest_does_not_allow_forbidden_imports_or_custody(self):
        probes = ['import IdentityEvidenceStorage', 'import Network',
                  'internal import\tNetwork', 'import\nNetwork',
                  'let store = UserDefaults.standard', 'let request = URLRequest()',
                  'import SwiftUI']
        for probe in probes:
            with self.subTest(probe=probe), self.checkout() as root:
                path = root/RUNTIME
                path.write_text(path.read_text()+'\n'+probe+'\n')
                self.refresh(root, RUNTIME)
                self.assertTrue(any('unexpected import' in value or
                                    'product storage, network or workflow' in value
                                    for value in self.check(root)))

    def test_camera_diagnostics_allow_only_reviewed_native_scalars(self):
        name = passport_guards.CAMERA_DIAGNOSTIC_SOURCE
        source = (ROOT/'passport'/name).read_text()
        self.assertNotIn('Logger(', passport_guards.reviewed_diagnostic_source(name, source))
        for changed in (
            source.replace('let lens = MRZCameraSelection.lens(for: device.deviceType).rawValue',
                           'let lens = device.uniqueID'),
            source.replace('let lens = MRZCameraSelection.lens(for: device.deviceType).rawValue',
                           'let lens = device.localizedName'),
            source.replace('lens=\\(lens, privacy: .public)', 'lens=\\(frame.candidates, privacy: .public)'),
            source.replace('lens=\\(lens, privacy: .public)', 'lens=\\(error.localizedDescription, privacy: .public)'),
            source.replace('self.diagnoseCamera()', 'self.diagnoseCamera(secret)'),
            source + '\nlet other = Logger()\n',
            source + '\nfunc leak() { logger.notice("secret") }\n',
        ):
            self.assertNotEqual(changed, source)
            self.assertIn('Logger(', passport_guards.reviewed_diagnostic_source(name, changed))
            with self.checkout() as root:
                (root/name).write_text(changed)
                problems = []
                with patch.dict(sys.modules, {'boundary_gates': boundary_entry,
                                              'passport_guards': passport_guards}):
                    capability_guards._check_swift_file(root, root/name,
                        lambda path, message: problems.append(message), capability='passport')
                self.assertIn('native diagnostics require a reviewed reason-code sink', problems)

    def test_authored_products_still_receive_neutral_rules(self):
        probes = {'no_authored_sentence': 'public let instruction = "Hold the passport steady."',
                  'no_ambient': 'public let instant = Date()',
                  'no_verdict': 'public var isIdentityAccepted: Bool { true }'}
        for rule, probe in probes.items():
            with self.subTest(rule=rule), self.checkout() as root:
                path = root/RUNTIME
                path.write_text(path.read_text()+'\n'+probe+'\n')
                self.refresh(root, RUNTIME)
                self.assertIn(rule, '\n'.join(findings(root)))

    def test_package_graph_and_dependency_mutations_fail(self):
        mutations = [
            ('targets: ["PassportNFC"]', 'targets: ["PassportSDK"]'),
            ('"PassportSDK",\n            .product', '"PassportMRZPreview",\n            .product'),
            ('path: "ios/Sources/PassportNFC"', 'path: "ios/Sources/PassportSDK"'),
            ('.package(path: "'+SUPPLIER+'")', '.package(path: "../outside")'),
        ]
        for old, new in mutations:
            with self.subTest(mutation=new), self.checkout() as root:
                manifest = root/'Package.swift'
                original = manifest.read_text()
                self.assertIn(old, original)
                manifest.write_text(original.replace(old, new, 1))
                self.assertTrue(self.graph(root))

    def test_missing_graph_lock_and_disabled_test_target_fail(self):
        with self.checkout() as root:
            manifest = root/'Package.swift'
            original = manifest.read_text()
            manifest.write_text(original.replace('.testTarget(name: "PassportNFCTests"',
                                                 '.testTarget(name: "DisabledNFCTests"'))
            self.assertTrue(self.graph(root))
            manifest.write_text(original)
            (root/'Gates/passport-graph.json').unlink()
            self.assertTrue(self.graph(root))

    def test_dynamic_openssl_pin_cannot_hide_behind_refreshed_supplier_digest(self):
        name = SUPPLIER+'/Package.swift'
        with self.checkout() as root:
            path = root/name
            original = path.read_text()
            self.assertIn(passport_guards.PIN, original)
            path.write_text(original.replace('.revision("'+passport_guards.PIN+'")',
                                             '.upToNextMinor(from: "3.3.3001")'))
            self.refresh(root, name)
            self.assertIn('OpenSSL must retain exact reviewed revision', self.check(root))

    def test_authored_test_and_helper_inventory_is_closed_even_after_registry_repin(self):
        for mutation in ('missing-test', 'extra-test', 'missing-hash', 'missing-helper', 'helper-donor'):
            with self.subTest(mutation=mutation), self.checkout() as root:
                path = root/'Gates/extraction-tests.json'
                registry = json.loads(path.read_text())
                if mutation == 'missing-test':
                    registry['authoredTests'].pop()
                elif mutation == 'extra-test':
                    registry['authoredTests'].append('ios/Tests/PassportNFCTests/HiddenTests.swift')
                elif mutation == 'missing-hash':
                    registry['authoredTestSHA256'].pop(next(iter(registry['authoredTestSHA256'])))
                elif mutation == 'missing-helper':
                    registry['authoredTestHelpers'].clear()
                else:
                    registry['authoredTestHelpers'][0]['origin'] = 'kenshiki-identity-sdk'
                path.write_text(json.dumps(registry))
                self.repin_test_registry(root)
                self.assertTrue(any('authored test' in problem for problem in self.check(root)))

    def test_authored_regression_cannot_be_reclassified_as_a_donor_test(self):
        with self.checkout() as root:
            path = root/'Gates/extraction-tests.json'
            registry = json.loads(path.read_text())
            name = registry['authoredTests'][0]
            registry['files'].append({
                'source': 'Tests/InventedDonor.swift', 'sourceSHA256': 'a'*64,
                'destination': 'passport/'+name,
                'destinationSHA256': registry['authoredTestSHA256'][name], 'patch': 'invented donor',
            })
            path.write_text(json.dumps(registry))
            self.repin_test_registry(root)
            self.assertIn('passport authored test cannot claim donor provenance', self.check(root))

    def test_test_and_helper_addition_deletion_edits_and_symlinks_fail(self):
        name = 'ios/Tests/PassportNFCTests/ReaderProtocolFixture.swift'
        for mutation in ('added', 'deleted', 'edited', 'symlink'):
            with self.subTest(mutation=mutation), self.checkout() as root:
                path = root/name
                if mutation == 'added':
                    path.with_name('UnreviewedTests.swift').write_text('import XCTest\n')
                elif mutation == 'deleted':
                    path.unlink()
                elif mutation == 'edited':
                    path.write_text(path.read_text()+'\n// altered cryptographic oracle\n')
                else:
                    target = root/'same-fixture.swift'
                    target.write_bytes(path.read_bytes())
                    path.unlink()
                    path.symlink_to(target)
                problems = self.check(root)
                self.assertTrue(any('passport test source inventory differs' in value
                                    or 'passport test provenance differs' in value for value in problems))

    def test_refreshing_test_digest_requires_separate_reviewed_tooling_pin(self):
        with self.checkout() as root:
            name = 'ios/Tests/PassportNFCTests/PassportActiveAuthenticationTests.swift'
            source = root/name
            source.write_text(source.read_text()+'\n// changed proof construction\n')
            path = root/'Gates/extraction-tests.json'
            registry = json.loads(path.read_text())
            registry['authoredTestSHA256'][name] = hashlib.sha256(source.read_bytes()).hexdigest()
            path.write_text(json.dumps(registry))
            self.assertIn('passport test registry requires reviewed tooling pin', self.check(root))

    @staticmethod
    def repin_test_registry(root):
        """Model explicit policy approval so mutations exercise inventory checks too."""
        path = root.parent/'governance/tooling-lock.json'
        tooling = json.loads(path.read_text())
        tooling['passport/Gates/extraction-tests.json'] = hashlib.sha256(
            (root/'Gates/extraction-tests.json').read_bytes()).hexdigest()
        path.write_text(json.dumps(tooling))


if __name__ == '__main__':
    unittest.main()
