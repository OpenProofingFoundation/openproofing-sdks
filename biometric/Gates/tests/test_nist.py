"""Reject changes to the integrated official code, inventory and source boundary."""
from pathlib import Path
import json
import shutil
import sys
import tempfile
import unittest
ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'Gates'))
from nist_integrity import verify


class NISTIntegrityTests(unittest.TestCase):
    def test_reviewed_sources_pass(self):
        paths, failures = verify(ROOT)
        self.assertFalse(failures)
        self.assertEqual(len(paths), 24)

    def test_modified_missing_extra_and_symlink_sources_fail(self):
        for mutation in ['modified', 'missing', 'extra', 'symlink', 'manifest', 'pin']:
            with self.subTest(mutation=mutation), tempfile.TemporaryDirectory() as folder:
                root = Path(folder)
                shutil.copytree(ROOT/'nist', root/'nist')
                target = root/'nist/upstream/11/src/include/frvt11.h'
                if mutation == 'modified':
                    target.write_text(target.read_text()+'\n// drift\n')
                elif mutation == 'missing':
                    target.unlink()
                elif mutation == 'extra':
                    (target.parent/'hidden.cpp').write_text('int hidden;')
                elif mutation == 'symlink':
                    target.unlink(); target.symlink_to(ROOT/'nist/upstream/11/src/include/frvt11.h')
                elif mutation == 'manifest':
                    path = root/'nist/upstream-manifest.json'
                    data = json.loads(path.read_text()); data['revision'] = 'unreviewed'
                    path.write_text(json.dumps(data))
                else:
                    path = root/'nist/sources.json'
                    data = json.loads(path.read_text()); data['sources'][0]['sha256'] = '0'*64
                    path.write_text(json.dumps(data))
                paths, failures = verify(root)
                self.assertTrue(failures)
                self.assertFalse(paths)
