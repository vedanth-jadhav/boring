#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
fullscreen_test_dir=$(mktemp -d /tmp/boring-fullscreen-checks.XXXXXX)
trap 'rm -rf "$fullscreen_test_dir"' EXIT
fullscreen_binary_dir="$PWD/.build/$(uname -m)-apple-macosx/debug"
[[ -d "$fullscreen_binary_dir/Modules" ]] || fullscreen_binary_dir="$PWD/.build/debug"
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library -emit-module -emit-object \
  -module-name MacroVisionKit Scripts/FullscreenMonitorFixture.swift \
  -emit-module-path "$fullscreen_test_dir/MacroVisionKit.swiftmodule" -o "$fullscreen_test_dir/monitor.o"
fullscreen_objects=("$fullscreen_binary_dir/Defaults.build/"*.o)
xcrun --sdk macosx swiftc -swift-version 5 -parse-as-library \
  -I "$fullscreen_test_dir" -I "$fullscreen_binary_dir/Modules" \
  boringNotch/observers/FullscreenMediaDetection.swift Scripts/FullscreenDetectionChecks.swift \
  "$fullscreen_test_dir/monitor.o" "${fullscreen_objects[@]}" -o "$fullscreen_test_dir/checks"
"$fullscreen_test_dir/checks"
