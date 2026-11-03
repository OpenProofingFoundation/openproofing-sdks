package com.kenshiki.reference

import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Modifier
import androidx.compose.ui.platform.testTag
import androidx.compose.ui.semantics.LiveRegionMode
import androidx.compose.ui.semantics.heading
import androidx.compose.ui.semantics.liveRegion
import androidx.compose.ui.semantics.semantics
import com.kenshiki.reference.design.KenshikiMaterialPrimitives

// Immutable localized values; host selects semantic action role and placement.
enum class ActionAppearance { PRIMARY, SECONDARY, TERTIARY }
data class ReferenceAction(val identifier: String, val title: String, val hint: String, val enabled: Boolean, val event: ReferenceEvent, val appearance: ActionAppearance)
data class ReferenceScreen(val title: String, val disclosure: String, val step: String, val message: String, val overview: String, val footerActions: List<ReferenceAction>, val navigation: PageNavigation?, val tabs: List<PageDestination>, val progress: String?, val developerMenu: PageDeveloperMenu?)

/** Material rendering only: supplied state in, typed interaction out. */
@Composable
fun ReferenceRenderer(screen: ReferenceScreen, emit: (ReferenceEvent) -> Unit) {
    NativePageContainer(screen.title, screen.navigation, { NativeTabNavigation(screen.tabs) }, screen.developerMenu, body = {
        screen.progress?.let { Text(it, style = KenshikiMaterialPrimitives.labelTextStyle, color = KenshikiMaterialPrimitives.colorOnSurfaceVariant) }
        Text(screen.step, style = KenshikiMaterialPrimitives.titleTextStyle, modifier = Modifier.testTag("workflow.step").semantics { heading() })
        Text(screen.message, style = KenshikiMaterialPrimitives.bodyTextStyle, modifier = Modifier.testTag("workflow.message").semantics { liveRegion = LiveRegionMode.Polite })
        Text(screen.overview, style = KenshikiMaterialPrimitives.bodyTextStyle)
        Text(screen.disclosure, style = KenshikiMaterialPrimitives.bodyTextStyle, color = KenshikiMaterialPrimitives.colorOnSurfaceVariant, modifier = Modifier.testTag("stub.notice"))
    }, actions = { screen.footerActions.forEach { ReferenceButton(it, emit) } })
}

@Composable
private fun ReferenceButton(action: ReferenceAction, emit: (ReferenceEvent) -> Unit) {
    NativeActionButton(action.title, action.enabled, action.appearance, Modifier.testTag(action.identifier)) { emit(action.event) }
}
