#!/usr/bin/env python3
"""Qualify the independent Sensors package and preserve exact-source native evidence."""
import argparse
from datetime import datetime, timezone
import hashlib
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[2]
DIRECTORY = 'foundation/sensors'
PACKAGE_MANIFEST = DIRECTORY + '/Package.swift'
SWIFT_SUFFIX = '.swift'
CAPTURE_EVIDENCE = 'quality/capture_evidence.py'
INVENTORY = DIRECTORY + '/sources.json'
CORE_PROVENANCE = DIRECTORY + '/core-provenance.json'
CONTRACT = 'contracts/sensor-measurement-window-v1.md'
VECTORS = 'contracts/sensor-measurement-window-v1.vectors.json'
RESOURCE = DIRECTORY + '/Tests/KenshikiSensorsTests/Fixtures/sensor-measurement-window-v1.vectors.json'
CONSUMER_DIRECTORY = DIRECTORY + '/Integration/Consumer'
CONSUMER_MANIFEST = CONSUMER_DIRECTORY + '/Package.swift'
CONSUMER_SOURCE = CONSUMER_DIRECTORY + '/Sources/SensorsConsumer/main.swift'
CONSUMER_FILES = {CONSUMER_MANIFEST, CONSUMER_SOURCE}
CONSUMER_SOURCE_SHA256 = '97b19e43689edaf219f2777f358c7ee91a2d2a7b8530b98f574f9e0f36b2c988'
CONSUMER_OUTPUT = '''{"schemaVersion":1,"consumer":"SensorsConsumer","passed":true,
"assertions":["observed-window","complete-coverage","r7-median","rms",
"half-open-routing","partial-window","invalid-distribution-rejected"]}
'''
SOURCE_NAMES = (
    'SensorVector3', 'EmpiricalDistribution', 'SensorSampleTime', 'SensorWindowTiming',
    'SensorTemporalSummary', 'BoundedSensorWindow', 'DeviceMotionAggregate',
    'RecordedAccelerationAggregate', 'RecordedAccelerationWindow',
    'SensorMeasurement', 'SensorEvidenceWindow', 'SensorDerivationBinding',
)
TEST_NAMES = ('SensorWindowTimingTests', 'SensorTemporalSummaryTests', 'MotionAggregateReducerTests', 'RecordedAccelerationWindowTests', 'SensorEvidenceContractTests', 'SensorCoreIntegrationTests')
SWIFT_FILES = {PACKAGE_MANIFEST} | {
    DIRECTORY+'/Sources/KenshikiSensors/'+name+SWIFT_SUFFIX for name in SOURCE_NAMES
} | {DIRECTORY+'/Tests/KenshikiSensorsTests/'+name+SWIFT_SUFFIX for name in TEST_NAMES}
EXPECTED_FILES = SWIFT_FILES | CONSUMER_FILES | {CORE_PROVENANCE, CONTRACT, VECTORS, RESOURCE}
DONOR_REVISION = 'd6d544a75d3b79106eb8224a6f93f0b7536d2e2f'
# Original source identities are immutable; adapted destinations remain separately reviewed.
DONOR_SHA256 = {'foundation/sensors/Sources/KenshikiSensors/BoundedSensorWindow.swift': '3e7b2aebc758615ab9e03a87c3cc660a65aafaede537f329fea77bf15aa8b88e',
 'foundation/sensors/Sources/KenshikiSensors/DeviceMotionAggregate.swift': '5e4e794f05c9f52847edbf616b8fbe29625ba34bbb746bb3953b42cc909d0abf',
 'foundation/sensors/Sources/KenshikiSensors/EmpiricalDistribution.swift': '8b51154d679500df442e410aab4d0e3bab3b61b793636b420f3d5324a36d74ae',
 'foundation/sensors/Sources/KenshikiSensors/RecordedAccelerationAggregate.swift': 'f8bafb2cbd51df4cd30a2d557453f940bc0bbf5be8555a2cc1f53d1517f276d4',
 'foundation/sensors/Sources/KenshikiSensors/RecordedAccelerationWindow.swift': '229df1b7684a7eac084e2f1184311c71d0aec0ee0de85c802611dd59e8dbadb6',
 'foundation/sensors/Sources/KenshikiSensors/SensorSampleTime.swift': '50f35ac3797943581653a37527750b764186ccdb5ec9784adb69d0a9f7de4054',
 'foundation/sensors/Sources/KenshikiSensors/SensorTemporalSummary.swift': 'dbb2c5ee9b5f28eb5b2f1eb8314a94a6a301073652697a4010f4434d07bd092d',
 'foundation/sensors/Sources/KenshikiSensors/SensorVector3.swift': 'ba980817ee4fe8b22460eccdc5df335da56a9b3c8f07d31772577cc3e2dbc716',
 'foundation/sensors/Sources/KenshikiSensors/SensorWindowTiming.swift': '77527f4c6e9200b09ece7b95ac4dae04f56de37b0015fadb5493524b6442df86',
 'foundation/sensors/Tests/KenshikiSensorsTests/MotionAggregateReducerTests.swift': 'ca2c520ea73b56d6644c94455d0736301a60d91ed7020d16cfac40b844fe7c7b',
 'foundation/sensors/Tests/KenshikiSensorsTests/RecordedAccelerationWindowTests.swift': '713a6050c8be57af4785839dd067827db139317f93cb5928f1fa906f08f0467b',
 'foundation/sensors/Tests/KenshikiSensorsTests/SensorTemporalSummaryTests.swift': 'e135ae809ab653d008cfa309bbb022e26b9a23178f2c97b207c6bb9008f810ac',
 'foundation/sensors/Tests/KenshikiSensorsTests/SensorWindowTimingTests.swift': 'a31e5ba31c85830f657ec02953219b5bbaa81cf0c1678c53729b270ce4176262'}
