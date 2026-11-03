"""Synthetic byte fixtures exercise migration invariants before owner-authorized cleanup."""
from pathlib import Path
import hashlib
import io
import json
import stat
import sys
import tempfile
import unittest
import zipfile
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT/'tools/face_lab'))
import axon_bulk
import canonical


class AxonCorpusTests(unittest.TestCase):
    def fixture(self, root, name):
        source = root/'data/quarantine'/name
        (source/'files/provider-folder').mkdir(parents=True)
        # Synthetic bytes; canonicalization consumes a previously verified media manifest.
        payloads = {'provider-folder/image.png': b'synthetic pixel fixture', 'labels.json': b'{"label":"synthetic"}'}
        rows = []
        with zipfile.ZipFile(source/'dataset.zip', 'w') as archive:
            for path, blob in payloads.items():
                archive.writestr(path, blob); (source/'files'/path).write_bytes(blob)
                row = {'path': path, 'sha256': hashlib.sha256(blob).hexdigest(), 'bytes': len(blob)}
                if path.endswith('.png'):
                    row.update({'format': 'PNG', 'width': 1, 'height': 1})
                rows.append(row)
        (source/'file-manifest.jsonl').write_text(''.join(json.dumps(row)+'\n' for row in rows))
        (source/'acquisition-summary.json').write_text(json.dumps({
            'ref': 'axondata/'+name, 'version': 1, 'title': name, 'license': 'synthetic-test',
            'files': len(rows), 'archiveSHA256': canonical.sha256(source/'dataset.zip'),
            'status': 'downloaded-extracted-inventory-and-crc-verified'}))
        return source

    def test_reconciled_media_and_annotations_survive_source_retirement(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); connection = canonical.connect(root); source = self.fixture(root, 'first')
            result = canonical.canonicalize(root, source, connection, retire=True)
            self.assertEqual(result['sourceCleanup'], 'complete'); self.assertFalse(source.exists())
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM media').fetchone()[0], 1)
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM annotations').fetchone()[0], 1)
            digest, path = connection.execute('SELECT sha256,path FROM media').fetchone()
            self.assertEqual(canonical.sha256(root/'data/canonical'/path), digest)
            self.assertEqual(connection.execute('SELECT label_state,verified_subject_id,split FROM observations').fetchone(), ('unreviewed', None, None))
            connection.close()

    def test_cross_dataset_duplicates_have_one_media_and_distinct_provenance(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); connection = canonical.connect(root)
            for name in ['first', 'second']:
                canonical.canonicalize(root, self.fixture(root, name), connection, retire=True)
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM media').fetchone()[0], 1)
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM observations').fetchone()[0], 2)
            self.assertEqual(len(list((root/'data/canonical/media').rglob('*.png'))), 1)
            previous=axon_bulk.existing_canonical({'ref':'axondata/first','currentVersionNumber':1,'title':'first'},root)
            self.assertEqual(previous['status'],'canonical_source_retired')
            self.assertEqual(previous['files'],2)
            connection.close()

    def test_tampered_source_is_not_retired_or_admitted(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); connection = canonical.connect(root); source = self.fixture(root, 'first')
            (source/'files/provider-folder/image.png').write_bytes(b'changed')
            with self.assertRaises(ValueError):
                canonical.canonicalize(root, source, connection, retire=True)
            self.assertTrue(source.exists())
            self.assertEqual(connection.execute('SELECT COUNT(*) FROM datasets').fetchone()[0], 0)
            connection.close()

    def test_cleanup_refuses_an_unowned_source_directory(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder); connection = canonical.connect(root)
            with self.assertRaises(ValueError):
                canonical.canonicalize(root, root/'data/canonical', connection, retire=True)
            self.assertTrue((root/'data/canonical/index.sqlite').exists()); connection.close()

    def test_archive_paths_symlinks_and_inventory_drift_are_rejected(self):
        for name, mode in [('../outside', 0), ('/absolute', 0), ('nested\\outside', 0), ('link', stat.S_IFLNK | 0o777)]:
            with self.subTest(name=name):
                stream = io.BytesIO()
                with zipfile.ZipFile(stream, 'w') as archive:
                    entry = zipfile.ZipInfo(name); entry.external_attr = mode << 16; archive.writestr(entry, b'x')
                stream.seek(0)
                with zipfile.ZipFile(stream) as archive, self.assertRaises(ValueError):
                    axon_bulk.safe_entries(archive, {'files': [{'name': name, 'bytes': 1}]})
        stream = io.BytesIO()
        with zipfile.ZipFile(stream, 'w') as archive:
            archive.writestr('safe', b'x')
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive, self.assertRaises(ValueError):
            axon_bulk.safe_entries(archive, {'files': [{'name': 'safe', 'bytes': 2}]})

    def test_selection_excludes_unrelated_provider_products(self):
        for title, expected in [('Face recognition', True), ('Silicone mask attacks', True), ('Russian call center audio', False), ('Palm recognition', False), ('MRI dataset', False)]:
            self.assertEqual(axon_bulk.relevant({'ref': 'axondata/synthetic', 'title': title}), expected)

    def test_sparse_segmented_download_cannot_use_sequential_resume(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder); destination=root/'data/quarantine/first-v1'; destination.mkdir(parents=True)
            (destination/'dataset.zip.partial').write_bytes(b'synthetic sparse-state placeholder')
            (destination/'dataset.zip.partial.aria2').write_bytes(b'synthetic resume state')
            item={'ref':'axondata/first','currentVersionNumber':1,'title':'first'}
            with patch.object(axon_bulk,'inventory',return_value={'files':[]}), patch.object(axon_bulk.urllib.request,'urlopen') as request:
                with self.assertRaisesRegex(ValueError,'must resume with aria2'):
                    axon_bulk.acquire(item,root,transport='urllib')
                request.assert_not_called()


    def test_sequential_resume_requires_matching_content_range(self):
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)/'partial'
            temporary.write_bytes(b'prefix')
            response = io.BytesIO(b'-suffix')
            response.status = 206
            response.headers = {'Content-Range': 'bytes 6-12/13'}
            with patch.object(axon_bulk.urllib.request, 'urlopen', return_value=response) as request:
                axon_bulk.stream_urllib_download(temporary, 'axondata/synthetic', 1)
                self.assertEqual(request.call_args.args[0].get_header('Range'), 'bytes=6-')
            self.assertEqual(temporary.read_bytes(), b'prefix-suffix')
            rejected = io.BytesIO(b'wrong')
            rejected.status = 206
            rejected.headers = {'Content-Range': 'bytes 0-4/5'}
            with patch.object(axon_bulk.urllib.request, 'urlopen', return_value=rejected):
                with self.assertRaisesRegex(ValueError, 'Unexpected partial response'):
                    axon_bulk.stream_urllib_download(temporary, 'axondata/synthetic', 1)
            self.assertEqual(temporary.read_bytes(), b'prefix-suffix')
            self.assertTrue(rejected.closed)

    def test_server_ignoring_range_restarts_without_retaining_partial_bytes(self):
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)/'partial'
            temporary.write_bytes(b'old-partial')
            response = io.BytesIO(b'new-complete')
            response.status = 200
            response.headers = {}
            with patch.object(axon_bulk.urllib.request, 'urlopen', return_value=response):
                axon_bulk.stream_urllib_download(temporary, 'axondata/synthetic', 1)
            self.assertEqual(temporary.read_bytes(), b'new-complete')

    def test_bad_archive_is_discarded_before_a_valid_bounded_retry(self):
        with tempfile.TemporaryDirectory() as folder:
            temporary = Path(folder)/'partial'
            final = Path(folder)/'dataset.zip'
            attempts = []
            def transfer(path, ref, version):
                attempts.append(path.exists())
                if len(attempts) == 1:
                    path.write_bytes(b'invalid zip')
                else:
                    with zipfile.ZipFile(path, 'w') as archive:
                        archive.writestr('safe.txt', b'ok')
            with patch.object(axon_bulk, 'stream_urllib_download', side_effect=transfer), patch.object(axon_bulk.time, 'sleep'):
                axon_bulk.download_urllib(temporary, final, 'axondata/synthetic', 1,
                                          {'files': [{'name': 'safe.txt', 'bytes': 2}]})
            self.assertEqual(attempts, [False, False])
            self.assertFalse(temporary.exists())
            with zipfile.ZipFile(final) as archive:
                self.assertEqual(archive.read('safe.txt'), b'ok')

    def test_late_source_tamper_rolls_back_database_and_preserves_source_tree(self):
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            connection = canonical.connect(root)
            source = self.fixture(root, 'first')
            (source/'files/labels.json').write_bytes(b'changed annotation after valid image')
            with self.assertRaisesRegex(ValueError, 'Source bytes changed'):
                canonical.canonicalize(root, source, connection, retire=True)
            for table in ['datasets', 'media', 'observations', 'annotations']:
                self.assertEqual(connection.execute('SELECT COUNT(*) FROM '+table).fetchone()[0], 0)
            self.assertTrue((source/'dataset.zip').is_file())
            self.assertTrue((source/'files/provider-folder/image.png').is_file())
            connection.close()


if __name__ == '__main__':
    unittest.main()
