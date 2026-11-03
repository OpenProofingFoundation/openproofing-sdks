"""Adversarial inventory/dependency controls for the shared operation module."""
import argparse
import importlib.util
import io
import hashlib
import json
from pathlib import Path
import runpy
import shutil
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('foundation_check', ROOT/'foundation/scripts/check.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


def copy_sensor_contract_inputs(root):
    """Foundation delegates Sensors validation to its shared contracts and QA owner."""
    for name in ('contracts/sensor-measurement-window-v1.md',
                 'contracts/sensor-measurement-window-v1.vectors.json',
                 'quality/capture_evidence.py'):
        destination = root/name
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(ROOT/name, destination)


class FoundationDestinationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        shutil.copyfile(ROOT/'Package.swift', self.root/'Package.swift')
        shutil.copytree(ROOT/'foundation', self.root/'foundation', ignore=shutil.ignore_patterns('.build', '.swiftpm'))
        copy_sensor_contract_inputs(self.root)

    def run_mocked_cli(self, destination):
        # runpy executes __main__ and derives ROOT from __file__: execute the fixture copy so
        # mocked subprocess results can never overwrite real validation logs or receipts.
        script = str(self.root/'foundation/scripts/check.py')
        arguments = [script, '--platform', 'ios-simulator', '--destination', destination]
        with patch.object(sys, 'argv', arguments), patch('subprocess.run') as process, \
                patch('subprocess.check_output', return_value='fixture-revision\n'):
            process.return_value.returncode = 0
            runpy.run_path(script, run_name='__main__')
        return process

    def test_cli_passes_one_validated_destination_argument_to_xcodebuild(self):
        destination = 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest,arch=arm64'
        process = self.run_mocked_cli(destination)
        process.assert_called_once()
        command = process.call_args.args[0]
        self.assertEqual(command[0], 'xcodebuild')
        self.assertEqual(command[command.index('-destination') + 1], destination)
        self.assertNotIn('shell', process.call_args.kwargs)
        self.assertEqual(process.call_args.kwargs['cwd'], self.root)

    def test_mocked_cli_cannot_create_or_overwrite_checkout_validation_evidence(self):
        real_output = ROOT/'.build/foundation-validation'
        def snapshot():
            return {path.relative_to(real_output).as_posix(): path.read_bytes()
                    for path in real_output.glob('*') if path.is_file()}
        existed = real_output.exists()
        before = snapshot()
        self.run_mocked_cli('platform=iOS Simulator,name=iPhone 17 Pro')
        fixture_receipt = self.root/'.build/foundation-validation/ios-simulator.json'
        receipt = json.loads(fixture_receipt.read_text())
        self.assertEqual(receipt['revision'], 'fixture-revision')
        self.assertEqual(real_output.exists(), existed)
        self.assertEqual(snapshot(), before)

    def test_cli_rejects_an_option_before_creating_output_or_launching_a_process(self):
        script = str(self.root/'foundation/scripts/check.py')
        arguments = [script, '--platform', 'ios-simulator', '--destination=-help']
        with patch.object(sys, 'argv', arguments), patch('subprocess.run') as process, \
                patch.object(Path, 'mkdir') as mkdir, patch('sys.stderr', new_callable=io.StringIO):
            with self.assertRaises(SystemExit) as failure:
                runpy.run_path(script, run_name='__main__')
        self.assertEqual(failure.exception.code, 2)
        process.assert_not_called()
        mkdir.assert_not_called()

    def test_simulator_names_ids_versions_and_architectures_are_permitted(self):
        for destination in [
            'platform=iOS Simulator,name=iPhone 17 Pro',
            'platform=iOS Simulator,name=iPad Pro 11-inch (M4),OS=26.0',
            'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest,arch=arm64',
            'platform=iOS Simulator,id=12345678-1234-5678-ABCD-1234567890AB',
            'platform=iOS Simulator,id=12345678-1234-5678-abcd-1234567890ab,OS=26.0.1,arch=x86_64',
        ]:
            with self.subTest(destination=destination):
                self.assertEqual(CHECK.simulator_destination(destination), destination)

    def test_options_control_characters_and_unknown_selector_fields_are_rejected(self):
        for destination in [
            '-help', '-project=unreviewed.xcodeproj',
            'platform=iOS Simulator,name=iPhone 17 Pro\n-project=unreviewed.xcodeproj',
            'platform=iOS Simulator,name=iPhone 17 Pro;echo injected',
            'platform=iOS Simulator,name=$(echo injected)',
            'platform=iOS Simulator,name=iPhone 17 Pro,unknown=value',
            'platform=iOS Simulator,name=iPhone 17 Pro,name=iPhone 16',
            'platform=iOS Simulator,id=not-a-uuid',
            'platform=iOS Simulator,name=',
            'platform=iOS Simulator,name=' + 'x' * 81,
            'platform=iOS,name=iPhone 17 Pro',
            'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.0,arch=unreviewed',
        ]:
            with self.subTest(destination=destination), self.assertRaises(argparse.ArgumentTypeError):
                CHECK.simulator_destination(destination)


class FoundationContractTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        shutil.copyfile(ROOT/'Package.swift', self.root/'Package.swift')
        shutil.copytree(ROOT/'foundation', self.root/'foundation', ignore=shutil.ignore_patterns('.build', '.swiftpm'))
        copy_sensor_contract_inputs(self.root)

    def test_registered_package(self):
        CHECK.validate(self.root)

    def test_hidden_source_rejected(self):
        (self.root/'foundation/Sources/Hidden.swift').write_text('import Foundation\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_forbidden_capability_dependency_rejected(self):
        p = self.root/'foundation/Sources/KenshikiOperationBinding/SealedOperation.swift'
        p.write_text(p.read_text()+'\nimport PassportSDK\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_missing_source_rejected(self):
        (self.root/'foundation/Sources/KenshikiOperationBinding/SealedOperation.swift').unlink()
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_external_dependency_rejected(self):
        p = self.root/'foundation/Package.swift'
        p.write_text(p.read_text()+'\n// .package(url: "https://synthetic.invalid")\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_hidden_target_rejected(self):
        p = self.root/'foundation/Package.swift'
        p.write_text(p.read_text().replace('name: "KenshikiOperationBinding",', 'name: "HiddenFoundation",', 1))
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_javascript_runtime_permission_is_specific_to_canonical_mechanism(self):
        p = self.root/'foundation/Sources/KenshikiOperationBinding/SealedOperation.swift'
        p.write_text(p.read_text()+'\nimport JavaScriptCore\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_canonical_mechanism_does_not_gain_arbitrary_dependencies(self):
        p = self.root/'foundation/Sources/KenshikiOperationBinding/CanonicalJSON.swift'
        p.write_text(p.read_text()+'\nimport UIKit\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_root_source_redirection_rejected(self):
        p = self.root/'Package.swift'
        p.write_text(p.read_text().replace('foundation/Sources/KenshikiOperationBinding', 'passport/ios/Sources'))
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_root_hidden_dependency_rejected(self):
        p = self.root/'Package.swift'
        p.write_text(p.read_text()+'\n// .package(path: "foundation")\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_missing_root_manifest_rejected(self):
        (self.root/'Package.swift').unlink()
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_only_exact_reviewed_sqlcipher_dependency_is_permitted(self):
        reviewed = f'.package(url: "{CHECK.SQLCIPHER_URL}", revision: "{CHECK.SQLCIPHER_REVISION}")'
        CHECK.validate_manifest(reviewed)
        for mutation in [
            reviewed.replace(CHECK.SQLCIPHER_REVISION, 'main'),
            reviewed.replace('revision:', 'branch:'),
            reviewed.replace('SQLCipher.swift.git', 'SQLCipher-typo.swift.git'),
            reviewed + '\n.package(path: "../unreviewed")',
            reviewed + '\n.unsafeFlags(["-disable-sandbox"])',
            reviewed + '\n.plugin(name: "Unreviewed")',
        ]:
            with self.subTest(mutation=mutation), self.assertRaises(ValueError):
                CHECK.validate_manifest(mutation)

    def test_unregistered_c_glue_is_rejected(self):
        (self.root/'foundation/Sources/Hidden.c').write_text('void hidden(void) {}\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_unregistered_native_header_is_rejected(self):
        (self.root/'foundation/Sources/Hidden.h').write_text('void hidden(void);\n')
        with self.assertRaises(ValueError):
            CHECK.validate(self.root)

    def test_sqlcipher_permission_is_confined_to_storage(self):
        storage = 'foundation/Sources/KenshikiProtectedStorage/Database.swift'
        operation = 'foundation/Sources/KenshikiOperationBinding/SealedOperation.swift'
        self.assertIn('SQLCipher', CHECK.permitted_imports(storage))
        self.assertNotIn('SQLite3', CHECK.permitted_imports(storage))
        self.assertNotIn('SQLCipher', CHECK.permitted_imports(operation))

    def test_supplier_policy_changes_require_review(self):
        p = self.root/'foundation/dependencies.json'
        p.write_text(p.read_text().replace('SQLCipher.swift.git', 'SQLCipher-typo.swift.git'))
        with self.assertRaisesRegex(ValueError, 'supplier/import policy'):
            CHECK.validate(self.root)


class CaptureCustodyFoundationBoundaryTests(unittest.TestCase):
    setUp = FoundationContractTests.setUp
    def test_pre_settlement_erasure_fence_cannot_be_hidden_even_if_patch_hash_is_renewed(self):
        name = 'foundation/Sources/CaptureEvidenceCustody/CaptureCustodyRuntime.swift'
        path = self.root/name
        path.write_text(path.read_text().replace('public func prepareErasure()', 'package func prepareErasure()', 1))
        record_path = self.root/'foundation/capture-custody-extraction.json'
        record = json.loads(record_path.read_text())
        record['destinationSHA256'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
        record_path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'public pre-settlement erasure fence'):
            CHECK.validate(self.root)

    def test_custody_cannot_import_an_identity_product_or_capability(self):
        path = self.root/'foundation/Sources/CaptureEvidenceCustody/CaptureEvidenceStore.swift'
        for module in ['KenshikiIdentity', 'DocumentCapture', 'PassportSDK', 'BiometricSDK', 'SQLCipher']:
            original = path.read_text()
            path.write_text(original + '\nimport ' + module + '\n')
            with self.subTest(module=module), self.assertRaisesRegex(ValueError, 'unreviewed module'):
                CHECK.validate(self.root)
            path.write_text(original)

    def test_extracted_ciphertext_binding_changes_need_updated_patch_provenance(self):
        path = self.root/'foundation/Sources/CaptureEvidenceCustody/CaptureEvidenceEnvelope.swift'
        path.write_text(path.read_text().replace('IdentityEvidenceStorage/v2/metadata/', 'unreviewed/metadata/'))
        with self.assertRaisesRegex(ValueError, 'patch provenance changed'):
            CHECK.validate(self.root)

    def test_declared_custody_target_cannot_add_capability_even_if_manifest_hash_is_renewed(self):
        path = self.root/'foundation/Package.swift'
        text = path.read_text().replace('dependencies: ["KenshikiProtectedStorage", "KenshikiEvidenceManifest"]',
            'dependencies: ["KenshikiProtectedStorage", "KenshikiEvidenceManifest", "DocumentCapture"]', 1)
        path.write_text(text)
        inventory_path = self.root/'foundation/sources.json'
        inventory = json.loads(inventory_path.read_text())
        inventory['manifestSHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
        inventory_path.write_text(json.dumps(inventory))
        with self.assertRaisesRegex(ValueError, 'only shared protected storage'):
            CHECK.validate(self.root)

    def test_synthetic_raw_keys_cannot_escape_debug_even_if_patch_hash_is_renewed(self):
        name = 'foundation/Sources/CaptureEvidenceCustody/CaptureCustodyTestFixture.swift'
        path = self.root/name
        path.write_text(path.read_text().replace('#if DEBUG', '#if true', 1))
        record_path = self.root/'foundation/capture-custody-extraction.json'
        record = json.loads(record_path.read_text())
        record['destinationSHA256'][name] = hashlib.sha256(path.read_bytes()).hexdigest()
        record_path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'debug-only SPI'):
            CHECK.validate(self.root)

    def test_removed_source_attribution_is_not_an_approved_extraction(self):
        path = self.root/'foundation/capture-custody-extraction.json'
        record = json.loads(path.read_text()); record['sourceSHA256'] = {}
        path.write_text(json.dumps(record))
        with self.assertRaisesRegex(ValueError, 'source attribution'):
            CHECK.validate(self.root)