REQUIRED = {
    'MotionAggregateReducerTests.testDeviceMotionRejectsMixedReferenceFrames',
    'MotionAggregateReducerTests.testDeviceMotionUsesUnmodifiedAppleProcessedMagnitudes',
    'MotionAggregateReducerTests.testRecordedAccelerationRetainsEverySampleWhileCompactlyProvenancingBatches',
    'RecordedAccelerationWindowTests.testCompleteFiftyHertzMinuteIsObserved',
    'RecordedAccelerationWindowTests.testConflictingSampleIdentityIsRejectedWithoutInputOrderChoosingEvidence',
    'RecordedAccelerationWindowTests.testFiniteWallDateBeyondBinPrecisionIsUnroutable',
    'RecordedAccelerationWindowTests.testHalfOpenBoundaryAndCutoffOnlyFinalizeClosedBins',
    'RecordedAccelerationWindowTests.testInternalGapAndMissingSupportArePartial',
    'RecordedAccelerationWindowTests.testInvalidWallDatesAreReportedAsUnroutable',
    'RecordedAccelerationWindowTests.testSensorTimestampRegressionIsReportedWithoutReplacingWallClockTiming',
    'RecordedAccelerationWindowTests.testSignedZeroOrderingIsBitDeterministic',
    'RecordedAccelerationWindowTests.testSortsDeduplicatesAndReportsActualBounds',
    'RecordedAccelerationWindowTests.testStationaryRecordedAccelerationPreservesRawGravityNearOneG',
    'SensorCoreIntegrationTests.testLiveAndHistoricalRawPipelinesReconcileTimingAndKeepGravityUnits',
    'SensorCoreIntegrationTests.testMissingSequencePropagatesPartialTimingAndOmissionLineage',
    'SensorCoreIntegrationTests.testReplaySessionMutationAndBoundaryCannotPolluteAcceptedSamples',
    'SensorCoreIntegrationTests.testRetainedAtomsDriveAggregateAndRejectConflictingRebinding',
    'SensorEvidenceContractTests.testArtifactCommitmentShapeIsStrict',
    'SensorEvidenceContractTests.testCanonicalUnicodeInputIdentitiesAndSelectorsAreDeduplicated',
    'SensorEvidenceContractTests.testCanonicalUnicodeRecordsAllowDistinctSelectorsAndSeparateRecords',
    'SensorEvidenceContractTests.testClockCorrelationsCannotSubstituteSessionOrClockKind',
    'SensorEvidenceContractTests.testCollectionAndNominalPeriodBoundsAreEnforced',
    'SensorEvidenceContractTests.testCompleteDecisionManifestPreservesNegativeInputsAndOrder',
    'SensorEvidenceContractTests.testComposedMeasurementsAllowConsistentRecordReuse',
    'SensorEvidenceContractTests.testComposedMeasurementsRejectConflictingRecordCommitments',
    'SensorEvidenceContractTests.testConflictingCommitmentsAndDuplicateInputsAreRefused',
    'SensorEvidenceContractTests.testDerivedMeasurementsRequireImmutableMethodBinding',
    'SensorEvidenceContractTests.testDuplicateSampleIdentitiesAreRefused',
    'SensorEvidenceContractTests.testFineSignedValuesPreserveBitsWithoutClaimingResolution',
    'SensorEvidenceContractTests.testForeignReceiptClockRequiresCorrelationOrExplicitOmission',
    'SensorEvidenceContractTests.testFrameTransformRequiresDerivedOriginAndSourceFrame',
    'SensorEvidenceContractTests.testInputExtentsRetainDomainsWithoutReidentifyingDuplicateEvidence',
    'SensorEvidenceContractTests.testMaximumWindowResolvesLateGapAndClockOmissions',
    'SensorEvidenceContractTests.testOmissionIntervalsCannotCrossSessionOrWindowBounds',
    'SensorEvidenceContractTests.testRawAndAggregateRetentionRemainExplicit',
    'SensorEvidenceContractTests.testRejectsNonFiniteMeasurementsAndIntervals',
    'SensorEvidenceContractTests.testSequenceGapsRequireExplicitPartialEvidence',
    'SensorEvidenceContractTests.testSharedConformanceVectors',
    'SensorEvidenceContractTests.testVectorShapeAndPointDerivationAreExplicit',
    'SensorEvidenceContractTests.testWindowRejectsMixedDomainsFramesUnitsAndOrder',
    'SensorEvidenceContractTests.testWindowRequiresExactCalibrationAndTransformationDescriptors',
    'SensorEvidenceContractTests.testWindowsRejectCrossSampleCommitmentConflicts',
    'SensorTemporalSummaryTests.testCountThresholdIsInclusiveAtNinetyFivePercent',
    'SensorTemporalSummaryTests.testCoverageThresholdIsInclusiveAndRejectsBelowByEpsilon',
    'SensorTemporalSummaryTests.testLiveAndRecordedRoutesProduceEquivalentTemporalEvidence',
    'SensorTemporalSummaryTests.testMaximumGapThresholdIsInclusiveAndRejectsAboveByEpsilon',
    'SensorTemporalSummaryTests.testTranslationAcrossNegativeAndPositiveClockDomainsPreservesSummary',
    'SensorWindowTimingTests.testDuplicateAndInvalidSamplesDoNotAffectMeasurementsOrCoverage',
    'SensorWindowTimingTests.testEmpiricalDistributionPinsR7Quantiles',
    'SensorWindowTimingTests.testExtremeFiniteTimestampIsInvalidWithoutClosingTheActiveWindow',
    'SensorWindowTimingTests.testHalfOpenBoundaryRoutesExactMinuteToNextWindow',
    'SensorWindowTimingTests.testInternalLossCannotEarnObservedQuality',
    'SensorWindowTimingTests.testIsolatedCallbackIsPartialRatherThanObserved',
    'SensorWindowTimingTests.testMaximumNominalCountRemainsRepresentable',
    'SensorWindowTimingTests.testPerfectOneHertzWindowIsObserved',
    'SensorWindowTimingTests.testSourceSessionDecodingRejectsEmptyIdentityAndPreservesWireShape',
    'SensorWindowTimingTests.testUnrepresentableWallProjectionCannotOpenAWindow',
    'SensorWindowTimingTests.testWallClockJumpDoesNotChangeWindowRouting',
}
EXACT_DONOR_NAMES = {'SensorVector3.swift', 'EmpiricalDistribution.swift', 'SensorTemporalSummary.swift'}


