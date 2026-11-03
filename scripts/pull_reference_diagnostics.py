"""Retrieve a committed comparison report from a foreground debug app.

Document DOB and current-age candidate input fields are redacted; age-pass results
remain present. Recorded input hashes refer to the original, unredacted evidence,
so the exported input projection is not an exact request replay.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import uuid

DIRECTORY = 'Library/Caches/KenshikiDiagnostics'
MAXIMUM_BYTES = 4 * 1024 * 1024


def parse_response(data, request_id):
    if len(data) > MAXIMUM_BYTES:
        raise ValueError('Diagnostic response exceeds its byte limit')
    value = json.loads(data)
    if not isinstance(value, dict):
        raise ValueError('Invalid diagnostic response')
    if value.get('requestID') != str(request_id).upper():
        return None
    if (type(value.get('version')) is not int or value['version'] != 1
            or value.get('kind') != 'kenshiki.debug-comparison-response'):
        raise ValueError('Unsupported diagnostic response')
    if value.get('status') == 'completed':
        report = value.get('report')
        if not isinstance(report, dict) or report.get('kind') != 'kenshiki.face-comparison-report':
            raise ValueError('Missing comparison report')
    elif value.get('status') == 'failed':
        if not isinstance(value.get('errorCode'), str) or len(value['errorCode']) > 64:
            raise ValueError('Invalid diagnostic failure')
    else:
        raise ValueError('Invalid diagnostic status')
    return value


def copy_command(device, bundle_id, direction, source, destination):
    return ['xcrun', 'devicectl', '--timeout', '20', 'device', 'copy', direction,
            '--device', device, '--domain-type', 'appDataContainer',
            '--domain-identifier', bundle_id, '--source', str(source),
            '--destination', str(destination)]


def pull(device, bundle_id, output, operation_id=None, timeout=240):
    request_id = uuid.uuid4()
    request = {'version': 1, 'requestID': str(request_id).upper()}
    if operation_id is not None:
        request['operationID'] = str(operation_id).upper()
    output = Path(output)
    output.parent.mkdir(parents=True, exist_ok=True)
    # Keep the final rename on the destination filesystem and intermediate responses private.
    with tempfile.TemporaryDirectory(prefix='.kenshiki-diagnostics-', dir=output.parent) as temporary:
        folder = Path(temporary)
        request_file = folder/'request.json'
        request_file.write_text(json.dumps(request))
        request_file.chmod(0o600)
        response_file = folder/'response.json'
        result = subprocess.run(copy_command(device, bundle_id, 'to', request_file, DIRECTORY+'/request.json'),
                                capture_output=True, text=True, timeout=25)
        if result.returncode:
            raise RuntimeError('Cannot deliver diagnostic request; the installed debug app must be open')
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            response_file.unlink(missing_ok=True)
            try:
                result = subprocess.run(copy_command(device, bundle_id, 'from', DIRECTORY+'/response.json', response_file),
                                        capture_output=True, text=True, timeout=25)
            except subprocess.TimeoutExpired:
                result = None
            if result is not None and result.returncode == 0 and response_file.is_file():
                if response_file.stat().st_size > MAXIMUM_BYTES:
                    raise ValueError('Diagnostic response exceeds its byte limit')
                value = parse_response(response_file.read_bytes(), request_id)
                if value is not None:
                    response_file.chmod(0o600)
                    os.replace(response_file, output)
                    return value
            time.sleep(1)
    raise TimeoutError('No matching diagnostic response; keep the debug app foregrounded until inference settles')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--device', required=True)
    parser.add_argument('--bundle-id', default='com.kenshiki.reference')
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--operation-id', type=uuid.UUID)
    parser.add_argument('--timeout', type=int, default=240, choices=range(1, 601), metavar='1..600')
    args = parser.parse_args()
    try:
        value = pull(args.device, args.bundle_id, args.output, args.operation_id, args.timeout)
        if value['status'] == 'failed':
            parser.exit(1, 'Device export failed: '+value['errorCode']+'; response saved to '+str(args.output)+'\n')
        print('Saved committed comparison JSON to '+str(args.output))
    except (OSError, ValueError, RuntimeError, TimeoutError, subprocess.TimeoutExpired) as error:
        parser.exit(1, str(error)+'\n')


if __name__ == '__main__':
    main()
