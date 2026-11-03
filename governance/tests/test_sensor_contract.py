"""Adversarial checks for independent Sensors packaging and exact native evidence."""
import argparse
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import subprocess
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('sensor_check', ROOT/'foundation/sensors/check.py')
CHECK = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHECK)


class SensorsContractTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory).resolve()
        shutil.copytree(ROOT/CHECK.DIRECTORY, root/CHECK.DIRECTORY,
                        ignore=shutil.ignore_patterns('.build', '.swiftpm', '__pycache__'))
        for name in (CHECK.CONTRACT, CHECK.VECTORS):
            destination = root/name
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, destination)
        return root

    def repin(self, root, name):
        path = root/CHECK.INVENTORY
        value = json.loads(path.read_text())
        value['files'][name] = hashlib.sha256((root/name).read_bytes()).hexdigest()
        path.write_text(json.dumps(value))

    def test_registered_independent_package(self):
        CHECK.validate(ROOT)

    def test_hidden_native_or_resource_inputs_fail_closed(self):
        for suffix in ('.swift', '.c', '.txt'):
            with self.subTest(suffix=suffix), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                (root/CHECK.DIRECTORY/'Sources/KenshikiSensors'/('Hidden'+suffix)).write_text('hidden')
                with self.assertRaisesRegex(ValueError, 'inventory differs'):
                    CHECK.validate(root)

    def test_missing_changed_and_symlinked_sources_fail_closed(self):
        name = CHECK.DIRECTORY+'/Sources/KenshikiSensors/SensorVector3.swift'
        for kind in ('missing', 'changed', 'symlink'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/name
                if kind == 'changed':
                    path.write_text(path.read_text()+'\n// substitution\n')
                else:
                    path.unlink()
                    if kind == 'symlink':
                        path.symlink_to(ROOT/name)
                with self.assertRaises(ValueError):
                    CHECK.validate(root)

    def test_repin_cannot_admit_ui_collection_or_product_dependencies(self):
        name = CHECK.DIRECTORY+'/Sources/KenshikiSensors/SensorVector3.swift'
        for mutation in ('import CoreMotion', 'import SwiftUI', 'import SQLCipher', 'import PassportSDK',
                         'let defaults = UserDefaults.standard'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/name
                path.write_text(path.read_text()+'\n'+mutation+'\n')
                self.repin(root, name)
                with self.assertRaisesRegex(ValueError, 'unreviewed module|cannot acquire'):
                    CHECK.validate(root)

    def test_repin_cannot_hide_external_dependency_or_extra_target(self):
        name = CHECK.DIRECTORY+'/Package.swift'
        mutations = {
            'external-local-package': (
                '    targets: [\n',
                '    dependencies: [.package(path: "../motion")],\n    targets: [\n',
            ),
            'extra-target': (
                '    targets: [\n',
                '    targets: [\n        .target(name: "Hidden"),\n',
            ),
        }
        for label, (before, after) in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/name
                original = path.read_text()
                changed = original.replace(before, after, 1)
                self.assertNotEqual(changed, original, 'Mutation must change the executable manifest')
                path.write_text(changed)
                self.repin(root, name)
                with self.assertRaisesRegex(ValueError, 'independent headless product'):
                    CHECK.validate(root)

    def test_repin_cannot_change_executable_product_or_target_graph(self):
        mutations = {
            'extra-library': (
                'products: [',
                'products: [.library(name: "UnreviewedSensors", targets: ["KenshikiSensors"]), ',
            ),
            'production-dependency-with-whitespace': (
                '.target(name: "KenshikiSensors")',
                '.target (name: "KenshikiSensors", dependencies: ["KenshikiSensorsTests"])',
            ),
            'missing-test-dependency': (
                'dependencies: ["KenshikiSensors"]',
                'dependencies: []',
            ),
            'missing-vector-resource': (
                'resources: [.process("Fixtures")]',
                'resources: []',
            ),
        }
        for label, (before, after) in mutations.items():
            with self.subTest(label=label), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/CHECK.PACKAGE_MANIFEST
                original = path.read_text()
                changed = original.replace(before, after, 1)
                self.assertNotEqual(changed, original, 'Mutation must change the executable manifest')
                path.write_text(changed)
                self.repin(root, CHECK.PACKAGE_MANIFEST)
                with self.assertRaisesRegex(ValueError, 'independent headless product'):
                    CHECK.validate(root)

    def test_original_donor_identity_cannot_be_reclassified(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            path = root/CHECK.CORE_PROVENANCE
            value = json.loads(path.read_text())
            value['files'][0]['sourceSHA256'] = '0'*64
            path.write_text(json.dumps(value))
            self.repin(root, CHECK.CORE_PROVENANCE)
            with self.assertRaisesRegex(ValueError, 'original donor identity'):
                CHECK.validate(root)

    def test_external_consumer_dependencies_cannot_be_repin_redirected(self):
        mutations = (
            ('path: "../.."', 'path: "../../motion"'),
            ('name: "KenshikiSensors", package: "sensors"', 'name: "KenshikiMotion", package: "motion"'),
            ('dependencies: [.product', 'dependencies: ["Hidden", .product'),
        )
        for before, after in mutations:
            with self.subTest(after=after), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/CHECK.CONSUMER_MANIFEST
                original = path.read_text()
                changed = original.replace(before, after, 1)
                self.assertNotEqual(changed, original)
                path.write_text(changed)
                self.repin(root, CHECK.CONSUMER_MANIFEST)
                with self.assertRaisesRegex(ValueError, 'consumer must select only'):
                    CHECK.validate(root)

    def test_external_consumer_cannot_hide_inputs_or_fake_success_after_repin(self):
        mutations = ('hidden-source', 'hidden-resource', 'testable', 'foreign-import', 'fake-success')
        for mutation in mutations:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                source = root/CHECK.CONSUMER_SOURCE
                if mutation.startswith('hidden-'):
                    suffix = '.swift' if mutation == 'hidden-source' else '.txt'
                    (source.parent/('Hidden'+suffix)).write_text('hidden')
                else:
                    additions = {'testable': '\n@testable import KenshikiSensors\n',
                                 'foreign-import': '\nimport PassportSDK\n',
                                 'fake-success': '\nprint("passed")\n'}
                    source.write_text(source.read_text()+additions[mutation])
                    self.repin(root, CHECK.CONSUMER_SOURCE)
                with self.assertRaisesRegex(ValueError, 'inventory differs|consumer must use only|reviewed assertions changed'):
                    CHECK.validate(root)

    def test_external_consumer_refuses_reused_scratch_and_redirected_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            attempt = Path(temporary).resolve()
            (attempt/'consumer-build').mkdir()
            with mock.patch.object(CHECK.subprocess, 'run') as run:
                with self.assertRaises(FileExistsError):
                    CHECK.run_external_consumer(attempt, {})
                run.assert_not_called()
        with tempfile.TemporaryDirectory() as temporary:
            attempt = Path(temporary).resolve()
            with mock.patch.object(CHECK.subprocess, 'run') as run, mock.patch.object(
                    CHECK.subprocess, 'check_output', return_value='/unreviewed/bin\n'):
                with self.assertRaises(ValueError):
                    CHECK.run_external_consumer(attempt, {})
                self.assertEqual(run.call_count, 1, 'A redirected binary must never execute')

    def test_external_consumer_rejects_failed_forged_or_changed_execution(self):
        for mutation in ('empty', 'false-success', 'stderr', 'nonzero', 'changed-binary'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                attempt = Path(temporary).resolve()
                binary = attempt/'consumer-build/bin/SensorsConsumer'

                def run(command, **options):
                    if command[0] == 'swift':
                        self.assertEqual(command[1], 'build')
                        self.assertEqual(command[command.index('--package-path')+1], str(ROOT/CHECK.CONSUMER_DIRECTORY))
                        self.assertEqual(command[command.index('--scratch-path')+1], str(attempt/'consumer-build'))
                        self.assertEqual(command[command.index('--product')+1], 'SensorsConsumer')
                        self.assertNotIn('--skip-build', command)
                        binary.parent.mkdir(parents=True)
                        binary.write_bytes(b'built-consumer-fixture')
                        return subprocess.CompletedProcess(command, 0)
                    self.assertEqual(command, [str(binary)])
                    if mutation == 'changed-binary':
                        binary.write_bytes(b'substituted-consumer-fixture')
                    stdout = {'empty': '', 'false-success': '{"passed":false}\n'}.get(mutation, CHECK.CONSUMER_OUTPUT)
                    return subprocess.CompletedProcess(command, int(mutation == 'nonzero'), stdout,
                                                       'unexpected' if mutation == 'stderr' else '')

                record = {}
                with mock.patch.object(CHECK.subprocess, 'run', side_effect=run), mock.patch.object(
                        CHECK.subprocess, 'check_output', return_value=str(binary.parent)+'\n'):
                    with self.assertRaises((ValueError, subprocess.CalledProcessError)):
                        CHECK.run_external_consumer(attempt, record)
                self.assertFalse(record['passed'])

    def test_macos_qualification_cannot_skip_consumer_even_when_authoring_api(self):
        for write_api in (False, True):
            with self.subTest(write_api=write_api), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary).resolve()
                api = root/CHECK.DIRECTORY/'api/macos.json'
                api.parent.mkdir(parents=True)
                api.write_text('{}')
                api_tool = SimpleNamespace(swift_surface=lambda *args, **kwargs: {})
                with mock.patch.multiple(CHECK, ROOT=root, validate=mock.Mock(return_value=set()),
                        digest=mock.Mock(return_value='0'*64), load_module=mock.Mock(return_value=api_tool),
                        execution_ids=mock.Mock(return_value=['Fixture.testCase']),
                        module_folder=mock.Mock(return_value=root/'Modules'),
                        compiled_artifacts=mock.Mock(return_value={'fixture': '0'*64})), mock.patch.object(
                        CHECK.subprocess, 'check_output', return_value='fixture'), mock.patch.object(
                        CHECK.subprocess, 'run'), mock.patch.object(CHECK, 'run_external_consumer',
                        side_effect=ValueError('external consumer refused')) as consumer:
                    args = SimpleNamespace(platform='macos', destination=None, write_api=write_api)
                    self.assertEqual(CHECK.qualify(args), 1)
                    consumer.assert_called_once()
                receipts = list((root/'.build/sensors-qualification').glob('*/receipt.json'))
                self.assertEqual(len(receipts), 1)
                receipt = json.loads(receipts[0].read_text())
                self.assertFalse(receipt['passed'])
                self.assertFalse(receipt['externalConsumer']['passed'])

    def test_exact_donor_math_cannot_be_repin_reclassified(self):
        name = CHECK.DIRECTORY+'/Sources/KenshikiSensors/EmpiricalDistribution.swift'
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            path = root/name
            path.write_text(path.read_text()+'\n// changed historical math\n')
            self.repin(root, name)
            provenance_path = root/CHECK.CORE_PROVENANCE
            value = json.loads(provenance_path.read_text())
            row = next(row for row in value['files'] if row['destinationPath'] == name)
            row['destinationSHA256'] = hashlib.sha256(path.read_bytes()).hexdigest()
            row['adaptations'] = ['Reclassify historical math as new work']
            provenance_path.write_text(json.dumps(value))
            self.repin(root, CHECK.CORE_PROVENANCE)
            with self.assertRaisesRegex(ValueError, 'exact donor implementation'):
                CHECK.validate(root)

    def test_vector_copy_cannot_diverge_after_repin(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            path = root/CHECK.RESOURCE
            path.write_text(path.read_text()+'\n')
            self.repin(root, CHECK.RESOURCE)
            with self.assertRaisesRegex(ValueError, 'canonical contract'):
                CHECK.validate(root)

    def test_required_ids_cannot_drop_or_duplicate_a_case(self):
        for kind in ('drop', 'duplicate'):
            with self.subTest(kind=kind), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/CHECK.INVENTORY
                value = json.loads(path.read_text())
                if kind == 'drop':
                    value['requiredIDs'].pop()
                else:
                    value['requiredIDs'].append(value['requiredIDs'][0])
                path.write_text(json.dumps(value))
                with self.assertRaisesRegex(ValueError, 'required test inventory'):
                    CHECK.validate(root)

    def test_duplicate_json_keys_cannot_change_reviewed_inventory(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            path = root/CHECK.INVENTORY
            path.write_text(path.read_text().replace('"schemaVersion": 1', '"schemaVersion": 1, "schemaVersion": 1', 1))
            with self.assertRaisesRegex(ValueError, 'Duplicate Sensors JSON key'):
                CHECK.validate(root)

    def test_native_commands_run_all_tests_and_isolate_package_outputs(self):
        attempt = Path('/developer-owned/qa/attempt')
        macos = CHECK.native_command('macos', attempt, None)
        simulator = CHECK.native_command('ios-simulator', attempt, 'platform=iOS Simulator,name=iPhone 17 Pro')
        device = CHECK.native_command('ios-device', attempt, None)
        self.assertIn('--xunit-output', macos)
        self.assertIn(str(ROOT/CHECK.DIRECTORY), macos)
        self.assertFalse(any('--filter' in argument for argument in macos))
        self.assertEqual(simulator[-1], 'test')
        self.assertNotIn('-skip-testing', ' '.join(simulator))
        self.assertEqual(device[-1], 'build')
        self.assertIn('CODE_SIGNING_ALLOWED=NO', device)
        self.assertIn(str(attempt/'build'), simulator)

    def test_macos_artifact_receipt_contains_the_executed_binary(self):
        with tempfile.TemporaryDirectory() as temporary:
            folder = Path(temporary)/'Modules'
            folder.mkdir()
            (folder/'KenshikiSensors.swiftmodule').write_bytes(b'module fixture')
            with self.assertRaisesRegex(ValueError, 'execution artifacts unavailable'):
                CHECK.compiled_artifacts('macos', folder)
            binary = folder.parent/'KenshikiSensorsPackageTests.xctest/Contents/MacOS/KenshikiSensorsPackageTests'
            binary.parent.mkdir(parents=True)
            binary.write_bytes(b'executed binary fixture')
            artifacts = CHECK.compiled_artifacts('macos', folder)
            self.assertIn(binary.relative_to(folder.parent).as_posix(), artifacts)
            self.assertIn('Modules/KenshikiSensors.swiftmodule', artifacts)

    def test_destination_is_one_validated_argument(self):
        destination = 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest,arch=arm64'
        self.assertEqual(CHECK.simulator_destination(destination), destination)
        for value in ('-help', 'platform=iOS Simulator,name=x;echo secret',
                      'platform=iOS Simulator,name=x\n-project=other', 'platform=iOS Simulator,id=not-a-uuid'):
            with self.subTest(value=value), self.assertRaises(argparse.ArgumentTypeError):
                CHECK.simulator_destination(value)

    def test_native_receipts_reject_empty_and_skipped_macos_results(self):
        for payload in ('<testsuite tests="0"/>', '<testsuite tests="1" skipped="1"><testcase classname="KenshikiSensorsTests.FixtureTests" name="testCase"><skipped/></testcase></testsuite>'):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as temporary:
                attempt = Path(temporary)
                (attempt/'tests.xml').write_text(payload)
                with self.assertRaises(ValueError):
                    CHECK.execution_ids('macos', attempt, 1)


if __name__ == '__main__':
    unittest.main()
