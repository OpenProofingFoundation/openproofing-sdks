# Apple face alignment route v1

This optional development route supplies aligned RGB112 images to the unchanged
AuraFace aligned-input profile. It does not establish a recognition threshold,
PAD result, document authenticity or final identity acceptance. Android detection
and a Linux detector for a complete FRTE recognition adapter remain separate.

## Exact inputs and route

`BiometricInference` consumes original encoded bytes plus their SHA-256. It checks
the hash before decoding, requires exactly one complete ImageIO image with physical
orientation 1, and bounds encoded bytes to 33,554,432, either dimension to 4,096,
and pixels to 8,388,608 before raster allocation. These are engineering resource
ceilings, not measured face-quality thresholds. sRGB premultiplied RGBA over black
is converted to owned packed RGB8, matching the capture decoder's row convention.

The route identifier is `apple-vision-revision3-five-point-cpp-bilinear-v1`.
`VNDetectFaceLandmarksRequest` revision 3 must return exactly one face. There is no
largest-face selection, bounding-box fallback, multi-route score maximization or
reuse of the previous InsightFace weights. Eye centres use pupils when available,
otherwise eye-contour centroids, ordered by image x. The nose tip is the nose-crest
point furthest from the eye midpoint; mouth corners are outer-lip x extrema.
Normalized Vision coordinates are restored through the observed bounding box into
top-left image coordinates. Missing, nonfinite or out-of-image landmarks fail.
The OS's implementation is still platform supplied; pinning the request revision
does not pin Apple's internal weights across OS releases.

## Portable fit and raster

The implementation is newly authored in `biometric/cpp/src/face_alignment.cpp`.
The inspected NIST-authored [Kabsch-Umeyama paper](../governance/research/papers/1902.03138v6.pdf),
sections 1–3, grounds centering and the orientation-preserving least-squares
objective. We derive a two-dimensional similarity fit directly, rather than
reproducing its rigid-fit SVD algorithm. With centred source `(x,y)` and target
`(u,v)`, `d=sum(x*x+y*y)`, `a=sum(x*u+y*v)/d`, `b=sum(x*v-y*u)/d`.
The transform is `[[a,-b],[b,a]]` plus the translation restoring the centroids.
Its determinant is `a*a+b*b`; reflection is never fitted. Zero/nonfinite scale
and repeated/near-collinear points fail. The covariance determinant floor
`1e-12*d*d` and transform determinant floor `1e-24` are numerical safeguards,
not population calibration or recognition policy.

The 112-pixel destination points are `(38.2946,51.6963)`, `(73.5318,51.5014)`,
`(56.0252,71.7366)`, `(41.5493,92.3655)`, `(70.7299,92.2041)` in the ordering
above. These coordinates and landmark selection were inspected in the owned
identity SDK donor `ThirdParty/FaceMatching/Sources/FaceMatching/FaceMatch+iOS.swift`;
no donor model/runtime, fallback route, threshold or logging code is imported.

The inverse transform maps destination pixel centres `(x+0.5,y+0.5)` into source
coordinates. Subtract 0.5 before bilinear sampling; samples outside the source
are constant black, and positive channel values round with `floor(value+0.5)`.
FP64 geometry disables floating-point contraction and fast math. This is a named
Kenshiki raster profile, not a claim of OpenCV/CoreGraphics warp equivalence.
The exact owned RGB112 digest accompanies each original encoded-source digest.

## Execution and publication

Apple ONNX Runtime 1.22.0 CPU calls the **same** C++ session and preprocessing as
the NIST track. The optional binary archive has an exact URL/checksum and MIT
notice in `biometric/Gates/onnxruntime-apple.json` and `biometric/third-party/onnxruntime/`.
Weights remain external; the reference build packages only the pinned public
model. The neutral BiometricSDK product has no runtime dependency. The Apple runtime archive requires macOS 13.3 for the development host, so this unpublished package now declares macOS 13.3 instead of 13.0; the iOS 18 floor is unchanged.

The actor serializes native ownership. Cancellation fences publication; it cannot
interrupt a synchronous ORT kernel. Images and embeddings are not logged, uploaded
or persisted by this module. Releasing application references is not cryptographic
memory zeroization. The reference controller binds completions to operation ID and
both exact image digests, refuses nonfinite/out-of-range observations, and discards
late results after replacement or backgrounding. Scores remain cosine observations;
no arbitrary match cutoff is introduced.
