"""Public trust packaging must reject substitution and never reuse stale build resources."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('reference_trust', ROOT/'scripts/provision_reference_trust.py')
trust = importlib.util.module_from_spec(spec)
spec.loader.exec_module(trust)

# Deliberately only a synthetic DER SEQUENCE envelope. These tests establish packaging
# framing/provenance, not X.509 authenticity; the native reader owns certificate validation.
PUBLIC_ENVELOPE = b'-----BEGIN CERTIFICATE-----\nMAA=\n-----END CERTIFICATE-----\n'


def policy(data=PUBLIC_ENVELOPE, count=1, limit=4096):
    return {'schemaVersion': 1, 'identifier': 'synthetic-public-envelope',
            'sha256': hashlib.sha256(data).hexdigest(), 'certificateCount': count,
            'maxBytes': limit}


class ReferencePassportTrustTests(unittest.TestCase):
    def test_provision_preserves_exact_reviewed_bytes_and_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'public.pem'
            source.write_bytes(PUBLIC_ENVELOPE)
            output = root/'bundle'
            expected = policy()
            self.assertTrue(trust.provision(source, output, expected))
            self.assertEqual((output/'PassportCSCA.pem').read_bytes(), PUBLIC_ENVELOPE)
            self.assertEqual(json.loads((output/'PassportTrust.json').read_text()), expected)
            self.assertEqual({path.name for path in output.iterdir()}, set(trust.NAMES))

    def test_missing_source_removes_both_stale_bundle_resources(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for name in trust.NAMES:
                (root/name).write_bytes(b'stale')
            self.assertFalse(trust.provision(root/'missing.pem', root, policy()))
            self.assertTrue(all(not (root/name).exists() for name in trust.NAMES))

    def test_changed_source_rejects_digest_and_removes_stale_outputs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root/'public.pem'
            source.write_bytes(PUBLIC_ENVELOPE + b'\n')
            output = root/'bundle'
            output.mkdir()
            for name in trust.NAMES:
                (output/name).write_bytes(b'stale')
            with self.assertRaises(ValueError):
                trust.provision(source, output, policy())
            self.assertEqual(list(output.iterdir()), [])

    def test_private_material_and_unexpected_bytes_are_refused_even_with_matching_digest(self):
        # A matching hash alone cannot turn a private-key block or unrelated bytes into CSCA data.
        for extra in (b'-----BEGIN PRIVATE KEY-----\nMAA=\n-----END PRIVATE KEY-----\n',
                      b'not a certificate', b'\x00', b'-----BEGIN PUBLIC KEY-----\nMAA=\n-----END PUBLIC KEY-----\n'):
            for data in (extra, PUBLIC_ENVELOPE + extra):
                with self.subTest(extra=extra):
                    with self.assertRaises(ValueError):
                        trust.validate(data, policy(data))

    def test_certificate_count_and_encoding_are_independent_requirements(self):
        for data, count in ((PUBLIC_ENVELOPE, 2), (PUBLIC_ENVELOPE * 2, 1),
                            (PUBLIC_ENVELOPE.replace(b'MAA=', b'!!!!'), 1),
                            (PUBLIC_ENVELOPE.replace(b'MAA=', b'AA=='), 1),
                            (PUBLIC_ENVELOPE.replace(b'MAA=', b''), 1)):
            with self.subTest(data=data, count=count):
                with self.assertRaises(ValueError):
                    trust.validate(data, policy(data, count))

    def test_resource_ceiling_rejects_even_matching_reviewed_digest(self):
        with self.assertRaises(ValueError):
            trust.validate(PUBLIC_ENVELOPE, policy(limit=len(PUBLIC_ENVELOPE)-1))


if __name__ == '__main__':
    unittest.main()
