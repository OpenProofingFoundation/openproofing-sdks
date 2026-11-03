# Shared native presentation resources

The iOS reference app uses the layered [Kenshiki Icon Composer asset](APP-ICON.md),
generated from the schema-validated `sources/app-icon.jsonc` alongside the native
presentation resources.

This is the implemented first resource slice of APP-ARCH-001: the three reference workflows share a strict JSONC token/catalog source and generated Swift/Kotlin resources. It is an optional presentation dependency; headless SDKs do not import it. These resources do not implement capture, identity decisions, storage, attestation or BFF policy.

The authoritative files are [sources/tokens.jsonc](sources/tokens.jsonc) and [sources/catalog.jsonc](sources/catalog.jsonc). They define semantic light/dark compatibility colors, contrast pairs, typography/platform scaling mappings, spacing, dimensions, shapes, borders, elevation, reduced-motion settings, icon mapping, component semantics and explicit native platform primitives. New reference containers use system-owned UIKit and Material 3 primitives rather than repainting both platforms with the compatibility palette. See [platform foundations](PLATFORM-FOUNDATIONS.md) for the implemented mappings, availability fallback and evidence boundaries. The catalog includes every workflow state, action, reason, stub disclosure, accessibility label and authored camera/NFC permission description used by the reference apps.

```sh
python3 design-system/generate.py
python3 design-system/generate.py --check
python3 -m unittest discover -s design-system/tests -p 'test_*.py'
swift test --package-path design-system
```

The dependency-free compiler pins JSONC parser/schema subset version 1. The committed schemas use the supported JSON Schema 2020-12 subset; an unknown keyword fails closed. JSONC comments and trailing commas are accepted without changing string contents. Duplicate keys, unknown/missing properties, wrong types/units/ranges, bad or cyclic schema references, unresolved semantic token names, incomplete component variants, disabled text scaling, reduced touch targets and unaudited/low-contrast component color pairs are rejected. Contrast checks evaluate both compatibility palettes at 4.5:1; they do not establish rendered contrast for system materials, dynamic Material colors or live camera surfaces.

Generation records a digest of source, schemas, generator bytes and compiler version. `--check` writes nothing and compares the complete artifact inventory and bytes. Kotlin generated APIs have no Android runtime dependency; the separately generated reference-app adapter exhaustively maps their typed keys to compile-time Android resource IDs. Swift exposes typed messages and native style mappings, including a UIKit-only adapter for semantic colors, freshly resolved preferred fonts and system glass/button configurations with native fallback. The Android reference adapter includes a generated Compose Material 3 theme function and semantic typography/color getters; the shared Kotlin resource API stays independent of Android. The generated XML theme supplies only the platform window shell. Swift package consumers resolve localized strings from the packaged resource bundle by default; direct-source app builds resolve from the main bundle. Callers may explicitly override the bundle without forcing a language. Native hosts apply dynamic platform appearance, system text scaling, reduced motion and accessibility behavior. A renderer must not invent alternate design constants.

`generated/swift/` contains typed accessors, localized strings and `InfoPlist.strings`. `generated/android/` contains typed Kotlin accessors and Android XML resources. No generated file is an independent authoring source.

Only English (`en`) is a supported authored locale in this slice, with a declared English fallback. Expanded `en-XA` and RTL/non-Latin `ar-XB` pseudolocales are generated for development acceptance, including accessibility and permission descriptions. Every catalog entry is required by schema; generation cannot silently omit a locale key. Do not release pseudolocales as reviewed translations. This slice has no dynamic messages: placeholder/plural syntax, additional supported locales and branding overlays are explicitly rejected until their typed schemas, native formatters and tests are implemented. It does not claim full multilingual formatter or host-overlay support.

The source/mutation tests establish generator and static contrast behavior. Native app compilation, rendered layouts at supported scales, screen-reader journeys, device permission UI, focus order and actual VoiceOver/TalkBack acceptance require separate evidence. JSONC definitions alone do not satisfy those gates.
