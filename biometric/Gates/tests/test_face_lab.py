"""Data tooling guards use synthetic archive names and bytes, never personal images."""
import importlib.util
import io
import json
from pathlib import Path
import stat
import sys
import tempfile
import unittest
from unittest.mock import patch
import zipfile
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'tools/face_lab'))
import data as face_data
import sample_index

class FaceLabDataTests(unittest.TestCase):
    def archive(self,name,mode=0):
        stream=io.BytesIO()
        with zipfile.ZipFile(stream,'w') as archive:
            item=zipfile.ZipInfo(name);item.external_attr=mode<<16;archive.writestr(item,b'synthetic')
        stream.seek(0);return zipfile.ZipFile(stream)

    def test_workbench_cannot_be_inside_repo(self):
        with self.assertRaises(ValueError):face_data.external_directory(ROOT/'private-data')
        self.assertFalse((ROOT/'private-data').exists())
        if (ROOT.parent/'sdks.json').is_file():
            for name in ['document','passport','foundation']:
                with self.assertRaises(ValueError):face_data.external_directory(ROOT.parent/name/'private-data')
                self.assertFalse((ROOT.parent/name/'private-data').exists())

    def test_archive_traversal_absolute_and_symlinks_rejected(self):
        for name,mode in [('../escape',0),('/escape',0),('folder\\escape',0),('link',stat.S_IFLNK | 0o777)]:
            with self.subTest(name=name),self.archive(name,mode) as archive:
                with self.assertRaises(ValueError):list(face_data.archive_entries(archive))

    def test_duplicate_archive_entries_rejected(self):
        with self.archive('safe/file') as archive:
            self.assertEqual(len(list(face_data.archive_entries(archive))),1)
        stream=io.BytesIO()
        with zipfile.ZipFile(stream,'w') as archive:
            import warnings
            with warnings.catch_warnings():
                warnings.simplefilter('ignore');archive.writestr('same',b'a');archive.writestr('same',b'b')
        stream.seek(0)
        with zipfile.ZipFile(stream) as archive:
            with self.assertRaises(ValueError):list(face_data.archive_entries(archive))

    def test_inventory_follows_pages_without_inventing_counts(self):
        responses=[{'currentVersionNumber':6,'licenseName':'sample-license','description':'sample'}, {'datasetFiles':[{'name':'one','totalBytes':3}],'nextPageToken':'next'}, {'datasetFiles':[{'name':'two','totalBytes':4}]}]
        with patch.object(face_data,'fetch_json',side_effect=responses):
            result=face_data.inventory();self.assertEqual(len(result['files']),2)

    def test_repeated_page_and_version_drift_rejected(self):
        with patch.object(face_data,'fetch_json',return_value={'currentVersionNumber':7}):
            with self.assertRaises(ValueError):face_data.inventory()
        responses=[{'currentVersionNumber':6,'licenseName':'x','description':'x'}, {'datasetFiles':[],'nextPageToken':'same'}, {'datasetFiles':[],'nextPageToken':'same'}]
        with patch.object(face_data,'fetch_json',side_effect=responses):
            with self.assertRaises(ValueError):face_data.inventory()

    def test_source_labels_remain_provisional(self):
        rows=[{'path':'sample/person-a/Passport.jpg','sha256':'a'*64,'width':112,'height':112},{'path':'sample/person-a/Phone_01.jpg','sha256':'b'*64,'width':112,'height':112}]
        records=sample_index.provisional_records(rows)
        self.assertEqual(records[0]['subjectGroup'],records[1]['subjectGroup'])
        self.assertEqual([r['role'] for r in records],['reference_candidate','selfie_candidate'])
        self.assertTrue(all(not r['productionEligible'] for r in records))

    def test_runtime_requirements_are_hashed_and_pinned(self):
        lock=(ROOT/'tools/face_lab/requirements-macos.lock.txt').read_text()
        import re
        names=re.findall(r'^([\w-]+)==[^\n]+',lock,re.M)
        self.assertIn('torch',names);self.assertIn('coremltools',names)
        for block in re.split(r'(?m)^(?=[\w-]+==)',lock)[1:]:self.assertIn('--hash=sha256:',block)

if __name__=='__main__':unittest.main()
