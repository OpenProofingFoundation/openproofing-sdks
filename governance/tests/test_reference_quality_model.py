import hashlib
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('quality_provision',ROOT/'scripts/provision_reference_quality.py')
module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)

class ReferenceQualityModelTests(unittest.TestCase):
    def fixture(self,folder):
        source=folder/'source';source.mkdir();(source/'model.bin').write_bytes(b'controlled-test-bytes')
        data=(source/'model.bin').read_bytes()
        profile=folder/'profile.json';profile.write_text(json.dumps({'schemaVersion':1,'files':[
            {'path':'model.bin','bytes':len(data),'sha256':hashlib.sha256(data).hexdigest()}]}))
        return source,profile

    def test_native_dependency_notices_are_exact_and_packaged_without_weights(self):
        with tempfile.TemporaryDirectory() as temporary:
            output=Path(temporary)
            module.provision_notices(output)
            files=json.loads((output/'NativeQualityNotices/licenses.json').read_text())['files']
            self.assertEqual(len(files),12)
            for name,expected in files.items():
                self.assertEqual(module.digest(output/'NativeQualityNotices'/name),expected)
            self.assertFalse((output/'FaceQuality').exists())

    def test_model_bearing_builds_stay_outside_source_tree(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            with patch.object(module,'ROOT',root):
                self.assertFalse(module.provision(root/'missing',root/'build'))
                with self.assertRaises(ValueError):module.provision(root/'missing',root/'build',True)
        import importlib.util
        spec=importlib.util.spec_from_file_location('reference_embedding',ROOT/'scripts/provision_reference_model.py')
        embedding=importlib.util.module_from_spec(spec);spec.loader.exec_module(embedding)
        with tempfile.TemporaryDirectory() as temporary:
            root=Path(temporary)
            with patch.object(embedding,'ROOT',root):
                self.assertFalse(embedding.provision(root/'missing',root/'build'))

    def test_declared_profile_is_exact_and_contains_no_runtime_weights(self):
        profile=module.validated_profile()
        self.assertEqual(profile['ofiqVersion'],'1.0.3')
        self.assertEqual(profile['runtimeVersion'],'1.22.0')
        self.assertEqual(len(profile['files']),30)
        self.assertEqual(profile['execution']['intraOpThreads'],1)

    def test_missing_assets_are_explicit_and_required_install_refuses(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp)
            self.assertFalse(module.provision(root/'absent',root/'output'))
            with self.assertRaisesRegex(ValueError,'quality_assets_missing'):
                module.provision(root/'absent',root/'output',True)

    def test_exact_copy_and_modified_source_are_not_silently_replaced(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source,profile=self.fixture(root)
            with patch.object(module,'PROFILE',profile),patch.object(module,'PROFILE_SHA256',module.digest(profile)):
                self.assertTrue(module.provision(source,root/'output',True))
                self.assertEqual((root/'output/FaceQuality/model.bin').read_bytes(),(source/'model.bin').read_bytes())
                (source/'model.bin').write_bytes(b'changed')
                with self.assertRaisesRegex(ValueError,'quality_asset_integrity'):
                    module.provision(source,root/'output',True)

    def test_profile_tamper_and_traversal_fail_closed(self):
        with tempfile.TemporaryDirectory() as temp:
            root=Path(temp);source,profile=self.fixture(root)
            with patch.object(module,'PROFILE',profile),patch.object(module,'PROFILE_SHA256','0'*64):
                with self.assertRaisesRegex(ValueError,'quality_profile_integrity'):module.validated_profile()
            value=json.loads(profile.read_text());value['files'][0]['path']='../escape';profile.write_text(json.dumps(value))
            with patch.object(module,'PROFILE',profile),patch.object(module,'PROFILE_SHA256',module.digest(profile)):
                with self.assertRaisesRegex(ValueError,'quality_profile_path'):module.validated_profile()
