package com.kenshiki.reference

import android.os.Bundle
import androidx.activity.ComponentActivity
import androidx.activity.OnBackPressedCallback
import androidx.activity.compose.setContent
import androidx.activity.enableEdgeToEdge
import androidx.compose.runtime.mutableStateOf
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import com.kenshiki.presentation.SyntheticBiometricEngine
import com.kenshiki.presentation.DeterministicStubEngine
import com.kenshiki.presentation.Capability
import com.kenshiki.presentation.WorkflowActionID
import com.kenshiki.presentation.WorkflowController
import com.kenshiki.presentation.WorkflowEvent
import com.kenshiki.presentation.WorkflowPhase
import com.kenshiki.presentation.design.KenshikiCopy
import com.kenshiki.reference.design.KenshikiMaterialPrimitives
import com.kenshiki.reference.design.KenshikiMaterialTheme
import com.kenshiki.reference.design.resourceId

sealed interface ReferenceEvent {
    data class Select(val capability: Capability) : ReferenceEvent
    data class Workflow(val event: WorkflowEvent) : ReferenceEvent
    data object Cancel : ReferenceEvent
    data object ShowDeveloperMenu : ReferenceEvent
    data object DismissDeveloperMenu : ReferenceEvent
}

private fun newWorkflowController(capability: Capability): WorkflowController =
    WorkflowController(capability, engine = if (capability == Capability.BIOMETRIC) SyntheticBiometricEngine() else DeterministicStubEngine())

/** Retained tab composition. It owns no Android context or view references. */
class WorkflowSession : ViewModel() {
    val controllers = Capability.entries.associateWith { newWorkflowController(it) }.toMutableMap()
    var selected = Capability.BIOMETRIC
    override fun onCleared() {
        controllers.values.forEach { it.onStateChanged = null; it.send(WorkflowEvent.Cancel) }
    }
}

/** Platform orchestration prepares immutable content. No workflow decisions live in composables. */
class ApplicationHost : ComponentActivity() {
    private lateinit var session: WorkflowSession
    private val preparedScreen = mutableStateOf<ReferenceScreen?>(null)
    private var developerExpanded = false
    private val controller: WorkflowController get() = session.controllers.getValue(session.selected)
    private val workflowBack = object : OnBackPressedCallback(false) {
        override fun handleOnBackPressed() { send(ReferenceEvent.Cancel) }
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        enableEdgeToEdge()
        session = ViewModelProvider(this)[WorkflowSession::class.java]
        bindController()
        onBackPressedDispatcher.addCallback(this, workflowBack)
        render()
        setContent { KenshikiMaterialTheme { preparedScreen.value?.let { ReferenceRenderer(it, ::send) } } }
    }

    override fun onPause() {
        super.onPause()
        controller.send(WorkflowEvent.Interrupt)
    }

    override fun onDestroy() {
        session.controllers.values.forEach { it.onStateChanged = null }
        super.onDestroy()
    }

    private fun send(event: ReferenceEvent) {
        when (event) {
            is ReferenceEvent.Select -> {
                if (event.capability == session.selected) return
                controller.send(WorkflowEvent.Interrupt)
                controller.onStateChanged = null
                session.selected = event.capability
                developerExpanded = false
                bindController()
            }
            is ReferenceEvent.Workflow -> {
                developerExpanded = false
                controller.send(event.event)
            }
            ReferenceEvent.Cancel -> {
                controller.onStateChanged = null
                controller.send(WorkflowEvent.Cancel)
                session.controllers[session.selected] = newWorkflowController(session.selected)
                developerExpanded = false
                bindController()
            }
            ReferenceEvent.ShowDeveloperMenu -> developerExpanded = true
            ReferenceEvent.DismissDeveloperMenu -> developerExpanded = false
        }
        render()
    }

    private fun bindController() {
        val selected = controller
        selected.onStateChanged = { runOnUiThread { if (controller === selected) render() } }
    }

    private fun action(action: com.kenshiki.presentation.WorkflowAction): ReferenceAction = ReferenceAction(
        "action.${action.id.wireValue}", copy(action.labelKey), copy("accessibility.actionHint"), action.enabled,
        ReferenceEvent.Workflow(action.event), ActionAppearance.PRIMARY
    )

    private fun screen(): ReferenceScreen {
        val state = controller.state
        val capability = state.capability.wireValue
        val idle = state.phase == WorkflowPhase.IDLE
        val title = copy("capability.$capability.title")
        val heading = if (idle) copy("capability.$capability.instructionTitle") else copy(state.stepKey)
        val message = if (idle) copy("capability.$capability.intro") else copy(state.outcome?.messageKey ?: state.accessibilityStatusKey)
        val overview = if (idle) copy("capability.$capability.summary") else ""
        val primary = state.actions.filter { it.id != WorkflowActionID.CANCEL && it.id != WorkflowActionID.SIMULATE_FAILURE }.map(::action)
        val navigationLabel = if (state.actions.any { it.id == WorkflowActionID.CANCEL }) copy("workflow.action.cancel") else copy("navigation.back")
        val navigation = if (!idle) PageNavigation(navigationLabel) { send(ReferenceEvent.Cancel) } else null
        val progress = if (!idle) copy("progress.step${state.step + 1}") else null
        val developer = if (BuildConfig.DEBUG) state.actions.firstOrNull { it.id == WorkflowActionID.SIMULATE_FAILURE }?.let(::action) else null
        val tabs = Capability.entries.map { selected ->
            val icon = when (selected) {
                Capability.BIOMETRIC -> KenshikiMaterialPrimitives.biometricIcon
                Capability.DOCUMENT -> KenshikiMaterialPrimitives.documentIcon
                Capability.PASSPORT -> KenshikiMaterialPrimitives.passportIcon
            }
            PageDestination(copy("navigation.tab.${selected.wireValue}"), selected == session.selected, icon) { send(ReferenceEvent.Select(selected)) }
        }
        val developerMenu = developer?.let { action -> PageDeveloperMenu(copy("developer.menu"), action.title, developerExpanded, { send(ReferenceEvent.ShowDeveloperMenu) }, { send(ReferenceEvent.DismissDeveloperMenu) }, { send(action.event) }) }
        return ReferenceScreen(title, copy("demo.disclosure"), heading, message, overview, primary, navigation, tabs, progress, developerMenu)
    }

    private fun render() {
        workflowBack.isEnabled = controller.state.phase != WorkflowPhase.IDLE
        preparedScreen.value = screen()
    }

    private fun copy(key: String): String = getString(KenshikiCopy.fromKey(key).resourceId())
}
