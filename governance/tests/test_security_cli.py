"""Adversarial checks for CLI command and filesystem boundaries."""
import argparse
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]


def load(name, relative):
    spec = importlib.util.spec_from_file_location(name, ROOT/relative)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


runner = load('root_check_security', 'scripts/check.py')
nist = load('nist_check_security', 'biometric/nist/check.py')
architecture = load('architecture_security', 'governance/architecture/validate_architecture.py')


class CLISecurityTests(unittest.TestCase):
    def test_project_runtime_rejects_unpinned_python(self):
        expected = (ROOT/'.python-version').read_text().strip()
        with patch.object(runner.platform, 'python_version', return_value=expected):
            runner.require_python()
        for version in ('3.9.6', '3.12.0', '3.15.1'):
            with self.subTest(version=version), patch.object(runner.platform, 'python_version', return_value=version):
                with self.assertRaisesRegex(RuntimeError, 'Python '+expected):
                    runner.require_python()

    def test_source_hashes_exclude_compiler_session_markers_but_bind_real_sources(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            source = root/'Workflow.kt'
            source.write_text('class Workflow')
            with patch.object(runner, 'ROOT', root):
                original = runner.input_hashes()
                marker = root/'reference-apps/android/.kotlin/sessions/compiler.salive'
                marker.parent.mkdir(parents=True)
                marker.write_text('ephemeral compiler session')
                self.assertEqual(runner.input_hashes(), original)
                marker.unlink()
                self.assertEqual(runner.input_hashes(), original)
                source.write_text('class ChangedWorkflow')
                self.assertNotEqual(runner.input_hashes(), original)

    def test_lane_runner_refuses_command_or_option_injection_before_execution(self):
        bad = [
            ['bash', '-c', 'touch /tmp/unexpected'],
            ['bash', '../document/scripts/check.sh', 'guards'],
            ['bash', 'document/scripts/check.sh', '--help'],
            ['node', 'scripts/monorepo-guards.mjs', '--eval=process.exit()'],
            ['python3', 'biometric/nist/check.py', '--compiler', 'sh'],
        ]
        with patch.object(runner.subprocess, 'run') as execute:
            for command in bad:
                with self.subTest(command=command), self.assertRaises(ValueError):
                    runner.run('document-guards', command, {})
            execute.assert_not_called()

    def test_lane_runner_refuses_receipt_traversal(self):
        with patch.object(runner.subprocess, 'run') as execute:
            with self.assertRaises(ValueError):
                runner.run('../../outside', ['bash', 'document/scripts/check.sh', 'guards'], {})
            execute.assert_not_called()

    def test_all_supported_workflow_commands_are_repository_constants(self):
        for command in (runner.LICENCE_INSTALL, (runner.sys.executable, runner.LICENCE_CHECK, '--execute')):
            self.assertEqual(runner.APPROVED_COMMANDS[command], command)
        self.assertLessEqual({'licence-check-dependencies', 'licence-check-packages'}, runner.APPROVED_LABELS)
        for product in runner.PRODUCTS:
            for lane in runner.LANES:
                command = ('bash', product+'/scripts/check.sh', lane)
                self.assertEqual(runner.APPROVED_COMMANDS[command], command)
        for _, command in runner.GOVERNANCE:
            self.assertEqual(runner.APPROVED_COMMANDS[command], command)
        for lane in runner.PRESENTATION_LANES:
            command = (runner.sys.executable, 'scripts/presentation_check.py', '--platform', lane)
            self.assertEqual(runner.APPROVED_COMMANDS[command], command)
        for lane in ('macos', 'ios-device', 'ios-simulator'):
            command = (runner.sys.executable, 'scripts/pulse_check.py', '--platform', lane)
            self.assertEqual(runner.APPROVED_COMMANDS[command], command)
            self.assertIn('pulse-'+lane, runner.APPROVED_LABELS)
            self.assertNotIn(command+('--write-api',), runner.APPROVED_COMMANDS)

    def test_all_scope_executes_every_capability_nist_and_presentation_lane(self):
        with patch.object(runner.sys, 'argv', ['check.py', '--platform', 'all']), \
                patch.object(runner, 'input_hashes', return_value={}), \
                patch.object(runner, 'run', return_value=True) as execute:
            self.assertEqual(runner.main(), 0)
        labels = {call.args[0] for call in execute.call_args_list}
        self.assertLessEqual({product+'-'+lane for product in runner.PRODUCTS for lane in runner.LANES}, labels)
        self.assertIn('biometric-nist', labels)
        self.assertLessEqual({'presentation-'+lane for lane in runner.PRESENTATION_LANES}, labels)
        self.assertLessEqual({'pulse-'+lane for lane in ('macos', 'ios-device', 'ios-simulator')}, labels)
        licence = [(call.args[0], tuple(call.args[1])) for call in execute.call_args_list
                   if call.args[0] in {'licence-check-dependencies', 'licence-check-packages'}]
        self.assertEqual(licence, [
            ('licence-check-dependencies', runner.LICENCE_INSTALL),
            ('licence-check-packages', (runner.sys.executable, runner.LICENCE_CHECK, '--execute')),
        ])

    def test_failed_licence_dependencies_fail_aggregate_without_qualifying_uninstalled_packages(self):
        with patch.object(runner.sys, 'argv', ['check.py', '--platform', 'all']), \
                patch.object(runner, 'input_hashes', return_value={}), \
                patch.object(runner, 'run', side_effect=lambda label, *_: label != 'licence-check-dependencies') as execute:
            self.assertEqual(runner.main(), 1)
        labels = [call.args[0] for call in execute.call_args_list]
        self.assertIn('licence-check-dependencies', labels)
        self.assertNotIn('licence-check-packages', labels)

    def test_source_guard_mode_keeps_licence_execution_and_installation_separate(self):
        with patch.object(runner.sys, 'argv', ['check.py', '--platform', 'guards']), \
                patch.object(runner, 'input_hashes', return_value={}), \
                patch.object(runner, 'run', return_value=True) as execute:
            self.assertEqual(runner.main(), 0)
        labels = [call.args[0] for call in execute.call_args_list]
        self.assertIn('all-guards-licence-check-boundaries', labels)
        self.assertNotIn('licence-check-dependencies', labels)
        self.assertNotIn('licence-check-packages', labels)

    def test_nist_refuses_compiler_and_docker_option_injection(self):
        with patch.object(nist.subprocess, 'check_output') as execute:
            for compiler, image in [('sh', None), ('clang++', '--privileged'),
                                    ('clang++', 'unreviewed-image:latest')]:
                with self.subTest(compiler=compiler, image=image), self.assertRaises(ValueError):
                    nist.check(compiler, ROOT/'.build/nist-security-test', image)
            execute.assert_not_called()

    def test_nist_build_directory_is_confined_and_has_no_symlink_components(self):
        for path in [ROOT/'.build', ROOT/'biometric', ROOT/'.build/../../outside', ROOT/'.build/out,readonly=false', ROOT/'.build/out\nargument']:
            with self.subTest(path=path), self.assertRaises(ValueError):
                nist.validated_options('clang++', path, None)
        (ROOT/'.build').mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=ROOT/'.build') as local, tempfile.TemporaryDirectory() as outside:
            link = Path(local)/'redirect'
            link.symlink_to(outside, target_is_directory=True)
            with self.assertRaises(ValueError):
                nist.validated_options('clang++', link/'build', None)
            compiler, output, image = nist.validated_options('g++-13', Path(local)/'safe', 'kenshiki-face-frte-dev:20261016')
            self.assertEqual(compiler, 'g++-13')
            self.assertEqual(output, Path(local)/'safe')
            self.assertEqual(image, 'kenshiki-face-frte-dev:20261016')

    def test_architecture_report_cannot_overwrite_sources_or_escape_repository(self):
        for path in [ROOT/'AGENTS.md', ROOT/'governance/architecture/other.json',
                     ROOT/'.build/validation/../outside.json', Path('/tmp/report.json'), ROOT/'.build/validation/unreviewed.json']:
            with self.subTest(path=path), self.assertRaises(argparse.ArgumentTypeError):
                architecture.report_destination(path)
        self.assertEqual(architecture.report_destination(ROOT/'governance/architecture/validation-results.json'),
                         ROOT/'governance/architecture/validation-results.json')
        self.assertEqual(architecture.report_destination(ROOT/'.build/validation/architecture.json'),
                         ROOT/'.build/validation/architecture.json')

    def test_report_write_refuses_symlink_substitution_and_preserves_target(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = Path(folder).resolve()
            target = folder/'original'
            target.write_text('preserve')
            link = folder/'report.json'
            link.symlink_to(target)
            with patch.object(architecture, 'REPORT_DESTINATIONS', {str(link): link}):
                with self.assertRaises(OSError):
                    architecture.write_report(link, {'passed': True})
            self.assertEqual(target.read_text(), 'preserve')
            report = folder/'regular.json'
            with self.assertRaises(ValueError):
                architecture.write_report(report, {'passed': True})
            self.assertFalse(report.exists())
            with patch.object(architecture, 'REPORT_DESTINATIONS', {str(report): report}):
                architecture.write_report(report, {'passed': True})
            self.assertIn('"passed": true', report.read_text())


if __name__ == '__main__':
    unittest.main()