def load_module(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def strict_json(path):
    def pairs(items):
        result = {}
        for key, value in items:
            if key in result:
                raise ValueError('Duplicate Sensors JSON key: '+key)
            result[key] = value
        return result
    return json.loads(path.read_text(), object_pairs_hook=pairs)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def checked_file(root, name):
    path = root/name
    if (Path(name).is_absolute() or '..' in Path(name).parts or not path.is_file()
            or path.is_symlink() or any((root/parent).is_symlink() for parent in Path(name).parents)):
        raise ValueError('Sensors input unavailable or redirected: '+name)
    return path


def _reviewed_inventory(root):
    record = strict_json(checked_file(root, INVENTORY))
    if (set(record) != {'schemaVersion', 'module', 'files', 'requiredIDs'}
            or type(record['schemaVersion']) is not int or record['schemaVersion'] != 1 or record['module'] != 'KenshikiSensors'
            or set(record['files']) != EXPECTED_FILES):
        raise ValueError('Sensors reviewed file inventory differs')
    if not REQUIRED or set(record['requiredIDs']) != REQUIRED or len(record['requiredIDs']) != len(REQUIRED):
        raise ValueError('Sensors required test inventory differs')
    for name, expected_hash in record['files'].items():
        if not isinstance(expected_hash, str) or not re.fullmatch(r'[0-9a-f]{64}', expected_hash):
            raise ValueError('Invalid Sensors source digest')
        if digest(checked_file(root, name)) != expected_hash:
            raise ValueError('Sensors reviewed source digest differs: '+name)
    return record


def _declared_source_files(root):
    """Enumerate every source/resource input, including hidden and non-Swift files."""
    actual = set()
    for folder in ('Sources', 'Tests'):
        for path in (root/DIRECTORY/folder).rglob('*'):
            if path.is_symlink():
                raise ValueError('Sensors source symlink')
            if path.is_file():
                actual.add(path.relative_to(root).as_posix())
    return actual


def _validate_source_inventory(root):
    if _declared_source_files(root) != (SWIFT_FILES - {PACKAGE_MANIFEST}) | {RESOURCE}:
        raise ValueError('Sensors source/resource inventory differs')
    actual_native = {p.relative_to(root).as_posix() for p in (root/DIRECTORY).rglob('*')
                     if p.suffix in {SWIFT_SUFFIX, '.c', '.h', '.cpp', '.m', '.mm', '.hpp', '.kt', '.java'}
                     and not {'.build', '.swiftpm', '__pycache__'} & set(p.parts)}
    if actual_native != SWIFT_FILES | CONSUMER_FILES:
        raise ValueError('Sensors native source inventory differs')


def _validate_independent_manifest(root):
    # This package has one deliberately fixed graph. Comparing the complete reviewed
    # manifest also refuses aliases, dynamic expressions and alternate Swift syntax
    # that token matching cannot reliably classify without executing the manifest.
    expected = '''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "KenshikiSensors",
    platforms: [.iOS(.v18), .macOS(.v13)],
    products: [.library(name: "KenshikiSensors", targets: ["KenshikiSensors"])],
    targets: [
        .target(name: "KenshikiSensors"),
        .testTarget(
            name: "KenshikiSensorsTests",
            dependencies: ["KenshikiSensors"],
            resources: [.process("Fixtures")]
        ),
    ]
)
'''
    manifest = (root/PACKAGE_MANIFEST).read_text()
    if manifest != expected:
        raise ValueError('Sensors must remain one independent headless product without external dependencies')


def _validate_import_boundary(root):
    for name in SWIFT_FILES - {PACKAGE_MANIFEST}:
        text = (root/name).read_text()
        allowed = {'Foundation', 'CryptoKit'} if '/Sources/' in name else {'Foundation', 'XCTest', 'KenshikiSensors'}
        if name == DIRECTORY+'/Tests/KenshikiSensorsTests/SensorCoreIntegrationTests.swift':
            allowed.add('CryptoKit')
        imports = set(re.findall(r'\bimport\s+(\w+)', text))
        if not imports <= allowed:
            raise ValueError('Sensors depends on unreviewed module: '+name)
        if '/Sources/' in name and re.search(r'\b(?:URLSession|UserDefaults|FileManager|UIKit|SwiftUI|CoreMotion|Logger|NSLog|print)\b', text):
            raise ValueError('Sensors cannot acquire platform collection, UI, transport or storage: '+name)


def _validate_consumer_fixture(root):
    actual = set()
    for path in (root/DIRECTORY/'Integration').rglob('*'):
        if path.is_symlink():
            raise ValueError('Sensors external consumer input redirected')
        if path.is_file():
            actual.add(path.relative_to(root).as_posix())
    if actual != CONSUMER_FILES:
        raise ValueError('Sensors external consumer inventory differs')
    expected_manifest = '''// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "SensorsConsumer",
  platforms: [.macOS(.v13)],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "SensorsConsumer",
      dependencies: [.product(name: "KenshikiSensors", package: "sensors")]
    )
  ]
)
'''
    if checked_file(root, CONSUMER_MANIFEST).read_text() != expected_manifest:
        raise ValueError('Sensors external consumer must select only the reviewed local product')
    source = checked_file(root, CONSUMER_SOURCE)
    imports = set(re.findall(r'\bimport\s+(\w+)', source.read_text()))
    if imports != {'Foundation', 'KenshikiSensors'} or '@testable' in source.read_text():
        raise ValueError('Sensors external consumer must use only the public Sensors API')
    if digest(source) != CONSUMER_SOURCE_SHA256:
        raise ValueError('Sensors external consumer reviewed assertions changed')


def _validate_core_provenance(root, files):
    provenance = strict_json(root/CORE_PROVENANCE)
    rows = provenance.get('files', [])
    if (provenance.get('schemaVersion') != 1 or provenance.get('donorRevision') != DONOR_REVISION
            or len(rows) != len(DONOR_SHA256) or {row.get('destinationPath') for row in rows} != set(DONOR_SHA256)):
        raise ValueError('Sensors original extraction provenance differs')
    for row in rows:
        name = row['destinationPath']
        if (row.get('sourceSHA256') != DONOR_SHA256[name] or not row.get('adaptations')
                or row.get('destinationSHA256') != files[name]):
            raise ValueError('Sensors original donor identity or adaptation attribution differs')
        if Path(name).name in EXACT_DONOR_NAMES and row['destinationSHA256'] != row['sourceSHA256']:
            raise ValueError('Sensors exact donor implementation changed')


def _validate_vectors_and_tests(root):
    if (root/VECTORS).read_bytes() != (root/RESOURCE).read_bytes():
        raise ValueError('Sensors executable vectors differ from canonical contract')
    capture = load_module('sensors_required_tests', ROOT/CAPTURE_EVIDENCE)
    capture.required_ids({'schemaVersion': 1, 'requiredIDs': sorted(REQUIRED)},
                         [(root/DIRECTORY/'Tests/KenshikiSensorsTests'/(name+SWIFT_SUFFIX)).read_text()
                          for name in TEST_NAMES])


def validate(root=ROOT):
    record = _reviewed_inventory(root)
    _validate_source_inventory(root)
    _validate_independent_manifest(root)
    _validate_import_boundary(root)
    _validate_consumer_fixture(root)
    _validate_core_provenance(root, record['files'])
    _validate_vectors_and_tests(root)
    return EXPECTED_FILES | {INVENTORY, DIRECTORY+'/check.py'}


def simulator_destination(value):
    shared = load_module('sensors_foundation_destination', ROOT/'foundation/scripts/check.py')
    return shared.simulator_destination(value)


def native_command(lane, attempt, destination):
    if lane == 'macos':
        return ['swift', 'test', '--package-path', str(ROOT/DIRECTORY),
                '--scratch-path', str(ROOT/'.build/sensors-qualification-swiftpm'),
                '--parallel', '--disable-swift-testing', '-Xswiftc', '-warnings-as-errors',
                '--xunit-output', str(attempt/'tests.xml')]
    command = ['xcodebuild', '-scheme', 'KenshikiSensors', '-destination',
               'generic/platform=iOS' if lane == 'ios-device' else destination,
               '-derivedDataPath', str(attempt/'build'), 'CODE_SIGNING_ALLOWED=NO',
               'SWIFT_TREAT_WARNINGS_AS_ERRORS=YES', 'SWIFT_STRICT_CONCURRENCY=complete']
    if lane == 'ios-device':
        return command + ['build']
    return command + ['-parallel-testing-enabled', 'NO', '-resultBundlePath', str(attempt/'tests.xcresult'),
                      '-collect-test-diagnostics', 'never', 'test']


def execution_ids(lane, attempt, started):
    if lane == 'ios-device':
        return []
    if lane == 'macos':
        evidence = load_module('sensors_macos_evidence', ROOT/'quality/portrait_evidence.py')
        required = {'KenshikiSensorsTests.'+name for name in REQUIRED}
        count = evidence.check_reports([attempt/'tests.xml'], required)
        # The closed manifest also refuses extra/duplicate/missing declared methods.
        if count != len(REQUIRED):
            raise ValueError('Sensors macOS executed test count differs from closed inventory')
        return sorted(REQUIRED)
    payloads = {}
    for kind in ('summary', 'tests'):
        payloads[kind] = json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(attempt/'tests.xcresult')], text=True))
        (attempt/(kind+'.json')).write_text(json.dumps(payloads[kind], indent=2)+'\n')
    evidence = load_module('sensors_ios_evidence', ROOT/CAPTURE_EVIDENCE)
    ids = evidence.validate(payloads['summary'], payloads['tests'], REQUIRED, started)
    if set(ids) != REQUIRED:
        raise ValueError('Sensors iOS executed IDs differ from closed inventory')
    return ids


