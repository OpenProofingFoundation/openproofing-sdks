# **Unified Engineering Specification: Edge-Native Geodesic Biometric & Document Verification Engine**

**Document ID:** SPEC-IDBIO-200  
**Version:** 3.0 (Unified Biometric & Document Architecture)  
**Status:** Working draft; proposed requirements and performance targets are not validation results.  
Normative Standards: NIST FRTE 1:1 Verification API, ISO/IEC 30107-3 (PAD), ISO/IEC 7810 (ID-1/ID-3 Physical Geometry), ICAO Doc 9303 (eMRTD Cryptographic Verification), ISO/IEC 18013-5 (mDL), ANSI D20 / AAMVA CDS (PDF417 Barcode Standard)

# **1\. System Overview & Architectural Unification**

This specification defines a unified, zero-trust edge verification architecture that executes both 1:1 Facial Biometrics and Physical/Digital Identity Document Authentication (ID-1 & ID-3) using shared metrological gates, shared NPU operators, and a unified hyperspherical metric learning framework—eliminating third-party document template databases (e.g., Regula) and server-side biometric pipelines.

## **1.1 Core Architectural Invariants**

* **Shared Mathematical Primitives:** Both facial verification and physical document authentication operate as **keypoint-driven projective orthorectification** followed by **hyperspherical projection onto S⁵¹¹** and **Central Difference Convolution (CDCN) material liveness**.  
* **Clean-Room & Indemnified Provenance:** All neural weights MUST originate from either (a) random (Kaiming) initialization trained exclusively on procedural 3D graphics renders (DigiFace-1M pipeline / procedural synthetic ID-1 cards) plus commercially indemnified, BIPA/CUBI/GDPR Article 9 consented corpora (≥ 50,000 subjects), OR (b) an explicitly licensed commercial enterprise weight artifact with contractual indemnification. Generative models conditioned on scraped web weights (Vec2Face, DCFace, Arc2Face) and unindemnified academic weights (buffalo\_l) are strictly prohibited.  
* **Local Biometric Processing & Controlled Identity Exchange:** Production biometric inference MUST execute on device. Raw camera frames, document crops and biometric embeddings MUST NOT leave the device through the production verification protocol. Identity fields required for authorized AAMVA verification and phone identifiers required for authorized CAMARA verification MAY cross their designated service boundaries. Each exchange MUST define its minimum fields, purpose, recipient, retention and session binding. A hash alone cannot replace fields a verification service requires. Sensitive local buffers MUST follow an explicit lifetime and erasure policy covering application-owned buffers and identifying platform or inference-runtime copies outside direct control. Local research evidence retention is a separate, explicit workflow; production signing does not authorize it.  
* **Fork-Safe Single-Core Determinism (NIST Track A):** The Linux C++17 compliance build (`libfrvt_11`) MUST enforce strict single-threaded execution (IntraOp \= 1, InterOp \= 1, OMP\_NUM\_THREADS \= 1\) to survive NIST `fork()` multiprocessing, completing template extraction in ≤ 150 ms on a single core of an Intel Xeon Gold 6254 CPU @ 3.10GHz (NIST ceiling: 2,000 ms).

## 1.2 Combined Verification Architecture

The replacement architecture combines the existing ID Cadastral capture and spatial-analysis foundation with the proposed biometric and document models and external verification services. These are complementary parts of one verification flow. No individual component is required to establish the entire identity claim.

| Evidence path | Contribution to the combined decision |
| --- | --- |
| ID Cadastral | Source-linked geometry, observed perimeter, texture, color, connected regions, topology, adjacency, material-score patterns and surrounding-scene relationships; temporal evidence where captured |
| Proposed document models | Jurisdiction/revision similarity and local anomaly or material observations, evaluated alongside Cadastral evidence |
| Face matching and PAD | Comparison of the present human with the credential portrait, together with evaluated presentation and injection defenses |
| AAMVA verification | Issuing-record checks for the submitted licence fields, limited to the actual service response and coverage |
| CAMARA verification | Phone-related verification signals, limited to the selected API's actual semantics and response |
| Session binding | Links the relevant capture, portrait derivation, model results and external-service results to the same verification attempt |

Cadastral observations MUST retain source coordinates, transforms and provenance. Model-specific masked or resized inputs are derived analysis branches; they MUST NOT replace the native spatial evidence or erase portrait-boundary and surrounding-scene observations. Existing host research tools are an implementation foundation, not a claim that every operation already ships or makes automated authentication decisions on device.

The relying-party policy MUST identify required checks for each credential path, distinguish pass, fail, unavailable, unsupported and inconclusive outcomes, and define retry or recovery behavior. External responses MUST be bound to the verification attempt and the submitted claims through a server-verifiable mechanism. Co-occurring signals MUST NOT be assumed independent or multiplied into a confidence score without supporting evaluation.

