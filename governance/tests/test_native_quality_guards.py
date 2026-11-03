"""Adversarial closure checks for the optional local quality stack."""
from pathlib import Path
import hashlib
import json
import shutil
import tempfile
import unittest
from quality import native_quality_guards as guards

ROOT=Path(__file__).resolve().parents[2]/'biometric'

class NativeQualityGuardsTests(unittest.TestCase):
    def checkout(self, temporary):
        root=Path(temporary)
        for name in guards.SOURCES|{'Gates/quality-sources.json'}:
            target=root/name;target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(ROOT/name,target)
        return root

    def test_reviewed_quality_boundary(self):
        self.assertEqual(guards.check(ROOT),[])

    def test_hidden_source_symlink_and_profile_change_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root=self.checkout(temporary)
            hidden=root/'quality-apple/Sources/BiometricQuality/Hidden.swift'
            hidden.write_text('import Foundation\n')
            self.assertTrue(guards.check(root));hidden.unlink()
            hidden.symlink_to(root/'quality-apple/Sources/BiometricQuality/OFIQFaceQuality.swift')
            self.assertTrue(guards.check(root));hidden.unlink()
            profile=root/guards.PROFILE;profile.write_text(profile.read_text()+'\n')
            lockpath=root/'Gates/quality-sources.json';lock=json.loads(lockpath.read_text())
            lock[guards.PROFILE]=hashlib.sha256(profile.read_bytes()).hexdigest();lockpath.write_text(json.dumps(lock))
            self.assertTrue(any('profile identity' in item for item in guards.check(root)))

    def test_reviewed_digest_cannot_introduce_network_or_ui(self):
        for injection in ('import UIKit','let transport = URLSession.shared'):
            with self.subTest(injection=injection),tempfile.TemporaryDirectory() as temporary:
                root=self.checkout(temporary);name='quality-apple/Sources/BiometricQuality/OFIQFaceQuality.swift'
                source=root/name;source.write_text(source.read_text()+'\n'+injection+'\n')
                lockpath=root/'Gates/quality-sources.json';lock=json.loads(lockpath.read_text())
                lock[name]=hashlib.sha256(source.read_bytes()).hexdigest();lockpath.write_text(json.dumps(lock))
                self.assertTrue(any('dependency' in item or 'cannot own' in item for item in guards.check(root)))

    def test_sidecar_cannot_redeclare_runtime_or_reach_ambient_state_with_updated_pins(self):
        for name,old,new in [
            ('quality-apple/Package.swift','BiometricRuntime','UnreviewedRuntime'),
            ('quality-apple/Package.swift','.build/native-quality/OFIQNative.xcframework','../unreviewed/OFIQNative.xcframework'),
            ('quality-apple/Sources/BiometricQuality/OFIQFaceQuality.swift','import Foundation','import Foundation\nlet ambient = Bundle.main'),
        ]:
            with self.subTest(name=name),tempfile.TemporaryDirectory() as temporary:
                root=self.checkout(temporary);source=root/name
                source.write_text(source.read_text().replace(old,new))
                lockpath=root/'Gates/quality-sources.json';lock=json.loads(lockpath.read_text())
                lock[name]=hashlib.sha256(source.read_bytes()).hexdigest();lockpath.write_text(json.dumps(lock))
                self.assertTrue(guards.check(root))
