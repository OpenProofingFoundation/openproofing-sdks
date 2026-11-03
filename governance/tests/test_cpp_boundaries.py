"""Deliberate violations of the new portable-library boundary must fail closed."""
import json
from pathlib import Path
import shutil
import tempfile
import unittest

from quality.cpp_guards import check

ROOT = Path(__file__).resolve().parents[2]


class CppBoundariesTests(unittest.TestCase):
    def test_current_portable_inventory_is_guarded(self):
        self.assertEqual(check(ROOT/'biometric')[1], [])

    def test_hidden_source_symlink_tamper_and_mobile_dependency_fail(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            shutil.copytree(ROOT/'biometric/cpp', root/'cpp')
            (root/'Gates').mkdir()
            shutil.copy(ROOT/'biometric/Gates/cpp-sources.json', root/'Gates/cpp-sources.json')
            hidden = root/'cpp/include/kenshiki/hidden.hpp'
            hidden.write_text('struct Unreviewed {};\n')
            self.assertTrue(check(root)[1])
            hidden.unlink()
            hidden.symlink_to(root/'cpp/include/kenshiki/portrait.hpp')
            self.assertTrue(check(root)[1])
            hidden.unlink()
            source = root/'cpp/src/portrait.cpp'
            source.write_text(source.read_text()+'\n#include <fstream>\n')
            failures = check(root)[1]
            self.assertTrue(any('reviewed digest' in failure for failure in failures))
            # Updating a digest cannot authorize storage/networking in the portable core.
            import hashlib
            lock_path = root/'Gates/cpp-sources.json'
            lock = json.loads(lock_path.read_text())
            lock['cpp/src/portrait.cpp'] = hashlib.sha256(source.read_bytes()).hexdigest()
            lock_path.write_text(json.dumps(lock))
            self.assertTrue(any('nonportable' in failure for failure in check(root)[1]))

    def test_profile_bytes_and_runtime_isolation_fail_closed(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)/'biometric'
            shutil.copytree(ROOT/'biometric/cpp', root/'cpp')
            shutil.copytree(ROOT/'contracts', root.parent/'contracts')
            (root/'Gates').mkdir()
            shutil.copy(ROOT/'biometric/Gates/cpp-sources.json', root/'Gates/cpp-sources.json')
            self.assertEqual(check(root)[1], [])
            profile = root.parent/'contracts/auraface-aligned-input-v1.json'
            profile.write_text(profile.read_text()+'\n')
            self.assertTrue(any('exact profile identity' in failure for failure in check(root)[1]))
            shutil.copy(ROOT/'contracts/auraface-aligned-input-v1.json', profile)
            source = root/'cpp/src/auraface_input.cpp'
            source.write_text(source.read_text()+'\n#include <onnxruntime_cxx_api.h>\n')
            import hashlib
            lock_path = root/'Gates/cpp-sources.json'
            lock = json.loads(lock_path.read_text())
            lock['cpp/src/auraface_input.cpp'] = hashlib.sha256(source.read_bytes()).hexdigest()
            lock_path.write_text(json.dumps(lock))
            self.assertTrue(any('optional inference runtime' in failure for failure in check(root)[1]))

    def test_selector_remains_portable_with_reviewed_digest(self):
        import hashlib
        for injection, expected in [('#include <fstream>\n', 'nonportable'),
                                    ('#include <onnxruntime_cxx_api.h>\n', 'optional inference runtime')]:
            with self.subTest(injection=injection), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)/'biometric'
                shutil.copytree(ROOT/'biometric/cpp', root/'cpp')
                shutil.copytree(ROOT/'contracts', root.parent/'contracts')
                (root/'Gates').mkdir()
                lock = json.loads((ROOT/'biometric/Gates/cpp-sources.json').read_text())
                name = 'cpp/src/frame_selection.cpp'
                source = root/name
                source.write_text(source.read_text()+'\n'+injection)
                lock[name] = hashlib.sha256(source.read_bytes()).hexdigest()
                (root/'Gates/cpp-sources.json').write_text(json.dumps(lock))
                self.assertTrue(any(expected in failure for failure in check(root)[1]))
