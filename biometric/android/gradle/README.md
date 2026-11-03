# Android dependency verification

`verification-metadata.xml` pins SHA-256 digests for the resolved Android/Kotlin plugin, build tooling and SDK test dependency artifacts and their dependency metadata. Gradle automatically enforces it in strict mode. Production runtime dependencies remain unchanged.

The initial inventory was generated against the actual assemble, lint and unit-test graph using the existing pinned Gradle wrapper and repository configuration:

```sh
./gradlew :biometric-sdk:assembleDebug :biometric-sdk:lintDebug :biometric-sdk:testDebugUnitTest --write-verification-metadata sha256 --console=plain
```

Generation bootstraps checksums from repository artifacts; it is a reviewed maintenance operation, never an automatic CI repair. Review every changed coordinate/digest and refresh the repository guard pin when intentionally updating dependencies. Normal builds must not use `--write-verification-metadata`, disable verification, or add trusted-artifact exceptions.

Validation runs the same tasks with `--dependency-verification=strict`. A separate temporary project with the Android Gradle plugin JAR checksum deliberately changed was rejected by Gradle. New platform-specific artifacts must be reviewed and pinned before adding tasks that resolve them.
