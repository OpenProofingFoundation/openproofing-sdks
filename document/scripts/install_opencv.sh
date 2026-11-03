#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "$0")/.." && pwd)"
destination="$repository_root/.build/native/opencv2.xcframework"
archive_url="https://github.com/ossappscollective/OSS-DocumentScanner/releases/download/dev_resources/ios.zip"
archive_sha256="980a041077a8fcb44ef98e0f3a9710fe029e4458ebdbedb0d3d3b598129a651f"

verify_source_framework() {
  local candidate="$1"
  local plist="$candidate/macos-arm64_x86_64/opencv2.framework/Versions/A/Resources/Info.plist"
  [[ -f "$candidate/Info.plist" ]] || return 1
  [[ -f "$plist" ]] || return 1
  [[ "$(plutil -extract CFBundleShortVersionString raw "$plist")" == "4.12.0" ]] || return 1
  plutil -p "$candidate/Info.plist" | grep -q 'ios-arm64_x86_64-simulator' || return 1
  plutil -p "$candidate/Info.plist" | grep -q 'macos-arm64_x86_64' || return 1
}

mobile_identifiers=(
  ios-arm64
  ios-arm64_x86_64-simulator
  tvos-arm64_arm64e
  tvos-arm64_x86_64-simulator
  watchos-arm64_32_armv7k
  watchos-arm64_x86_64-simulator
  xros-arm64
  xros-arm64_x86_64-simulator
)

normalize_mobile_frameworks() {
  local candidate="$1"
  local identifier framework versioned executable index library_count
  for identifier in "${mobile_identifiers[@]}"; do
    framework="$candidate/$identifier/opencv2.framework"
    versioned="$framework/Versions/A"
    [[ -f "$versioned/opencv2" && -f "$versioned/Resources/Info.plist" ]] || return 1

    rm "$framework/Headers" "$framework/Resources" "$framework/opencv2"
    cp -R "$versioned/Headers" "$framework/Headers"
    cp -p "$versioned/opencv2" "$framework/opencv2"
    cp -R "$versioned/Resources/." "$framework/"
    rm -rf "$framework/Versions"

    executable="$(plutil -extract CFBundleExecutable raw "$framework/Info.plist" 2>/dev/null || true)"
    if [[ -z "$executable" ]]; then
      /usr/libexec/PlistBuddy -c "Add :CFBundleExecutable string opencv2" "$framework/Info.plist"
    elif [[ "$executable" != "opencv2" ]]; then
      return 1
    fi
  done

  library_count="$(plutil -convert json -o - "$candidate/Info.plist" | jq '.AvailableLibraries | length')"
  for ((index = 0; index < library_count; index++)); do
    identifier="$(plutil -extract "AvailableLibraries.$index.LibraryIdentifier" raw "$candidate/Info.plist")"
    if [[ " ${mobile_identifiers[*]} " == *" $identifier "* ]]; then
      /usr/libexec/PlistBuddy \
        -c "Set :AvailableLibraries:$index:BinaryPath opencv2.framework/opencv2" \
        "$candidate/Info.plist"
    fi
  done
}

verify_installation() {
  local candidate="$1"
  local identifier framework binary_path
  verify_source_framework "$candidate" || return 1
  for identifier in "${mobile_identifiers[@]}"; do
    framework="$candidate/$identifier/opencv2.framework"
    [[ -f "$framework/Info.plist" && -f "$framework/opencv2" ]] || return 1
    [[ ! -e "$framework/Versions" ]] || return 1
    [[ "$(plutil -extract CFBundleExecutable raw "$framework/Info.plist" 2>/dev/null)" == "opencv2" ]] \
      || return 1
    binary_path="$(plutil -convert json -o - "$candidate/Info.plist" \
      | jq -r --arg identifier "$identifier" \
        '.AvailableLibraries[] | select(.LibraryIdentifier == $identifier) | .BinaryPath')"
    [[ "$binary_path" == "opencv2.framework/opencv2" ]] || return 1
  done
}

# A checkout made without Git LFS content (CI uses lfs: false) leaves the tracked framework as
# Git LFS pointer files. Such a tree is a placeholder, not an installation: it is replaced like a
# legacy layout. A tree with any file that is not a pointer is still refused below.
only_lfs_pointers() {
  local candidate="$1" file count=0
  while IFS= read -r -d '' file; do
    [[ "$(head -n 1 "$file")" == "version https://git-lfs.github.com/spec/v1" ]] || return 1
    count=$((count + 1))
  done < <(find "$candidate" -type f -print0)
  [[ "$count" -gt 0 ]]
}

replace_legacy_installation=0
if [[ -e "$destination" ]]; then
  if verify_installation "$destination"; then
    python3 "$repository_root/scripts/verify_capture_opencv.py" "$destination"
    echo "OpenCV 4.12.0 XCFramework is already installed"
    exit 0
  fi
  if verify_source_framework "$destination" || only_lfs_pointers "$destination"; then
    replace_legacy_installation=1
  else
    echo "refusing to replace an unrecognized OpenCV installation at $destination" >&2
    exit 1
  fi
fi

temporary_root="$(mktemp -d "${TMPDIR:-/tmp}/identity-evidence-opencv.XXXXXX")"
trap 'rm -rf "$temporary_root"' EXIT
archive="$temporary_root/ios.zip"

curl --proto '=https' --proto-redir '=https' -L --fail --show-error --output "$archive" "$archive_url"
actual_sha256="$(shasum -a 256 "$archive" | awk '{print $1}')"
if [[ "$actual_sha256" != "$archive_sha256" ]]; then
  echo "OpenCV resource digest mismatch" >&2
  exit 1
fi

unzip -q "$archive" 'opencv/ios/opencv2.xcframework/*' -d "$temporary_root/extracted"
candidate="$temporary_root/extracted/opencv/ios/opencv2.xcframework"
if ! verify_source_framework "$candidate"; then
  echo "downloaded OpenCV resource does not contain the expected XCFramework" >&2
  exit 1
fi
normalize_mobile_frameworks "$candidate"
if ! verify_installation "$candidate"; then
  echo "normalized OpenCV resource failed XCFramework verification" >&2
  exit 1
fi

python3 "$repository_root/scripts/verify_capture_opencv.py" "$candidate"

mkdir -p "$(dirname "$destination")"
if [[ "$replace_legacy_installation" == "1" ]]; then
  mv "$destination" "$temporary_root/legacy-opencv2.xcframework"
fi
mv "$candidate" "$destination"
echo "installed OpenCV 4.12.0 XCFramework with Apple-compliant mobile framework layout"
