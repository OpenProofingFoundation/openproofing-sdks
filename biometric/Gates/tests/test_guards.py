"""Run the common adversarial suite against this capability."""
import json
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Gates'))
sys.path.insert(0,str(ROOT.parent/'quality'))
import test_guard_regressions as shared_guard_tests
import capability_guards as guards

class GuardRegressionTests(shared_guard_tests.GuardRegressionTests):
    root=ROOT
    def test_primitive_wire_vocabularies_and_units_cannot_drift(self):
        paths=[('ios/Sources/BiometricSDK/EmbeddingMath.swift','"invalid_norm"','"ordinary_mismatch"'),
               ('android/biometric-sdk/src/main/kotlin/com/kenshikilabs/biometric/EmbeddingMath.kt','"face_identity"','"shared_document_face"')]
        for name,before,after in paths:
            with self.subTest(name=name),self.checkout() as root:
                path=root/name;path.write_text(path.read_text().replace(before,after))
                self.assertIn('embedding primitive contract','\n'.join(guards.scan(root)))
        with self.checkout() as root:
            path=root.parent/'contracts/embedding-math-v1.json'
            data=json.loads(path.read_text());data['angularDistanceUnit']='degree';path.write_text(json.dumps(data))
            self.assertIn('numerical/units','\n'.join(guards.scan(root)))


if __name__=='__main__':
    import unittest
    unittest.main()
