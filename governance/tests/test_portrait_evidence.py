"""Native evidence must prove required tests executed, including adversarial lifecycle cases."""
from pathlib import Path
import tempfile
import unittest
import xml.etree.ElementTree as ET

from quality import portrait_evidence as evidence


class PortraitEvidenceTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def report(self, required, filename='TEST-native.xml'):
        suite = ET.Element('testsuite', tests=str(len(required)), failures='0', errors='0', skipped='0')
        for identifier in sorted(required):
            classname, name = identifier.rsplit('.', 1)
            ET.SubElement(suite, 'testcase', classname=classname, name=name)
        path = self.root / filename
        self.save(suite, path)
        return suite, path

    @staticmethod
    def save(suite, path):
        ET.ElementTree(suite).write(path, encoding='utf-8', xml_declaration=True)

    def test_required_swift_and_android_identities_pass(self):
        for platform, required in evidence.REQUIRED.items():
            _, path = self.report(required)
            self.assertEqual(evidence.check(platform, path), len(required))
        self.assertEqual(len(evidence.SWIFT_REQUIRED), 33)
        self.assertEqual(len(evidence.QUALITY_SWIFT_REQUIRED), 10)
        self.assertFalse(evidence.SWIFT_REQUIRED & evidence.QUALITY_SWIFT_REQUIRED)
        self.assertEqual(len(evidence.ANDROID_REQUIRED), 13)

    def test_core_and_optional_quality_require_their_separate_actual_reports(self):
        _, core = self.report(evidence.SWIFT_REQUIRED, 'TEST-core.xml')
        _, quality = self.report(evidence.QUALITY_SWIFT_REQUIRED, 'TEST-quality.xml')
        self.assertEqual(evidence.check('swift', core), 33)
        self.assertEqual(evidence.check('quality-swift', quality), 10)
        with self.assertRaisesRegex(ValueError, 'Missing required'):
            evidence.check('quality-swift', core)
        with self.assertRaisesRegex(ValueError, 'Missing required'):
            evidence.check('swift', quality)

    def test_retired_visual_validation_is_required_in_app_receipts(self):
        from scripts.presentation_check import REQUIRED_TESTS
        archived = {
            'testHistoricalTasksAndDescriptorsDecodeWithoutV4Fields',
            'testMetricsRemainOptionalForHistoryAndSurviveFailedGeneration',
            'testMetricAllocatorScopeDefaultsForLegacyAndRejectsUnknownScope',
            'testPureDescriptorValidationRejectsRehashedEvidenceSubstitution',
            'testStrictJSONRejectsEscapedDuplicateKeysAndInvalidNumbers',
            'testCaptureBindingsAndNonfiniteMeasurementsAreRejected',
            'testAuraContextChecksSourceAndRejectsBidiControls',
            'testMotionBindingRejectsAWindowFromAnotherFrame',
            'testMotionRejectsStaleReversedNonfiniteAndInconsistentWindows',
        }
        self.assertFalse(any(name.startswith('VisualAssessmentTests.') for name in evidence.SWIFT_REQUIRED))
        self.assertTrue({'LiquidRetirementTests.' + name for name in archived}.issubset(REQUIRED_TESTS['ios-ui']))

    def test_each_missing_required_identity_fails_even_with_green_summary(self):
        for required in evidence.REQUIRED.values():
            for missing in required:
                with self.subTest(missing=missing):
                    _, path = self.report(required - {missing})
                    with self.assertRaisesRegex(ValueError, 'Missing required'):
                        evidence.check_reports([path], required)

    def test_skipped_failed_error_or_disabled_cases_and_suite_summaries_fail(self):
        required = {'NativeTests.required'}
        for tag in ('skipped', 'failure', 'error'):
            for target in ('testcase', 'testsuite'):
                with self.subTest(tag=tag, target=target):
                    suite, path = self.report(required)
                    ET.SubElement(suite.find('testcase') if target == 'testcase' else suite, tag)
                    self.save(suite, path)
                    with self.assertRaises(ValueError):
                        evidence.check_reports([path], required)
        for attribute in ('skipped', 'failures', 'errors', 'disabled'):
            for value in ('1', '-1', 'NaN', '', 'true'):
                with self.subTest(attribute=attribute, value=value):
                    suite, path = self.report(required)
                    suite.set(attribute, value)
                    self.save(suite, path)
                    with self.assertRaises(ValueError):
                        evidence.check_reports([path], required)

    def test_duplicate_test_identity_fails_within_or_across_reports(self):
        required = {'NativeTests.required'}
        suite, path = self.report(required)
        ET.SubElement(suite, 'testcase', classname='NativeTests', name='required')
        suite.set('tests', '2')
        self.save(suite, path)
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            evidence.check_reports([path], required)
        _, first = self.report(required)
        _, second = self.report(required, 'TEST-second.xml')
        with self.assertRaisesRegex(ValueError, 'Duplicate'):
            evidence.check_reports([first, second], required)

    def test_empty_malformed_external_entity_symlink_and_wrong_counts_fail(self):
        path = self.root / 'TEST-native.xml'
        for payload in ('', '<testsuite>', '<other/>', '<!DOCTYPE x><testsuite/>',
                        '<testsuite><testcase classname="NativeTests" name="required"><x:failure xmlns:x="urn:hidden"/></testcase></testsuite>',
                        '<testsuite tests="2"><testcase classname="NativeTests" name="required"/></testsuite>'):
            with self.subTest(payload=payload):
                path.write_text(payload)
                with self.assertRaises(ValueError):
                    evidence.check_reports([path], {'NativeTests.required'})
        _, path = self.report({'NativeTests.required'})
        link = self.root / 'TEST-link.xml'
        link.symlink_to(path)
        with self.assertRaises(ValueError):
            evidence.check_reports([link], {'NativeTests.required'})
        with self.assertRaises(ValueError):
            evidence.check_reports([], {'NativeTests.required'})

    def test_cases_hidden_under_metadata_or_output_are_not_executed(self):
        required = {'NativeTests.required'}
        for wrapper in ('properties', 'property', 'system-out', 'system-err', 'testcase', 'error'):
            with self.subTest(wrapper=wrapper):
                suite = ET.Element('testsuite', tests='1')
                container = ET.SubElement(suite, wrapper)
                ET.SubElement(container, 'testcase', classname='NativeTests', name='required')
                path = self.root / 'TEST-hidden.xml'
                self.save(suite, path)
                with self.assertRaises(ValueError):
                    evidence.check_reports([path], required)

    def test_nested_tags_in_leaf_elements_fail_closed(self):
        required = {'NativeTests.required'}
        for leaf in ('property', 'system-out', 'system-err', 'error', 'failure', 'skipped'):
            for nested in ('error', 'properties', 'testsuite'):
                with self.subTest(leaf=leaf, nested=nested):
                    suite, path = self.report(required)
                    parent = ET.SubElement(suite, 'properties') if leaf == 'property' else suite.find('testcase')
                    container = ET.SubElement(parent, leaf)
                    ET.SubElement(container, nested)
                    self.save(suite, path)
                    with self.assertRaises(ValueError):
                        evidence.check_reports([path], required)

    def test_only_suite_children_can_supply_case_evidence(self):
        required = {'NativeTests.required'}
        root = ET.Element('testsuites')
        ET.SubElement(root, 'testcase', classname='NativeTests', name='required')
        path = self.root / 'TEST-invalid-root-child.xml'
        self.save(root, path)
        with self.assertRaisesRegex(ValueError, 'hierarchy'):
            evidence.check_reports([path], required)
        root = ET.Element('testsuites', tests='1')
        group = ET.SubElement(root, 'testsuites', tests='1')
        suite = ET.SubElement(group, 'testsuite', tests='1')
        nested = ET.SubElement(suite, 'testsuite', tests='1')
        ET.SubElement(nested, 'testcase', classname='NativeTests', name='required')
        self.save(root, path)
        self.assertEqual(evidence.check_reports([path], required), 1)

    def test_nested_summary_error_and_unexecuted_status_fail(self):
        suite, path = self.report({'NativeTests.required'})
        root = ET.Element('testsuites', errors='1')
        root.append(suite)
        self.save(root, path)
        with self.assertRaises(ValueError):
            evidence.check_reports([path], {'NativeTests.required'})
        for attribute, value in (('status', 'notrun'), ('result', 'suppressed')):
            suite, path = self.report({'NativeTests.required'})
            suite.find('testcase').set(attribute, value)
            self.save(suite, path)
            with self.assertRaises(ValueError):
                evidence.check_reports([path], {'NativeTests.required'})
