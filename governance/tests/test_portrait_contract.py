"""Common synthetic inputs specify byte/layout and operation-binding failures."""
import copy
import json
from pathlib import Path
import unittest

from quality import portrait_contract as contract

ROOT = Path(__file__).resolve().parents[2]


class PortraitContractTests(unittest.TestCase):
    def test_shared_vectors_execute_all_binding_fields_and_pixel_formats(self):
        profile = json.loads((ROOT/'contracts/portrait-selfie-v1.json').read_text())
        data = json.loads((ROOT/'contracts/portrait-selfie-v1.vectors.json').read_text())
        self.assertGreaterEqual(contract.check(), 20)
        binding = {key for v in data['vectors'] if v['kind'] == 'binding' and v['expect'] == 'binding_mismatch'
                   for key in v['overrides']}
        self.assertEqual(binding, set(profile['bindingFields']))
        self.assertEqual(set(profile['consumers']), {'swift', 'kotlin', 'cpp20_nist'})

    def test_pixel_bytes_are_verified_instead_of_trusting_declared_hash(self):
        profile = json.loads((ROOT/'contracts/portrait-selfie-v1.json').read_text())
        data = json.loads((ROOT/'contracts/portrait-selfie-v1.vectors.json').read_text())
        descriptor = copy.deepcopy(data['pixelBase']['descriptor'])
        payload = bytearray.fromhex(data['pixelBase']['payloadHex'])
        payload[-1] ^= 1
        with self.assertRaisesRegex(ValueError, '^integrity_failure$'):
            contract.validate_pixels(descriptor, payload, profile)

    def test_each_binding_field_rejects_omission_and_type_confusion(self):
        data = json.loads((ROOT/'contracts/portrait-selfie-v1.vectors.json').read_text())
        for field in data['bindingBase']:
            cases = {v['id']: v for v in data['vectors']}
            with self.subTest(field=field):
                self.assertEqual(cases['missing-binding-'+field]['expect'], 'invalid_schema')
                for attack in ('null', 'array', 'number', 'newline'):
                    case = cases['type-binding-'+field+'-'+attack]
                    self.assertEqual(case['expect'], 'invalid_schema')
                self.assertEqual(cases['uppercase-binding-'+field]['expect'], 'invalid_schema')

    def test_integral_json_floats_and_narrowing_cannot_be_admitted(self):
        profile = json.loads((ROOT/'contracts/portrait-selfie-v1.json').read_text())
        data = json.loads((ROOT/'contracts/portrait-selfie-v1.vectors.json').read_text())
        payload = bytes.fromhex(data['pixelBase']['payloadHex'])
        for field in ('width', 'height', 'rowStrideBytes', 'byteLength', 'orientation'):
            for invalid in (True, False, None, '2', 2.0, [2], {'value': 2}, 2**63, 2**64 - 1, 2**64 + 2):
                descriptor = copy.deepcopy(data['pixelBase']['descriptor'])
                descriptor[field] = invalid
                with self.subTest(field=field, value=invalid):
                    with self.assertRaisesRegex(ValueError, '^invalid_pixels$'):
                        contract.validate_pixels(descriptor, payload, profile)

    def test_hashing_checks_every_single_byte_substitution(self):
        profile = json.loads((ROOT/'contracts/portrait-selfie-v1.json').read_text())
        data = json.loads((ROOT/'contracts/portrait-selfie-v1.vectors.json').read_text())
        descriptor = data['pixelBase']['descriptor']
        original = bytes.fromhex(data['pixelBase']['payloadHex'])
        for index in range(len(original)):
            changed = bytearray(original)
            changed[index] ^= 0x80
            with self.subTest(index=index):
                with self.assertRaisesRegex(ValueError, '^integrity_failure$'):
                    contract.validate_pixels(descriptor, changed, profile)
