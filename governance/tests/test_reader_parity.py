"""Changes in either reader copy must fail the explicit parity gate."""
import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location('reader_parity', ROOT/'quality/reader_parity.py')
PARITY = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PARITY)


class ReaderParityTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix='reader-parity-guard-')
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)/'sdks'
        self.peer = Path(temporary.name)/'identity'
        files = {'Package.swift': b'// reviewed package', 'Sources/Reader.swift': b'public struct Reader {}'}
        for folder in (self.root/PARITY.READER, self.peer/PARITY.PEER):
            for name, content in files.items():
                path = folder/name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_bytes(content)
        manifest = self.root/PARITY.MANIFEST
        manifest.parent.mkdir(parents=True)
        manifest.write_text(json.dumps({
            'schemaVersion': 1,
            'scope': 'NFCPassportReader runtime and package; historical import hashes remain unchanged',
            'runtimeSHA256': {name: hashlib.sha256(content).hexdigest() for name, content in files.items()},
        }))

    def test_both_actual_runtime_trees_match_reviewed_record(self):
        self.assertEqual(len(PARITY.validate(self.root, self.peer)), 2)

    def test_changed_missing_or_added_runtime_on_either_side_fails(self):
        for folder in (self.root/PARITY.READER, self.peer/PARITY.PEER):
            path = folder/'Sources/Reader.swift'
            original = path.read_bytes()
            for mutation in ('changed', 'missing', 'added', 'package'):
                with self.subTest(folder=folder.name, mutation=mutation):
                    extra = folder/'Sources/Hidden.swift'
                    package = folder/'Package.swift'
                    package_original = package.read_bytes()
                    if mutation == 'changed':
                        path.write_bytes(original+b'\n// drift')
                    elif mutation == 'missing':
                        path.unlink()
                    elif mutation == 'added':
                        extra.write_text('struct Hidden {}')
                    else:
                        package.write_text('// changed supplier pin')
                    with self.assertRaises(ValueError):
                        PARITY.validate(self.root, self.peer)
                    path.write_bytes(original)
                    package.write_bytes(package_original)
                    if extra.exists():
                        extra.unlink()

    def test_symlink_and_empty_review_record_do_not_pass(self):
        path = self.peer/PARITY.PEER/'Sources/Reader.swift'
        path.unlink()
        path.symlink_to(self.root/PARITY.READER/'Sources/Reader.swift')
        with self.assertRaises(ValueError):
            PARITY.validate(self.root, self.peer)
        manifest = self.root/PARITY.MANIFEST
        data = json.loads(manifest.read_text())
        data['runtimeSHA256'] = {}
        manifest.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            PARITY.validate(self.root)


if __name__ == '__main__':
    unittest.main()
