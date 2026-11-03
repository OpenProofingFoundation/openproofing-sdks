"""Exercise patched NIST helper failures without installing packages or submitting data."""
from pathlib import Path
import os
import subprocess
import tempfile
import unittest
ROOT=Path(__file__).resolve().parents[2]
UTILS=ROOT/'biometric/nist/upstream/common/scripts/utils.sh'

class NISTShellTests(unittest.TestCase):
    def run_helper(self,folder,body):
        return subprocess.run(['bash','-c','source "$1"; '+body,'probe',str(UTILS)],cwd=folder,
                              env={**os.environ,'TERM':'xterm'},capture_output=True,text=True,timeout=10)

    def test_missing_validation_folders_fail_on_stderr(self):
        with tempfile.TemporaryDirectory() as folder:
            result=self.run_helper(folder,'check_folders')
            self.assertEqual(result.returncode,1)
            self.assertIn('[ERROR] ./config was not found',result.stderr)
            self.assertNotIn('[ERROR]',result.stdout)

    def test_required_folders_and_os_checks_keep_their_contract(self):
        with tempfile.TemporaryDirectory() as folder:
            root=Path(folder)
            for name in ['config','lib','doc']:(root/name).mkdir()
            (root/'lib/reference.so').write_bytes(b'synthetic')
            (root/'doc/version.txt').write_text('test only')
            self.assertEqual(self.run_helper(folder,'check_folders').returncode,0)
            valid='lsb_release() { printf "Description: Ubuntu 24.04.3 LTS\\n"; }; check_os'
            invalid='lsb_release() { printf "Description: Unsupported OS\\n"; }; check_os'
            self.assertEqual(self.run_helper(folder,valid).returncode,0)
            failure=self.run_helper(folder,invalid)
            self.assertEqual(failure.returncode,1)
            self.assertIn('[ERROR]',failure.stderr)
