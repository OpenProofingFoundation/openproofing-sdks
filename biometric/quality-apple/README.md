# Optional Apple face quality package

This package supplies local OFIQ assessment independently of capture and matching. It consumes the parent biometric primitives and the parent’s single pinned runtime binary through `BiometricRuntime`. Basic `BiometricSDK` consumers do not resolve or build this quality package. The large quality models remain separately provisioned external inputs.

Before resolving this optional package, run `python3 ../tools/native_quality/build.py --ensure` using the repository Python toolchain. This source-build recipe creates the local three-platform XCFramework with no weights or second runtime. Its exact source/config/model/notice profile is documented in the parent selection contract and architecture appendix A.19. The reference app packages the complete checked profile into its signed bundle; a compile-only artifact without those assets cannot execute quality assessment.

Carry the notices in `../third-party/ofiq` and the ONNX Runtime attribution when distributing a model-bearing application. Native tests, resource measurements, physical capture and recognition utility remain separate evidence.