Acceptance MUST evaluate the complete flow at an explicit operating point, including genuine-user rejection and joint attack acceptance. Portrait substitution using otherwise valid licence data is one required scenario; testing MUST exercise the combined spatial, material, face, issuer-record, phone and session controls applicable to that scenario. Component benchmarks remain useful diagnostics. Regula and InsightFace removal gates MUST be tracked separately against the capabilities each replacement supplies.

# **2\. Unified Subsystem Matrix (Face \+ Document Parity)**

| Pipeline Stage | Track A: NIST FRTE 1:1 Harness | Track B1: Production Edge Face Pipeline | Track B2: Production Edge Document Pipeline (ID-1 / ID-3) |
| :---- | :---- | :---- | :---- |
| Execution Target | Ubuntu 22.04 (x86\_64 AVX-512, 1 Core) | Apple Neural Engine / Android NPU (FP16) | Apple Neural Engine / Android NPU \+ CoreNFC |
| Layer 1: Physics Gate | Bypassed (Static frvt::Image buffer) | Active Screen-Flash Timestamp Lock \+ 8-12 Hz Differential Tremor Parallax | IMU-Synchronized Multi-Angle Specular Sweep (Δθ\_IMU in \[5°, 12°\]) |
| Layer 2A: Keypoint Regress | SCRFD-500M (5-Pt Facial Landmarks) | SCRFD-500M (5-Pt Facial Landmarks) | SCRFD-Doc (4 Outer Card Corners \+ Inner Portrait & MRZ Boxes) |
| Layer 2B: Orthorectification | 2D Procrustes Similarity Warp (M in ℝ²ˣ³ \-\> 112×112) | 2D Procrustes Similarity Warp (M in ℝ²ˣ³ \-\> 112×112) | 8-DOF Projective Homography (H in ℝ³ˣ³ \-\> 856×540 @ 10 px/mm) |
| Layer 2C: Material PAD | Bypassed (Not tested in FRTE 1:1) | MobileViT-CDCN \+ Subsurface Red/Blue Dermal Albedo | MobileViT-CDCN (Substrate/Guilloche) \+ OVD Kinegram Diffraction Gate |
| Layer 3: Metric Projection | IResNet-50 (x\_probe in S⁵¹¹) | IResNet-50 / MobileFaceNet (x\_probe in S⁵¹¹) | Dual-Head: (1) De-Artifacted Portrait \-\> x\_ref in S⁵¹¹, (2) Jurisdiction Centroid d in S⁵¹¹ |
| Layer 4: Cryptographic Bind | 2,052-byte std::vector\<uint8\_t\> | Secure Enclave CBOR Assertion \+ Session Heartbeat | ICAO 9303 EF.SOD / mDL COSE Signature \+ Front-OCR-to-PDF417 Parity |

# **3\. Shared Layer 1: OIS- and Vehicle-Immune Physical Provenance Gate**

Before any frame enters the NPU for facial or document inference, the capture pipeline enforces hardware-attested physical provenance that is immune to mobile Optical Image Stabilization (OIS/EIS) and moving-vehicle macro-accelerations:

## **3.1 Mode 1 — Biometric Face Capture (Anti-Injection & Liveness Lock)**

1. **Active Photometric Exposure-Timestamp Coherence:**  
   * The display emits a nonce-seeded, pseudo-random binary sequence of chromatic pulses during the 400 ms capture window.  
   * The pipeline correlates hardware CMSampleBuffer CMOS exposure timestamps (t\_CMOS) against display vsync emission timestamps (t\_display) across facial skin regions.  
   * **Rejection Condition:** Virtual camera drivers, WebRTC injection hooks, or real-time generative deepfake pipelines introduce ≥ 2 frames (Δt \> 33 ms) of synthesis/encoding latency or fail dermal red-to-blue subsurface scattering ratios, triggering immediate rejection.  
2. **High-Frequency Differential Parallax:**  
   * Apply a 4th-order Butterworth bandpass filter (8 Hz \- 12 Hz) to IMU gyroscope telemetry ω\_BP(t) to isolate involuntary human physiological hand tremor—above vehicle vibration (\< 3 Hz) and beyond OIS actuator damping at close focal distances.  
   * Require nonzero differential optical flow ||Δp\_face \- Δp\_background||₂ \> ε\_3D phase-locked to ω\_BP(t).

## **3.2 Mode 2 — Physical ID-1 Document Capture (Hologram & Substrate Lock)**

To defeat flat color photocopies, desktop prints, and digital screen replays of driver's licenses without relying on proprietary template rules:

1. **IMU-Driven Specular & Diffraction Sweep:**  
   * Over a 500 ms capture window (15 frames at 30 fps), track integrated IMU pitch/roll angle Δθ\_IMU \= ∫ ω(t)dt across a natural 5° \- 12° hand tilt.  
