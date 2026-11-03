"""Shared motion keeps the original math and a closed, independent native source graph."""
import hashlib
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('motion_contract', ROOT/'foundation/motion/check.py')
motion = importlib.util.module_from_spec(spec)
spec.loader.exec_module(motion)


class MotionContractTests(unittest.TestCase):
    def fixture(self, directory):
        root = Path(directory).resolve()
        shutil.copytree(ROOT/'foundation/motion', root/'foundation/motion',
                        ignore=shutil.ignore_patterns('.build', '.swiftpm', '__pycache__'))
        return root

    def repin(self, root, name):
        path = root/motion.PROVENANCE
        record = json.loads(path.read_text())
        record['files'][name]['destinationSHA256'] = hashlib.sha256((root/name).read_bytes()).hexdigest()
        path.write_text(json.dumps(record))

    def test_registered_shared_motion_package(self):
        motion.validate(ROOT)

    def test_changed_summary_cannot_be_reclassified_as_new_work(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = self.fixture(temporary)
            path = root/motion.SUMMARY
            path.write_text(path.read_text()+'\n// changed math\n')
            self.repin(root, motion.SUMMARY)
            with self.assertRaisesRegex(ValueError, 'exact donor'):
                motion.validate(root)

    def test_witness_cannot_acquire_unreviewed_dependencies_after_repin(self):
        for mutation in ('import Network', 'import UIKit', 'let defaults = UserDefaults.standard'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                path = root/motion.WITNESS
                path.write_text(path.read_text()+'\n'+mutation+'\n')
                self.repin(root, motion.WITNESS)
                with self.assertRaisesRegex(ValueError, 'cannot acquire'):
                    motion.validate(root)

    def test_extra_source_missing_attribution_and_external_package_fail(self):
        for mutation in ('extra', 'donor', 'dependency'):
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as temporary:
                root = self.fixture(temporary)
                if mutation == 'extra':
                    (root/motion.DIRECTORY/'Sources/KenshikiMotion/Hidden.swift').write_text('import Foundation\n')
                elif mutation == 'donor':
                    path = root/motion.PROVENANCE
                    value = json.loads(path.read_text())
                    value['files'][motion.WITNESS]['sourceSHA256'] = '0'*64
                    path.write_text(json.dumps(value))
                else:
                    name = motion.DIRECTORY+'/Package.swift'
                    path = root/name
                    path.write_text(path.read_text()+'\n// .package(path: "../unreviewed")\n')
                    self.repin(root, name)
                with self.assertRaises(ValueError):
                    motion.validate(root)

    def test_native_runner_requires_every_original_math_case(self):
        self.assertEqual(len(motion.REQUIRED), 18)
        source = ''.join((ROOT/name).read_text() for name in (motion.TEST, motion.WITNESS_TEST, motion.PERMISSION_TEST))
        for name in motion.REQUIRED:
            self.assertIn('func '+name.rsplit('.', 1)[1]+'(', source)
