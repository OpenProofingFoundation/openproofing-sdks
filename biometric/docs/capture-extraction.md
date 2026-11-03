# Optional native selfie capture extraction

This slice moves the existing owned ARKit selfie acquisition mechanisms into the biometric package. `BiometricSDK` remains the headless portable contract/math product. `BiometricCapture` adds admission, native camera orchestration and an owned PNG-to-RGB bridge; `BiometricCapturePreview` adds the optional ARSCNView surface. The latter two have no mandatory document/passport, storage, backend or model-runtime dependency.

## Source and changes

The source is the identity SDK's `Sources/CaptureSelfie` at revision `b3884d93374ceb5b63743be831c38390794d9562`. Exact source and destination hashes, original ownership and extraction patches belong in `Gates/capture-sources.json`. The original repositories remain intact. This extraction contains no model weights, training media or copied third-party inference runtime. Publication remains a separate source/licence and release decision.

The extraction preserves explicit consent, native permission denial/restriction, TrueDepth availability, frame/depth pairing, blink continuity, depth relief and guide admission, bounded analysis/render workers, timeouts and stale-completion fencing. Changes establish private deep copies of camera/depth buffers before asynchronous use, preserve the original depth-filtering fact and require the host to supply guide geometry from its design system. Unsupported color/depth formats and resource/layout violations fail with typed reasons.

[Apple's depth replacement API](https://developer.apple.com/documentation/avfoundation/avdepthdata/replacingdepthdatamap(with:)) drops camera calibration metadata. The retained evaluator measures least-squares plane residual in the paired map's pixel coordinates; it does not consume calibration or claim metric 3D reconstruction. Distances and engineering policy remain explicit. A local `live` depth assessment is the existing relief/blink observation vocabulary, not a certified PAD or identity result.

## Image contract

The capture result is an oriented PNG rendered from the admitted AR frame, not an original AVCapturePhoto file. The receipt's frame dimensions, orientation and timestamps describe the source frame. The PNG digest identifies encoded bytes. `SelfiePixelBridge` separately snapshots those bytes, verifies their digest, checks encoding/orientation/dimensions before raster allocation and produces owned packed top-to-bottom RGB8 with orientation 1.

The camera decoder applies stricter engineering resource limits than the portable pixel contract: 4,096 per dimension, 8,388,608 pixels and 33,554,432 encoded bytes. These bound declared allocations; they are not a measured physical-device working-set guarantee.

The conversion profile is `apple-imageio-srgb-rgb8-oriented-png-v1`: Apple ImageIO decoding, explicit sRGB, no resizing/interpolation and premultiplied alpha over black. The RGB digest identifies the consumed RGB bytes and is distinct from the PNG digest. This is decoding, not face detection/alignment or a complete ordered-derivation proof. Full source/selection/transform lineage remains a subsequent contract slice.

## Reference integration

The reference app composes these optional products in its guided passport/selfie
journey and separate biometric example. Consent, visibility, lifecycle,
cancellation, retry and late-result decisions remain outside renderers. JSONC
supplies copy and guide styling. The reviewed original image enters the separate
`BiometricInference` adapter; the capture products themselves do not perform
inference, network upload or durable custody.

Shared protected storage/key/attestation mechanisms belong in `foundation/`.
The donor capture custody and its tests are not duplicated into this capability.
Two donor SwiftUI-binding tests do not apply to the UIKit extraction; pure
opening-ID controller tests remain applicable. Android native acquisition remains
unimplemented and its reference workflow remains synthetic.

## Verification

Execution receipts and the required native test inventory are emitted by the capture runner. Capture behavior must execute on an iOS simulator; macOS-only tests do not establish ARKit compilation or execution. Device compilation, simulator execution, native UI/controller integration, hosted Sonar and physical TrueDepth/VoiceOver acceptance are recorded separately. See [the product evidence index](../README.md#build-and-validation) for actual outcomes rather than inferring them from this design description.
