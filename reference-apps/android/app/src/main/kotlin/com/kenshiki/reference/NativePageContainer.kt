package com.kenshiki.reference

import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.ColumnScope
import androidx.compose.foundation.layout.PaddingValues
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.imePadding
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.widthIn
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.MoreVert
import androidx.compose.material3.NavigationBar
import androidx.compose.material3.NavigationBarItem
import androidx.compose.material3.DropdownMenu
import androidx.compose.material3.DropdownMenuItem
import androidx.compose.foundation.layout.heightIn
import androidx.compose.material3.Button
import androidx.compose.material3.OutlinedButton
import androidx.compose.material3.TextButton
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.HorizontalDivider
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Scaffold
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.material3.TopAppBar
import androidx.compose.material3.contentColorFor
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.graphics.vector.ImageVector
import androidx.compose.ui.Modifier
import androidx.compose.ui.semantics.semantics
import androidx.compose.ui.semantics.testTagsAsResourceId
import androidx.compose.ui.text.style.TextOverflow
import androidx.compose.ui.unit.dp
import com.kenshiki.presentation.design.KenshikiDesign

/** Platform layout only. Scaffold owns system insets; IME reduces the stable action region. */
@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun NativePageContainer(title: String, navigation: PageNavigation?, bottomNavigation: @Composable () -> Unit, developer: PageDeveloperMenu?, body: @Composable ColumnScope.() -> Unit, actions: @Composable ColumnScope.() -> Unit) {
    Scaffold(
        modifier = Modifier.fillMaxSize().imePadding().semantics { testTagsAsResourceId = true },
        topBar = { TopAppBar(title = { Text(title, maxLines = 1, overflow = TextOverflow.Ellipsis) }, navigationIcon = {
            navigation?.let { back -> TextButton(onClick = back.activate) { Text(back.label) } }
        }, actions = {
            developer?.let { menu -> Box {
                IconButton(onClick = menu.open) { Icon(Icons.Default.MoreVert, menu.label) }
                DropdownMenu(expanded = menu.expanded, onDismissRequest = menu.dismiss) {
                    DropdownMenuItem(text = { Text(menu.actionTitle) }, onClick = menu.activate)
                }
            } }
        }) },
        bottomBar = { Surface(color = MaterialTheme.colorScheme.surfaceContainer, contentColor = contentColorFor(MaterialTheme.colorScheme.surfaceContainer)) {
            Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxWidth()) {
                HorizontalDivider()
                Column(modifier = Modifier.widthIn(max = KenshikiDesign.contentMax.toFloat().dp).fillMaxWidth().padding(KenshikiDesign.pageSpacing.toFloat().dp, KenshikiDesign.gapSpacing.toFloat().dp), verticalArrangement = Arrangement.spacedBy(KenshikiDesign.compactSpacing.toFloat().dp), content = actions)
                bottomNavigation()
            }
        } },
    ) { insets: PaddingValues ->
        Column(horizontalAlignment = Alignment.CenterHorizontally, modifier = Modifier.fillMaxSize().padding(insets).verticalScroll(rememberScrollState())) {
            Column(modifier = Modifier.widthIn(max = KenshikiDesign.contentMax.toFloat().dp).fillMaxWidth().padding(KenshikiDesign.pageSpacing.toFloat().dp, KenshikiDesign.gapSpacing.toFloat().dp), verticalArrangement = Arrangement.spacedBy(KenshikiDesign.gapSpacing.toFloat().dp), content = body)
        }
    }
}

data class PageNavigation(val label: String, val activate: () -> Unit)

/** Visual variant selection only; receives no workflow state or events. */
@Composable
fun NativeActionButton(title: String, enabled: Boolean, appearance: ActionAppearance, modifier: Modifier, activate: () -> Unit) {
    val target = modifier.fillMaxWidth().heightIn(min = KenshikiDesign.minimumTargetAndroid.toFloat().dp)
    when (appearance) {
        ActionAppearance.PRIMARY -> Button(activate, target, enabled = enabled) { Text(title) }
        ActionAppearance.SECONDARY -> OutlinedButton(activate, target, enabled = enabled) { Text(title) }
        ActionAppearance.TERTIARY -> TextButton(activate, target, enabled = enabled) { Text(title) }
    }
}

data class PageDestination(val label: String, val selected: Boolean, val icon: ImageVector, val activate: () -> Unit)
data class PageDeveloperMenu(val label: String, val actionTitle: String, val expanded: Boolean, val open: () -> Unit, val dismiss: () -> Unit, val activate: () -> Unit)


/** Root navigation composition stays separate from the reusable page container. */
@Composable
fun NativeTabNavigation(destinations: List<PageDestination>) {
    NavigationBar {
        destinations.forEach { destination -> NavigationBarItem(selected = destination.selected, onClick = destination.activate, icon = { Icon(destination.icon, null) }, label = { Text(destination.label, maxLines = 1, overflow = TextOverflow.Ellipsis) }) }
    }
}
