#!/bin/bash
# Test the production state machine and IOPM service with Apple's CLI toolchain.
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
focus_test_dir=$(mktemp -d /tmp/boring-focus-tests.XXXXXX)
trap 'rm -rf "$focus_test_dir"' EXIT
cat > "$focus_test_dir/Haptics.swift" <<'SWIFT'
import AppKit
@MainActor enum FocusHaptics { static func action() {} }
SWIFT
engine_binary_dir=$(/usr/bin/xcrun --sdk macosx swift build --build-system native -c release --show-bin-path)
[[ -f "$engine_binary_dir/Modules/CaffeineEngine.swiftmodule" ]] || { echo "Build the local app before running focus checks." >&2; exit 1; }
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -strict-concurrency=complete -warnings-as-errors \
  -parse-as-library -I "$engine_binary_dir/Modules" -sdk "$SDKROOT" -target arm64-apple-macosx14.0 \
  boringNotch/models/FocusSessionMode.swift boringNotch/models/FocusSessionState.swift \
  boringNotch/models/FocusDurationSelection.swift boringNotch/models/FocusSessionSnapshot.swift boringNotch/managers/FocusPowerManaging.swift \
  boringNotch/managers/CaffeineManager.swift boringNotch/managers/FocusSessionManager.swift \
  boringNotch/managers/CaffeineSettings.swift boringNotch/models/CaffeineAppChoice.swift \
  "$engine_binary_dir"/CaffeineEngine.build/*.o \
  "$focus_test_dir/Haptics.swift" Scripts/FocusSessionChecks.swift -o "$focus_test_dir/checks"
"$focus_test_dir/checks" "$@"
