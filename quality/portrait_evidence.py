"""Require executed native portrait/math/lifecycle tests, not only a green test command."""
import argparse
from pathlib import Path
import xml.etree.ElementTree as ET


SWIFT_REQUIRED = {
    'PrimitiveTests.PortraitContractTests.' + name for name in (
        'testAllSharedVectorsExecuteNativeContracts',
        'testDirectLayoutRejectsUntrustedMetadataBeforeDigestValidation',
        'testOwnedSnapshotSurvivesCallerAndReturnedArrayMutation',
        'testWireIntegerIngressRejectsBeyondSigned64WithoutNarrowing',
        'testExtremeMetadataCannotOverflowOrTriggerAllocation',
        'testObservationsRejectForeignModelAndDocumentDomain')
} | {'PrimitiveTests.SharedEmbeddingVectorsTests.testSharedNumericalAndFailureVectors'} | {
    'PrimitiveTests.ComparisonOperationFenceTests.' + name for name in (
        'testUnsubmittedDuplicateAndReusedCompletionsCannotPublish',
        'testEveryForeignBindingLeavesOriginalRequestOutstanding',
        'testReentrantCancellationCannotResurrectCancelledOperation',
        'testForeignCancellationDoesNotInvalidateLiveRequest',
        'testConcurrentDuplicateCompletionHasExactlyOneWinner',
        'testThrowingCancellationCannotRestoreOutstandingRequest')
}
SWIFT_REQUIRED |= {'InferenceTests.AuraFaceComparisonTests.' + name for name in (
    'testSubstitutedSourceRejectedBeforeModelAccess',
    'testMalformedImageRejectedBeforeModelAccess',
    'testEmptyImageRejected',
    'testBlankImageDoesNotProduceSimilarity')}
SWIFT_REQUIRED |= {'InferenceTests.AuraFaceComparisonTests.' + name for name in (
    'testPreflightRejectsSubstitutedSourceWithoutModelAccess',
    'testPreflightRejectsMalformedImageWithoutModelAccess',
    'testPreflightRejectsEmptyAndOversizedEncodingBeforeSourceHash',
    'testPreflightRejectsOversizedDimensionsBeforeFaceDetection',
    'testPreflightRejectsNoFaceWithoutRequiringEmbeddingModel',
    'testCancelledPreflightRefusesBeforeSourceProcessing')}
# Historical Liquid validation now executes in the app-owned archive test suite.
SWIFT_REQUIRED |= {'InferenceTests.FaceFrameSelectionTests.' + name for name in (
    'testBothPoliciesUseOriginalIndexAndNativeScoreThroughSharedCore',
    'testNativeTieUsesEarliestOriginalIndexRegardlessOfInputOrder',
    'testEmptyAndIneligibleBatchesHaveNoFallback',
    'testSourceBindingsExcludeSubstitutedAndUnavailableObservations',
    'testQualityFailuresRetainEveryExclusion',
    'testMalformedPresentDigestRejectsBatchRatherThanSilentlyExcluding',
    'testDuplicateIdentityOrIndexRejectsWholeBatchEvenWhenFrameFails',
    'testIdenticalPixelsWithDistinctFrameIdentitiesArePermitted',
    'testResourceBoundaryAccepts32AndRejects33',
    'testInvalidLineageAndEmbeddedNulNeverTruncateAcrossBridge')}

QUALITY_SWIFT_REQUIRED = {'QualityTests.OFIQFaceQualityTests.' + name for name in (
    'testNonFileAssetDirectoryRefusedBeforeNativeInitialization',
    'testMissingManifestIsTypedAndDoesNotCreateAssets',
    'testChangedOrEmptyManifestNeverReachesModelInitialization',
    'testOversizedManifestHasIndependentReadBound',
    'testManifestSymlinkCannotEscapeSuppliedDirectory',
    'testComponentConversionRetainsFailedCodesAndFiniteSentinels',
    'testUnknownNativeMeasureCannotProduceAnAssessment',
    'testCanonicalIDsAndNamesMatchAll28OFIQComponents',
    'testPixelIngressRejectsUnorientedGrayAndInvalidSourceDigests',
    'testPixelIngressResourceCeilingsPrecedeNativeAllocation',
)}

