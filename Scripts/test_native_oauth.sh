#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
native_oauth_test_dir=$(mktemp -d /tmp/boring-native-oauth.XXXXXX)
trap 'rm -rf "$native_oauth_test_dir"' EXIT
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -sdk "$SDKROOT" -target arm64-apple-macosx14.0 \
  boringNotch/models/Codex/*.swift boringNotch/managers/Codex/*.swift \
  boringNotch/models/AIUsage/*.swift boringNotch/managers/AIUsage/*.swift \
  Scripts/NativeOAuthChecks.swift -o "$native_oauth_test_dir/checks"
"$native_oauth_test_dir/checks" "$@"
