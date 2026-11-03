#!/usr/bin/env bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$repo_dir"
case "${1:-all}" in
  guards|macos|ios-device|ios-simulator|apple|android|all) check_platform="${1:-all}" ;;
  *) echo 'Usage: scripts/check.sh [guards|macos|ios-device|ios-simulator|apple|android|all]' >&2; exit 2 ;;
esac
python3 scripts/quality.py
if [[ "$check_platform" == macos || "$check_platform" == apple || "$check_platform" == all ]]; then
  python3 scripts/provision_native.py
  xcodebuild -version
  swift --version
  python3 scripts/provision_test_assets.py
  swift test
  python3 scripts/guards/public_api.py macos
fi
if [[ "$check_platform" == ios-device || "$check_platform" == apple || "$check_platform" == all ]]; then
  python3 scripts/provision_native.py
  xcodebuild -version
  xcodebuild -scheme KenshikiDocumentSDK-Package -destination "generic/platform=iOS" \
    -derivedDataPath "$repo_dir/.build/ios-device" CODE_SIGNING_ALLOWED=NO build
  python3 scripts/guards/public_api.py ios-device
  python3 scripts/check_example.py ios-device
fi
if [[ "$check_platform" == ios-simulator || "$check_platform" == apple || "$check_platform" == all ]]; then
  python3 scripts/provision_native.py
  xcodebuild -version
  xcodebuild -scheme KenshikiDocumentSDK-Package -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$repo_dir/.build/ios-simulator" CODE_SIGNING_ALLOWED=NO build
  python3 scripts/guards/public_api.py ios-simulator
  python3 scripts/check_example.py ios-simulator
fi
if [[ "$check_platform" == android || "$check_platform" == all ]]; then
  java -version
  cd "$repo_dir/android"
  ./gradlew :document-sdk:assembleDebug :document-sdk:lintDebug :document-sdk:testDebugUnitTest --console=plain
  cd "$repo_dir"
  python3 scripts/guards/public_api.py android
  python3 Gates/capability_guards.py --aar android/document-sdk/build/outputs/aar/document-sdk-debug.aar
fi
