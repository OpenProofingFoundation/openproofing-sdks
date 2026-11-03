"""Adversarial checks that retired inference cannot re-enter SDK or adopter graphs."""
from pathlib import Path
import importlib.util
import shutil
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('retired_visual_guards', ROOT/'quality/visual_assessment_guards.py')
guards = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guards)

class VisualRetirementGuardsTests(unittest.TestCase):
    def checkout(self, temporary):
        root = Path(temporary)/'repo'
        names = ['biometric/Package.swift', 'reference-apps/ios/project.yml']
        names += [guards.ARCHIVE+'/'+name for name in guards.ARCHIVE_FILES]
        for name in names:
            target = root/name
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(ROOT/name, target)
        return root

    def test_current_retirement_boundary_keeps_legacy_records_without_inference(self):
        self.assertEqual(guards.check(ROOT/'biometric'), [])

    def test_reintroduced_model_target_and_remote_dependency_are_rejected(self):
        for addition in ['.library(name: "BiometricVisualAssessment", targets: ["BiometricVisualAssessment"])',
                         '.package(url: "https://github.com/ml-explore/mlx-swift", revision: "'+'0'*40+'")',
                         '.package(url: "https://example.com/hidden-runtime", revision: "'+'0'*40+'")']:
            with self.subTest(addition=addition), tempfile.TemporaryDirectory() as temporary:
                root=self.checkout(temporary);p=root/'biometric/Package.swift'
                p.write_text(p.read_text()+'\n'+addition)
                self.assertTrue(guards.check(root/'biometric'))

    def test_archive_inventory_and_source_symlink_are_rejected(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=self.checkout(temporary);folder=root/guards.ARCHIVE
            (folder/'Hidden.swift').write_text('import Foundation\n')
            self.assertTrue(guards.check(root/'biometric'))
            (folder/'Hidden.swift').unlink()
            original=folder/'ReviewJSON.swift';outside=Path(temporary)/'outside.swift'
            outside.write_bytes(original.read_bytes());original.unlink();original.symlink_to(outside)
            self.assertTrue(guards.check(root/'biometric'))

    def test_archive_file_access_work_scheduling_and_active_imports_are_rejected(self):
        for addition in ['\nimport MLX\n', '\nimport CoreImage\n', '\nlet x = Task {}\n',
                         '\nlet x = try Data(contentsOf: url)\n', '\nactor Hidden {}\n']:
            with self.subTest(addition=addition), tempfile.TemporaryDirectory() as temporary:
                root=self.checkout(temporary);p=root/guards.ARCHIVE/'ReviewJSON.swift'
                p.write_text(p.read_text()+addition)
                self.assertTrue(guards.check(root/'biometric'))

    def test_reintroduced_app_runtime_and_model_provisioning_are_rejected(self):
        for name,addition in [('reference-apps/ios/Sources/Hidden.swift','import MLXVLM\n'),
                              ('reference-apps/ios/Sources/Hidden.swift','func runLiquid() {}\n'),
                              ('scripts/provision_reference_visual_model.py','pass\n'),
                              ('biometric/ios/Sources/BiometricVisualAssessment/Record.swift','import Foundation\n')]:
            with self.subTest(name=name), tempfile.TemporaryDirectory() as temporary:
                root=self.checkout(temporary);p=root/name;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(addition)
                self.assertTrue(guards.check(root/'biometric'))

    def test_reference_app_cannot_link_retired_product_or_provision_weights(self):
        for addition in ['product: BiometricVisualAssessment', 'script: provision_reference_visual_model.py', 'LiquidFaceModel']:
            with self.subTest(addition=addition), tempfile.TemporaryDirectory() as temporary:
                root=self.checkout(temporary);p=root/'reference-apps/ios/project.yml';p.write_text(p.read_text()+'\n'+addition)
                self.assertTrue(guards.check(root/'biometric'))