2. **Anisotropic OVD Grating Verification:**  
   * Track the spectral chroma shift ΔC(u, t) in the HSV/CIELAB color space across the orthorectified card surface as a function of Δθ\_IMU.  
   * **Acceptance Condition:** Genuine RealID polycarbonate/Teslin substrates embedded with Optically Variable Devices (OVDs / kinegrams / rainbow holograms) exhibit spatially localized, high-frequency chromatic diffraction gradients (||∇\_θ C\_OVD|| ≥ τ\_grating) that shift predictably with Δθ\_IMU, whereas paper prints exhibit flat isotropic reflection and OLED screen replays exhibit uniform glass specular saturation plus RGB subpixel Moiré.

# **4\. Shared Layer 2: Metrological Orthorectification & Material PAD**

Both modalities share a single NPU detection/alignment paradigm and a unified Central Difference Convolution (MobileViT-CDCN) architecture.

## **4.1 Facial Orthorectification (5-Point Affine Similarity Transform)**

1. **Detector (SCRFD-500M):** Extracts candidate face boxes B\_k and 5-point landmarks P\_k in ℝ⁵ˣ².  
2. **Multi-Subject Foreground Ranking (NIST & Production):** When K \> 1 faces appear in frame, rank candidates by area-centrality weight:  
   W\_k \= Area(B\_k) × exp(-||c\_k \- c\_img||₂² / (2σ²))  
3. **Canonical Warp:** Solve the closed-form 2D Procrustes similarity transform M in ℝ²ˣ³ mapping P\_k to the 112 × 112 canonical reference coordinates:  
   P\_ref \= \[\[38.2946, 51.6963\], \[73.5318, 51.5014\], \[56.0252, 71.7366\], \[41.5493, 92.3655\], \[70.7299, 92.2041\]\]

## **4.2 Document Orthorectification (4-Corner 8-DOF Homography)**

1. **Detector (SCRFD-Doc, 0.6 MB):** A re-trained single-shot keypoint head using the identical SCRFD architecture regresses:  
   * The 4 physical outer vertices of the document V\_doc \= {v\_TL, v\_TR, v\_BR, v\_BL} in ℝ⁴ˣ².  
   * The inner portrait bounding box B\_portrait and 5 facial landmarks of the printed/laser-engraved ID portrait.  
