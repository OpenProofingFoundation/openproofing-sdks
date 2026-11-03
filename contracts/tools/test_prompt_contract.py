"""Semantic conformance vectors complement JSON Schema and prompt examples."""
from copy import deepcopy
import tempfile
from pathlib import Path
import unittest

import prompt_contract as contract


class PromptContractTests(unittest.TestCase):
    def setUp(self):
        self.checks = contract.validators()
        self.cases = contract.strict_load(contract.ROOT / 'examples/liquid-prompt-examples-v2.json')['examples']
        self.input = deepcopy(self.cases[0]['input'])
        self.output = deepcopy(self.cases[0]['output'])

    def test_balanced_examples_and_exact_assembly(self):
        self.assertEqual({case['id'] for case in self.cases},
                         {'usable-evidence', 'meaningful-conflict', 'insufficient-evidence'})
        for case in self.cases:
            contract.validate_input(case['input'], self.checks)
            contract.validate_output(case['output'], case['input'], self.checks)
            packet = contract.assemble(case['input'])
            self.assertEqual(packet, contract.assemble(case['input']))
            self.assertEqual(len(packet['messages']), 8)
            self.assertEqual(packet['messages'][-1]['content'][1]['imageId'], 'Media-1')
            self.assertEqual(packet['messages'][-1]['content'][3]['imageId'], 'Media-2')

    def test_dynamic_context_changes_cannot_keep_old_request_identity(self):
        first = contract.assemble(self.input)
        self.input['context']['aura']['cosineSimilarity'] = 0.12
        second = contract.assemble(self.input)
        self.assertNotEqual(first['inputSHA256'], second['inputSHA256'])
        self.assertNotEqual(first['messagesSHA256'], second['messagesSHA256'])

    def test_foreign_aura_and_swapped_sources_are_rejected(self):
        for kind in ('aura', 'swapped'):
            bad = deepcopy(self.input)
            if kind == 'aura': bad['context']['aura']['referenceSHA256'] = 'f' * 64
            else: bad['images'][0], bad['images'][1] = bad['images'][1], bad['images'][0]
            with self.subTest(kind=kind), self.assertRaises(ValueError):
                contract.validate_input(bad, self.checks)

    def test_invalid_chronology_and_invented_portrait_age_are_rejected(self):
        for key, value in [('expectedAgeAtSelfieCapture', 99), ('referencePhotoDate', None)]:
            bad = deepcopy(self.input)
            bad['context']['age'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                contract.validate_input(bad, self.checks)

    def test_output_cannot_invent_missing_inputs_or_temporal_measurements(self):
        bad = deepcopy(self.output)
        bad['captureReview']['indicators'] = [{'indicator': 'motion_parallax', 'status': 'present',
            'evidence': 'Motion was observed.', 'sourceImageIds': ['Media-2']}]
        with self.assertRaises(ValueError): contract.validate_output(bad, self.input, self.checks)
        unavailable = deepcopy(self.input)
        unavailable['context']['aura'] = {'status': 'not_provided', 'reason': 'Not supplied.'}
        with self.assertRaises(ValueError): contract.validate_output(self.output, unavailable, self.checks)

    def test_impossible_age_range_and_repeated_indicators_are_rejected(self):
        bad = deepcopy(self.output)
        bad['selfie']['apparentAge']['rangeYears'] = [60, 20]
        with self.assertRaises(ValueError): contract.validate_output(bad, self.input, self.checks)
        bad = deepcopy(self.output)
        cue = {'indicator': 'moire', 'status': 'absent', 'evidence': 'No visible pattern.', 'sourceImageIds': ['Media-2']}
        bad['captureReview']['indicators'] = [cue, cue]
        with self.assertRaises(ValueError): contract.validate_output(bad, self.input, self.checks)

    def test_strict_json_rejects_duplicate_keys_and_nonfinite_numbers(self):
        for payload in ('{"x":1,"x":2}', '{"x":1,"\\u0078":2}', '{"x":NaN}'):
            with self.subTest(payload=payload), tempfile.TemporaryDirectory() as directory:
                path = Path(directory) / 'input.json'
                path.write_text(payload)
                with self.assertRaises(ValueError): contract.strict_load(path)

    def test_unknown_verdict_and_control_text_are_rejected(self):
        bad = deepcopy(self.output)
        bad['match'] = True
        self.assertFalse(self.checks['liquid-prompt-output-v2.schema.json'].is_valid(bad))
        for text in ('hidden\u202etext', 'hidden\ntext', '\ud800'):
            bad = deepcopy(self.output)
            bad['summary'] = text
            with self.subTest(text=repr(text)), self.assertRaises((ValueError, UnicodeError)):
                contract.validate_output(bad, self.input, self.checks)

    def test_native_static_depth_retains_image_clock_and_bounded_measurements(self):
        request = deepcopy(self.input)
        del request['bindings']
        request['images'][1]['timestampSeconds'] = 10
        measurements = {'status': 'available', 'sourceSHA256': 'a'*64,
            'imageSHA256': request['images'][1]['sha256'], 'frameTimestampSeconds': 10,
            'clockDomain': 'arkit_session_seconds', 'depth': {'sourceSHA256': 'b'*64,
                'imageTimestampSeconds': 10, 'depthTimestampSeconds': 9.99,
                'ageAtAdmissionSeconds': 0.03, 'mapWidth': 320, 'mapHeight': 240,
                'filtered': False, 'sampleCount': 100, 'residualRMSMetres': 0.002},
            'blink': {'completedAtSeconds': 9, 'ageSeconds': 1.02,
                'leftEyeClosed': 0.1, 'rightEyeClosed': 0.2, 'eyesOpen': True},
            'tracking': {'consecutiveFrames': 10, 'steadyHoldSeconds': 0.5}, 'motion': None,
            'quality': {'score': 0.8, 'revision': 3, 'insideGuide': True,
                'analysisDurationSeconds': 0.01, 'frameAgeAtAdmissionSeconds': 0.02}}
        request['context']['capture']['measurements'] = measurements
        contract.validate_input(request, self.checks)
        output = deepcopy(self.output)
        output['captureReview']['indicators'] = [{'indicator': 'depth_consistency',
            'status': 'present', 'evidence': 'Bound depth measurement is available.',
            'sourceImageIds': ['Media-2']}]
        contract.validate_output(output, request, self.checks)
        for field, value in [('imageSHA256', 'f'*64), ('frameTimestampSeconds', 11)]:
            bad = deepcopy(request)
            bad['context']['capture']['measurements'][field] = value
            with self.subTest(field=field), self.assertRaises(ValueError):
                contract.validate_input(bad, self.checks)
        model = contract.model_context(request)
        self.assertNotIn('sourceSHA256', model['capture']['measurements'])
        self.assertEqual(model['capture']['measurements']['depth']['residualRMSMetres'], 0.002)

    def test_core_motion_window_is_bound_and_cannot_claim_visual_temporal_cues(self):
        request = deepcopy(self.input)
        request['images'][1]['timestampSeconds'] = 10
        request['context']['capture']['measurements'] = {
            'status': 'available', 'sourceSHA256': 'a'*64,
            'imageSHA256': request['images'][1]['sha256'], 'frameTimestampSeconds': 10,
            'clockDomain': 'arkit_session_seconds', 'depth': None, 'blink': None,
            'tracking': None, 'quality': None,
            'motion': {'sourceSHA256': 'b'*64, 'frameTimestampSeconds': 10,
                'windowStartTimestampSeconds': 8, 'windowEndTimestampSeconds': 9.98,
                'requestedSampleRateHz': 50, 'clockDomain': 'core_motion_boot_seconds',
                'alignment': 'host_uptime_checked', 'summary': {
                    'ceremony': 'face_match', 'sampleCount': 100, 'durationSeconds': 1.98,
                    'accelerationRMSg': 0.02, 'rotationRMSRadPerSecond': 0.01,
                    'tremorBandRatio': 0.4, 'gravityDominantAxis': 'y',
                    'gravityDominance': 0.9, 'gravityDriftRadians': 0.01,
                    'approachRMSg': 0.03, 'settleRatio': 0.5,
                    'magneticDeltaMicrotesla': None, 'magnetometerCalibrated': False,
                    'rawWindowSHA256': 'c'*64}}}
        contract.validate_input(request, self.checks)
        for key, value in [('frameTimestampSeconds', 9), ('windowEndTimestampSeconds', 11)]:
            bad = deepcopy(request)
            bad['context']['capture']['measurements']['motion'][key] = value
            with self.subTest(key=key), self.assertRaises(ValueError):
                contract.validate_input(bad, self.checks)
        output = deepcopy(self.output)
        output['captureReview']['indicators'] = [{'indicator': 'camera_motion_consistency',
            'status': 'present', 'evidence': 'Motion supplied.', 'sourceImageIds': ['Media-2']}]
        with self.assertRaises(ValueError): contract.validate_output(output, request, self.checks)


if __name__ == '__main__':
    unittest.main()
