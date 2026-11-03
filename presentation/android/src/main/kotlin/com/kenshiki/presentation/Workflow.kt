package com.kenshiki.presentation

import java.util.UUID
import java.util.Collections

enum class Capability(val wireValue: String, internal val steps: List<String>) {
    BIOMETRIC("biometric", listOf("referencePortrait", "selfie", "compare")),
    DOCUMENT("document", listOf("front", "back", "review")),
    PASSPORT("passport", listOf("mrz", "nfc", "review"));

    val titleKey: String get() = "capability.$wireValue.title"
}

enum class WorkflowPhase(val wireValue: String) {
    IDLE("idle"), READY("ready"), CAPTURING("capturing"), PROCESSING("processing"),
    RECOVERABLE("recoverable"), COMPLETED("completed"), CANCELLED("cancelled")
}

enum class RecoveryReason(val wireValue: String) {
    PERMISSION_DENIED("permissionDenied"), INTERRUPTED("interrupted"),
    SERVICE_UNAVAILABLE("serviceUnavailable"), INVALID_INPUT("invalidInput");

    val messageKey: String get() = "workflow.reason.$wireValue"
}

data class OperationToken(val capability: Capability, val sessionID: String, val generation: Int, val step: Int)

sealed interface StubCompletion {
    data object Observed : StubCompletion
    data class Recoverable(val reason: RecoveryReason) : StubCompletion
}

data class OperationRequest(
    val capability: Capability, val stepKey: String, val token: OperationToken
) {
    val contractVersion: Int = 1
}

/** Demonstration port only. Callbacks use the controller's serialized executor. */
interface WorkflowEngine {
    fun resolve(request: OperationRequest, completion: (OperationToken, StubCompletion) -> Unit)
    fun cancel(token: OperationToken)
}

class DeterministicStubEngine(private val result: StubCompletion = StubCompletion.Observed) : WorkflowEngine {
    override fun resolve(request: OperationRequest, completion: (OperationToken, StubCompletion) -> Unit) {
        completion(request.token, result)
    }
    override fun cancel(token: OperationToken) { /* Stub has no external operation to stop. */ }
}

sealed interface WorkflowEvent {
    data object Start : WorkflowEvent
    data object Advance : WorkflowEvent
    data object Retry : WorkflowEvent
    data object Cancel : WorkflowEvent
    data object Interrupt : WorkflowEvent
    data object Restore : WorkflowEvent
    data object SimulateFailure : WorkflowEvent
    data class Fail(val reason: RecoveryReason) : WorkflowEvent
    data class Complete(val token: OperationToken, val completion: StubCompletion) : WorkflowEvent
}

enum class WorkflowActionID(val wireValue: String) {
    START("start"), ADVANCE("advance"), RETRY("retry"), CANCEL("cancel"),
    RESTORE("restore"), SIMULATE_FAILURE("simulateFailure")
}

data class WorkflowAction(val id: WorkflowActionID, val event: WorkflowEvent) {
    val labelKey: String = "workflow.action.${id.wireValue}"
    val enabled: Boolean = true
}

enum class StubScope(val wireValue: String) { DEMONSTRATION_ONLY("demonstrationOnly") }

/** A demonstration outcome carries no credential, model verdict or identity decision. */
data class StubOutcome(val capability: Capability) {
    val scope: StubScope = StubScope.DEMONSTRATION_ONLY
    val messageKey: String = "workflow.stub.outcome"
}

data class WorkflowState(
    val capability: Capability,
    val phase: WorkflowPhase,
    val step: Int,
    val generation: Int,
    val stepKey: String,
    val messageKey: String,
    val reason: RecoveryReason?,
    val actions: List<WorkflowAction>,
    val pendingOperation: OperationToken?,
    val outcome: StubOutcome?
) {
    val stubNoticeKey: String = "workflow.stub.notice"
    val accessibilityStatusKey: String get() = reason?.messageKey ?: messageKey
}

