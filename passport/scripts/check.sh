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
  xcodebuild -version
  swift --version
  swift test
  python3 scripts/guards/public_api.py macos
fi
if [[ "$check_platform" == ios-device || "$check_platform" == apple || "$check_platform" == all ]]; then
  xcodebuild -version
  xcodebuild -scheme KenshikiPassportSDK-Package -destination "generic/platform=iOS" \
    -derivedDataPath "$repo_dir/.build/ios-device" CODE_SIGNING_ALLOWED=NO build
  python3 scripts/guards/public_api.py ios-device
fi
if [[ "$check_platform" == ios-simulator || "$check_platform" == apple || "$check_platform" == all ]]; then
  xcodebuild -version
  xcodebuild -scheme KenshikiPassportSDK-Package -destination "generic/platform=iOS Simulator" \
    -derivedDataPath "$repo_dir/.build/ios-simulator" CODE_SIGNING_ALLOWED=NO build
  python3 scripts/guards/public_api.py ios-simulator
fi
if [[ "$check_platform" == android || "$check_platform" == all ]]; then
  java -version
  cd "$repo_dir/android"
  ./gradlew :passport-sdk:assembleDebug :passport-sdk:lintDebug :passport-sdk:testDebugUnitTest --console=plain
  cd "$repo_dir"
  python3 scripts/guards/public_api.py android
  python3 Gates/capability_guards.py --aar android/passport-sdk/build/outputs/aar/passport-sdk-debug.aar
fi
