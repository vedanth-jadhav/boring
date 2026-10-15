#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
ruler_test_dir=$(mktemp -d /tmp/boring-ruler-tests.XXXXXX)
trap 'rm -rf "$ruler_test_dir"' EXIT
binary_dir="$PWD/.build/release"
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -DBORING_LOCAL_BUILD -parse-as-library -sdk "$SDKROOT" \
  -target arm64-apple-macosx14.0 -I "$binary_dir/Modules" \
  boringNotch/helpers/ViewState.swift boringNotch/components/Focus/DurationRuler.swift \
  boringNotch/components/Focus/DurationRulerTick.swift boringNotch/components/Focus/CenteredRulerSnapping.swift \
  boringNotch/components/Focus/RulerMouseDrag.swift boringNotch/components/Focus/RulerInputSurface.swift \
  boringNotch/extensions/PanGesture.swift boringNotch/components/Notch/BoringNotchSkyLightWindow.swift \
  boringNotch/components/Notch/NotchKeyboardFocus.swift \
  boringNotch/components/Notch/NotchHostingView.swift \
  boringNotch/components/Notch/NotchShape.swift boringNotch/components/NativeNotchGlass.swift \
  boringNotch/components/LiquidGlassBackground.swift \
  "$binary_dir"/SwiftUIIntrospect.build/*.o "$binary_dir"/Defaults.build/*.o \
  "$binary_dir"/SkyLightWindow.build/*.o Scripts/DurationRulerChecks.swift -o "$ruler_test_dir/checks"
"$ruler_test_dir/checks"
