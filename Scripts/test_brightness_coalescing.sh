#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
brightness_test_dir=$(mktemp -d /tmp/boring-brightness-checks.XXXXXX)
trap 'rm -rf "$brightness_test_dir"' EXIT
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -sdk "$SDKROOT" \
  boringNotch/components/OSD/Managers/XPC/BrightnessManager.swift Scripts/BrightnessCoalescingChecks.swift \
  -o "$brightness_test_dir/checks"
"$brightness_test_dir/checks"