def module_folder(lane, attempt):
    if lane == 'macos':
        return Path(subprocess.check_output(['swift', 'build', '--package-path', str(ROOT/DIRECTORY),
            '--scratch-path', str(ROOT/'.build/sensors-qualification-swiftpm'), '--show-bin-path'],
            cwd=ROOT, text=True).strip())/'Modules'
    sdk = 'iphoneos' if lane == 'ios-device' else 'iphonesimulator'
    return attempt/'build/Build/Products'/('Debug-'+sdk)


def compiled_artifacts(lane, folder):
    artifact_root = folder.parent if lane == 'macos' else folder
    artifacts = {}
    for path in sorted(artifact_root.rglob('*')):
        relative = path.relative_to(artifact_root)
        if not any(part.startswith('KenshikiSensors') for part in relative.parts):
            continue
        if path.is_symlink():
            raise ValueError('Sensors compiled artifact symlink')
        if path.is_file():
            artifacts[relative.as_posix()] = digest(path)
    if not artifacts or (lane == 'macos' and not any('.xctest/' in name for name in artifacts)):
        raise ValueError('Sensors compiled execution artifacts unavailable')
    return artifacts


def consumer_build_command(scratch):
    return ['swift', 'build', '--package-path', str(ROOT/CONSUMER_DIRECTORY),
            '--scratch-path', str(scratch), '--product', 'SensorsConsumer',
            '-Xswiftc', '-warnings-as-errors']


