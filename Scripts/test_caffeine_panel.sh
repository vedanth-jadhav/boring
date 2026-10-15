#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source Scripts/toolchain.sh
panel_test_dir=$(mktemp -d /tmp/boring-caffeine-panel.XXXXXX)
trap 'rm -rf "$panel_test_dir"' EXIT
binary_dir="$PWD/.build/release"
/usr/bin/xcrun --sdk macosx swiftc -swift-version 5 -DBORING_LOCAL_BUILD -parse-as-library -sdk "$SDKROOT" \
  -target arm64-apple-macosx27.0 -I "$binary_dir/Modules" \
  boringNotch/helpers/ViewState.swift boringNotch/components/Focus/DurationRuler.swift \
  boringNotch/components/Focus/DurationRulerTick.swift boringNotch/components/Focus/CenteredRulerSnapping.swift \
  boringNotch/components/Focus/RulerMouseDrag.swift boringNotch/components/Focus/RulerInputSurface.swift \
  boringNotch/components/Focus/CaffeineSearchTextField.swift boringNotch/components/Focus/CaffeineSearchField.swift \
  boringNotch/components/Focus/CaffeineSetupView.swift boringNotch/components/Focus/CaffeineAppRow.swift \
  boringNotch/components/Focus/FocusTimerView.swift boringNotch/components/Focus/FocusDurationPicker.swift \
  boringNotch/models/FocusDurationSelection.swift boringNotch/models/FocusSessionMode.swift boringNotch/models/CaffeineAppChoice.swift \
  boringNotch/components/Focus/FocusControlSurface.swift boringNotch/extensions/PanGesture.swift \
  boringNotch/components/Notch/BoringNotchSkyLightWindow.swift boringNotch/components/Notch/NotchKeyboardFocus.swift \
  boringNotch/components/Notch/NotchHostingView.swift boringNotch/components/Notch/NotchShape.swift \
  boringNotch/components/NativeNotchGlass.swift boringNotch/components/LiquidGlassBackground.swift \
  "$binary_dir"/SwiftUIIntrospect.build/*.o "$binary_dir"/Defaults.build/*.o \
  "$binary_dir"/SkyLightWindow.build/*.o Scripts/CaffeinePanelModels.swift Scripts/CaffeinePanelChecks.swift -o "$panel_test_dir/checks"
"$panel_test_dir/checks"
