"""Adversarial evidence tests for mandatory native presentation execution."""
import contextlib
import importlib.util
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('presentation_runner_evidence', ROOT/'scripts/presentation_check.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class PresentationRunnerTests(unittest.TestCase):
    @contextlib.contextmanager
    def evidence(self):
        with tempfile.TemporaryDirectory(prefix='kenshiki-runner-evidence-') as folder:
            root = Path(folder)
            with patch.object(runner, 'ROOT', root), patch.object(runner, 'OUTPUT', root/'.build/presentation'):
                runner.OUTPUT.mkdir(parents=True)
                yield root

    def xml(self, lane='macos', names=None, tag=None):
        names = runner.REQUIRED_TESTS[lane] if names is None else names
        if lane == 'macos':
            for filename, required in runner.MACOS_REPORTS.items():
                selected = names & required
                if filename == runner.SWIFT_REPORT:
                    selected |= names - runner.REQUIRED_TESTS[lane]
                self.xml_report(runner.OUTPUT/filename, selected, tag)
            return runner.OUTPUT/runner.SWIFT_REPORT
        path = runner.ROOT/'reference-apps/android/app/build/test-results/testDebugUnitTest/TEST-WorkflowTest.xml'
        self.xml_report(path, names, tag)
        return path

    def xml_report(self, path, names, tag=None):
        suite = ET.Element('testsuite')
        for name in names:
            klass, method = name.rsplit('.', 1)
            case = ET.SubElement(suite, 'testcase', classname='module.'+klass, name=method)
            if tag:
                ET.SubElement(case, tag)
        path.parent.mkdir(parents=True, exist_ok=True)
        ET.ElementTree(suite).write(path)

    def ui_payloads(self, skipped=0, omit=False):
        names = runner.REQUIRED_TESTS['ios-ui']
        summary = {'result': 'Passed', 'totalTestCount': len(names), 'passedTests': len(names),
                   'failedTests': 0, 'skippedTests': skipped, 'expectedFailures': 0, 'startTime': time.time()}
        nodes = [{'nodeType': 'Test Case', 'nodeIdentifier': 'Bundle/'+name.replace('.', '/')+'()',
                  'result': 'Passed'} for name in names]
        if omit:
            nodes.pop()
        return [json.dumps(summary), json.dumps({'testNodes': [{'nodeType': 'UI test bundle', 'children': nodes}]})]

    def test_exact_required_controller_ids_execute_on_both_platforms(self):
        with self.evidence():
            for lane in ('macos', 'android'):
                self.xml(lane)
                result = runner.test_counts(lane, 0)
                self.assertEqual(result['executed'], 9)
                self.assertEqual(set(result['ids']), runner.REQUIRED_TESTS[lane])

    def test_unrelated_empty_and_missing_vector_execution_fail(self):
        for names in (set(), {'Unrelated.testNothing'}, runner.REQUIRED_TESTS['macos'] -
                      {'WorkflowTests.testSharedPositiveAndNegativeVectors'}):
            with self.subTest(names=names), self.evidence():
                self.xml(names=names)
                with self.assertRaises(ValueError):
                    runner.test_counts('macos', 0)

    def test_skipped_failed_or_error_controller_case_fails(self):
        for tag in ('skipped', 'failure', 'error'):
            with self.subTest(tag=tag), self.evidence():
                self.xml(tag=tag)
                with self.assertRaises(ValueError):
                    runner.test_counts('macos', 0)

    def test_missing_stale_or_empty_controller_report_fails(self):
        with self.evidence():
            with self.assertRaises(ValueError):
                runner.test_counts('macos', 0)
            report = self.xml()
            os.utime(report, ns=(1, 1))
            started_ns = time.time_ns()
            with self.assertRaises(ValueError):
                runner.test_counts('macos', started_ns)
            report.write_text('')
            with self.assertRaises(ValueError):
                runner.test_counts('macos', 0)

    def test_known_report_cleanup_cannot_reuse_old_results_or_remove_another_lane(self):
        with self.evidence():
            report = self.xml()
            other = runner.OUTPUT/'android.json'
            other.write_text('preserve')
            runner.prepare_outputs('macos')
            self.assertFalse(report.exists())
            self.assertFalse((runner.OUTPUT/runner.DESIGN_REPORT).exists())
            self.assertEqual(other.read_text(), 'preserve')
            with self.assertRaises(ValueError):
                runner.test_counts('macos', 0)

    def test_symlink_report_or_ancestor_cannot_read_or_delete_outside_evidence(self):
        for ancestor in (False, True):
            with self.subTest(ancestor=ancestor), self.evidence() as root:
                outside = root/'outside'
                outside.mkdir()
                external = outside/'swift-tests.xml'
                external.write_text('preserve')
                if ancestor:
                    runner.OUTPUT.rmdir()
                    runner.OUTPUT.symlink_to(outside, target_is_directory=True)
                else:
                    (runner.OUTPUT/'swift-tests.xml').symlink_to(external)
                with self.assertRaises(ValueError):
                    runner.test_counts('macos', 0)
                with self.assertRaises(ValueError):
                    runner.prepare_outputs('macos')
                self.assertEqual(external.read_text(), 'preserve')

    def test_ui_counts_require_fresh_bundle_summary_and_all_required_case_ids(self):
        with self.evidence():
            bundle = runner.OUTPUT/'ios-ui.xcresult'
            with self.assertRaises(ValueError):
                runner.test_counts('ios-ui', 0)
            bundle.mkdir()
            with patch.object(runner.subprocess, 'check_output', side_effect=self.ui_payloads()):
                self.assertEqual(runner.test_counts('ios-ui', 0)['executed'], len(runner.REQUIRED_TESTS['ios-ui']))
            for kwargs in ({'skipped': 1}, {'omit': True}):
                with patch.object(runner.subprocess, 'check_output', side_effect=self.ui_payloads(**kwargs)):
                    with self.assertRaises(ValueError):
                        runner.test_counts('ios-ui', 0)
            os.utime(bundle, ns=(1, 1))
            started_ns = time.time_ns()
            with self.assertRaises(ValueError):
                runner.test_counts('ios-ui', started_ns)

    def test_artifacts_are_scoped_to_current_lane_fresh_and_nonempty(self):
        with self.evidence():
            apk = runner.ROOT/'reference-apps/android/app/build/outputs/apk/debug/app-debug.apk'
            apk.parent.mkdir(parents=True)
            apk.write_bytes(b'android-artifact')
            release, mapping = runner.artifact_paths('android')[1:]
            release.parent.mkdir(parents=True)
            release.write_bytes(b'android-release-artifact')
            mapping.parent.mkdir(parents=True)
            mapping.write_text('# compiler: R8\nexample.Controller -> a.b:\n')
            executable = runner.OUTPUT/'ios-device/Build/Products/Debug-iphoneos/KenshikiReference.app/KenshikiReference'
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'ios-device-artifact')
            self.assertEqual(runner.collect_artifacts('macos', 0), {})
            self.assertEqual(set(runner.collect_artifacts('android', 0)),
                             {path.relative_to(runner.ROOT).as_posix() for path in runner.artifact_paths('android')})
            self.assertEqual(set(runner.collect_artifacts('ios-device', 0)), {executable.relative_to(runner.ROOT).as_posix()})
            for path in (apk, executable):
                os.utime(path, ns=(1, 1))
            started_ns = time.time_ns()
            for lane in ('android', 'ios-device', 'ios-simulator'):
                with self.assertRaises(ValueError):
                    runner.collect_artifacts(lane, started_ns)
            apk.write_bytes(b'')
            with self.assertRaises(ValueError):
                runner.collect_artifacts('android', 0)
            apk.unlink()
            (apk.parent/'unrelated.apk').write_bytes(b'unrelated')
            with self.assertRaises(ValueError):
                runner.collect_artifacts('android', 0)

    def test_source_change_during_successful_commands_fails_receipt(self):
        with self.evidence(), patch.object(runner, 'execute_stages', return_value=True), \
                patch.object(runner, 'input_hashes', side_effect=[{'source': 'before'}, {'source': 'after'}]), \
                patch.object(runner.subprocess, 'check_output', return_value='revision'), \
                patch.object(runner.platform, 'platform', return_value='test-host'), patch('builtins.print'):
            self.assertFalse(runner.run('guards'))
            receipt = json.loads((runner.OUTPUT/'guards.json').read_text())
            self.assertFalse(receipt['passed'])
            self.assertEqual(receipt['artifactSHA256'], {})
            self.assertIn('Source inputs changed', receipt['error'])

    def test_ios_bundle_resources_are_bound_and_symlink_content_rejected(self):
        with self.evidence():
            executable = runner.artifact_paths('ios-device')[0]
            executable.parent.mkdir(parents=True)
            executable.write_bytes(b'ios-binary')
            resource = executable.parent/'Resources.bundle/en.lproj/Localizable.strings'
            resource.parent.mkdir(parents=True)
            resource.write_bytes(b'first-catalog')
            before = runner.collect_artifacts('ios-device', 0)
            resource.write_bytes(b'changed-catalog')
            after = runner.collect_artifacts('ios-device', 0)
            relative = resource.relative_to(runner.ROOT).as_posix()
            self.assertNotEqual(before[relative], after[relative])
            self.assertEqual(set(before), set(after))
            resource.unlink()
            resource.symlink_to(executable)
            with self.assertRaises(ValueError):
                runner.collect_artifacts('ios-device', 0)

    def test_failed_command_cannot_certify_artifacts(self):
        with self.evidence(), patch.object(runner, 'execute_stages', return_value=False), \
                patch.object(runner, 'input_hashes', return_value={'source': 'stable'}), \
                patch.object(runner.subprocess, 'check_output', return_value='revision'), \
                patch.object(runner.platform, 'platform', return_value='test-host'), patch('builtins.print'):
            self.assertFalse(runner.run('macos'))
            receipt = json.loads((runner.OUTPUT/'macos.json').read_text())
            self.assertFalse(receipt['passed'])
            self.assertEqual(receipt['artifactSHA256'], {})

    def test_unregistered_lane_rejected_before_execution(self):
        with self.assertRaises(ValueError):
            runner.commands('../../outside')
        with self.assertRaises(ValueError):
            runner.run('../../outside')

    def test_untrusted_receipt_values_do_not_control_the_output_path(self):
        payload = '../../outside/receipt.json\n"} malicious receipt value'
        with self.evidence() as root, patch.object(runner, 'execute_stages', return_value=True), \
                patch.object(runner, 'input_hashes', return_value={payload: payload}), \
                patch.object(runner.subprocess, 'check_output', return_value=payload), \
                patch.object(runner.platform, 'platform', return_value=payload), patch('builtins.print'):
            self.assertTrue(runner.run('guards'))
            receipt = json.loads((runner.OUTPUT/'guards.json').read_text())
            self.assertEqual(receipt['gitStatus'], payload)
            self.assertEqual(receipt['sourceSHA256'], {payload: payload})
            self.assertFalse((root/'outside').exists())
            self.assertEqual({path.name for path in runner.OUTPUT.iterdir()}, {'guards.json'})

    def test_android_requires_release_build_and_real_obfuscation_mapping(self):
        command = next(stage for stage in runner.commands('android') if 'assembleDebug' in stage)
        self.assertEqual(command[:2], ['bash', 'reference-apps/android/gradlew'])
        self.assertIn('assembleRelease', command)
        self.assertIn('lintRelease', command)
        with self.evidence():
            mapping = runner.OUTPUT/'mapping.txt'
            for source in ('', '# compiler: R8\nexample.Controller -> example.Controller:\n',
                           'example.Controller -> a.b:\n'):
                with self.subTest(source=source):
                    mapping.write_text(source)
                    with self.assertRaises(ValueError):
                        runner.validate_release_mapping(mapping)

    def test_android_api_cannot_reuse_old_kotlin_plugin_output(self):
        spec = importlib.util.spec_from_file_location('reference_api', ROOT/'scripts/presentation_api.py')
        api = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(api)
        with self.evidence() as root, patch.object(api, 'ROOT', root):
            old = root/'reference-apps/android/app/build/tmp/kotlin-classes/debug/com/kenshiki/presentation/WorkflowController.class'
            old.parent.mkdir(parents=True)
            old.write_bytes(b'stale compiler output')
            with self.assertRaisesRegex(ValueError, 'Missing built-in Kotlin'):
                api.surface('android')

    def test_design_tests_cannot_be_missing_stale_skipped_or_in_another_packages_report(self):
        for mutation in ('missing', 'stale', 'skipped', 'wrong-package'):
            with self.subTest(mutation=mutation), self.evidence():
                self.xml()
                report = runner.OUTPUT/runner.DESIGN_REPORT
                started_ns = 0
                if mutation == 'missing':
                    report.unlink()
                elif mutation == 'stale':
                    os.utime(report, ns=(1, 1))
                    started_ns = time.time_ns()
                    workflow = runner.OUTPUT/runner.SWIFT_REPORT
                    os.utime(workflow, ns=(started_ns, started_ns))
                elif mutation == 'skipped':
                    self.xml_report(report, runner.MACOS_REPORTS[runner.DESIGN_REPORT], 'skipped')
                else:
                    self.xml_report(runner.OUTPUT/runner.SWIFT_REPORT, runner.REQUIRED_TESTS['macos'])
                    self.xml_report(report, {'Unrelated.testNothing'})
                with self.assertRaises(ValueError):
                    runner.test_counts('macos', started_ns)

    def test_macos_requires_both_native_package_test_commands(self):
        stages = runner.commands('macos')
        for package, filename in (('presentation', runner.SWIFT_REPORT), ('design-system', runner.DESIGN_REPORT)):
            stage = next(command for command in stages if command[:4] == ['swift', 'test', '--package-path', package])
            self.assertIn('--parallel', stage)
            self.assertIn('--disable-swift-testing', stage)
            self.assertIn('-warnings-as-errors', stage)
            self.assertEqual(stage[-1], str(runner.OUTPUT/filename))

    def test_ui_command_requires_explicit_result_bundle(self):
        with patch.object(runner, 'simulator_destination', return_value='platform=iOS Simulator,id=fixed'):
            command = runner.commands('ios-ui')[-1]
        self.assertIn('-resultBundlePath', command)
        self.assertEqual(command[command.index('-collect-test-diagnostics')+1], 'never')
        self.assertEqual(command[-1], 'test')

    def test_failed_or_incomplete_evidence_is_archived_before_replacement(self):
        with self.evidence():
            self.xml()
            log = runner.OUTPUT/'macos.log'
            log.write_text('failed attempt log')
            receipt = runner.OUTPUT/'macos.json'
            receipt.write_text('{"passed":false}')
            other = runner.OUTPUT/'android.log'
            other.write_text('other lane')
            runner.prepare_outputs('macos')
            archives = list((runner.OUTPUT/'history').iterdir())
            self.assertEqual(len(archives), 1)
            archived = archives[0]
            self.assertIn('-macos-', archived.name)
            self.assertEqual((archived/log.name).read_text(), 'failed attempt log')
            self.assertEqual((archived/receipt.name).read_text(), '{"passed":false}')
            self.assertTrue((archived/runner.SWIFT_REPORT).is_file())
            self.assertTrue((archived/runner.DESIGN_REPORT).is_file())
            self.assertEqual(other.read_text(), 'other lane')
            self.assertFalse(log.exists())
            log.write_text('interrupted without receipt')
            runner.prepare_outputs('macos')
            self.assertEqual(len(list((runner.OUTPUT/'history').iterdir())), 2)

    def test_ui_result_bundle_is_moved_to_history_without_derived_builds(self):
        with self.evidence():
            bundle = runner.OUTPUT/runner.UI_RESULT
            bundle.mkdir()
            attachment = bundle/'Data/screenshot'
            attachment.parent.mkdir()
            attachment.write_bytes(b'prior-ui-evidence')
            unrelated = runner.OUTPUT/'ios-device'
            unrelated.mkdir()
            (unrelated/'preserve').write_text('another build')
            archived = runner.archive_previous('ios-ui')
            self.assertEqual((archived/runner.UI_RESULT/'Data/screenshot').read_bytes(), b'prior-ui-evidence')
            self.assertFalse(bundle.exists())
            self.assertEqual((unrelated/'preserve').read_text(), 'another build')

    def test_archive_rejects_symlink_history_and_nested_result_without_moving_evidence(self):
        for location in ('history', 'nested-result'):
            with self.subTest(location=location), self.evidence() as root:
                outside = root/'outside'
                outside.mkdir()
                log = runner.OUTPUT/'ios-ui.log'
                log.write_text('preserve prior log')
                if location == 'history':
                    (runner.OUTPUT/'history').symlink_to(outside, target_is_directory=True)
                else:
                    bundle = runner.OUTPUT/runner.UI_RESULT
                    bundle.mkdir()
                    (bundle/'escape').symlink_to(outside, target_is_directory=True)
                with self.assertRaises(ValueError):
                    runner.archive_previous('ios-ui')
                self.assertEqual(log.read_text(), 'preserve prior log')
                self.assertEqual(list(outside.iterdir()), [])


if __name__ == '__main__':
    unittest.main()