def run_external_consumer(attempt, record):
    """Build a separate product consumer, then execute its exact fresh binary."""
    _validate_consumer_fixture(ROOT)
    scratch = attempt.resolve()/'consumer-build'
    scratch.mkdir()  # Refuse preexisting output, including symlinks and cached binaries.
    command = consumer_build_command(scratch)
    record.update({'passed': False, 'buildCommand': command})
    build_log = attempt/'consumer-build.log'
    with build_log.open('w') as stream:
        subprocess.run(command, cwd=ROOT/CONSUMER_DIRECTORY, stdout=stream,
                       stderr=subprocess.STDOUT, timeout=600, check=True)
    record['buildLogSHA256'] = digest(build_log)
    folder = Path(subprocess.check_output(
        ['swift', 'build', '--package-path', str(ROOT/CONSUMER_DIRECTORY),
         '--scratch-path', str(scratch), '--show-bin-path'], text=True).strip())
    binary = checked_file(scratch, (folder/'SensorsConsumer').relative_to(scratch).as_posix())
    before = digest(binary)
    record['command'] = [str(binary)]
    result = subprocess.run(record['command'], cwd=ROOT/CONSUMER_DIRECTORY,
                            capture_output=True, text=True, timeout=60, check=False)
    stdout, stderr = attempt/'consumer.stdout.json', attempt/'consumer.stderr.log'
    stdout.write_text(result.stdout)
    stderr.write_text(result.stderr)
    record.update({'returncode': result.returncode, 'stdoutSHA256': digest(stdout),
                   'stderrSHA256': digest(stderr), 'binaryPath': binary.relative_to(attempt.resolve()).as_posix(),
                   'binarySHA256': before, 'endBinarySHA256': digest(binary)})
    result.check_returncode()
    if result.stdout != CONSUMER_OUTPUT or result.stderr or record['endBinarySHA256'] != before:
        raise ValueError('Sensors external consumer execution outcome or binary differs')
    record.update({'outcome': strict_json(stdout), 'passed': True})


