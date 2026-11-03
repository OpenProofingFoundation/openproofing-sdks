# Portable C++20 primitives

`kenshiki/portrait.hpp` implements the decoded pixel, comparison binding and
embedding numerical contracts without mobile capture, attestation, storage or a
BFF. It is reusable by the future NIST algorithm adapter; it does not implement
recognition, a decoder, inference, portable template serialization or the NIST
algorithm interface. The upstream null adapter remains separate.

## Optional aligned-input inference

`kenshiki/auraface_input.hpp` adds the fixed [RGB112 profile](../../contracts/auraface-aligned-input-v1.md)
to the dependency-free portable target. `kenshiki/auraface.hpp` is the separate
optional CPU inference API: `Session` takes stable model bytes, owns a verified
copy and returns the consumed pixel digest, raw features and a manifest-bound
normalized embedding. It performs no model acquisition, filesystem access,
capture, detection, alignment or identity acceptance. The caller keeps constructor
input stable during the copy; later mutation cannot change the session. Inference
on one session serializes. The synchronous API has no cancellation primitive;
surrounding operation fences control whether a result may be published.

The public adapter accepts only the exact owner-selected AuraFace artifact.
Its internal unexported-header engine is exercised with generated synthetic ONNX
graphs; that test seam is not a configurable public model loader. ORT exceptions
become typed failures without exposing their prose. Allocation failures report
`resource_limit`; portable pixel/numerical failures retain their original codes.
The host still owns overall process memory, worker concurrency and model supply.
The adapter's fixed byte ceiling does not establish a process memory ceiling for
the runtime or independently qualify the weights for mobile deployment.

Configure the optional Linux target explicitly with the reviewed external ONNX
Runtime 1.22.0 CPU installation:

```sh
cmake -S biometric/cpp -B .build/auraface-cmake -G Ninja \
  -DCMAKE_CXX_COMPILER=g++-13 -DKENSHIKI_AURAFACE=ON \
  -DONNXRUNTIME_ROOT=/absolute/external/onnxruntime-linux-x64-1.22.0
cmake --build .build/auraface-cmake --target kenshiki_auraface
```

Default CMake builds remain ORT-independent. Consumers must provide trusted
runtime binaries: API/version checks alone are not binary authentication.
`Gates/onnxruntime-linux-x64.json` pins the Microsoft archive and selected members
for the qualification runner, which downloads only that runtime, never weights:

```sh
bash scripts/python.sh biometric/cpp/check_inference.py
# On this Mac, use the prepared Linux amd64 development container:
bash scripts/python.sh biometric/cpp/check_inference.py \
  --container-image kenshiki-face-frte-dev:20261016 \
  --runtime-archive /absolute/external/onnxruntime-linux-x64-1.22.0.tgz \
  --model /absolute/external/glintr100.onnx
```

The first command requires Linux x86_64, g++13, OpenSSL development headers,
CMake and Ninja. The optional `--model` path must be outside the monorepo and
must pass the public adapter's exact size/hash checks. CI uses generated graphs
and sanitizer tests without real images or learned model files. Local qualification
also checks the actual artifact against retained synthetic reference features.
Receipts distinguish this inference from the official null-driver mechanics and
from the still-unimplemented FRTE recognition adapter.

Pixel creation checks schema, integer type, orientation, dimensions and packed
lengths before copying or hashing any payload. Descriptor integers use the
positive signed-64 domain shared with mobile;
unsigned values above `INT64_MAX` fail as invalid pixels before resource checks.
The synchronous caller must keep
its input span valid and stable during creation. The accepted object owns an
immutable defensive snapshot. Copies share that immutable owner; returned spans
remain valid only while an owning snapshot lives. Never retain a span beyond its
owner. Hashing uses CommonCrypto on Apple and OpenSSL EVP on Linux, over the
exact accepted snapshot. Original/source/derivation records still belong to the
producer; a consistent selected-byte digest does not verify issuer authenticity.

`ComparisonBinding` validates all session, operation, selected/source/lineage and
artifact identifiers. `ComparisonRequest` owns both snapshots and verifies that
their exact hashes match the binding. `CompletionFence` only accepts these bound
requests and atomically returns a current request once, rejecting foreign,
duplicate and late completions. Cancellation invalidates before invoking external
work through an unlocked callback. Cancellation and completion have a defined mutex ordering;
completion that wins the lock before cancellation is accepted. Batch pixel/math
APIs do not require this optional interactive envelope. No physical admission or
proof verification is inferred from a binding.

Each fence owns the operation-ID history for its lifetime. Begin while busy fails;
an operation ID cannot be reused after completion or cancellation, including with
a different envelope. Hosts retain a fence for the ceremony they protect and
must not replace it to resume an old request. The used-ID history is in memory;
durable replay protection remains the separate custody/BFF mechanism.

Embedding math implements `embedding-math-v1`: finite FP32 model features, FP64
norm/normalization/dot, inclusive explicit norm floor, complete space identity,
clamped cosine and radians. It follows the pinned ArcFace/FaceNet method notes'
normalized comparison; numerical choices and failures are our declared contract,
not measured model performance. There is no threshold or identity verdict.
`CosineObservation` retains the complete embedding space;
`BoundComparisonObservation` rejects artifact or face-domain mismatches while
retaining the exact request binding. Calling this constructor establishes
structural consistency; it does not prove an inference engine consumed the inputs.

Run the governed shared-vector/adversarial executable and official null-driver
mechanics together:

```sh
bash scripts/python.sh biometric/nist/check.py
```

The runner generates C++ cases from every current shared portrait vector and
executes them under AddressSanitizer and UndefinedBehaviorSanitizer. Additional
tests cover caller mutation/lifetime, uint64 bounds, truncated maximum metadata,
concurrent duplicate completion, cancellation, numerical extremes and embedding
space incompatibility. The source-derived fixture include stays in `.build/`.
Receipts distinguish portable tests from null mechanics and official validation.
Linux needs OpenSSL development headers (`libssl-dev` on Ubuntu); no crypto source
is vendored. Standalone library consumers may use the adjacent CMake project.
