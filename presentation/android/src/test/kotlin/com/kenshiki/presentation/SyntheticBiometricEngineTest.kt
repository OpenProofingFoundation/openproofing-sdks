package com.kenshiki.presentation

import java.util.UUID
import org.junit.Assert.assertEquals
import org.junit.Test

class SyntheticBiometricEngineTest {
    @Test fun syntheticCoreCompletesAllStagesWithoutIdentityVerdict() {
        val controller = WorkflowController(Capability.BIOMETRIC, engine = SyntheticBiometricEngine())
        controller.send(WorkflowEvent.Start)
        repeat(9) { controller.send(WorkflowEvent.Advance) }
        assertEquals(WorkflowPhase.COMPLETED, controller.state.phase)
        assertEquals(StubScope.DEMONSTRATION_ONLY, controller.state.outcome?.scope)
    }
    @Test fun malformedSessionForeignCapabilityAndTokenReplayFailClosed() {
        val engine = SyntheticBiometricEngine()
        val token = OperationToken(Capability.BIOMETRIC, UUID.randomUUID().toString(), 1, 0)
        val request = OperationRequest(Capability.BIOMETRIC, "workflow.step.biometric.referencePortrait", token)
        val results = mutableListOf<StubCompletion>()
        engine.resolve(request) { returned, result -> assertEquals(token, returned); results.add(result) }
        engine.resolve(request) { _, result -> results.add(result) }
        assertEquals(listOf(StubCompletion.Observed, StubCompletion.Recoverable(RecoveryReason.INVALID_INPUT)), results)
        for (bad in listOf(token.copy(sessionID = "invalid-session"), token.copy(capability = Capability.PASSPORT))) {
            engine.resolve(request.copy(token = bad)) { _, result ->
                assertEquals(StubCompletion.Recoverable(RecoveryReason.INVALID_INPUT), result)
            }
        }
    }
}
