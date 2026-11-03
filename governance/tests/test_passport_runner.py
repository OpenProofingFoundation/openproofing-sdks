"""Reader test helpers cannot silently hide required native execution."""
import json
from pathlib import Path
import tempfile
import unittest

from scripts.passport_check import declared_test_ids


class PassportRunnerInventoryTests(unittest.TestCase):
    def test_helper_test_declarations_cannot_escape_required_id_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            tests = root/'passport/ios/Tests/PassportNFCTests'
            tests.mkdir(parents=True)
            gates = root/'passport/Gates'
            gates.mkdir()
            (gates/'passport-tests.json').write_text(json.dumps({'schemaVersion': 1,
                'requiredIDs': ['ReaderTests.testRead']}))
            (tests/'ReaderTests.swift').write_text('final class ReaderTests: XCTestCase { func testRead() {} }')
            helper = tests/'ReaderProtocolFixture.swift'
            helper.write_text('struct ReaderProtocolFixture {}')
            self.assertEqual(declared_test_ids(root), {'ReaderTests.testRead'})
            for declaration in ('class HiddenTests {}', 'struct HiddenTests {}',
                                'func testHidden() {}', '@Test func hidden() {}'):
                with self.subTest(declaration=declaration):
                    helper.write_text(declaration)
                    with self.assertRaises(ValueError):
                        declared_test_ids(root)


if __name__ == '__main__':
    unittest.main()
