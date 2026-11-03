# Platform presentation foundations

This implemented reference-app slice shares semantic roles and workflow contracts, while delegating control appearance and interaction to each platform. It replaces the previous generic palette-driven page composition. It is not a finished capture UI or an accessibility acceptance record.

## iOS

UIKit owns the navigation stack, navigation bar, grouped list behavior, semantic colors, typography and system button configurations. JSONC maps content roles to `UIColor` semantic colors and preferred text styles. The generated adapter resolves fonts when called, so the host can refresh them when Dynamic Type changes; the renderer enables automatic text scaling. No custom font point sizes or copied system color hex values define this slice.

Liquid Glass is the controls and navigation layer above content. Native navigation and tab bars retain their system-owned glass appearance. The content primary action uses UIKit `filled()` on all supported releases; the secondary configuration uses `glass()` on iOS 26 and `tinted()` on earlier supported releases, while the tertiary action uses `plain()`. The primary configuration pairs the semantic system-background foreground with the semantic label background. This native filled configuration addresses the disabled-looking title treatment observed with prominent glass in the simulator, without text transformers, tint overrides or hardcoded color values. Clear glass is not used on the plain content background. Content does not receive a fabricated glass surface. Actual rendered acceptance remains separate evidence.

These choices follow Apple's [Materials guidance](https://developer.apple.com/design/human-interface-guidelines/materials), [Liquid Glass overview](https://developer.apple.com/documentation/technologyoverviews/liquid-glass) and [adoption guidance](https://developer.apple.com/documentation/technologyoverviews/adopting-liquid-glass). The OS availability check selects a visual implementation; it makes no workflow decision.

## Android

The reference app uses Jetpack Compose with stable Material 3. The generated `KenshikiMaterialTheme` uses the system light/dark preference, Android 12/API 31 dynamic colors where available, and standard Material 3 light/dark schemes on older supported releases. Compose supplies type scales, button shapes, interactive feedback and component defaults. Generated semantic getters resolve theme typography and color roles without fixed font sizes or copied color values. `Button`, `OutlinedButton`, `TextButton` and `TopAppBar` are the JSONC-declared action and navigation primitives. Shared page spacing and minimum target metrics remain layout policy, rather than attempts to reproduce Material controls.

The generated Android day and night XML themes provide matching light/dark platform window shells for `ComponentActivity`; Compose Material 3 owns the component theme. It does not select the old Material Views widget library or provide a competing palette. The migration is appropriate here because the reference UI is a new scaffold. The current Material Components Views library is in maintenance mode; see its [official notice](https://github.com/material-components/material-components-android/blob/master/docs/getting-started.md). No workflow controller moves into composables.

These choices follow Android's [Material 3 in Compose](https://developer.android.com/develop/ui/compose/designsystems/material3), [dynamic color guidance](https://developer.android.com/develop/ui/compose/designsystems/material3#dynamic_color), [Compose Material 3 release notes](https://developer.android.com/jetpack/androidx/releases/compose-material3), and [edge-to-edge guidance](https://developer.android.com/develop/ui/compose/system/insets).

## Root navigation and page composition

The reference shell contract declares three peer destinations: **Face match**, **Documents** and **Passport**, with localized labels and native icons. iOS uses `UITabBarController` with an independent navigation stack per destination. Android uses Material `NavigationBar`; destination state belongs to the host. These controls navigate SDK areas and never represent workflow progress. Apple’s [tab-bar guidance](https://developer.apple.com/design/human-interface-guidelines/tab-bars) and Android’s [navigation patterns](https://developer.android.com/design/ui/mobile/guides/layout-and-content/layout-and-nav-patterns) describe this hierarchy.

The reusable native page container owns content layout, scrolling, safe-area/system/keyboard insets and a primary action region. It does not own the tab bar. Tab roots have no synthetic Back button. A root instruction page presents one task heading, a concise instruction, a compact three-stage overview and a visible simulation disclosure. Prepared localized `progress.step1` through `progress.step3` identify workflow progress separately. The host supplies any active status and action placement. Developer failure injection is a DEBUG menu item rather than ordinary task content.

These mappings and catalog resources are implemented. Final shell assembly and rendered approval are tracked by the native reference-app work; this document does not turn a generated navigation mapping into installed UI evidence.

## Source and acceptance boundaries

`sources/tokens.jsonc` owns the closed `platformPrimitives` contract: supported native mappings, material scope and fallback, action prominence, Compose Material theme, colors, typography and native component mappings. The schema rejects unknown mappings and replacement raw colors, fixed typography, a non-Material theme, or a glass-only fallback. Existing palette/shape tokens remain compatibility resources; they do not override the new system-owned primitives. The catalog owns chooser summaries, instruction copy and all authored accessibility strings. The generator emits fourteen artifacts, including the Material theme, with deterministic source/schema/compiler identity.

Source validation and native compilation demonstrate contract and API correctness. They do not establish visual quality or WCAG conformance. Platform container assembly, rendered light/dark and scaled-text checks, VoiceOver/TalkBack journeys, keyboard and navigation behavior, and physical-device accessibility acceptance are separate evidence. Real camera/NFC/matching engines and capture-surface design remain future work; the workflows remain explicit demonstrations.
