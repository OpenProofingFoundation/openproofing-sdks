#!/usr/bin/env python3
"""Validate the native reference workflows and shared presentation with scoped receipts."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import tempfile
import time
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT/'scripts'))
from check import input_hashes, require_python  # noqa: E402

LANES = ('guards', 'macos', 'ios-device', 'ios-simulator', 'ios-ui', 'android')
OUTPUT = ROOT/'.build/presentation'
PROJECT = 'reference-apps/ios/KenshikiReference.xcodeproj'
SWIFT_REPORT = 'swift-tests.xml'
DESIGN_REPORT = 'design-tests.xml'
UI_RESULT = 'ios-ui.xcresult'
UNAPPROVED_LANE = 'Unapproved presentation lane'
REQUIRED_TESTS = {
    'macos': {
        'WorkflowTests.testEveryPresentedActionDispatchesWithoutHiddenViewDecisions',
        'WorkflowTests.testInjectedEngineLateCallbacksAndDuplicateSubmissionsAreFenced',
        'WorkflowTests.testSeparateControllersCannotConsumeOneAnothersCompletion',
        'WorkflowTests.testSharedPositiveAndNegativeVectors',
        'WorkflowTests.testUnavailableEngineRemainsRecoverableWithoutProducingOutcome',
        'WorkflowTests.testDeferredCompletionPublishesStateAndIgnoredEventsDoNotNotify',
    },
    'android': {
        'SyntheticBiometricEngineTest.syntheticCoreCompletesAllStagesWithoutIdentityVerdict',
        'SyntheticBiometricEngineTest.malformedSessionForeignCapabilityAndTokenReplayFailClosed',
        'DesignResourcesTest.catalogResourceIdsMatchTheirDeclaredNames',
        'WorkflowTest.sharedPositiveAndNegativeVectors',
        'WorkflowTest.presentedActionsAndTerminalStates',
        'WorkflowTest.controllersHaveSeparateCompletionNamespaces',
        'WorkflowTest.delayedCallbacksAndDuplicateSubmissionsAreFenced',
        'WorkflowTest.unavailableEngineProducesNoOutcome',
        'WorkflowTest.deferredCompletionPublishesStateAndIgnoresInvalidEvents',
    },
    'ios-ui': {
        'FaceCaptureSelectionTests.testSDKExampleComparisonWaitsForExistingInferenceLease',
        'FaceCaptureSelectionTests.testLiveSelectedHandoffRequiresPreparedOwnerInsteadOfRepeatingSelfiePreparation',
        'FaceCaptureSelectionTests.testLiveQualityAdapterRefusesProfileOutsideSignedApplicationBundle',
        'FaceCaptureSelectionTests.testForeignProfilePolicyAndNonCanonicalMetricsCannotValidateAsCurrentLineage',
        'FaceCaptureSelectionTests.testEarlierWinnerKeepsOwnReceiptThroughBatchReviewProtectedCheckpointAndCompare',
        'FaceCaptureSelectionTests.testSelectionRejectsLatestReceiptAndConsistentButLowerQualityWinner',
        'FaceCaptureSelectionTests.testMatcherFailureExcludesHigherQualityAndPersistsItsFailureWithoutScoreFallback',
        'FaceCaptureSelectionTests.testHistoricalInputWithoutSelectionStillDecodesAndCurrentLineageRoundTrips',
        'FaceCaptureSelectionTests.testCancelledAndBackgroundedSelectionCannotPublishLateWinnerOrProgress',
        'FaceCaptureSelectionTests.testNoSelectionRetainsTypedCandidateDiagnosticsWithoutCheckpointOrReview',
        'FaceCaptureSelectionTests.testSelectionStorageRetryUsesSameWinnerWithoutReassessingOrRecapturing',
        'FaceCaptureSelectionTests.testCancellationBeforeSelectedCheckpointTaskBeginsDoesNotWrite',
        'FaceCaptureSelectionTests.testPerFrameAssessmentFailureRetainsDiagnosticsContinuesAndClosesBeforeRefusal',
        'FaceCaptureSelectionTests.testQualityResourceFailureAbortsWindowAndClosesWithoutAssessingLaterFrame',
        'SavedPassportJourneyTests.testHomeHasOnePrimaryStartAndKeepsSavedActionsInTheirDestination',
        'SavedPassportJourneyTests.testSavedWorkDeletionRequiresReviewAndCancellationKeepsRecord',
        'SavedPassportJourneyTests.testDeveloperToolsNavigationCannotStartCaptureOrInterruptActiveJourney',
        'BiometricCaptureHostTests.testRapidReadinessCannotFlashShutterAndStaleTimersCannotReenableIt',
        'BiometricCaptureHostTests.testGuidanceChurnNeverReattachesOrMovesThePreview',
        'LiquidRetirementTests.testHistoricalTasksAndDescriptorsDecodeWithoutV4Fields',
        'LiquidRetirementTests.testMetricsRemainOptionalForHistoryAndSurviveFailedGeneration',
        'LiquidRetirementTests.testMetricAllocatorScopeDefaultsForLegacyAndRejectsUnknownScope',
        'LiquidRetirementTests.testPureDescriptorValidationRejectsRehashedEvidenceSubstitution',
        'LiquidRetirementTests.testStrictJSONRejectsEscapedDuplicateKeysAndInvalidNumbers',
        'LiquidRetirementTests.testCaptureBindingsAndNonfiniteMeasurementsAreRejected',
        'LiquidRetirementTests.testAuraContextChecksSourceAndRejectsBidiControls',
        'LiquidRetirementTests.testMotionBindingRejectsAWindowFromAnotherFrame',
        'LiquidRetirementTests.testMotionRejectsStaleReversedNonfiniteAndInconsistentWindows',
        'LiquidRetirementTests.testAuraOnlyPipelinePersistsAndReusesResultWithoutCreatingVisualRecords',
        'LiquidRetirementTests.testHistoricalVisualStageRemainsReadableWithoutAppearingInLiveUI',
        'LiquidRetirementTests.testHistoricalPassBytesAndEvidenceBindingsSurviveReopenAfterRetirement',
        'LiquidRetirementTests.testNewComparisonExportMarksVisualRuntimeRetired',
        'PassportFlowControllerTests.testChipAndServerFailuresKeepReadRecoveryWithoutManualEntry',
        'PassportFlowControllerTests.testCameraAndInvalidKeyFailuresStillAllowManualEntryBeforeNFC',
        'PassportFlowControllerTests.testRetiredNFCCompletionCannotStartPersistence',
        'SavedPassportJourneyTests.testFailedCommitRetriesSameReadWithoutRepeatingNFC',
        'SavedPassportJourneyTests.testLeavingAfterNFCCompletionKeepsAdmittedCommitButCannotPublishOldResult',
        'SavedPassportJourneyTests.testBlockedCommitCannotPublishResultOrAcceptRepeatedContinue',
        'SavedPassportJourneyTests.testNFCCompletionCommitsRealDatabaseBeforeResultWithoutContinueOrSelfie',
        'PassportCaptureStoreTests.testUnownedVersionZeroDatabaseIsPreservedAndRefused',
        'PassportCaptureStoreTests.testWellFormedArchiveCannotBypassInnerEvidenceAndLocalCheckBindings',
        'PassportCaptureStoreTests.testMissingOrUnsupportedDigestCannotMakeMissingEvidenceCompareEqual',
        'PassportCaptureStoreTests.testOldRepositoryCannotAdoptNewGenerationForWriteOrErase',
        'SavedPassportJourneyTests.testRestoredComparisonReportKeepsHistoricalSourceAndNoServerVerdict',
        'PassportCaptureStoreTests.testPresenceIOFailureCannotMasqueradeAsMissingCapture',
        'PassportCaptureStoreTests.testReadingAbsentCheckpointDoesNotCreateDatabase',
        'FaceWorkflowPersistenceTests.testV1MigrationFailureAtEveryNewTablePreservesPassportAndRetries',
        'FaceWorkflowPersistenceTests.testCaptureAndStageRetriesAreIdempotentAndReopenPreservesEvidence',
        'FaceWorkflowPersistenceTests.testChangedCaptureAndCrossPairAuraAreRejectedWithoutReplacingOriginal',
        'FaceWorkflowPersistenceTests.testCorruptParentAndStageTimestampCannotBeReadAsValid',
        'FaceWorkflowPersistenceTests.testCancelledAuraRetainsCompletedOutcomeWithoutPublishingAndResumeReusesIt',
        'FaceWorkflowPersistenceTests.testCancelledAuraPersistsInterruptionWhenEngineThrows',
        'FaceWorkflowPersistenceTests.testCancelledAuraCommitCannotResurrectErasedStore',
        'LiquidPassIntegrationTests.testComparisonSnapshotFreezesCompareBoundaryAndRejectsForgedOrLaterArchives',
        'LiquidPassIntegrationTests.testV4MigrationRollbackAtEveryBoundaryPreservesExactV3PassBytes',
        'LiquidPassIntegrationTests.testPartialTaskReportExportsPartialInsteadOfCompleted',
        'LiquidPassIntegrationTests.testV4PassRejectsSubstitutedAuraAndSnapshotBindings',
        'LiquidPassIntegrationTests.testRehashedWorkflowMeasurementAndModelProjectionSubstitutionsAreRejected',
        'LiquidPassIntegrationTests.testHistoricalSnapshotRecoveryStopsAtOriginalCompareBeforeLongTail',
        'LiquidPassIntegrationTests.testHistoricalSnapshotRecoveryDoesNotBorrowLaterRetakeComparison',
        'LiquidPassIntegrationTests.testHistoricalSnapshotRecoveryNeverDowngradesStorageReadFailure',
        'LiquidPassIntegrationTests.testHistoricalSnapshotRejectsActionAndTimestampMetadataCorruption',
        'LiquidPassIntegrationTests.testUnavailableSnapshotAndPassRemainReadableAfterLaterRetake',


        'LiquidPassIntegrationTests.testOutcomeRequiresMatchingPendingAttemptAndCannotBeRewritten',
        'LiquidPassIntegrationTests.testV2MigrationFailureAtIndexCreationPreservesCapturesAndRetries',
        'LiquidPassIntegrationTests.testMalformedModelAgeRangeCannotEnterStorageOrCrashPresentation',
        'FaceInferenceSchedulerTests.testCancelledQueuedInferenceNeverRunsAndNextWaitsForEngineSettlement',
        'FaceInferenceSchedulerTests.testCancelledFullQueueReleasesCapacityBeforeActiveInferenceSettles',
        'FaceComparisonControllerTests.testReentrantSameOperationReplacementStartsOnlyItsOwnInference',
        'FaceComparisonControllerTests.testHistoricalV4ExportPreservesEverySchemaIndicatorValueAndRuntimeMetric',
        'FaceComparisonControllerTests.testHistoricalV4AggregateStatesRemainReadableWithoutRendering',
        'FaceComparisonControllerTests.testUnknownHistoricalDiagnosticKeysRemainPreservedWithoutRendering',
        'LiquidPassIntegrationTests.testDebugDiagnosticsRejectsMalformedStaleOversizeAndPathRequestsBeforeLease',
        'LiquidPassIntegrationTests.testDebugDiagnosticsRejectsRequestSymlinkWithoutReadingTarget',
        'LiquidPassIntegrationTests.testDebugDiagnosticsCancellationSettlesOneExportWithoutPublishingAndCanRetry',
        'LiquidPassIntegrationTests.testDebugDiagnosticsExpiresAndErasesProtectedExports',
        'LiquidPassIntegrationTests.testDebugDiagnosticsOrphanPendingIsReconciliationEvidenceNotLiveInference',
        'LiquidPassIntegrationTests.testDebugDiagnosticsRejectsOversizedCommittedReportWithBoundedError',
        'LiquidPassIntegrationTests.testDebugDiagnosticsEraseWaitsForExportLeaseAndLeavesNoReport',
        'LiquidPassIntegrationTests.testDebugDiagnosticsRechecksFreshnessAfterWaitingForInferenceLease',
        'WorkflowEvidenceTests.testJourneySensorHeartbeatsPersistWithoutRenderingAndPublishFailureRecovery',
        'WorkflowEvidenceTests.testLargeMotionPagesAreByteBoundedAndPreserveEveryEvent',
        'LiquidPassIntegrationTests.testLargePassHistoryReadsSharedEvidenceOnceAndRevalidatesOnNextLoad',
        'LiquidPassIntegrationTests.testPendingAdmissionReservesLastTerminalSlotAndRejectsAnotherAttempt',
        'LiquidPassIntegrationTests.testPendingWithLargeContextAndProjectionIsRefusedBeforeItsFailureCanOverflow',
        'LiquidPassIntegrationTests.testHistoricalV3PassHistoryRetainsItsThreeTaskMeaning',
        'LiquidPassIntegrationTests.testDebugDiagnosticsSharedLiveStoreExportsAfterDeleteAndRecaptureWithoutRestart',
        'LiquidPassIntegrationTests.testAdmittedPendingPersistsMaximumFailureIncludingUnicodeExpansionAndMetrics',
        'LiquidPassIntegrationTests.testPassCapacityAccountsForAllOutstandingRowsAndMaximumTerminalBytes',
        'WorkflowEvidenceTests.testLostAcknowledgementRetriesIdenticalEventAndDeduplicatesMotion',
        'WorkflowEvidenceTests.testDeletingWorkflowDiscardsFailedSensorQueueBeforeNewWorkflow',
        'WorkflowEvidenceTests.testJournalRetirementWaitsForInflightWriterAndRejectsLateProducers',
        'WorkflowEvidenceTests.testGapsAndNewClockSegmentsAreRetainedWithoutInterpolation',
        'WorkflowEvidenceTests.testDeniedAndStaleLocationsNeverBecomeUsableZeroCoordinates',
        'WorkflowEvidenceTests.testEventMetadataSubstitutionIsRejectedOnReadback',
        'WorkflowRecoveryTests.testMRZSurvivesReopenBeforeAnyNFCReadAndRejectsChangedFields',
        'WorkflowRecoveryTests.testInterruptedCaptureRestoresAsIncompleteWithoutInventedOutcomes',
        'PassportFlowControllerTests.testOpticalMRZCannotReachConfirmationBeforeCommitAndRetriesSameCapture',
        'PassportFlowControllerTests.testManualMRZCommitGatesAutomaticNFCAndCancellationFencesLateCommit',
        'PassportFlowControllerTests.testRestoredMRZSkipsCameraAndRequiresFreshConfirmation',
        'WorkflowEvidenceTests.testExportReadsOnlyCommittedEventsThroughItsAcknowledgedBoundary',
        'WorkflowEvidenceTests.testWorkflowCannotStartSensorsBeforeItsStartRecordCommits',
        'WorkflowEvidenceTests.testInvalidMotionVectorAndChangedSummaryAreRefused',
        'BiometricCaptureControllerTests.testSelfieReviewWaitsForCommitAndDuplicateUseCannotEscape',
        'BiometricCaptureControllerTests.testFailedSelfieCommitRetriesSameImageWithoutReopeningCamera',
        'BiometricCaptureControllerTests.testCancelledSelfieCommitCannotPublishReviewAfterWriteSettles',
        'PassportCaptureStoreTests.testEncryptedReopenPreservesExactEvidenceWithoutPlaintext',
        'PassportCaptureStoreTests.testWrongKeyAndUnavailableKeyNeverReplaceGoodEvidence',
        'PassportCaptureStoreTests.testFutureSchemaAndChangedMigrationHistoryAreRefusedWithoutReset',
        'PassportCaptureStoreTests.testMigrationFailureAfterFirstDDLLeavesNoPartialSchema',
        'PassportCaptureStoreTests.testWriteFailurePreservesPreviousCompleteCheckpoint',
        'PassportCaptureStoreTests.testChangedPayloadAndReboundMetadataCannotRestore',
        'PassportCaptureStoreTests.testIndependentConcurrentWritersCannotMixEvidenceAndBindingColumns',
        'PassportCaptureStoreTests.testEraseRetiresOldHandlesAndAllowsOnlyNewCaptureToRecreateStore',
        'SavedPassportJourneyTests.testRestoredCaptureStartsSelfieWithoutOpeningPassportAndUsesOriginalBytes',
        'SavedPassportJourneyTests.testCompletedLivePassportPersistsAcrossFreshControllerAndDone',
        'SavedPassportJourneyTests.testDeletionWaitsForNonCooperativeSaveAndNeverResurrectsIt',
        'SavedPassportJourneyTests.testLateLoadCannotRestoreDeletedCapture',
        'SavedPassportJourneyTests.testStorageFailureCannotAdvanceToSelfieOrMasqueradeAsSaved',
        'SavedPassportJourneyTests.testFailedDeletionCannotReuseCachedPassportAndRequiresDeletionRetry',
        'PassportFaceJourneyTests.testExplicitSelfieAdmissionWaitsForVisibilityAndCannotSurviveWithdrawal',
        'PassportFaceJourneyTests.testCameraRetryDoesNotIntroduceAnotherStartScreen',
        'PassportFaceJourneyTests.testNewJourneyWaitsForCancelledNFCReadToSettle',
        'PassportFaceJourneyTests.testRetiredPassportFactoryCannotMountOrStartAcquisition',
        'PassportFaceJourneyTests.testRetiredSelfieFactoryCannotMountOrRestartCapture',
        'PassportFaceJourneyTests.testExplicitPassportBeginWaitsForVisibilityAndCannotSurviveWithdrawal',
        'PassportFaceJourneyTests.testOrderedJourneyConsumesEachHandoffOnceAndRetakeKeepsPassport',
        'PassportFaceJourneyTests.testCancelledPassportCannotEnterAnotherSession',
        'PassportFaceJourneyTests.testBackgroundClearsEvidenceAndFencesNonCooperativeComparison',
        'PassportFaceJourneyTests.testReentrantCancellationBeforeInferencePreventsExecution',
        'PassportFaceJourneyTests.testUnverifiedOrMissingPortraitCannotAdvance',
        'PassportFaceJourneyTests.testExamplesCannotInterruptAnActiveJourneyAndDoneClearsResults',
        'PassportFaceJourneyTests.testNativeJourneyReadsOnceReviewsSelfieAndShowsCombinedResultWithoutTabs',
        'WorkflowSmokeTests.testGuidedJourneyRequiresHardwareBackedStorageBeforeCapture',
        'WorkflowSmokeTests.testGuidedJourneyExpandedRTLAndExamplesReturnToHome',
        'FaceComparisonControllerTests.testReportExportPreservesPendingAndUnavailableStatesWithoutStaleData',
        'PassportFaceJourneyTests.testJourneyCopyReportUsesCurrentResultAndRejectsRetiredButton',
        'FaceComparisonControllerTests.testMissingCaptureMetricsRemainUnavailableWithoutInventedZeros',
        'FaceComparisonControllerTests.testCaptureAndAuraSubstitutionCannotEnterReviewContext',
        'FaceComparisonControllerTests.testForeignMotionImageTimeAndClockCannotEnterReviewContext',
        'FaceComparisonControllerTests.testRecordedMotionPermissionStatesAreVisibleAndDeniedEvidenceIsRejected',
        'FaceComparisonControllerTests.testRetiredVisualValuesNeverAppearInActivePresentation',
        'FaceComparisonControllerTests.testAppPortraitAndReviewedSelfieReachComparisonAndVisibleResult',
        'FaceComparisonControllerTests.testAppTabWithdrawalRejectsLateComparisonResult',
        'FaceComparisonControllerTests.testAppRoutesReviewedSelfieThroughRealInferenceAdapter',
        'FaceComparisonControllerTests.testAcceptedImagesAutomaticallyProcessAndPublishSimilarity',
        'FaceComparisonControllerTests.testReviewedCaptureIsBoundToTheSelectedReferenceAndConsumedOnce',
        'FaceComparisonControllerTests.testPortraitReplacementDuringReviewRejectsCaptureBeforeInference',
        'FaceComparisonControllerTests.testRetiredCaptureAndCancellationCannotConsumeReplacementCapture',
        'FaceComparisonControllerTests.testCancellationRejectsNonCooperativeLateCompletion',
        'FaceComparisonControllerTests.testReplacementCannotConsumePreviousOperationCompletion',
        'FaceComparisonControllerTests.testForeignOperationOrImageBindingsNeverPublishScore',
        'FaceComparisonControllerTests.testNonfiniteAndOutOfRangeScoresNeverPublish',
        'FaceComparisonControllerTests.testSourceSubstitutionFailsBeforeEngineConstruction',
        'FaceComparisonControllerTests.testReentrantWithdrawalPreventsEngineWork',

        'PassportFlowControllerTests.testNativeMRZFramesReachConfirmationWithoutTemporalGuideGateAndFenceRetiredFrames',
        'PassportFlowControllerTests.testVerifiedServerMismatchUsesPulseFieldSpecificRecoveryAndRetainsRefusal',
        'PassportFlowControllerTests.testVerifiedServerReadReportsCheckpointFailureSeparatelyFromProofFailure',
        'PassportFlowControllerTests.testIncompleteTruncatedAndAmbiguousMRZStayCapturingUntilComplete',
        'PassportFlowControllerTests.testConsentVisibilityAndConfirmationPrecedeAcquisition',
        'PassportFlowControllerTests.testManualKeyRequiresExplicitConfirmationAndTrust',
        'PassportFlowControllerTests.testInvalidManualKeyCannotBecomeReady',
        'PassportFlowControllerTests.testCameraStopsBeforeNFCAndOldCandidatesCannotReplaceConfirmedSource',
        'PassportFlowControllerTests.testResignActiveDoesNotRequireForegroundMutationWhileTrueBackgroundRejectsLateRead',
        'PassportFlowControllerTests.testCancelScanPreservesConfirmedKeyAndFencesLateEventsAndResult',
        'PassportFlowControllerTests.testVerifiedResultRetainsOriginalPortraitWithoutDisplayDecodeAndDeliversOnce',
        'PassportFlowControllerTests.testInjectedFailedOrMissingProofsNeverBecomeResult',
        'PassportFlowControllerTests.testMissingPortraitStillReturnsVerifiedReadButCannotDeliverPortrait',
        'PassportFlowControllerTests.testHiddenAndDiscardClearEvidenceAndCancelCannotReopen',
        'PassportFlowControllerTests.testReentrantScanRenderCancellationPreventsReadConstruction',
        'PassportFlowControllerTests.testChangingTrustDuringReadRejectsItsResult',
        'PassportFlowControllerTests.testUnsupportedNFCPrecedesMissingTrustAndDoesNotConstructRead',
        'PassportFlowControllerTests.testNativeSheetCancelReturnsReadyAndRetryCanReadAgain',
        'PassportFlowControllerTests.testCancelledReadMustSettleBeforeReplacementReadStarts',
        'PassportFlowControllerTests.testTerminalRenderBackgroundWithdrawalPreventsAcceptedDelivery',
        'PassportFlowControllerTests.testManualConfirmedFieldsMustCorrespondToChipEvenWithVerifiedProofs',
        'PassportFlowControllerTests.testPrintedFieldsMustCorrespondToVerifiedChip',
        'PassportFlowControllerTests.testAbsentPrintedGivenNamesRemainNotCompared',
        'BiometricCaptureHostTests.testBiometricRootRequiresReferenceAndHasNoAcceptedSelfieDeadEnd',
        'BiometricCaptureHostTests.testLatestReadinessAnnouncementArrivesWithoutAnotherRenderAndDoesNotFlood',
        'BiometricCaptureHostTests.testPendingAnnouncementsCannotSurviveHiddenForegroundBackgroundOrCancel',
        'BiometricCaptureHostTests.testPhaseChangeAndUseInvalidateDeferredGuidance',
        'BiometricCaptureControllerTests.testTerminalRenderWithdrawalCannotDeliverAcceptedSelfie',
        'BiometricCaptureHostTests.testReadinessKeepsButtonIdentityOrderAndSingleBinding',
        'BiometricCaptureHostTests.testReviewedUseHandsExactBundleOnceAndReleasesImage',
        'BiometricCaptureControllerTests.testUseSelfieTransfersExactBoundBundleOnceAfterTerminalRelease',
        'BiometricCaptureControllerTests.testCapturedReviewWithdrawalAndRetakeCannotDeliverOldBundle',
        'BiometricCaptureControllerTests.testInactiveForegroundRevokesReadyShutterAndLateAcquisition',
        'BiometricCaptureControllerTests.testReviewRotationPreservesAcceptedSourceAndPixels',
        'BiometricCaptureControllerTests.testReentrantConsentWithdrawalCannotOverwriteCancellation',
        'BiometricCaptureControllerTests.testReentrantCancellationAtFactoryRenderViewportAndGrantNeverReactivatesDriver',
        'BiometricCaptureControllerTests.testReentrantProcessingCancellationNeverStartsDecoder',
        'BiometricCaptureControllerTests.testReentrantRetryCancellationCannotRetryRetiredDriver',
        'BiometricCaptureControllerTests.testCapturedImageDecodesToOwnedPixelsAndRetakeClearsEvidence',
        'BiometricCaptureControllerTests.testCancellationRejectsSuspendedDecodeCompletion',
        'BiometricCaptureControllerTests.testBackgroundRejectsSuspendedDecodeCompletion',
        'BiometricCaptureControllerTests.testDuplicateAndRetiredCaptureCallbacksCannotReplaceOwnedEvidence',
        'BiometricCaptureControllerTests.testDecoderSourceSubstitutionFailsWithoutPublishingEvidence',
        'BiometricCaptureControllerTests.testConsentAndVisibilityPrecedeDriverConstruction',
        'BiometricCaptureControllerTests.testViewportIsValidatedCachedAndDeliveredBeforeActivation',
        'BiometricCaptureControllerTests.testShutterRequiresCurrentAdmissionReadiness',
        'BiometricCaptureControllerTests.testWithdrawalInvalidatesLateCallbacksBeforeRelease',
        'BiometricCaptureControllerTests.testCancelledControllerCannotReopenOrDeliverLateFailure',
        'BiometricCaptureControllerTests.testFailureReasonsMapToScopedLocalizableStates',
        'BiometricCaptureControllerTests.testRetryPreservesSameDriverAndDoesNotAbandonOccupiedWorker',
        'BiometricCaptureControllerTests.testHiddenAndForegroundStateCannotGrantAcquisition',
        'WorkflowSmokeTests.testLivePassportManualInputAndCancellationHaveNoSimulationPath',
        'WorkflowSmokeTests.testLivePassportSimulatorRefusesNFCWithoutProducingPortrait',
        'WorkflowSmokeTests.testLivePassportScanCanCancelWithoutProducingEvidence',
        'WorkflowSmokeTests.testFaceComparisonRequiresPortraitBeforeSelfie',
        'WorkflowSmokeTests.testNativeInstructionContainerAndTabNavigation',
        'WorkflowSmokeTests.testDefaultLaunchShowsThreeCapabilityTabsWithoutAFirstRunJourney',
        'WorkflowSmokeTests.testDocumentIntroOffersExplicitCameraStartWithoutSimulation',
        'WorkflowSmokeTests.testDocumentCameraDenialReportsFailureWithoutProducingEvidence',
        'WorkflowSmokeTests.testExpandedRTLAndDarkPresentationRemainsReachable',
        'WorkflowSmokeTests.testBackgroundDoesNotStartDocumentCameraOrHideCapabilityTabs',
    },
}
REQUIRED_TESTS['ios-ui'].update({
    'PassportFaceJourneyTests.testRetiredRetakeFailureCannotClearNewJourneyAdmissionTask',
    'FaceComparisonControllerTests.testAppMissingInferenceModelReturnsUnavailableWithoutScore',
    'WorkflowEvidenceTests.testLongMotionWorkflowStreamsFullExtremaAndCoverageWithBoundedSampleRetention',
    'WorkflowEvidenceTests.testMotionProjectionBoundsResumeTailsAndRejectsStaleOrOutOfOrderSamples',
    'PassportFaceJourneyTests.testResultSummaryKeepsExactScoreAndMovesImplementationAndRangesToDetails',
    'PassportFaceJourneyTests.testWorkflowMotionLoadKeepsDetailsSheetStableAndLateLoadCannotRestoreRetiredSession',
    'PassportPulseRegistrationTests.testBearerRecoveryPreservesRegisteredInstallationAndKeyWithoutReattestation',
    'PassportPulseRegistrationTests.testCredentialWriteFailureCanReplayWithoutReplacingOrReattestingKey',
    'PassportPulseRegistrationTests.testExpiredChallengeNeverCallsPlatformAttestation',
    'PassportPulseRegistrationTests.testFreshRegistrationUsesOnePlatformAttestationAndRetainedCredentialsAvoidNetwork',
    'PassportPulseRegistrationTests.testGenericRecovery404NeverAuthorizesRegistrationPacketReplay',
    'PassportPulseRegistrationTests.testLostRegistrationResponseReplaysExactPacketWithoutReattesting',
    'PassportPulseRegistrationTests.testWrongInstallationResponseNeverPersistsBearer',
    'PassportServerCeremonyTests.testKnownTrustConfigurationVerdictsRequireServerRepairInsteadOfChipRetry',
    'PassportServerCeremonyTests.testUnknownTrustTextAndPassportIntegrityVerdictsRemainRejected',
    'PassportServerCeremonyTests.testDiagnosticsDistinguishLocalRefusalFromServerVerdictAndHTTPStatus',
    'PassportServerCeremonyTests.testDiagnosticsLocateMalformedVerificationBindingWithoutReportingServerRejection',
    'PassportServerCeremonyTests.testDiagnosticsHashUnknownServerTextWithoutAcceptingKnownPrefixOrRetainingCredentials',
    'PassportServerCeremonyTests.testSODFramingDiagnosticsExposeOnlyBoundedMetadataAcrossEnvelopeShapes',
    'PassportServerCeremonyTests.testActiveChallengeSubstitutionNeverSubmits',
    'PassportServerCeremonyTests.testAmbiguousSessionFailureRetriesIdenticalOperationBytes',
    'PassportServerCeremonyTests.testAmbiguousVerificationRetiresPossiblyConsumedNonceBeforeRetry',
    'PassportServerCeremonyTests.testCancelledReadDoesNotSubmitAndCanRetryWithUnconsumedSession',
    'PassportServerCeremonyTests.testFailedServerVerdictNeverReturnsVerifiedRead',
    'PassportServerCeremonyTests.testHistoricalLocalCheckpointRemainsWithoutServerVerification',
    'PassportServerCeremonyTests.testKnownBearerRefusalRecoversOnceAndResubmitsSameProofWithFreshAssertion',
    'PassportServerCeremonyTests.testLocalIntegrityFailureNeverSubmitsRemoteProof',
    'PassportServerCeremonyTests.testMissingOrMismatchedVerificationIDsNeverAcceptServerSuccess',
    'PassportServerCeremonyTests.testNFCPercentUsesBoundedRealStageValuesAndCompletion',
    'PassportServerCeremonyTests.testServerCARefusalSurvivesReaderFailureMapping',
    'PassportServerCeremonyTests.testServerChallengeRelayAndVerificationUseExactReadWithoutDG2Upload',
    'PassportServerCeremonyTests.testServerFailureCannotDowngradeToLocalReadOrPersistPortrait',
    'PassportServerCeremonyTests.testServerObservationRoundTripsThroughEncryptedCheckpointAndRejectsSubstitutedSOD',
    'PassportServerCeremonyTests.testWrongSessionNonceRefusesBeforeNFC',
    'WorkflowEvidenceTests.testHistoricalMotionProjectionPagesThroughBoundaryAndRejectsDifferentWorkflowOrTruncation',
    'WorkflowEvidenceTests.testMotionProjectionDeduplicatesOverlapsAndSeparatesResumeCoverage',
    'WorkflowEvidenceTests.testMotionProjectionPreservesDeniedEmptyAndMissingMagneticEvidence',
    'WorkflowEvidenceTests.testMotionProjectionRejectsConflictingSamplesAtTheSameSegmentTime',
    'WorkflowEvidenceTests.testMotionProjectionSpansMRZNFCSelfieAndRetakeWithExactRanges',
    'WorkflowEvidenceTests.testRecorderMotionProjectionReadsPersistedWindowsAndRetiresPriorWorkflow',
})
REQUIRED_TESTS['ios-ui'].update({
    'PassportFlowControllerTests.testCorrespondenceRecoveryRescansPageBeforeFreshConfirmationAndRead',
    'PassportFlowControllerTests.testDiagnosticCheckpointObserversCannotResurrectRetiredSuccessOrFailure',
    'PassportFlowControllerTests.testDiagnosticReadObserversCannotOverwriteRetiredFlowOrStartPersistence',
    'PassportServerCeremonyTests.testActualServerReportAndPrivateCapabilityRoundTripWithoutDisclosureOrSourceSubstitution',
    'PassportServerCeremonyTests.testEveryDeliveredLocalGuardRetiresItsNonceBeforeRetryWithoutVerification',
    'PassportServerCeremonyTests.testCancellationAfterReturnedReadRetiresDeliveredNonceBeforeNextRead',
    'PassportServerCeremonyTests.testReviewedPageMismatchRefusesBeforeAnyRemoteVerification',
    'PassportServerPresentationTests.testCanonicalServerChecksUseOneProjectionWithoutUnperformedHardwareRows',
    'PassportServerPresentationTests.testHistoricalReceiptDoesNotInventMissingServerChecks',
})
REQUIRED_TESTS['ios-ui'].update({
    'PassportServerCeremonyTests.testFailedWorkerReportRemainsExactCurrentAttemptDetailsWithoutPersistingPortraitOrCapability',
    'PassportServerCeremonyTests.testLateFailedResponseAfterRetirementCannotRestoreReportOrPersistEvidence',
    'PassportServerCeremonyTests.testLocalAndTransportFailuresDoNotFabricateCanonicalServerRejections',
})
REQUIRED_TESTS['ios-ui'].update({
    'DocumentFlowControllerTests.testNoPortraitObservationRemainsReviewableWithoutInventedMatch',
    'DocumentFlowControllerTests.testBackFailurePreservesFrontForExplicitBackRetake',
    'DocumentFlowControllerTests.testCameraIsLazyAndRequiresExplicitStartWhileVisibleAndForeground',
    'DocumentFlowControllerTests.testCameraStartupFailureSettlesBeforeExplicitRetry',
    'DocumentFlowControllerTests.testEachSuspendedProcessingStageIsFencedAfterBackground',
    'DocumentFlowControllerTests.testFactoryWithdrawalCannotStartTheReturnedCamera',
    'DocumentFlowControllerTests.testFailedNativeSettlementBlocksReplacementUntilExplicitRetrySucceeds',
    'DocumentFlowControllerTests.testFrontAndBackRetainExactIndependentSourceAndDerivativeObservations',
    'DocumentFlowControllerTests.testOldStartAndStopSettleBeforeReplacementCameraIsConstructed',
    'DocumentFlowControllerTests.testProcessingFailuresRemainStageSpecificWithoutReviewSuccess',
    'DocumentFlowControllerTests.testReentrantVisibilityWithdrawalDoesNotStartCameraOrProcessing',
    'DocumentFlowControllerTests.testRepeatedStartAndCaptureIntentsCannotDuplicateAcquisition',
    'DocumentFlowControllerTests.testResetLeaveAndBackgroundImmediatelyClearAllReviewMedia',
    'DocumentFlowControllerTests.testRetakeBackPreservesFrontAndRetakeFrontClearsBothSides',
    'DocumentFlowControllerTests.testSourceDerivativeReadingAndPortraitBindingMismatchesAreRefused',
    'DocumentFlowControllerTests.testStalePortraitCompletionCannotPublishOrStopNewCamera',
})
REQUIRED_TESTS['ios-ui'].update({
    'StorageHealthTests.testTrustedBaseAliasCanonicalizesWithoutResolvingAnUntrustedChild',
    'StorageHealthTests.testFailedConstructionRetriesOnceAndSharesRecoveredStoreAcrossBothPorts',
    'StorageHealthTests.testConcurrentPortsCoalesceConstructionAndKeepOneOwner',
    'StorageHealthTests.testCorruptRetainedStorageFailureNeverErasesOrReplacesItsFiles',
    'StorageHealthTests.testStartupReportIdentifiesMRZFailureWithoutPretendingPassportLoadFailed',
    'StorageHealthTests.testDiagnosticsRetainOnlyBoundedCodesAndObservedRootBoolean',
})
REQUIRED_TESTS['ios-ui'].update({
    'DocumentFlowHostLifecycleTests.testRetainedFrontButtonCannotConsumeBackStepButBackButtonCan',
    'DocumentFlowPersistenceTests.testStaleFrontCaptureIntentCannotCaptureOrSaveBackButExplicitBackCaptureCan',
    'DocumentFlowControllerTests.testLivePDF417BeforeBackIsIgnoredAndExactCandidateCapturesBackOnlyOnce',
    'DocumentFlowControllerTests.testPDF417DuringBackStartupWaitsForReadyBackOwner',
    'DocumentFlowControllerTests.testRetiredPDF417CallbacksCannotCaptureReplacementBackOrCancelledSession',
    'DocumentFlowControllerTests.testCameraWithoutLiveBarcodeSupportRefusesInsteadOfDowngradingCandidate',
    'DocumentFlowControllerTests.testLiveBarcodeBypassesFailingPreparationAndExtractionWithoutInventingStillOCR',
    'DocumentFlowPersistenceTests.testFrontSaveFailureCannotStartBarcodeBackUntilExactRetryCommits',
    'DocumentFlowPersistenceTests.testLivePDF417BackCaptureCommitsPairWithOriginalFrontAndExactCandidate',
    'DocumentFlowPersistenceTests.testBarcodeReadDuringFrontCommitCannotCreateBackOrPublishPartialPair',
    'DocumentFlowPersistenceTests.testLiveBarcodeRawOriginAndNoPreparedImageSurviveSavedReopen',
    'DocumentFlowPersistenceTests.testReopenRefusesMissingFrontPreparationAndAmbiguousLiveBarcodeOrigin',
    'DocumentFlowSQLiteStoreTests.testSavedRawPDF417RendersStructuredFieldsWithoutScanningOrRewritingEvidence',
    'DocumentFlowSQLiteStoreTests.testLiveStructuredResultsRejectMalformedPayloadInsteadOfUsingUnrelatedCachedFields',
    'DocumentFlowSQLiteStoreTests.testHistoricalStructuredResultsRemainReadableWithoutChangingEncodedReading',
    'DocumentFlowSQLiteStoreTests.testAdmittedLiveBackReopensRawSourceAndPreservesFrontAndMotionProof',
    'DocumentFlowSQLiteStoreTests.testUnboundRawBackAndForgedLiveOriginsPreservePreviousAtomicPublication',
    'DocumentFlowRendererTests.testFactorySelectsBarcodeGuideAndMountsBackPreviewThenRestoresFrontSurface',
    'StorageHealthTests.testDocumentPhaseTraceIsBoundedAndContainsOnlyPhaseAndPresenceFacts',
    'StorageHealthTests.testDocumentTraceWriteFailureCannotInterruptCaptureState',
    'DocumentFlowHostLifecycleTests.testOwnedPermissionSheetKeepsStartAndDenialPublishesFailure',
    'DocumentFlowHostLifecycleTests.testTrueBackgroundDuringOwnedPermissionSheetRevokesLateGrant',
    'DocumentFlowHostLifecycleTests.testUnownedInactivityStillRevokesPendingStart',
})
REQUIRED_TESTS['ios-ui'].update({
    'DocumentFlowControllerTests.testAutomaticFrontPreservesIdentityAndManualRaceCannotCaptureTwice',
    'DocumentFlowControllerTests.testRetiredAutomaticCallbackCannotCaptureReplacementCamera',
    'DocumentFlowRendererTests.testFrontSurfaceRemainsMountedDuringGuidanceAndProcessingUpdates',
    'DocumentFlowRendererTests.testBackPreviewRemainsMountedDuringGuidanceAndProcessingUpdates',
    'DocumentFlowRendererTests.testSharedFrontControlsDispatchCaptureAndCancelInHostedApplication',
})
REQUIRED_TESTS['ios-ui'].update({
    'DocumentFlowPersistenceTests.testFrontSaveCompletesBeforeBackAndExplicitReopenDoesNotAcquireOrReprocess',
    'DocumentFlowPersistenceTests.testPairedReopenPreservesIndependentOriginalDerivativeReadingAndPortraitLineage',
    'DocumentFlowPersistenceTests.testFailedSaveCanRetryExactProcessedFrontWithoutAnotherCapture',
    'DocumentFlowPersistenceTests.testFailedBackSaveKeepsPreviousFrontUntilExactRetrySucceeds',
    'DocumentFlowPersistenceTests.testDuplicateCaptureAndRetryWhileSavingCannotDuplicatePersistenceOrAcquisition',
    'DocumentFlowPersistenceTests.testAdmittedSaveDrainsAfterWithdrawalWithoutRepublishingOrStoppingReplacement',
    'DocumentFlowPersistenceTests.testLateReadAfterWithdrawalCannotRestoreOrStartCameraAndDuplicateReadCoalesces',
    'DocumentFlowPersistenceTests.testMissingAndUnavailableSavedEvidenceAreDistinctWithoutInventedReview',
    'DocumentFlowPersistenceTests.testDeleteFailurePreservesCommittedEvidenceAndExplicitRetryRemovesIt',
    'DocumentFlowPersistenceTests.testReopenRefusesMisboundSourceDerivativeAndPortraitInsteadOfPartialPublication',
    'DocumentFlowPersistenceTests.testReentrantWithdrawalBeforeSaveOrReadAdmissionPerformsNoPersistenceIO',
    'DocumentFlowSQLiteStoreTests.testMissingLoadCreatesNeitherDatabaseNorSigningKey',
    'DocumentFlowSQLiteStoreTests.testFrontAndPairedRevisionsReopenExactBytesFromEncryptedDatabase',
    'DocumentFlowSQLiteStoreTests.testLostAcknowledgementRetryReturnsSameSignedFrontAndBackRevisions',
    'DocumentFlowSQLiteStoreTests.testMissingHistoricalSigningKeyRefusesReadAndSaveWithoutReplacement',
    'DocumentFlowSQLiteStoreTests.testFailedSignatureAndStaleRevisionPreservePreviousCommit',
    'DocumentFlowSQLiteStoreTests.testAlteredSignedPayloadAndNativeMetadataAreRefused',
    'DocumentFlowSQLiteStoreTests.testConcurrentReplacementDuringSigningCannotOverwriteNewerRevision',
    'DocumentFlowSQLiteStoreTests.testSQLFailureAfterRevisionInsertRollsBackEntirePublication',
    'DocumentFlowSQLiteStoreTests.testCallerCancellationDoesNotCancelAnAdmittedSignedPublication',
    'DocumentFlowSQLiteStoreTests.testExternalErasureDuringSigningCannotRepublishThroughOldLifecycleOwner',
    'DocumentFlowSQLiteStoreTests.testExplicitDeleteRemovesCiphertextThenSigningCustody',
    'DocumentFlowSQLiteStoreTests.testFailedSigningKeyErasureRemainsEraseOnlyAcrossFreshOwnerUntilRetry',
})
REQUIRED_TESTS['ios-ui'].update({
    'DocumentFlowPersistenceTests.testRetakeBackCannotReplaceAnAdmittedSaveOrReuseItsStaleRevision',
    'DocumentFlowSQLiteStoreTests.testSubstitutedNativeAdmissionAndTemporalStillFactsCannotEnterSignedStore',
})
REQUIRED_TESTS['ios-ui'].update({
    'DocumentFlowSQLiteStoreTests.testMotionReceiptAndWholeSnapshotCommitTogetherAndFrontReceiptIsReusedForBack',
    'DocumentFlowSQLiteStoreTests.testMissingTamperedOrForeignMotionRowRefusesWholeReview',
    'DocumentFlowSQLiteStoreTests.testMotionKeyLossNeverMintsReplacementOrReturnsPartialSnapshot',
    'DocumentFlowSQLiteStoreTests.testLegacyV1ReadAndMigrationPreserveOriginalPayloadMetadataAndSignatureBytes',
    'DocumentFlowSQLiteStoreTests.testFailureAfterMotionInsertRollsBackSnapshotPointerAndSchemaMigration',
    'DocumentFlowSQLiteStoreTests.testFutureAndMalformedSchemasArePreservedAndRefused',
})
MACOS_REPORTS = {
    SWIFT_REPORT: frozenset(REQUIRED_TESTS['macos']),
    DESIGN_REPORT: frozenset({
        'LocalizationTests.testPackagedDefaultResolvesEveryMessage',
        'LocalizationTests.testExplicitBundleOverrideUsesSelectedLocale',
        'LocalizationTests.testPackagedEnglishFallbackMetadata',
    }),
}
REQUIRED_TESTS['macos'].update(MACOS_REPORTS[DESIGN_REPORT])


def simulator_destination():
    data = json.loads(subprocess.check_output(['xcrun', 'simctl', 'list', 'devices', 'available', '--json'], cwd=ROOT, text=True))
    devices = [device for runtime, entries in data['devices'].items() if 'iOS' in runtime
               for device in entries if device.get('isAvailable') and device['name'].startswith(('iPhone', 'KenshikiPresentationUI', 'KenshikiPresentationQA'))]
    if not devices:
        raise ValueError('An available iPhone simulator is required for native UI execution')
    devices.sort(key=lambda device: (device['name'] != 'KenshikiPresentationQA', device['name'] != 'KenshikiPresentationUI',
                                    device['state'] != 'Booted', device['name'], device['udid']))
    return 'platform=iOS Simulator,id='+devices[0]['udid']


def commands(lane):
    stages = [[sys.executable, 'quality/presentation_guards.py'],
              [sys.executable, 'design-system/generate.py', '--check']]
    if lane == 'guards':
        stages.append([sys.executable, '-m', 'unittest', 'discover', '-s', 'design-system/tests', '-p', 'test_*.py'])
    elif lane == 'macos':
        stages.extend([
            ['swift', '--version'],
            ['swift', 'test', '--package-path', 'presentation', '--parallel', '--disable-swift-testing',
             '-Xswiftc', '-warnings-as-errors',
             '--xunit-output', str(OUTPUT/SWIFT_REPORT)],
            ['swift', 'test', '--package-path', 'design-system', '--parallel', '--disable-swift-testing',
             '-Xswiftc', '-warnings-as-errors', '--xunit-output', str(OUTPUT/DESIGN_REPORT)],
            [sys.executable, 'scripts/presentation_api.py', '--platform', 'macos'],
        ])
    elif lane in ('ios-device', 'ios-simulator', 'ios-ui'):
        stages.append([sys.executable, 'biometric/tools/native_quality/build.py', '--ensure'])
        stages.append([sys.executable, 'document/scripts/provision_native.py'])
        stages.append(['xcodebuild', '-version'])
        destinations = {'ios-device': 'generic/platform=iOS', 'ios-simulator': 'generic/platform=iOS Simulator'}
        destination = simulator_destination() if lane == 'ios-ui' else destinations[lane]
        command = ['xcodebuild', '-project', PROJECT, '-scheme', 'KenshikiReference',
                   '-destination', destination, '-derivedDataPath', str(OUTPUT/lane), 'CODE_SIGNING_ALLOWED=NO']
        if lane == 'ios-ui':
            # Skip Xcode's optional sysdiagnose collection, which can stall after tests.
            # Test execution, exit status, xcresult assertions and screenshots remain required.
            command.extend(['-resultBundlePath', str(OUTPUT/UI_RESULT), '-collect-test-diagnostics', 'never', 'test'])
        else:
            command.append('build')
        stages.append(command)
    elif lane == 'android':
        stages.extend([
            ['java', '-version'],
            ['bash', 'reference-apps/android/gradlew', '-p', 'reference-apps/android', '--no-daemon',
             '--dependency-verification', 'strict', 'clean', 'assembleDebug', 'assembleRelease',
             'lintDebug', 'lintRelease', 'testDebugUnitTest'],
            [sys.executable, 'scripts/presentation_api.py', '--platform', 'android'],
        ])
    else:
        raise ValueError(UNAPPROVED_LANE)
    return stages


def safe_path(path):
    """Generated evidence may not traverse a symlink or escape the checkout."""
    path = Path(path)
    relative = path.relative_to(ROOT)
    if '..' in relative.parts:
        raise ValueError('Generated evidence path escapes checkout')
    current = ROOT
    for part in relative.parts:
        current = current/part
        if current.is_symlink():
            raise ValueError('Symlink in generated evidence path: '+str(current))
    return path


def android_reports():
    folder = safe_path(ROOT/'reference-apps/android/app/build/test-results/testDebugUnitTest')
    return [safe_path(path) for path in folder.glob('TEST-*.xml')]


def remove_generated(path):
    path = safe_path(path)
    if path.is_dir():
        shutil.rmtree(path)
    elif path.exists():
        path.unlink()


def previous_evidence(lane):
    paths = [OUTPUT/(lane+'.log'), receipt_path(lane)]
    if lane == 'macos':
        paths.extend(OUTPUT/name for name in MACOS_REPORTS)
    elif lane == 'ios-ui':
        paths.append(OUTPUT/UI_RESULT)
    elif lane == 'android':
        paths.extend(android_reports())
    return paths


def receipt_path(lane):
    return OUTPUT/(lane+'.json')


def archive_previous(lane):
    """Move only known generated evidence before a new attempt replaces it."""
    if lane not in LANES:
        raise ValueError(UNAPPROVED_LANE)
    paths = [safe_path(path) for path in previous_evidence(lane)]
    existing = [path for path in paths if path.exists()]
    for path in existing:
        if path.is_dir():
            for nested in path.rglob('*'):
                safe_path(nested)
    if not existing:
        return None
    history = safe_path(OUTPUT/'history')
    history.mkdir(parents=True, exist_ok=True)
    prefix = datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ-')+lane+'-'
    destination = Path(tempfile.mkdtemp(prefix=prefix, dir=history))
    for path in existing:
        shutil.move(str(path), str(safe_path(destination/path.name)))
    return destination


def prepare_outputs(lane):
    safe_path(OUTPUT).mkdir(parents=True, exist_ok=True)
    safe_path(OUTPUT/(lane+'.log'))
    safe_path(receipt_path(lane))
    archive_previous(lane)
    if lane == 'macos':
        for name in MACOS_REPORTS:
            remove_generated(OUTPUT/name)
    elif lane.startswith('ios-'):
        remove_generated(OUTPUT/lane)
        if lane == 'ios-ui':
            remove_generated(OUTPUT/UI_RESULT)
    elif lane == 'android':
        for path in android_reports():
            remove_generated(path)
        # Gradle clean owns deletion; reject redirected outputs before invoking it.
        safe_path(ROOT/'reference-apps/android/app/build')


def fresh_file(path, started_ns):
    path = safe_path(path)
    if not path.is_file() or path.stat().st_size == 0 or path.stat().st_mtime_ns < started_ns:
        raise ValueError('Missing, empty or stale generated evidence: '+str(path))
    return path


def required_ids(lane, identifiers):
    identifiers = set(identifiers)
    missing = REQUIRED_TESTS[lane] - identifiers
    if missing:
        raise ValueError('Required presentation tests did not execute: '+str(sorted(missing)))
    return {'executed': len(identifiers), 'ids': sorted(identifiers)}


def xml_test_counts(lane, started_ns):
    paths = [OUTPUT/name for name in MACOS_REPORTS] if lane == 'macos' else android_reports()
    if not paths:
        raise ValueError('Required controller tests produced no test reports')
    ids = []
    for path in paths:
        current = xml_ids(path, started_ns)
        if lane == 'macos' and not MACOS_REPORTS[path.name].issubset(current):
            raise ValueError('Required package tests did not execute in report: '+path.name)
        ids.extend(current)
    return required_ids(lane, ids)


def xml_ids(path, started_ns):
    cases = list(ET.parse(fresh_file(path, started_ns)).iter('testcase'))
    if not cases or any(case.find(tag) is not None for case in cases for tag in ('failure', 'error', 'skipped')):
        raise ValueError('Required controller tests must execute and pass without skips')
    return [case.get('classname', '').rsplit('.', 1)[-1]+'.'+case.get('name', '').removesuffix('()') for case in cases]


def test_nodes(nodes):
    for node in nodes:
        if node.get('nodeType') == 'Test Case':
            yield node
        yield from test_nodes(node.get('children', []))


def ui_test_counts(started_ns):
    bundle = safe_path(OUTPUT/UI_RESULT)
    if not bundle.is_dir() or bundle.stat().st_mtime_ns < started_ns:
        raise ValueError('Missing or stale iOS UI result bundle')
    payloads = {}
    for kind in ('summary', 'tests'):
        payloads[kind] = json.loads(subprocess.check_output(
            ['xcrun', 'xcresulttool', 'get', 'test-results', kind, '--path', str(bundle)], cwd=ROOT, text=True))
    summary = payloads['summary']
    required = len(REQUIRED_TESTS['ios-ui'])
    if (summary.get('result') != 'Passed' or summary.get('totalTestCount', 0) < required
            or summary.get('passedTests') != summary.get('totalTestCount')
            or any(summary.get(key) != 0 for key in ('failedTests', 'skippedTests', 'expectedFailures'))):
        raise ValueError('iOS UI tests must all execute and pass without skips or expected failures')
    if summary.get('startTime', 0)*1_000_000_000 < started_ns:
        raise ValueError('iOS UI result summary predates this run')
    nodes = list(test_nodes(payloads['tests'].get('testNodes', [])))
    if not nodes or any(node.get('result') != 'Passed' for node in nodes):
        raise ValueError('iOS UI required test cases did not pass')
    ids = [node.get('nodeIdentifier', '').removesuffix('()').replace('/', '.') for node in nodes]
    # Xcode may qualify a test with its bundle name; retain its class + method.
    return required_ids('ios-ui', ['.'.join(identifier.split('.')[-2:]) for identifier in ids])


def test_counts(lane, started_ns):
    if lane in ('macos', 'android'):
        return xml_test_counts(lane, started_ns)
    if lane == 'ios-ui':
        return ui_test_counts(started_ns)
    return None


def artifact_paths(lane):
    if lane == 'android':
        folder = safe_path(ROOT/'reference-apps/android/app/build/outputs')
        return [folder/'apk/debug/app-debug.apk', folder/'apk/release/app-release-unsigned.apk',
                folder/'mapping/release/mapping.txt']
    if lane.startswith('ios-'):
        sdk = 'iphoneos' if lane == 'ios-device' else 'iphonesimulator'
        app = safe_path(OUTPUT/lane/'Build/Products'/('Debug-'+sdk)/'KenshikiReference.app')
        return [app/'KenshikiReference']
    return []


def collect_artifacts(lane, started_ns):
    paths = artifact_paths(lane)
    artifacts = {}
    for path in paths:
        path = fresh_file(path, started_ns)
        artifacts[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
        if lane.startswith('ios-'):
            artifacts.update(app_tree_hashes(path.parent))
    if lane == 'android':
        validate_release_mapping(paths[-1])
    return artifacts


def validate_release_mapping(path):
    source = path.read_text()
    classes = re.findall(r'^(\S+) -> (\S+):$', source, re.MULTILINE)
    if '# compiler: R8' not in source or not any(original != renamed for original, renamed in classes):
        raise ValueError('Android release requires executed R8 obfuscation evidence')


def app_tree_hashes(app):
    artifacts = {}
    for path in sorted(app.rglob('*')):
        path = safe_path(path)
        if path.is_file():
            artifacts[path.relative_to(ROOT).as_posix()] = hashlib.sha256(path.read_bytes()).hexdigest()
    return artifacts


def execute_stages(lane, log_path, receipt):
    with log_path.open('w') as log:
        for command in commands(lane):
            print('RUN '+lane+': '+' '.join(command), flush=True)
            log.write('COMMAND '+json.dumps(command)+'\n')
            log.flush()
            result = subprocess.run(command, cwd=ROOT, stdout=log, stderr=subprocess.STDOUT, timeout=2400, env=os.environ.copy())
            receipt['stages'].append({'command': command, 'exitCode': result.returncode})
            if result.returncode:
                return False
    return True


def run(lane):
    if lane not in LANES:
        raise ValueError(UNAPPROVED_LANE)
    prepare_outputs(lane)
    started_ns = time.time_ns()
    log_path = OUTPUT/(lane+'.log')
    receipt = {'lane': lane, 'startedUTC': datetime.now(timezone.utc).isoformat(),
               'revision': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
               'gitStatus': subprocess.check_output(['git', 'status', '--porcelain'], cwd=ROOT, text=True),
               'sourceSHA256': input_hashes(), 'host': platform.platform(), 'stages': [],
               'scope': 'Native reference workflows, generated resources and executed builds/tests. Recognition calibration, physical acceptance and manual accessibility remain separate.'}
    passed = False
    try:
        passed = execute_stages(lane, log_path, receipt)
        if passed:
            receipt['tests'] = test_counts(lane, started_ns)
            receipt['artifactSHA256'] = collect_artifacts(lane, started_ns)
    except (OSError, ValueError, subprocess.SubprocessError, ET.ParseError) as error:
        receipt['error'] = type(error).__name__+': '+str(error)
        passed = False
    receipt['endSourceSHA256'] = input_hashes()
    if receipt['endSourceSHA256'] != receipt['sourceSHA256']:
        receipt['error'] = 'Source inputs changed during presentation validation'
        passed = False
    if not passed:
        receipt['artifactSHA256'] = {}
        receipt['artifactStatus'] = 'No artifacts certified by failed validation'
    receipt.update({'passed': passed, 'finishedUTC': datetime.now(timezone.utc).isoformat()})
    if log_path.exists():
        receipt['logSHA256'] = hashlib.sha256(log_path.read_bytes()).hexdigest()
    safe_path(receipt_path(lane)).write_text(json.dumps(receipt, indent=2)+'\n')
    if not passed and log_path.exists():
        print(log_path.read_text()[-14000:])
    print(('PASS ' if passed else 'FAIL ')+lane, flush=True)
    return passed


if __name__ == '__main__':
    require_python()
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--platform', choices=LANES, required=True)
    args = parser.parse_args()
    raise SystemExit(not run(args.platform))