2. **Metric Homography Warp (H in ℝ³ˣ³):**  
   * For **ID-1 Cards (Driver's Licenses, 85.60 × 53.98 mm):** Solve the Direct Linear Transform (DLT) 8-DOF perspective homography H mapping V\_doc onto a metric **856 × 540 pixel** plane (exact 10.0 pixels/mm metrological scale).  
   * For **ID-3 Passports (125.0 × 88.0 mm):** Map onto a metric **1250 × 880 pixel** plane (10.0 pixels/mm).  
   * **Sub-Millimeter Aspect Gate:** Prior to warping, project the 3D corner rays using camera intrinsics K to verify the physical aspect ratio matches ISO/IEC 7810 (r\_ID1 \= 1.5858 ± 0.015)—instantly rejecting non-standard crop injections.  
3. **Portrait De-Artifacting & Extraction:**  
   * Pass the inner portrait crop through a lightweight 2.1 MB shallow U-Net (Model\_DeArtifact) to strip holographic security overlays, laser-engraved tactile lines, and laminate glare without altering underlying facial geometry, then apply the 5-point similarity warp M to produce the clean 112 × 112 reference tensor I\_ref.

# **5\. Shared Layer 3: Hyperspherical Metric Space (Face & Zero-Regula Document Auth)**

Both face matching and document template verification operate on the 512-dimensional unit hypersphere S⁵¹¹ using **AdaFace** quality-adaptive angular margin loss:

* Feature norm proxy: z\_norm \= clip((||x\_hat||₂ \- μ\_z) / (σ\_z / h), \-1, 1\)  
* Adaptive margins: g\_angle \= \-m · z\_norm and g\_add \= m · z\_norm \+ m  
* Fixed hyperparameters: Scale s \= 64.0, base margin m \= 0.40, concentration h \= 0.333, embedding dimension d \= 512\.  
* Degradation & Color-Space Standardization: Input tensors standardize strictly on RGB channel ordering normalized to \[-1.0, 1.0\] via (pixel \- 127.5) / 128.0, with 30% low-resolution (32px-45px IOD) and 15% single-channel grayscale luminance replication during training.

## **5.1 Biometric Face Embedding (Model\_FaceEmbed)**

* **Input:** 112 × 112 × 3 strictly RGB tensor normalized to \[-1.0, 1.0\].  
* **Outputs:**  
  1. Pre-normalized feature norm q\_face \= ||x\_hat||₂ (used as the metrological image quality gate; frames with q\_face \< τ\_qual are dropped).  
  2. Unit vector x \= x\_hat / q\_face in S⁵¹¹.  
* **1:1 Face Verification:** Compute geodesic cosine similarity between the live selfie probe x\_probe and the credential reference portrait x\_ref:  
  S\_face \= x\_probe · x\_ref

## **5.2 Hyperspherical Document Authentication (Model\_DocEmbed — Replacing Regula)**

Instead of shipping a 200MB database of 16,000+ static reference images and brittle pixel rules, the orthorectified 856 × 540 ID-1 card (with the variable PII portrait and text regions masked via standardized layout coordinates) is projected onto a 512-D unit hypersphere via a lightweight 3.8 MB projection head (MobileNetV3-AdaFace):

* **Class Centroids (307 KB total footprint):** Each supported issuing jurisdiction and revision c in {1 ... C} (50 US States \+ DC/Territories × 2–3 active RealID/Standard revisions \= \~150 centroids) is represented solely by a single 512-dimensional unit centroid vector w\_c in S⁵¹¹ (150 × 512 × 4 bytes \= 307.2 KB).  
* **Zero-Database Authenticity Check:**  
  1. Compute the document embedding d \= f\_doc(I\_ID1\_masked) in S⁵¹¹.  
  2. Verify angular proximity to the claimed jurisdiction centroid w\_c\* (derived from the AAMVA PDF417 Issuer Identification Number IIN):  
     S\_doc \= d · w\_c\* ≥ τ\_doc\_manifold  
  3. Any counterfeit layout, altered background guilloche frequency, non-standard typography, or pasted portrait boundary perturbation pushes d outside the tight angular cone of w\_c\*.

# **6\. Document Cryptographic & Structural Cross-Verification**

## **6.1 Path 1: Physical ID-1 (US / Canadian Driver's Licenses)**

1. **Back Barcode Decode:** Decode the raw ANSI D20 / AAMVA CDS byte stream from the back PDF417 2D barcode, verifying the header (`@ \n \x1E \r ANSI` ), the 6-digit Issuer Identification Number (IIN), AAMVA version number, and mandatory data elements (DAQ, DCS, DAC, DBB, DBA, DAG).  
2. **Front-to-Back Cross-Modal Parity:** Execute an on-device micro-OCR pass on the orthorectified 856 × 540 front image and enforce deterministic string/date Levenshtein parity against the decoded PDF417 payload:  
   Parity(OCR\_front({Name, DOB, Exp, DocNum}), PDF417\_back) \= 1.0  
3. **Portrait Vector:** Extract x\_ref in S⁵¹¹ from the de-artifacted front portrait crop.

## **6.2 Path 2: Physical ID-3 Passports & e-IDs (ICAO Doc 9303\)**

1. **Optical MRZ Seed:** Extract the 2-line (88-character TD3) or 3-line (90-character TD1) Machine Readable Zone via deterministic monospaced OCR-B recognition, validating all Modulo-10 check digits across Document Number, DOB, and Expiration Date.  
2. **NFC Contactless IC Extraction:** Compute the SHA-1 / SHA-256 Basic Access Control (BAC) or Password Authenticated Connection Establishment (PACE) keys from (DocNum, DOB, Exp) and open an encrypted ISO/IEC 14443 channel via device NFC.  
3. **Cryptographic Passive & Active Authentication:**  
   * Read EF.COM, DG1 (MRZ biometric metadata), DG2 (ISO/IEC 19794-5 high-resolution JPEG2000 facial portrait), and EF.SOD (Document Security Object).  
   * Verify the EF.SOD CMS digital signature against the bundled ICAO Public Key Directory (PKD) / CSCA Master List and validate the SHA-256 hashes of DG1 and DG2.  
   * Execute Active Authentication (DG15) or Chip Authentication (DG14) via an ephemeral challenge nonce to prove the physical RFID chip was not cloned.  
4. **Portrait Vector:** Project the cryptographically verified DG2 chip portrait directly to x\_ref in S⁵¹¹.

## **6.3 Path 3: Mobile Driver's Licenses (ISO/IEC 18013-5 mDL)**

1. Establish local device engagement via NFC/BLE, verify the Issuing Authority Certificate Authority (IACA) COSE\_Sign1 signature over the Mobile Security Object (MSO), verify the DeviceAuth ECDSA signature, and project the authenticated portrait byte array to x\_ref in S⁵¹¹.

# **7\. Track A Normative C++ Implementation (NIST FRTE 1:1 Harness)**

For the NIST FRTE 1:1 submission (`libfrvt_11_<org>_<seq>.so`), the document layers are bypassed at compile time (-DBUILD\_NIST\_FRTE\_11=1), exposing only the fork-safe, 8-bit/24-bit compliant facial template extractor and geodesic comparator:\#include "frvt11.h"

\#include \<onnxruntime\_cxx\_api.h\>

\#include \<immintrin.h\>

\#include \<algorithm\>

\#include \<cmath\>

\#include \<cstdlib\>

\#include \<cstring\>

namespace FRVT\_11 {

FRVT::ReturnStatus ImplFRVT11::initialize(const std::string \&configDir) {

    // Enforce strict single-thread execution across NIST fork() workers

    setenv("OMP\_NUM\_THREADS", "1", 1);

    setenv("MKL\_NUM\_THREADS", "1", 1);

    setenv("OPENBLAS\_NUM\_THREADS", "1", 1);

    setenv("VECLIB\_MAXIMUM\_THREADS", "1", 1);

    Ort::SessionOptions opts;

    opts.SetIntraOpNumThreads(1);

    opts.SetInterOpNumThreads(1);

    opts.SetExecutionMode(ExecutionMode::ORT\_SEQUENTIAL);

    opts.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT\_ENABLE\_ALL);

    // Initialize SCRFD-500M detector and AdaFace IResNet-50 sessions...

    return FRVT::ReturnStatus(FRVT::ReturnCode::Success);

}

FRVT::ReturnStatus ImplFRVT11::createFaceTemplate(

    const std::vector\<FRVT::Image\> \&faces,

    FRVT::TemplateRole role,

    std::vector\<uint8\_t\> \&templ,

    std::vector\<FRVT::EyePair\> \&eyeCoordinates)

{

    templ.resize(2052, 0);

    if (faces.empty() || faces\[0\].data \== nullptr) {

        return FRVT::ReturnStatus(FRVT::ReturnCode::ImageFormatError);

    }

    const FRVT::Image \&img \= faces\[0\];

    std::vector\<uint8\_t\> rgbBuffer(static\_cast\<size\_t\>(img.width) \* img.height \* 3);

    // Bit-depth normalization guardrail: handle 8-bit Grayscale & 24-bit RGB

    if (img.depth \== 8\) {

        const uint8\_t\* src \= img.data.get();

        for (size\_t i \= 0; i \< static\_cast\<size\_t\>(img.width) \* img.height; \++i) {

            rgbBuffer\[i \* 3 \+ 0\] \= src\[i\];

            rgbBuffer\[i \* 3 \+ 1\] \= src\[i\];

            rgbBuffer\[i \* 3 \+ 2\] \= src\[i\];

        }

    } else if (img.depth \== 24\) {

        std::memcpy(rgbBuffer.data(), img.data.get(), rgbBuffer.size());

    } else {

        return FRVT::ReturnStatus(FRVT::ReturnCode::ImageFormatError);

    }

    // 1\. Run SCRFD-500M \-\> select primary foreground face via Area \* Centrality weight W\_k

    // 2\. Apply 2D Procrustes similarity warp M \-\> 112x112x3 RGB float tensor in \[-1.0f, 1.0f\]

    // 3\. Run single-core AVX-512 IResNet-50 inference \-\> raw 512-D vector x\_hat

    // 4\. L2-normalize to unit hypersphere S^511 and write 2048B vector \+ 4B norm q

    return FRVT::ReturnStatus(FRVT::ReturnCode::Success);

}

FRVT::ReturnStatus ImplFRVT11::matchTemplates(

    const std::vector\<uint8\_t\> \&verifTemplate,

    const std::vector\<uint8\_t\> \&enrollTemplate,

    double \&similarity)

{

    if (verifTemplate.size() \< 2048 || enrollTemplate.size() \< 2048\) {

        similarity \= 0.0;

        return FRVT::ReturnStatus(FRVT::ReturnCode::VerifTemplateError);

    }

    const float\* x\_probe \= reinterpret\_cast\<const float\*\>(verifTemplate.data());

    const float\* x\_ref   \= reinterpret\_cast\<const float\*\>(enrollTemplate.data());

    float cos\_theta \= avx512\_dot\_f32\_512(x\_probe, x\_ref);

    float clamped   \= std::max(-1.0f, std::min(1.0f, cos\_theta));

    // Piecewise linear calibration anchoring FMR \= 10^-6 knee (0.38) to 500.0

    if (clamped \< 0.38f) {

        similarity \= static\_cast\<double\>((clamped \+ 1.0f) / 1.38f \* 500.0f);

    } else {

        similarity \= static\_cast\<double\>(500.0f \+ ((clamped \- 0.38f) / 0.62f \* 500.0f));

    }

    return FRVT::ReturnStatus(FRVT::ReturnCode::Success);

}

} // namespace FRVT\_11

