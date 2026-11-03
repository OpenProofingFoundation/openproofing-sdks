#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
case "${1:-all}" in
  guards|macos|ios-device|ios-simulator|apple|android|all) check_platform="${1:-all}" ;;
  *) echo 'Usage: scripts/check.sh [guards|macos|ios-device|ios-simulator|apple|android|all]' >&2; exit 2 ;;
esac
python3 scripts/quality.py
# The local native artifact belongs only to the explicitly checked optional sidecar.
# Plain BiometricSDK SwiftPM consumers never resolve or bootstrap it.
if [[ "$check_platform" == macos || "$check_platform" == ios-device || "$check_platform" == ios-simulator || "$check_platform" == apple || "$check_platform" == all ]]; then
  python3 tools/native_quality/build.py --ensure
fi
if [[ "$check_platform" == macos || "$check_platform" == apple || "$check_platform" == all ]]; then
  xcodebuild -version
  swift --version
  rm -f .build/portrait-tests.xml
  swift test --parallel --disable-swift-testing --xunit-output .build/portrait-tests.xml
  python3 ../quality/portrait_evidence.py --platform swift --report .build/portrait-tests.xml
  mkdir -p quality-apple/.build
  rm -f quality-apple/.build/quality-tests.xml
  swift test --package-path quality-apple --parallel --disable-swift-testing --xunit-output "$repo_dir/quality-apple/.build/quality-tests.xml"
  python3 ../quality/portrait_evidence.py --platform quality-swift --report quality-apple/.build/quality-tests.xml
  python3 scripts/guards/public_api.py macos
fi
if [[ "$check_platform" == ios-device || "$check_platform" == apple || "$check_platform" == all ]]; then
  xcodebuild -version
  xcodebuild -scheme KenshikiBiometricSDK-Package -destination "generic/platform=iOS" \
    -derivedDataPath "$repo_dir/.build/ios-device" CODE_SIGNING_ALLOWED=NO build
  cd "$repo_dir/quality-apple"
  xcodebuild -scheme KenshikiFaceQuality -destination "generic/platform=iOS" \
    -derivedDataPath "$repo_dir/quality-apple/.build/ios-device" CODE_SIGNING_ALLOWED=NO build
  cd "$repo_dir"
  python3 scripts/guards/public_api.py ios-device
fi
if [[ "$check_platform" == ios-simulator || "$check_platform" == apple || "$check_platform" == all ]]; then
  xcodebuild -version
  xcodebuild -scheme KenshikiBiometricSDK-Package -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$repo_dir/.build/ios-simulator" CODE_SIGNING_ALLOWED=NO build
  cd "$repo_dir/quality-apple"
  xcodebuild -scheme KenshikiFaceQuality -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$repo_dir/quality-apple/.build/ios-simulator" CODE_SIGNING_ALLOWED=NO build
  cd "$repo_dir"
  python3 scripts/guards/public_api.py ios-simulator
fi
if [[ "$check_platform" == android || "$check_platform" == all ]]; then
  java -version
  cd "$repo_dir/android"
  ./gradlew :biometric-sdk:assembleDebug :biometric-sdk:lintDebug :biometric-sdk:testDebugUnitTest --console=plain
  cd "$repo_dir"
  python3 ../quality/portrait_evidence.py --platform android --report android/biometric-sdk/build/test-results/testDebugUnitTest
  python3 scripts/guards/public_api.py android
  python3 Gates/capability_guards.py --aar android/biometric-sdk/build/outputs/aar/biometric-sdk-debug.aar
fi
