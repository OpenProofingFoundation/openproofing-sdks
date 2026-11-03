#!/usr/bin/env python3
"""Closed shared-motion provenance checks and executed SwiftPM test evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = 'foundation/motion'
PROVENANCE = DIRECTORY + '/sources.json'
SUMMARY = DIRECTORY + '/Sources/KenshikiMotion/PulseCeremonyMotionSummary.swift'
WITNESS = DIRECTORY + '/Sources/KenshikiMotion/PulseCeremonyMotionWitness.swift'
TEST = DIRECTORY + '/Tests/KenshikiMotionTests/PulseCeremonyMotionSummaryTests.swift'
TRACE = DIRECTORY + '/Sources/KenshikiMotion/PulseCeremonyMotionTrace.swift'
PERMISSION = DIRECTORY + '/Sources/KenshikiMotion/PulseMotionPermission.swift'
WITNESS_TEST = DIRECTORY + '/Tests/KenshikiMotionTests/PulseCeremonyMotionWitnessTests.swift'
PERMISSION_TEST = DIRECTORY + '/Tests/KenshikiMotionTests/PulseMotionPermissionTests.swift'
DONOR_REVISION = 'c77d87bacd166eabcc69e2de1afadbd8fa7d8de8'
DONOR_SHA256 = {
    SUMMARY: 'b544c0b87acb80b39fad51b17b947dc1d5d93ee495f949efc5089499aac89d06',
    WITNESS: '904f75eca209849643abb1a088dfc35c9c599c14e09500d1d3e9794d9a5b1995',
    TEST: '8e0be198230df7035649cebfc71ad826ee721c4e7946979396ee8ad871904a93',
    PERMISSION: '7b14195d01a06a9d98c6ceaa0655862be53191ea8cbbcff7378d16dfbebbd98d',
}
REQUIRED = {'KenshikiMotionTests.PulseCeremonyMotionSummaryTests.' + name for name in (
    'testDeadStillTraceHasZeroEnergyAndNoTremorRatio', 'testTenHertzTremorDominatesTheBandRatio',
    'testSlowSwayFallsOutsideTheTremorBand', 'testSettleRatioDropsWhenTheLastFifthOfASecondIsStill',
    'testGravityDriftIsTheAngleBetweenFirstAndLastVectors', 'testMagneticDeltaIsMaxMinusMin',
    'testMissingMagneticReferenceIsUnavailableNeverZero', 'testUnderOneSecondOfSamplesYieldsNoTremorRatio',
    'testHashIsDeterministicAndSensitiveToOneSample')}
REQUIRED |= {'KenshikiMotionTests.PulseCeremonyMotionWitnessTests.' + name for name in (
    'testCountAndTimePruningBoundActualRetainedSamples',
    'testCalibrationBelongsToSelectedWindowNotLaterSamples',
    'testFrameCutoffExcludesFutureSamplesAndStaleWindow',
    'testRetiredGenerationCannotAppendOrSurviveRestart',
    'testInvalidRatesNonfiniteOrReorderedSamplesAreRejected',
    'testStopRebasesTrimmedSamplesAndBoundsReturnedWallTime')}
REQUIRED |= {'KenshikiMotionTests.PulseMotionPermissionTests.' + name for name in (
    'testCancellationWhileRequestingPreventsQueryRegistration',
    'testCancelledAndReplacedQueriesCannotPublishLateResults',
    'testResolvedPermissionReturnsImmediatelyWithoutQuery')}


def validate(root=ROOT):
    record = json.loads((root/PROVENANCE).read_text())
    if record.get('schemaVersion') != 1 or record.get('donorRevision') != DONOR_REVISION:
        raise ValueError('Shared motion donor revision differs')
    files = record['files']
    expected = {DIRECTORY+'/Package.swift', SUMMARY, WITNESS, TEST, TRACE, PERMISSION, WITNESS_TEST, PERMISSION_TEST}
    if set(files) != expected:
        raise ValueError('Shared motion reviewed source inventory differs')
    actual = {p.relative_to(root).as_posix() for p in (root/DIRECTORY).rglob('*.swift')
              if '.build' not in p.parts and '.swiftpm' not in p.parts}
    if actual != expected:
        raise ValueError('Shared motion source inventory differs')
    for name, row in files.items():
        path = root/name
        if (path.is_symlink() or not path.is_file()
                or any((root/parent).is_symlink() for parent in Path(name).parents)
                or hashlib.sha256(path.read_bytes()).hexdigest() != row.get('destinationSHA256')):
            raise ValueError('Shared motion reviewed source digest differs: '+name)
        if name in DONOR_SHA256 and row.get('sourceSHA256') != DONOR_SHA256[name]:
            raise ValueError('Shared motion original donor digest differs: '+name)
        if name == SUMMARY and row['destinationSHA256'] != DONOR_SHA256[SUMMARY]:
            raise ValueError('Shared motion summary must remain the exact donor implementation')
        if name in {WITNESS, TEST} and not row.get('patches'):
            raise ValueError('Shared motion adaptation must retain patch provenance')
        if '/Sources/' in name:
            text = path.read_text()
            allowed = {'Foundation', 'CryptoKit'} if name == SUMMARY else {'Foundation', 'CoreMotion'}
            imports = set(re.findall(r'\bimport\s+(\w+)', text))
            if not imports <= allowed or re.search(r'\b(?:URLSession|UserDefaults|FileManager|UIKit|SwiftUI|Logger|NSLog|print)\b', text):
                raise ValueError('Shared motion cannot acquire UI, transport, storage or diagnostics')
    manifest = (root/DIRECTORY/'Package.swift').read_text()
    if re.search(r'\.(?:package|binaryTarget|plugin|unsafeFlags)\s*\(', manifest):
        raise ValueError('Shared motion package must remain independent of external dependencies')
    return expected | {PROVENANCE, DIRECTORY+'/check.py'}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guards', action='store_true')
    args = parser.parse_args()
    inputs = validate()
    if args.guards:
        print('PASS shared motion source, original-summary provenance and dependency boundary')
        return
    from importlib.util import module_from_spec, spec_from_file_location
    spec = spec_from_file_location('motion_native_evidence', ROOT/'quality/portrait_evidence.py')
    evidence = module_from_spec(spec)
    spec.loader.exec_module(evidence)
    output = ROOT/'.build/foundation-motion'
    output.mkdir(parents=True, exist_ok=True)
    before = {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in inputs}
    command = ['swift', 'test', '--package-path', str(ROOT/DIRECTORY), '--parallel', '--disable-swift-testing',
               '-Xswiftc', '-warnings-as-errors', '--xunit-output', str(output/'tests.xml')]
    with (output/'native.log').open('w') as log:
        result = subprocess.run(command, cwd=ROOT, text=True, stdout=log, stderr=subprocess.STDOUT)
    count, evidence_error = 0, None
    if result.returncode == 0:
        try:
            count = evidence.check_reports([output/'tests.xml'], REQUIRED)
        except ValueError as error:
            evidence_error = str(error)
    after = {name: hashlib.sha256((ROOT/name).read_bytes()).hexdigest() for name in inputs}
    passed = result.returncode == 0 and before == after and count >= len(REQUIRED)
    (output/'receipt.json').write_text(json.dumps({
        'recordedAt': datetime.now(timezone.utc).isoformat(), 'command': command,
        'sourceSHA256': before, 'sourceUnchanged': before == after, 'executedTests': count,
        'passed': passed, 'evidenceError': evidence_error,
        'scope': 'Executed shared motion math tests; no physical sensor acceptance.'
    }, indent=2)+'\n')
    print((output/'native.log').read_text())
    if not passed:
        raise SystemExit(result.returncode or 1)


if __name__ == '__main__':
    main()