# **8\. Unified Footprint & Release Acceptance Criteria**

## **8.1 Total On-Device Binary & Weight Footprint (Track B Mobile SDK)**

* SCRFD-500M (Face 5-Pt Detector): **0.8 MB**  
* SCRFD-Doc (ID-1 / ID-3 4-Corner \+ Portrait Detector): **0.6 MB**  
* Model\_DeArtifact (Shallow U-Net ID Portrait Restoration): **2.1 MB**  
* MobileViT-CDCN (Shared Face & Document Material PAD): **3.2 MB**  
* Model\_DocEmbed \+ 150 State/Jurisdiction Centroids: **4.1 MB**  
* Model\_FaceEmbed (MobileFaceNet FP16 / Pruned IResNet-50 FP16): **4.5 MB to 22.0 MB**  
* **Total Edge SDK Footprint:** **\~15.3 MB to 32.8 MB** (vs. 200 MB+ for legacy Regula \+ third-party biometric stacks).

## **8.2 Release Verification Matrix**

| Verification Gate | Target Requirement | Validation Protocol |
| :---- | :---- | :---- |
| 1\. Pre-NIST Local Proxy (IJB-C) | TAR ≥ 0.930 @ FAR \= 10⁻⁶ (Clean-Room) or ≥ 0.965 (Top-50 Track) | Local evaluation of compiled .so on IARPA Janus Benchmark-C 1:1 protocol |
| 2\. NIST Single-Core & Fork Safety | ≤ 150 ms (P99) on 1 Core Xeon 6254; strictly 1 thread/process | Official usnistgov/frvt validation harness across 36 concurrent forked processes |
| 3\. Bit-Depth & Channel Parity | max |  |
| 4\. ID-1 Metric Homography Accuracy | Corner reprojection error ≤ 0.25 mm (2.5 px @ 856×540) | Metrological validation across skewed (0° \- 40°) physical ID-1 captures |
| 5\. Document Counterfeit Rejection | ≥ 99.2% rejection of paper prints, screen replays, and font edits | Cross-check of IMU OVD diffraction sweep \+ hypersphere centroid cone w\_c |
| 6\. Face & Doc PAD (ISO 30107-3) | APCER ≤ 1.0% across Level 1–3 physical & injection attacks | Active photometric timestamp lock \+ MobileViT-CDCN testbench |

