package com.kenshiki.presentation

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class WorkflowTest {
    @Test fun sharedPositiveAndNegativeVectors() {
        val root = File(requireNotNull(System.getProperty("kenshiki.repoRoot")))
        val rows = File(root, "contracts/presentation-v1.vectors.tsv").readLines().drop(1)
        val catalogKeys = Regex("(?m)^    \"([^\"]+)\": \\{").findAll(
            File(root, "design-system/sources/catalog.jsonc").readText()
        ).map { it.groupValues[1] }.toSet()
        assertEquals("Every required shared vector must execute", 11, rows.size)
        rows.forEach { row ->
            val fields = row.split('\t')
            assertEquals(7, fields.size)
            val capability = Capability.entries.single { it.wireValue == fields[1] }
            val controller = WorkflowController(capability, "fixture-session")
            assertCatalog(controller.state, catalogKeys)
            val columns = fields.drop(2).map { it.split(',') }
            assertTrue(columns.all { it.size == columns[0].size })
            var saved: OperationToken? = null
            columns[0].indices.forEach { index ->
                controller.send(parse(columns[0][index], controller.state.pendingOperation, saved))
                if (saved == null) saved = controller.state.pendingOperation
                val state = controller.state
                assertCatalog(state, catalogKeys)
                val context = "${fields[0]} event $index: ${columns[0][index]}"
                assertEquals(context, columns[1][index], state.phase.wireValue)
                assertEquals(context, columns[2][index].toInt(), state.step)
                assertEquals(context, columns[3][index].toInt(), state.generation)
                assertEquals(context, columns[4][index], state.reason?.wireValue ?: "-")
                assertEquals(context, state.phase == WorkflowPhase.COMPLETED, state.outcome != null)
                assertEquals(context, state.phase == WorkflowPhase.PROCESSING, state.pendingOperation != null)
                assertEquals(capability, state.capability)
                assertEquals("workflow.phase.${state.phase.wireValue}", state.messageKey)
                state.outcome?.let { assertEquals(StubScope.DEMONSTRATION_ONLY, it.scope) }
                state.pendingOperation?.let {
                    assertEquals("fixture-session", it.sessionID)
                    assertEquals(capability, it.capability)
                    assertEquals(state.generation, it.generation)
                    assertEquals(state.step, it.step)
                }
                assertTrue(state.actions.all { it.enabled })
                assertEquals(state.actions.size, state.actions.map { it.id }.toSet().size)
            }
        }
    }

    @Test fun presentedActionsAndTerminalStates() {
        Capability.entries.forEach { capability ->
            val controller = WorkflowController(capability)
            repeat(10) {
                controller.state.actions.firstOrNull()?.let { action ->
                    assertEquals("workflow.action.${action.id.wireValue}", action.labelKey)
                    controller.send(action.event)
                }
            }
            assertEquals(WorkflowPhase.COMPLETED, controller.state.phase)
            assertEquals(capability, controller.state.outcome?.capability)
            assertTrue(controller.state.actions.isEmpty())
            val completed = controller.state
            listOf(WorkflowEvent.Start, WorkflowEvent.Advance, WorkflowEvent.Retry, WorkflowEvent.Cancel,
                WorkflowEvent.Interrupt, WorkflowEvent.Restore, WorkflowEvent.SimulateFailure,
                WorkflowEvent.Fail(RecoveryReason.INVALID_INPUT)).forEach(controller::send)
            assertEquals(completed, controller.state)
        }
    }

    @Test fun controllersHaveSeparateCompletionNamespaces() {
        val first = WorkflowController(Capability.BIOMETRIC)
        val second = WorkflowController(Capability.BIOMETRIC)
        listOf(first, second).forEach { controller ->
            listOf(WorkflowEvent.Start, WorkflowEvent.Advance, WorkflowEvent.Advance).forEach(controller::send)
        }
        assertNotEquals(first.state.pendingOperation, second.state.pendingOperation)
        val before = second.state
        second.send(WorkflowEvent.Complete(requireNotNull(first.state.pendingOperation), StubCompletion.Observed))
        assertEquals(before, second.state)
    }

    @Test fun delayedCallbacksAndDuplicateSubmissionsAreFenced() {
        val engine = DeferredEngine()
        val controller = WorkflowController(Capability.PASSPORT, engine = engine)
        listOf(WorkflowEvent.Start, WorkflowEvent.Advance, WorkflowEvent.Advance,
            WorkflowEvent.Advance, WorkflowEvent.Advance).forEach(controller::send)
        assertEquals(1, engine.requests.size)
        assertEquals(1, engine.requests.first().contractVersion)
        assertEquals(Capability.PASSPORT, engine.requests.first().capability)
        assertEquals("workflow.step.passport.mrz", engine.requests.first().stepKey)
        controller.send(WorkflowEvent.Interrupt)
        assertEquals(1, engine.cancelled.size)
        assertEquals(WorkflowPhase.RECOVERABLE, controller.state.phase)
        controller.send(WorkflowEvent.Restore)
        repeat(3) { controller.send(WorkflowEvent.Advance) }
        assertEquals(2, engine.requests.size)
        val before = controller.state
        engine.finish(0)
        assertEquals(before, controller.state)
        engine.finish(1)
        assertEquals(WorkflowPhase.READY, controller.state.phase)
        assertEquals(1, controller.state.step)
        val accepted = controller.state
        engine.finish(1)
        assertEquals(accepted, controller.state)
    }

    @Test fun unavailableEngineProducesNoOutcome() {
        Capability.entries.forEach { capability ->
            val controller = WorkflowController(capability, engine = DeterministicStubEngine(
                StubCompletion.Recoverable(RecoveryReason.SERVICE_UNAVAILABLE)))
            controller.send(WorkflowEvent.Start)
            repeat(3) { controller.send(WorkflowEvent.Advance) }
            assertEquals(WorkflowPhase.RECOVERABLE, controller.state.phase)
            assertEquals(RecoveryReason.SERVICE_UNAVAILABLE, controller.state.reason)
            assertNull(controller.state.outcome)
            assertNull(controller.state.pendingOperation)
            assertFalse(controller.state.actions.isEmpty())
        }
    }

    @Test fun deferredCompletionPublishesStateAndIgnoresInvalidEvents() {
        val engine = DeferredEngine()
        val controller = WorkflowController(Capability.DOCUMENT, engine = engine)
        val snapshots = mutableListOf<WorkflowState>()
        controller.onStateChanged = { snapshots.add(it) }
        listOf(WorkflowEvent.Advance, WorkflowEvent.Retry, WorkflowEvent.Restore).forEach(controller::send)
        assertTrue(snapshots.isEmpty())
        listOf(WorkflowEvent.Start, WorkflowEvent.Advance, WorkflowEvent.Advance,
            WorkflowEvent.Advance).forEach(controller::send)
        assertEquals(listOf(WorkflowPhase.READY, WorkflowPhase.CAPTURING, WorkflowPhase.PROCESSING),
            snapshots.map { it.phase })
        engine.finish(0)
        assertEquals(listOf(WorkflowPhase.READY, WorkflowPhase.CAPTURING, WorkflowPhase.PROCESSING,
            WorkflowPhase.READY), snapshots.map { it.phase })
        assertEquals(1, snapshots.last().step)
        engine.finish(0)
        assertEquals(4, snapshots.size)
        controller.onStateChanged = null
        controller.send(WorkflowEvent.Cancel)
        assertEquals(4, snapshots.size)
        assertEquals(WorkflowPhase.CANCELLED, controller.state.phase)
    }

    private fun parse(text: String, current: OperationToken?, saved: OperationToken?): WorkflowEvent {
        val parts = text.split(':')
        return when (parts[0]) {
            "start" -> WorkflowEvent.Start
            "advance" -> WorkflowEvent.Advance
            "retry" -> WorkflowEvent.Retry
            "cancel" -> WorkflowEvent.Cancel
            "interrupt" -> WorkflowEvent.Interrupt
            "restore" -> WorkflowEvent.Restore
            "simulateFailure" -> WorkflowEvent.SimulateFailure
            "fail" -> WorkflowEvent.Fail(RecoveryReason.entries.single { it.wireValue == parts[1] })
            "complete" -> completion(parts[1], current, saved)
            else -> error("Unknown fixture event: $text")
        }
    }

    private fun completion(name: String, current: OperationToken?, saved: OperationToken?): WorkflowEvent {
        val token = requireNotNull(if (name == "saved") saved else current)
        return when (name) {
            "saved", "current" -> WorkflowEvent.Complete(token, StubCompletion.Observed)
            "foreign" -> WorkflowEvent.Complete(token.copy(sessionID = "other-session"), StubCompletion.Observed)
            "wrongStep" -> WorkflowEvent.Complete(token.copy(step = token.step + 1), StubCompletion.Observed)
            "wrongCapability" -> WorkflowEvent.Complete(token.copy(capability =
                if (token.capability == Capability.PASSPORT) Capability.BIOMETRIC else Capability.PASSPORT),
                StubCompletion.Observed)
            "invalidInput" -> WorkflowEvent.Complete(token, StubCompletion.Recoverable(RecoveryReason.INVALID_INPUT))
            else -> error("Unknown fixture completion: $name")
        }
    }

    private class DeferredEngine : WorkflowEngine {
        val requests = mutableListOf<OperationRequest>()
        val callbacks = mutableListOf<(OperationToken, StubCompletion) -> Unit>()
        val cancelled = mutableListOf<OperationToken>()
        override fun resolve(request: OperationRequest, completion: (OperationToken, StubCompletion) -> Unit) {
            requests.add(request)
            callbacks.add(completion)
        }
        fun finish(index: Int) { callbacks[index](requests[index].token, StubCompletion.Observed) }
        override fun cancel(token: OperationToken) {
            cancelled.add(token)
            val index = requests.indexOfFirst { it.token == token }
            if (index >= 0) finish(index)
        }
    }

    private fun assertCatalog(state: WorkflowState, keys: Set<String>) {
        val emitted = listOf(state.capability.titleKey, state.stepKey, state.messageKey,
            state.accessibilityStatusKey, state.stubNoticeKey) + state.actions.map { it.labelKey } +
            listOfNotNull(state.reason?.messageKey, state.outcome?.messageKey)
        emitted.forEach { assertTrue("Missing catalog key: $it", it in keys) }
    }
}
