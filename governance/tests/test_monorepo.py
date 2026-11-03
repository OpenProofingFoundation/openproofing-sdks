"""Adversarial checks mutate the real root workflow and guarded monorepo surfaces."""
from pathlib import Path
import contextlib
import json
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class MonorepoGuardsTests(unittest.TestCase):
    @contextlib.contextmanager
    def checkout(self):
        with tempfile.TemporaryDirectory(prefix='kenshiki-monorepo-guards-') as folder:
            root = Path(folder)/'repo'
            shutil.copytree(ROOT, root, ignore=shutil.ignore_patterns('.git', '.build', '.gradle', 'build', 'node_modules', '__pycache__', '.swiftpm'))
            (root/'node_modules').symlink_to(ROOT/'node_modules', target_is_directory=True)
            yield root

    def inspect(self, root):
        return subprocess.run(['node', 'scripts/monorepo-guards.mjs'], cwd=root, text=True, capture_output=True)

    def test_current_checkout_passes(self):
        result = self.inspect(ROOT)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def test_actual_ci_cannot_skip_or_redirect_lanes(self):
        original = (ROOT/'.github/workflows/ci.yml').read_text()
        mutations = {
            'Sensors job skipped': original.replace('  sensors-ios-simulator:\n', '  sensors-ios-simulator:\n    if: false\n', 1),
            'Sensors command redirected': original.replace('python3 foundation/sensors/check.py --platform macos', 'echo python3 foundation/sensors/check.py --platform macos', 1),
            'Pulse service job skipped': original.replace('  pulse-ios-simulator:\n', '  pulse-ios-simulator:\n    if: false\n', 1),
            'Pulse service command redirected': original.replace('python3 scripts/pulse_check.py', 'echo python3 scripts/pulse_check.py', 1),
            'foundation job skipped': original.replace('  foundation:\n', '  foundation:\n    if: false\n', 1),
            'foundation test redirected': original.replace('python3 foundation/scripts/check.py', 'echo python3 foundation/scripts/check.py', 1),
            'document capture job skipped': original.replace('  document-capture-ios:\n', '  document-capture-ios:\n    if: false\n', 1),
            'document capture command redirected': original.replace('python3 scripts/document_capture_check.py', 'echo python3 scripts/document_capture_check.py', 1),
            'capture job skipped': original.replace('  capture-ios:\n', '  capture-ios:\n    if: false\n', 1),
            'capture command redirected': original.replace('python3 scripts/capture_check.py', 'echo python3 scripts/capture_check.py', 1),
            'NIST tooling skipped': original.replace('  nist-linux:\n', '  nist-linux:\n    if: false\n', 1),
            'NIST command redirected': original.replace('python3 biometric/nist/check.py', 'echo python3 biometric/nist/check.py', 1),
            'inference command redirected': original.replace('python3 biometric/cpp/check_inference.py', 'echo python3 biometric/cpp/check_inference.py', 1),
            'product dropped': original.replace('          - passport\n', '', 1),
            'matrix exclusion': original.replace('      matrix:\n', '      matrix:\n        exclude:\n          - sdk: passport\n', 1),
            'job skip': original.replace('  macos:\n', '  macos:\n    if: false\n', 1),
            'soft failure': original.replace('  guards:\n', '  guards:\n    continue-on-error: true\n', 1),
            'early success': original.replace('python3 scripts/check.py --sdk', 'exit 0; python3 scripts/check.py --sdk', 1),
            'echo instead': original.replace('python3 scripts/check.py --sdk', 'echo python3 scripts/check.py --sdk', 1),
            'root environment': original.replace('jobs:\n', 'env:\n  BASH_ENV: /tmp/skip.sh\njobs:\n', 1),
            'redirected directory': original.replace('jobs:\n', 'defaults:\n  run:\n    working-directory: /tmp\njobs:\n', 1),
            'filtered push': original.replace('  push: null', '  push:\n    paths: [never/**]', 1),
            'bootstrap removed': original.replace('      - run: python3 scripts/bootstrap.py\n', '', 1),
            'public sample generator removed': original.replace('        run: brew install xcodegen', '        run: echo xcodegen', 1),
            'artifact skipped': original.replace('if: always()', 'if: success()', 1),
        }
        for label, value in mutations.items():
            with self.subTest(label=label), self.checkout() as root:
                self.assertNotEqual(value, original, 'Mutation must affect the actual workflow')
                (root/'.github/workflows/ci.yml').write_text(value)
                self.assertNotEqual(self.inspect(root).returncode, 0)

    def test_required_product_cannot_disappear(self):
        with self.checkout() as root:
            path = root/'sdks.json'
            data = json.loads(path.read_text()); del data['products']['passport']
            path.write_text(json.dumps(data))
            self.assertNotEqual(self.inspect(root).returncode, 0)

    def test_python_runtime_and_sonar_target_cannot_drift(self):
        mutations = {
            '.python-version': '3.14.0\n',
            '.sonarcloud.properties': 'sonar.python.version=3.14\n',
        }
        for name, value in mutations.items():
            with self.subTest(name=name), self.checkout() as root:
                (root/name).write_text(value)
                self.assertNotEqual(self.inspect(root).returncode, 0)
        with self.checkout() as root:
            path = root/'.sonarcloud.properties'
            path.write_text(path.read_text()+'sonar.exclusions=**/*.py\n')
            self.assertNotEqual(self.inspect(root).returncode, 0)

    def test_shared_quality_inventory_cannot_expand_unreviewed(self):
        with self.checkout() as root:
            (root/'quality/hidden.py').write_text('pass\n')
            self.assertIn('Unregistered shared QA source',self.inspect(root).stderr)

    def test_reference_gradle_bootstrap_requires_its_own_reviewed_pin(self):
        with self.checkout() as root:
            path = root/'governance/tooling-lock.json'
            data = json.loads(path.read_text())
            del data['reference-apps/android/gradle/wrapper/gradle-wrapper.properties']
            path.write_text(json.dumps(data))
            self.assertIn('Unregistered reference Gradle bootstrap', self.inspect(root).stderr)

    def test_new_shared_source_requires_guard_extension(self):
        for name in ('foundation/Unowned.swift', 'services/unowned.ts', 'services/licence-check/core/src/unowned.ts'):
            with self.subTest(name=name), self.checkout() as root:
                (root/name).write_text('// unregistered implementation\n')
                self.assertIn('outside registered', self.inspect(root).stderr)

    def test_real_assets_are_rejected_outside_capability_too(self):
        for name in ['foundation/portrait.jpg', 'biometric/fixtures/model.safetensors', 'foundation/unregistered-paper.pdf']:
            with self.subTest(name=name), self.checkout() as root:
                (root/name).write_bytes(b'synthetic forbidden asset')
                self.assertIn('Unreviewed binary/model/identity asset', self.inspect(root).stderr)

    def test_frozen_reference_and_tooling_changes_require_review(self):
        for name in ['governance/references/boundary-contract.md', 'scripts/check.py', 'biometric/android/gradle/libs.versions.toml']:
            with self.subTest(name=name), self.checkout() as root:
                path = root/name; path.write_text(path.read_text()+'\n# mutation\n')
                self.assertNotEqual(self.inspect(root).returncode, 0)

    def test_unknown_workflow_and_symlink_are_rejected(self):
        for symlink in (False, True):
            with self.subTest(symlink=symlink), self.checkout() as root:
                if symlink:
                    (root/'foundation/hidden').symlink_to('/tmp', target_is_directory=True)
                else:
                    (root/'.github/workflows/unreviewed.yml').write_text('name: bypass\n')
                self.assertNotEqual(self.inspect(root).returncode, 0)

    def test_licence_package_tests_ignore_stale_runtime_configuration_and_emitted_tests(self):
        package = ROOT/'services/licence-check'
        inventory = json.loads((package/'sources.json').read_text())['files']
        with tempfile.TemporaryDirectory(prefix='licence-fresh-tests-') as temporary:
            fixture = Path(temporary).resolve()/'package'
            for name in inventory:
                source = ROOT/name
                destination = fixture/source.relative_to(package)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
            self.assertFalse((fixture/'node_modules').exists())
            installation = subprocess.run(['npm', 'ci', '--ignore-scripts', '--no-audit', '--no-fund'],
                                          cwd=fixture, capture_output=True, text=True, timeout=120)
            self.assertEqual(installation.returncode, 0, installation.stdout+installation.stderr)
            self.assertFalse((fixture/'node_modules/typescript').is_symlink())
            for directory in ('core', 'trusona'):
                stale = fixture/directory/'.build/test'
                (stale/'test').mkdir(parents=True)
                (stale/'package.json').write_text('{"type":"commonjs"}')
                (stale.parent/'package.json').write_text('{"type":"commonjs"}')
                (stale/'test/untracked.test.js').write_text('throw new Error("Stale emitted test executed");')
            result = subprocess.run(['npm', 'run', 'check'], cwd=fixture, capture_output=True, text=True, timeout=120)
            self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
            for count in (14, 156):
                self.assertIn('ℹ tests '+str(count), result.stdout)
                self.assertIn('ℹ pass '+str(count), result.stdout)
            self.assertIn('ℹ skipped 0', result.stdout)
            for directory in ('core', 'trusona'):
                scratch = fixture/directory/'.build'
                attempts = list(scratch.glob('test-*'))
                self.assertEqual(len(attempts), 1)
                self.assertEqual(json.loads((attempts[0]/'package.json').read_text()), {'type': 'module'})
                self.assertEqual((scratch/'test/package.json').read_text(), '{"type":"commonjs"}')
                self.assertEqual((scratch/'package.json').read_text(), '{"type":"commonjs"}')


if __name__ == '__main__':
    unittest.main()