# **Appendix A: Layer 4 Hardware-Attested Assertion Wire Protocol & Schema (SPEC-IDBIO-200)**

This appendix defines the normative wire contract for **Layer 4** of SPEC-IDBIO-200. It specifies both the over-the-wire **CBOR / COSE\_Sign1 (RFC 9052\)** binary structure signed inside the device Secure Enclave / StrongBox TEE and the deterministic **JSON Schema (Draft-07, AJV-strict compatible)** used by the native-to-JS bridge (`BridgeValidation.ts`) and relying-party verification gateways.

## **A.1 Cryptographic Envelope (COSE\_Sign1 Wire Structure)**

To ensure zero raw biometric or PII egress while proving that both the face match and document verification occurred inside an attested physical session, the Secure Enclave signs the canonical CBOR-encoded AssertionPayload using its hardware-bound ECDSA P-256 (ES256, COSE algorithm \-7) private key:COSE\_Sign1 \= \[

    protected:   bstr .cbor { 1: \-7, 4: kid\_bytes }, // alg: ES256 (-7)

    unprotected: { 33: x5chain\_attestation\_certs },  // App Attest / StrongBox cert chain

    payload:     bstr .cbor AssertionPayload,        // Deterministic CBOR (RFC 8949 Sec 4.2)

    signature:   bstr (64-byte P-256 R||S signature)

\]

### **A.1.1 Telemetry & Physics Coherence Bitmask (telemetryBitmask)**

The `telemetryBitmask` is an unsigned 16-bit integer (0x0000 to 0xFFFF) encoding the deterministic pass/fail state of every Layer 1–3 hardware and metrological gate:

| Bit | Hex Mask | Gate Name | Normative Condition |
| :---- | :---- | :---- | :---- |
| 0 | 0x0001 | ENCLAVE\_ATTEST\_OK | Hardware key attestation & OS integrity verified |
| 1 | 0x0002 | PHOTOMETRIC\_LOCK\_OK | Screen-pulse to CMOS exposure delta Δt ≤ 1 frame |
| 2 | 0x0004 | TREMOR\_PARALLAX\_OK | 8-12 Hz bandpass IMU tremor phase-locked to 3D optical parallax |
| 3 | 0x0008 | AMBIENT\_SANITY\_OK | Barometric / magnetometer micro-variance non-synthetic |
| 4 | 0x0010 | FACE\_PAD\_CDCN\_OK | MobileViT-CDCN \+ dermal red/blue subsurface scattering pass |
| 5 | 0x0020 | DOC\_ASPECT\_METRIC\_OK | 4-corner homography matches ISO 7810 aspect ratio (±0.015) |
| 6 | 0x0040 | DOC\_OVD\_GRATING\_OK | Anisotropic kinegram diffraction shift verified across Δθ\_IMU |
| 7 | 0x0080 | DOC\_HYPERSPHERE\_OK | Document vector d · w\_c\* ≥ τ\_doc\_manifold |
| 8 | 0x0100 | DOC\_CRYPTO\_PARITY\_OK | Front OCR \== Back PDF417 OR ICAO 9303 EF.SOD / mDL COSE valid |
| 9 | 0x0200 | VOLATILE\_SCRUB\_OK | memset\_s zeroization of x\_probe, x\_ref, and raw PII confirmed |

* **ID-1 Physical Flow Required Mask:** 0x03FF (All bits 0..9 set \= decimal 1023).  
* **ICAO 9303 NFC / ISO 18013-5 mDL Flow Required Mask:** 0x031F (Bits 0..4, 8, 9 set \= decimal 799; optical document geometry/OVD bits 5..7 bypassed in favor of cryptographic chip signature).

