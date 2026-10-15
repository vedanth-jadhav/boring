#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
surface_binary_dir="$PWD/.build/$(uname -m)-apple-macosx/debug"
surface_test_dir=$(mktemp -d /tmp/boring-notch-surface.XXXXXX)
trap 'rm -rf "$surface_test_dir"' EXIT
surface_defaults_objects=("$surface_binary_dir/Defaults.build/"*.o)
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors -DBORING_LOCAL_BUILD -parse-as-library -sdk "$SDKROOT" \
  -I "$surface_binary_dir/Modules" \
  boringNotch/components/Notch/NotchShape.swift boringNotch/components/NativeNotchGlass.swift \
  boringNotch/components/LiquidGlassBackground.swift boringNotch/extensions/PanGesture.swift boringNotch/extensions/ConditionalModifier.swift \
  Scripts/NotchSurfaceChecks.swift \
  "${surface_defaults_objects[@]}" -o "$surface_test_dir/checks"
"$surface_test_dir/checks"
