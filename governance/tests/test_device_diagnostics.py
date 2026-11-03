"""Developer transfer rejects stale responses and never interprets shell fragments."""
import json
from pathlib import Path
import unittest
import uuid

from scripts.pull_reference_diagnostics import MAXIMUM_BYTES, copy_command, parse_response


class DeviceDiagnosticsTests(unittest.TestCase):
    def test_stale_response_cannot_satisfy_a_new_request(self):
        request_id = uuid.uuid4()
        value = self.response(uuid.uuid4())
        self.assertIsNone(parse_response(json.dumps(value).encode(), request_id))
        value['requestID'] = str(request_id).upper()
        self.assertEqual(parse_response(json.dumps(value).encode(), request_id), value)

    def test_malformed_success_and_boolean_version_are_rejected(self):
        request_id = uuid.uuid4()
        for mutation in [{'version': True}, {'kind': 'other'}, {'status': 'pending'}, {'report': {}}]:
            value = self.response(request_id)
            value.update(mutation)
            with self.assertRaises(ValueError):
                parse_response(json.dumps(value).encode(), request_id)
        with self.assertRaises(ValueError):
            parse_response(b'x' * (MAXIMUM_BYTES + 1), request_id)

    def test_device_and_paths_are_literal_argv_without_shell_execution(self):
        device = 'SHF; $(touch /tmp/should-not-exist)'
        source = Path('/tmp/private report.json')
        command = copy_command(device, 'com.kenshiki.reference', 'to', source, 'Library/Caches/request.json')
        self.assertEqual(command[command.index('--device') + 1], device)
        self.assertEqual(command[command.index('--source') + 1], str(source))
        self.assertNotIn('sh', command)

    @staticmethod
    def response(request_id):
        return {'version': 1, 'kind': 'kenshiki.debug-comparison-response',
                'requestID': str(request_id).upper(), 'status': 'completed',
                'report': {'kind': 'kenshiki.face-comparison-report'}}
