"""Adversarial archive, allocation and build-boundary checks without downloads."""
import hashlib
import importlib.util
import io
import json
from pathlib import Path
import sys
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
saved_path = sys.path[:]
try:
    spec = importlib.util.spec_from_file_location('inference_runner_under_test', ROOT/'biometric/cpp/check_inference.py')
    runner = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(runner)
finally:
    sys.path[:] = saved_path


def checksum(data):
    return hashlib.sha256(data).hexdigest()


def archive(entries):
    output = io.BytesIO()
    with tarfile.open(fileobj=output, mode='w:gz') as stream:
        for name, body, kind in entries:
            member = tarfile.TarInfo(name)
            member.type = kind
            member.size = len(body) if kind == tarfile.REGTYPE else 0
            if kind in (tarfile.SYMTYPE, tarfile.LNKTYPE):
                member.linkname = '/outside'
            stream.addfile(member, io.BytesIO(body) if member.isfile() else None)
    return output.getvalue()


class InferenceRunnerTests(unittest.TestCase):
    def test_import_preserves_presentation_check_module_and_search_path(self):
        script = (
            'import importlib.util,sys\n'
            'original=list(sys.path)\n'
            f'spec=importlib.util.spec_from_file_location("isolated_inference", {str(ROOT/"biometric/cpp/check_inference.py")!r})\n'
            'module=importlib.util.module_from_spec(spec)\n'
            'spec.loader.exec_module(module)\n'
            'assert sys.path==original\n'
            f'sys.path.insert(0,{str(ROOT/"scripts")!r})\n'
            'from check import input_hashes\n'
            'assert callable(input_hashes)\n'
        )
        result = subprocess.run([sys.executable, '-c', script], capture_output=True, text=True, timeout=15)
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)

    def fixture(self, entries=None):
        entries = [('reviewed', b'', tarfile.DIRTYPE),
                   ('reviewed/include/header.h', b'header', tarfile.REGTYPE),
                   ('reviewed/lib/library.so', b'library', tarfile.REGTYPE)] if entries is None else entries
        data = archive(entries)
        pin = {'archiveRoot': 'reviewed', 'archiveSHA256': checksum(data),
               'maximumArchiveBytes': len(data), 'files': {
                   'include/header.h': {'bytes': 6, 'sha256': checksum(b'header')},
                   'lib/library.so': {'bytes': 7, 'sha256': checksum(b'library')}}}
        return data, pin

    def test_exact_root_directory_and_regular_members_are_accepted(self):
        data, pin = self.fixture()
        self.assertEqual(runner.runtime_members(data, pin),
                         {'include/header.h': b'header', 'lib/library.so': b'library'})

    def test_archive_digest_is_checked_before_parsing(self):
        data, pin = self.fixture()
        with patch.object(runner.tarfile, 'open') as parse:
            with self.assertRaisesRegex(ValueError, 'integrity'):
                runner.runtime_members(data + b'tampered', pin)
            parse.assert_not_called()

    def test_missing_duplicate_links_size_digest_and_foreign_root_fail(self):
        header = ('reviewed/include/header.h', b'header', tarfile.REGTYPE)
        library = ('reviewed/lib/library.so', b'library', tarfile.REGTYPE)
        cases = {
            'missing': [header], 'duplicate': [header, library, header],
            'symlink': [('reviewed/include/header.h', b'', tarfile.SYMTYPE), library],
            'hardlink': [('reviewed/include/header.h', b'', tarfile.LNKTYPE), library],
            'oversize': [('reviewed/include/header.h', b'header!', tarfile.REGTYPE), library],
            'undersize': [('reviewed/include/header.h', b'heade', tarfile.REGTYPE), library],
            'member_digest': [('reviewed/include/header.h', b'HEADER', tarfile.REGTYPE), library],
            'foreign_root': [header, library, ('foreign/file', b'x', tarfile.REGTYPE)],
            'root_prefix_collision': [('reviewed-other/include/header.h', b'header', tarfile.REGTYPE), library],
            'root_file': [('reviewed', b'file', tarfile.REGTYPE), header, library],
        }
        for name, entries in cases.items():
            with self.subTest(name=name):
                data, pin = self.fixture(entries)
                with self.assertRaises(ValueError):
                    runner.runtime_members(data, pin)

    def test_bounded_read_checks_exact_limit_and_never_uses_unbounded_read(self):
        class RecordingStream(io.BytesIO):
            def read(self, size=-1):
                self.last_requested = size
                if size < 0:
                    raise AssertionError('unbounded_read')
                return super().read(size)
        stream = RecordingStream(b'1234')
        self.assertEqual(runner.bounded_read(stream, 4), b'1234')
        self.assertEqual(stream.last_requested, 5)
        oversized_stream = RecordingStream(b'12345')
        with self.assertRaises(ValueError):
            runner.bounded_read(oversized_stream, 4)
        self.assertEqual(runner.bounded_read(RecordingStream(b''), 0), b'')
        for limit in (-1, -2):
            negative_limit_stream = RecordingStream(b'payload')
            with self.subTest(limit=limit), self.assertRaises(ValueError):
                runner.bounded_read(negative_limit_stream, limit)

    def test_local_archive_obeys_same_digest_and_size_checks_without_network(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary)/'runtime.tgz'
            data, pin = self.fixture()
            path.write_bytes(data)
            with patch.object(runner.urllib.request, 'urlopen', side_effect=AssertionError('network')):
                self.assertEqual(set(runner.acquire_runtime(pin, path)), set(pin['files']))
                path.write_bytes(data + b'x')
                with self.assertRaises(ValueError):
                    runner.acquire_runtime(pin, path)

    def test_late_invalid_member_prevents_every_runtime_file_write(self):
        entries = [('reviewed/include/header.h', b'header', tarfile.REGTYPE),
                   ('reviewed/lib/library.so', b'LIBRARY', tarfile.REGTYPE)]
        data, pin = self.fixture(entries)
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            pin_path = root/'pin.json'
            pin_path.write_text(json.dumps(pin))
            archive_path = root/'archive.tgz'
            archive_path.write_bytes(data)
            output = root/'output'
            with patch.object(runner, 'validated_options', return_value=('g++-13', output, None)), \
                 patch.object(runner, 'PIN_PATH', pin_path), \
                 patch.object(runner.platform, 'system', return_value='Linux'), \
                 patch.object(runner.platform, 'machine', return_value='x86_64'), \
                 patch.object(runner.subprocess, 'run', side_effect=AssertionError('build_before_validation')):
                with self.assertRaisesRegex(ValueError, 'member integrity'):
                    runner.check(output, archive_path=archive_path)
            self.assertFalse(list(output.rglob('runtime')))
            self.assertFalse(list(output.rglob('header.h')))
            self.assertFalse(json.loads((output/'receipt.json').read_text())['passed'])

    def test_bad_output_and_container_fail_before_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary:
            with patch.object(runner, 'acquire_runtime', side_effect=AssertionError('acquired')):
                with self.assertRaises(ValueError):
                    runner.check(Path(temporary)/'output')
                with self.assertRaises(ValueError):
                    runner.check(ROOT/'.build/inference-invalid-container', container_image='unreviewed')

    def test_repository_missing_directory_and_linked_models_fail_before_acquisition(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            link = root/'model.onnx'
            link.symlink_to(ROOT/'README.md')
            for model in (ROOT/'README.md', root/'missing.onnx', root, link):
                with self.subTest(model=str(model)), \
                     patch.object(runner, 'acquire_runtime', side_effect=AssertionError('acquired')):
                    with self.assertRaises((ValueError, FileNotFoundError)):
                        runner.check(ROOT/'.build/inference-invalid-model', model=model)
            self.assertFalse((ROOT/'.build/inference-invalid-model').exists())
