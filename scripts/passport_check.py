#!/usr/bin/env python3
"""Execute ported passport protocol and MRZ tests with source-bound, complete native evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
sys.path.insert(0, str(ROOT))
from check import require_python  # noqa: E402
from presentation_check import safe_path, simulator_destination  # noqa: E402
from quality.capture_evidence import required_ids, validate  # noqa: E402

HELPERS = {'SyntheticPACEPeer.swift', 'ReaderProtocolFixture.swift'}
SWIFT_GLOB = '*.swift'


def declared_test_ids(root=ROOT):
    test_sources = []
    for folder in ('PassportTests', 'PassportNFCTests', 'CaptureMRZTests'):
        for path in sorted((root/'passport/ios/Tests'/folder).glob(SWIFT_GLOB)):
            source = path.read_text()
            if path.name in HELPERS:
                if re.search(r'\b(?:class|struct)\s+\w+Tests\b|\bfunc\s+test\w*\s*\(|@Test\b', source):
                    raise ValueError('Passport helper may not hide executable test declarations')
            else:
                test_sources.append(source)
    return required_ids(json.loads((root/'passport/Gates/passport-tests.json').read_text()), test_sources)


def sources():
    paths = [ROOT/'passport/Package.swift', ROOT/'passport/Package.resolved',
             ROOT/'passport/Gates/passport-tests.json', ROOT/'passport/Gates/extraction-tests.json',
             Path(__file__), ROOT/'quality/capture_evidence.py']
    paths.extend((ROOT/'passport/ios').rglob(SWIFT_GLOB))
    paths.extend((ROOT/'passport/third-party/NFCPassportReader/Sources').rglob(SWIFT_GLOB))
    paths.append(ROOT/'passport/third-party/NFCPassportReader/Package.swift')
    paths.append(ROOT/'passport/third-party/NFCPassportReader/Package.resolved')
    paths.extend(ROOT/path for path in (
        'passport/Gates/extraction-sources.json', 'passport/Gates/passport-graph.json',
        'passport/third-party/NFCPassportReader/Sources/NFCPassportReader/Resources/PrivacyInfo.xcprivacy',
        'passport/third-party/NFCPassportReader/VENDORED.md',
        'passport/third-party/NFCPassportReader/LICENSE',
        'passport/third-party/NFCPassportReader/provenance.json',
        'passport/third-party/NFCPassportReader/import-manifest.json'))
    return {path.relative_to(ROOT).as_posix(): hashlib.sha256(safe_path(path).read_bytes()).hexdigest()
            for path in sorted(paths)}


def run(simulator_id=None):
    output = safe_path(ROOT/'.build/passport')
    output.mkdir(parents=True, exist_ok=True)
    attempt = Path(tempfile.mkdtemp(prefix='ios-', dir=output))
    result = attempt/'tests.xcresult'
    log_path = attempt/'execution.log'
    started_ns = time.time_ns()
    required = declared_test_ids()
    receipt = {'startedUTC': datetime.now(timezone.utc).isoformat(), 'sourceSHA256': sources(),
               'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
               'gitStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
               'host': platform.platform(), 'requiredIDs': sorted(required), 'passed': False,
               'scope': 'Synthetic passport cryptography, transport and MRZ execution; no physical NFC/camera or accessibility acceptance'}
    try:
        destination = simulator_destination() if simulator_id is None else 'platform=iOS Simulator,id='+simulator_id
        command = ['xcodebuild', '-scheme', 'KenshikiPassportSDK-Package', '-destination', destination,
                   '-derivedDataPath', str(attempt/'build'), '-resultBundlePath', str(result),
                   '-only-testing:PassportTests', '-only-testing:PassportNFCTests', '-only-testing:CaptureMRZTests', '-parallel-testing-enabled', 'NO',
                   '-collect-test-diagnostics', 'never', 'CODE_SIGNING_ALLOWED=NO', 'test']
        receipt['command'] = command
        receipt['destination'] = destination
        with log_path.open('w') as log:
            completed = subprocess.run(command, cwd=ROOT/'passport', stdout=log,
                                       stderr=subprocess.STDOUT, timeout=1800, check=False)
        if completed.returncode:
            raise ValueError('Native passport command failed: '+str(completed.returncode))
        payloads = {}
        for kind in ('summary', 'tests'):
            payloads[kind] = json.loads(subprocess.check_output(
                ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(result)], text=True))
            (attempt/(kind+'.json')).write_text(json.dumps(payloads[kind], indent=2)+'\n')
        receipt['executedIDs'] = validate(payloads['summary'], payloads['tests'], required, started_ns)
        receipt['toolchain'] = subprocess.check_output(['xcodebuild', '-version'], text=True)
        receipt['sdkVersion'] = subprocess.check_output(['xcrun', '--sdk', 'iphonesimulator', '--show-sdk-version'], text=True).strip()
        receipt['devicesAndConfigurations'] = payloads['summary'].get('devicesAndConfigurations', [])
        artifacts = sorted((attempt/'build/Build/Products').glob('Debug-iphonesimulator/*.xctest/*'))
        binaries = [path for path in artifacts if path.is_file() and path.name in {'PassportTests', 'PassportNFCTests', 'CaptureMRZTests'}]
        if {path.name for path in binaries} != {'PassportTests', 'PassportNFCTests', 'CaptureMRZTests'}:
            raise ValueError('Missing native passport test binary')
        receipt['artifactSHA256'] = {path.relative_to(attempt).as_posix(): hashlib.sha256(safe_path(path).read_bytes()).hexdigest()
                                     for path in binaries}
        receipt['endSourceSHA256'] = sources()
        if receipt['sourceSHA256'] != receipt['endSourceSHA256']:
            raise ValueError('Passport source inputs changed during execution')
        receipt['resultSHA256'] = {path.relative_to(attempt).as_posix(): hashlib.sha256(safe_path(path).read_bytes()).hexdigest()
                                   for path in sorted(result.rglob('*')) if path.is_file()}
        receipt['passed'] = True
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        receipt['error'] = type(error).__name__+': '+str(error)
    receipt['finishedUTC'] = datetime.now(timezone.utc).isoformat()
    if log_path.exists():
        receipt['logSHA256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()
    (attempt/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(('PASS' if receipt['passed'] else 'FAIL')+' iOS passport: '+str(attempt/'receipt.json'), flush=True)
    return 0 if receipt['passed'] else 1


if __name__ == '__main__':
    require_python()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--simulator-id')
    arguments = parser.parse_args()
    raise SystemExit(run(arguments.simulator_id))