## **A.2 JSON Schema Definition (AJV Draft-07 Strict Mode)**

For React Native bridge validation (`BridgeValidation.ts`) and relying-party verification, the decoded assertion payload conforms to the following strict JSON Schema:{

  "\$schema": "json-schema-draft-07",

  "\$id": "urn:kenshiki:spec-idbio-200:v3:Layer4AssertionPayload",

  "title": "Layer4AssertionPayload",

  "description": "Hardware-attested zero-knowledge biometric and document verification assertion (SPEC-IDBIO-200).",

  "type": "object",

  "additionalProperties": false,

  "required": \[

    "specVersion",

    "sessionId",

    "serverNonce",

    "timestampMs",

    "hardwareAttestation",

    "physicsGate",

    "biometricVerification",

    "documentVerification",

    "continuousBinding",

    "enclaveSignature"

  \],

  "properties": {

    "specVersion": {

      "type": "string",

      "const": "SPEC-IDBIO-200-v3.0"

    },

    "sessionId": {

      "type": "string",

      "format": "uuid"

    },

    "serverNonce": {

      "type": "string",

      "pattern": "^\[A-Za-z0-9\_-\]{32,128}\$",

      "description": "Base64URL-encoded cryptographic challenge nonce issued by the relying party."

    },

    "timestampMs": {

      "type": "integer",

      "minimum": 1700000000000,

      "maximum": 4102444800000

    },

    "hardwareAttestation": {

      "type": "object",

      "additionalProperties": false,

      "required": \["platform", "keyId", "attestationFormat", "certificateChainB64"\],

      "properties": {

        "platform": {

          "type": "string",

          "enum": \["IOS\_SECURE\_ENCLAVE", "ANDROID\_STRONGBOX", "ANDROID\_TEE"\]

        },

        "keyId": {

          "type": "string",

          "pattern": "^\[A-Za-z0-9\_-\]{16,128}\$"

        },

        "attestationFormat": {

          "type": "string",

          "enum": \["APPLE\_APP\_ATTEST", "ANDROID\_KEY\_ATTESTATION", "FIDO2\_WEBAUTHN"\]

        },

        "certificateChainB64": {

          "type": "array",

          "minItems": 1,

          "maxItems": 5,

          "items": {

            "type": "string",

            "pattern": "^\[A-Za-z0-9+/=\]+\$"

          }

        }

      }

    },

    "physicsGate": {

      "type": "object",

      "additionalProperties": false,

      "required": \[

        "telemetryBitmask",

        "photometricExposureDeltaMs",

        "tremorParallaxCorrelation",

        "barometricVariancePa"

      \],

      "properties": {

        "telemetryBitmask": {

          "type": "integer",

          "minimum": 0,

          "maximum": 65535

        },

        "photometricExposureDeltaMs": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 33.4,

          "description": "Latency between screen chromatic pulse vsync and CMOS exposure timestamp."

        },

        "tremorParallaxCorrelation": {

          "type": "number",

          "minimum": \-1.0,

          "maximum": 1.0,

          "description": "Phase correlation between 8-12 Hz bandpass IMU tremor and differential foreground/background optical flow."

        },

        "barometricVariancePa": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 500.0

        }

      }

    },

    "biometricVerification": {

      "type": "object",

      "additionalProperties": false,

      "required": \[

        "backboneId",

        "rawCosineSimilarity",

        "calibratedSimilarityScore",

        "probeQualityNorm",

        "refQualityNorm",

        "padConfidenceScore",

        "decision",

        "memoryScrubbed"

      \],

      "properties": {

        "backboneId": {

          "type": "string",

          "enum": \["ADAFACE\_IRESNET50\_V2", "ADAFACE\_MOBILEFACENET\_V2"\]

        },

        "rawCosineSimilarity": {

          "type": "number",

          "minimum": \-1.0,

          "maximum": 1.0

        },

        "calibratedSimilarityScore": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 1000.0,

          "description": "NIST-calibrated similarity scale where 500.0 anchors FMR \= 10^-6."

        },

        "probeQualityNorm": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 100.0

        },

        "refQualityNorm": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 100.0

        },

        "padConfidenceScore": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 1.0

        },

        "decision": {

          "type": "string",

          "enum": \["MATCH", "NON\_MATCH", "PAD\_REJECT", "QUALITY\_REJECT"\]

        },

        "memoryScrubbed": {

          "type": "boolean",

          "const": true

        }

      }

    },

    "documentVerification": {

      "type": "object",

      "additionalProperties": false,

      "required": \[

        "credentialClass",

        "issuerJurisdictionIIN",

        "authMechanism",

        "docHypersphereSimilarity",

        "ovdDiffractionGradient",

        "frontToBackParityScore",

        "cryptographicSignatureValid",

        "identityClaimsCommitmentHash"

      \],

      "properties": {

        "credentialClass": {

          "type": "string",

          "enum": \["ISO\_7810\_ID1", "ICAO\_9303\_ID3", "ISO\_18013\_5\_MDL"\]

        },

        "issuerJurisdictionIIN": {

          "type": "string",

          "pattern": "^\[A-Z0-9\]{2,10}\$",

          "description": "AAMVA 6-digit IIN (e.g., 636045 for WA) or ISO 3166-1 alpha-3 country code."

        },

        "authMechanism": {

          "type": "string",

          "enum": \["OPTICAL\_HYPERSPHERE\_AAMVA", "NFC\_ICAO\_9303\_SOD\_AA", "MDL\_COSE\_SIGN1"\]

        },

        "docHypersphereSimilarity": {

          "type": "number",

          "minimum": \-1.0,

          "maximum": 1.0,

          "description": "Cosine similarity d · w\_c against the 512-D jurisdiction centroid (0.0 if NFC/mDL)."

        },

        "ovdDiffractionGradient": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 100.0

        },

        "frontToBackParityScore": {

          "type": "number",

          "minimum": 0.0,

          "maximum": 1.0

        },

        "cryptographicSignatureValid": {

          "type": "boolean"

        },

        "identityClaimsCommitmentHash": {

          "type": "string",

          "pattern": "^\[a-f0-9\]{64}\$",

          "description": "SHA-256 commitment hash of normalized (DocNum || DOB || ExpDate || ServerNonce) so zero raw PII crosses the wire."

        }

      }

    },

    "continuousBinding": {

      "type": "object",

      "additionalProperties": false,

      "required": \["heartbeatIntervalMs", "ephemeralSessionPublicKeyB64", "custodyStateChainHash"\],

      "properties": {

        "heartbeatIntervalMs": {

          "type": "integer",

          "minimum": 500,

          "maximum": 30000

        },

        "ephemeralSessionPublicKeyB64": {

          "type": "string",

          "pattern": "^\[A-Za-z0-9\_-\]{40,128}\$"

        },

        "custodyStateChainHash": {

          "type": "string",

          "pattern": "^\[a-f0-9\]{64}\$"

        }

      }

    },

    "enclaveSignature": {

      "type": "object",

      "additionalProperties": false,

      "required": \["coseAlgorithm", "coseSign1PayloadB64"\],

      "properties": {

        "coseAlgorithm": {

          "type": "integer",

          "const": \-7

        },

        "coseSign1PayloadB64": {

          "type": "string",

          "pattern": "^\[A-Za-z0-9\_-\]+\$"

        }

      }

    }

  }

}

