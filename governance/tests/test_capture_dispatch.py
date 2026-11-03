"""The aggregate local check must execute the same capture lane as CI."""
import importlib.util
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('capture_dispatch_runner', ROOT/'scripts/check.py')
runner = importlib.util.module_from_spec(spec)
spec.loader.exec_module(runner)


class CaptureDispatchTests(unittest.TestCase):
    def test_aggregate_biometric_and_all_execute_capture_without_softening_failure(self):
        for sdk in ('biometric', 'all'):
            with self.subTest(sdk=sdk), patch.object(runner, 'run', return_value=False) as execute:
                args = SimpleNamespace(sdk=sdk, platform='all')
                self.assertEqual(runner.run_capture(args, {'source': 'digest'}), [False])
                execute.assert_called_once_with('biometric-capture-ios',
                    [runner.sys.executable, 'scripts/capture_check.py'], {'source': 'digest'})

    def test_unaffected_products_and_individual_builds_do_not_launch_capture(self):
        for sdk, platform in (('document', 'all'), ('passport', 'all'), ('all', 'guards'),
                              ('biometric', 'ios-device'), ('biometric', 'nist')):
            with self.subTest(sdk=sdk, platform=platform), patch.object(runner, 'run') as execute:
                self.assertEqual(runner.run_capture(SimpleNamespace(sdk=sdk, platform=platform), {}), [])
                execute.assert_not_called()

    def test_capture_argv_and_receipt_label_have_explicit_inventory(self):
        command = (runner.sys.executable, 'scripts/capture_check.py')
        self.assertEqual(runner.APPROVED_COMMANDS[command], command)
        self.assertIn('biometric-capture-ios', runner.APPROVED_LABELS)
        self.assertNotIn(command+('--skip-tests',), runner.APPROVED_COMMANDS)


if __name__ == '__main__':
    unittest.main()