ANDROID_REQUIRED = {
    'com.kenshikilabs.biometric.PortraitContractTest.' + name for name in (
        'allSharedVectorsExecuteNativeContracts',
        'ownedSnapshotSurvivesCallerAndReturnedArrayMutation',
        'fixtureProjectionPreservesOutOfRangeIntegerLiterals',
        'wireIntegerIngressRejectsBeyondSigned64WithoutNarrowing',
        'extremeMetadataCannotOverflowOrTriggerAllocation',
        'observationsRejectForeignModelAndDocumentDomain')
} | {'com.kenshikilabs.biometric.SharedEmbeddingVectorsTest.sharedNumericalAndFailureVectors'} | {
    'com.kenshikilabs.biometric.ComparisonOperationFenceTest.' + name for name in (
        'unsubmittedDuplicateAndReusedCompletionsCannotPublish',
        'everyForeignBindingLeavesOriginalRequestOutstanding',
        'reentrantCancellationCannotResurrectCancelledOperation',
        'foreignCancellationDoesNotInvalidateLiveRequest',
        'concurrentDuplicateCompletionHasExactlyOneWinner',
        'throwingCancellationCannotRestoreOutstandingRequest')
}
REQUIRED = {'swift': SWIFT_REQUIRED, 'quality-swift': QUALITY_SWIFT_REQUIRED, 'android': ANDROID_REQUIRED}


def _parse_report(path):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or not 0 < path.stat().st_size <= 2097152:
        raise ValueError('Invalid native test report')
    raw = path.read_bytes()
    if b'<!DOCTYPE' in raw or b'<!ENTITY' in raw or b'\x00' in raw:
        raise ValueError('Unsupported XML declaration')
    try:
        root = ET.fromstring(raw)
    except ET.ParseError as error:
        raise ValueError('Malformed native test report') from error
    if root.tag not in {'testsuite', 'testsuites'}:
        raise ValueError('Invalid native test report root')
    return root


def _count(value, message):
    if not value.isascii() or not value.isdecimal():
        raise ValueError(message)
    return int(value)


def _validate_execution(element):
    message = 'Native report has unsuccessful summary'
    for attribute in ('failures', 'errors', 'skipped', 'disabled'):
        value = element.get(attribute)
        if value is not None and _count(value, message) != 0:
            raise ValueError(message)
    if element.get('status') not in (None, 'run') or element.get('result') not in (None, 'completed'):
        raise ValueError('Native test was not executed')


def _validate_suite_count(element):
    count = element.get('tests')
    if count is None:
        return
    message = 'Native test count disagrees with report'
    if _count(count, message) != len(list(element.iter('testcase'))):
        raise ValueError(message)


_CHILDREN = {
    'testsuites': {'testsuite', 'testsuites'},
    'testsuite': {'testsuite', 'testcase', 'properties', 'system-out', 'system-err'},
    'testcase': {'properties', 'system-out', 'system-err', 'failure', 'error', 'skipped'},
    'properties': {'property'},
    'property': set(),
    'system-out': set(),
    'system-err': set(),
    'failure': set(),
    'error': set(),
    'skipped': set(),
}


def _validate_children(element):
    allowed = _CHILDREN[element.tag]
    if any(child.tag not in allowed for child in element):
        raise ValueError('Invalid native report hierarchy')


def _validate_element(element):
    allowed = {'testsuite', 'testsuites', 'testcase', 'failure', 'error', 'skipped',
               'properties', 'property', 'system-out', 'system-err'}
    if element.tag not in allowed:
        raise ValueError('Unsupported native report element')
    _validate_children(element)
    if element.tag in {'failure', 'error', 'skipped'}:
        raise ValueError('Native test skipped or failed')
    if element.tag in {'testsuite', 'testsuites', 'testcase'}:
        _validate_execution(element)
    if element.tag in {'testsuite', 'testsuites'}:
        _validate_suite_count(element)


def _record_case(element, seen):
    classname, name = element.get('classname'), element.get('name')
    if not classname or not name:
        raise ValueError('Missing native test identity')
    identifier = classname + '.' + name
    if identifier in seen:
        raise ValueError('Duplicate native test identity: ' + identifier)
    seen.add(identifier)


def _collect_report(path, seen):
    for element in _parse_report(path).iter():
        _validate_element(element)
        if element.tag == 'testcase':
            _record_case(element, seen)


def check_reports(paths, required):
    """Check every reported case and summary; reject duplicates across all input files."""
    paths = list(paths)
    if not paths or len(paths) > 64:
        raise ValueError('Missing or excessive native test reports')
    seen = set()
    for path in paths:
        _collect_report(path, seen)
    missing = required - seen
    if missing:
        raise ValueError('Missing required native tests: ' + ', '.join(sorted(missing)))
    return len(seen)


def check(platform, report):
    if platform not in REQUIRED:
        raise ValueError('Unknown native test platform')
    report = Path(report)
    if report.is_symlink():
        raise ValueError('Invalid native test report')
    paths = sorted(report.glob('TEST-*.xml')) if report.is_dir() else [report]
    return check_reports(paths, REQUIRED[platform])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=sorted(REQUIRED), required=True)
    parser.add_argument('--report', type=Path, required=True)
    args = parser.parse_args()
    try:
        count = check(args.platform, args.report)
    except (OSError, ValueError) as error:
        parser.exit(1, 'FAIL native portrait evidence: ' + str(error) + '\n')
    print('PASS native portrait evidence: ' + args.platform + '; ' + str(count) + ' executed test IDs')


if __name__ == '__main__':
    main()
