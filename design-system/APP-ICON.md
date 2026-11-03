# Kenshiki reference app icon

The icon preserves the Kenshiki concentric-ring mark from
`kenshiki-identity-sdk/Examples/ReactNativeCaptureHost/KenshikiID.icon`: three
open blue rings around a blue core. Its geometry, gradients, foreground layers
and light/dark backgrounds are retained. No passport or face image is used.

Author the reviewed shape and color values in `sources/app-icon.jsonc` and run
`python3 design-system/generate.py`. The compiler validates the closed schema
and ring separation, then writes
`generated/ios/KenshikiReference.icon` with an `icon.json` document and two SVG
layers. The existing deterministic generation and complete inventory checks
cover these files. The core uses Apple's glass material; the rings preserve
their solid gradient. Apple owns masking, lighting and appearance rendering.

Open the generated `.icon` package in Apple Icon Composer to preview default,
dark, tinted and clear appearances. Preserve design changes in the JSONC source;
the generated package is replaced by the compiler. Icon Composer's bundled
`Contents/Executables/ictool` can export previews without flattening the source.

The iOS application target includes this document as a resource and selects
`KenshikiReference` through `ASSETCATALOG_COMPILER_APPICON_NAME`. Xcode compiles
the icon and backward-compatible renditions for the app's iOS deployment floor.
Build output and installed-device metadata must be checked separately from
Icon Composer previews. No runtime workflow or SDK algorithm changes accompany
this artwork.