## **A.3 TypeScript Bridge Interface (Layer4AssertionPayload)**

Generated directly from the JSON Schema above for strict type-safe consumption after `ajv.validate()` passes in the React Native / native bridge container:export interface Layer4AssertionPayload {

  specVersion: "SPEC-IDBIO-200-v3.0";

  sessionId: string;

  serverNonce: string;

  timestampMs: number;

  hardwareAttestation: {

    platform: "IOS\_SECURE\_ENCLAVE" | "ANDROID\_STRONGBOX" | "ANDROID\_TEE";

    keyId: string;

    attestationFormat: "APPLE\_APP\_ATTEST" | "ANDROID\_KEY\_ATTESTATION" | "FIDO2\_WEBAUTHN";

    certificateChainB64: string\[\];

  };

  physicsGate: {

    telemetryBitmask: number;

    photometricExposureDeltaMs: number;

    tremorParallaxCorrelation: number;

    barometricVariancePa: number;

  };

  biometricVerification: {

    backboneId: "ADAFACE\_IRESNET50\_V2" | "ADAFACE\_MOBILEFACENET\_V2";

    rawCosineSimilarity: number;

    calibratedSimilarityScore: number;

    probeQualityNorm: number;

    refQualityNorm: number;

    padConfidenceScore: number;

    decision: "MATCH" | "NON\_MATCH" | "PAD\_REJECT" | "QUALITY\_REJECT";

    memoryScrubbed: true;

  };

  documentVerification: {

    credentialClass: "ISO\_7810\_ID1" | "ICAO\_9303\_ID3" | "ISO\_18013\_5\_MDL";

    issuerJurisdictionIIN: string;

    authMechanism: "OPTICAL\_HYPERSPHERE\_AAMVA" | "NFC\_ICAO\_9303\_SOD\_AA" | "MDL\_COSE\_SIGN1";

    docHypersphereSimilarity: number;

    ovdDiffractionGradient: number;

    frontToBackParityScore: number;

    cryptographicSignatureValid: boolean;

    identityClaimsCommitmentHash: string;

  };

  continuousBinding: {

    heartbeatIntervalMs: number;

    ephemeralSessionPublicKeyB64: string;

    custodyStateChainHash: string;

  };

  enclaveSignature: {

    coseAlgorithm: \-7;

    coseSign1PayloadB64: string;

  };

}  
