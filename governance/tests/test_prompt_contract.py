"""The isolated, version-pinned prompt validator runs in every root governance check."""
import json
from pathlib import Path
import re
import subprocess
import unittest

ROOT = Path(__file__).resolve().parents[2]
EXPECTED = {'attrs': '26.1.0', 'jsonschema': '4.25.1',
            'jsonschema-specifications': '2025.9.1', 'referencing': '0.37.0',
            'rpds-py': '2026.9.1'}
REQUIRED = {
    'test_balanced_examples_and_exact_assembly',
    'test_dynamic_context_changes_cannot_keep_old_request_identity',
    'test_foreign_aura_and_swapped_sources_are_rejected',
    'test_invalid_chronology_and_invented_portrait_age_are_rejected',
    'test_output_cannot_invent_missing_inputs_or_temporal_measurements',
    'test_impossible_age_range_and_repeated_indicators_are_rejected',
    'test_strict_json_rejects_duplicate_keys_and_nonfinite_numbers',
    'test_unknown_verdict_and_control_text_are_rejected',
    'test_native_static_depth_retains_image_clock_and_bounded_measurements',
    'test_core_motion_window_is_bound_and_cannot_claim_visual_temporal_cues',
}


class PromptContractGovernanceTests(unittest.TestCase):
    def test_pinned_isolated_validator_executes_contract_and_adversarial_vectors(self):
        requirements = (ROOT/'contracts/tools/requirements.txt').read_text().splitlines()
        self.assertEqual(dict(line.split('==') for line in requirements), EXPECTED)
        python = ROOT/'.build/contracts-validator/bin/python'
        self.assertTrue(python.is_file(), 'Run npm run bootstrap to install the isolated prompt validator')
        probe = ('import importlib.metadata,json,sys; '
                 'print(json.dumps({name:importlib.metadata.version(name) for name in '
                 + repr(list(EXPECTED)) + '})); assert sys.prefix != sys.base_prefix')
        versions = subprocess.run([str(python), '-c', probe], cwd=ROOT, text=True,
                                  capture_output=True, timeout=30)
        self.assertEqual(versions.returncode, 0, versions.stderr)
        self.assertEqual(json.loads(versions.stdout), EXPECTED)
        result = subprocess.run([str(python), '-m', 'unittest', 'discover', '-v',
                                 '-s', 'contracts/tools', '-p', 'test_prompt_contract.py'],
                                cwd=ROOT, text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        executed = set(re.findall(r'^(test_\w+) \([^\n]+\) \.\.\. ok$', result.stderr, re.M))
        self.assertTrue(REQUIRED <= executed, result.stderr)
        self.assertNotRegex(result.stderr, r'(?i)\bskipped\b')
        result = subprocess.run([str(python), 'contracts/tools/prompt_contract.py'], cwd=ROOT,
                                text=True, capture_output=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