def qualify(args):
    inputs = validate() | {CAPTURE_EVIDENCE, 'quality/portrait_evidence.py',
                          'quality/public_api.py', 'scripts/check.py', '.python-version'}
    before = {name: digest(ROOT/name) for name in sorted(inputs)}
    output = ROOT/'.build/sensors-qualification'
    output.mkdir(parents=True, exist_ok=True)
    attempt = Path(tempfile.mkdtemp(prefix=args.platform+'-', dir=output))
    receipt = {'schemaVersion': 1, 'startedUTC': datetime.now(timezone.utc).isoformat(),
               'platform': args.platform, 'sourceSHA256': before, 'requiredIDs': sorted(REQUIRED),
               'passed': False, 'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
               'gitStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
               'scope': 'Independent Sensors math/contracts, compiled public API and native execution; no physical acquisition or app adoption'}
    log = attempt/'execution.log'
    try:
        command = native_command(args.platform, attempt, args.destination)
        receipt['command'] = command
        sdk = {'macos': 'macosx', 'ios-device': 'iphoneos', 'ios-simulator': 'iphonesimulator'}[args.platform]
        receipt['toolchain'] = {
            'swift': subprocess.check_output(['swift', '--version'], text=True).strip(),
            'xcode': subprocess.check_output(['xcodebuild', '-version'], text=True).strip(),
            'sdkPath': subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-path'], text=True).strip(),
            'sdkVersion': subprocess.check_output(['xcrun', '--sdk', sdk, '--show-sdk-version'], text=True).strip(),
        }
        started = time.time_ns()
        with log.open('w') as stream:
            subprocess.run(command, cwd=ROOT/DIRECTORY, stdout=stream, stderr=subprocess.STDOUT,
                           timeout=1800, check=True)
        receipt['executedIDs'] = execution_ids(args.platform, attempt, started)
        receipt['executedTests'] = len(receipt['executedIDs'])
        api_tool = load_module('sensors_public_api', ROOT/'quality/public_api.py')
        folder = module_folder(args.platform, attempt)
        actual_api = api_tool.swift_surface(ROOT/DIRECTORY, {'swiftModule': 'KenshikiSensors'},
                                           args.platform, module_folder=folder)
        api = ROOT/DIRECTORY/'api'/(args.platform+'.json')
        if args.write_api:
            api.parent.mkdir(parents=True, exist_ok=True)
            api.write_text(json.dumps(actual_api, indent=2, sort_keys=True)+'\n')
        elif not api.is_file() or strict_json(api) != actual_api:
            raise ValueError('Sensors compiler-derived public API drift')
        receipt['apiSHA256'] = digest(api)
        receipt['artifactSHA256'] = compiled_artifacts(args.platform, folder)
        if args.platform == 'macos':
            receipt['externalConsumer'] = {'passed': False}
            run_external_consumer(attempt, receipt['externalConsumer'])
        after = {name: digest(ROOT/name) for name in sorted(inputs)}
        receipt['endSourceSHA256'] = after
        receipt['sourceUnchanged'] = before == after
        if before != after:
            raise ValueError('Sensors source changed during qualification')
        validate()
        receipt['passed'] = True
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        receipt['error'] = type(error).__name__+': '+str(error)
    receipt['finishedUTC'] = datetime.now(timezone.utc).isoformat()
    if log.is_file():
        receipt['logSHA256'] = digest(log)
    (attempt/'receipt.json').write_text(json.dumps(receipt, indent=2)+'\n')
    print(('PASS ' if receipt['passed'] else 'FAIL ')+str(attempt/'receipt.json'))
    return int(not receipt['passed'])


def main():
    load_module('sensors_root_validation', ROOT/'scripts/check.py').require_python()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--guards', action='store_true')
    parser.add_argument('--platform', choices=('macos', 'ios-device', 'ios-simulator'), default='macos')
    parser.add_argument('--destination', type=simulator_destination, default='platform=iOS Simulator,name=iPhone 17 Pro')
    parser.add_argument('--write-api', action='store_true', help='Explicit initial API authoring; never a CI option')
    args = parser.parse_args()
    if args.guards:
        validate()
        print('PASS Sensors closed source, dependency, provenance, vector and required-test contracts')
        return 0
    return qualify(args)


if __name__ == '__main__':
    raise SystemExit(main())
