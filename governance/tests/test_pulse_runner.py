"""Shared service qualification must execute the required tests without skips."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('pulse_runner', ROOT/'scripts/pulse_check.py')
RUNNER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(RUNNER)


class PulseExecutionEvidenceTests(unittest.TestCase):
    def test_source_snapshot_records_dependency_edits_and_rejects_directory_symlinks(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            service = root/'services/pulse'
            service.mkdir(parents=True)
            (root/'foundation/Tests').mkdir(parents=True)
            sources = root/'foundation/Sources'
            sources.mkdir()
            for name in RUNNER.FIXED_INPUTS:
                path = root/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text('input')
            dependency = sources/'Dependency.swift'
            dependency.write_text('original')
            with patch.object(RUNNER, 'ROOT', root), patch.object(RUNNER, 'SERVICE', service):
                before = RUNNER.source_hashes()
                dependency.write_text('changed')
                self.assertNotEqual(before, RUNNER.source_hashes())
                target = root/'external'
                target.mkdir()
                (target/'Source.swift').write_text('external')
                linked = sources/'KenshikiOperationBinding'
                linked.symlink_to(target, target_is_directory=True)
                with self.assertRaises(ValueError):
                    RUNNER.source_hashes()
                linked.unlink()
                dependency.unlink()
                sources.rmdir()
                sources.symlink_to(target, target_is_directory=True)
                with self.assertRaises(ValueError):
                    RUNNER.source_hashes()

    def test_macos_requires_exact_unique_passing_cases(self):
        with tempfile.TemporaryDirectory() as folder:
            path = Path(folder)/'tests.xml'
            valid = '<testsuites><testsuite><testcase classname="Module.FlowTests" name="testPrepare"/></testsuite></testsuites>'
            path.write_text(valid)
            required = {'FlowTests.testPrepare'}
            self.assertEqual(RUNNER.macos_cases(path, required), sorted(required))
            mutations = [
                valid.replace('/>', '><skipped/></testcase>'),
                valid.replace('/>', '><failure/></testcase>'),
                valid.replace('/>', '><error/></testcase>'),
                valid.replace('testPrepare', 'testOther'),
                valid.replace('<testsuite>', '<testsuite tests="2" skipped="1">'),
                valid.replace('<testsuite>', '<testsuite tests="2">'),
                valid.replace('<testsuite>', '<testsuite expectedFailures="1">'),
                valid.replace('</testsuite>', '<testcase classname="Module.FlowTests" name="testPrepare"/></testsuite>'),
                '<testsuites/>',
            ]
            for content in mutations:
                with self.subTest(content=content):
                    path.write_text(content)
                    with self.assertRaises(ValueError):
                        RUNNER.macos_cases(path, required)

    def test_native_commands_compile_device_and_execute_required_simulator_target(self):
        attempt = Path('/synthetic/attempt')
        device = RUNNER.native_command('ios-device', attempt, None)
        simulator = RUNNER.native_command('ios-simulator', attempt, 'platform=iOS Simulator,id=fixture')
        macos = RUNNER.native_command('macos', attempt, None)
        self.assertEqual(device[-1], 'build')
        self.assertIn('CODE_SIGNING_ALLOWED=NO', device)
        self.assertIn('SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', device)
        self.assertIn('SWIFT_STRICT_CONCURRENCY=complete', device)
        self.assertEqual(simulator[-1], 'test')
        self.assertIn('-only-testing:KenshikiPulsePassportTests', simulator)
        self.assertIn('-resultBundlePath', simulator)
        self.assertEqual(macos[:2], ['swift', 'test'])
        self.assertIn('--xunit-output', macos)
        self.assertIn('--disable-swift-testing', macos)
        self.assertIn('--parallel', macos)
        self.assertIn('-warnings-as-errors', macos)
        self.assertIn('-strict-concurrency=complete', macos)


if __name__ == '__main__':
    unittest.main()
