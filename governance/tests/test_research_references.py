"""Reference replacement and version/path substitution must be visible to governance."""
import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from quality import research

ROOT = Path(__file__).resolve().parents[2]


class ResearchReferenceTests(unittest.TestCase):
    def test_committed_papers_match_the_reviewed_manifest(self):
        self.assertGreaterEqual(research.check(), 15)

    def test_replaced_pdf_cannot_keep_its_original_citation(self):
        manifest = json.loads((ROOT/'governance/research/manifest.json').read_text())
        entry = copy.deepcopy(manifest['papers'][0])
        with tempfile.TemporaryDirectory() as name:
            folder = Path(name)
            path = folder/entry['localPath']
            path.parent.mkdir(parents=True)
            body = b'%PDF-1.7\nreplacement reference copy'
            entry['bytes'] = len(body)
            entry['sha256'] = hashlib.sha256(body).hexdigest()
            path.write_bytes(body)
            research.validate_entry(folder, entry)
            path.write_bytes(body.replace(b'replacement', b'unreviewed!'))
            with self.assertRaisesRegex(ValueError, 'mismatch'):
                research.validate_entry(folder, entry)

    def test_mutable_reference_or_escaping_path_is_rejected(self):
        entry = json.loads((ROOT/'governance/research/manifest.json').read_text())['papers'][0]
        for overrides in ({'id': entry['id'].split('v')[0]},
                          {'url': 'https://arxiv.org/abs/'+entry['id'].split('v')[0]},
                          {'localPath': '../outside.pdf'}):
            with self.subTest(overrides=overrides), self.assertRaises(ValueError):
                research.validate_entry(ROOT/'governance/research', {**entry, **overrides})