/** Single owner synchronous demo controller. Hosts serialize events on their UI executor. */
class WorkflowController(
    capability: Capability, private val sessionID: String = UUID.randomUUID().toString(),
    private val engine: WorkflowEngine = DeterministicStubEngine()
) {
    var state: WorkflowState = makeState(capability, WorkflowPhase.IDLE, 0, 0)
        private set
    var onStateChanged: ((WorkflowState) -> Unit)? = null
    private var submitted: OperationToken? = null

    fun send(event: WorkflowEvent) {
        when (event) {
            WorkflowEvent.Start -> if (state.phase == WorkflowPhase.IDLE) {
                replace(WorkflowPhase.READY, generation = state.generation + 1)
            }
            WorkflowEvent.Advance -> advance()
            WorkflowEvent.Retry -> if (state.phase == WorkflowPhase.RECOVERABLE) {
                replace(WorkflowPhase.READY, generation = state.generation + 1)
            }
            WorkflowEvent.Cancel -> if (state.phase in CANCELLABLE_PHASES) {
                invalidate(WorkflowPhase.CANCELLED)
            }
            WorkflowEvent.Interrupt -> fail(RecoveryReason.INTERRUPTED)
            WorkflowEvent.Restore -> if (
                state.phase == WorkflowPhase.RECOVERABLE && state.reason == RecoveryReason.INTERRUPTED
            ) {
                replace(WorkflowPhase.READY, generation = state.generation + 1)
            }
            WorkflowEvent.SimulateFailure -> fail(RecoveryReason.SERVICE_UNAVAILABLE)
            is WorkflowEvent.Fail -> fail(event.reason)
            is WorkflowEvent.Complete -> complete(event.token, event.completion)
        }
    }

    private fun advance() {
        when (state.phase) {
            WorkflowPhase.READY -> replace(WorkflowPhase.CAPTURING)
            WorkflowPhase.CAPTURING -> replace(
                WorkflowPhase.PROCESSING,
                pending = OperationToken(state.capability, sessionID, state.generation, state.step)
            )
            WorkflowPhase.PROCESSING -> submit()
            else -> Unit
        }
    }

    private fun submit() {
        val token = state.pendingOperation ?: return
        if (submitted == token) return
        submitted = token
        engine.resolve(OperationRequest(state.capability, state.stepKey, token)) { returnedToken, result ->
            complete(returnedToken, result)
        }
    }

    private fun fail(reason: RecoveryReason) {
        if (state.phase in ACTIVE_PHASES) {
            invalidate(WorkflowPhase.RECOVERABLE, reason)
        }
    }

    private fun invalidate(phase: WorkflowPhase, reason: RecoveryReason? = null) {
        val pending = state.pendingOperation
        replace(phase, generation = state.generation + 1, reason = reason)
        pending?.let(engine::cancel)
    }

    private fun complete(token: OperationToken, completion: StubCompletion) {
        if (state.phase != WorkflowPhase.PROCESSING || token != state.pendingOperation) return
        when (completion) {
            is StubCompletion.Recoverable -> fail(completion.reason)
            StubCompletion.Observed -> {
                val next = state.step + 1
                if (next < state.capability.steps.size) {
                    replace(WorkflowPhase.READY, step = next, generation = state.generation + 1)
                } else {
                    replace(WorkflowPhase.COMPLETED, outcome = StubOutcome(state.capability))
                }
            }
        }
    }

    private fun replace(
        phase: WorkflowPhase, step: Int = state.step, generation: Int = state.generation,
        reason: RecoveryReason? = null, pending: OperationToken? = null, outcome: StubOutcome? = null
    ) {
        state = makeState(state.capability, phase, step, generation, reason, pending, outcome)
        onStateChanged?.invoke(state)
    }

    private fun makeState(
        capability: Capability, phase: WorkflowPhase, step: Int, generation: Int,
        reason: RecoveryReason? = null, pending: OperationToken? = null, outcome: StubOutcome? = null
    ) = WorkflowState(
        capability, phase, step, generation,
        "workflow.step.${capability.wireValue}.${capability.steps[step]}",
        "workflow.phase.${phase.wireValue}", reason, Collections.unmodifiableList(actions(phase, reason)), pending, outcome
    )

    private fun actions(phase: WorkflowPhase, reason: RecoveryReason?): List<WorkflowAction> = when (phase) {
        WorkflowPhase.IDLE -> listOf(WorkflowAction(WorkflowActionID.START, WorkflowEvent.Start))
        WorkflowPhase.READY, WorkflowPhase.CAPTURING, WorkflowPhase.PROCESSING -> listOf(
            WorkflowAction(WorkflowActionID.ADVANCE, WorkflowEvent.Advance),
            WorkflowAction(WorkflowActionID.CANCEL, WorkflowEvent.Cancel),
            WorkflowAction(WorkflowActionID.SIMULATE_FAILURE, WorkflowEvent.SimulateFailure)
        )
        WorkflowPhase.RECOVERABLE -> listOf(
            if (reason == RecoveryReason.INTERRUPTED) {
                WorkflowAction(WorkflowActionID.RESTORE, WorkflowEvent.Restore)
            } else {
                WorkflowAction(WorkflowActionID.RETRY, WorkflowEvent.Retry)
            },
            WorkflowAction(WorkflowActionID.CANCEL, WorkflowEvent.Cancel)
        )
        WorkflowPhase.COMPLETED, WorkflowPhase.CANCELLED -> emptyList()
    }

    private companion object {
        val ACTIVE_PHASES = setOf(WorkflowPhase.READY, WorkflowPhase.CAPTURING, WorkflowPhase.PROCESSING)
        val CANCELLABLE_PHASES = ACTIVE_PHASES + WorkflowPhase.RECOVERABLE
    }
}
