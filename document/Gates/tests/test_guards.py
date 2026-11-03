"""Run the common adversarial suite against this capability."""
from pathlib import Path
import sys
ROOT=Path(__file__).resolve().parents[2]
sys.path.insert(0,str(ROOT/'Gates'))
sys.path.insert(0,str(ROOT.parent/'quality'))
import test_guard_regressions as shared_guard_tests

class GuardRegressionTests(shared_guard_tests.GuardRegressionTests):
    root=ROOT

if __name__=='__main__':
    import unittest
    unittest.main()
