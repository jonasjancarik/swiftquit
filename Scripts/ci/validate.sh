#!/usr/bin/env bash
set -Eeuo pipefail

export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-${RUNNER_TEMP:-/tmp}/clang-module-cache}"

result_root="${RUNNER_TEMP:-/tmp}/xcode-results"
derived_data="${RUNNER_TEMP:-/tmp}/SwiftQuit-DerivedData"

mkdir -p "$result_root" "$derived_data" "$CLANG_MODULE_CACHE_PATH"

echo "::group::Environment"
sw_vers
xcodebuild -version
echo "::endgroup::"

xcodebuild test \
  -project "Swift Quit.xcodeproj" \
  -scheme "Swift Quit" \
  -destination "platform=macOS" \
  -derivedDataPath "$derived_data" \
  -resultBundlePath "$result_root/SwiftQuit.xcresult"
