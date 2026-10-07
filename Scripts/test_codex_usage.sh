#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
codex_test_dir=$(mktemp -d /tmp/boring-codex-tests.XXXXXX)
trap 'rm -rf "$codex_test_dir"' EXIT
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -sdk "$SDKROOT" -target arm64-apple-macosx14.0 \
  boringNotch/models/Codex/*.swift boringNotch/managers/Codex/*.swift \
  Scripts/CodexUsageChecks.swift -o "$codex_test_dir/checks"
"$codex_test_dir/checks" "$@"
