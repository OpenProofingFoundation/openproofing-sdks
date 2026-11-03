"""Real source/schema/output mutations exercise the design compiler boundary."""
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location('kenshiki_design_generator', ROOT / 'generate.py')
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)


class DesignCompilerTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name) / 'design-system'
        shutil.copytree(ROOT, self.root, ignore=shutil.ignore_patterns('__pycache__', '.build'))

    def mutate(self, name, mutation):
        path = self.root / 'sources' / f'{name}.jsonc'
        value = GENERATOR.parse_jsonc(path.read_text())
        mutation(value)
        path.write_text(json.dumps(value))

    def assert_rejected(self):
        with self.assertRaises(ValueError):
            GENERATOR.outputs(self.root)

    def test_committed_output_matches_and_generation_is_deterministic(self):
        GENERATOR.generate(check=True)
        first = GENERATOR.generate(root=self.root)
        second = GENERATOR.generate(root=self.root)
        self.assertEqual(first, second)
        GENERATOR.generate(check=True, root=self.root)

    def test_jsonc_preserves_comment_like_content_and_escaped_quotes(self):
        value = GENERATOR.parse_jsonc(r'''{
          // outside a string
          "url": "https://example.invalid/a/*b*/,", /* a comment */
          "quote": "escaped \" // still text",
          "list": ["one,]",],
        }''')
        self.assertEqual(value['url'], 'https://example.invalid/a/*b*/,')
        self.assertEqual(value['quote'], 'escaped " // still text')
        self.assertEqual(value['list'], ['one,]'])

    def test_multiline_adjacent_and_eof_comments_preserve_source_positions(self):
        source = '{/* first\r\nsecond */"a":/* adjacent *//* comment */[1,],} // eof'
        stripped = GENERATOR._without_comments(source)
        self.assertEqual(len(source), len(stripped))
        self.assertEqual([index for index, char in enumerate(source) if char == '\n'],
                         [index for index, char in enumerate(stripped) if char == '\n'])
        self.assertEqual(GENERATOR.parse_jsonc(source), {'a': [1]})

    def test_comment_does_not_join_invalid_json_number_tokens(self):
        for source in ('{"a": 1/* comment */2}', '{"a": "unterminated // text}'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                GENERATOR.parse_jsonc(source)

    def test_duplicate_keys_rejected_after_comments(self):
        with self.assertRaisesRegex(ValueError, 'Duplicate key'):
            GENERATOR.parse_jsonc('{"a": 1, /* second */ "a": 2}')

    def test_unterminated_comment_and_nonfinite_numbers_rejected(self):
        for source in ('{"a": 1 /*', '{"a": NaN}', '{"a": Infinity}'):
            with self.subTest(source=source), self.assertRaises(ValueError):
                GENERATOR.parse_jsonc(source)

    def test_unknown_token_and_unknown_catalog_key_rejected(self):
        self.mutate('tokens', lambda value: value.update({'biometricThreshold': .5}))
        self.assert_rejected()
        self.mutate('catalog', lambda value: value['messages'].update({'unregistered': {'text': 'unreviewed'}}))
        self.assert_rejected()

    def test_missing_accessibility_and_permission_messages_rejected(self):
        for key in ('accessibility.workflowStatus', 'permission.camera', 'permission.nfc', 'permission.motion'):
            with self.subTest(key=key):
                value = GENERATOR.parse_jsonc((ROOT / 'sources/catalog.jsonc').read_text())
                del value['messages'][key]
                schema = json.loads((ROOT / 'schemas/catalog.schema.json').read_text())
                with self.assertRaises(ValueError):
                    GENERATOR.validate(value, schema)

    def test_incorrect_units_and_touch_target_reduction_rejected(self):
        self.mutate('tokens', lambda value: value['spacing'].update({'page': '24px'}))
        self.assert_rejected()
        self.mutate('tokens', lambda value: value['dimensions'].update({'minimumTargetIOS': 43}))
        self.assert_rejected()

    def test_overlay_cannot_bypass_schema_or_minima(self):
        # Host overlays are not supported in this release. An overlay supplied as
        # an extra source property must fail closed rather than merge silently.
        self.mutate('tokens', lambda value: value.update({'overlay': {'minimumTargetIOS': 1}}))
        self.assert_rejected()

    def test_invalid_color_and_low_contrast_both_appearances_rejected(self):
        for palette in ('colors', 'darkColors'):
            value, catalog = GENERATOR.load_sources()
            value = copy.deepcopy(value)
            value[palette]['text'] = value[palette]['surface']
            with self.subTest(palette=palette), self.assertRaisesRegex(ValueError, 'contrast'):
                GENERATOR.validate_semantics(value, catalog)
        self.mutate('tokens', lambda value: value['colors'].update({'text': 'red'}))
        self.assert_rejected()

    def test_unresolved_token_and_incomplete_component_variants_rejected(self):
        self.mutate('tokens', lambda value: value['components']['button'].update({'foreground': 'missing'}))
        self.assert_rejected()
        self.mutate('tokens', lambda value: value['components']['card'].update({'variants': []}))
        self.assert_rejected()

    def test_unsupported_platform_mapping_and_disabled_scaling_rejected(self):
        self.mutate('tokens', lambda value: value['platforms']['ios'].update({'textScaling': 'fixed'}))
        self.assert_rejected()
        self.mutate('tokens', lambda value: value['typography']['title'].update({'scales': False}))
        self.assert_rejected()

    def test_native_primitive_mappings_reject_visual_and_material_substitutions(self):
        original, _ = GENERATOR.load_sources()
        schema = json.loads((ROOT / 'schemas/tokens.schema.json').read_text())
        mutations = (
            lambda value: value['platformPrimitives']['ios']['colors'].update({'text': '#000000'}),
            lambda value: value['platformPrimitives']['ios']['material'].update({'scope': 'allContent'}),
            lambda value: value['platformPrimitives']['ios']['buttons']['primary'].update({'fallback': 'prominentGlass'}),
            lambda value: value['platformPrimitives']['android']['theme'].update({'parent': 'android:Theme.Material.Light'}),
            lambda value: value['platformPrimitives']['android']['typography'].update({'bodyTextStyle': '16sp'}),
            lambda value: value['platformPrimitives']['android']['colors'].update({'colorSurface': '#FFFFFF'}),
        )
        for mutation in mutations:
            value = copy.deepcopy(original)
            mutation(value)
            with self.subTest(value=value['platformPrimitives']), self.assertRaises(ValueError):
                GENERATOR.validate(value, schema)

    def test_required_platform_instruction_copy_cannot_be_omitted(self):
        _, original = GENERATOR.load_sources()
        schema = json.loads((ROOT / 'schemas/catalog.schema.json').read_text())
        keys = ('navigation.title', 'capability.biometric.intro', 'capability.document.summary',
                'capability.passport.intro', 'navigation.tab.biometric', 'progress.step1',
                'developer.menu')
        for key in keys:
            value = copy.deepcopy(original)
            del value['messages'][key]
            with self.subTest(key=key), self.assertRaises(ValueError):
                GENERATOR.validate(value, schema)

    def test_unknown_schema_keywords_and_bad_schema_refs_rejected(self):
        for schema in ({'unsupported': True}, {'$ref': '#/$defs/missing'}, {'$ref': '#/$defs/a', '$defs': {'a': {'$ref': '#/$defs/a'}}}):
            with self.subTest(schema=schema), self.assertRaises(ValueError):
                GENERATOR.validate({}, schema)
        with self.assertRaisesRegex(ValueError, 'cyclic'):
            GENERATOR.validate({}, {'$ref': '#/$defs/a'}, root_schema={'$defs': {'a': {'$ref': '#/$defs/a'}}})

    def test_catalog_interpolation_and_unreleased_locale_rejected(self):
        self.mutate('catalog', lambda value: value['messages']['app.title'].update({'text': 'Hello {name}'}))
        self.assert_rejected()
        self.mutate('catalog', lambda value: value.update({'supportedLocales': ['en', 'fr']}))
        self.assert_rejected()

    def test_pseudolocales_expand_and_include_direction_and_nonlatin_content(self):
        _, catalog = GENERATOR.load_sources()
        for message in catalog['messages'].values():
            original = message['text']
            self.assertGreaterEqual(len(GENERATOR.pseudo(original)), len(original) * 1.3)
            rtl = GENERATOR.pseudo(original, rtl=True)
            self.assertTrue(rtl.startswith('\u2067['))
            self.assertTrue(rtl.endswith(']\u2069'))
            self.assertIn('العربية', rtl)
        # Exact protocol-like identifiers retain their order inside RTL isolates.
        self.assertIn('ABC-123', GENERATOR.pseudo('ABC-123', rtl=True))

    def test_native_catalogs_have_complete_matching_resource_inventory(self):
        result = GENERATOR.outputs()
        _, catalog = GENERATOR.load_sources()
        expected = {GENERATOR.android_name(key) for key in catalog['messages']}
        for name, contents in result.items():
            if name.endswith('strings.xml'):
                resource = ET.fromstring(contents)
                self.assertEqual({child.attrib['name'] for child in resource}, expected)
            if name.endswith('InfoPlist.strings'):
                self.assertIn('CFBundleDisplayName', contents)
                self.assertIn('NSCameraUsageDescription', contents)
                self.assertIn('NFCReaderUsageDescription', contents)
                self.assertIn('NSMotionUsageDescription', contents)
        self.assertEqual(catalog['fallbacks'], {'en': ['en']})

    def test_generator_schema_source_and_output_tampering_changes_or_rejects_digest(self):
        original = GENERATOR.source_identity(self.root)
        for relative in ('generate.py', 'schemas/tokens.schema.json', 'sources/tokens.jsonc'):
            path = self.root / relative
            path.write_text(path.read_text() + '\n')
            self.assertNotEqual(original, GENERATOR.source_identity(self.root))
            original = GENERATOR.source_identity(self.root)
        GENERATOR.generate(root=self.root)
        path = self.root / 'generated/swift/KenshikiDesign.swift'
        path.write_text(path.read_text() + '// unmanaged edit\n')
        with self.assertRaisesRegex(ValueError, 'drift'):
            GENERATOR.generate(check=True, root=self.root)

    def test_unregistered_and_symlink_sources_rejected(self):
        path = self.root / 'sources/extra.jsonc'
        path.write_text('{}')
        self.assert_rejected()
        path.unlink()
        path = self.root / 'sources/tokens.jsonc'
        path.unlink()
        path.symlink_to(ROOT / 'sources/tokens.jsonc')
        self.assert_rejected()

    def test_added_and_removed_native_resources_are_detected(self):
        unexpected = self.root / 'generated/swift/unmanaged.strings'
        unexpected.write_text('"raw"="copy";')
        with self.assertRaisesRegex(ValueError, 'inventory'):
            GENERATOR.generate(check=True, root=self.root)
        unexpected.unlink()
        (self.root / 'generated/swift/en.lproj/InfoPlist.strings').unlink()
        with self.assertRaisesRegex(ValueError, 'inventory'):
            GENERATOR.generate(check=True, root=self.root)


if __name__ == '__main__':
    unittest.main()
